#!/usr/bin/env bash
set -euo pipefail

# Install the Anland Next session package published by build-anland-session.yml.
# The package itself remains owned by apt, dnf, or pacman; this script only
# selects, verifies, and installs the native package for the current system.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_NEXT_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_NEXT_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-session-packages"
readonly MANIFEST_NAME="anland-session-manifest"
readonly CHECKSUMS_NAME="SHA256SUMS"
readonly MAX_MANIFEST_BYTES=$((1024 * 1024))
readonly MAX_CHECKSUMS_BYTES=$((1024 * 1024))
readonly MAX_PACKAGE_BYTES=$((128 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly COMPONENT_STATE_DIR="${DROIDSPACES_COMPONENT_STATE_DIR:-/var/lib/droidspaces-tui/components}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_NEXT_WORK_DIR:-}"
PREPARED_PACKAGE_FILE="${ANLAND_NEXT_PACKAGE_FILE:-}"
UI_LANG="en"
TARGET=""
PACKAGE_TYPE=""
MANIFEST_TARGET=""
ASSET_PREFIX=""
ASSET_SUFFIX=""
PACKAGE_NAME=""
PACKAGE_FILE=""
PACKAGE_VERSION=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
CHECKSUMS_FILE=""
EXPECTED_MANIFEST_SHA256=""
EXPECTED_PACKAGE_SHA256=""
OFFICIAL_RELEASE_METADATA=""
UNINSTALL=false

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    if [[ "$locale_name" == zh* ]]; then
        UI_LANG="zh"
    fi
}

msg() {
    if [[ "$UI_LANG" == zh ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

log() {
    printf '[anland-next] %s\n' "$(msg "$1" "$2")"
}

die() {
    printf '[anland-next] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

record_component_version() {
    local version="$1"
    local state_file="$COMPONENT_STATE_DIR/anland-next.version"
    local temporary_file

    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    mkdir -p -- "$COMPONENT_STATE_DIR" || {
        log "无法记录 Anland Next 版本。" "Could not record the Anland Next version."
        return 0
    }
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录 Anland Next 版本。" "Could not record the Anland Next version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录 Anland Next 版本。" "Could not record the Anland Next version."
}

parse_arguments() {
    local argument

    for argument in "$@"; do
        case "$argument" in
            -1|--1)
                DOWNLOAD_SOURCE="1"
                SKIP_SOURCE_PROBE=true
                ;;
            -2|--2)
                DOWNLOAD_SOURCE="2"
                SKIP_SOURCE_PROBE=true
                ;;
            -3|--3)
                DOWNLOAD_SOURCE="3"
                SKIP_SOURCE_PROBE=true
                ;;
            --uninstall)
                UNINSTALL=true
                ;;
            -h|--help)
                cat <<EOF
用法: $0 [选项]

安装或卸载 Anland Next session 原生软件包。

  -1, --1          使用 GitHub
  -2, --2          使用 gh-proxy.com
  -3, --3          使用 CNB
  --uninstall      卸载 anland-session，不删除发行版依赖
  -h, --help       显示帮助
EOF
                exit 0
                ;;
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || \
        die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_NEXT_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_NEXT_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_NEXT_WORK_DIR=$WORK_DIR" \
        "ANLAND_NEXT_PACKAGE_FILE=$PACKAGE_FILE" \
        "DROIDSPACES_COMPONENT_STATE_DIR=$COMPONENT_STATE_DIR" \
        bash "$script_path" "$@"; then
        status=0
    else
        status=$?
    fi
    cleanup
    exit "$status"
}

