#!/bin/bash

# 禁止 apt 在执行过程中弹出交互式配置界面，适用于无人值守构建。
export DEBIAN_FRONTEND=noninteractive

# 停止服务、卸载挂载点和修改 apt 配置都需要 root 权限。
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行：sudo bash nosnap.sh"
  exit 1
fi

echo "[nosnap] 正在停止 snapd 服务"
# 某些精简 RootFS 中可能没有 systemctl，因此先检查命令是否存在。
# stop 终止当前进程，disable 防止 snapd 在下次启动时再次运行。
if command -v systemctl >/dev/null 2>&1; then
  for unit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] 正在卸载 Snap 挂载点"
# 删除 snapd 文件前先卸载其 loop/bind 挂载，避免目录仍被占用。
# sort -r 让较深的子挂载点优先卸载；-l/-f 用于处理容器中的残留挂载。
if command -v mount >/dev/null 2>&1 && command -v umount >/dev/null 2>&1; then
  for mountpoint in $(mount | awk '$3 ~ "^/snap" || $3 ~ "^/var/snap" || $3 ~ "^/var/lib/snapd" { print $3 }' | sort -r); do
    umount -lf "$mountpoint" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] 正在清除 snapd 软件包"
# 仅处理已经安装的软件包，避免 apt 因找不到可删除目标而中断构建。
# 同时移除 GNOME Software、Discover 等桌面环境中的 Snap 后端。
if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
  for package in snapd gnome-software-plugin-snap snapd-desktop-integration plasma-discover-backend-snap; do
    if dpkg -s "$package" >/dev/null 2>&1; then
      apt-get purge -y "$package" >/dev/null 2>&1 || true
    fi
  done
  apt-get autoremove -y --purge >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
fi

echo "[nosnap] 正在清理 Snap 残留"
# 清理卸载软件包后仍可能保留的挂载目录、缓存、用户数据和 systemd 单元。
rm -rf \
  /snap \
  /var/snap \
  /var/lib/snapd \
  /var/cache/snapd \
  /usr/lib/snapd \
  /etc/systemd/system/snapd* \
  /etc/apt/apt.conf.d/*snap* \
  "$HOME/snap" \
  /home/*/snap

echo "[nosnap] 正在阻止 APT 重新安装 snapd"
# 使用负优先级阻止后续依赖解析重新安装 snapd 及桌面集成组件。
# Ubuntu 的 chromium-browser 是用于拉取 Chromium Snap 的过渡包，也一并屏蔽。
mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
Package: snapd snapd-desktop-integration gnome-software-plugin-snap plasma-discover-backend-snap
Pin: release a=*
Pin-Priority: -10

Package: chromium-browser
Pin: release o=Ubuntu
Pin-Priority: -10
EOF

# 确认 pin 配置成功落盘；缺少它会导致后续 apt 操作重新引入 Snap。
if [ ! -f /etc/apt/preferences.d/nosnap.pref ]; then
  echo "[nosnap] 写入 APT 锁定配置失败"
  exit 1
fi

echo "[nosnap] 正在添加 ppa:xtradeb/apps"
# XtraDeb 提供部分 Ubuntu 软件的传统 deb 包，可替代只提供 Snap/过渡包的来源。
# 优先使用 UBUNTU_CODENAME，并兼容只提供 VERSION_CODENAME 的系统。
xtradeb_codename=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  xtradeb_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
fi

# 下载文本并输出到标准输出，供 API 查询和仓库可用性探测使用。
download_stdout() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    return 1
  fi
}

# 下载内容到指定文件；优先使用 curl，在精简环境中回退到 wget。
download_file() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" > "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    return 1
  fi
}

# 通过读取仓库 Release 文件判断指定 Ubuntu 代号是否已被 PPA 发布。
release_exists() {
  download_stdout "$1" >/dev/null 2>&1
}

if [ -n "$xtradeb_codename" ]; then
  xtradeb_key=""
  xtradeb_source_codename=""
  xtradeb_api="https://api.launchpad.net/1.0/~xtradeb/+archive/ubuntu/apps"
  xtradeb_candidates="$xtradeb_codename"

  # 新 Ubuntu 版本刚发布时 PPA 可能尚未建立对应仓库，此处按由新到旧的
  # 顺序回退到兼容版本，避免整个 RootFS 构建因此失败。
  case "$xtradeb_codename" in
    resolute)
      xtradeb_candidates="$xtradeb_codename questing plucky noble"
      ;;
    questing)
      xtradeb_candidates="$xtradeb_codename plucky noble"
      ;;
    plucky|oracular)
      xtradeb_candidates="$xtradeb_codename noble"
      ;;
  esac

  # 从 Launchpad API 动态获取签名密钥指纹，避免在脚本中硬编码可能轮换的密钥。
  xtradeb_key="$(download_stdout "$xtradeb_api" 2>/dev/null | awk -F'"' '/signing_key_fingerprint/ { print $4; exit }')"

  # 选择候选列表中第一个实际存在 Release 元数据的仓库代号。
  for candidate in $xtradeb_candidates; do
    xtradeb_release="https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu/dists/${candidate}/Release"
    if release_exists "$xtradeb_release"; then
      xtradeb_source_codename="$candidate"
      break
    fi
  done

  if [ -n "$xtradeb_source_codename" ] && [ -n "$xtradeb_key" ]; then
    mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
    # 密钥下载失败时立即删除空文件，防止 apt 将其误认为有效 keyring。
    download_file "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${xtradeb_key}" /etc/apt/keyrings/xtradeb-apps.asc 2>/dev/null || rm -f /etc/apt/keyrings/xtradeb-apps.asc

    if [ -s /etc/apt/keyrings/xtradeb-apps.asc ]; then
      chmod 0644 /etc/apt/keyrings/xtradeb-apps.asc
      # signed-by 将该仓库的信任范围限制在专用密钥文件内。
      echo "deb [signed-by=/etc/apt/keyrings/xtradeb-apps.asc] https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu ${xtradeb_source_codename} main" > /etc/apt/sources.list.d/xtradeb-apps.list
      if [ "$xtradeb_source_codename" != "$xtradeb_codename" ]; then
        echo "[nosnap] ppa:xtradeb/apps 未发布 ${xtradeb_codename}，改用 ${xtradeb_source_codename}"
      fi
    else
      echo "[nosnap] 获取 XtraDeb 签名密钥失败，跳过 ppa:xtradeb/apps"
    fi
  else
    echo "[nosnap] ppa:xtradeb/apps 不支持 ${xtradeb_codename} 或网络不可用，已跳过"
  fi
else
  echo "[nosnap] 无法检测 Ubuntu 代号，跳过 ppa:xtradeb/apps"
fi

echo "[nosnap] 处理完成"
