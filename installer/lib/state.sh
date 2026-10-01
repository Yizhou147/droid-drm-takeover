#!/usr/bin/env bash
# state.sh — "现在到底处于哪种状态"的唯一判定处。
# 为什么单独一个文件：主按钮的取反、失败轮的两项补救、以及"绝不允许在当前接管轮还活着时
# 再跑一轮 takeover"（09-24 实锤事故：中途重跑 desk-takeover，可用桌面被 kill_linux_stack 杀掉，
# 用户只能强启）全靠它。判错的代价是黑屏，所以这里宁可多问一句、不要多跑一轮。
#
# 判据纪律（工作总结 §7）：每条"OK/up"必须打到它声称的那个对象身上。
#   · pgrep -x kwinwrap 存在 ≠ plasmashell 起来了（历史上害黑屏白猜三轮）。
#   · 两套 kwin 是不同进程，必须按 cmdline 区分：
#       DRM 轮   = kwin_wayland --socket=taketest   （kwinwrap 交出来的 master）
#       anland 轮 = kwin_wayland --wayland-fd 7 --socket wayland-0
#   · 安卓侧 adb 调用一律限时（09-24 16:52 一次 wake_unlock 的 adb 永久阻塞，把交还钉死在半路）。

readonly DRM_ADB_TIMEOUT="${DRM_ADB_TIMEOUT:-8}"

# 结果变量（调用方读这些，不要自己 pgrep）
DRM_STATE=""            # drm | anland | android | failed-round | half-dead | unknown
DRM_STATE_LABEL=""
DRM_DEV=""              # adb 设备串（emulator-5554 优先）
DRM_MODEL=""            # ro.product.model
DRM_PRODUCT=""          # ro.product.device（piano = 小米平板 8 Pro 的代号）
DRM_SF=""               # init.svc.surfaceflinger —— 安卓显示栈是否在线的唯一可靠锚点
DRM_KWIN_ROLE="none"    # none | drm | anland | both
DRM_SENTINEL=0          # takeover.ok 是否存在
DRM_ROUND_PID=""        # 接管轮 kwin 的 pid

# adb 通道状态：none(没有设备) / unauthorized(有设备但未授权) / offline / device / no-adb
# 这四种必须分开报：**unauthorized 被说成"看不到设备"或"机型不符"会把人带去装 adb、
# 查机型，而真正要做的是**走无线调试配对**（这台设备没有 USB 物理连接，不会出现任何授权对话框；
# 10-01 新容器实测就是这么被误导的）。
DRM_ADB_STATUS="no-adb"
DRM_ADB_STATUS_LABEL=""

probe_adb() {
    DRM_ADB_STATUS="no-adb"; DRM_ADB_DEV=""
    command -v adb >/dev/null 2>&1 || return 0
    local out
    out=$(timeout "${DRM_ADB_TIMEOUT:-8}" adb devices 2>/dev/null | tail -n +2)
    # 本机通道优先：容器与 pad 同一台机器，emulator-5554 这类通道与 WiFi 生死无关
    DRM_ADB_DEV=$(printf '%s\n' "$out" | awk '$2=="device"{print $1; exit}')
    if [[ -n "$DRM_ADB_DEV" ]]; then
        DRM_ADB_STATUS="device"
    elif printf '%s\n' "$out" | grep -q 'unauthorized'; then
        DRM_ADB_STATUS="unauthorized"
        DRM_ADB_DEV=$(printf '%s\n' "$out" | awk '$2=="unauthorized"{print $1; exit}')
    elif printf '%s\n' "$out" | grep -qE 'offline|no permissions'; then
        DRM_ADB_STATUS="offline"
        DRM_ADB_DEV=$(printf '%s\n' "$out" | awk '$1!=""){print $1; exit}')
    else
        DRM_ADB_STATUS="none"
    fi
}

adb_dev() {
    [[ "$DRM_ADB_STATUS" == "device" ]] || probe_adb
    [[ "$DRM_ADB_STATUS" == "device" ]] || return 1
    printf '%s' "$DRM_ADB_DEV"
}

android_getprop() {
    [[ -n "$DRM_DEV" ]] || return 1
    timeout "$DRM_ADB_TIMEOUT" adb -s "$DRM_DEV" shell getprop "$1" 2>/dev/null | tr -d '\r' | head -1
}

detect_android_identity() {
    probe_adb
    DRM_DEV="$DRM_ADB_DEV"
    [[ "$DRM_ADB_STATUS" == "device" ]] || return 1
    DRM_PRODUCT="$(android_getprop ro.product.device)"
    DRM_MODEL="$(android_getprop ro.product.model)"
    DRM_SF="$(android_getprop init.svc.surfaceflinger)"
    # 不要再尝试读 init.svc.vendor.qti.hardware.display.composer：09-30 实测本机它是**空串**
    # （那个 vendor HAL 由 SF 按 vintf 拉起，不是 init 跟踪的常驻服务，getprop 里压根没有）。
    # 停/起它仍然有效（`setprop ctl.restart …`，见工作总结 §2），但"查它在不在"只能靠 surfaceflinger。
    [[ -n "$DRM_PRODUCT" ]] || return 1
    return 0
}

# 小米平板 8 Pro = piano / SM8750。model 串随区域版本变化（25091RP04C 等），
# 所以 device==piano 是主判据；读不到时返回 2（"未知"），与"确认不是"（返回 1）严格分开。
is_target_model() {
    [[ -n "${DRM_PRODUCT:-}" ]] || return 2
    [[ "$DRM_PRODUCT" == "piano" ]]
}

