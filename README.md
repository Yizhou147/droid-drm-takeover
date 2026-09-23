# Droid DRM Takeover

在安卓设备上直接接管它的 DRM/KMS 显示，让一个**原生 Linux 桌面（KWin + Plasma）跑在平板的真实面板上**——
3200x2136@120、触摸可用、不 ROOT 改内核、**不魔改一行 Mesa**。

> ⚠️ 目前只在 **Xiaomi Pad 8 Pro（codename `piano`，Adreno 830 / msm_geni_serial，内核 6.6.118-android15）** 上完整验证过。
> 其他设备需要按"设备适配"一节重新探测对象 ID 和串口/固件参数，风险自负（最坏情况：需要长按电源强重启）。

## 它解决什么问题

在安卓上跑 Linux 图形（Termux/容器方案）通常只有一条路：把帧**转发**回安卓 SurfaceFlinger 合成上屏
（Anland、Droidspaces 都是这个架构，Droidspaces 甚至刻意剪掉了 card 节点来防止绕过）。
本项目证明了另一条路：**Linux 侧合成器直接从 KMS 手里抢到面板的所有权**，安卓整套图形栈原地退场，
帧路径零拷贝零转发，延迟只取决于 KMS 提交本身。

## 核心原理（为什么不需要动 Mesa）

难点从来不在 GPU 用户态驱动，而在**谁能往屏上提交**：

1. **master 的真相** —— `DRM master` 并不在内核或 surfaceflinger 手里，而是被安卓侧
   `vendor.qti.hardware.display.composer` HAL 进程持有。`adb shell su` 里 `stop` + 显式
   `setprop ctl.stop vendor.qti.hardware.display.composer`（注意：`stop` 不动 `class hal`，必须点名）
   → master 自然空闲。
2. **藏了节点而已** —— 小米只是把 `/dev/dri/card0` 从文件系统里删了，驱动仍在内核里活着。
   主设备号从 sysfs 读出后 `mknod` 重建即可，无需任何驱动改动。
3. **kwinwrap 交接仪式** —— 自制的 setuid 桥（`src/kwinwrap.c`）以 root 完成：
   拿 master → **预清理安卓遗留 atomic 状态**（释放它占用的 plane/CRTC、把 connector DPMS 拉回 On）
   → `DROP_MASTER` → setuid/setgid 降权到普通用户 → `exec kwin_wayland`。
   之后 kwin 用 **stock GBM + EGL + atomic commit** 驱动面板，全程普通用户权限。
4. **GPU 走现成路** —— `MESA_LOADER_DRIVER_OVERRIDE=kgsl` 让 EGL/drm 拿不到 wl_drm fd 时直接开
   `/dev/kgsl-3d0`；kgsl 的 bo"只进不出"（无导出 ioctl）恰好不影响这个方向：显示端分配、GPU 导入渲染，
   瓶颈在 KMS 提交侧（实测 TEST 51ms + flip 28ms 量级，与 GL 驱动无关）。

一句话：**把"递交上屏的权力"（master + atomic 状态）从安卓手里合法接过来，渲染链路一个字都不改。**

## 踩坑精华（每条都值一天时间）

- **彻底断网根因**：接管后 SF 停 ~120s，安卓 system_server watchdog 会杀 system_server，init 级联
  SIGKILL wpa_supplicant/netd/zygote → WiFi 掉线且 UI 不可用，只能强重启。对策：接管前解除
  watchdog（`watchdog_timeout`/`nativehang`/`stay_on`）+ wake_lock 钉住；**接管与回滚脚本都必须与
  将被它们杀掉的 GUI 栈脱钩**（setsid 后台 + pgrep 验证重试 + `fuser -k /dev/dri/card0` 兜底；
  我们被这事咬了两次：desk-stop 和 desk-takeover 从桌面终端启动时，杀掉 kwin 的瞬间终端连带
  脚本一起死，安卓又已 stop → 两头全黑）。
- **双桌面共享 HOME，全局环境改动必须两边回归**：DRM 桌面的虚拟键盘要求 Qt 直连合成器 text-input，
  为此删了全局 `/etc/environment` 的 `QT_IM_MODULE=fcitx5`——结果 anland（帧转发方案）的安卓 IME
  桥恰恰依赖 Qt 走 fcitx5 桥，中文选词后只剩前缀字母（Chrome 不受影响）。修复=在 anland launcher
  里**会话级**注入 `QT_IM_MODULE=fcitx5`（并把 fcitx5 守护起在同一 dbus 总线），全局保持干净。
- **触摸验证禁旁听**：对触摸节点跑 `getevent` 会触发小米安全联动直接断网（多次实锤）。触摸链路一律
  只让 kwin 一个读者，用 `bin/touchtest` 打点日志验证。
- **虚拟键盘**：kwin 6.6 的 `zwp_input_method_v1` 只对 kwin 自己拉起的 IM 可见——配置
  `setInputMethodCommand` 让 kwin 自动 exec plasma-keyboard；`/etc/environment` 里的
  `QT_IM_MODULE=fcitx5` 会把 Qt 的 text-input 抢走导致键盘永不弹出，必须清掉。
