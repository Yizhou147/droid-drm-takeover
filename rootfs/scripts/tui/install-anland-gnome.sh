#!/usr/bin/env bash
set -euo pipefail

# The package archives are deliberately kept out of Git. Override the
# repository when installing packages published by a fork.
readonly DEFAULT_REPOSITORY="Goldzxcbug/droidspaces-package"
readonly RELEASE_REPOSITORY="${ANLAND_GNOME_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_GNOME_RELEASE_TAG:-}"
readonly ROLLING_RELEASE_TAG="anland-gnome-packages"
readonly MANIFEST_NAME="anland-gnome-manifest"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((2 * 1024 * 1024 * 1024))
readonly SOURCE_PROBE_TIMEOUT_SECONDS=2
readonly GITHUB_RELEASE_URL="https://github.com"
readonly GITHUB_API_URL="https://api.github.com"
readonly GH_PROXY_RELEASE_URL="https://gh-proxy.com/https://github.com"
readonly CNB_RELEASE_URL="https://cnb.cool"
readonly APT_HOLD_STATE="/var/lib/anland-gnome/apt-holds"
readonly COMPONENT_STATE_DIR="/var/lib/droidspaces-tui/components"
readonly DESKTOP_CONFIG="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"

WORK_DIR=""
PREPARED_WORK_DIR="${ANLAND_GNOME_WORK_DIR:-}"
PREPARED_PACKAGE_DIR="${ANLAND_GNOME_PACKAGE_DIR:-}"
UI_LANG="en"
TARGET=""
ARCHIVE_PREFIX=""
ARCHIVE_SUFFIX=""
ARCHIVE_NAME=""
ARCHIVE_TARGET=""
PACKAGE_DIR=""
DOWNLOAD_SOURCE=""
SKIP_SOURCE_PROBE=false
EXPECTED_MANIFEST_SHA256=""
EXPECTED_ARCHIVE_SHA256=""
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
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

log() {
    printf '[anland-gnome] %s\n' "$(msg "$1" "$2")"
}

record_component_version() {
    local version="$1" state_file="$COMPONENT_STATE_DIR/gnome.version" temporary_file
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,63}$ ]] || return 0
    if ! mkdir -p -- "$COMPONENT_STATE_DIR"; then
        log "无法记录已安装的 Mutter 版本。" "Could not record the installed Mutter version."
        return 0
    fi
    temporary_file="$(mktemp "$state_file.tmp.XXXXXXXX")" || {
        log "无法记录已安装的 Mutter 版本。" "Could not record the installed Mutter version."
        return 0
    }
    if printf '%s\n' "$version" > "$temporary_file" && \
        chmod 0644 "$temporary_file" && mv -f -- "$temporary_file" "$state_file"; then
        return 0
    fi
    rm -f -- "$temporary_file" || true
    log "无法记录已安装的 Mutter 版本。" "Could not record the installed Mutter version."
    return 0
}

