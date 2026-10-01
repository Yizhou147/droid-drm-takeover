#!/usr/bin/env bash
# drm-tui — 小米平板 8 Pro DRM 显示接管：一键安装器 + 运行期 TUI。
#
# 一个文件两种身份（按参数分流）：
#   安装： bash drm-tui.sh install [--yes]
#   日常： drm-tui                 （装完后落在 /usr/local/bin/drm-tui）
#   内部： --run <脚本> / --save-conf / --do-repair …（sudo 重入时走的分支，不给用户看）
#
# 为什么装完还要留个 TUI，而不只给两个桌面快捷方式：
#   · 快捷方式只管"进"和"回"，管不了"上一轮没成功、anland 也没回来、手里只剩终端"那种情况；
#   · 机型/依赖/补丁 kwin 这些状态用户自己无法判断，需要一处能"检查并补装"的地方；
#   · 老脚本跑起来一晃就没、不知道卡在哪（用户的原话），得有个把判据行翻成人话的界面。
#
# 安全边界（全部来自工作总结踩过的坑，改这个文件前先读 §12 与 §7）：
#   · 识别到 DRM 态时**只给"回到安卓"**，绝不在此时再跑一轮 takeover（09-24 实锤：
#     中途重跑 desk-takeover，可用桌面被 kill_linux_stack 杀掉，用户只能强启平板）。
#   · 本程序不主动重启设备、不自己碰网络实验；显示/网络动作一律委托仓内 desk-*.sh。
#   · 给用户的补救命令一律单行、不串 &&、不用续行（用户的终端粘不了多行）。

set -uo pipefail

VERSION="0.1.0"
SCRIPT_SRC="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "$SCRIPT_SRC")")" && pwd -P)"
LIB_DIR="$SCRIPT_DIR/lib"

if [[ ! -r "$LIB_DIR/common.sh" ]]; then
    printf '%s\n' "缺少 $LIB_DIR/common.sh —— 请通过仓库里的 installer/drm-tui.sh 运行，或用安装器重装。" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"
source "$LIB_DIR/conf.sh"
source "$LIB_DIR/state.sh"
source "$LIB_DIR/net.sh"
source "$LIB_DIR/precheck.sh"
source "$LIB_DIR/adbroute.sh"
source "$LIB_DIR/baseline.sh"

readonly REPO_SLUG="${DRM_REPO_SLUG:-Yizhou147/droid-drm-takeover}"
readonly KEYBOARD_REPO_SLUG="${DRM_KEYBOARD_REPO_SLUG:-Yizhou147/droid-pc-keyboard}"
readonly KWIN_REPO_SLUG="${DRM_KWIN_REPO_SLUG:-Yizhou147/droidspaces-package}"
readonly KWIN_ROLLING_TAG="anland-kde-packages"
readonly TUI_BIN="/usr/local/bin/drm-tui"
readonly SUDOERS_FILE="/etc/sudoers.d/drm-tui"
readonly COMPONENTS_LOCK="${DRM_COMPONENTS_LOCK:-$LIB_DIR/components.lock.json}"

# 桌面快捷方式与图标（图标是用户自制的资产，见 §8.0：现在**不在 git 里**，
# 所以安装时优先用设备上已有的那份；找不到就退回 KDE 主题图标，不阻塞安装）。
# 目标桌面用户的家目录。安装器以 root 运行，此时 $HOME=/root ——
# 用它写快捷方式会把文件放进 /root/Desktop，用户桌面上自然什么都没有（10-01 实测）。
drm_target_home() { printf '%s' "${DRM_CONF[DRM_HOME]:-$HOME}"; }
readonly ICON_ENTER="droid-enter-drm.png"
readonly ICON_BACK="droid-back-android.png"

# 接管/交还两条链的日志名（脚本自己写，我们只读）
readonly TAKEOVER_SCRIPT="desk-takeover.sh"
readonly STOP_SCRIPT="scripts/desk-stop.sh"

# 阶段表按"哪条链"分开：把交还当接管去匹配，会得到一张永远不动的阶段表——
# 用户看到的就是"按了没反应"，比不显示更糟。token 全部取自脚本里真实存在的判据行。
STAGE_ROWS_TAKEOVER=(
    "预检与读取当前 WiFi|WIFI-GEN|NO-ADB-DEVICE|15"
    "重建 DRM 节点与 udev 合成记录|GPU-NODE|TOUCH-RECORD FAIL|10"
    "输入热插拔（裸 udevd）|UDEV-HOTPLUG OK|UDEV-HOTPLUG OFF|6"
    "触摸/GPU 权限自证|GPU-PERM OK|INPUT-PERM FAIL|5"
    "放倒安卓显示栈|ANDROID-STOP|ROLLBACK|45"
    "kwin 接管显示（画面应已上屏）|KWIN-UP|kwin died|15"
    "起 Plasma 桌面组件|DESKTOP-UP|PLASMA-FAIL|30"
    "XWayland 就绪|XWAYLAND-OK|XWAYLAND-ABSENT|12"
    "组合键守护 pc-keyd|PC2-UP|PC2-FAIL|6"
    "容器接管 WiFi|NET-TAKEOVER|NET-FAILED|60"
)
STAGE_ROWS_STOP=(
    "解除悬停保护|WATCHDOG|WATCHDOG_PID|5"
    "收掉容器侧 supplicant|WPA-GRACEFUL|WPA-TERM|12"
    "恢复安卓显示栈|SURFACEFLINGER|ROLLBACK|90"
    "交还蓝牙 HAL|BT-HANDOVER|BT-LEAK-STILL|15"
    "还原 kwinrc 撕裂许可|TEARING-CONFIG|TEARING-CONFIG FAIL|4"
    "复活 anland 会话|anland session relaunched|ANLAND-MISS|25"
    "接回安卓存储|STORAGE-FIX|STORAGE-STALE|12"
)

# ---------------------------------------------------------------- 基础设施 ----

detect_json_parser() {
    if command -v jq >/dev/null 2>&1; then JSON_PARSER="jq"
    elif command -v python3 >/dev/null 2>&1; then JSON_PARSER="python3"
    else return 1
    fi
    return 0
}
JSON_PARSER=""

json_get() {
    local file="$1" path="$2"
    case "$JSON_PARSER" in
        jq) jq -r "$path // empty" "$file" 2>/dev/null ;;
        python3) python3 - "$file" "$path" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cur = d
for k in [x for x in sys.argv[2].strip(".").split(".") if x]:
    try:
        cur = cur[int(k)] if k.isdigit() else cur.get(k)
    except Exception:
        cur = None
    if cur is None:
        break
print("" if cur is None else (cur if isinstance(cur, str) else json.dumps(cur)))
PY
    esac
}

load_state() {
    drm_conf_defaults
    drm_conf_load || info "$(msg "还没有配置文件（$DRM_CONF_FILE），先用当前默认值" 'No config file yet; using defaults for now')"
    DRM_REPO_DIR="${DRM_CONF[REPO_DIR]}"
    # conf 的 UI_LANG 可以是 auto/zh/en：非 auto 时当作强制覆盖，再跑一次 detect_language
    if [[ "${DRM_CONF[UI_LANG]:-auto}" != "auto" ]]; then
        DRM_FORCE_LANG="${DRM_CONF[UI_LANG]}"
        detect_language
    fi
    # 先取安卓侧身份（机型/通道/surfaceflinger），再判状态：detect_state 的"安卓是否停着"
    # 全靠 DRM_SF，不调这一步就会既显示"设备未知"又误报"看不到 adb 设备"（09-30 冒烟测试实锤）。
    # 导出成普通变量：接管/交还那段是按 $LOG_DIR、$REPO_DIR 这些名字写的，
    # 只留在关联数组里的话，一点"进入接管"就会在 set -u 下当场炸（09-30 冒烟测试漏掉的那类）。
    drm_conf_eval
    detect_android_identity
    detect_state >/dev/null
}

