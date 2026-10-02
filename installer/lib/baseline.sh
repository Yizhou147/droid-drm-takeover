#!/usr/bin/env bash
# baseline.sh — 把"良好容器里靠数周手工攒下来的持久状态"变成可重放的安装步骤。
#
# 为什么需要这个文件：10-01 全新容器实测"装完像出厂状态"。逐条取证（adb root + nsenter 对比两容器）
# 得到的结论是：**运行时该修的脚本都修了**（WiFi/蓝牙/音频/撕裂/热插拔判据全 OK），
# 缺的是**从来没被任何脚本写过的持久配置**，以及两处代码 bug。这里的每一项都注明证据来源。
#
# 规矩：
#   · 每一步都必须幂等（可重复执行），且**只写目标用户的家目录与 /etc 下的项目自有文件**。
#   · 写家目录一律用 DRM_HOME（安装器以 root 运行，$HOME 是 /root —— 这正是快捷方式跑错地方的原因）。
#   · 绝不 restart 真 udevd 单元（§5.31 实锤：那一轮 WiFi 炸 + 交还卡死）。drop-in 只写不重启。
#   · 改 kwinrc 一律用 kwriteconfig6：sed 只能改**已存在**的行，键缺失时静默不生效
#     （§VirtualKeyboardEnabled 就是这么在新容器上失效的）。

# 写单个 kwinrc 键（幂等；root 写完必须 chown 回桌面用户，否则 kwin/anland 都写不了自己的配置）
drm_kconfig_set() {
    local file="$1" group="$2" key="$3" value="$4"
    local dir; dir="$(dirname "$file")"
    mkdir -p "$dir" 2>/dev/null || true
    kwriteconfig6 --file "$file" --group "$group" --key "$key" "$value" 2>/dev/null || return 1
    chown "${DRM_CONF[DRM_USER]:-root}:" "$file" 2>/dev/null || true
    return 0
}

# 1) kwin 合成器基线（证据：良好容器 ~/.config/kwinrc 与新容器的键差集）
apply_kwin_baseline() {
    local rc="${DRM_CONF[DRM_HOME]}/.config/kwinrc"
    say "$(msg '写入 kwin 合成器基线' 'Applying kwin baseline')"
    # 虚拟键盘必须在这里落地：desk-takeover 只用 sed 改已存在的行，键缺失时它永远不生效
    drm_kconfig_set "$rc" Wayland VirtualKeyboardEnabled true
    # 只留功能项。缩放/动画/装饰这类是我这台开发机的个人设置，原先一并写进装机基线，
    # 等于替每个新用户改界面大小（10-01 用户就问了"你为什么要动我的缩放"）。
    # `[Xwayland] Scale=2` 已删；`Effect-overview BorderActivate`、wobbly 参数、
    # kdecoration2/Breeze 也一并删。要恢复成个人偏好请各自在系统设置里调，不由安装器代劳。
    #
    # 【10-02 推翻】`[Xwayland] Scale=2` 从"个人偏好"改判为**功能必需**：轮内 X11 应用的
    # 缩放只吃它（desk-takeover 的 XFTDPI 段按此现算 Xft.dpi=Scale×96 写进轮的 Xwayland）。
    # 全新容器没写它 ⇒ usb-manager 等 X11 应用按 96dpi 渲染、字体元素极小（drm2 实测）。
    # 与桌面 UI 缩放不同：本容器（drm）与良好容器（Ubuntu-Wayland）实测值都是 2。
    drm_kconfig_set "$rc" Xwayland Scale 2
    drm_kconfig_set "$rc" TouchEdges Bottom ShowDesktop
    ok "$(msg "  kwinrc 已写入：$rc" '  kwinrc written')"
}