detect_kwin_role() {
    local drm_pids anland_pids
    # 按 cmdline 特征分：两套 kwin 的 socket 名不同，这是最可靠的区分点
    drm_pids=$(pgrep -f 'kwin_wayland.*--socket=taketest' 2>/dev/null | tr '\n' ' ')
    anland_pids=$(pgrep -f 'kwin_wayland.*--wayland-fd' 2>/dev/null | tr '\n' ' ')
    DRM_ROUND_PID="${drm_pids%% *}"
    if [[ -n "$drm_pids" && -n "$anland_pids" ]]; then DRM_KWIN_ROLE="both"
    elif [[ -n "$drm_pids" ]];   then DRM_KWIN_ROLE="drm"
    elif [[ -n "$anland_pids" ]]; then DRM_KWIN_ROLE="anland"
    else DRM_KWIN_ROLE="none"; fi
    [[ -f "${DRM_REPO_DIR:-/}/takeover.ok" ]] && DRM_SENTINEL=1 || DRM_SENTINEL=0
}

# detect_state —— 把上面这些拼成一个状态词。顺序要紧：先看安卓是否停着（那是最危险的一型）。
# ⚠ 调用方必须写 `detect_state >/dev/null` 再读 DRM_STATE/DRM_STATE_LABEL：
#    用 $(detect_state) 取返回值会在子 shell 里跑，全局变量全部丢失（09-30 冒烟测试就是这么踩的）。
detect_state() {
    detect_kwin_role
    local sf_stopped=0
    [[ "${DRM_SF:-}" == "stopped" || -z "${DRM_SF:-}" ]] && sf_stopped=1

    if [[ "$DRM_KWIN_ROLE" == "drm" || ( "$DRM_KWIN_ROLE" == "both" && $DRM_SENTINEL -eq 1 ) ]]; then
        DRM_STATE="drm"; DRM_STATE_LABEL="$(msg 'DRM 接管中（Linux 直驱屏幕）' 'DRM takeover active (Linux owns the panel)')"
    elif [[ $sf_stopped -eq 1 && "$DRM_KWIN_ROLE" == "none" ]]; then
        # 安卓框架停着、桌面又没起来 = 两头全黑的最坏形态（早期调试问题，现在脚本会自动回滚，
        # 但真撞上时用户唯一能做的就是跑一次完整交还）
        DRM_STATE="half-dead"; DRM_STATE_LABEL="$(msg '安卓已下线但桌面也没起来（需要交还）' 'Android is down and no desktop either (hand back required)')"
    elif [[ "$DRM_KWIN_ROLE" == "anland" ]]; then
        DRM_STATE="anland"; DRM_STATE_LABEL="$(msg 'anland 态（Linux 桌面显示在安卓里）' 'anland mode (Linux desktop shown inside Android)')"
    elif [[ $sf_stopped -eq 0 && "$DRM_KWIN_ROLE" == "none" ]]; then
        # "失败轮"必须有证据：真的跑过一轮（有接管日志）才算。
        # 全新容器从来没人起过桌面，判成"上一轮没成功"会让人以为是自己搞坏了（10-01 实测）。
        if [[ -s "${DRM_CONF[LOG_DIR]:-/dev/null}/desk-takeover.log" ]]; then
            DRM_STATE="failed-round"; DRM_STATE_LABEL="$(msg '安卓正常、Linux 桌面没在跑（上一轮未成功）' 'Android fine, no Linux desktop (last round did not succeed)')"
        else
            DRM_STATE="android"; DRM_STATE_LABEL="$(msg 'Android 正常，本容器还没有 Linux 桌面在运行' 'Android is up; no Linux desktop is running in this container yet')"
        fi
    else
        DRM_STATE="android"; DRM_STATE_LABEL="$(msg '纯安卓态（容器 Linux 未在显示）' 'Plain Android (container Linux not displaying)')"
    fi
    printf '%s' "$DRM_STATE"
}

# 给主菜单用的一句话状态行（含 pid，方便用户对着 ps 自查）
state_summary() {
    local s
    s="$(printf '%b%s%b' "$COLOR_BOLD" "$DRM_STATE_LABEL" "$COLOR_RESET")"
    [[ -n "$DRM_DEV" ]] && s="$s$(msg '  ·安卓通道 ' '  ·adb ' )$DRM_DEV"
    [[ -n "$DRM_ROUND_PID" ]] && s="$s$(msg '  ·桌面 pid ' '  ·desktop pid ' )$DRM_ROUND_PID"
    [[ "$DRM_SENTINEL" -eq 1 ]] && s="$s$(msg '  ·哨兵在' '  ·sentinel up')"
    printf '%s\n' "$s"
}

# 判据自证：TUI 显示的"DRM 接管中"必须和 kwinwrap/哨兵至少一项对得上，
# 历史上"以为在轮内其实早死了"造成过白猜（5.27 纪律）。
sanity_check_state() {
    local problems=()
    [[ "$DRM_STATE" == "drm" && -z "$DRM_ROUND_PID" ]] && problems+=("state=drm but no --socket=taketest kwin")
    [[ "$DRM_STATE" == "drm" && -z "${DRM_SF:-}" ]] && problems+=("state=drm but surfaceflinger prop unreadable (adb down?)")
    [[ -z "$DRM_DEV" ]] && problems+=("adb 通道不可用（状态：$DRM_ADB_STATUS）")
    if (( ${#problems[@]} )); then
        printf '%b%s%b\n' "$COLOR_YELLOW" \
            "$(msg '状态判定存在疑点：' 'State detection is shaky: ')${problems[*]}" "$COLOR_RESET"
        return 1
    fi
    return 0
}

# 一次调用把状态与标签都备好；主菜单每帧开头调它。
state_refresh() {
    detect_state >/dev/null
    printf '%s\n' "$DRM_STATE"
}