detect_target() {
    [[ -r /etc/os-release ]] || \
        die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || \
        die "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    case "$distro_id" in
        arch|archarm)
            TARGET="Arch Linux"
            PACKAGE_TYPE="pkg.tar.*"
            MANIFEST_TARGET="arch"
            ASSET_PREFIX="anland-session-arch-anland-session-"
            ASSET_SUFFIX="-aarch64.pkg.tar.zst"
            ;;
        *)
            [[ -n "$version_id" ]] || \
                die "/etc/os-release 缺少 VERSION_ID。" "/etc/os-release does not contain VERSION_ID."
            case "$distro_id:$version_id" in
                debian:13*)
                    TARGET="Debian 13"
                    PACKAGE_TYPE="deb"
                    MANIFEST_TARGET="debian13"
                    ASSET_PREFIX="anland-session-debian13-anland-session_"
                    ASSET_SUFFIX="_arm64.deb"
                    ;;
                ubuntu:26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_TYPE="deb"
                    MANIFEST_TARGET="ubuntu2604"
                    ASSET_PREFIX="anland-session-ubuntu2604-anland-session_"
                    ASSET_SUFFIX="_arm64.deb"
                    ;;
                fedora:43*)
                    TARGET="Fedora 43"
                    PACKAGE_TYPE="rpm"
                    MANIFEST_TARGET="fedora43"
                    ASSET_PREFIX="anland-session-fedora43-anland-session-"
                    ASSET_SUFFIX=".aarch64.rpm"
                    ;;
                fedora:44*)
                    TARGET="Fedora 44"
                    PACKAGE_TYPE="rpm"
                    MANIFEST_TARGET="fedora44"
                    ASSET_PREFIX="anland-session-fedora44-anland-session-"
                    ASSET_SUFFIX=".aarch64.rpm"
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13、Ubuntu 26.04、Fedora 43/44、Arch Linux。" \
                        "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux."
                    ;;
            esac
            ;;
    esac

    log "已识别系统：${system_name} -> ${TARGET}" \
        "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            die "预编译包仅支持 ARM64/aarch64，当前架构为 $(uname -m)。" \
                "The prebuilt packages support ARM64/aarch64 only; current architecture is $(uname -m)."
            ;;
    esac
}

validate_repository() {
    [[ "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
        die "Release 仓库必须是 owner/repository 格式。" \
            "The Release repository must use the owner/repository format."
}

resolve_release_tag() {
    validate_repository
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_TAG="$ROLLING_RELEASE_TAG"
    fi
    [[ "$RELEASE_TAG" == "$ROLLING_RELEASE_TAG" ]] || \
        die "Release tag 只能是 ${ROLLING_RELEASE_TAG}。" \
            "The Release tag must be ${ROLLING_RELEASE_TAG}."
    log "使用固定滚动 Release：${RELEASE_TAG}" "Using rolling Release: ${RELEASE_TAG}"
}

download_file() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
            "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --waitretry=3 --retry-connrefused \
            -O "$destination" "$url"
    else
        die "未找到 curl 或 wget，无法下载安装包。" \
            "Neither curl nor wget was found; packages cannot be downloaded."
    fi
}

download_stdout() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    else
        die "未找到 curl 或 wget，无法读取 Release 信息。" \
            "Neither curl nor wget was found; Release information cannot be read."
    fi
}

release_download_base() {
    case "$DOWNLOAD_SOURCE" in
        1) printf '%s/%s/releases/download/%s' "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        2) printf '%s/%s/releases/download/%s' "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        3) printf '%s/%s/-/releases/download/%s' "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" ;;
        *) die "下载源选择无效。" "The selected download source is invalid." ;;
    esac
}

download_source_name() {
    case "$1" in
        1) printf 'GitHub' ;;
        2) printf 'gh-proxy.com' ;;
        3) printf 'CNB' ;;
        *) return 1 ;;
    esac
}

download_source_probe_url() {
    case "$1" in
        1) printf '%s/%s/releases/download/%s/%s' \
            "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        2) printf '%s/%s/releases/download/%s/%s' \
            "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        3) printf '%s/%s/-/releases/download/%s/%s' \
            "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME" ;;
        *) return 1 ;;
    esac
}

