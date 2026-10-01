#!/usr/bin/env bash
# adbroute.sh — 建立并修复"容器 → Android 的 adb 通道"。
#
# 为什么这是安装第一步而不是预检里的一句报错：接管与交还的每一步都要经 adb 驱动 Android。
# 通道没建立之前，"读不到机型""属性为空"都只是症状，不是原因。
#
# ★ 本文件按**这台设备的实际历史做法**写，不写通用 Android 教程：
#   · 信任关系靠无线调试的**配对码**（`adb pair`）建立。这台设备由容器经网络连接，
#     **不存在 USB 物理连接，因此不会出现「允许 USB 调试」对话框**；
#     也**不需要**往 /data/misc/adb/adb_keys 里追加公钥。
#     （这两条我在 09-30 凭通用知识写进过提示，10-01 被用户指出与本机事实不符，已删除。
#      历史上第一次建桥的实况是：`echo <6位码> | adb pair <ip>:<配对端口>` → `adb connect <ip>:<连接端口>`。）
#   · `adb root` 在这台设备上被拒绝（生产版本），root 只有 `su -c '<cmd>'` 一条路；
#     提示里不出现任何 root 管理器的名字（用户要求）。
#   · 本机通道 emulator-5554 与无线通道共用**同一份容器客户端密钥、同一个 adbd**：
#     无线配对成功后本机通道通常一并可用（历史上它长期 unauthorized，直到某次配对之后才变 device）。
#   · **配对端口与连接端口是两个不同的数字**，两处 IP 必须一致；
#     端口每次重新启用无线调试/每次开机都会变（历史：37827→45889→33869→43805→46213…），
#     所以连上之后要钉固定端口（见 fix_adb_port）。

ADBR_OK=0

adb_endpoints_from_conf() {
    local raw="${ADB_ENDPOINTS:-${DRM_CONF[ADB_ENDPOINTS]:-}}"
    [[ -n "$raw" ]] || return 0
    printf '%s\n' $raw
}

# 只有"真能跑通 getprop"的地址才算可用；光出现在 adb devices 里不算
tcp_ready_ep() {
    local ep
    while IFS= read -r ep; do
        [[ -n "$ep" ]] || continue
        if timeout 10 adb -s "$ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            printf '%s' "$ep"; return 0
        fi
    done < <(adb_endpoints_from_conf)
    return 1
}

explain_adb_purpose() {
    say "$(msg '为什么需要这条通道：接管与交还的每一步都要通过 adb 驱动 Android——' \
               'Why this channel is needed: every takeover/hand-back step drives Android over adb:')"
    say "  $(msg '停止 surfaceflinger 与 composer（屏幕才能交给 Linux 直接驱动）' \
                 'stopping surfaceflinger and composer so Linux can own the panel')"
    say "  $(msg '交还时恢复 system_suspend 等安卓服务（漏掉会被 watchdog 拖到自动重启）' \
                 'restoring system_suspend on hand-back, otherwise the watchdog reboots the device')"
    say "  $(msg '读取当前 WiFi 的 SSID 与口令（接管后容器才能自己连回同一个网络）' \
                 'reading the current WiFi SSID/PSK so the container reconnects on its own')"
    say "  $(msg '写背光、发唤醒键、收割内核日志（断网与花屏类问题只能靠内核日志定位）' \
                 'backlight, wake keyevent and kernel-log harvesting for post-mortem evidence')"
    say ""
}

guide_wireless_debug() {
    say "$(msg '请在平板上操作：设置 → 开发者选项 → 无线调试 = 开启。' \
               'On the tablet: Settings → Developer options → Wireless debugging = ON.')"
    say "$(msg '  这一步只能人工完成：容器没有 USB 物理连接，屏幕上不会出现任何 USB 授权对话框，' \
               '  This must be done by hand: the container has no USB link, so no USB consent dialog will ever appear;')"
    say "$(msg '  所有信任关系都在无线调试页上建立。该页给出两组数字，注意它们是**不同的端口**：' \
               '  all trust is established on that page, which shows two sets of numbers with **different ports**:')"
    say "  $(msg 'a) 设备条目里的「IP 地址 : 端口」—— 连接用' 'a) the device entry IP:port — used to CONNECT')"
    say "  $(msg 'b)「使用配对码配对设备」给出的 6 位码 + 配对端口 —— 配对用' \
                'b) "Pair device with pairing code" — a 6-digit code and the PAIRING port')"
    say ""
}