# ---- 打开时的后台自检（dstui 的姿势：界面先画，结果到了再刷）----
# 菜单**只读结果文件**，绝不在这上面等网络：查更新走 GitHub API，未认证限速 60 次/小时，
# 慢或者失败都不能让主菜单转不出来。
drm_check_path() { printf '%s/.drm-tui-check' "${DRM_CONF[LOG_DIR]}"; }

start_background_checks() {
    local out; out="$(drm_check_path)"
    mkdir -p "${DRM_CONF[LOG_DIR]}" 2>/dev/null || return 0
    rm -f -- "$out"
    (
        {
            printf '# 生成于 %s\n' "$(date '+%F %T')"
            local fails; fails=$(run_precheck 2>/dev/null | tail -1)
            printf 'precheck_fails=%s\n' "${fails:-1}"
            if detect_json_parser; then
                local j; j="$(mktemp -t drm-chk.XXXXXX.json)"
                if github_api "/repos/$REPO_SLUG/releases/latest" "$j"; then
                    printf 'latest_tag=%s\n' "$(json_get "$j" .tag_name)"
                    printf 'latest_draft=%s\n' "$(json_get "$j" .draft)"
                else
                    printf 'latest_tag=\n'
                fi
                rm -f -- "$j"
            fi
        } >"$out.tmp" 2>/dev/null
        mv -f -- "$out.tmp" "$out" 2>/dev/null
    ) &
    disown 2>/dev/null || true
}

# 头部那一行：新鲜（<10 分钟）就报数，没结果就一个字"检查中"，超时就提示重跑
render_check_line() {
    local f; f="$(drm_check_path)"
    [[ -r "$f" ]] || { info "$(msg '后台自检进行中…' 'background checks running…')"; return 0; }
    local newest=$(( $(date +%s) - 600 ))
    if [[ "$f" -ot "$newest" ]]; then
        info "$(msg '自检结果已过期（>10 分钟），可用"检查安装 / 修复"重跑' 'Checks are stale (>10 min); run Check installation / repair')"
        return 0
    fi
    local fails="" latest=""
    fails=$(sed -n 's/^precheck_fails=//p' "$f" | head -1)
    latest=$(sed -n 's/^latest_tag=//p' "$f" | head -1)
    if [[ "${fails:-1}" == "0" ]]; then
        ok "$(msg '预检通过' 'Precheck passed')"
    else
        warn "$(msg "预检有 ${fails:-?} 项未通过（详见「检查安装 / 修复」）" 'Precheck has '"${fails:-?}"' unmet item(s); see Check installation / repair')"
    fi
    if [[ -n "$latest" ]]; then
        local installed="${DRM_CONF[INSTALLED_VERSION]:-未记录}"
        if [[ "$installed" == "$latest" ]]; then
            say "$(msg "  主仓已是最新（$latest）" '  Main repo is up to date ('"$latest"')')"
        else
            say "$(msg "  主仓有新版：$latest（本地 $installed）" '  New main-repo release: '"$latest"' (local '"$installed"')')"
        fi
    fi
}

# ---------------------------------------------------------------- 安装流程 ----

ask_components() {
    # 一步只问一件事。WiFi / 蓝牙 / 音频固定默认开启，不给开关（用户 10-01 明确要求）。
    say ""
    if ask_yes "生成桌面快捷方式（进入DRM接管 / 返回安卓）？" "Create desktop shortcuts?"; then
        DRM_CONF[SHORTCUTS]=1
    else
        DRM_CONF[SHORTCUTS]=0
    fi

    if ask_yes "安装输入法 droid-pc-keyboard？" "Install the droid-pc-keyboard input method?"; then
        DRM_CONF[INSTALL_KEYBOARD]=1
        if ask_yes "X11 应用也弹出虚拟键盘？（需换装打过补丁的 kwin）" \
                   "Also pop the VKB in X11 apps? (needs the patched kwin)"; then
            DRM_CONF[KWIN_X11_IM]=1
            warn "$(msg '  副作用：这台机器上 anland 用的就是这个 kwin 二进制，回退后 anland 可能起不来。' \
                        '  Side effect: anland uses this same kwin binary; rolling back may stop anland from starting.')"
        else
            DRM_CONF[KWIN_X11_IM]=0
        fi
    else
        DRM_CONF[INSTALL_KEYBOARD]=0
        DRM_CONF[KWIN_X11_IM]=0
    fi

    DRM_CONF[TAKEOVER_WIFI]=1
    DRM_CONF[BT_BRIDGE]=1
    DRM_CONF[AUDIO_BRIDGE]=1
}