probe_download_source() {
    local source="$1" probe_url latency probe_status=0
    probe_url="$(download_source_probe_url "$source")" || return 1
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
            --write-out '%{time_total}' "$probe_url" 2>/dev/null)"; then
            awk -v seconds="$latency" 'BEGIN { printf "%.0f ms", seconds * 1000 }'
            return
        else
            probe_status=$?
        fi
    elif command -v wget >/dev/null 2>&1; then
        if timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" wget -q --tries=1 \
            --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url"; then
            printf '%s' "$(msg '可用' 'available')"
            return
        else
            probe_status=$?
        fi
    else
        die "未找到 curl 或 wget，无法测试下载源。" \
            "Neither curl nor wget was found; download sources cannot be tested."
    fi
    if ((probe_status == 28 || probe_status == 124)); then
        printf '%s' "$(msg '超时' 'timeout')"
    else
        printf '%s' "$(msg '不可用' 'unavailable')"
    fi
}

select_download_source() {
    local source latency choice recommendation
    if [[ "$SKIP_SOURCE_PROBE" == true ]]; then
        log "已按参数选择 $(download_source_name "$DOWNLOAD_SOURCE")，跳过延迟测试。" \
            "Selected $(download_source_name "$DOWNLOAD_SOURCE") from the command line; skipping latency checks."
        return
    fi

    log "正在测试下载源延迟（达到 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒视为超时）..." \
        "Testing download-source latency (timeouts at ${SOURCE_PROBE_TIMEOUT_SECONDS} seconds)..."
    for source in 1 2 3; do
        latency="$(probe_download_source "$source")"
        recommendation=""
        [[ "$source" == 3 ]] && recommendation="$(msg '（推荐）' ' (recommended)')"
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$recommendation" "$(msg '延迟' 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        IFS= read -r choice || die "无法读取下载源选择。" "Unable to read a download-source choice."
        case "$choice" in
            1|2|3) DOWNLOAD_SOURCE="$choice"; return ;;
            *) log "请输入 1、2 或 3。" "Enter 1, 2, or 3." ;;
        esac
    done
}

fetch_official_release_metadata() {
    local api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    if ! OFFICIAL_RELEASE_METADATA="$(download_stdout "$api_url")"; then
        log "无法获取 GitHub 官方 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "Could not obtain GitHub's official SHA-256 digest; refusing the third-party mirror package."
        return 1
    fi
}

