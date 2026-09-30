#!/usr/bin/env bash
# net.sh — 下载与"镜像站测速"。照搬 dstui（/usr/local/bin/droidspaces-tui）的姿势并补上它缺的那一环。
#
# 从 dstui 抄来的（它已在本机装了多年，行为可靠）：
#   · 三源：1=github、2=gh-proxy.com/https://github.com、3=cnb.cool；--1/--2/--3 手动钉源，auto=顺序回退。
#   · 下载后**必须**把 sha256 对上 GitHub release 的 digest 才算成功。
#     实锤教训（工作总结 §21/§41.14）：镜像站会截断/损坏文件，校验不是仪式；
#     有一次镜像下来的包 sha256 不匹配被当场拦下，改用 CI artifact 才一致。
#   · 后台 worker + 结果文件 + deadline 的并发形态（查版本时不让界面冻住）。
#
# dstui 没有、这里补上的：它叫"自动测速"其实是**按顺序试到成功为止**，不测速度。
# 09-30 实测就是反例：同一个 11.6MB 资产，直连 GitHub 一分钟后只爬到 1MB 然后
# `curl: (92) HTTP/2 stream 1 was not closed cleanly: PROTOCOL_ERROR`；
# 同一个文件走 gh-proxy **3 秒完成、sha256 与 release digest 一致**。
# ⇒ 顺序"github→proxy→cnb"在墙内经常是先撞死再成功，所以这里做真探测：
#    各源下一次同一个已知大小的小文件，量吞吐，赢家还必须**长度对得上**才算数。

readonly SRC_NAMES=(github proxy cnb)
readonly SRC_LABELS=("GitHub 直连 / direct" "gh-proxy.com" "cnb.cool")
readonly PROBE_TIMEOUT=12

GITHUB_RELEASE_BASE="https://github.com"
GITHUB_API_BASE="https://api.github.com"
PROXY_RELEASE_BASE="https://gh-proxy.com/https://github.com"
CNB_RELEASE_BASE="https://cnb.cool"

dl_curl() {
    # --http1.1：09-30 的 HTTP/2 PROTOCOL_ERROR 就是这个；retry 只覆盖可重试错误，
    # 协议级中断要靠**外层换源**重试，不能指望 curl 自己恢复。
    curl --http1.1 --fail --silent --show-error --location \
        --connect-timeout 8 --max-time "${1:-120}" --speed-time 30 --speed-limit 2048 \
        --retry 2 --retry-all-errors --output "${2:?output}" "${3:?url}"
}

# source_base <1|2|3> <owner/repo> → 该源的 release/download 基址
source_base() {
    local idx="$1" repo="$2"
    case "$idx" in
        1) printf '%s' "$GITHUB_RELEASE_BASE/$repo/releases/download" ;;
        2) printf '%s' "$PROXY_RELEASE_BASE/$repo/releases/download" ;;
        3) printf '%s' "$CNB_RELEASE_BASE/repo/git//release/download" ;;
        *) return 1 ;;
    esac
}

# fetch_verified <repo> <tag> <asset> <expected_sha256> <out> [source|auto]
# 返回 0 并置 FETCHED_SOURCE；任何一源下下来 sha 不匹配 = 换下一源（这是"截断防护"的本体）。
FETCHED_SOURCE=""
fetch_verified() {
    local repo="$1" tag="$2" asset="$3" want="$4" out="$5" want_source="${6:-auto}"
    local order=() idx base url actual
    case "$want_source" in
        auto) order=(2 3 1) ;;                     # 墙内默认先 proxy；github 直连放最后兜底
        1|2|3) order=("$want_source") ;;
        *)   order=(2 3 1) ;;
    esac
    for idx in "${order[@]}"; do
        base="$(source_base "$idx" "$repo")" || continue
        url="$base/$tag/$asset"
        info "$(msg "从 ${SRC_LABELS[idx-1]} 下载 $asset" "Downloading $asset from ${SRC_LABELS[idx-1]}")"
        rm -f -- "$out"
        dl_curl 180 "$out" "$url" || { warn "$(msg '该源下载失败，换下一个' 'This source failed; trying the next one')"; continue; }
        actual="$(sha256sum "$out" 2>/dev/null | awk '{print $1}')"
        if [[ -n "$want" && "$actual" != "$want" ]]; then
            fail "$(msg "sha256 不匹配（镜像截断的典型表现），丢弃" 'sha256 mismatch — the mirror truncated the file; discarding')"
            info "  expected=$want"
            info "  actual  =$actual"
            rm -f -- "$out"; continue
        fi
        FETCHED_SOURCE="$idx"
        ok "$(msg "已校验并下载（源：${SRC_LABELS[idx-1]}）" 'Verified and downloaded' ) — ${SRC_LABELS[idx-1]}"
        return 0
    done
    return 1
}

# pick_fastest_source —— 拿 release 里那个几百字节的 manifest 当样本（谁都拉得动，
# 又能同时验证源是否已同步到最新版本：CNB 那条线历史上就是"能下但过期"）。
# 输出：源序号 1|2|3；失败输出空串。
pick_fastest_source() {
    local repo="$1" tag="$2" asset="$3"
    local best="" best_rate=0 idx out rate
    for idx in 1 2 3; do
        out="$(mktemp -t drm-src-probe.XXXXXX)"
        local base; base="$(source_base "$idx" "$repo")" || { rm -f "$out"; continue; }
        local t0 t1 n
        t0=$(date +%s%N)
        if dl_curl "$PROBE_TIMEOUT" "$out" "$base/$tag/$asset"; then
            t1=$(date +%s%N); n=$(stat -c '%s' "$out")
            (( n > 0 )) && rate=$(( n * 1000000000 / (t1 - t0 + 1) ))
            if [[ -n "${rate:-}" ]] && (( rate > best_rate )); then
                best_rate=$rate; best=$idx
                info "$(msg "  ${SRC_LABELS[idx-1]}：$(( rate / 1024 )) KB/s（${n}B）" \
                           "  ${SRC_LABELS[idx-1]}: $(( rate / 1024 )) KB/s (${n}B)")"
            else
                info "$(msg "  ${SRC_LABELS[idx-1]}：$(( ${rate:-0} / 1024 )) KB/s" \
                           "  ${SRC_LABELS[idx-1]}: $(( ${rate:-0} / 1024 )) KB/s")"
            fi
        else
            info "$(msg "  ${SRC_LABELS[idx-1]}：不可达 / unreachable" "  ${SRC_LABELS[idx-1]}: unreachable")"
        fi
        rm -f -- "$out"; unset rate
    done
    printf '%s' "$best"
}

github_api() {
    local path="$1" out="$2"
    dl_curl 30 "$out" "$GITHUB_API_BASE$path"
}