install_flow() {
    require_root "$SCRIPT_SRC" install "$@"
    head2 "$(msg 'drm-tui 安装' 'Install drm-tui')"
    load_state

    step 1 10 '建立 Android 调试通道' 'Establish the Android debug channel'
    if ! establish_adb_bridge 1; then
        [[ "$DRM_ADB_STATUS" == "unauthorized" ]] && auth_remedy
        die "$(msg 'adb 通道未建立，无法继续。开启无线调试并完成配对后重跑。' \
              'adb channel unavailable. Enable wireless debugging, pair, then re-run.')"
    fi

    step 2 10 '识别设备与发行版' 'Identify device and distribution'
    detect_android_identity
    is_target_model
    case "$?" in
        0) ok "$(msg "设备型号确认：Xiaomi Pad 8 Pro（${DRM_MODEL}）" 'Device verified: Xiaomi Pad 8 Pro')" ;;
        2) die "$(msg '无法确认设备型号：ro.product.device 读取为空。请先完成 Android 调试通道授权（下一步的 adb 检查会给出具体状态与处置）。' \
              'Cannot determine the device model: ro.product.device is empty. Authorize the Android debug channel first; the adb check below reports the exact state and remedy.')" ;;
        *) die "$(msg "设备型号不匹配：检测到 ro.product.device=${DRM_PRODUCT}。本工具仅在 Xiaomi Pad 8 Pro（piano）上验证。" \
              'Device mismatch: detected ro.product.device='"${DRM_PRODUCT}"'. This tool is verified on Xiaomi Pad 8 Pro (piano) only.')" ;;
    esac
    supported_target || die "$(msg "当前发行版或桌面环境不受支持：本工具仅在 Ubuntu 26.04 + KDE 上验证（检测到 $(detect_distro) / $(detect_desktop)）。" \
              'Unsupported distribution or desktop environment: verified only on Ubuntu 26.04 + KDE.')"
    ok "$(msg "运行环境确认：$(detect_distro) / $(detect_desktop)" 'Runtime environment verified')"

    step 3 10 '安装前环境检查' 'Pre-install environment checks'
    # 原来写 `fails=$(run_precheck | tail -1)`：只留最后一行数字，
    # 于是所有 ✔/✘ 明细都被吞掉，用户在第 3 步什么也看不见（10-01 实测第 3 步是空的）。
    local fails pre_out
    pre_out="$(mktemp -t drm-precheck.XXXXXX)"
    run_precheck >"$pre_out" 2>&1
    sed '$d' "$pre_out"
    fails="$(tail -1 "$pre_out")"
    rm -f -- "$pre_out"
    (( ${fails:-1} == 0 )) || die "$(msg "预检未通过 $fails 项——按上面每条的单行命令补救后重跑安装" 'Precheck failed '"$fails"' item(s); fix with the single-line hints, then re-run')"

    step 4 10 '选择下载源（按实测吞吐）' 'Select download source by measured throughput'
    pick_mirror

    step 5 10 '选择要安装的组件' 'Select components'
    ask_components

    step 6 10 '安装 apt 依赖' 'Install apt dependencies'
    local -a miss=()
    mapfile -t miss < <(missing_packages)
    # 基线额外需要的包（命令名与包名同名，missing_packages 查不到）：
    # bluez-obexd 与 libspa-0.2-bluetooth 缺了，接管轮里的蓝牙配对/A2DP 就不可用。
    local -a extra=(); mapfile -t extra < <(baseline_extra_packages)
    local e
    for e in "${extra[@]}"; do
        dpkg -l "$e" 2>/dev/null | awk '$2=="ii"{f=1} END{exit f?0:1}' || miss+=("$e")
    done
    if (( ${#miss[@]} )); then
        install_debs_with_audit "${miss[@]}" || die "$(msg 'apt 安装失败' 'apt install failed')"
    else
        ok "$(msg '依赖已齐全' 'Dependencies already present')"
    fi

    step 7 10 '获取接管产物并校验 sha256' 'Fetch takeover artifacts and verify sha256'
    extract_release || warn "$(msg '产物取回不完整——可用"检查安装/修复"重试' 'Artifacts incomplete; retry from Check installation / repair')"
    install_keyboard_if_chosen

    step 8 10 '写入配置、桌面快捷方式、sudoers 与 drm-tui 命令' 'Write configuration, shortcuts, sudoers and the drm-tui command'
    drm_conf_save || warn "$(msg '配置写入失败（需要 root）' 'Cannot write config (needs root)')"
    install_shortcuts
    install_sudoers
    install_tui_entry

    step 9 10 '写入桌面基线（kwinrc / 输入法 / 运行期脚本 / systemd）' 'Apply the desktop baseline'
    apply_desktop_baseline

    step 10 10 '部署安卓侧桥产物（音频 sink 与蓝牙桥）' 'Deploy Android-side bridge artifacts'
    deploy_android_bridges || warn "$(msg "桥产物未全部就位：${BRIDGE_DEPLOY_FAILED# } —— 接管轮里声音/蓝牙会不可用，可用「检查安装 / 修复」重试" \
        'Some bridge artifacts are missing: '"${BRIDGE_DEPLOY_FAILED# }"' — audio/Bluetooth will not work; retry from Check installation / repair')"

    local -a gaps=()
    (( ${DRM_KWIN_FAILED:-0} == 1 )) && gaps+=("$(msg '定制 kwin' 'patched kwin')")
    [[ -n "${BRIDGE_DEPLOY_FAILED:-}" ]] && gaps+=("$(msg '安卓侧桥产物' 'device bridges'):${BRIDGE_DEPLOY_FAILED# }")
    if (( ${#gaps[@]} )); then
        head2 "$(msg '安装完成，但有未齐项' 'Installed, with gaps')"
        say "$(msg "  未齐：${gaps[*]}" '  Missing: '"${gaps[*]}")"
        say "$(msg '  处理：设置 → 补装，或重跑「检查安装 / 修复」。接管本身仍可用。' \
                   '  Fix from Settings → install now, or re-run Check installation / repair. Takeover still works.')"
    else
        head2 "$(msg '安装完成' 'Done')"
    fi
    say "$(msg '以后在终端输入一行即可：' 'From now on, run this single line:')"
    printf '  %bdrm-tui%b\n' "$COLOR_BOLD" "$COLOR_RESET"
    say "$(msg '接管时屏幕会熄灭数十秒，失败自动恢复，不要长按电源键。' \
               'During takeover the screen goes dark for tens of seconds; failures roll back. Do not hold the power button.')"
}

# 接管产物：aarch64 tarball（脚本 + 已交叉编译好的 bin/）。用户端不编译。
# tar 的 sha 不可能写进 tar 里那份清单（自指），所以这个组件的 tag 与 digest
# 一律现问 release API —— 与 install-drm-tui.sh 用的是同一套判据。
extract_release() {
    local tag asset want out rc=0
    detect_json_parser || { warn "$(msg '需要 jq 或 python3 才能读 release' 'jq or python3 needed to read release info')"; return 1; }
    asset="drm-takeover-aarch64.tar.gz"
    [[ -r "$COMPONENTS_LOCK" ]] && asset="$(json_get "$COMPONENTS_LOCK" ".takeover.asset")"
    [[ -n "$asset" ]] || asset="drm-takeover-aarch64.tar.gz"
    out="$(mktemp -t drm-rel.XXXXXX.json)"
    github_api "/repos/$REPO_SLUG/releases/latest" "$out" || { rm -f -- "$out"; warn "$(msg '取不到 release 信息' 'Cannot reach release info')"; return 1; }
    tag=$(json_get "$out" ".tag_name")
    want="$(release_asset_digest "$out" "$asset")"
    rm -f -- "$out"
    [[ -n "$tag" ]] || { warn "$(msg '没有公开的 release（draft 走 latest 读不到）' 'No public release; drafts are invisible via latest')"; return 1; }
    [[ -n "$want" ]] || warn "$(msg '取不到该资产的 digest，本次下载不校验' 'No digest for this asset; downloading unverified')"

    local dest="${DRM_CONF[REPO_DIR]}"
    mkdir -p "$dest" 2>/dev/null || true
    out="$(mktemp -t drm-tar.XXXXXX.tar.gz)"
    fetch_verified "$REPO_SLUG" "$tag" "$asset" "$want" "$out" "${DRM_CONF[DOWNLOAD_SOURCE]}" || { rm -f -- "$out"; return 1; }
    info "$(msg "解包到 $dest" 'Extracting to '"$dest")"
    # 不假设 tar 根目录名 == dest 名（同 install-drm-tui.sh 的教训）：先解到临时目录再按内容铺
    local work inner
    work="$(mktemp -d -t drm-unpack.XXXXXXXX)"
    if tar -xzf "$out" -C "$work"; then
        inner="$work/drm-takeover"
        [[ -d "$inner" ]] || inner="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)"
        if [[ -d "$inner" ]]; then
            mkdir -p "$dest" || rc=1
            cp -a "$inner"/. "$dest"/ || rc=1
        else
            rc=1; warn "$(msg 'tar 里没有预期目录' 'tar has no expected directory')"
        fi
    else
        rc=1
    fi
    rm -rf -- "$work"
    chmod +x "$dest"/*.sh "$dest"/scripts/*.sh 2>/dev/null || true
    rm -f -- "$out"
    DRM_CONF[INSTALLED_VERSION]="$tag"
    return $rc
}

# 键盘：deb 装前**必须** dry-run 看有没有 Remv 行（§21 的 Breaks 拆桌面栈事故）。
install_keyboard_if_chosen() {
    [[ "${DRM_CONF[INSTALL_KEYBOARD]}" == "1" ]] || { say "$(msg '未勾选输入法，跳过' 'Keyboard not selected; skipping')"; return 0; }
    detect_json_parser || return 1
    local out tag asset want deb
    out="$(mktemp -t drm-kb.XXXXXX.json)"
    github_api "/repos/$KEYBOARD_REPO_SLUG/releases/latest" "$out" || { rm -f -- "$out"; warn "$(msg '取不到键盘版本信息' 'Cannot read keyboard release')"; return 1; }
    tag=$(json_get "$out" ".tag_name"); rm -f -- "$out"
    [[ -n "$tag" ]] || { warn "$(msg '键盘 release 为空（draft 的 release 不进镜像，必须先公开）' 'Empty keyboard release (drafts are not mirrored; publish first)')"; return 1; }
    deb="droid-pc-keyboard_${tag#v}_arm64.deb"
    want=""
    out="$(mktemp -t drm-kb2.XXXXXX.json)"
    # 按资产名取 digest（.assets[0] 在双架构 deb 的 release 里完全可能是 amd64 那份）
    if github_api "/repos/$KEYBOARD_REPO_SLUG/releases/tags/$tag" "$out"; then
        want="$(release_asset_digest "$out" "$deb")"
    fi
    rm -f -- "$out"
    local tmpdir; tmpdir="$(mktemp -d -t drm-kb.XXXXXXXX)"
    fetch_verified "$KEYBOARD_REPO_SLUG" "$tag" "$deb" "$want" "$tmpdir/$deb" "${DRM_CONF[DOWNLOAD_SOURCE]}" || { rm -rf -- "$tmpdir"; return 1; }

    say "$(msg '装前 dry-run：确认没有包被连坐卸载（历史上 Breaks 曾把整个 plasma 桌面栈拆掉）' \
          'Dry-run first: confirm nothing gets removed (a Breaks field once tore out the whole Plasma stack)')"
    # 先把 dry-run 结果整份取下来再判：管道 + grep -q 在 pipefail 下会因为 apt 提前收到
    # SIGPIPE 而把"确实有 Remv"误判成"没有"（09-30 在同一文件里踩过一次，别再犯）。
    local dryrun
    dryrun="$(apt install --dry-run "$tmpdir/$deb" 2>&1)"
    local -a removelines=()
    mapfile -t removelines < <(printf '%s\n' "$dryrun" | grep -E 'Remv ' | head -8)
    if (( ${#removelines[@]} )); then
        fail "$(msg 'dry-run 里出现 Remv（要卸载别的包）——已中止键盘安装，这是拆包防护起效' \
               'dry-run shows Remv lines — aborting the keyboard install; this is the anti-teardown guard')"
        printf '    %s\n' "${removelines[@]}"
        rm -rf -- "$tmpdir"; return 1
    fi
    apt install -y --no-install-recommends "$tmpdir/$deb" || { warn "$(msg 'deb 安装失败' 'deb install failed')"; rm -rf -- "$tmpdir"; return 1; }
    ok "$(msg '输入法已安装' 'Keyboard installed')"
    rm -rf -- "$tmpdir"
    [[ "${DRM_CONF[KWIN_X11_IM]}" == "1" ]] && install_patched_kwin
}

install_patched_kwin() {
    # 装法：install-anland-kde.sh 本身就是 anland-kde-packages 那个滚动 release 的资产，
    # 取回来直接跑它 —— 它已经处理好多发行版、三源回退、apt holds、以及 --uninstall 回退，
    # 不要在这里重新发明一遍（尤其别试图用 dpkg 判断补丁在不在，见 §12.3 的 md5sums 污染）。
    # api.github.com 在部分网络下不可达（10-01 新容器实测 curl 28 超时）。
    # 那不该终止这一步：draft 检查只是省一次无用下载，资产本身走 release 下载 URL 就能取。
    local out base
    out="$(mktemp -t drm-kwin.XXXXXX.json)"
    if github_api "/repos/$KWIN_REPO_SLUG/releases/tags/$KWIN_ROLLING_TAG" "$out" && detect_json_parser; then
        if [[ "$(json_get "$out" ".draft")" == "true" ]]; then
            rm -f -- "$out"
            warn "$(msg 'anland-kde-packages 仍是 draft：镜像站拿不到，请先公开发布' 'Rolling kwin release is still a draft; publish it first')"
            return 1
        fi
    fi
    rm -f -- "$out"

    local tmp; tmp="$(mktemp -t drm-kwininst.XXXXXX.sh)"
    local srcidx="${DRM_CONF[DOWNLOAD_SOURCE]}"
    [[ "$srcidx" =~ ^[123]$ ]] || srcidx=""
    base="$(source_base "${srcidx:-2}" "$KWIN_REPO_SLUG")"
    info "$(msg "下载 install-anland-kde.sh（源 ${SRC_LABELS[${srcidx:-2}-1]}）" 'Downloading install-anland-kde.sh')"
    if ! dl_curl 120 "$tmp" "$base/$KWIN_ROLLING_TAG/install-anland-kde.sh"; then
        rm -f -- "$tmp"
        warn "$(msg '取不到 install-anland-kde.sh，跳过定制 kwin（X11 应用将不弹虚拟键盘，接管本身不受影响）'                'Cannot fetch the kwin installer; skipping patched kwin (VKB will not pop for X11 apps)')"
        return 1
    fi
    # 这个脚本自带 --uninstall（回发行版 kwin），把入口透出给用户
    local chosen="${srcidx:-3}"
    step 1 1 "$(msg '换装打过补丁的 kwin（含 anland 后端与 pc-keyd 通道 C）' 'Installing patched kwin')"
    local attempt rc
    for attempt in 1 2; do
        bash "$tmp" "--$chosen"; rc=$?
        # 判据只看实测：libkwin 里有没有本项目自造的符号。
        # 不能用 dpkg -V / md5sums —— 定制 deb 复用 Ubuntu 版本串并抄了原厂 md5sums，三条校验全废。
        if (( rc == 0 )) && kwin_patch_present; then
            ok "$(msg '定制 kwin 已安装并复检通过' 'Patched kwin installed and verified')"
            DRM_KWIN_FAILED=0
            rm -f -- "$tmp"
            return 0
        fi
        if (( attempt == 1 )); then
            if kwin_patch_present; then local v=通过; else local v=未通过; fi
            warn "$(msg "  第 1 次未成功（退出码 $rc / 复检$v），重试一次" "  Attempt 1 failed (rc $rc / verify $v); retrying")"
        fi
    done
    DRM_KWIN_FAILED=1
    fail "$(msg '定制 kwin 未装上：X11 应用不会弹虚拟键盘、组合键通道 C 不可用（接管与 anland 本身不受影响）' \
               'Patched kwin not installed: X11 apps will not pop the VKB and channel C is unavailable')"
    rm -f -- "$tmp"
    return 1
}

# kwin_patch_present —— 实测判据：libkwin 里有没有本项目自造的符号
kwin_patch_present() {
    local lib hits
    lib="$(ls /usr/lib/*/libkwin.so.6* 2>/dev/null | grep -v '\.so\.6$' | head -1)"
    [[ -n "$lib" && -r "$lib" ]] || return 1
    hits=$(strings -a "$lib" 2>/dev/null | grep -c '^PCKEYD_INPUT_SOCKET$')
    (( ${hits:-0} > 0 ))
}

# ---- 桌面快捷方式 ----
write_desktop_file() {
    local name="$1" exec_target="$2" icon="$3" comment="$4" file="$5"
    cat >"$file" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Name[zh_CN]=$name
Comment=$comment
Exec=bash -c 'konsole -e sudo $exec_target'
Terminal=false
Icon=$icon
Categories=System;
EOF
    chmod +x "$file"
}

install_shortcuts() {
    local repo="${DRM_CONF[REPO_DIR]}" user="${DRM_CONF[DRM_USER]}"
    local home deskdir icondir
    home="$(drm_target_home)"; deskdir="$home/Desktop"; icondir="$home/.local/share/icons"
    mkdir -p "$deskdir" "$icondir" 2>/dev/null || { warn "$(msg "写不进 $deskdir" 'Cannot write '"$deskdir")"; return 1; }
    # 图标一律从仓库装进目标用户家目录（仓库已收这两张 PNG），不再依赖设备上"恰好有一份"
    local src="$SCRIPT_DIR/assets/icons"
    [[ -f "$src/$ICON_ENTER" ]] || src="$icondir"
    cp -f "$src/$ICON_ENTER" "$src/$ICON_BACK" "$icondir/" 2>/dev/null || true
    local enter_icon="$icondir/$ICON_ENTER" back_icon="$icondir/$ICON_BACK"
    [[ -f "$enter_icon" ]] || { enter_icon="video-display"; back_icon="computer"; }
    write_desktop_file "进入DRM接管" "$repo/$TAKEOVER_SCRIPT" "$enter_icon" "停掉安卓，接管显示/WiFi，起 Plasma 桌面" "$deskdir/进入DRM接管.desktop"
    write_desktop_file "返回安卓" "$repo/$STOP_SCRIPT" "$back_icon" "结束 DRM 接管，把屏幕/网络还给安卓" "$deskdir/返回安卓.desktop"
    # root 写的文件必须 chown 回桌面用户，否则 Plasma 读不到、快捷方式显示不出来
    chown -R "$user:" "$deskdir" "$icondir" 2>/dev/null || true
    ok "$(msg "桌面快捷方式已写入 $deskdir" 'Shortcuts written to '"$deskdir")"
}

# ---- sudoers：让快捷方式/ TUI 免密跑那两条链 ----
install_sudoers() {
    local repo="${DRM_CONF[REPO_DIR]}" user="${DRM_CONF[DRM_USER]}"
    local tmp; tmp="$(mktemp -t drm-sudoers.XXXXXX)"
    # 只放行这两条具体路径，不给全量 root —— 写通配等于把整台机器的 root 交出去
    cat >"$tmp" <<EOF
# drm-tui：只允许免密跑接管/交还这两条链（安装器生成，勿手改）
$user ALL=(root) NOPASSWD: $repo/$TAKEOVER_SCRIPT, $repo/$STOP_SCRIPT
EOF
    # 必须先 visudo -c 再落盘：sudoers 语法错 = 整机 sudo 不可用
    if visudo -c -f "$tmp" >/dev/null 2>&1; then
        install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE" || { warn "$(msg 'sudoers 写入失败（需 root）' 'Cannot write sudoers (needs root)')"; rm -f -- "$tmp"; return 1; }
        ok "$(msg 'sudoers 白名单已就位（免密范围只有那两条脚本）' 'sudoers whitelist installed (scoped to those two scripts only)')"
    else
        fail "$(msg 'sudoers 校验不通过，已放弃写入（宁可不给免密，也不能把 sudo 写坏）' 'sudoers failed validation; not written')"
        rm -f -- "$tmp"; return 1
    fi
    rm -f -- "$tmp"
    return 0
}

install_tui_entry() {
    # 不能把 drm-tui.sh 单独拷到 /usr/local/bin：它按"自己所在目录的 lib/"找依赖库，
    # 拷过去就会报 /usr/local/bin/lib/common.sh 不存在（10-01 新容器实测：装完的 drm-tui 命令直接不可用）。
    # 正确做法是装一个入口脚本，运行期从配置里取仓库路径再 exec 过去。
    mkdir -p /usr/local/bin 2>/dev/null
    local tmp; tmp="$(mktemp -t drm-tui-entry.XXXXXX)"
    cat >"$tmp" <<ENTRY
#!/usr/bin/env bash
# drm-tui 入口（由安装器生成）。实现与 lib/ 都在接管仓库里，别把本文件当实现改。
CONF="\${DRM_CONF_FILE:-/etc/drm-takeover.conf}"
REPO=""
[ -r "\$CONF" ] && REPO=\$(sed -n 's/^REPO_DIR=\("\{0,1\}\)\([^"]*\)\1\$/\2/p' "\$CONF" | head -1)
if [ -z "\$REPO" ] || [ ! -f "\$REPO/installer/drm-tui.sh" ]; then
    echo "找不到接管仓库（REPO_DIR=\"\$REPO\"）。请重新运行安装器，或修正 \$CONF 里的 REPO_DIR。" >&2
    exit 1
fi
exec bash "\$REPO/installer/drm-tui.sh" "\$@"
ENTRY
    chmod 0755 "$tmp"
    install -m 0755 "$tmp" "$TUI_BIN" 2>/dev/null || { warn "$(msg 'drm-tui 命令安装失败' 'Cannot install drm-tui command')"; rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    ok "$(msg "命令已安装：drm-tui（指向 ${DRM_CONF[REPO_DIR]}）" 'Command installed: drm-tui')"
}

# ---------------------------------------------------------------- 运行期 ----

# 轮内显示：脚本自己 setsid 脱钩并把日志落盘，我们 tail 它并翻成人话。
# 轮内显示：脚本自己 setsid 脱钩并把日志落盘，我们 tail 它并翻成人话。
# 阶段表只列**脚本里真实存在的判据 token**（不编造）；预计秒数用来提示"这一步大概还要等多久"。
STAGE_ROWS=()

# 关键纪律：阶段完成只能由"它自己那行判据"证明。历史上用 pgrep kwinwrap 当
# "plasmashell 起来了"的判据 = 永远真，害黑屏白猜三轮（工作总结 §7/5.27）。
stream_round_log() {
    local logfile="$1" child_pid="$2"
    local -A stage_done=()
    local entry name done_pat fail_pat eta idx=0
    for entry in "${STAGE_ROWS[@]}"; do
        IFS='|' read -r name done_pat fail_pat eta <<<"$entry"
        stage_names+=("$name")
        printf '  %b…%b [%2ds] %s\n' "$COLOR_DIM" "$COLOR_RESET" "$eta" "$name"
    done
    say ""
    say "$(msg '（下面是脚本自己的判据行，出现✔才算那一步真过了）' "(these are the script's own judge lines; a ✔ means that step really passed)")"
    local cur_line shown=0
    while :; do
        if [[ -f "$logfile" ]]; then
            while IFS= read -r cur_line; do
                shown=1
                for idx in "${!STAGE_ROWS[@]}"; do
                    IFS='|' read -r name done_pat fail_pat eta <<<"${STAGE_ROWS[idx]}"
                    [[ "${stage_done[$idx]:-}" == "1" ]] && continue
                    if [[ "$cur_line" =~ $done_pat ]]; then
                        stage_done[$idx]=1
                        printf '  %b✔%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$name"
                    elif [[ -n "$fail_pat" && "$cur_line" =~ $fail_pat ]]; then
                        stage_done[$idx]=2
                        printf '  %b✘%b %s（该行原文：%s）\n' "$COLOR_RED" "$COLOR_RESET" "$name" "${cur_line:0:120}"
                    fi
                done
            done < <(tail -n +1 "$logfile" 2>/dev/null | sed -n '/DESK-TAKEOVER START/,$p')
        fi
        kill -0 "$child_pid" 2>/dev/null || break
        sleep 2
    done
    (( shown )) || warn "$(msg '脚本没留下日志，请直接看文件' 'No log lines captured; open the log file directly')"
}

run_takeover() {
    local script="$1" action="$2"
    local repo="${DRM_CONF[REPO_DIR]}"
    local logfile="${DRM_CONF[LOG_DIR]}/$(basename "$script" .sh).log"
    [[ -f "$repo/$script" ]] || die "$(msg "找不到 $repo/$script，请先用「检查安装 / 修复」" 'Script not found; run Check installation / repair first')"

    say ""
    head2 "$action"
    msg "  $script" "  $script"
    msg "  · 屏幕会熄灭数十秒；失败时自动恢复 Android。" \
        "  · The screen goes dark for tens of seconds; failures roll back automatically."
    say ""
    confirm "$(msg '确认开始？' 'Proceed?')" || { say "$(msg '已取消。' 'Cancelled.')"; return 0; }

    # 接管/交还必须要 root：10-01 新容器实测以普通用户跑起来时，mknod/chmod 全被拒，
    # 但安卓显示栈照样被 stop，最后回滚 —— 用户白看几十秒黑屏。脚本侧已加 NEED-ROOT 闸门，
    # 这里负责在 TUI 里把这一步用 sudo 提权后重跑（密码提示由 sudo 给）。
    if [[ "$(id -u)" != 0 ]]; then
        say ""
        msg "  这一步需要 root，将通过 sudo 执行（可能需要输入一次密码）。" \
            "  This step needs root; running via sudo (a password may be required)."
        sudo "$SCRIPT_SRC" --run-round "$script"
        local src=$?
        detect_android_identity; detect_state >/dev/null
        return $src
    fi
    run_round "$script"
}

# run_round —— 真正执行一轮接管/交还（root 侧），并把判据行翻成阶段进度
run_round() {
    local script="$1"
    local repo="${DRM_CONF[REPO_DIR]}"
    local logfile="${DRM_CONF[LOG_DIR]}/$(basename "$script" .sh).log"
    # 阶段表按链选：交还链没有"进入接管"那些判据，拿错表就是一张永远不动的阶段清单
    if [[ "$script" == "$STOP_SCRIPT" ]]; then
        STAGE_ROWS=("${STAGE_ROWS_STOP[@]}")
    else
        STAGE_ROWS=("${STAGE_ROWS_TAKEOVER[@]}")
    fi
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    : >"$logfile" 2>/dev/null || warn "$(msg '日志目录不可写（接管仍会跑，只是这里看不到进度）' 'Log dir not writable; progress will not show here')"

    local -a envargs=()
    drm_conf_bool TAKEOVER_WIFI || envargs+=(SKIP_WIFI=1)
    drm_conf_bool BT_BRIDGE     && envargs+=(BT_BRIDGE=1)
    drm_conf_bool AUDIO_BRIDGE  && envargs+=(AUDIO_BRIDGE=1)
    drm_conf_bool GPUFLOOR      && envargs+=(GPUFLOOR=1)
    drm_conf_bool PERFMAX       && envargs+=(PERFMAX=1)
    # 必须把 LOG_DIR 显式传下去：脚本默认写"仓库同级 logs"，而用户在设置页改过目录的话，
    # 不传就会各写各的，这边进度永远空白（"按了没反应"就是这么来的）。
    envargs+=(LOG_DIR="${DRM_CONF[LOG_DIR]}")

    ( cd "$repo" && env "${envargs[@]}" bash "$repo/$script" ) &
    local child=$!
    sleep 1
    stream_round_log "$logfile" "$child"
    wait "$child"
    local rc=$?
    # 跑完一定要重新识别状态：主按钮是"进入接管/回到安卓"取反的，
    # 只在启动时取一次的话，进完一轮回来按钮还写着"进入 DRM 接管"（点了就是二次接管=09-24 事故形态）。
    detect_android_identity
    detect_state >/dev/null
    say ""
    if (( rc == 0 )); then ok "$(msg '脚本正常结束' 'Script finished')"
    else warn "$(msg "脚本退出码 $rc——详情看 $logfile" 'Exit code '"$rc"'; see '"$logfile"'')"
    fi
    return $rc
}

relaunch_anland() {
    say ""
    head2 "$(msg '重启 anland 会话' 'Restart the anland session')"
    # 不同 rootfs 里 anland 启动脚本位置不同（DroidSpaces 的 KDE 镜像放 /usr/local/bin，
    # 也有发行版放 /usr/bin；全新容器可能根本没有 anland 集成）。
    local starter="" cand
    for cand in /usr/local/bin/startanland-kde.sh /usr/bin/startanland-kde.sh \
                "$(drm_target_home)/.local/bin/startanland-kde.sh" /opt/droidspaces/startanland-kde.sh; do
        [[ -f "$cand" ]] && { starter="$cand"; break; }
    done
    if [[ -z "$starter" ]]; then
        say "$(msg '本容器没有 anland 启动脚本，即未安装 DroidSpaces 的 Linux 桌面集成。' \
                   'This container has no anland launcher, i.e. no DroidSpaces Linux desktop integration.')"
        say "$(msg '  不影响 DRM 接管：直接从菜单选「进入 DRM 接管」。' \
                   '  This does not block DRM takeover: choose Enter DRM takeover from the menu.')"
        return 0
    fi
    msg "  将以桌面用户身份重启 anland（屏幕仍归安卓）：$starter" \
        "  Restarting anland as the desktop user (Android keeps the screen): $starter"
    confirm "$(msg '确认？' 'Proceed?')" || return 0
    local user="${DRM_CONF[DRM_USER]}"
    runuser -u "$user" -- bash -c "nohup $starter > /tmp/anland-restart.log 2>&1 &" 2>/dev/null \
        && ok "$(msg '已拉起（日志 /tmp/anland-restart.log）' 'Relaunched (log /tmp/anland-restart.log)')" \
        || warn "$(msg '拉起失败：此操作需要 root 权限，请使用 sudo drm-tui 重新执行' 'Failed; this step needs root — run drm-tui under sudo')"
}

show_tail_log() {
    local f="${DRM_CONF[LOG_DIR]}/desk-takeover.log"
    [[ -r "$f" ]] || f="${DRM_CONF[LOG_DIR]}/desk-stop.log"
    [[ -r "$f" ]] || { warn "$(msg '还没有日志' 'No log yet')"; return 0; }
    say "$(msg "最近 60 行：$f" 'Last 60 lines: '"$f")"
    tail -n 60 "$f"
    say ""
}

toggle_key() {
    local k="$1"
    [[ "${DRM_CONF[$k]}" == "1" ]] && DRM_CONF[$k]="0" || DRM_CONF[$k]="1"
    drm_conf_save || warn "$(msg '配置需要 root 才能写入：请用 sudo drm-tui 打开设置' 'Config needs root: open settings via sudo drm-tui')"
    say "$(msg "已切换 $k = ${DRM_CONF[$k]}（下次接管生效）" "Toggled $k = ${DRM_CONF[$k]} (applies next round)")"
}

set_adb_endpoints() {
    local v
    v=$(ask "$(msg '无线 adb 地址列表，空格分隔（回车保持当前）' 'Wireless adb addresses, space-separated (Enter keeps current)')" "${DRM_CONF[ADB_ENDPOINTS]}")
    DRM_CONF[ADB_ENDPOINTS]="$v"
    drm_conf_save || warn "$(msg '写入需要 root' 'Needs root to write')"
    say "$(msg "已保存：${v:-（空）}；接管脚本会在本机通道不可用时依次 adb connect 这些地址。" \
               "Saved: ${v:-(empty)}. Takeover tries these addresses when the local channel is unavailable.")"
}

pick_mirror() {
    head2 "$(msg '镜像站测速' 'Mirror probe')"
    detect_json_parser || die "$(msg '缺少 JSON 解析器（需要 jq 或 python3）' 'Need jq or python3')"
    # 探测必须用**真实 tag**：release 的下载 URL 不支持 "latest" 这个字面量，
    # 拿它去拼地址会三源全 404（10-01 实测）。
    local tag="" winner
    local j; j="$(mktemp -t drm-tag.XXXXXX.json)"
    github_api "/repos/$REPO_SLUG/releases/latest" "$j" && tag=$(json_get "$j" ".tag_name")
    rm -f -- "$j"
    if [[ -z "$tag" ]]; then
        warn "$(msg '取不到 release tag，跳过测速（稍后可在设置页重选下载源）' 'Cannot resolve the release tag; skipping the probe')"
        return 1
    fi
    winner=$(pick_fastest_source "$REPO_SLUG" "$tag" "components.lock.json")
    if [[ -z "$winner" ]]; then
        warn "$(msg '三源都不可达，保持当前设置' 'All sources unreachable; keeping current choice')"
        return 1
    fi
    DRM_CONF[DOWNLOAD_SOURCE]="$winner"
    ok "$(msg "已选择：${SRC_LABELS[winner-1]}" 'Selected: '"${SRC_LABELS[winner-1]}")"
    drm_conf_save || true
}

set_log_dir() {
    local v
    v=$(ask "$(msg '日志目录（回车保持）' 'Log directory (Enter keeps current)')" "${DRM_CONF[LOG_DIR]}")
    [[ -n "$v" ]] || return 0
    DRM_CONF[LOG_DIR]="$v"
    mkdir -p "$v" 2>/dev/null
    drm_conf_save || warn "$(msg '写入需要 root' 'Needs root to write')"
    local size
    size=$(du -sh "$v" 2>/dev/null | cut -f1)
    say "$(msg "日志目录＝$v；当前占用 ${size:-0}" 'Log dir = '"$v"'; using '"${size:-0}")"
    say "$(msg '接管期 dmesg 每 20s 收割一份、只留 15 份（脚本自带轮转）；要清旧日志可在此删 logs/harvest。' \
          'The harvester keeps 15 dmesg snapshots; clear logs/harvest to reclaim space.')"
}

pick_language() {
    local v
    v=$(ask "$(msg '界面语言 zh / en / auto（回车保持 auto）' 'Language zh / en / auto')" "${DRM_CONF[UI_LANG]:-auto}")
    case "$v" in zh|en|auto) ;; *) warn "$(msg '只能填 zh / en / auto' 'Allowed: zh / en / auto')"; return 0 ;; esac
    DRM_CONF[UI_LANG]="$v"
    drm_conf_save || true
    [[ "$v" != "auto" ]] && DRM_FORCE_LANG="$v" && detect_language
    ok "$(msg '语言已设置' 'Language set')"
}

settings_page() {
    while :; do
        menu "$(msg '设置' 'Settings')  $(msg '快捷方式' 'shortcuts'):$(drm_conf_get SHORTCUTS) $(msg '输入法' 'keyboard'):$(drm_conf_get INSTALL_KEYBOARD)/$(drm_conf_get KWIN_X11_IM) anland:$(drm_conf_get RELAUNCH_ANLAND)" \
            "$(msg '桌面快捷方式：装 / 撤' 'Desktop shortcuts: install / remove')" \
            "$(msg '输入法与 X11 虚拟键盘支持（定制 kwin）' 'Keyboard and X11 VKB support (patched kwin)')" \
            "$(msg '返回安卓时拉起 anland：当前 $(drm_conf_get RELAUNCH_ANLAND)' 'Relaunch anland on hand-back: currently '"$(drm_conf_get RELAUNCH_ANLAND)")" \
            "$(msg '下载源' 'Download source')" \
            "$(msg '日志目录' 'Log directory')" \
            "$(msg '语言' 'Language')" \
            "$(msg '无线 adb 地址' 'Wireless adb address')" \
            "$(msg '返回' 'Back')"
        case "$MENU_CHOICE" in
            1) toggle_key SHORTCUTS; [[ "${DRM_CONF[SHORTCUTS]}" == "1" ]] && install_shortcuts ;;
            2) toggle_key INSTALL_KEYBOARD; install_keyboard_if_chosen ;;
            3) toggle_key RELAUNCH_ANLAND ;;
            4) pick_mirror ;;
            5) set_log_dir ;;
            6) pick_language ;;
            7) set_adb_endpoints ;;
            8|0) return 0 ;;
        esac
    done
}