release_asset_sha256() {
    local requested_name="$1" digest
    if ! digest="$(jq -er --arg name "$requested_name" --arg tag "$RELEASE_TAG" '
        if .tag_name != $tag then error("release tag mismatch")
        else [.assets[] | select(.name == $name) | .digest]
             | if length == 1 then .[0] else error("asset digest is not unique") end
        end
    ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)"; then
        return 1
    fi
    [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_official_manifest_sha256() {
    EXPECTED_MANIFEST_SHA256=""
    [[ "$DOWNLOAD_SOURCE" == 1 ]] && return 0
    command -v jq >/dev/null 2>&1 || die "选择第三方镜像需要 jq。" "jq is required for a third-party mirror."
    command -v sha256sum >/dev/null 2>&1 || die "选择第三方镜像需要 sha256sum。" "sha256sum is required for a third-party mirror."
    fetch_official_release_metadata || return 1
    EXPECTED_MANIFEST_SHA256="$(release_asset_sha256 "$MANIFEST_NAME")" || {
        log "GitHub Release 未提供 ${MANIFEST_NAME} 的 SHA-256 校验值。" \
            "GitHub Release has no valid SHA-256 digest for ${MANIFEST_NAME}."
        return 1
    }
}

resolve_official_package_sha256() {
    EXPECTED_PACKAGE_SHA256=""
    [[ "$DOWNLOAD_SOURCE" == 1 ]] && return 0
    EXPECTED_PACKAGE_SHA256="$(release_asset_sha256 "$PACKAGE_NAME")" || {
        log "GitHub Release 未提供 ${PACKAGE_NAME} 的 SHA-256 校验值。" \
            "GitHub Release has no valid SHA-256 digest for ${PACKAGE_NAME}."
        return 1
    }
}

checksum_sha256_for_asset() {
    local checksums_file="$1" asset_name="$2"

    awk -v asset_name="$asset_name" '
        $1 ~ /^[0-9A-Fa-f]+$/ && length($1) == 64 && NF == 2 {
            name = $2
            sub(/^\*/, "", name)
            if (name == asset_name) {
                digest = tolower($1)
                count += 1
            }
        }
        END {
            if (count == 1) {
                print digest
            } else {
                exit 1
            }
        }
    ' "$checksums_file"
}

prepare_cnb_checksums() {
    local base_url="$1" checksum_size

    [[ "$DOWNLOAD_SOURCE" == 3 ]] || return 0
    CHECKSUMS_FILE="$WORK_DIR/$CHECKSUMS_NAME"
    download_file "$base_url/$CHECKSUMS_NAME" "$CHECKSUMS_FILE" || return 1
    checksum_size="$(stat -c '%s' "$CHECKSUMS_FILE")" || return 1
    [[ "$checksum_size" =~ ^[0-9]+$ && "$checksum_size" -gt 0 && \
       "$checksum_size" -le "$MAX_CHECKSUMS_BYTES" ]] || return 1
    EXPECTED_MANIFEST_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$MANIFEST_NAME")" || {
        log "CNB Release 的 ${CHECKSUMS_NAME} 缺少 ${MANIFEST_NAME} 的唯一 SHA-256 校验值。" \
            "The CNB Release ${CHECKSUMS_NAME} has no unique SHA-256 digest for ${MANIFEST_NAME}."
        return 1
    }
}

resolve_cnb_package_sha256() {
    [[ "$DOWNLOAD_SOURCE" == 3 ]] || return 0
    EXPECTED_PACKAGE_SHA256="$(checksum_sha256_for_asset "$CHECKSUMS_FILE" "$PACKAGE_NAME")" || {
        log "CNB Release 的 ${CHECKSUMS_NAME} 缺少 ${PACKAGE_NAME} 的唯一 SHA-256 校验值。" \
            "The CNB Release ${CHECKSUMS_NAME} has no unique SHA-256 digest for ${PACKAGE_NAME}."
        return 1
    }
}

validate_package_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ && "$1" != *..* ]]
}

resolve_manifest_package() {
    local manifest_file="$1" format release_tag
    local -a selected_names=()

    format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$format" == 1 && "$release_tag" == "$RELEASE_TAG" ]] || return 1
    mapfile -t selected_names < <(
        awk -F= -v key="$MANIFEST_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file"
    )
    [[ "${#selected_names[@]}" -eq 1 ]] || return 1
    PACKAGE_NAME="${selected_names[0]}"
    validate_package_name "$PACKAGE_NAME" || return 1
    case "$PACKAGE_NAME" in
        "${ASSET_PREFIX}"*"${ASSET_SUFFIX}") ;;
        *) return 1 ;;
    esac
}

validate_package_file() {
    local package package_arch package_version package_release package_info
    local package_name package_architecture
    [[ -f "$PACKAGE_FILE" && ! -L "$PACKAGE_FILE" ]] || return 1
    local package_size
    package_size="$(stat -c '%s' "$PACKAGE_FILE")"
    [[ "$package_size" =~ ^[0-9]+$ && "$package_size" -gt 0 && \
       "$package_size" -le "$MAX_PACKAGE_BYTES" ]] || return 1

    case "$PACKAGE_TYPE" in
        deb)
            package="$(dpkg-deb -f "$PACKAGE_FILE" Package)"
            package_arch="$(dpkg-deb -f "$PACKAGE_FILE" Architecture)"
            package_version="$(dpkg-deb -f "$PACKAGE_FILE" Version)"
            [[ "$package" == anland-session && "$package_arch" == arm64 ]] || return 1
            ;;
        rpm)
            IFS=$'\t' read -r package package_arch package_version package_release < <(
                rpm -qp --queryformat '%{NAME}\t%{ARCH}\t%{VERSION}\t%{RELEASE}\n' "$PACKAGE_FILE"
            )
            [[ "$package" == anland-session && "$package_arch" == aarch64 ]] || return 1
            package_version="${package_version}-${package_release}"
            ;;
        pkg.tar.*)
            package_info="$(LC_ALL=C pacman -Qip "$PACKAGE_FILE")"
            package_name="$(sed -n 's/^[[:space:]]*Name[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            package_architecture="$(sed -n 's/^[[:space:]]*Architecture[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            package_version="$(sed -n 's/^[[:space:]]*Version[[:space:]]*:[[:space:]]*//p' <<< "$package_info")"
            [[ "$package_name" == anland-session && "$package_architecture" == aarch64 ]] || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$package_version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 1
    PACKAGE_VERSION="$package_version"
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk find grep mktemp realpath sed sort stat sha256sum; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" \
                "The installer requires the missing command: ${command_name}."
    done
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
        die "未找到 curl 或 wget。" "Neither curl nor wget was found."
    case "$PACKAGE_TYPE" in
        deb)
            command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
            ;;
        rpm)
            command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
            ;;
        pkg.tar.*)
            command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
            ;;
    esac
}

