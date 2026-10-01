#!/usr/bin/env bash
# common.sh — drm-tui 的显示/交互/提权底座。被 installer 与运行期 TUI 共同 source。
# 约定（全部来自本项目踩过的坑）：
#   · 单行命令纪律：给用户的补救命令一律单独一行，不串 &&、不用续行。
#   · 每条"OK"必须打到它声称的对象身上（工作总结 §7：pgrep kwinwrap 当"plasma 起来了"的判据=永远真）。
#   · 任何长耗时动作都要让用户看见"现在在第几步、卡在哪"，静默等待=用户以为死机。

readonly DRM_TUI_VERSION="0.1.0"
readonly DRM_CONF_FILE="${DRM_CONF_FILE:-/etc/drm-takeover.conf}"
readonly DRM_STATE_DIR="/var/lib/drm-tui"

UI_LANG="en"
COLOR_RESET="" COLOR_BOLD="" COLOR_BLUE="" COLOR_CYAN="" COLOR_GREEN=""
COLOR_YELLOW="" COLOR_RED="" COLOR_DIM=""
DRM_LOG_FILE="${DRM_LOG_FILE:-}"

init_colors() {
    [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]] || return 0
    COLOR_RESET=$'\033[0m' COLOR_BOLD=$'\033[1m' COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m' COLOR_GREEN=$'\033[32m' COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m' COLOR_DIM=$'\033[2m'
}

detect_language() {
    case "${DRM_FORCE_LANG:-}" in
        zh) UI_LANG="zh"; return 0 ;;
        en) UI_LANG="en"; return 0 ;;
    esac
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    [[ "$locale_name" == zh* ]] && UI_LANG="zh"
}

# msg <中文> <English> —— 与 dstui 同一姿势：一条字符串对两种语言，永不出现半中半英。
msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${2:-$1}"
    fi
}

log_line() {
    [[ -n "$DRM_LOG_FILE" ]] || return 0
    printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$DRM_LOG_FILE" 2>/dev/null || true
}

