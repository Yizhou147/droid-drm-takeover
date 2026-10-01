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
# sudo 时 $HOME 是 /root ⇒ 会把整套产物装进 /root/Documents，用户目录那份还是旧的
# （和快捷方式当初被写进 /root/Desktop 同一类事故）。按 SUDO_USER 找真正的用户目录。
_target_home() {
    local u="${SUDO_USER:-}" h
    [[ -n "$u" && "$u" != "root" ]] || { printf '%s' "$HOME"; return; }
    h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    [[ -n "$h" ]] && printf '%s' "$h" || printf '/home/%s' "$u"
}
# 已经装过就别换地方：/etc/drm-takeover.conf 里的 REPO_DIR 是唯一的权威位置（sudo 升级装到别处
# 只会留下两份仓库）。没装过才用默认单目录 ~/drm-takeover。
_existing_repo() {
    local r
    r=$(sed -n 's/^REPO_DIR="\(.*\)"$/\1/p' /etc/drm-takeover.conf 2>/dev/null | head -1)
    [[ -n "$r" ]] && printf '%s' "$r" || return 1
}
DEST="${DRM_INSTALL_DIR:-$(_existing_repo 2>/dev/null || printf '%s' "$(_target_home)/drm-takeover")}"

say() { printf '%s\n' "$*"; }
die() { printf '✘ %s\n' "$*" >&2; exit 1; }

zh=1
case "${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}" in zh*) zh=1 ;; *) zh=0 ;; esac
m() { if (( zh )); then say "$1"; else say "$2"; fi; }

for tool in curl tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool（需要 coreutils/curl/tar）/ $tool is required"
done

# 机型闸门：认不出 piano 就直接停，别把接管装到别的机器上。
# 必须逐地址试：这台机器同时挂着本机通道与无线通道，裸 `adb shell` 会报
# "more than one device/emulator" → product 为空 → 闸门形同不存在（把非 piano 设备放过去）。
if command -v adb >/dev/null 2>&1; then
    product=""
    while IFS= read -r dev; do
        [[ -n "$dev" ]] || continue
        p=$(timeout 8 adb -s "$dev" shell getprop ro.product.device 2>/dev/null | tr -d '\r')
        [[ -n "$p" ]] || continue
        if [[ "$p" != "piano" ]]; then
            die "机型为 $p，本项目只在小米平板 8 Pro（piano）上验证过 / unsupported device: $p"
        fi
        product="$p"
        break
    done < <(timeout 12 adb devices 2>/dev/null | awk '$2=="device"{print $1}')
    [[ -n "$product" ]] || m "提示：未能读取设备型号（Android 调试通道尚未就绪），此处跳过；安装前的环境检查会再次校验并给出具体状态。" \
                    "Note: device model unavailable (Android debug channel not ready); skipped here and re-checked before install."
else
    m "未检测到 adb：接管与交还均需通过 adb 驱动 Android，安装前的环境检查会要求安装它。" \
      "adb not found: takeover and hand-back drive Android through adb; the pre-install check requires it."
fi

bases=(
    "https://gh-proxy.com/https://github.com/$REPO/releases/download"
    "https://github.com/$REPO/releases/download"
)
want_release_json="$(mktemp -t drm-bootstrap.XXXXXX.json)"
curl --http1.1 -fsSL --connect-timeout 8 --max-time 40 \
    "https://api.github.com/repos/$REPO/releases/${TAG/#latest/latest}" -o "$want_release_json" 2>/dev/null || true
# digest 必须**按资产名选**。release 的 assets 数组里第一个是 components.lock.json，
# 拿"JSON 里出现的第一个 digest"去比 tar，会把完好的包判成镜像截断
# （10-01 真实测试第一跑就栽在这：gh-proxy 下回来的文件 sha 与 CI digest 逐字相等，
# 却被假阳性拒掉，最后报"所有源都取不到"）。
want=""
tag=""
if [[ -s "$want_release_json" ]] && command -v python3 >/dev/null 2>&1; then
    tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("tag_name",""))' "$want_release_json" 2>/dev/null)
    want=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
for a in d.get("assets", []):
    if a.get("name") == sys.argv[2]:
        print((a.get("digest") or "").split(":")[-1])
        break
' "$want_release_json" "$ASSET" 2>/dev/null)
else
    # 没有 python3 时宁可"不校验但明说"，也绝不拿别的资产的 digest 当好包的判据
    tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$want_release_json" | head -1)
fi
rm -f -- "$want_release_json"
[[ -n "$tag" ]] && TAG="$tag"
[[ -n "$want" ]] || m "警告：取不到该资产的 release digest，装完请手工比对 sha256" \
                    "Warning: no digest for this asset; verify sha256 manually after download"

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

# 解包不能假设 tar 的根目录名等于 DEST 名：产物根叫 drm-takeover，
# 而目标目录按仓库名是 droid-drm-takeover —— 直接 -C 到父目录会解到别处，
# 表现为"下载校验都过了， DEST 却是空的"（10-01 真实测试第二跑撞上的）。
work="$(mktemp -d -t drm-unpack.XXXXXXXX)"
tar -xzf "$tmp" -C "$work" || { rm -rf -- "$work"; die "解包失败 / extraction failed"; }
rm -f -- "$tmp"
inner="$work/drm-takeover"
[[ -d "$inner" ]] || inner="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)"
[[ -d "$inner" ]] || { rm -rf -- "$work"; die "tar 里没有预期目录 / tar has no expected directory"; }
mkdir -p "$DEST" || die "建不了 $DEST / cannot create $DEST"
cp -a "$inner"/. "$DEST"/ || die "铺文件失败 / copy failed"
rm -rf -- "$work"
chmod +x "$DEST"/*.sh "$DEST"/scripts/*.sh "$DEST"/installer/*.sh 2>/dev/null || true
# 以 root 跑时 cp -a 会把整棵目录变成 root 属主，用户之后自己跑 drm-tui 就写不动了
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$DEST" 2>/dev/null || m "  注意：$DEST 属主没能改回 $SUDO_USER" \
                                                       "  Note: ownership of $DEST was not restored to $SUDO_USER"
fi

m "已就位：$DEST" "Installed to: $DEST"
m "接下来跑这一条（它会先测速、再问你要装哪些组件）：" "Now run this single line (it probes mirrors, then asks what to install):"
say "  bash $DEST/installer/drm-tui.sh install"
