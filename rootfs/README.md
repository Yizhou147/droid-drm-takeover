中文 | [English](README_english.md)

# Droid RootFS Builder

为 Xiaomi Pad 8 Pro（`piano`）构建 Droidspaces 容器 rootfs：**Ubuntu 26.04 + KDE Plasma**，
用户名可自定义，构建全部在 GitHub Actions 云端完成。

本目录是从 [Droidspaces-rootfs-KDE-builder](https://github.com/Yizhou147/Droidspaces-rootfs-KDE-builder)
移植而来的收窄版本：上游能选 7 个发行版 × 5 种桌面 × 14 个附加开关，这里只留四个表单项，
其余开关钉死在机型预设文件里。

## 前提

本目录是 `droid-drm-takeover` 仓库的子目录，构建在**该仓库的 Actions** 上跑
（workflow 文件必须留在仓库根的 `.github/workflows/build-rootfs.yml`，构建文件都在这里）。
仓库根的 `.github/workflows/release.yml` 打包接管产物用的是显式清单，不会把本目录塞进接管 tar。

## 构建表单（只有四项）

在仓库的 Actions → 构建 RootFS（piano / Ubuntu-26 / KDE）→ Run workflow：

| 表单项 | 类型 | 可选值 / 默认 |
|---|---|---|
| 机型 | choice | 仅 `piano` |
| 发行版 | choice | 仅 `Ubuntu-26` |
| 自定义用户名 | string | 默认 `xyz`；1–32 位，字母或下划线开头，仅 `[A-Za-z0-9_-]` |
| 桌面 | choice | 仅 `KDE` |

其余开关**不出现在表单里**，全部取自 `presets/<机型>.env`。

## piano 预设

`presets/piano.env` 是这些开关的唯一取值处（值 = 上游中文 workflow 默认值）：

| 开关 | 值 | 说明 |
|---|---|---|
| `DESKTOP_AUTOSTART` | `true` | 容器起来即进 KDE |
| `DISPLAY_BACKEND_INPUT` | `anland-wayland` | Anland 后端为默认；此模式下脚本会把 `PulseAudio` 自动降为 `none`（Anland 自带音频通道），与上游行为一致。**piano 必须保持此值**——定制 kwin 补丁靠它才装得进 rootfs，见下节 |
| `PulseAudio` | `socket` | 仅 X11 后端时生效 |
| `ENABLE_zh_tz` | `true` | 中文 locale + 上海时区 |
| `ENABLE_mesa` | `true` | 骁龙 GPU（kgsl/Mesa）支持 |
| `ENABLE_8gen2_wayland` | `false` | piano 是 SM8750 / Adreno 830，不需要 8 Gen 2 的 Turnip UBWC 花屏修复 |
| `ENABLE_nosnap` | `true` | 移除 Snap/snapd 并阻止 APT 重装 |
| `ENABLE_srf` | `true` | fcitx5 输入法 |
| `ENABLE_yj` | `true` | NAT 与安卓/Droidspaces 硬件识别 |
| `ENABLE_zip` | `true` | 常用压缩工具 |
| `ENABLE_binfmt` | `false` | 跨架构支持 |
| `ENABLE_kfgj` | `false` | 开发工具链 |
| `ENABLE_docker` | `false` | rootfs 内装 Docker |
| `ENABLE_systemd257` | `false` | 旧内核 systemd 257 兼容（实验性） |
| `ANLAND_RELEASE_REPOSITORY` | `Goldzxcbug/droidspaces-package` | Anland KDE 包来源 |

以下一项**不属上游那 14 个开关**，是本项目加的：

| 开关 | 值 | 说明 |
|---|---|---|
| `ENABLE_drmtui` | `true` | 出厂预装接管 drmtui，见下节 |

换机型 = 新增一个 `presets/<新机型>.env` 并把机型名加进 workflow 的 `options`。

## rootfs 自带已装好的 drmtui

`piano` 的 rootfs 出厂就带着**已经装完**的 DRM 接管（`drmtui` 命令、接管脚本与二进制、桌面基线、
快捷方式、sudoers），不是躺一个没跑过的安装脚本。

实现方式：`Ubuntu-26.Dockerfile` 末尾一段**带标注的追加块**（上游无此段），
`ENABLE_drmtui=true` 时取 `droid-drm-takeover` 最新 release 的 `install-drm-tui.sh` 铺好产物，
再跑该仓库的 `installer/drm-tui.sh --preinstall-offline`。

`--preinstall-offline` 只跑安装流程里**不依赖真机**的五步：选下载源、apt 依赖、
接管产物并校验 sha256、写配置/快捷方式/sudoers/`drmtui` 命令、写桌面基线。
安装流程里剩下三步在 Docker 构建环境里根本做不到，脚本**不会假装做了**：

| 步骤 | 为什么构建期做不了 | 谁来完成 |
|---|---|---|
| 建立 Android 调试通道 | 容器里没有设备的 adb 通道 | 设备上首次 `drmtui` |
| 机型闸门（`ro.product.device == piano`） | 要真机才读得到属性 | 同上 |
| 部署安卓侧桥产物（音频 sink / 蓝牙桥） | 要往 `/data/local/tmp` push | 同上 |

这三项由设备上第一次运行 `drmtui` 的「检查安装 / 修复」自动列出并补齐。
追加块结尾有两条硬判据（`/usr/local/bin/drmtui` 存在、`desk-takeover.sh` 落位），
不通过则整个 rootfs 构建失败——不会出一个"以为装好了"的镜像。

⚠ **自指要知道**：本目录就在 `droid-drm-takeover` 仓库里，而预装取的是该仓库 **`releases/latest` 已发布的产物**，
不是触发构建的那个提交。改完 `installer/` 或接管脚本后要先发版（覆盖/新 tag 重出资产），
再跑 rootfs 构建，否则镜像里装到的是上一个 release。

## piano 必带定制 kwin 补丁

选 `piano` 就等于要带上打过补丁的 kwin（anland 后端 + pc-keyd 通道 C，接管轮的 X11 虚拟键盘与组合键靠它）。
这条链在构建期就完成，不需要装完再补：`DISPLAY_BACKEND=anland-wayland` 时
`Ubuntu-26.Dockerfile` 会跑 `install-anland-desktop kde` → `install-anland-kde`，
它按 `/etc/os-release` 认出 `ubuntu:26.04`，取 `anland-kde-ubuntu2604-kwin-*` 资产装上并锁住包版本。

CI 用两道闸保证它不会被静默跳过：

1. **构建前**：`piano` 的预设里 `DISPLAY_BACKEND_INPUT` 若不是 `anland-wayland`，直接失败——
   换走 x11 后端就不装补丁，等于出货未打补丁的 rootfs。
2. **产物里实测**：从 `.tar.xz` 解出 `libkwin.so.6.*`，`grep -c PCKEYD_INPUT_SOCKET` 必须命中
   （判据与 `droid-drm-takeover` 安装器的 `kwin_patch_present()` 同源；不用 `strings`，
   全新环境没有 binutils，只信二进制里的符号）。不通过就不出 Release。

## 产物

- 文件名：`piano-Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-Runs<N>.tar.xz`
- 版本号取 Actions 运行号（`Runs<N>`），不是表单项
- 同时上传 workflow artifact（保留 30 天）与 Release 资产；Release 会**自动从草稿转为公开**
  （草稿不进 `releases/latest`、也不进镜像，主项目安装器现问 `releases/latest`）
- Release 说明与任务汇总里给出文件名的 `sha256`

## 文件来源与上游同步

`scripts/` 整目录（28 个文件）**逐字复制**自上游 `2fc5ef2`，md5 一致；
`Ubuntu-26.Dockerfile` 同样复制自上游，**只多两段带标注的追加**（drmtui 预装的 2 个 `ARG` 与文末那段 `RUN`），
除此之外逐字未动。刻意不做裁剪式复制：Dockerfile 第 35–56 行逐条 `COPY scripts/...`，
裁文件就得改 Dockerfile 的既有内容，既引入构建期断链风险，也让同步上游变成逐文件比对。
代价只是带上本组合用不到的脚本，而其中多数（`droidspaces-tui`、`install-mesa` 等）本来就要装进 rootfs 当运行时工具。

本目录**相对上游的改动**：

1. `build_rootfs.sh`（上游名 `build_rootfs-native.sh`）三处：
   开关缺省值改 `: "${VAR:=默认}"` 以接受机型预设（命令行 `-X` 仍优先）、产物名加 `${DEVICE_MODEL}-` 前缀、
   构建摘要多打机型与用户名两行
2. `Ubuntu-26.Dockerfile` 仅追加：`ARG ENABLE_drmtui_ARG`、`ARG DRMTUI_REPO_SLUG`、文末 drmtui 预装块
3. 新增：`presets/piano.env`、`.github/workflows/build-rootfs.yml`、本 README 一对

其余 6 个 `*.Dockerfile`、`build_rootfs-qemu-aarch64.sh`、上游 `docs/` 未复制。

同步上游：在 `~/Documents/Droidspaces-rootfs-KDE-builder` 里 `git pull`，重新复制 `scripts/` 与 Dockerfile
（Dockerfile 复制完要把两段追加块挪回去），再对 `scripts/` 做 md5 比对、对 Dockerfile 做 `diff` 比对
——**diff 结果应只剩那两段标注过的追加**。上游仓库根没有 LICENSE 文件，本目录不臆造许可声明，只注明代码来源。

## 预装所依赖的本仓库改动

`--preinstall-offline` 落在本仓库两处（`67a745a`，**已本地提交、尚未推送**）：

- `installer/drm-tui.sh`：新增 `--preinstall-offline` 入口与 `preinstall_offline_flow()`
- `installer/lib/conf.sh`：`drm_conf_defaults` 认 `DRM_PREINSTALL_USER`

第二条是必须的：构建期是 root 且没有 `SUDO_USER`/`logname`，按原推导会把装机目标算成 `root`，
整套产物与快捷方式全落进 `/root`，出厂镜像里那个真实用户（`xyz`）什么也没有。

## 状态

功能**尚未在真机构建上验证过**：开发容器内没有 docker，本地只做到脚本语法检查、
`bash installer/drm-tui.sh --version` 的入口冒烟、YAML 解析，以及用 docker 桩子核对组装出的
15 个 `--build-arg` 取值（含 `ENABLE_drmtui_ARG=true`）。
下面这些都要等 CI 真跑一次才算验完：产物里的用户名与家目录、`drmtui` 命令与接管产物落位、
桌面基线生效、定制 kwin 补丁命中、以及设备上首次 `drmtui` 能否把剩三步补齐。