advanced_page() {
    menu "$(msg '高级：实验开关（默认全关）' 'Advanced: experimental knobs (all off)')" \
        "$(msg "GPUFLOOR 钉 GPU 顶频（当前 $(drm_conf_get GPUFLOOR)）——实测增益 6~16%，而噪声就有 8.7%，不建议常驻" 'GPUFLOOR: worth ~6-16% while noise is 8.7%')" \
        "$(msg "PERFMAX 全旋钮拉满（当前 $(drm_conf_get PERFMAX)）——die 到 65~69°C、掉电明显，只作跑分" 'PERFMAX: die hits 65-69C; benchmarks only')" \
        "$(msg '返回' 'Back')"
    case "$MENU_CHOICE" in
        1) toggle_key GPUFLOOR ;;
        2) toggle_key PERFMAX ;;
        *) return 0 ;;
    esac
}

check_and_repair() {
    head2 "$(msg '检查安装 / 修复' 'Check installation / repair')"
    local -a todo=()
    [[ -r "$DRM_CONF_FILE" ]]                       || todo+=("config")
    [[ -f "${DRM_CONF[REPO_DIR]}/bin/kwinwrap" ]]    || todo+=("binaries")
    [[ -f "${DRM_CONF[REPO_DIR]}/$TAKEOVER_SCRIPT" ]] || todo+=("takeover-script")
    [[ -e "$TUI_BIN" ]]                              || todo+=("drm-tui-command")
    [[ -f "$(drm_target_home)/Desktop/进入DRM接管.desktop" ]]       || [[ "${DRM_CONF[SHORTCUTS]}" == "0" ]] || todo+=("shortcuts")
    [[ -f "$SUDOERS_FILE" ]]                         || [[ "${DRM_CONF[SHORTCUTS]}" == "0" ]] || todo+=("sudoers")
    [[ -f /usr/local/bin/startanland-kde.sh ]]         || todo+=("runtime-scripts")
    [[ -f /etc/systemd/system/systemd-udevd.service.d/zz-drm-force-udevd.conf ]] || todo+=("systemd-baseline")
    local _dev=""
    _dev=$(drm_adb_target 2>/dev/null) || _dev=""
    if [[ -z "$_dev" ]] || [[ -z "$(timeout 20 adb -s "$_dev" shell "su -c 'test -e /data/local/tmp/argsloop && echo Y'" 2>/dev/null | tr -d '\r')" ]]; then
        todo+=("bridges")
    fi
    local -a miss=(); mapfile -t miss < <(missing_packages)
    (( ${#miss[@]} )) && todo+=("deps(${miss[*]})")
    check_android_root || todo+=("android-root")

    if (( ${#todo[@]} == 0 )); then
        ok "$(msg '安装完整，无需修复' 'Installation is complete')"
        return 0
    fi
    warn "$(msg "需要补：${todo[*]}" 'Needs repair: '"${todo[*]}")"
    confirm "$(msg '现在补装？' 'Repair now?')" || return 0
    local item
    for item in "${todo[@]}"; do
        case "$item" in
            config) drm_conf_save ;;
            binaries|takeover-script) extract_release ;;
            drm-tui-command) install_tui_entry ;;
            shortcuts) install_shortcuts ;;
            sudoers) install_sudoers ;;
            runtime-scripts) install_runtime_scripts ;;
            systemd-baseline) apply_systemd_baseline ;;
            baseline) apply_desktop_baseline ;;
            bridges) deploy_android_bridges ;;
            deps*) install_debs_with_audit $(missing_packages) ;;
            android-root) warn "$(msg '安卓侧 root 仍未授权：执行 adb -s <地址> shell su -c id 并授予 root，再重跑检查' 'Android root still not authorized: run adb -s <address> shell su -c id, grant it root, then re-check')" ;;
        esac
    done
}