validate_release_asset_checksum() {
    local asset_file="$1" expected_checksum="$2" asset_name="$3" actual_checksum
    actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')"
    if [[ ! "$actual_checksum" =~ ^[0-9a-f]{64}$ || "$actual_checksum" != "$expected_checksum" ]]; then
        log "下载的 ${asset_name} 未通过 SHA-256 校验。" \
            "Downloaded ${asset_name} failed SHA-256 verification."
        return 1
    fi
}

download_packages_once() {
    local base_url manifest_file manifest_size
    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        prepare_cnb_checksums "$base_url" || return 1
    else
        resolve_official_manifest_sha256 || return 1
    fi

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} Anland Next 包..." \
        "Downloading the Anland Next package for ${TARGET} from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    manifest_size="$(stat -c '%s' "$manifest_file")"
    [[ "$manifest_size" =~ ^[0-9]+$ && "$manifest_size" -le "$MAX_MANIFEST_BYTES" ]] || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_manifest_package "$manifest_file" || {
        log "Release 清单中没有 ${TARGET} 的匹配原生包。" \
            "The Release manifest has no matching native package for ${TARGET}."
        return 1
    }
    if [[ "$DOWNLOAD_SOURCE" == 3 ]]; then
        resolve_cnb_package_sha256 || return 1
    else
        resolve_official_package_sha256 || return 1
    fi
    PACKAGE_FILE="$WORK_DIR/$PACKAGE_NAME"
    download_file "$base_url/$PACKAGE_NAME" "$PACKAGE_FILE" || return 1
    if [[ -n "$EXPECTED_PACKAGE_SHA256" ]]; then
        validate_release_asset_checksum "$PACKAGE_FILE" "$EXPECTED_PACKAGE_SHA256" "$PACKAGE_NAME" || return 1
    fi
    validate_package_file || {
        log "下载的软件包不是当前系统的有效 ARM64 anland-session 包。" \
            "The downloaded package is not a valid ARM64 anland-session package for this system."
        return 1
    }
}

download_packages() {
    local attempt
    WORK_DIR="$(mktemp -d -t anland-next.XXXXXXXX)"
    for ((attempt = 1; attempt <= 3; attempt++)); do
        if ((attempt > 1)); then
            rm -rf -- "$WORK_DIR"
            mkdir -m 700 -- "$WORK_DIR"
        fi
        if download_packages_once; then
            return
        fi
        if ((attempt < 3)); then
            log "Release 正在更新或网络暂时失败，准备重试（第 ${attempt} 次）。" \
                "The Release is updating or the network failed; retrying after attempt ${attempt}."
            sleep "$attempt"
        fi
    done
    die "无法稳定获取 Anland Next 软件包，请稍后重试。" \
        "Unable to consistently download the Anland Next package; please try again later."
}