# pair_then_connect —— 成功时把可用地址写到 stdout（其余输出全部走 stderr）
pair_then_connect() {
    local pair_addr code conn
    say "$(msg '1) 平板上点「使用配对码配对设备」，记下 6 位码和配对端口。' \
               '1) Tap "Pair device with pairing code"; note the 6-digit code and the pairing port.')" >&2
    pair_addr=$(ask "$(msg '   配对地址（形如 172.16.30.245:43341，回车跳过）' '   Pairing address (e.g. 172.16.30.245:43341; Enter skips)')" "")
    [[ -n "$pair_addr" ]] || { say "$(msg '   已跳过配对。' '   Pairing skipped.')" >&2; return 1; }
    code=$(ask "$(msg '   6 位配对码' '   6-digit pairing code')" "")
    if [[ ! "$code" =~ ^[0-9]{6}$ ]]; then
        say "$(msg '   配对码需要 6 位数字，已跳过。' '   The pairing code needs 6 digits; skipped.')" >&2
        return 1
    fi
    info "$(msg "   正在配对 $pair_addr" 'Pairing '"$pair_addr")" >&2
    local pair_out pair_rc
    pair_out=$(printf '%s\n' "$code" | timeout 45 adb pair "$pair_addr" 2>&1); pair_rc=$?
    printf '%s\n' "$pair_out" | sed 's/^/     /' >&2
    # 判据必须是"退出码 + 成功短语"两个一起看：只 grep "success" 会假阳性——
    # 失败原文结尾就带着 "): Success"（10-01 实测：protocol fault 那条错误里就有），
    # 而成功原文是 "Successfully paired to ..."。
    if (( pair_rc != 0 )) || [[ "$pair_out" != *"Successfully paired"* ]]; then
        say "$(msg '   配对未成功。本机最常见的两个原因：把连接端口当成配对端口填了；两处 IP 写得不一致。' \
                   '   Pairing failed. Two common causes on this device: the connect port was entered as the pairing port; the two IPs differ.')" >&2
        say "$(msg '   另外配对码有效期很短，超时请在平板上重新生成再试。' \
                   '   Codes expire quickly; generate a new one on the tablet and retry.')" >&2
        return 1
    fi
    say "" >&2
    say "$(msg '2) 用设备条目里的「IP 地址 : 端口」连接（端口与配对端口不同）。' \
               '2) Connect using the device entry IP:port (not the pairing port).')" >&2
    conn=$(ask "$(msg '   连接地址（形如 172.16.30.245:37827）' '   Connection address')" "")
    if [[ ! "$conn" =~ ^[0-9A-Za-z._-]+:[0-9]+$ ]]; then
        say "$(msg '   地址格式不符（应为 ip:端口），已跳过。' '   Bad address format (expected ip:port); skipped.')" >&2
        return 1
    fi
    info "$(msg "   正在 adb connect $conn" 'adb connect '"$conn")" >&2
    timeout 20 adb connect "$conn" >/dev/null 2>&1 || true
    if timeout 10 adb -s "$conn" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
        printf '%s' "$conn"
        return 0
    fi
    # 配对后本机通道常会立刻可用（共用同一份密钥与同一个 adbd），这里复检一次
    probe_adb
    if [[ "$DRM_ADB_STATUS" == "device" ]]; then
        printf ''
        return 0
    fi
    say "$(msg "   已连接但命令仍被拒绝（$conn）：这次配对没有被设备接受，请重新生成配对码再做一次。" \
               "   Connected but commands are refused at $conn: the pairing was not accepted; generate a new code and redo it.")" >&2
    return 1
}

guide_shell_root() {
    say ""
    say "$(msg '3) 让 adb shell 具备 root（接管需要以 su -c 形式执行命令）。先在容器里验证：' \
               '3) Give adb shell root (takeover needs su -c). Verify from the container:')"
    say "    adb -s ${1:-$DRM_ADB_DEV} shell su -c id"
    say "$(msg '  返回 uid=0(root) 即已就绪；若被拒绝，请在平板上同意随即弹出的 root 授权请求后重试。' \
               '  uid=0(root) means ready; if denied, approve the root request shown on the tablet and retry.')"
    say "$(msg '  说明：这台设备上 adb root 不可用（生产版本会直接拒绝），只有 su -c 这一条路。' \
               '  Note: adb root is refused on this device (production build); su -c is the only path.')"
}

fix_adb_port() {
    local ep="${1:-$DRM_ADB_DEV}"
    local ip="${ep%:*}"
    say ""
    say "$(msg '4) 钉固定端口，做成长期可用的桥（无线调试的连接端口每次重新启用/每次开机都会变）：' \
               '4) Pin a fixed port so the bridge survives reconnects (the wireless port changes on every enable/boot):')"
    say "    adb -s $ep shell su -c 'setprop persist.adb.tcp.port 5555'"
    say "    adb -s $ep shell su -c 'setprop service.adb.tcp.port 5555'"
    say "    adb -s $ep shell su -c 'stop adbd'"
    say "    adb -s $ep shell su -c 'start adbd'"
    say "    adb connect $ip:5555"
    say ""
    warn "$(msg '  两点副作用要知道：stop adbd 会立刻断开当前这条无线连接；' \
                '  Two side effects: stop adbd drops the current connection immediately;')"
    warn "$(msg '  这台设备不保证认 persist 属性——若 5555 连不上说明仍走随机端口，' \
                '  this device may not honour the persist property; if 5555 will not connect it still uses random ports,')"
    warn "$(msg '  那时每次从无线调试页读新地址，并更新到 ADB_ENDPOINTS。' \
                '  then read the fresh address from the page each time and update ADB_ENDPOINTS.')"
    say ""
    say "$(msg '  钉成功后记进配置，以后不必再问：' '  Record it so it never has to be asked again:')"
    say "    sudo tee -a /etc/drm-takeover.conf <<< 'ADB_ENDPOINTS=\"$ip:5555\"'"
}