check_updates() {
    head2 "$(msg '检查更新' 'Check for updates')"
    detect_json_parser || die "$(msg '需要 jq 或 python3' 'jq or python3 required')"
    local out tag installed
    out="$(mktemp -t drm-up.XXXXXX.json)"
    if github_api "/repos/$REPO_SLUG/releases/latest" "$out"; then
        tag=$(json_get "$out" ".tag_name"); rm -f -- "$out"
        installed="${DRM_CONF[INSTALLED_VERSION]:-未记录}"
        if [[ -n "$tag" ]]; then
            say "$(msg "主仓：本地 $installed → 最新 $tag" 'Main repo: local '"$installed"' → latest '"$tag")"
            [[ "$installed" != "$tag" ]] && say "$(msg '  要升级：设置 → 补装产物（会校验 sha256）' '  To upgrade: Settings → re-fetch artifacts (sha256 verified)')" \
                                          || say "$(msg '  已是最新' '  Already up to date')"
        else
            warn "$(msg 'release 为空或仍是 draft（draft 不进镜像站，也不会被当最新）' 'No published release (drafts are excluded)')"
        fi
    else
        rm -f -- "$out"
        warn "$(msg 'GitHub API 不可达（未认证限速 60 次/小时；可改用镜像源重试）' 'GitHub API unreachable (unauthenticated limit is 60/h; try a mirror)')"
    fi
    say ""
    say "$(msg '定制 kwin 的更新看 anland-kde-packages 的 manifest，不要用 dpkg 判断：' 'For patched kwin use the anland-kde-packages manifest, not dpkg:')"
    say "  $(msg 'bash installer/drm-tui.sh --check-kwin' 'bash installer/drm-tui.sh --check-kwin')"
}

