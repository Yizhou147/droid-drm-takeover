#!/usr/bin/env bash
# adbroute.sh — 建立容器到 Android 的 adb 通道。
#
# 本机事实（不要用通用 Android 教程覆盖）：
#   · 信任靠无线调试配对建立。容器与 pad 之间没有 USB 连接，不会出现 USB 授权对话框，
#     也不需要往 /data/misc/adb/adb_keys 写东西。（这两条我 09-30 凭通用知识写进过提示，是错的。）
#   · 配对每台容器只做一次：它信任的是容器侧的 adb 客户端密钥。之后只需
#     `adb connect <IP>:<当前端口>`；端口每次重新启用无线调试/每次开机都会变，配对不用重做。
#     ⇒ 顺序必须是"先 connect，只有 unauthorized 才配对"。
#   · 配对弹窗与设备条目是同一个 IP、两个不同端口：前者用于 pair，后者用于 connect。
#   · `adb root` 被生产版本拒绝，root 只有 `su -c`。
#   · 本机通道 emulator-5554 与无线通道共用同一份密钥与同一个 adbd：配对成功后一并可用。
#   · 本机 adb 34.0.5：`adb help` 写的是 `pair HOST[:PORT] [PAIRING CODE]`（码作参数），
#     而历史上成功那次用的是 `echo <码> | adb pair <ip>:<port>`（码走 stdin，会话 7960f018 行 1819）。
#     ⇒ 两种都试，别赌一种。
#     ⚠ 10-01 新容器报 `protocol fault (couldn't read status message)` 时弹窗是开着的、码也对，
#       **原因尚未定位**（候选：端口取自设备条目而非弹窗、弹窗在两次输入之间被关闭、该容器 adb 不同）。
#       因此这里加了端口可达性探测与 adb 能力检查来取证据；没有证据前不要把任何一种解释写进用户提示。

ADBR_OK=0

adb_endpoints_from_conf() {
    local raw="${ADB_ENDPOINTS:-${DRM_CONF[ADB_ENDPOINTS]:-}}"
    [[ -n "$raw" ]] || return 0
    printf '%s\n' $raw
}