use_prepared_package() {
    local prepared_work_dir prepared_package_file
    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_file="$(realpath -e "$PREPARED_PACKAGE_FILE")" || \
        die "预下载软件包无效。" "The pre-downloaded package is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-next\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_file" == "$prepared_work_dir/"* ]] || \
        die "预下载软件包路径无效。" "The pre-downloaded package path is invalid."
    [[ -d "$prepared_work_dir" && -f "$prepared_package_file" ]] || \
        die "预下载软件包已不存在。" "The pre-downloaded package no longer exists."
    PACKAGE_NAME="${prepared_package_file##*/}"
    validate_package_name "$PACKAGE_NAME" || die "预下载包名无效。" "The pre-downloaded package name is invalid."
    case "$PACKAGE_NAME" in
        "${ASSET_PREFIX}"*"${ASSET_SUFFIX}") ;;
        *) die "预下载软件包与当前系统不匹配。" "The pre-downloaded package does not match this system." ;;
    esac
    WORK_DIR="$prepared_work_dir"
    PACKAGE_FILE="$prepared_package_file"
    validate_package_file || die "预下载软件包校验失败。" "The pre-downloaded package failed validation."
}

package_installed_version() {
    case "$PACKAGE_TYPE" in
        deb) dpkg-query -W -f='${Version}' anland-session 2>/dev/null ;;
        rpm) rpm -q --queryformat '%{VERSION}-%{RELEASE}' anland-session 2>/dev/null ;;
        pkg.tar.*) pacman -Q anland-session 2>/dev/null | awk '{print $2}' ;;
    esac
}

verify_installed_package_version() {
    local installed_version

    installed_version="$(package_installed_version || true)"
    [[ "$installed_version" == "$PACKAGE_VERSION" ]] || \
        die "安装后的 anland-session 版本与下载包不一致（期望 ${PACKAGE_VERSION:-unknown}，实际 ${installed_version:-unknown}）。" \
            "The installed anland-session version does not match the downloaded package (expected ${PACKAGE_VERSION:-unknown}, got ${installed_version:-unknown})."
}

verify_installed_xwayland_paths() {
    local xwayland_binary=/usr/lib/anland/Xwayland

    [[ -x "$xwayland_binary" ]] || \
        die "已安装的 anland-session 缺少 Xwayland：$xwayland_binary。" \
            "The installed anland-session package is missing Xwayland: $xwayland_binary."
    grep -aFq '/usr/share/X11/xkb' "$xwayland_binary" || \
        die "已安装的 Xwayland 没有正确的 /usr XKB 数据路径。请更新 Anland Next 软件包。" \
            "The installed Xwayland has no correct /usr XKB data path. Update the Anland Next package."
    if grep -aFq '/usr/local/share/X11/xkb' "$xwayland_binary" || \
       grep -aFq '/usr/local/bin' "$xwayland_binary"; then
        die "已安装的 Xwayland 仍含错误的 /usr/local 运行时路径。请更新 Anland Next 软件包。" \
            "The installed Xwayland still embeds incorrect /usr/local runtime paths. Update the Anland Next package."
    fi
}

