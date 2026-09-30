#!/usr/bin/env bash
# precheck.sh — 安装前闸门。缺任一项就明确报错并给出**单行**补救命令，绝不"先往下跑再说"。
# 为什么这么硬：现有脚本默认"KernelSU 已装、adb 通道已开、容器能 mknod、依赖都在"，
# 全新用户恰恰缺的就是这些；脚本在半路失败 = 安卓被 stop 后起不来 = 只能长按强启。
#
# 发行版/桌面接口（用户要求：现在只支持 Ubuntu 26.04 + KDE，但接口留着）：
#   detect_distro() / detect_desktop() 各返回一个 id，supported_target() 是唯一闸门点。
#   以后适配新发行版＝往 TARGETS 数组加一行 + 补 apt/dnf 两套包名映射，别的地方不用改。

readonly -a TARGETS=("ubuntu2604|kde")

# 必装依赖：命令 → 包名（09-30 逐条在本机 dpkg -S 验证过，见工作总结 §12.3c）。
# 用关联数组而不是两个平行数组：命令名与包名大多不同名（nmcli→network-manager、
# kwriteconfig6→libkf6config-bin），平行数组一旦错位，缺的包就装到别的名字上去。
declare -A DEP_PACKAGE_MAP=(
    [adb]=adb [nmcli]=network-manager [wpa_supplicant]=wpasupplicant
    [wpa_passphrase]=wpasupplicant [dhcpcd]=dhcpcd-base [rfkill]=rfkill
    [udevadm]=udev [runuser]=util-linux [fuser]=psmisc
    [kwin_wayland]=kwin-wayland [Xwayland]=xwayland [plasmashell]=plasma-workspace
    [startplasma-wayland]=plasma-workspace [konsole]=konsole
    [upower]=upower [kwriteconfig6]=libkf6config-bin [busctl]=systemd
    [dbus-send]=dbus [fcitx5]=fcitx5 [plasma-keyboard]=plasma-keyboard
    [onboard]=onboard [xdotool]=xdotool [pactl]=pulseaudio-utils
    [wpctl]=wireplumber [bluetoothctl]=bluez [hciconfig]=bluez
    [wayland-info]=wayland-utils [es2gears_wayland]=mesa-utils
    [jq]=jq [python3]=python3-minimal [curl]=curl [sha256sum]=coreutils
    [pipewire]=pipewire
)
# 命令名不可直接 which 的条目：靠包名判定
declare -A DEP_PACKAGE_ONLY=(
    [org_kde_powerdevil]=powerdevil [pipewire]=pipewire
)

detect_distro() {
    local id="" ver=""
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        id="${ID:-}"; ver="${VERSION_ID:-}"
    fi
    printf '%s|%s' "$id" "$ver"
}

detect_desktop() {
    # 只看"有没有 KDE 的那套东西"，不信任 $XDG_CURRENT_DESKTOP（容器里从串口/终端进来时它是空的）
    if command -v plasmashell >/dev/null 2>&1; then printf 'kde'
    elif command -v gnome-shell >/dev/null 2>&1; then printf 'gnome'
    else printf 'none'; fi
}

supported_target() {
    local distro desktop id ver key
    distro="$(detect_distro)"; desktop="$(detect_desktop)"
    id="${distro%%|*}"; ver="${distro##*|}"
    case "$id:$ver" in
        ubuntu:26.04) key="ubuntu2604|$desktop" ;;
        *)            key="other|$desktop" ;;
    esac
    [[ " ${TARGETS[*]} " == *" $key "* ]]
}