uninstall() {
    head2 "$(msg '卸载' 'Uninstall')"
    warn "$(msg '这会删除：sudoers 白名单、桌面两个 .desktop、图标、drm-tui 命令。' \
           'This removes: sudoers entry, the two desktop files, icons, the drm-tui command.')"
    msg "  不会动：接管仓库本体、已装的 apt 包、deb（键盘/定制 kwin 请各自用 --uninstall 回退）。" \
        "  Kept: the takeover repo itself, apt packages, debs (roll back kwin with its own --uninstall)."
    confirm "$(msg '确认卸载？' 'Confirm uninstall?')" || return 0
    local th; th="$(drm_target_home)"
    rm -f "$th/Desktop/进入DRM接管.desktop" "$th/Desktop/返回安卓.desktop"
    rm -f "$TUI_BIN"
    rm -f "$SUDOERS_FILE" 2>/dev/null || warn "$(msg 'sudoers 需要 root 才能删：sudo rm -f '"$SUDOERS_FILE" 'sudoers needs root: sudo rm -f '"$SUDOERS_FILE")"
    ok "$(msg '已卸载（接管仓库仍在原处）' 'Uninstalled; the takeover repo is untouched')"
}

# ---- 主菜单：按钮随状态取反（用户第 2 条里"最重要的功能"） ----
main_menu() {
    # 每帧重新识别：接管可能在桌面快捷方式那边已经跑起来了，TUI 不能拿启动那一刻的旧状态画按钮。
    detect_android_identity
    detect_state >/dev/null
    clear 2>/dev/null || true
    printf '%bdrm-tui v%s%b — Xiaomi Pad 8 Pro DRM 显示接管\n' "$COLOR_BOLD$COLOR_CYAN" "$VERSION" "$COLOR_RESET"
    printf '  %b设备%b %s (%s)   %b目标%b %s/%s\n' \
        "$COLOR_DIM" "$COLOR_RESET" "${DRM_MODEL:-未知}" "${DRM_PRODUCT:-?}" \
        "$COLOR_DIM" "$COLOR_RESET" "$(detect_distro)" "$(detect_desktop)"
    printf '  %b状态%b %s\n' "$COLOR_DIM" "$COLOR_RESET" "$(state_summary)"
    render_check_line
    sanity_check_state || true
    say ""

    case "$DRM_STATE" in
        drm)
            # 接管轮活着：只给"回到安卓"。这里绝不能出现"再跑一轮接管"的入口。
            menu "" \
                "$(msg '▶ 回到安卓（结束接管，交还显示与网络）' 'Return to Android (hand the panel back)')" \
                "$(msg '查看本轮日志' 'View this round log')" \
                "$(msg '设置' 'Settings')" \
                "$(msg '检查安装 / 修复' 'Check installation / repair')" \
                "$(msg '检查更新' 'Check for updates')" \
                "$(msg '高级（实验开关）' 'Advanced (experimental)')" \
                "$(msg '退出' 'Quit')"
            case "$MENU_CHOICE" in
                1) run_takeover "$STOP_SCRIPT" "$(msg '结束接管、把屏幕和网络交还给安卓' 'Ending takeover, handing display & network back')" ;;
                2) show_tail_log ;;
                3) settings_page ;; 4) check_and_repair ;; 5) check_updates ;;
                6) advanced_page ;; 7|0) exit 0 ;;
            esac ;;
        half-dead)
            warn "$(msg '检测到安卓显示栈已下线、但桌面也没有起来：此刻多半是黑屏。' \
                   'Android display is down but no desktop came up: the screen is probably black.')"
            menu "" "$(msg '▶ 紧急交还：把安卓拉回来' 'Emergency hand-back: bring Android back')" \
                     "$(msg '查看日志找原因' 'Read the log to see why')" "$(msg '退出' 'Quit')"
            case "$MENU_CHOICE" in
                1) run_takeover "$STOP_SCRIPT" "$(msg '紧急交还' 'Emergency hand-back')" ;;
                2) show_tail_log ;; 3|0) exit 0 ;;
            esac ;;
        failed-round)
            # 用户明确要求只给这两个选项（都已在安卓了，不需要"完整交还链"）
            warn "$(msg '上一轮接管没成功：安卓正常，但 Linux 桌面（含 anland）没在跑。' \
                   'Last round failed: Android is fine but no Linux session (anland included) is running.')"
            menu "" \
                "$(msg '▶ 重启 anland 会话（把 Linux 桌面放回安卓里）' 'Restart the anland session')" \
                "$(msg '重试进入 DRM 接管' 'Retry DRM takeover')" \
                "$(msg '查看上一轮日志' 'Read the last round log')" \
                "$(msg '退出' 'Quit')"
            case "$MENU_CHOICE" in
                1) relaunch_anland ;;
                2) run_takeover "$TAKEOVER_SCRIPT" "$(msg '进入 DRM 接管' 'Entering DRM takeover')" ;;
                3) show_tail_log ;; 4|0) exit 0 ;;
            esac ;;
        *)
            menu "" \
                "$(msg '▶ 进入 DRM 接管（停安卓显示栈，Linux 直驱屏幕）' 'Enter DRM takeover (Linux drives the panel)')" \
                "$(msg '回到安卓（交还显示与网络）' 'Return to Android')" \
                "$(msg '查看上一轮日志' 'Read the last round log')" \
                "$(msg '重建 Android 调试通道（adb 授权 / 无线地址）' 'Re-establish the Android debug channel (adb authorization / wireless address)')" \
                "$(msg '设置（组件 / WiFi / anland / 日志 / 语言 / 源）' 'Settings (components, WiFi, anland, log, language, mirror)')" \
                "$(msg '检查安装 / 修复' 'Check installation / repair')" \
                "$(msg '检查更新' 'Check for updates')" \
                "$(msg '高级（实验开关，默认关）' 'Advanced (experimental, all off)')" \
                "$(msg '卸载' 'Uninstall')" \
                "$(msg '退出' 'Quit')"
            case "$MENU_CHOICE" in
                1) run_takeover "$TAKEOVER_SCRIPT" "$(msg '进入 DRM 接管' 'Entering DRM takeover')" ;;
                2) run_takeover "$STOP_SCRIPT" "$(msg '回到安卓' 'Returning to Android')" ;;
                3) show_tail_log ;;
                4) if establish_adb_bridge 1; then ok "$(msg "通道已就绪：$DRM_ADB_DEV" 'Channel ready: '"$DRM_ADB_DEV")"
                   else [[ "$DRM_ADB_STATUS" == "unauthorized" ]] && auth_remedy; fi ;;
                5) settings_page ;; 6) check_and_repair ;;
                7) check_updates ;; 8) advanced_page ;; 9) uninstall ;; 10|0) exit 0 ;;
            esac ;;
    esac
    sleep 0.4
}