install_deb_package() {
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    log "正在通过 APT 安装 anland-session 并处理依赖..." \
        "Installing anland-session through APT and resolving dependencies..."
    (
        cd "${PACKAGE_FILE%/*}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --allow-downgrades --allow-change-held-packages "./${PACKAGE_FILE##*/}"
    )
    dpkg-query -W -f='${db:Status-Status}' anland-session 2>/dev/null | \
        grep -Fqx installed || die "APT 未安装 anland-session。" "APT did not install anland-session."
}

install_rpm_package() {
    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    log "正在通过 DNF 安装 anland-session 并处理依赖..." \
        "Installing anland-session through DNF and resolving dependencies..."
    dnf install -y --setopt=install_weak_deps=False "$PACKAGE_FILE"
    rpm -q anland-session >/dev/null || die "DNF 未安装 anland-session。" "DNF did not install anland-session."
}

install_arch_package() {
    local pacman_conf
    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    pacman_conf="$(mktemp -t anland-next-pacman.XXXXXXXX)"
    cp -p -- /etc/pacman.conf "$pacman_conf"
    if grep -Eq '^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=' "$pacman_conf"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*LocalFileSigLevel[[:space:]]*=.*/LocalFileSigLevel = Optional/' "$pacman_conf"
    elif grep -qE '^\[options\][[:space:]]*$' "$pacman_conf"; then
        sed -i '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' "$pacman_conf"
    else
        rm -f -- "$pacman_conf"
        die "pacman.conf 缺少 [options] 段。" "pacman.conf has no [options] section."
    fi
    if ! pacman --config "$pacman_conf" -U --noconfirm --needed "$PACKAGE_FILE"; then
        rm -f -- "$pacman_conf"
        die "Arch 软件包安装失败。" "Arch package installation failed."
    fi
    rm -f -- "$pacman_conf"
    pacman -Q anland-session >/dev/null || die "pacman 未安装 anland-session。" "pacman did not install anland-session."
}

refresh_user_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl --user daemon-reload >/dev/null 2>&1; then
        if systemctl --user enable --now anland-session.service >/dev/null 2>&1; then
            log "已刷新、启用并启动 anland-session 用户服务。" \
                "Refreshed, enabled, and started the anland-session user service."
        else
            systemctl --user enable anland-session.service >/dev/null 2>&1 || true
            log "已启用 anland-session 用户服务，但当前未能启动；可稍后运行 systemctl --user restart anland-session.service。" \
                "The anland-session user service was enabled but could not start; run systemctl --user restart anland-session.service later."
        fi
    else
        log "当前没有可用的 systemd 用户总线；软件包已安装，可稍后运行 systemctl --user daemon-reload。" \
            "No systemd user bus is available; the package is installed, and systemctl --user daemon-reload can be run later."
    fi
}

stop_user_service() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl --user disable --now anland-session.service >/dev/null 2>&1 || true
}

uninstall_package() {
    stop_user_service
    case "$PACKAGE_TYPE" in
        deb)
            command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
            if dpkg-query -W -f='${db:Status-Status}' anland-session 2>/dev/null | grep -Fqx installed; then
                DEBIAN_FRONTEND=noninteractive apt-get remove -y anland-session
            else
                log "没有已安装的 anland-session 包。" "No installed anland-session package was found."
            fi
            ;;
        rpm)
            command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
            if rpm -q anland-session >/dev/null 2>&1; then
                dnf remove -y anland-session
            else
                log "没有已安装的 anland-session 包。" "No installed anland-session package was found."
            fi
            ;;
        pkg.tar.*)
            command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
            if pacman -Q anland-session >/dev/null 2>&1; then
                pacman -R --noconfirm anland-session
            else
                log "没有已安装的 anland-session 包。" "No installed anland-session package was found."
            fi
            ;;
    esac
    rm -f -- "$COMPONENT_STATE_DIR/anland-next.version"
    rmdir --ignore-fail-on-non-empty "$COMPONENT_STATE_DIR" 2>/dev/null || true
    log "Anland Next session 已卸载；发行版 Xwayland 和其他依赖未删除。" \
        "Anland Next session was uninstalled; distribution Xwayland and other dependencies were kept."
}

main() {
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        uninstall_package
        return
    fi

    require_runtime_dependencies
    resolve_release_tag

    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_FILE" ]]; then
        [[ -n "$PREPARED_WORK_DIR" && -n "$PREPARED_PACKAGE_FILE" ]] || \
            die "预下载环境变量不完整。" "The pre-downloaded package environment is incomplete."
        use_prepared_package
    else
        select_download_source
        download_packages
    fi
    require_root "$@"

    case "$PACKAGE_TYPE" in
        deb) install_deb_package ;;
        rpm) install_rpm_package ;;
        pkg.tar.*) install_arch_package ;;
    esac
    verify_installed_package_version
    verify_installed_xwayland_paths
    refresh_user_service
    record_component_version "$PACKAGE_VERSION"
    log "Anland Next session 安装完成（${PACKAGE_VERSION:-unknown}）。" \
        "Anland Next session installation completed (${PACKAGE_VERSION:-unknown})."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