- **PC 键盘/拼音/组合键**：桌面输入体验的增强（全尺寸 PC 布局、中文拼音、uinput 组合键守护
  pc-keyd）已拆分为独立项目 [droid-pc-keyboard](https://github.com/Yizhou147/droid-pc-keyboard)；
  本仓库的 `desk-takeover.sh` 只负责在接管会话里把它拉起来（daemon 装在 `/usr/local/bin`）。
- **任务栏打不开应用**：`xdg-desktop-portal` 必须带 `XDG_CURRENT_DESKTOP=KDE` 起来才有 KDE 后端。
- **换网零配置**：接管前先从安卓动态读取当前连接的 SSID/PSK（`cmd wifi status` +
  `WifiConfigStore.xml`）自动生成 wpa 配置；dhcpcd 拿到租约后再动态探测网关/网段，注入安卓遗留的
  **table 1015**（安卓没有 `lookup main`，全部 fwmark 到 1015）。而且网络段是**纯尽力而为**：
  关联/出口失败只打警告，绝不再回滚连坐已上屏的桌面。
- **plasmashell 硬依赖 kactivitymanagerd，别赌 dbus 自动激活**：接管会话里激活超时 → shell 直接
  `Aborting shell load`，现象是"kwin 活着、触摸在收、面板有模式，但整屏纯黑"。必须显式拉起
  kactivitymanagerd（记得给 `QT_QPA_PLATFORM=wayland`，否则 Qt 找不到平台插件又自杀）并等
  `org.kde.ActivityManager` 上总线后再起 plasmashell。
- 其余对象 ID 漂移（conn/crtc/plane 每次 boot 都变）、vendor vblank 时间戳为 0、`TEST` 返 -22 噪音等，
  见 docs；kwin.log 里 `Failed to open drm node: ""` 是节点发现噪音，**不代表软件渲染**
  （实测 Mesa/Vulkan 完整，vkmark 1w+ 分）。

## 设备要求

- 安卓侧：可 ROOT（KernelSU/Magisk），高通平台（本项目为 composer HAL 停法，其他平台需调整）
- Linux 容器：Ubuntu (aarch64)，KWin 6.6 + Plasma 6.x，`libdrm/libwayland` 开发包，`wpa_supplicant`、`dhcpcd`
- 一条稳定的安卓控制通道（本项目用 adb over 本机转发，容器内 `adb connect`；不依赖 WiFi）

## 快速开始

```
make                       # 编译 bin/ 下全部工具与探针
cp configs/desk-wifi.conf.example /root/desk-wifi.conf   # 填你自己的 SSID/PSK（此文件永不入库）
sudo bash desk-takeover.sh # 全自动：停安卓 → kwin 接管 → Plasma 桌面 → 容器接管 WiFi
sudo bash scripts/desk-stop.sh   # 全自动还给安卓（可与桌面快捷方式/sudoers 白名单配合）
```

单轮短窗口验证用 `drm-takeover.sh`（接管 ~150s 自动恢复），常驻用 `PERSIST=1 MODE=kwin`。

## 目录结构

```
desk-takeover.sh        全自动接管：显示+桌面+WiFi（推荐入口）
drm-takeover.sh         单轮/常驻接管（无桌面或仅 kwin），带自动回滚
scripts/                desk-stop / drm-stop / kwin-restart / keepbright / dmesg-harvester
src/                    kwinwrap(核心) + 一批 atomic/drm/udev 探针 + touchdraw/touchtest/touchinj
configs/                desk-wifi.conf.example
docs/tools.md           全部编译产物的用法手册
Makefile                一次 make 编全部，无需 wayland-scanner（协议桩已随仓库生成）
```

## 工具速览

`make` 产出 18 个二进制，**日常全自动、不需要手动跑任何一个**；按角色分三类：

- **接管核心**（脚本内部调用）：`kwinwrap`（master 交接桥，心脏）、`setbright`/`setprop`（点亮屏幕）、`atomicspy`（录制每次 atomic 提交）。
- **触摸验证**（替代被厂商安全策略禁止的 getevent 旁听）：`touchtest`（合成器链路画板）、`touchdraw`（裸 atomic 直绘）、`touchinj`（假触摸注入）、`udevprobe`/`udevmatch`（动态找触摸节点）。
- **KMS 诊断探针**（新设备适配用）：`rawprobe`、`drmatomic`、`atombisect`、`connprops`、`planecrtc`、`informats`、`crtcstate`、`masterprobe`、`stageprobe`、`replicate`、`kwinprobe`。

每个工具的用法与新设备适配最短路径 → [docs/tools.md](docs/tools.md)。

运行日志默认写到仓库**同级**的 `logs/` 目录（可用 `LOG_DIR=...` 覆盖），与真实 WiFi 配置一样不进版本库。

## 风险提示

接管期间安卓整套 UI/网络栈是停摆的，脚本有回滚逻辑但**不承诺所有异常路径都能自愈**；
最坏情况是长按电源强制重启（数据不会丢，但当前未保存工作会丢）。首次上机请保证：
电量 >50%、有人在现场、且你不介意重启一次。

## License

GPLv3（GNU General Public License v3，全文见 [LICENSE](LICENSE)）。
