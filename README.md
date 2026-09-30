中文 | [English](README_english.md)

# Droid DRM Takeover

在 Android 设备上，由容器内的原生 Linux 桌面（KWin + Plasma）直接取得面板的 DRM/KMS 所有权，
不经 Android SurfaceFlinger 合成与转发。帧路径零拷贝，延迟仅取决于 KMS 提交本身。

已在 **Xiaomi Pad 8 Pro**（codename `piano`，SM8750 / Adreno 830，内核 6.6.118-android15，HyperOS）
完整验证：3200x2136@120 直驱、多点触摸、蓝牙外设、接管轮内音频外放、容器直管 WiFi。

> ⚠️ 仅在上述设备完整验证。其他设备必须按 [docs/tools.md](docs/tools.md) 的适配流程重新探测
> DRM 对象与参数；已知最坏后果是长按电源强制重启（数据不丢，未保存的工作会丢）。

## 工作原理

难点不在 GPU 用户态驱动（渲染链路零改动），而在**由谁向面板提交**：

1. **DRM master 的归属** —— master 由 Android 侧
   `vendor.qti.hardware.display.composer` HAL 持有（而非 surfaceflinger）。`adb shell su` 中
   `stop` 之外必须显式 `setprop ctl.stop vendor.qti.hardware.display.composer`
   （`stop` 不作用于 `class hal`，需按名停止）→ master 空闲。
2. **节点缺失而非驱动缺失** —— 厂商仅从文件系统移除 `/dev/dri/card0`，驱动仍在内核中。
   主/从设备号从 sysfs 现读后 `mknod` 重建即可，无需任何内核改动。
3. **kwinwrap 交接** —— `src/kwinwrap.c` 以 root 完成：取得 master → 预清理 Android 遗留的
   atomic 状态（释放其占用的 plane/CRTC、connector DPMS 恢复 On）→ `DROP_MASTER` →
   按 `KWINWRAP_UID/GID` 降权 → `exec kwin_wayland`。此后 kwin 以普通用户权限经
   stock GBM/EGL + atomic commit 驱动面板。
4. **GPU 使用容器现有 Mesa 栈** —— kwin 经 `renderD128` 走 stock Mesa
   （实测 renderer 为 `zink Vulkan 1.4 (Adreno, MESA_TURNIP)`，由 `GPU-WHICH` 探针判定）。
   **严禁注入 `MESA_LOADER_DRIVER_OVERRIDE=kgsl` 等 Mesa 环境变量**：kgsl 的缓冲区无导出
   ioctl，无法向 KMS 提供 dmabuf，注入后 kwin 一帧都无法送出（09-25 实测纯黑，已回退，
   见 `desk-takeover.sh` 内注释）。判定是否软件渲染的唯一判据是 `glxinfo -B` 的 renderer
   字符串；kwin.log 中 `Failed to open drm node: ""` 属 render 节点发现噪音，不构成
   软件渲染的证据。

## 目录结构

```
desk-takeover.sh        全自动接管入口：显示 + 桌面 + WiFi + 蓝牙 + 音频（推荐）
drm-takeover.sh         单轮/常驻接管（无完整桌面），带回滚；常驻用 PERSIST=1 MODE=kwin
scripts/                desk-stop / drm-stop / storage-fix / kwin-restart / keepbright / dmesg-harvester
                        / vkb-show / aa-feeder / bt-keepalive / bt-power-watcher / bt-anland-baseline / input-node-sync / power-state-sync / log收集
src/                    kwinwrap（核心）+ KMS 探针组 + touchdraw/touchtest/touchinj
configs/                desk-wifi.conf.example（WiFi 兜底配置样例）
docs/tools.md           全部编译产物的用法手册与新设备适配流程（英文版 docs/tools_english.md）
Makefile                一次 make 编全部（协议桩随仓库分发，无需 wayland-scanner）
```

## 快速开始

```
make                     # 编译 bin/ 下全部工具
# 可选：WiFi 兜底配置。主路径会接管前从 Android 动态读取当前 SSID/PSK，无此文件也能连网
cp configs/desk-wifi.conf.example /root/desk-wifi.conf
sudo bash desk-takeover.sh       # 全自动接管，直至 Plasma 桌面上屏
sudo bash scripts/desk-stop.sh   # 交还 Android（含看门狗兜底）
```

单轮短窗口验证用 `drm-takeover.sh`（约 150s 后自动恢复 Android）；常驻接管用
`PERSIST=1 MODE=kwin`。

## 运行期开关