# 安卓侧 root：接管要 setprop ctl.stop surfaceflinger，没 KernelSU 授权一切免谈
check_android_root() {
    local out=""
    [[ -n "$DRM_DEV" ]] || return 1
    out=$(timeout 10 adb -s "$DRM_DEV" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r')
    [[ "$out" == "0" ]]
}

# adb 桥：容器里要有 adb，且本机通道必须已经列出来。
# 全新用户最常卡在这两步（DroidSpaces 的 adb 通道没开 / KernelSU 没给 adb shell 授权），
# 所以这里把判据拆开报，不要笼统一句"adb 不可用"。
check_adb_bridge() {
    local rc=0
    if ! command -v adb >/dev/null 2>&1; then
        fail "$(msg '容器里没有 adb（接管与交还都要用它驱动安卓）' 'adb is missing in the container (needed to drive Android)')"
        say "$(msg '  补救：sudo apt install -y --no-install-recommends adb' '  Fix: sudo apt install -y --no-install-recommends adb')"
        rc=1
    else
        ok "$(msg '容器内 adb 就位' 'adb present in container')"
    fi
    if [[ -n "$DRM_DEV" ]]; then
        ok "$(msg "安卓通道可用：$DRM_DEV" 'Android channel ready: '"$DRM_DEV")"
    else
        fail "$(msg '看不到任何 adb 设备' 'No adb device visible')"
        say "$(msg '  请在 DroidSpaces 里开启本机 adb 通道，然后在 KernelSU 里给 adb shell 授权' \
               '  Enable the local adb channel in DroidSpaces, then authorize adb shell in KernelSU')"
        say "$(msg '  检查命令（单行）：adb devices' '  Check (single line): adb devices')"
        rc=1
    fi
    if check_android_root; then
        ok "$(msg '安卓侧 root 可用（KernelSU 已授权）' 'Android root available (KernelSU authorized)')"
    else
        fail "$(msg '安卓侧 su 不可用：接管要停 surfaceflinger/composer，必须有 root' \
               'Android su unavailable: takeover stops surfaceflinger/composer, root is mandatory')"
        say "$(msg '  请在 KernelSU 里为本机授予 root（第一次会弹授权窗），然后重跑本检查' \
               '  Grant root in KernelSU (a prompt appears on first use), then re-run this check')"
        rc=1
    fi
    return $rc
}

check_drm_nodes() {
    # 容器重启后 /dev 是合成的，card0 可能压根没建出来；这里只验"能不能建"，不实际建
    # （真正的 mknod 在 desk-takeover.sh 里，它每轮都重建）。/tmp 带 nodev，节点建那儿会 EACCES。
    local probe="/dev/.drm-tui-probe-$$"
    if [[ "$(id -u)" -eq 0 ]]; then
        if mknod "$probe" c 1 3 2>/dev/null; then
            rm -f "$probe"; ok "$(msg '可在 /dev 建节点（mknod 可用）' 'mknod into /dev works')"
        else
            fail "$(msg '/dev 不可 mknod：容器缺少设备写权限' 'cannot mknod in /dev: container lacks device write access')"
            return 1
        fi
    else
        info "$(msg '非 root，跳过 mknod 自检（接管脚本会自己建节点）' 'not root; skipping mknod self-test')"
    fi
    [[ -c /dev/dri/renderD128 || -e /dev/kgsl-3d0 ]] \
        && ok "$(msg 'GPU 节点可见（renderD128 / kgsl-3d0 至少一个）' 'GPU node visible')" \
        || warn "$(msg 'GPU 节点当前不可见——每轮接管会重建，但请留意 GPU-PERM 判据' 'GPU node not visible now; each round recreates it, watch GPU-PERM')"
    return 0
}

# 依赖检查：只报缺的，并把命令写成单行给用户
missing_packages() {
    local cmd pkg
    for cmd in "${!DEP_PACKAGE_MAP[@]}"; do
        pkg="${DEP_PACKAGE_MAP[$cmd]}"
        if [[ "$cmd" == "$pkg" || -n "${DEP_PACKAGE_ONLY[$cmd]:-}" ]]; then
            dpkg -l "$pkg" 2>/dev/null | awk '$2=="ii"{f=1} END{exit f?0:1}' && continue
        fi
        command -v "$cmd" >/dev/null 2>&1 && continue
        case "$cmd" in
            org_kde_powerdevil) [[ -x /usr/lib/aarch64-linux-gnu/libexec/org_kde_powerdevil ]] && continue ;;
        esac
        printf '%s\n' "$cmd"
    done | sort
}

