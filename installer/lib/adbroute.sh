#!/usr/bin/env bash
# adbroute.sh — 建立并修复"容器 → Android 的 adb 通道"。
#
# 为什么这是安装器的一步、而不是预检的一句报错：接管与交还**全部**动作都要经 adb 驱动安卓
# （setprop ctl.stop surfaceflinger、读 WifiConfigStore 拿 SSID/PSK、写背光…）。
# 通道没建立之前，"机型不符""读不到属性"这些报错都只是症状，不是原因。
#
# 本机历史事实（决定这里的尝试顺序，见工作总结 §0.2 / 5.31 / 6.1）：
#   · 早期只能走**无线 adb**：`adb connect 10.166.147.104:<端口>`，而**端口每次重连都会变**
#     （历史上出现过 36031→43439→44295→38851→36263→36933→33575），所以 drm-takeover.sh 里留了一份 EP 列表。
#   · 后来才出现**本机通道** emulator-5554（容器 → 本机 adbd 的 socket，不经 WiFi 射频，与 WiFi 生死无关）——
#     优先级因此是"本机通道在前、TCP 在后"。
#   · 两条通道都受 adbd 的 RSA 授权管：没授权时 `adb devices` 显示 unauthorized，
#     此时**任何 shell 命令都执行不了**（包括 we 需要的 getprop）。
#
# 授权怎么来（用户要做的事，本文件只负责把它说清楚并给可执行的下一步）：
#   A. 平板屏幕上弹出的「允许 USB 调试」对话框 —— 勾选"一律允许"后同意；对话框没出现就撤销授权重连。
#   B. 固定授权：把容器里的 adb 公钥追加进设备侧 /data/misc/adb/adb_keys（需要安卓本机 root，
#      例如 KernelSU 自带的终端）。这样容器重启/换 key 之前不用再点。
#   C. Android 11+ 的无线调试还要先 `adb pair <ip:配对端口> <6位码>`，再 connect 业务端口。

ADBR_OK=0

adb_endpoints_from_conf() {
    local raw="${ADB_ENDPOINTS:-${DRM_CONF[ADB_ENDPOINTS]:-}}"
    [[ -n "$raw" ]] || return 0
    printf '%s\n' $raw
}

# 已知历史端口（本机 EP 列表的公共部分）：只当"顺手试一下"，不作为判据
adb_endpoints_builtin() {
    local ip="${ADBR_PROBE_IP:-}"
    [[ -n "$ip" ]] || return 0
    local port
    for port in 5555 5556; do printf '%s:%s\n' "$ip" "$port"; done
}

# try_tcp_endpoints —— 逐个 adb connect，成功(能跑 getprop)即返回该串
try_tcp_endpoints() {
    local ep
    while IFS= read -r ep; do
        [[ -n "$ep" ]] || continue
        info "$(msg "尝试 adb connect $ep" 'Trying adb connect '"$ep")" 1>&2
        timeout 10 adb connect "$ep" >/dev/null 2>&1 || true
        if timeout 10 adb -s "$ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            printf '%s' "$ep"; return 0
        fi
    done < <(cat <(adb_endpoints_from_conf) <(adb_endpoints_builtin))
    return 1
}

# ask_for_endpoint —— 让用户给出 IP:端口（无线调试界面里那两个数）
ask_for_endpoint() {
    # 本函数用 stdout 回传地址（调用方 `ep=$(ask_for_endpoint)`），
    # 所以所有给人看的输出都必须显式 >&2。
    # ⚠ 不要用 `exec 1>&2` 图省事：函数里的 exec 改的是整个 shell 的 fd，
    #    返回之后 stdout 仍旧接着指向 stderr，后面所有正常输出都会"消失"。
    say "$(msg '请提供 Android 侧的 adb 地址。位置：设置 → 开发者选项 → 无线调试 →（已开启的设备）IP 地址与端口' \
               'Provide the Android adb address: Settings → Developer options → Wireless debugging → IP address & port')" >&2
    say "$(msg '注意：无线调试的端口每次重连都会变，形如 192.168.1.20:37511。' \
               'Note: the wireless-debugging port changes on every reconnect, e.g. 192.168.1.20:37511')" >&2
    local v
    v=$(ask "$(msg '地址（留空跳过）' 'Address (empty to skip)')" "")
    [[ -n "$v" ]] || return 1
    if [[ ! "$v" =~ ^[0-9A-Za-z._-]+:[0-9]+$ ]]; then
        say "$(msg '格式不符（应为 ip:端口），已跳过。' 'Bad format (expected ip:port), skipped.')" >&2
        return 1
    fi
    info "$(msg "正在 adb connect $v" 'adb connect '"$v")" >&2
    timeout 15 adb connect "$v" >/dev/null 2>&1 || true
    if timeout 10 adb -s "$v" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
        printf '%s' "$v"
        return 0
    fi
    say "$(msg "  adb connect $v 未能通过命令自检：多半仍是未授权，或端口已经变了。" \
               "  adb connect $v did not pass the command self-test: still unauthorized, or the port changed.")" >&2
    return 1
}