| 开关 | 默认 | 说明 |
|---|---|---|
| `LOG_DIR` | 仓库同级 `logs/` | 日志目录（不入库） |
| `BT_BRIDGE` | `1`（开） | 蓝牙桥（见相关项目）+ 配套的 `scripts/bt-keepalive.sh`（默认上电、掉电回开、桥卡死重拉）。置 `0` 经 `/run/drm-round.conf` 或环境变量关闭；桥与看门狗都带自熔断，Android 框架复活时立即退场 |
| `AUDIO_BRIDGE` | `0`（**09-30 起默认关**） | 接管轮 A 路板载外放。默认关的原因：它与蓝牙 A2DP 抢同一套输出路由（A 路停掉 audioserver 并独占 deep_buffer/speaker 端口，实测会让耳机没声）。要外放：`echo 'AUDIO_BRIDGE=1' > /run/drm-round.conf` 后重跑一轮。失败仅告警，**绝不触发回滚** |
| `AUDIO_ROUTE` | `a` | `a` = 直连 vendor AIDL HAL（`argsloop` SINK + `aa-feeder`，已实测外放）；`b` = 回退的 AAudio 路线 |

## 子系统现状

| 子系统 | 实现方式 | 状态 |
|---|---|---|
| 显示 | kwinwrap 交接 + kwin DRM backend | 稳定；piano 需 split_commit 将单管虚拟 plane 改写为成对平面（对象 ID 随 boot 漂移，见已知问题） |
| 触摸 | udev 属性合成 + libinput 校准矩阵，kwin 为唯一读者 | 可用（十指） |
| 网络 | NetworkManager 裸进程直管 wlan0；SSID/PSK 接管前自 Android 现读；`ip rule` 备份/恢复标准三表；polkit 规则放行，plasma-nm 桌面 UI 可连可改密 | 可用；关联/出口失败仅告警，不连坐桌面 |
| 蓝牙 | droid-bluetooth-bridge（vendor HAL binder 客户端 → pty H4 → 内核 hci0 → 容器 BlueZ）；`scripts/bt-keepalive.sh` 轮内常驻 | 鼠标/HID 可用，A2DP 出声已验证；轮内与 WiFi 同政策「默认开 + 关不掉」：判到适配器后显式上电并实测 `Powered: yes`（BT-POWER）、装一条 dbus 总线策略拒桌面用户写适配器属性并每轮自检（BT-LOCK，蓝牙侧没有 polkit 可用）、掉电与卡死由看门狗按「内核重踢 → 重拉桥(先杀旧，整轮上限 2 次) → 收手留现场 `logs/bt-wedge-*.txt`」三级台阶处理（BT-KICK/BT-RESTART/BT-GIVEUP）。开局若见 `bt_power` rfkill soft=1（芯片电源还没被 vendor HAL 拉起来）只标 `BT-POWER-PENDING`/`BT-CHIP-BLOCKED` 并**等待**——实测这是接管开局暂态，自己会回 0，到位后 root `power on` 一次即通，同一座从未重拉的桥计数立刻从 `转发=50` 走到 150+；**不**手动解这颗 rfkill，也**不**在等待期重拉桥（重拉会注销 hci0、把恢复窗口吹掉） |
| 音频 | A 路：直连 vendor AIDL HAL（`argsloop` SINK 经 FMQ 喂数 + `aa-feeder` 抓 PipeWire monitor） | 接管轮内板载扬声器外放已实测；**09-30 起默认关**——它与蓝牙 A2DP 抢同一套输出路由，同开时耳机没声（共存方案是待办，见 工作总结 §58 ⑤） |
| 输入法 | 轮内定稿（09-29）：座位=plasma-keyboard，kwin 以 `KWIN_IM_SHOW_ALWAYS=1` 窗口激活时弹出（X11/Wayland 均覆盖）；旁观 fcitx5 守护（`FCITX5-BYST` 段，带 WAYLAND_DISPLAY 但晚于座位、只当 XIM 前端，默认英文态）负责 X11 应用组词；PC 页 Ctrl+Space 由 pc-keyd 特判 `fcitx5-remote -T` DBus 直达；两模式各自入场归一 kwinrc（轮=plasma-keyboard / anland=fcitx5） | 可用 |
| 组合键 | pc-keyd v2（XTEST/EIS 主通道；通道 C 经 kwin pkeyd 补丁，uinput 仅兜底） | X11 应用已验证；Wayland 应用待通道 C 真轮验证 |

## 安全边界

- **wlan0 全程零 admin 状态变更**：接管与交还双向都不得对 wlan0 执行 admin down/up。
  cnss 驱动在 idle 态收到 down 后的任意一次 up（不分持有者）都会进入
  MHI -110 → recovery → ASSERT 路径，D 态进程永久持有 rtnl，用户态无解，只能整机重启。
  接管只做 L3 清理（地址/路由/邻居表），接口保持 UP 原样（5.36 定案）。
- **uinput 防滥用**：内核对高频建删 uinput 设备有防护机制，触发后本启动会话内所有注入
  静默丢弃。不得反复启停 uinput 守护；修饰键抬起必须无条件补发（finally），否则内核
  卡键。pc-keyd v2 默认不创建 uinput 设备。

## 已知问题与对策（均已内建于脚本）

1. **system_server watchdog**：SF 停止约 120s 后，Android watchdog 杀死 system_server，
   init 级联终止 wpa_supplicant/netd/zygote → WiFi 彻底掉线。对策：PERSIST 轮解除
   watchdog（`watchdog_timeout` / `nativehang` / `stay_on`）+ wake_lock。
