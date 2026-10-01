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
    # 只有包名、没有对应命令的条目：按 dpkg 状态判定（键=值走同一条快速路径）。
    # 只有包名、没有对应命令的条目：按 dpkg 状态判定（键=值走同一条快速路径）。
    # bluez-obexd / libspa-0.2-bluetooth 缺了，接管轮里蓝牙配对与 A2DP 音频不可用；
    # bluez 也按包名判，不借助 command -v（命令在不在与桥能不能跑不是一回事）。
    [bluez-obexd]=bluez-obexd [libspa-0.2-bluetooth]=libspa-0.2-bluetooth
    [bluez]=bluez
    # bluedevil：系统设置里的蓝牙页 + 托盘图标都来自它。Ubuntu + Plasma 默认不装，
    # 缺了会让人误判"桥没通"（工作总结 §470 实测坑，10-01 双容器包比对确认新容器没有它）。
    [bluedevil]=bluedevil
    [plasma-nm]=plasma-nm [mesa-utils]=mesa-utils
    [xdotool]=xdotool [zenity]=zenity
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

# adb 桥：容器里要有 adb，且通道必须已授权。
# 未装 adb / 通道未建立 / 通道未授权这三种情况症状相同而处置不同，必须分开报，
# 不能笼统一句"adb 不可用"（10-01 新容器实测：unauthorized 被说成"机型不符"，
# 把人带去查机型和装 adb，而真正该做的是走无线调试配对 —— 这台设备不会出现任何 USB 授权对话框）。
check_adb_bridge() {
    local rc=0
    if ! command -v adb >/dev/null 2>&1; then
        fail "$(msg '未安装 adb：接管与交还均需通过它驱动 Android' \
               'adb is not installed; takeover and hand-back both drive Android through it')"
        say "  $(msg '执行：sudo apt install -y --no-install-recommends adb' \
                   'Run: sudo apt install -y --no-install-recommends adb')"
        rc=1
    else
        ok "$(msg 'adb 已安装' 'adb is installed')"
    fi
    probe_adb
    case "$DRM_ADB_STATUS" in
        device)
            ok "$(msg "Android 调试通道已授权：$DRM_ADB_DEV" \
               'Android debug channel authorized: '"$DRM_ADB_DEV")"
            ;;
        unauthorized)
            fail "$(msg "设备未授权（$DRM_ADB_DEV：unauthorized）：adb 已发现设备，但 Android 拒绝执行命令" \
               'Device not authorized ('"$DRM_ADB_DEV"': unauthorized): adb sees the device, but Android refuses commands')"
            say "$(msg '  这台设备没有 USB 物理连接，不会出现 USB 授权对话框；信任要用无线调试配对建立：' \
               '  This device has no USB link, so no USB consent dialog appears; establish trust by pairing over wireless debugging:')"
            say "  $(msg '位置：设置 → 开发者选项 → 无线调试 →「使用配对码配对设备」' \
                        'Location: Settings → Developer options → Wireless debugging → \"Pair device with pairing code\"')"
            say "    adb pair <ip>:<配对端口>       # 按提示输入 6 位配对码"
            say "    adb connect <ip>:<连接端口>    # 同一个 IP、另一个端口（与配对端口不同），照设备条目填"
            say "  adb devices"
            rc=1
            ;;
        offline)
            fail "$(msg "设备状态异常（$DRM_ADB_DEV：offline / no permissions）" \
               'Device state abnormal ('"$DRM_ADB_DEV"': offline / no permissions)')"
            say "  adb kill-server"
            say "  adb devices"
            rc=1
            ;;
        none)
            fail "$(msg '未检测到任何 Android 设备：adb 可用，但本机调试通道尚未建立' \
               'No Android device detected: adb works, but the local debug channel is not established')"
            say "$(msg '  请在 DroidSpaces 中启用本机 adb 通道，然后执行：adb devices' \
               '  Enable the local adb channel in DroidSpaces, then run: adb devices')"
            say "  adb devices"
            rc=1
            ;;
        *)
            fail "$(msg 'adb 状态未知：adb devices 未能执行' 'adb state unknown: adb devices did not run')"
            rc=1
            ;;
    esac
    if [[ "$DRM_ADB_STATUS" == "device" ]]; then
        if check_android_root; then
            ok "$(msg 'Android 侧 root 可用（su -c 已授权）' 'Android root is available (su -c authorized)')"
        else
            fail "$(msg 'Android 侧 su 不可用：接管需要停止 surfaceflinger 与 composer，必须具备 root' \
               'Android su unavailable: takeover must stop surfaceflinger and composer, which requires root')"
            say "$(msg "  执行 adb -s $DRM_DEV shell su -c id，为它授予 root，然后重新运行本检查。" \
               "  Run adb -s $DRM_DEV shell su -c id, grant it root, then re-run this check.")"
            rc=1
        fi
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
    # 普通用户的 PATH 常常不含 /usr/sbin 与 /sbin，直接 command -v 会把已装的
    # rfkill / runuser / wpa_supplicant / dhcpcd 报成"缺失"（10-01 实测）。
    # 查找命令时显式补上这两段；判定仍只看可执行文件是否存在，不依赖当前 PATH。
    local search_path="$PATH:/usr/sbin:/sbin"
    for cmd in "${!DEP_PACKAGE_MAP[@]}"; do
        pkg="${DEP_PACKAGE_MAP[$cmd]}"
        if [[ "$cmd" == "$pkg" || -n "${DEP_PACKAGE_ONLY[$cmd]:-}" ]]; then
            # dpkg -l 的状态在**第 1 列**（"ii  包名  版本"），写成 $2=="ii" 会永远判成缺失
            dpkg -l "$pkg" 2>/dev/null | awk '/^ii /{f=1} END{exit f?0:1}' && continue
        fi
        PATH="$search_path" command -v "$cmd" >/dev/null 2>&1 && continue
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
    local before="$DRM_STATE_DIR/enabled-units.before" now unit audit=1
    mkdir -p "$DRM_STATE_DIR" 2>/dev/null
    # 基线写不下去就必须喊出来：这条审计是 modemmanager 那类"apt 顺手 enable 的自启单元"的唯一防线，
    # 静默跳过等于没装（10-01 非 root 试跑时它就是悄悄空转的）。
    if ! systemctl list-unit-files --state=enabled 2>/dev/null | awk '{print $1}' >"$before" 2>/dev/null; then
        audit=0
        warn "$(msg "无法记录自启单元基线（$DRM_STATE_DIR 不可写）：装完请手工核对 systemctl list-unit-files --state=enabled" \
                    "Cannot record the enabled-unit baseline ($DRM_STATE_DIR not writable): verify manually after install")"
    fi
    local -a pkgs=()
    mapfile -t pkgs < <(_packages_for_missing "$@" | sort -u)
    (( ${#pkgs[@]} )) || { say "$(msg '依赖已齐全' 'All dependencies present')"; return 0; }
    # 新容器的 apt 列表常常是空的：不先 update 就会 "Unable to locate package" /
    # "没有可安装候选"（10-01 实测：10 个包全部报找不到）。
    say "$(msg '刷新软件包索引：apt-get update' 'Refreshing package lists: apt-get update')"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || warn "$(msg 'apt-get update 未全部成功，继续尝试安装' 'apt-get update partially failed; continuing')"
    say "$(msg "将安装 ${#pkgs[@]} 个包：${pkgs[*]}" "Installing ${#pkgs[@]} packages: ${pkgs[*]}")"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}" || {
        # 失败时把"到底哪个包找不到"说清楚，不要只留一句"apt 安装失败"
        local missing="" q
        for q in "${pkgs[@]}"; do
            apt-cache show "$q" >/dev/null 2>&1 || missing="$missing $q"
        done
        [[ -n "$missing" ]] && fail "$(msg "这些包在当前源里找不到：$missing —— 检查 /etc/apt/sources.list 是否可用、是否需要同步镜像源" \
                                       'Not available from the configured sources:'"$missing")"
        return 1
    }
    now="$DRM_STATE_DIR/enabled-units.after"
    (( audit )) || return 0
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
    local cmd pkg seen=" "
    for cmd in "$@"; do
        pkg="${DEP_PACKAGE_MAP[$cmd]:-}"
        [[ -n "$pkg" ]] || continue
        # 按**包名**去重，不是按命令名：bluetoothctl 与 hciconfig 都是 bluez、
        # wpa_supplicant 与 wpa_passphrase 都是 wpasupplicant。
        # 原来按命令去重 ⇒ apt 参数里同一个包出现两遍（10-01 新容器实测）。
        case "$seen" in *" $pkg "*) continue ;; esac
        seen="$seen$pkg "
        printf '%s\n' "$pkg"
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
    # 预检是非交互的：只把已有通道/已配置端点试一遍，需要人工输入地址或授权时留给安装流程
    if command -v establish_adb_bridge >/dev/null 2>&1; then
        establish_adb_bridge 0 || true
    fi
    detect_android_identity
    is_target_model
    case "$?" in
        0) ok "$(msg "设备型号确认：Xiaomi Pad 8 Pro（${DRM_MODEL}）" 'Device verified: Xiaomi Pad 8 Pro ('"$DRM_MODEL"')')" ;;
        2) fail "$(msg '无法确认设备型号：ro.product.device 读取为空，通常是 Android 调试通道尚未就绪（见上一项 adb 结果）' \
              'Cannot determine the device model: ro.product.device is empty, normally because the Android debug channel is not ready')"
           fails=$((fails + 1)) ;;
        *) fail "$(msg "设备型号不匹配：检测到 ro.product.device=${DRM_PRODUCT}，本工具仅在 Xiaomi Pad 8 Pro（piano）上验证" \
              'Device mismatch: detected ro.product.device='"${DRM_PRODUCT}"'; verified on Xiaomi Pad 8 Pro (piano) only')"
           fails=$((fails + 1)) ;;
    esac
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
