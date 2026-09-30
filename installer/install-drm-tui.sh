#!/usr/bin/env bash
# install-drm-tui.sh — 一次性 bootstrap：给全新容器用的第一条命令。
# 它只做三件事：认机型 → 从镜像站取主仓 release 的 aarch64 tarball → 验 sha256 → 交给 installer/drm-tui.sh install。
# 为什么还需要它、而 dstui 不需要：接管产物里有**必须在 pad 上交叉编译好的二进制**（kwinwrap 等），
# 用户端既没有 libdrm-dev 工具链、也不该为跑一次桌面去装编译依赖，所以走"CI 出 tar、脚本只验不编"。
#
# 规矩照抄 dstui（本机 /usr/local/bin/droidspaces-tui）：三源顺序回退 + 下载后必须比对 release digest。
# 09-30 实测依据：同一个 11.6MB 资产，直连 GitHub 爬到 ~1MB 就 `curl: (92) HTTP/2 PROTOCOL_ERROR`，
# 走 gh-proxy 3 秒完成且 sha256 与 digest 一致 ⇒ 默认源顺序是 proxy → cnb → github。

set -uo pipefail

REPO="${DRM_REPO_SLUG:-Yizhou147/droid-drm-takeover}"
TAG="${DRM_TAG:-latest}"
ASSET="${DRM_ASSET:-drm-takeover-aarch64.tar.gz}"
DEST="${DRM_INSTALL_DIR:-$HOME/Documents/XiaomiPad8Pro-drm-display/droid-drm-takeover}"

say() { printf '%s\n' "$*"; }
die() { printf '✘ %s\n' "$*" >&2; exit 1; }

zh=1
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}" in zh*) zh=1 ;; *) zh=0 ;; esac
m() { if (( zh )); then say "$1"; else say "$2"; fi; }

for tool in curl tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool（需要 coreutils/curl/tar）/ $tool is required"
done

# 机型闸门：认不出 piano 就直接停，别把接管装到别的机器上
if command -v adb >/dev/null 2>&1; then
    product=$(timeout 8 adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')
    if [[ -n "$product" && "$product" != "piano" ]]; then
        die "机型为 $product，本项目只在小米平板 8 Pro（piano）上验证过 / unsupported device: $product"
    fi
    [[ -n "$product" ]] || m "警告：adb 取不到机型，继续（后续预检还会再问一次）" "Warning: cannot read device model via adb; continuing"
else
    m "容器里没有 adb，后续预检会要求先装上（接管与交还都要用它驱动安卓）" \
      "adb is missing; the precheck will require it (takeover drives Android through adb)"
fi

bases=(
    "https://gh-proxy.com/https://github.com/$REPO/releases/download"
    "https://github.com/$REPO/releases/download"
)
want_release_json="$(mktemp -t drm-bootstrap.XXXXXX.json)"
curl --http1.1 -fsSL --connect-timeout 8 --max-time 40 \
    "https://api.github.com/repos/$REPO/releases/${TAG/#latest/latest}" -o "$want_release_json" 2>/dev/null || true
want=$(sed -n 's/.*"digest"[[:space:]]*:[[:space:]]*"sha256:\([0-9a-fA-F]\{64\}\)".*/\1/p' "$want_release_json" | head -1)
tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$want_release_json" | head -1)
rm -f -- "$want_release_json"
[[ -n "$tag" ]] && TAG="$tag"
[[ -n "$want" ]] || m "警告：取不到 release digest，只能装完再手工比对 sha256" \
                    "Warning: no release digest available; verify sha256 manually after download"

tmp="$(mktemp -t drm-tar.XXXXXX.tar.gz)"
ok=0
for base in "${bases[@]}"; do
    m "尝试从 $base 下载 $ASSET" "Trying $base for $ASSET"
    rm -f -- "$tmp"
    curl --http1.1 -fsSL --location --connect-timeout 8 --max-time 300 \
         --speed-time 30 --speed-limit 2048 --retry 2 --retry-all-errors \
         -o "$tmp" "$base/$TAG/$ASSET" || continue
    got=$(sha256sum "$tmp" | awk '{print $1}')
    if [[ -n "$want" && "$got" != "$want" ]]; then
        m "  sha256 不匹配（镜像截断的典型症状），换下一个源" "  sha256 mismatch (mirror truncation); next source"
        continue
    fi
    [[ "$want" == "$got" ]] || m "  已下载（未校验，因无 digest）" "  Downloaded (unverified: no digest available)"
    ok=1
    break
done
(( ok )) || { rm -f -- "$tmp"; die "所有源都取不到 $ASSET / no source served $ASSET"; }

mkdir -p "$(dirname "$DEST")" 2>/dev/null
tar -xzf "$tmp" -C "$(dirname "$DEST")" || die "解包失败 / extraction failed"
rm -f -- "$tmp"
chmod +x "$DEST"/*.sh "$DEST"/scripts/*.sh "$DEST"/installer/*.sh 2>/dev/null || true

m "已就位：$DEST" "Installed to: $DEST"
m "接下来跑这一条（它会先测速、再问你要装哪些组件）：" "Now run this single line (it probes mirrors, then asks what to install):"
say "  bash $DEST/installer/drm-tui.sh install"