# establish_adb_bridge <interactive:0|1>
establish_adb_bridge() {
    local interactive="${1:-1}" ep
    probe_adb
    if [[ "$DRM_ADB_STATUS" == "device" ]]; then
        ok "$(msg "Android 调试通道已就绪：$DRM_ADB_DEV" 'Android debug channel ready: '"$DRM_ADB_DEV")"
        ADBR_OK=1; return 0
    fi
    if ! command -v adb >/dev/null 2>&1; then
        fail "$(msg '未安装 adb：接管与交还均需通过它驱动 Android。' \
               'adb is not installed; takeover and hand-back drive Android through it')"
        say "  $(msg '执行：sudo apt install -y --no-install-recommends adb' \
                    'Run: sudo apt install -y --no-install-recommends adb')"
        ADBR_OK=0; return 1
    fi
    # 已配置过地址时先直接试（非交互也走这一步）
    if ep=$(tcp_ready_ep); then
        timeout 20 adb connect "$ep" >/dev/null 2>&1 || true
        if timeout 10 adb -s "$ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            DRM_ADB_DEV="$ep"; DRM_ADB_STATUS="device"; ADBR_OK=1
            ok "$(msg "已用配置的地址建立通道：$ep" 'Channel established from the configured address: '"$ep")"
            return 0
        fi
    fi
    if [[ "$DRM_ADB_STATUS" == "unauthorized" ]]; then
        warn "$(msg "本机通道尚未被信任（$DRM_ADB_DEV：unauthorized）" \
               'Local channel is not trusted ('"$DRM_ADB_DEV"': unauthorized)')"
        say "$(msg '  这台设备不会出现 USB 授权对话框；信任要靠无线调试的配对码建立。' \
               '  This device shows no USB consent dialog; trust comes from pairing over wireless debugging.')"
        say "$(msg '  配对成功后本机通道通常一并可用（两者共用同一份容器密钥与同一个 adbd）。' \
               '  Once paired the local channel usually works too (same client key, same adbd).')"
    else
        warn "$(msg '尚未建立任何 Android 调试通道。' 'No Android debug channel established yet.')"
    fi
    [[ "$interactive" == "1" ]] || { ADBR_OK=0; return 1; }

    explain_adb_purpose
    guide_wireless_debug
    if ep=$(pair_then_connect); then
        # ep 为空表示"无线地址没通、但本机通道已经通了"
        if [[ -n "$ep" ]]; then DRM_ADB_DEV="$ep"; fi
        DRM_ADB_STATUS="device"; ADBR_OK=1
        say ""
        ok "$(msg "通道已建立：$DRM_ADB_DEV" 'Channel established: '"$DRM_ADB_DEV")"
        guide_shell_root "$DRM_ADB_DEV"
        local go
        go=$(ask "$(msg '是否现在把端口钉到 5555，建立长期可用的桥？[y/N]' 'Pin to 5555 now for a durable bridge? [y/N]')" "n")
        [[ "${go,,}" == "y" ]] && fix_adb_port "$DRM_ADB_DEV"
        return 0
    fi
    ADBR_OK=0
    return 1
}

# 建桥失败时的补充说明：只讲这台机器真实存在的钥匙与端口，不再提 USB 对话框 / adb_keys
auth_remedy() {
    explain_adb_purpose
    guide_wireless_debug
    say "$(msg '补充：配对建立信任的是容器侧这份 adb 客户端密钥（sudo 与普通用户各一份，别搞混）：' \
               'Note: pairing trusts the container-side adb client key (root and the normal user each keep one):')"
    local f seen=" "
    for f in "$HOME/.android/adbkey.pub" "/home/${SUDO_USER:-nobody}/.android/adbkey.pub" "/root/.android/adbkey.pub"; do
        [[ -r "$f" ]] || continue
        case "$seen" in *" $f "*) continue ;; esac
        seen="$seen$f "
        say "  $f"
    done
    say "$(msg '  一次配对即对该密钥长期有效，除非设备侧删除了配对记录（撤销无线调试授权）。' \
               '  One pairing trusts that key until the device drops the pairing record (revoke wireless debugging).')"
    say ""
    say "$(msg '  多容器注意：adbd 只有一份，一个容器的配对/撤销会牵动其它容器的通道状态。' \
               '  Multi-container note: there is one adbd; pairing or revoking affects other containers too.')"
}