# 把"网络到不了"与"协议被拒"分开：两者处置不同
tcp_reachable() {
    local host="${1%:*}" port="${1##*:}"
    [[ "$host" =~ ^[0-9.]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
    timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

# 只有真能执行 getprop 的地址才算可用
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

# connect_only —— 已配对过的容器只需这一步。
# 返回 0=成功（stdout 回传地址）；1=地址不可用；2=设备未信任（需首次配对）
connect_only() {
    local ep
    ep=$(ask "$(msg '设备条目地址 (IP:端口)' 'Device-entry address (IP:port)')" "")
    [[ "$ep" =~ ^[0-9A-Za-z._-]+:[0-9]+$ ]] || return 1
    if ! tcp_reachable "$ep"; then
        say "$(msg "  $ep 不可达：无线调试未开启、IP 不对或端口已变更。" \
                   "  $ep unreachable: wireless debugging off, wrong IP, or the port changed.")" >&2
        return 1
    fi
    timeout 20 adb connect "$ep" >/dev/null 2>&1 || true
    if timeout 10 adb -s "$ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
        printf '%s' "$ep"; return 0
    fi
    probe_adb
    [[ "$DRM_ADB_STATUS" == "unauthorized" ]] && return 2
    say "$(msg "  $ep 已连接但拒绝命令：请重新读取端口。" \
               "  $ep connected but refuses commands: re-read the port.")" >&2
    return 1
}

# pair_now <配对地址> <6位码> —— 码作参数与码走 stdin 两种都试
pair_now() {
    local addr="$1" code="$2" out out2
    if ! tcp_reachable "$addr"; then
        say "$(msg "  配对端口 $addr 不可达：请用配对弹窗里显示的地址，并保持弹窗开启。" \
                   "  Pairing port $addr unreachable: use the address in the pairing dialog and keep it open.")" >&2
        return 1
    fi
    out=$(timeout 45 adb pair "$addr" "$code" 2>&1)
    [[ "$out" == *"Successfully paired"* ]] && return 0
    out2=$(printf '%s\n' "$code" | timeout 45 adb pair "$addr" 2>&1)
    [[ "$out2" == *"Successfully paired"* ]] && return 0
    # 成败判据：必须匹配 "Successfully paired" 整短语。
    # 只 grep success 会假阳性 —— 失败原文结尾自带 "): Success"。
    printf '%s\n%s\n' "$out" "$out2" | grep -v '^[[:space:]]*$' | sed 's/^/     /' >&2
    say "     adb $(adb version | head -1)" >&2
    return 1
}

# pair_then_connect —— 首次配对并连接，成功时 stdout 回传可用地址
pair_then_connect() {
    local paddr code caddr
    say "$(msg '  打开「使用配对码配对设备」并保持弹窗开启，输入弹窗里的地址与配对码。' \
               '  Open "Pair device with pairing code", keep it open, then enter its address and code.')" >&2
    paddr=$(ask "$(msg '  配对地址 (IP:端口)' '  Pairing address (IP:port)')" "") >&2
    [[ -n "$paddr" ]] || return 1
    code=$(ask "$(msg '  配对码' '  Pairing code')" "") >&2
    if [[ ! "$code" =~ ^[0-9]{6}$ ]]; then
        say "$(msg "  配对码为 6 位数字。" "  The pairing code is 6 digits.")" >&2
        return 1
    fi
    if ! pair_now "$paddr" "$code"; then
        say "$(msg "  配对失败。按序核对：① 弹窗是否仍开启；② 端口是否取自弹窗而非设备条目；③ 码是否为当前显示的那组。" \
                   "  Pairing failed. Check in order: dialog still open; port taken from the dialog not the device entry; code is the one currently shown.")" >&2
        return 1
    fi
    say "  $(msg '配对成功。' 'Paired.')" >&2
    caddr=$(ask "$(msg '  设备条目地址 (IP:端口)' '  Device-entry address (IP:port)')" "") >&2
    [[ "$caddr" =~ ^[0-9A-Za-z._-]+:[0-9]+$ ]] || return 1
    timeout 20 adb connect "$caddr" >/dev/null 2>&1 || true
    if timeout 10 adb -s "$caddr" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
        printf '%s' "$caddr"; return 0
    fi
    probe_adb
    [[ "$DRM_ADB_STATUS" == "device" ]] && { printf ''; return 0; }
    say "$(msg "  配对成功但 $caddr 不可用：确认端口取自设备条目。" \
               "  Paired but $caddr unusable: confirm the port came from the device entry.")" >&2
    return 1
}

guide_shell_root() {
    say ""
    say "$(msg '接管需要 adb shell 具备 root（su -c）。验证：' \
               'Takeover needs root on adb shell (su -c). Verify:')"
    say "    adb -s ${1:-$DRM_ADB_DEV} shell su -c id"
    say "$(msg '  返回 uid=0(root) 即就绪；被拒绝则在平板上同意后重试。本机 adb root 不可用。' \
               '  uid=0(root) means ready; if denied, approve the request on the tablet and retry. adb root is unavailable here.')"
}

fix_adb_port() {
    local ep="${1:-$DRM_ADB_DEV}" ip="${1%:*}"
    say ""
    say "$(msg '可选：钉固定端口，之后不必再读端口（需设备侧 root）：' \
               'Optional: pin a fixed port so it never has to be re-read (needs device root):')"
    say "    adb -s $ep shell su -c 'setprop persist.adb.tcp.port 5555; setprop service.adb.tcp.port 5555; stop adbd; start adbd'"
    say "    adb connect $ip:5555"
    warn "$(msg '  stop adbd 会立刻断开当前连接；本机不保证认 persist，5555 连不上说明端口仍是随机的。' \
                '  stop adbd drops the current connection; the persist property may not be honoured, in which case ports stay random.')"
    say "    sudo tee -a /etc/drm-takeover.conf <<< 'ADB_ENDPOINTS=\"$ip:5555\"'"
}

# establish_adb_bridge <interactive:0|1>
establish_adb_bridge() {
    local interactive="${1:-1}" ep rc
    probe_adb
    if [[ "$DRM_ADB_STATUS" == "device" ]]; then
        ok "$(msg "adb 通道就绪：$DRM_ADB_DEV" 'adb channel ready: '"$DRM_ADB_DEV")"
        ADBR_OK=1; return 0
    fi
    if ! command -v adb >/dev/null 2>&1; then
        fail "$(msg '未安装 adb（接管与交还都要靠它驱动 Android）：' \
               'adb is not installed (takeover and hand-back drive Android through it):')"
        say "  sudo apt install -y --no-install-recommends adb"
        ADBR_OK=0; return 1
    fi
    if ! adb help 2>&1 | grep -qE '^[[:space:]]*pair '; then
        fail "$(msg '本机 adb 不支持无线调试配对（无 pair 子命令），需 platform-tools 31 以上。当前：' \
               'This adb cannot pair (no pair subcommand); platform-tools 31+ required. Current:')"
        say "  $(adb version | head -1)"
        ADBR_OK=0; return 1
    fi
    if ep=$(tcp_ready_ep); then
        timeout 20 adb connect "$ep" >/dev/null 2>&1 || true
        if timeout 10 adb -s "$ep" shell getprop ro.build.version.sdk >/dev/null 2>&1; then
            DRM_ADB_DEV="$ep"; DRM_ADB_STATUS="device"; ADBR_OK=1
            ok "$(msg "adb 通道就绪：$ep" 'adb channel ready: '"$ep")"
            return 0
        fi
    fi
    [[ "$interactive" == "1" ]] || { ADBR_OK=0; return 1; }

    say ""
    say "$(msg '接管需要平板的 adb 通道。本容器已配对过则只需连接，否则做一次配对（仅一次）。' \
               'Takeover needs the tablet adb channel. If this container has paired, connect only; otherwise pair once.')"
    ep=$(connect_only); rc=$?
    if (( rc == 0 )); then
        DRM_ADB_DEV="$ep"; DRM_ADB_STATUS="device"; ADBR_OK=1
        ok "$(msg "adb 通道已恢复：$ep" 'adb channel restored: '"$ep")"
        guide_shell_root "$ep"
        return 0
    fi
    (( rc == 2 )) && say "$(msg '本容器尚未配对，现在做一次配对。' 'This container has not paired; pairing now.')"
    if ep=$(pair_then_connect); then
        [[ -n "$ep" ]] && DRM_ADB_DEV="$ep"
        DRM_ADB_STATUS="device"; ADBR_OK=1
        ok "$(msg "adb 通道已建立：$DRM_ADB_DEV" 'adb channel established: '"$DRM_ADB_DEV")"
        say "$(msg '  以后只需 adb connect；端口变了换端口，不必重新配对。' \
                   '  Afterwards adb connect is enough; change the port when it changes, no re-pairing.')"
        guide_shell_root "$DRM_ADB_DEV"
        local go
        go=$(ask "$(msg '钉固定端口 5555？[y/N]' 'Pin to port 5555? [y/N]')" "n")
        [[ "${go,,}" == "y" ]] && fix_adb_port "$DRM_ADB_DEV"
        return 0
    fi
    ADBR_OK=0
    return 1
}

auth_remedy() {
    say "$(msg '配对信任的是本容器的 adb 客户端密钥（每台容器一次）。密钥位置：' \
               'Pairing trusts this container adb client key, once per container. Key locations:')"
    local f seen=" "
    for f in "$HOME/.android/adbkey.pub" "/home/${SUDO_USER:-nobody}/.android/adbkey.pub" "/root/.android/adbkey.pub"; do
        [[ -r "$f" ]] || continue
        case "$seen" in *" $f "*) continue ;; esac
        seen="$seen$f "; say "  $f"
    done
    say "$(msg '  在平板上撤销无线调试授权会使该密钥失效，需重新配对。' \
               '  Revoking wireless debugging authorization on the tablet invalidates it and requires re-pairing.')"
}