# 2) 虚拟键盘布局与触摸板（证据：plasmakeyboardrc / kcminputrc 键差集）
apply_input_baseline() {
    local home="${DRM_CONF[DRM_HOME]}"
    say "$(msg '写入输入法与触摸设备基线' 'Applying input baseline')"
    local pkr="$home/.config/plasmakeyboardrc"
    mkdir -p "$home/.config" 2>/dev/null
    {
        printf '[General]\n'
        printf 'enabledLocales=en_US,zh_CN\n'
        printf 'keyboardNavigationEnabled=true\n'
    } >"$pkr" 2>/dev/null
    chown "${DRM_CONF[DRM_USER]}:" "$pkr" 2>/dev/null
    # 小米触摸屏：libinput 默认滚动方向在这块面板上是反的
    local kci="$home/.config/kcminputrc"
    drm_kconfig_set "$kci" "Libinput/device__dev__1__Xiaomi_Touch" NaturalScroll true
    ok "$(msg '  plasmakeyboardrc / kcminputrc 已写入' '  keyboard and pointer config written')"
}

# 3) 把仓库里的正源脚本装到 /usr/local/bin（证据：新容器缺 startanland-kde.sh，
#    而 desk-stop 交还时要靠它复活 anland；缺它=交还后没有任何 Linux 桌面）
install_runtime_scripts() {
    local repo="${DRM_CONF[REPO_DIR]}" f
    say "$(msg '安装运行期脚本到 /usr/local/bin' 'Installing runtime scripts')"
    # 名单只列仓库里真有的东西：`usb-passthrough.sh` 曾在这里挂着，但仓库从没带过它
    # （本机 /usr/local/bin 那份是 DroidSpaces 侧的通用 /dev/bus/usb 建节点脚本，与接管无关），
    # 结果每次装机都固定报"已安装 4/5"，把真缺的东西淹在噪声里。
    local -a want=(startanland-kde.sh power-state-sync.py vkb-show.sh storage-fix.sh)
    local installed=0
    for f in "${want[@]}"; do
        if [[ -f "$repo/scripts/$f" ]]; then
            install -m 0755 "$repo/scripts/$f" "/usr/local/bin/$f" 2>/dev/null && installed=$((installed + 1))
        fi
    done
    ok "$(msg "  已安装 $installed/${#want[@]} 个" "  Installed $installed/${#want[@]}")"
    (( installed > 0 ))
}

# 4) systemd 侧持久化（证据：良好容器有 zz-drm-force-udevd.conf 与一组 mask，新容器没有）
#    ⚠ 只写文件，**绝不 daemon-reload/restart udevd**（§5.31：那一轮 WiFi 炸 + 交还链卡死）
apply_systemd_baseline() {
    say "$(msg '写入 systemd 基线（不重启任何单元）' 'Writing systemd baseline (no unit restarts)')"
    local d=/etc/systemd/system/systemd-udevd.service.d
    mkdir -p "$d" 2>/dev/null || return 1
    # DroidSpaces 给 udevd 加了 ExecCondition(enable_hw_access)，条件不满足时 udevd 永久 skipped
    # ⇒ 容器 NM 拿不到 udev 设备对象，WiFi 永远"正在搜索"（§3.11 的根因）。这里把条件清空。
    cat >"$d/zz-drm-force-udevd.conf" <<'EOF'
# 由 drm-tui 安装器写入：清空 DroidSpaces 的 ExecCondition，保证容器内 udevd 正常启动。
# 只写文件、不 restart 单元（重启真 udevd 曾把接管轮 WiFi 打进不可用状态）。
[Unit]
ConditionPathExists=
ExecCondition=
EOF
    # 容器里这几个服务不能自启：接管轮由脚本以裸进程起 NM，apt 自启版会与安卓 netd 抢 wlan0（§41）
    local s
    for s in NetworkManager.service systemd-networkd.service ModemManager.service wpa_supplicant.service; do
        ln -sfn /dev/null "/etc/systemd/system/$s" 2>/dev/null || true
    done
    ok "$(msg '  udevd 强制启动 drop-in 与自启掩码已写入' '  udevd drop-in and autostart masks written')"
    return 0
}

# 5) 蓝牙/PipeWire 音频栈的缺失包（证据：新容器缺 bluez-obexd 与 libspa bluetooth 模块，
#    良好容器有；缺了它们 A2DP/配对在接管轮里不可用）
baseline_extra_packages() {
    printf '%s\n' bluez-obexd libspa-0.2-bluetooth plasma-nm mesa-utils
    # 【10-02】字体全家（与良好容器 dpkg 实测一致）：新容器默认只有 dejavu/liberation 等
    # 32 个族，usb-manager 等 Qt/X11 应用的中文字形与排版严重残缺。§12.23 曾裁定"不进
    # 依赖表"，drm2 实测（装最新安装器后 usb-manager 字体极小）推翻：属功能必需。
    printf '%s\n' fonts-noto fonts-noto-cjk fonts-noto-cjk-extra fonts-noto-core \
        fonts-noto-ui-core fonts-noto-color-emoji fonts-ubuntu fonts-droid-fallback fonts-liberation
}

# 6) 校验：把"体验是否已对齐"变成可判定的实测，而不是看日志措辞
verify_baseline() {
    local rc="${DRM_CONF[DRM_HOME]}/.config/kwinrc" problems=0
    kreadconfig6 --file "$rc" --group Wayland --key VirtualKeyboardEnabled 2>/dev/null | grep -qi true \
        || { warn "$(msg 'kwinrc 的 VirtualKeyboardEnabled 未生效' 'VirtualKeyboardEnabled not set')"; problems=$((problems + 1)); }
    [[ -f /usr/local/bin/startanland-kde.sh ]] \
        || { warn "$(msg '缺 /usr/local/bin/startanland-kde.sh：交还后不会有 anland 桌面' 'anland launcher missing')"; problems=$((problems + 1)); }
    [[ -f "${DRM_CONF[DRM_HOME]}/Desktop/进入DRM接管.desktop" ]] \
        || { warn "$(msg '桌面快捷方式不在目标用户家目录（多半被写进了 /root）' 'shortcuts not in the target user home')"; problems=$((problems + 1)); }
    local lib hits
    lib="$(ls /usr/lib/*/libkwin.so.6* 2>/dev/null | grep -v '\.so\.6$' | head -1)"
    hits=$(grep -ac 'PCKEYD_INPUT_SOCKET' "$lib" 2>/dev/null)   # 不用 strings：binutils 只在我这台开发机上有
    (( ${hits:-0} > 0 )) || { warn "$(msg '定制 kwin 未安装：X11 应用不会弹虚拟键盘' 'patched kwin missing')"; problems=$((problems + 1)); }
    (( problems == 0 )) && ok "$(msg '桌面基线校验全部通过' 'Baseline checks all passed')"
    return $problems
}

# 总入口
# XDG 应用菜单入口：Ubuntu 的 plasma-workspace 只发 plasma-applications.menu，
# 而 KService 默认读的是 applications.menu —— 没有这个软链接时，应用列表整个是空的，
# 表现为「开始菜单一片空白、任务栏图标点了没反应」，日志里每一条形如
# `org.kde.plasma.kicker: Entry is not valid "org.kde.dolphin.desktop"`（.desktop 明明在）。
# 这台开发机上是 09-22 手工 `ln -s` 出来的，从没进过任何脚本，也没写进工作总结，
# 所以全新容器一直缺（10-01 在 drm 容器实测到）。
apply_xdg_menu_baseline() {
    local src=/etc/xdg/menus/plasma-applications.menu dst=/etc/xdg/menus/applications.menu
    [[ -f "$src" ]] || { warn "$(msg '  没有 plasma-applications.menu，跳过应用菜单链接' '  plasma-applications.menu absent; skipping')"; return 0; }
    if [[ -e "$dst" || -L "$dst" ]]; then
        ok "$(msg '  应用菜单入口已在' '  XDG application menu already present')"
    else
        ln -s "$src" "$dst" 2>/dev/null && ok "$(msg '  已建 /etc/xdg/menus/applications.menu → plasma-applications.menu' '  Linked applications.menu')" \
            || fail "$(msg '  建链接失败（需要 root）' '  Cannot create the link (needs root)')"
    fi
}

# 菜单/桌面文件一变，KService 缓存必须重建：缓存是**按用户**的，所以要用桌面用户身份跑，
# 且要 --delay 否则与 kded 里那份重复；重建失败只影响应用列表，不拦安装。
rebuild_ksycoca() {
    local user="${DRM_CONF[DRM_USER]:-}" exe
    [[ -n "$user" && "$user" != "root" ]] || return 0
    exe=$(command -v kbuildsycoca6 || command -v kbuildsycoca5 || true)
    [[ -n "$exe" ]] || { warn "$(msg '  没找到 kbuildsycoca6，应用菜单可能要等下次登录才出来' '  kbuildsycoca6 missing')"; return 0; }
    local uid; uid=$(id -u "$user" 2>/dev/null || echo 1000)
    runuser -u "$user" -- env -u DISPLAY XDG_RUNTIME_DIR="/run/user/$uid" "$exe" --noincremental >/dev/null 2>&1 \
        && ok "$(msg '  KService 缓存已重建' '  KService cache rebuilt')" \
        || warn "$(msg '  KService 缓存重建失败（应用列表可能要重登一次才齐）' '  KService cache rebuild failed')"
}

apply_desktop_baseline() {
    head2 "$(msg '写入桌面基线（把良好容器的持久状态变成可重放步骤）' 'Apply desktop baseline')"
    apply_kwin_baseline
    apply_input_baseline
    apply_xdg_menu_baseline
    install_runtime_scripts
    apply_systemd_baseline
    verify_baseline
    rebuild_ksycoca
}


# ---------------------------------------------------------------- 安卓侧桥产物 ----
# 为什么必须装：音频桥与蓝牙桥的设备侧二进制/模板过去**只存在于开发机的 /data/local/tmp**
# （我早期手动 push 的），两个容器共用同一份所以新容器"碰巧能用"，换一台设备就是空的：
# 表现是接管轮里没声音、蓝牙鼠标连上不动。halsink.sh 自己会检查并 exit 3。
# 现在由各自的仓库发 release 资产，安装器负责取包 + push + 复检。

BRIDGE_DEPLOY_FAILED=""

# drm_adb_target —— 设备侧命令必须显式选地址：这台机器同时挂着本机通道 emulator-5554 与无线通道，
# 裸 `adb shell` 会直接报 "more than one device/emulator"（第 10 步整步空转）。
drm_adb_target() {
    local t="${DRM_ADB_DEV:-}"
    [[ -n "$t" ]] || t="${ADB_TARGET:-}"
    if [[ -z "$t" ]]; then
        t=$(timeout 12 adb devices 2>/dev/null | awk '$2=="device"{print $1; exit}')
    fi
    [[ -n "$t" ]] || return 1
    printf '%s' "$t"
}

# deploy_android_bridges —— 成功返回 0；失败时把失败的组件名留在 BRIDGE_DEPLOY_FAILED
deploy_android_bridges() {
    local lock="$COMPONENTS_LOCK" key
    detect_json_parser || { warn "$(msg '需要 jq 或 python3 才能读组件清单' 'jq or python3 required')"; return 1; }
    [[ -r "$lock" ]] || { warn "$(msg '缺组件清单，跳过安卓侧产物部署' 'Component lock missing; skipping device bridge deploy')"; return 1; }
    if ! drm_adb_target >/dev/null 2>&1; then
        fail "$(msg '没有可用的 adb 通道，安卓侧产物无法部署：先跑「建立 adb 通道」' 'No usable adb channel; run the adb bridge step first')"
        BRIDGE_DEPLOY_FAILED=" audio_bridge bluetooth_bridge"
        return 1
    fi
    BRIDGE_DEPLOY_FAILED=""
    for key in audio_bridge bluetooth_bridge; do
        deploy_one_bridge "$key" "$(json_get "$lock" ".$key.repo")" "$(json_get "$lock" ".$key.tag")" \
            "$(json_get "$lock" ".$key.asset")" "$(json_get "$lock" ".$key.sha256")" \
            || BRIDGE_DEPLOY_FAILED="$BRIDGE_DEPLOY_FAILED $key"
    done
    [[ -z "$BRIDGE_DEPLOY_FAILED" ]]
}

deploy_one_bridge() {
    local name="$1" repo="$2" tag="$3" asset="$4" sha="$5"
    [[ -n "$repo" && -n "$tag" && -n "$asset" ]] || { warn "$(msg "清单里 $name 条目不完整，跳过" "$name entry incomplete; skipping")"; return 1; }
    say "$(msg "部署安卓侧产物：$name（$repo@$tag）" "Deploying device artifacts: $name ($repo@$tag)")"
    local tmp dir
    tmp="$(mktemp -t drm-bridge.XXXXXX.tar.gz)"; dir="$(mktemp -d -t drm-bridge.XXXXXXXX)"
    if ! fetch_verified "$repo" "$tag" "$asset" "$sha" "$tmp" "${DRM_CONF[DOWNLOAD_SOURCE]}"; then
        warn "$(msg "$name 产物取不到（源不可达或 sha256 不匹配）" "$name artifact unavailable")"
        rm -rf -- "$dir" "$tmp"; return 1
    fi
    tar -xzf "$tmp" -C "$dir" || { warn "$(msg "$name 解包失败" "$name extract failed")"; rm -rf -- "$dir" "$tmp"; return 1; }
    local root="$dir/$name"
    [[ -d "$root" ]] || root="$(find "$dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    local dev f base pushed=0
    dev=$(drm_adb_target) || { warn "$(msg "  $name：没有可用 adb 地址" '  '"$name"': no adb address')"; rm -rf -- "$dir" "$tmp"; return 1; }
    for f in "$root"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        timeout 30 adb -s "$dev" push "$f" "/data/local/tmp/$base" >/dev/null 2>&1 \
            && { timeout 20 adb -s "$dev" shell "su -c 'chmod 755 /data/local/tmp/$base'" >/dev/null 2>&1; pushed=$((pushed + 1)); } \
            || warn "$(msg "  push 失败：$base" '  push failed: '"$base")"
    done
    rm -rf -- "$dir" "$tmp"
    say "$(msg "  已推送 $pushed 个文件到 /data/local/tmp" "  Pushed $pushed files")"
    (( pushed > 0 )) || { fail "$(msg "  $name 一个文件都没推上去" '  '"$name"': nothing was pushed')"; return 1; }
    verify_bridge_files "$name"
}

# 复检只认"文件真的在设备上且可执行"，不认措辞
verify_bridge_files() {
    local name="$1" out dev
    dev=$(drm_adb_target) || { fail "$(msg '  复检取不到 adb 地址' '  Cannot resolve an adb address for the re-check')"; return 1; }
    case "$name" in
        audio_bridge)
            out=$(timeout 25 adb -s "$dev" shell "su -c 'for f in argsloop halsink.sh mix2.bin dev23.bin patch0.bin; do test -e /data/local/tmp/\$f || echo MISS-\$f; done; test -x /data/local/tmp/argsloop || echo NOTEXEC-argsloop'" 2>/dev/null | tr -d '\r') ;;
        bluetooth_bridge)
            out=$(timeout 25 adb -s "$dev" shell "su -c 'test -e /data/local/tmp/bthci-bridge-v2 || echo MISS-bthci-bridge-v2; test -x /data/local/tmp/bthci-bridge-v2 || echo NOTEXEC'" 2>/dev/null | tr -d '\r') ;;
    esac
    if [[ -z "${out// }" ]]; then
        ok "$(msg "  $name 设备侧复检通过" "  $name device-side check passed")"
        return 0
    fi
    fail "$(msg "  $name 设备侧缺文件：$out" "  $name missing on device: $out")"
    return 1
}
