#!/usr/bin/env bash
# conf.sh — /etc/drm-takeover.conf 的读写（接管脚本与 TUI 的唯一参数源）。
# 为什么必须有它：desk-takeover.sh 里 xieyizhou / /home/xieyizhou 出现 43 处
# （runuser、HOME、XDG_RUNTIME_DIR、kwinrc/plasmakeyboardrc、chown、KWINWRAP_USER、polkit subject.user）。
# 不分发给别人的话，"快捷方式按实际用户名"只是表面。deb 不管这些值，避免双源。
#
# 规矩：
#   · 本文件只由安装器/TUI 写（写需要 root），接管脚本只读。
#   · 缺文件必须回落到"当前运行用户"，让老设备零改动继续跑（见 drm_conf_defaults）。
#   · 每次 apt 装东西后必须审计新增 enabled 单元（工作总结 §41：modemmanager 被 Recommends 带进来
#     并 enable，plasmashell 查它的 D-Bus 干等 25 秒）；这条不写在 conf 里，写在 precheck.sh。

declare -A DRM_CONF=()
# ⚠ 运行中不要 `unset DRM_CONF`：-A 属性会随之丢失，之后所有 `DRM_CONF[键]=值` 会被当成
# 索引数组、键按算术塌成 0，读回来全是最后一个写进去的值（09-30 单元测试就是这么"静默读不回"的）。
# 要重置请重新 source 本文件，或只清空内容：DRM_CONF=()。

# 键 = 名称|默认值来源|说明（中文给 TUI 显示用）
drm_conf_defaults() {
    local user="" uid="" home=""
    user="${SUDO_USER:-$(id -un)}"
    [[ "$user" == "root" ]] && user="$(logname 2>/dev/null || id -un)"
    uid="$(id -u "$user" 2>/dev/null || echo 1000)"
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [[ -n "$home" ]] || home="/home/$user"

    DRM_CONF[DRM_USER]="$user"
    DRM_CONF[DRM_UID]="$uid"
    DRM_CONF[DRM_HOME]="$home"
    DRM_CONF[REPO_DIR]="${REPO_DIR:-$home/Documents/XiaomiPad8Pro-drm-display/droid-drm-takeover}"
    DRM_CONF[LOG_DIR]="${LOG_DIR:-$(dirname "${REPO_DIR:-$home/Documents/XiaomiPad8Pro-drm-display/droid-drm-takeover}")/logs}"
    DRM_CONF[DOWNLOAD_SOURCE]="auto"
    DRM_CONF[UI_LANG]="auto"
    DRM_CONF[SHORTCUTS]="1"
    DRM_CONF[INSTALL_KEYBOARD]="1"
    DRM_CONF[KWIN_X11_IM]="1"          # 键盘的子选项：装不装打过补丁的 kwin（X11 应用弹 VKB + 通道 C）
    DRM_CONF[TAKEOVER_WIFI]="1"
    DRM_CONF[BT_BRIDGE]="1"
    DRM_CONF[AUDIO_BRIDGE]="1"
    DRM_CONF[RELAUNCH_ANLAND]="1"      # 返回安卓时自动拉起 anland（默认开；关掉它 anland 就不会自己回来）
    DRM_CONF[GPUFLOOR]="0"             # 高级页，默认关（实测只值 6~16%，噪声就有 8.7%）
    DRM_CONF[PERFMAX]="0"              # 高级页，默认关（die 能到 69°C，只作跑分）
}

# 从 conf 文件恢复（只认 KEY=VALUE，值里的引号按 shell 规则剥掉）
drm_conf_load() {
    [[ -r "$DRM_CONF_FILE" ]] || return 1
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"; value="${line#*=}"
        key="${key//[[:space:]]/}"
        value="${value%\"}"; value="${value#\"}"
        [[ -n "$key" ]] || continue
        DRM_CONF[$key]="$value"
    done <"$DRM_CONF_FILE"
    return 0
}

drm_conf_get() { printf '%s' "${DRM_CONF[$1]:-}"; }

drm_conf_bool() { [[ "${DRM_CONF[$1]:-0}" == "1" ]]; }

# 写盘：先落 .tmp 再 mv（防半截文件），权限 0644（接管脚本要以普通用户身份读到它）。
drm_conf_save() {
    local dir; dir="$(dirname "$DRM_CONF_FILE")"
    mkdir -p "$dir" 2>/dev/null || true
    local tmp="$DRM_CONF_FILE.tmp.$$" key
    {
        printf '# drm-takeover 参数（由 drm-tui 安装器生成；改这些值请用 drm-tui 的设置页，别手改）\n'
        printf '# 生成时间：%s\n\n' "$(date '+%F %T')"
        for key in DRM_USER DRM_UID DRM_HOME REPO_DIR LOG_DIR DOWNLOAD_SOURCE UI_LANG \
                   SHORTCUTS INSTALL_KEYBOARD KWIN_X11_IM TAKEOVER_WIFI BT_BRIDGE AUDIO_BRIDGE \
                   RELAUNCH_ANLAND GPUFLOOR PERFMAX; do
            [[ -n "${DRM_CONF[$key]:-}" ]] || continue
            printf '%s="%s"\n' "$key" "${DRM_CONF[$key]}"
        done
    } >"$tmp" || return 1
    chmod 0644 "$tmp"
    mv -f -- "$tmp" "$DRM_CONF_FILE" || { rm -f -- "$tmp"; return 1; }
    return 0
}

# 让接管脚本能 source 的最小 shim：写进 conf 文件末尾之外，单独给脚本用。
# 用法（脚本顶部）： source "$DIR/installer/lib/conf.sh"; drm_conf_eval; 之后 $DRM_USER 等直接可用。
drm_conf_eval() {
    local k
    for k in "${!DRM_CONF[@]}"; do
        printf -v "$k" '%s' "${DRM_CONF[$k]}"
        export "${k?}"
    done
}