# explain_adb_purpose —— 用户第一次装的时候，先说清"这条通道是干什么的"，
# 否则后面所有授权/端口的问题都没法解释为什么要折腾这些。
explain_adb_purpose() {
    say "$(msg 'Android 调试通道（adb）的作用：接管与交还的每一步都要通过它驱动 Android——' \
               'What the adb channel is for: every takeover/hand-back step drives Android through adb:')"
    say "  $(msg '停止 surfaceflinger 与 composer（屏幕才能交给 Linux）、恢复 system_suspend（否则会被 watchdog 拖死）' \
                 'stopping surfaceflinger/composer so Linux can own the panel, and restoring system_suspend')"
    say "  $(msg '读取当前 WiFi 的 SSID 与密码（接管后容器才能自己连网）、写背光与唤醒屏幕' \
                 'reading the current WiFi SSID/PSK so the container can reconnect, plus backlight and wake-keyevent')"
    say "  $(msg '收割内核日志用于事后取证（断网/花屏类问题只能靠它定位）' \
                 'harvesting the kernel log for post-mortem evidence')"
    say ""
}

# fixed_port_hint —— 无线调试的端口每次重连都会变（历史上 36031→43439→44295→…），
# 每次都要重新查端口很痛苦。经典解法是把 adbd 钉在固定 TCP 端口上（需要设备侧 root 一次）。
fixed_port_hint() {
    say ""
    say "$(msg '固定端口（可选，但推荐）：无线调试的业务端口每次重连都会变，' \
               'Fixed port (optional, recommended): the wireless-debugging port changes on every reconnect,')"
    say "$(msg '  每次换网络/重启都要重新查一遍。用设备侧 root 把 adbd 钉在 5555 端口可以一劳永逸：' \
               '  so it must be looked up again after every reconnect. Pinning adbd to TCP 5555 once avoids that:')"
    say "  su -c 'setprop service.adb.tcp.port 5555'"
    say "  su -c 'stop adbd'"
    say "  su -c 'start adbd'"
    say "$(msg '之后容器侧地址固定为 <平板 IP>:5555，把它写进配置的 ADB_ENDPOINTS 即可：' \
               'The container address then stays at <tablet-ip>:5555; record it in ADB_ENDPOINTS:')"
    say "  sudo tee -a /etc/drm-takeover.conf <<< 'ADB_ENDPOINTS=\"192.168.1.20:5555\"'"
    say "$(msg '  注意：这钉住的是 TCP 端口，**不会**替你完成 RSA 授权；也仍需注意平板 IP 随网络变化。' \
               '  Note: this pins the TCP port only — it does not grant RSA authorization, and the tablet IP still changes with the network.')"
}

# auth_remedy —— unauthorized 时给完整可执行的下一步（两种授权方式）
auth_remedy() {
    local pubkeys=("$HOME/.android/adbkey.pub" "/root/.android/adbkey.pub")
    say ""
    say "$(msg '设备当前为 unauthorized：adb 已发现设备，但 Android 拒绝执行任何命令，' \
               'The device is unauthorized: adb sees it, but Android refuses every command,')"
    say "$(msg '  因此在授权完成前无法读取机型、也无法执行接管。' \
               '  so the model cannot be read and takeover cannot run until it is authorized.')"
    say ""
    say "$(msg '方式 A（最快）：看平板屏幕上的「允许 USB 调试」对话框，勾选"一律允许"后同意。' \
               'Option A (fastest): accept the "Allow USB debugging" dialog on the tablet and tick "Always allow".')"
    say "$(msg '  对话框没弹出时，在开发者选项里撤销全部 USB 调试授权，然后执行下面两条重连：' \
               '  If no dialog appears, revoke all USB debugging authorizations, then run these two lines:')"
    say "  adb kill-server"
    say "  adb devices"
    say ""
    say "$(msg '方式 B（持久，免每台容器重复点）：把容器里的 adb 公钥追加到设备侧 adb_keys。' \
               'Option B (persistent): append this container'\''s adb public key to the device-side adb_keys.')"
    say "$(msg '  1) 在容器里取出公钥内容（root 与非 root 各存一份，两个都要）：' \
               '  1) Print the container key(s) — root and the normal user each keep one:')"
    local f
    for f in "${pubkeys[@]}"; do
        [[ -r "$f" ]] && say "    cat $f"
    done
    say "$(msg '  2) 在平板上用一个已有 root 的终端（如 KernelSU）执行，把上一步的输出粘进去：' \
               '  2) On the tablet, from a terminal that already has root (e.g. KernelSU), paste that key in:')"
    say "    su -c 'cat >> /data/misc/adb/adb_keys'"
    say "    su -c 'chmod 600 /data/misc/adb/adb_keys'"
    say "    su -c 'setprop ctl.restart adbd'"
    say "$(msg '  3) 回到容器：adb kill-server 之后重新 adb devices，状态应变为 device。' \
               '  3) Back in the container: adb kill-server, then adb devices should report device.')"
    say ""
    say "$(msg '多容器提醒：adbd 只有一份，一个容器的授权/撤销会牵动其它容器的通道状态。' \
               'Multi-container note: there is one adbd; authorizing or revoking affects other containers too.')"
}