update_desktop_config() {
    local desktop="gnome" config_dir temporary_file line configured_desktop=""
    local desktop_lines=0

    config_dir="$(dirname -- "$DESKTOP_CONFIG")"
    if [[ ! -e "$DESKTOP_CONFIG" && ! -L "$DESKTOP_CONFIG" ]]; then
        if [[ ! -d "$config_dir" ]]; then
            install -d -m 0755 -- "$config_dir" || \
                die "无法创建桌面配置目录。" "Could not create the desktop configuration directory."
        fi
        temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
            die "无法创建临时桌面配置。" "Could not create a temporary desktop configuration."
        if ! printf 'DESKTOP=%s\n' "$desktop" > "$temporary_file" || \
            ! chmod 0644 "$temporary_file" || ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
            rm -f -- "$temporary_file" || true
            die "无法创建桌面配置。" "Could not create the desktop configuration."
        fi
        log "已创建桌面配置：DESKTOP=${desktop}。" \
            "Created the desktop configuration with DESKTOP=${desktop}."
        return
    fi

    if [[ ! -f "$DESKTOP_CONFIG" || -L "$DESKTOP_CONFIG" || ! -r "$DESKTOP_CONFIG" ]]; then
        die "桌面配置不是可安全修改的普通文件：${DESKTOP_CONFIG}。" \
            "The desktop configuration is not a safely writable regular file: ${DESKTOP_CONFIG}."
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            DESKTOP=*)
                configured_desktop="${line#DESKTOP=}"
                ((desktop_lines += 1))
                ;;
        esac
    done < "$DESKTOP_CONFIG"
    if ((desktop_lines != 1)) || \
        [[ ! "$configured_desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]]; then
        die "桌面配置格式无效，未覆盖原文件。" \
            "The desktop configuration is invalid; the original file was not overwritten."
    fi
    if [[ "$configured_desktop" != none ]]; then
        log "保留现有桌面配置：DESKTOP=${configured_desktop}。" \
            "Keeping the existing desktop configuration: DESKTOP=${configured_desktop}."
        return
    fi

    temporary_file="$(mktemp "$config_dir/.droidspaces-desktop.conf.tmp.XXXXXXXX")" || \
        die "无法创建临时桌面配置。" "Could not create a temporary desktop configuration."
    if ! awk -v desktop="$desktop" '
        /^DESKTOP=/ { print "DESKTOP=" desktop; next }
        { print }
    ' "$DESKTOP_CONFIG" > "$temporary_file" || ! chmod 0644 "$temporary_file" || \
        ! mv -f -- "$temporary_file" "$DESKTOP_CONFIG"; then
        rm -f -- "$temporary_file" || true
        die "无法更新桌面配置。" "Could not update the desktop configuration."
    fi
    log "已将桌面配置更新为 DESKTOP=${desktop}。" \
        "Updated the desktop configuration to DESKTOP=${desktop}."
}

die() {
    printf '[anland-gnome] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
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
            *)
                die "不支持的参数：${argument}。可用参数为 -1/--1、-2/--2、-3/--3、--uninstall。" \
                    "Unsupported argument: ${argument}. Valid arguments are -1/--1, -2/--2, -3/--3, and --uninstall."
                ;;
        esac
    done
}