say()   { printf '%s\n' "$*"; }
ok()    { printf '  %b✔%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; log_line "OK $*"; }
warn()  { printf '  %b!%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"; log_line "WARN $*"; }
fail()  { printf '  %b✘%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*"; log_line "FAIL $*"; }
info()  { printf '  %b·%b %s\n' "$COLOR_DIM" "$COLOR_RESET" "$*"; }
head2() { printf '\n%b%s%b\n' "$COLOR_BOLD$COLOR_BLUE" "$*" "$COLOR_RESET"; }

die() {
    fail "$*"
    [[ -n "${DRM_TMP_DIR:-}" && -d "${DRM_TMP_DIR:-}" ]] && rm -rf -- "$DRM_TMP_DIR"
    exit 1
}

# step <编号> <总数> <中文> <English> —— 啰嗦模式的骨架：每一步都先报"在干什么"再干。
# 用户明确要求：不要像老脚本那样"进程一晃就过去、不知道跑了什么、卡在哪"。
step() {
    # 缺第 4 个参数时不能直接写 ${4}：set -u 下会当场"未绑定的变量"退出，
    # 而且是在 printf 的子命令里炸，结果连步骤名都被吞掉，用户只看到 [1/7] 后面空白
    # （10-01 新容器实测就是这个现象）。
    local idx="${1:-0}" total="${2:-0}" zh="${3:-}" en="${4:-${3:-}}"
    printf '%b[%d/%d]%b %s\n' "$COLOR_CYAN" "$idx" "$total" "$COLOR_RESET" "$(msg "$zh" "$en")"
}

# require_root <script-path> —— 非 root 时自己 sudo 重跑。
# 不能"申请权限"：sudoers 白名单本身需要 root 才能写，所以这里只能重跑；
# 图形 konsole 下 sudo 会弹密码提示，用户体验是"多敲一次密码"，不需要退出再来一遍。
# 注意 Ubuntu 默认 tty_tickets：不同终端的 sudo 计时不共享，这是正常现象不是 bug。
require_root() {
    [[ "$(id -u)" -eq 0 ]] && return 0
    local script="$1"; shift
    if [[ "${DRM_REINVOKED:-}" == "1" ]]; then
        die "$(msg '提权后仍不是 root，无法继续。' 'Still not root after elevation; cannot continue.')"
    fi
    command -v sudo >/dev/null 2>&1 || die "$(msg '需要 root，但本机没有 sudo。' 'root is required but sudo is missing.')"
    say "$(msg '此步骤需要 root 权限，将通过 sudo 重新执行（可能需要输入一次密码）。' 'This step requires root; re-executing via sudo (a password may be required).')"
    DRM_REINVOKED=1 exec sudo -- "$script" "$@"
}

# ask <提示> <默认值> —— 读一行；非交互（DRM_ASSUME_YES）时直接给默认值。
ask() {
    local prompt="$1" default="${2:-}" reply=""
    # 提示必须写到 stderr：调用方普遍写 `v=$(ask …)`，命令替换会把 stdout 全吃进返回值——
    # 提示语一起进去以后，菜单比较、配置赋值全部失真（本函数所有调用者都中招，10-01 才发现）。
    printf '%s [%s]: ' "$prompt" "$default" >&2
    if [[ "${DRM_ASSUME_YES:-0}" == "1" ]] || ! [[ -t 0 ]]; then
        printf '%s\n' "$default"; return 0
    fi
    IFS= read -r reply || return 1
    printf '%s' "${reply:-$default}"
}

# ask_yes <中文> <English> <默认 Y/N> —— 一次只问一件事，回车走默认值。
ask_yes() {
    local reply
    # 默认值标记由 ask() 自己渲染成 "[Y]"，这里不要再拼 [Y/n]（否则提示会出现两遍后缀）
    reply=$(ask "$(msg "$1" "$2")" "${3:-Y}")
    [[ "${reply,,}" != "n" && "${reply,,}" != "no" ]]
}

# 读完一屏内容后必须停住等回车：否则调用方一 return，主菜单立刻 clear 重绘，
# 用户看到的就是"字闪了一下就没了"（10-01 用户实测反馈，检查更新那屏就是这么看不见的）。
pause() {
    [[ -t 0 ]] || return 0          # 非交互（管道/脚本）里不停，否则直接把流程卡死
    printf '%s\n' "${1:-$(msg '按回车返回菜单' 'Press Enter to go back')}" >&2
    read -r _ || true
}

confirm() {
    local prompt="$1"
    [[ "${DRM_ASSUME_YES:-0}" == "1" ]] && return 0
    local reply
    reply=$(ask "${prompt} [y/N]" "n")
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# menu <标题> <条目1> <条目2> ... —— 编号菜单；返回用户选的序号（1..n）到全局 MENU_CHOICE。
# 用编号而不是方向键高亮：本项目的终端是安卓里的 konsole/串口，转义序列不可靠，
# 而 dstui 也是同一套"画一遍 + 读一行"的做法。
MENU_CHOICE=""
menu() {
    local title="$1"; shift
    local i=0 line
    printf '\n%b%s%b\n' "$COLOR_BOLD" "$title" "$COLOR_RESET"
    for line in "$@"; do
        i=$((i + 1))
        if [[ "$line" == *@DISABLED ]]; then
            line="${line%@DISABLED}"
            printf '  %b%d)%b %s\n' "$COLOR_DIM" "$i" "$COLOR_RESET" "$line"
        else
            printf '  %b%d)%b %s\n' "$COLOR_CYAN" "$i" "$COLOR_RESET" "$line"
        fi
    done
    local reply
    reply=$(ask "$(msg '请输入编号' 'Number')" "0") || { MENU_CHOICE="0"; return 1; }
    [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= i )) || { MENU_CHOICE="0"; return 1; }
    MENU_CHOICE="$reply"
}

# with_spinner <中文> <English> <cmd...> —— 长任务期间的打点，避免"看起来死了"。
with_spinner() {
    local zh="$1" en="$2"; shift 2
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏') i=0 rc=0
    if [[ -t 1 ]]; then
        (
            while :; do
                printf '\r  %b%s%b %s   %b%s%b' "$COLOR_CYAN" "${frames[i % 10]}" "$COLOR_RESET" \
                    "$(msg "$zh" "$en")" "$COLOR_DIM" "$(date +%S)s" "$COLOR_RESET"
                sleep 0.2; i=$((i + 1))
            done
        ) &
        local sp=$!
        "$@"; rc=$?
        kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
        printf '\r\033[K'
    else
        say "  $(msg "$zh" "$en")"
        "$@"; rc=$?
    fi
    return $rc
}

# human_time <seconds>
human_time() {
    local s="${1:-0}"
    if (( s < 60 )); then printf '%ds' "$s"
    else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}