# 只读地报定制 kwin 的在位情况（判据不能用 dpkg -V：见 §12.3 的 md5sums 污染陷阱）
check_kwin_patch() {
    # 判据不能用 dpkg -V / md5sums（§12.3：定制 deb 复用 Ubuntu 版本串并抄了原厂 md5sums，三项校验全废）。
    # 也不能写成 grep -q：本文件开了 pipefail，grep 提前关管道会让 strings 吃 SIGPIPE、整条管道判失败
    # ——09-30 就是被这个把"补丁在位"报成"发行版 kwin"的。用 grep -c 读完整份再数。
    local lib
    lib="$(ls /usr/lib/*/libkwin.so.6* 2>/dev/null | grep -v '\.so\.6$' | head -1)"
    [[ -n "$lib" && -r "$lib" ]] || { warn "$(msg '找不到 libkwin6，无法判定补丁状态' 'libkwin6 not found')"; return 1; }
    local hits
    hits=$(strings -a "$lib" 2>/dev/null | grep -c '^PCKEYD_INPUT_SOCKET$')
    if (( ${hits:-0} > 0 )); then
        ok "$(msg "定制 kwin 在位：含 pc-keyd 通道 C 与 IM-showalways（$lib）" 'Patched kwin present')"
    else
        warn "$(msg '当前是发行版 kwin：X11 应用不会弹出虚拟键盘，通道 C 也不可用' 'Stock kwin: X11 apps will not pop the VKB; channel C unavailable')"
    fi
    if [[ -f /var/lib/anland-kde/apt-holds ]]; then
        ok "$(msg 'apt holds 已设（apt 升级不会把补丁版冲掉）' 'apt holds set')"
    else
        warn "$(msg 'apt holds 未设：一次 apt 升级可能把补丁版冲回发行版' 'No apt holds: an upgrade may replace the patched kwin')"
    fi
}

main() {
    detect_language
    init_colors
    case "${1:-}" in
        install) shift; install_flow "$@" ;;
        --version) say "drm-tui $VERSION" ;;
        --check-kwin) load_state; check_kwin_patch ;;
        --run-round) shift; load_state; run_round "$1" ;;
        --check) load_state; check_and_repair ;;
        *) load_state
           # 打开即后台并发跑预检与查更新（dstui 的姿势：菜单先画，结果到了再刷）
           ( run_precheck >"${DRM_CONF[LOG_DIR]}/.precheck.$BASHPID" 2>&1 ) &
           while :; do main_menu; done ;;
    esac
}
main "$@"