2. **双桌面共享 HOME**：anland 与 DRM 桌面共用同一容器与 `/etc`，任何全局改动
   （`/etc/environment`、kwinrc 等）必须双模式回归。历史事故：删除全局 `QT_IM_MODULE=fcitx5`
   （DRM 侧必要）打坏 anland 中文输入——修复为在 anland launcher 内会话级注入。
3. **触摸验证禁用 getevent**：对触摸节点运行 getevent 会触发小米安全联动直接断网（多次
   实锤）。触摸链路只保留 kwin 一个读者，用 `bin/touchtest` 打点日志验证。
4. **kactivitymanagerd 必须显式拉起**：依赖 dbus 自动激活会超时，plasmashell 直接
   `Aborting shell load`，表现为"kwin 存活、触摸在收、面板有模式，但整屏黑"。脚本先拉起
   并等待 `org.kde.ActivityManager` 上总线后再起 plasmashell（需 `QT_QPA_PLATFORM=wayland`）。
5. **xdg-desktop-portal**：必须带 `XDG_CURRENT_DESKTOP=KDE` 启动，否则无 KDE 后端，
   任务栏无法打开应用。
6. **DRM 对象 ID 随 boot 漂移**：connector/crtc/plane ID 每次重启都变。触摸节点与 kgsl
   主设备号已运行时解析；kwinwrap 内的 plane 对 ID 为 piano 快照值，其他设备适配时必须
   重新探测（见 docs/tools.md）。
7. **良性噪音**：vendor vblank 时间戳为 0（kwin 打印数次后自静音）；kwin 启动期部分
   atomic TEST 返回 -22/-ENOENT 后仍走通提交。均无需处理。

## 设备要求

- Android 侧：可 root（KernelSU/Magisk），高通平台（本项目按 composer HAL 停法，其他平台需调整）
- Linux 容器：Ubuntu aarch64，KWin 6.6 + Plasma 6.x，`libdrm`/`libwayland` 开发包，
  NetworkManager + plasma-nm（网络主路径；`wpa_supplicant` 作为其 D-Bus 后端；
  `dhcpcd` 仅 legacy 回退段使用）
- 控制通道：容器内 adb（本机 adbd 优先，`emulator-5554`；不依赖 WiFi 射频）

## 工具

`make` 产出 19 个二进制与 `atomicspy.so`，**接管流程由脚本自动调用，日常无需手动运行**。
按角色分为接管核心、触摸验证、KMS 诊断探针、存储四类，全部用法与新设备适配流程见
[docs/tools.md](docs/tools.md)。

## 安卓存储

容器里的 `/storage/emulated/0` 是容器启动时 bind 的**那一个** Android FUSE 超级块。Android 每次重启
框架（交还时的 `start`、MediaProvider 崩溃、用户解锁）都会 mount 出新的超级块，容器抱着旧的那份之后
一律返回 `ENOTCONN`，表现为"拒绝访问"——与权限无关，改授权不可能修好。

- **交还后自动修复**：`scripts/storage-fix.sh` 比对主机与容器同一挂点的 major:minor，不一致就用
  `open_tree`+`setns`+`move_mount` 把当下活的挂载重新接进容器。已挂在 `desk-stop.sh` 与 `drm-stop.sh`
  的交还路径（后台运行），判据在 `logs/storage-fix.log` 的 `STORAGE-OK` / `STORAGE-STALE`。
  非接管触发的重挂不会自愈，手动跑 `bash scripts/storage-fix.sh 90`。
- **接管轮内请用 `/Android`**：轮里 Android 框架是停的，根本没有活的 FUSE 可接。`/Android` 是
  `container.config` 里 `bind_mounts` 绑的 `/data/media/0`（储存本体，在 `/data` 上，不随框架重启失效）。
  代价：绕过 per-app 储存权限、`chmod`/`chown` 真生效、新文件不进 MediaStore；轮里当传输通道用即可。

## 风险与回滚

接管期间 Android 的 UI 与网络栈整体停摆。脚本具备回滚逻辑（`desk-stop.sh` 含 50s 看门狗
兜底），但不承诺覆盖所有异常路径；最坏情况为长按电源强制重启。首次上机请保证：电量 >50%、
有人在现场、可接受一次重启。

## 相关项目

- [droid-pc-keyboard](https://github.com/Yizhou147/droid-pc-keyboard) — PC 布局虚拟键盘、
  拼音与 pc-keyd 组合键守护（本仓库在桌面就绪后以会话用户拉起 `/usr/local/bin/pc-keyd.py`）
- [droid-bluetooth-bridge](https://github.com/Yizhou147/droid-bluetooth-bridge) — vendor
  蓝牙 HAL 的 binder 客户端桥，为容器提供原生 `hci0`
- [droid-audio-bridge](https://github.com/Yizhou147/droid-audio-bridge) — 接管轮直连 HAL
  音频（A 路）与 anland 态 AAudio 环回

## License

GPLv3（GNU General Public License v3，全文见 [LICENSE](LICENSE)）。
