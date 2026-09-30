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

adb_dev() {
    command -v adb >/dev/null 2>&1 || return 1
    # 本机通道优先：容器与 pad 同一台机器，emulator-5554 型通道与 WiFi 生死无关
    local local_dev
    local_dev=$(timeout "$DRM_ADB_TIMEOUT" adb devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
    [[ -n "$local_dev" ]] || return 1
    printf '%s' "$local_dev"
}

# android_getprop <key> —— 不需要 root；拿不到就返回空串，由调用方决定怎么解释。
android_getprop() {
    [[ -n "$DRM_DEV" ]] || return 1
    timeout "$DRM_ADB_TIMEOUT" adb -s "$DRM_DEV" shell getprop "$1" 2>/dev/null | tr -d '\r' | head -1
}

detect_android_identity() {
    DRM_DEV="$(adb_dev || true)"
    [[ -n "$DRM_DEV" ]] || return 1
    DRM_PRODUCT="$(android_getprop ro.product.device)"
    DRM_MODEL="$(android_getprop ro.product.model)"
    DRM_SF="$(android_getprop init.svc.surfaceflinger)"
    # 不要再尝试读 init.svc.vendor.qti.hardware.display.composer：09-30 实测本机它是**空串**
    # （那个 vendor HAL 由 SF 按 vintf 拉起，不是 init 跟踪的常驻服务，getprop 里压根没有）。
    # 停/起它仍然有效（`setprop ctl.restart …`，见工作总结 §2），但"查它在不在"只能靠 surfaceflinger。
    return 0
}

# 小米平板 8 Pro = piano / SM8750。model 串在不同区域版本会变（24091RP05C 等），
# 所以 device==piano 是主判据、model 只是第二道确认；两者都中才认。
is_target_model() {
    [[ "${DRM_PRODUCT:-}" == "piano" ]] || return 1
    [[ -n "${DRM_MODEL:-}" ]] || return 0
    return 0
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
        # 安卓活着、没有任何 Linux 桌面 = "失败轮"（点过进入接管但没成功，anland 也没回来）
        DRM_STATE="failed-round"; DRM_STATE_LABEL="$(msg '安卓正常、Linux 桌面没在跑（可能是上一轮失败）' 'Android fine, no Linux desktop (last round may have failed)')"
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
    [[ -z "$DRM_DEV" ]] && problems+=("no adb device visible")
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