install_debs_with_audit() {
    # 两条 apt 铁律（都踩过）：
    #   ① 一律 --no-install-recommends：Recommends 把 modemmanager 带进来并 enable，
    #      plasmashell 启动查它的 D-Bus 干等 25 秒（工作总结 §41）。
    #   ② 装完必须审计新增 enabled 单元（09-23「deb 自启单元暗雷三连」）。
    local before="$DRM_STATE_DIR/enabled-units.before" now unit
    mkdir -p "$DRM_STATE_DIR" 2>/dev/null
    systemctl list-unit-files --state=enabled 2>/dev/null | awk '{print $1}' >"$before" || true
    local -a pkgs=()
    mapfile -t pkgs < <(_packages_for_missing "$@")
    (( ${#pkgs[@]} )) || { say "$(msg '依赖已齐全' 'All dependencies present')"; return 0; }
    say "$(msg "将安装 ${#pkgs[@]} 个包：${pkgs[*]}" "Installing ${#pkgs[@]} packages: ${pkgs[*]}")"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" || return 1
    now="$DRM_STATE_DIR/enabled-units.after"
    systemctl list-unit-files --state=enabled 2>/dev/null | awk '{print $1}' >"$now"
    while IFS= read -r unit; do
        grep -qx -- "$unit" "$before" 2>/dev/null && continue
        [[ -z "$unit" || "$unit" == "UNIT FILE" ]] && continue
        warn "$(msg "apt 顺手 enable 了 $unit，正在撤掉自启" "apt auto-enabled $unit; disabling autostart")"
        systemctl disable --now "$unit" 2>/dev/null || true
    done < <(comm -13 <(sort -u "$before") <(sort -u "$now"))
    return 0
}

_packages_for_missing() {
    local cmd pkg seen=""
    for cmd in "$@"; do
        case " $seen " in *" $cmd "*) continue ;; esac
        seen="$seen $cmd"
        pkg="${DEP_PACKAGE_MAP[$cmd]:-}"
        [[ -n "$pkg" ]] && printf '%s\n' "$pkg"
    done
}

# 磁盘：rootfs.img 已经 75GB 量级，装之前提示一下剩余空间是应该的
check_disk_space() {
    local avail_kb
    avail_kb=$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')
    [[ -n "$avail_kb" ]] || return 0
    if (( avail_kb < 2 * 1024 * 1024 )); then
        warn "$(msg "根分区仅剩 $(( avail_kb / 1024 ))MB，接管与 deb 安装可能失败" \
               'Only '"$(( avail_kb / 1024 ))"'MB free on /; install may fail')"
    else
        ok "$(msg "磁盘可用 $(( avail_kb / 1024 / 1024 ))GB" 'Disk free: '"$(( avail_kb / 1024 / 1024 ))"'GB')"
    fi
    return 0
}

# 一条命令跑完全部预检，返回失败项个数（TUI 的预检页直接调它）
run_precheck() {
    local fails=0
    detect_android_identity
    if ! is_target_model; then
        fail "$(msg "机型不符：只支持小米平板 8 Pro（检测到 device=${DRM_PRODUCT:-未知} model=${DRM_MODEL:-未知}）" \
               'Unsupported device: only Xiaomi Pad 8 Pro (got device='"${DRM_PRODUCT:-?}"' model='"${DRM_MODEL:-?}"')')"
        fails=$((fails + 1))
    else
        ok "$(msg "机型：Xiaomi Pad 8 Pro（${DRM_MODEL:-piano}）" 'Device: Xiaomi Pad 8 Pro ('"$DRM_MODEL"')')"
    fi
    if supported_target; then
        ok "$(msg "发行版/桌面：$(detect_distro) / $(detect_desktop)" 'Target: '"$(detect_distro)/$(detect_desktop)")"
    else
        fail "$(msg "本安装器目前只支持 Ubuntu 26.04 + KDE（检测到 $(detect_distro) / $(detect_desktop)）" \
               'Only Ubuntu 26.04 + KDE is supported (detected '"$(detect_distro)/$(detect_desktop)"')')"
        fails=$((fails + 1))
    fi
    check_adb_bridge || fails=$((fails + 1))
    check_drm_nodes  || fails=$((fails + 1))
    check_disk_space
    local -a miss=()
    mapfile -t miss < <(missing_packages)
    if (( ${#miss[@]} )); then
        warn "$(msg "缺 ${#miss[@]} 项依赖：${miss[*]}" "${#miss[@]} dependencies missing: ${miss[*]}")"
    else
        ok "$(msg 'apt 依赖齐全' 'All apt dependencies present')"
    fi
    printf '%s\n' "$fails"
}