uninstall_gnome() {
    local package candidate
    local -a packages=() package_specs=()
    [[ -s "$APT_HOLD_STATE" ]] || {
        rm -f -- "$COMPONENT_STATE_DIR/gnome.version"
        log "没有 Anland GNOME 安装记录。" "No Anland GNOME installation record was found."
        return 0
    }
    command -v apt-cache >/dev/null 2>&1 || die "未找到 apt-cache。" "apt-cache was not found."
    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v apt-mark >/dev/null 2>&1 || die "未找到 apt-mark。" "apt-mark was not found."
    mapfile -t packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    ((${#packages[@]} > 0)) || die "APT hold 清单为空。" "The APT hold list is empty."
    for package in "${packages[@]}"; do
        candidate="$(apt-cache madison "$package" | awk -F '|' 'NR == 1 {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }')"
        [[ -n "$candidate" ]] || \
            die "找不到 $package 的官方候选版本。" "No distribution candidate was found for $package."
        package_specs+=("$package=$candidate")
    done
    apt-mark unhold "${packages[@]}" >/dev/null
    apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages \
        "${package_specs[@]}"
    rm -f -- "$APT_HOLD_STATE" "$COMPONENT_STATE_DIR/gnome.version"
    rmdir -- "${APT_HOLD_STATE%/*}" 2>/dev/null || true
    log "Anland GNOME 已卸载，发行版 Mutter/Xwayland 已恢复。" \
        "Anland GNOME was uninstalled and distribution Mutter/Xwayland packages were restored."
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

    command -v sudo >/dev/null 2>&1 || die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    local script_path="${BASH_SOURCE[0]}"
    [[ "$script_path" = /* ]] || script_path="$PWD/$script_path"
    local status
    if sudo env \
        "ANLAND_GNOME_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_GNOME_RELEASE_TAG=$RELEASE_TAG" \
        "ANLAND_GNOME_WORK_DIR=$WORK_DIR" \
        "ANLAND_GNOME_PACKAGE_DIR=$PACKAGE_DIR" \
        "DROIDSPACES_DESKTOP_CONFIG=$DESKTOP_CONFIG" \
        bash "$script_path" "$@"; then
        status=0
    else
        status=$?
    fi
    cleanup
    exit "$status"
}

detect_target() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    [[ -n "$version_id" ]] || die "/etc/os-release 缺少 VERSION_ID。" "/etc/os-release does not contain VERSION_ID."
    case "$distro_id:$version_id" in
        debian:13*)
            TARGET="Debian 13"
            ARCHIVE_PREFIX="anland-gnome-debian13-mutter-"
            ARCHIVE_SUFFIX="-arm64.tar.gz"
            ARCHIVE_TARGET="debian13"
            ;;
        ubuntu:26.04*)
            TARGET="Ubuntu 26.04"
            ARCHIVE_PREFIX="anland-gnome-ubuntu2604-mutter-"
            ARCHIVE_SUFFIX="-arm64.tar.gz"
            ARCHIVE_TARGET="ubuntu2604"
            ;;
        *)
            die "不支持当前系统 ${system_name}。仅支持 Debian 13 和 Ubuntu 26.04。" \
                "Unsupported system: ${system_name}. Supported systems are Debian 13 and Ubuntu 26.04."
            ;;
    esac

    log "已识别系统: ${system_name} -> ${TARGET}" "Detected system: ${system_name} -> ${TARGET}"
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

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O "$destination" "$url"
    else
        die "未找到 curl 或 wget，无法下载安装包。" "Neither curl nor wget was found; packages cannot be downloaded."
    fi
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --timeout=20 --waitretry=3 --retry-connrefused -O - "$url"
    else
        die "未找到 curl 或 wget，无法读取 Release 信息。" "Neither curl nor wget was found; Release information cannot be read."
    fi
}

validate_release_tag() {
    case "$RELEASE_TAG" in
        "$ROLLING_RELEASE_TAG") ;;
        *)
            die "Release tag 只能是 ${ROLLING_RELEASE_TAG}。" \
                "The Release tag must be ${ROLLING_RELEASE_TAG}."
            ;;
    esac
}

validate_repository() {
    if [[ ! "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        die "Release 仓库必须是 owner/repository 格式。" \
            "The Release repository must use the owner/repository format."
    fi
}

resolve_release_tag() {
    validate_repository
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_TAG="$ROLLING_RELEASE_TAG"
    fi
    validate_release_tag
    log "使用固定滚动 Release: ${RELEASE_TAG}" "Using rolling Release: ${RELEASE_TAG}"
}

resolve_archive_name() {
    local manifest_file="$1"
    local manifest_format manifest_release_tag selected_name checksum_key checksum_count checksum

    manifest_format="$(awk -F= '$1 == "format" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    manifest_release_tag="$(awk -F= '$1 == "release_tag" { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    [[ "$manifest_format" == "1" && "$manifest_release_tag" == "$RELEASE_TAG" ]] || {
        log "Release 清单格式无效。" "The Release manifest format is invalid."
        return 1
    }

    selected_name="$(awk -F= -v key="$ARCHIVE_TARGET" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")"
    case "$selected_name" in
        "${ARCHIVE_PREFIX}"*"${ARCHIVE_SUFFIX}") ;;
        *)
            log "Release 清单没有 ${TARGET} 的匹配 ARM64 包。" \
                "The Release manifest has no matching ARM64 archive for ${TARGET}."
            return 1
            ;;
    esac
    if [[ ! "$selected_name" =~ ^[A-Za-z0-9._+~_-]+$ || "$selected_name" == *..* ]]; then
        log "Release 清单中的包名无效。" "The archive name in the Release manifest is invalid."
        return 1
    fi

    ARCHIVE_NAME="$selected_name"
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "3" ]]; then
        checksum_key="${ARCHIVE_TARGET}_sha256"
        checksum_count="$(awk -F= -v key="$checksum_key" '$1 == key { count += 1 } END { print count + 0 }' "$manifest_file")" || return 1
        case "$checksum_count" in
            0)
                log "CNB 的旧 Release 清单没有 ${ARCHIVE_NAME} 的 SHA-256；将只执行归档结构和软件包元数据校验。" \
                    "The legacy CNB Release manifest has no SHA-256 for ${ARCHIVE_NAME}; only archive structure and package metadata will be verified."
                ;;
            1)
                checksum="$(awk -F= -v key="$checksum_key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$manifest_file")" || return 1
                [[ "$checksum" =~ ^[0-9A-Fa-f]{64}$ ]] || {
                    log "CNB Release 清单中的 ${ARCHIVE_NAME} SHA-256 无效。" \
                        "The CNB Release manifest has an invalid SHA-256 for ${ARCHIVE_NAME}."
                    return 1
                }
                EXPECTED_ARCHIVE_SHA256="${checksum,,}"
                ;;
            *)
                log "CNB Release 清单中的 ${ARCHIVE_NAME} SHA-256 不唯一。" \
                    "The CNB Release manifest has multiple SHA-256 entries for ${ARCHIVE_NAME}."
                return 1
                ;;
        esac
    fi
    log "已选择 ${ARCHIVE_NAME}" "Selected ${ARCHIVE_NAME}"
}

fetch_official_release_metadata() {
    local api_url

    api_url="${GITHUB_API_URL}/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    if ! OFFICIAL_RELEASE_METADATA="$(download_stdout "$api_url")"; then
        log "无法获取 GitHub 官方 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "Could not obtain GitHub's official SHA-256 digest; refusing the third-party mirror package."
        return 1
    fi
}

release_asset_sha256() {
    local requested_name="$1"
    local digest

    if ! digest="$(jq -er --arg name "$requested_name" --arg tag "$RELEASE_TAG" '
        if .tag_name != $tag then
            error("release tag mismatch")
        else
            [.assets[] | select(.name == $name) | .digest] |
            if length == 1 then .[0] else error("asset digest is not unique") end
        end
    ' <<< "$OFFICIAL_RELEASE_METADATA" 2>/dev/null)"; then
        return 1
    fi
    if [[ ! "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        return 1
    fi

    printf '%s' "${BASH_REMATCH[1],,}"
}

resolve_official_manifest_sha256() {
    EXPECTED_MANIFEST_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    command -v jq >/dev/null 2>&1 || \
        die "选择第三方镜像需要 jq 来校验 GitHub Release。" \
            "Selecting a third-party mirror requires jq to verify the GitHub Release."
    command -v sha256sum >/dev/null 2>&1 || \
        die "选择第三方镜像需要 sha256sum 来校验下载文件。" \
            "Selecting a third-party mirror requires sha256sum to verify downloaded files."
    if ! fetch_official_release_metadata; then
        return 1
    fi
    if ! EXPECTED_MANIFEST_SHA256="$(release_asset_sha256 "$MANIFEST_NAME")"; then
        log "GitHub Release 未提供 ${MANIFEST_NAME} 的 SHA-256 校验值，拒绝使用第三方镜像包。" \
            "GitHub Release did not provide a SHA-256 digest for ${MANIFEST_NAME}; refusing the third-party mirror package."
        return 1
    fi
}

resolve_official_archive_sha256() {
    EXPECTED_ARCHIVE_SHA256=""
    if [[ "$DOWNLOAD_SOURCE" == "1" ]]; then
        return
    fi
    if EXPECTED_ARCHIVE_SHA256="$(release_asset_sha256 "$ARCHIVE_NAME")"; then
        return
    fi
    log "GitHub Release 未提供 ${ARCHIVE_NAME} 的 SHA-256 校验值，拒绝使用第三方镜像包。" \
        "GitHub Release did not provide a SHA-256 digest for ${ARCHIVE_NAME}; refusing the third-party mirror package."
    return 1
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
    local source="$1"

    case "$source" in
        1)
            printf '%s/%s/releases/download/%s/%s' \
                "$GITHUB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        2)
            printf '%s/%s/releases/download/%s/%s' \
                "$GH_PROXY_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        3)
            printf '%s/%s/-/releases/download/%s/%s' \
                "$CNB_RELEASE_URL" "$RELEASE_REPOSITORY" "$RELEASE_TAG" "$MANIFEST_NAME"
            ;;
        *) return 1 ;;
    esac
}

format_latency() {
    local seconds="$1"

    awk -v seconds="$seconds" 'BEGIN { printf "%d ms", (seconds * 1000) + 0.5 }'
}

probe_download_source() {
    local source="$1"
    local probe_url latency started finished probe_status=0
    local -a probe_command

    probe_url="$(download_source_probe_url "$source")" || return 1
    if command -v curl >/dev/null 2>&1; then
        if latency="$(curl -fsSL --connect-timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" \
            --max-time "$SOURCE_PROBE_TIMEOUT_SECONDS" --output /dev/null \
            --write-out '%{time_total}' "$probe_url" 2>/dev/null)"; then
            if awk -v seconds="$latency" -v limit="$SOURCE_PROBE_TIMEOUT_SECONDS" \
                'BEGIN { exit (seconds < limit ? 0 : 1) }'; then
                format_latency "$latency"
                return
            fi
            printf '%s' "$(msg '超时' 'timeout')"
            return
        else
            probe_status=$?
        fi
    elif command -v wget >/dev/null 2>&1; then
        command -v timeout >/dev/null 2>&1 || \
            die "wget 测试下载源需要 timeout 命令以限制为 ${SOURCE_PROBE_TIMEOUT_SECONDS} 秒。" \
                "Testing download sources with wget requires timeout to enforce the ${SOURCE_PROBE_TIMEOUT_SECONDS}-second limit."
        started="$(date +%s%3N 2>/dev/null || true)"
        probe_command=(wget -q --tries=1 --timeout="$SOURCE_PROBE_TIMEOUT_SECONDS" -O /dev/null "$probe_url")
        probe_command=(timeout "$SOURCE_PROBE_TIMEOUT_SECONDS" "${probe_command[@]}")
        if "${probe_command[@]}"; then
            finished="$(date +%s%3N 2>/dev/null || true)"
            if [[ "$started" =~ ^[0-9]+$ && "$finished" =~ ^[0-9]+$ ]]; then
                if (( finished - started < SOURCE_PROBE_TIMEOUT_SECONDS * 1000 )); then
                    printf '%d ms' "$((finished - started))"
                else
                    printf '%s' "$(msg '超时' 'timeout')"
                fi
            else
                printf '%s' "$(msg '可用' 'available')"
            fi
            return
        else
            probe_status=$?
        fi
    else
        die "未找到 curl 或 wget，无法测试下载源。" "Neither curl nor wget was found; download sources cannot be tested."
    fi

    if (( probe_status == 28 || probe_status == 124 )); then
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
        if [[ "$source" == "3" ]]; then
            recommendation="$(msg '（推荐）' ' (recommended)')"
        fi
        printf '%s. %s%s %s: %s\n' "$source" "$(download_source_name "$source")" \
            "$recommendation" "$(msg '延迟' 'latency')" "$latency"
    done

    while :; do
        printf '%s' "$(msg '请输入下载源编号 [1-3]: ' 'Choose a download source [1-3]: ')"
        if ! IFS= read -r choice; then
            die "无法读取下载源选择。请使用 -1/--1、-2/--2 或 -3/--3 指定下载源。" \
                "Unable to read a download-source choice. Specify -1/--1, -2/--2, or -3/--3."
        fi
        case "$choice" in
            1|2|3)
                DOWNLOAD_SOURCE="$choice"
                return
                ;;
            *)
                log "请输入 1、2 或 3。" "Enter 1, 2, or 3."
                ;;
        esac
    done
}

has_packages() {
    local directory="$1"
    compgen -G "$directory/*.deb" >/dev/null
}

require_runtime_dependencies() {
    local command_name
    for command_name in awk du find mktemp realpath sha256sum sort stat tar; do
        command -v "$command_name" >/dev/null 2>&1 || \
            die "缺少运行安装器所需的命令：${command_name}。" \
                "The installer requires the missing command: ${command_name}."
    done

    command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
}

validate_archive_contents() {
    local archive_file="$1"
    local archive_size members entry

    if ! archive_size="$(stat -c '%s' "$archive_file")" || ! [[ "$archive_size" =~ ^[0-9]+$ ]]; then
        log "无法读取下载包的大小。" "Unable to read the downloaded archive size."
        return 1
    fi
    if (( archive_size > MAX_ARCHIVE_BYTES )); then
        log "下载包超过允许的大小。" "The downloaded archive exceeds the allowed size."
        return 1
    fi
    if ! members="$(tar -tzf "$archive_file")" || [[ -z "$members" ]]; then
        log "下载包不是有效的非空 tar.gz 文件。" "The downloaded archive is not a valid non-empty tar.gz file."
        return 1
    fi
    while IFS= read -r entry; do
        case "$entry" in
            /*|.|./*|..|../*|*/.|*/./*|*/..|*/../*)
                log "下载包包含不安全路径。" "The downloaded archive contains an unsafe path."
                return 1
                ;;
            "anland-gnome-packages/${ARCHIVE_TARGET}/"*) ;;
            *)
                log "下载包包含目标系统目录以外的文件。" \
                    "The downloaded archive contains files outside the target system directory."
                return 1
                ;;
        esac
    done <<< "$members"

    if ! LC_ALL=C tar -tvzf "$archive_file" | awk -v maximum="$MAX_EXTRACTED_BYTES" '
        {
            entry_type = substr($1, 1, 1)
            if (entry_type !~ /^[-d]$/ || $3 !~ /^[0-9]+$/) {
                exit 1
            }
            total += $3
            if (total > maximum) {
                exit 1
            }
        }
    '; then
        log "下载包包含不允许的条目，或解压后会超过大小限制。" \
            "The downloaded archive has a disallowed entry or exceeds the extraction size limit."
        return 1
    fi
}

validate_release_asset_checksum() {
    local asset_file="$1"
    local expected_checksum="$2"
    local asset_name="$3"
    local actual_checksum

    if ! actual_checksum="$(sha256sum "$asset_file" | awk '{print $1}')" || \
        ! [[ "$actual_checksum" =~ ^[0-9a-f]{64}$ ]] || \
        [[ "$actual_checksum" != "$expected_checksum" ]]; then
        log "下载的 ${asset_name} 未通过 SHA-256 校验。" \
            "Downloaded ${asset_name} failed SHA-256 verification."
        return 1
    fi
}

validate_package_architecture() {
    local -a files=()
    local file package_arch

    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    for file in "${files[@]}"; do
        package_arch="$(dpkg-deb -f "$file" Architecture)"
        case "$package_arch" in arm64|all) ;; *) return 1 ;; esac
    done

    ((${#files[@]} > 0))
}

download_packages_once() {
    local base_url manifest_file archive_file extracted_size

    base_url="$(release_download_base)"
    manifest_file="$WORK_DIR/$MANIFEST_NAME"
    OFFICIAL_RELEASE_METADATA=""
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_manifest_sha256 || return 1
    fi

    log "正在从 $(download_source_name "$DOWNLOAD_SOURCE") 下载 ${TARGET} 预编译包..." \
        "Downloading ${TARGET} prebuilt packages from $(download_source_name "$DOWNLOAD_SOURCE")..."
    download_file "$base_url/$MANIFEST_NAME" "$manifest_file" || return 1
    if [[ -n "$EXPECTED_MANIFEST_SHA256" ]]; then
        validate_release_asset_checksum "$manifest_file" "$EXPECTED_MANIFEST_SHA256" "$MANIFEST_NAME" || return 1
    fi
    resolve_archive_name "$manifest_file" || return 1
    if [[ "$DOWNLOAD_SOURCE" != "3" ]]; then
        resolve_official_archive_sha256 || return 1
    fi

    archive_file="$WORK_DIR/$ARCHIVE_NAME"
    download_file "$base_url/$ARCHIVE_NAME" "$archive_file" || return 1
    if [[ -n "$EXPECTED_ARCHIVE_SHA256" ]]; then
        validate_release_asset_checksum "$archive_file" "$EXPECTED_ARCHIVE_SHA256" "$ARCHIVE_NAME" || return 1
    fi
    validate_archive_contents "$archive_file" || return 1
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive_file" -C "$WORK_DIR"; then
        log "无法安全解压下载包。" "Unable to safely extract the downloaded archive."
        return 1
    fi

    PACKAGE_DIR="$WORK_DIR/anland-gnome-packages/$ARCHIVE_TARGET"
    has_packages "$PACKAGE_DIR" || {
        log "未能获取 ${TARGET} 的安装包。" "Could not obtain packages for ${TARGET}."
        return 1
    }
    if ! extracted_size="$(du -sb "$PACKAGE_DIR" | awk '{print $1}')" || ! [[ "$extracted_size" =~ ^[0-9]+$ ]] || (( extracted_size > MAX_EXTRACTED_BYTES )); then
        log "解压后的软件包大小无效或超过限制。" \
            "The extracted package size is invalid or exceeds the limit."
        return 1
    fi
    if ! validate_package_architecture; then
        log "下载包中的软件包架构与当前系统不匹配。" \
            "The package architecture in the archive does not match this system."
        return 1
    fi
}

download_packages() {
    local attempt
    WORK_DIR="$(mktemp -d -t anland-gnome.XXXXXXXX)"

    for ((attempt = 1; attempt <= 3; attempt++)); do
        if (( attempt > 1 )); then
            rm -rf -- "$WORK_DIR"
            mkdir -m 700 -- "$WORK_DIR"
        fi
        if download_packages_once; then
            return
        fi
        if (( attempt < 3 )); then
            log "Release 正在更新或网络暂时失败，准备重新获取（第 ${attempt} 次）。" \
                "The Release is being updated or the network failed; retrying after attempt ${attempt}."
            sleep "$attempt"
        fi
    done

    die "无法稳定获取 Release 包，请稍后重试。" \
        "Unable to consistently download the Release package; please retry later."
}

use_prepared_packages() {
    local prepared_work_dir prepared_package_dir

    prepared_work_dir="$(realpath -e "$PREPARED_WORK_DIR")" || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    prepared_package_dir="$(realpath -e "$PREPARED_PACKAGE_DIR")" || \
        die "预下载包目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_work_dir" =~ ^/tmp/anland-gnome\.[A-Za-z0-9]+$ ]] || \
        die "预下载目录无效。" "The pre-downloaded package directory is invalid."
    [[ "$prepared_package_dir" == "$prepared_work_dir/anland-gnome-packages/$ARCHIVE_TARGET" ]] || \
        die "预下载包的目标系统不匹配。" "The pre-downloaded package target does not match this system."
    [[ -d "$prepared_work_dir" && -d "$prepared_package_dir" ]] || \
        die "预下载包已不存在。" "The pre-downloaded package directory no longer exists."

    WORK_DIR="$prepared_work_dir"
    PACKAGE_DIR="$prepared_package_dir"
    has_packages "$PACKAGE_DIR" || die "预下载目录中没有可安装的软件包。" "The pre-downloaded directory has no installable packages."
    validate_package_architecture || \
        die "预下载包中的软件包架构与当前系统不匹配。" "The pre-downloaded package architecture does not match this system."
}

clear_stale_apt_holds() {
    local -a current_packages=("$@") previous_packages=()
    local previous current keep

    [[ -r "$APT_HOLD_STATE" ]] || return 0
    mapfile -t previous_packages < <(sed -nE 's/^([a-z0-9][a-z0-9+.-]*)$/\1/p' "$APT_HOLD_STATE" | sort -u)
    for previous in "${previous_packages[@]}"; do
        keep=false
        for current in "${current_packages[@]}"; do
            if [[ "$previous" == "$current" ]]; then
                keep=true
                break
            fi
        done
        if [[ "$keep" == false ]]; then
            apt-mark unhold "$previous" >/dev/null 2>&1 || true
        fi
    done
}

write_apt_hold_state() {
    install -d -m 0755 "$(dirname "$APT_HOLD_STATE")"
    printf '%s\n' "$@" | sort -u > "$APT_HOLD_STATE"
}

install_deb_packages() {
    local -a files packages
    local file package

    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 deb 包。" "No installable deb packages were found."

    log "正在安装 ${#files[@]} 个 deb 包并自动处理依赖..." \
        "Installing ${#files[@]} deb packages and resolving dependencies..."
    apt-get install -y --allow-downgrades --allow-change-held-packages "${files[@]}"

    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package)"
        [[ -n "$package" ]] && packages+=("$package")
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 deb 包名。" "Could not determine the deb package names."

    clear_stale_apt_holds "${packages[@]}"
    log "正在设置 APT hold..." "Applying APT holds..."
    apt-mark hold "${packages[@]}"
    write_apt_hold_state "${packages[@]}"
    printf '  hold: %s\n' "${packages[@]}"
}

main() {
    local archive_version
    detect_language
    parse_arguments "$@"
    detect_target
    check_architecture
    if [[ "$UNINSTALL" == true ]]; then
        require_root "$@"
        uninstall_gnome
        return
    fi
    require_runtime_dependencies
    resolve_release_tag
    if [[ -n "$PREPARED_WORK_DIR" || -n "$PREPARED_PACKAGE_DIR" ]]; then
        use_prepared_packages
    else
        select_download_source
        download_packages
    fi
    require_root "$@"

    install_deb_packages

    archive_version="${ARCHIVE_NAME#"$ARCHIVE_PREFIX"}"
    archive_version="${archive_version%"$ARCHIVE_SUFFIX"}"
    record_component_version "$archive_version"
    update_desktop_config
    log "安装完成，patched Mutter/Xwayland 已锁定。" \
        "Installation complete; patched Mutter/Xwayland packages are now locked."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