# pair_if_needed —— Android 11+ 无线调试要先配对
try_pair() {
    say ""
    say "$(msg '无线调试首次使用需要配对：在"无线调试"页点"使用配对码配对设备"，会给出 6 位码和一个配对端口。' \
               'Wireless debugging needs pairing: tap "Pair device with pairing code" for a 6-digit code and a pairing port.')"
    local addr code
    addr=$(ask "$(msg '配对地址 ip:port（留空跳过）' 'Pairing address ip:port (empty skips)')" "")
    [[ -n "$addr" ]] || return 1
    code=$(ask "$(msg '6 位配对码' '6-digit code')" "")
    [[ "$code" =~ ^[0-9]{6}$ ]] || { say "$(msg '配对码格式不符，已跳过。' 'Bad pairing code, skipped.')"; return 1; }
    info "$(msg "正在 adb pair $addr" 'adb pair '"$addr")"
    printf '%s\n' "$code" | timeout 30 adb pair "$addr" 2>&1 | tail -2
}

# establish_adb_bridge <interactive:0|1> —— 总入口
# 成功：置 DRM_ADB_STATUS=device、DRM_ADB_DEV=<serial>，并把 TCP 地址回写建议给用户。
establish_adb_bridge() {
    local interactive="${1:-1}"
    probe_adb
    if [[ "$DRM_ADB_STATUS" == "device" ]]; then
        ok "$(msg "Android 调试通道已就绪：$DRM_ADB_DEV" 'Android debug channel ready: '"$DRM_ADB_DEV")"
        ADBR_OK=1; return 0
    fi
    case "$DRM_ADB_STATUS" in
        unauthorized)
            warn "$(msg "本机通道未授权（$DRM_ADB_DEV）" 'Local channel unauthorized ('"$DRM_ADB_DEV"')')" ;;
        none)
            warn "$(msg "本机没有可用通道：adb 已装但未发现设备" 'No usable channel: adb installed but no device')" ;;
        *)
            warn "$(msg "本机通道状态：$DRM_ADB_STATUS" 'Channel state: '"$DRM_ADB_STATUS")" ;;
    esac

    # 依次：已配置的 TCP 端口 →（交互时）用户现场给的地址
    local ep
    explain_adb_purpose
    if ep=$(try_tcp_endpoints); then
        DRM_ADB_DEV="$ep"; DRM_ADB_STATUS="device"
        ok "$(msg "已通过无线 adb 建立通道：$ep" 'Channel established over wireless adb: '"$ep")" 1>&2
        fixed_port_hint 1>&2
        say "$(msg "  已用 TCP 通道：无线调试的端口每次重连都会变，建议把它写进配置的 ADB_ENDPOINTS，或改用本机通道。" \
                   '  Wireless ports change on reconnect: keep this value in ADB_ENDPOINTS, or prefer the local channel.')" 1>&2
        ADBR_OK=1; return 0
    fi
    if [[ "$interactive" == "1" ]]; then
        if ep=$(ask_for_endpoint); then
            DRM_ADB_DEV="$ep"; DRM_ADB_STATUS="device"
            ok "$(msg "已通过无线 adb 建立通道：$ep" 'Channel established over wireless adb: '"$ep")"
            ADBR_OK=1; return 0
        fi
        try_pair && {
            if ep=$(ask_for_endpoint); then
                DRM_ADB_DEV="$ep"; DRM_ADB_STATUS="device"; ADBR_OK=1
                ok "$(msg "配对后已建立通道：$ep" 'Channel established after pairing: '"$ep")"
                return 0
            fi
        }
    fi
    ADBR_OK=0
    return 1
}
