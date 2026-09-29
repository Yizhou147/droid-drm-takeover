中文 | [English](tools_english.md)

# 工具清单（bin/ 产物）

`make` 在 `bin/` 生成全部工具（19 个二进制 + `atomicspy.so`）。接管流程由
`desk-takeover.sh` / `drm-takeover.sh` 自动调用，日常使用无需手动运行其中任何一个；
本文面向新设备适配与故障排查。

前提：所有需要 DRM master 的工具（含 TEST_ONLY 探测）都必须在 Android 显示栈停止后以
root 运行，否则 atomic ioctl 一律返回 `EACCES`。各工具不带参数直接运行会打印用法提示。

## ① 接管核心（脚本自动调用）

| 工具 | 作用 | 手动用法示例 |
|---|---|---|
| `kwinwrap` | 交接桥：root 取得 DRM master → 预清理 Android 遗留 atomic 状态（释放其占用的 plane/CRTC、connector DPMS 恢复 On）→ `DROP_MASTER` → 按 `KWINWRAP_UID/GID` 降权 → `exec` 目标程序。可选 `KWINWRAP_BRIGHTNESS` 钉住背光。对 piano 这类双 DSI 面板另含 **split_commit**：ptrace 改写提交中的单管虚拟 plane 为成对平面（对象 ID 为 piano 快照，其他设备必须重新探测） | `kwinwrap --out /tmp/atomic.log -- env KWIN_DRM_DEVICES=/dev/dri/card0 kwin_wayland --socket=taketest` |
| `setbright` | 直写/读取背光亮度（Android 关机流程会将亮度清零，接管后需自行点亮） | `setbright 2048`；不带参数 = 打印范围与当前值 |
| `setprop` | 直写 connector 的 DRM 属性（默认 DPMS；`0` = On） | `setprop 0 DPMS`；属性名/connector id 可作第 2/3 参 |
| `atomicspy.so` | ptrace 附加式记录器：attach 目标进程，打印每次 `DRM_IOCTL_MODE_ATOMIC` 的对象/属性/errno，不改变行为。以 `-shared` 编译为 `.so` 后缀，但按可执行文件直接运行（非 LD_PRELOAD） | `bin/atomicspy.so <pid> [秒]` |

## ② 触摸验证（替代 getevent 旁听，避免触发厂商安全联动）

| 工具 | 作用 | 用法 |
|---|---|---|
| `touchtest` | 经合成器的标准验证画板：每个触点绘制圆点并打点日志，验证"手指 → 驱动 → kwin → 渲染"全链路 | `WAYLAND_DISPLAY=taketest touchtest [秒]` |
| `touchdraw` | 绕过合成器：以裸 atomic 直接点亮 framebuffer 绘制触摸点，验证无 kwin 时面板与触摸链路可用 | 需 DRM master（`touchdraw` 直跑） |
| `touchinj` | 经 kwin 的 fake-input 扩展注入合成触摸，用于无真手指的端到端测试 | `WAYLAND_DISPLAY=... touchinj [秒]` |
| `udevprobe` / `udevmatch` | 经 udev 枚举/匹配触摸事件节点（`eventN` 编号随 boot 变化，不得写死） | 直跑打印 |

## ③ KMS 诊断探针（新设备适配第一步）

| 工具 | 作用 | 用法 |
|---|---|---|
| `rawprobe` | 新设备首查：枚举 connector/encoder/crtc/plane，逐属性打印原始 errno | `rawprobe [card=/dev/dri/card0]` |
| `drmatomic` | 通用 atomic 提交命令行（模式设置 + 色带上屏 + 双 pipe split 演示） | `drmatomic [card] [秒]` |
| `atombisect` | atomic TEST 返回 -22 时，二分定位被内核拒绝的属性（全程 TEST_ONLY，非破坏性） | `atombisect [card]` |
| `stageprobe` | 与 `drmatomic` 同配置的分阶段提交验证 | `stageprobe [card]` |
| `replicate` | 对接管期返回 -ENOENT 的属性做 TEST_ONLY 变体重放 | 直跑 |
| `connprops` | 免 master 查询 connector 属性 ID（DPMS/mode 等） | `connprops [card]` |
| `planecrtc` | plane↔CRTC possible_crtcs 矩阵（识别虚拟/overlay 平面） | 直跑 |
| `informats` | 列出显卡支持的 FB 像素格式与 modifier | `informats [card]` |
| `crtcstate` | 导出 CRTC 当前状态（上屏取证） | 直跑 |
| `masterprobe` | 查询当前 DRM master 持有者 | 直跑 |
| `kwinprobe` | 借 kwin 已持有的 card fd（附加指定 pid）在真实上下文中测量 | `kwinprobe <pid>` |

## ④ 存储：把安卓的存储重新挂回容器

容器 boot 时 bind 的 `/storage/emulated/0` 是安卓**当时那个** fuse 超级块。安卓每次重启框架
（交还时的 `start`、MediaProvider 崩、用户解锁）都会 mount 出一个新的超级块，容器抱着的旧那份
之后一律返回 `ENOTCONN`，表现为"拒绝访问"，与权限/授权无关（改权限不可能修好）。完整实测记录
见主项目《工作总结.md》§3.12。

| 工具 | 作用 | 用法 |
|---|---|---|
| `storage-rebind` | 在安卓侧（root、init mount ns）比对主机与容器同一挂点的 major:minor，不一致就用 `open_tree(OPEN_TREE_CLONE)`+`setns`+`move_mount` 把当下活的挂载重新接进容器。静态 musl 产物（安卓没有 glibc） | `storage-rebind [-c] [-s 源 -d 容器挂点] [容器pid]`；pid 缺省取 `/data/local/Droidspaces/Pids/*.pid` |
| `scripts/storage-fix.sh` | 编排层：按需 push 工具与设备侧脚本，等安卓侧源真的可用后再动手，最后在容器 ns 里带 timeout 验收 | `bash scripts/storage-fix.sh [等待秒=60]`；判据 `STORAGE-OK` / `STORAGE-STALE` / `HOST-SOURCE-DEAD` |

已接进 `desk-stop.sh`（4b1）与 `drm-stop.sh`（第 5 步）交还路径，后台运行，判据落在
`logs/storage-fix.log`。**接管轮内不要指望 `/storage/emulated/0`**：那时框架是停的，压根没有活的
FUSE 可接；轮里读写手机存储走 `/Android`（容器配置 `bind_mounts` 绑 `/data/media/0`）。

两条铁律，改这块代码前先读：

- 判断挂载死活**只能读 `/proc/<pid>/mountinfo`**。在容器 ns 里 `stat`/`ls` 那个挂载，遇到
  system_server 被 SIGSTOP 的冻结态会永久挂住（连 `umount2` 都要带 `MNT_DETACH`）。
- 不要在容器 ns 里 `mount --bind /proc/1/root/...`：路径解析走当前 ns，`/proc/1` 是容器自己的
  init，结果会把**已经死掉的旧超级块**再绑一遍（实测踩过）。跨 ns 只能用 open_tree+move_mount。
  另注：`open_tree=428`、`move_mount=429`（asm-generic，别记反）。

## ⑤ 安卓侧性能/频率工具（经 adb root 使用，不进 DRM 通路）

| 工具 | 作用 | 用法 |
| --- | --- | --- |
| `scripts/perfmax.sh` | 把本机 sysfs 可达的全部性能旋钮拧到顶并**可还原**：CPU 两簇 `scaling_min/max_freq`、GPU（`min_pwrlevel`/`pwrscale`/`hwcg`/`ifpc`）、DDR/LLCC 频率地板。子命令 `pin`/`loop`/`stop`/`restore`/`status`；原值与原 mode 记在安卓侧 `/data/local/tmp/perfmax.orig`，**写不进记录就什么都不拧**；`loop` 每 2s 重申一次（perf 守护进程会回写覆盖单次写），60min 自动退出 | 由 `desk-takeover.sh` 的 1d) PERFMAX 段自动调用（`PERFMAX=1` 开启）；手动：`adb -s <EP> push scripts/perfmax.sh /data/local/tmp/` 后 `adb -s <EP> shell "su -c 'sh /data/local/tmp/perfmax.sh pin'"` |
| `scripts/cpu-prof.sh` | 归因探针：5s `/proc/stat` 差分给出**每个核的占用率**、被测进程各线程的**实际落点核**、每核当前频率、policy 上下限、GPU 档频与 `throttling` | 推到 `/data/local/tmp/` 后 `adb -s <EP> shell "su -c 'sh /data/local/tmp/cpu-prof.sh vkmark'"`；同一时刻只能有一个被测进程，否则占用率会被混计 |

> 说明：perf HAL（QTI `perf2.IPerf` 与小米 `miperf2.IMiPerf`）对调用方做**按包名的白名单校验**，
> root/uid 0 发 `perfLockAcquire`/`perfHint` 一律被拒（`EX_SERVICE_SPECIFIC`），因此本机性能调节走上面的
> sysfs 路径而非 perflock。方法表、transaction code、资源 opcode 与白名单证据记录在工作总结 §48。

## 新设备适配最短路径

1. `rawprobe` + `planecrtc` + `informats` —— 摸清面板资源拓扑；
2. `drmatomic` 手动点亮一次色带 —— 验证 KMS 通路；
3. atomic TEST 返回 -22/-ENOENT 时，用 `atombisect` / `replicate` 定位到具体属性；
4. `kwinwrap` + `kwin_wayland` 走通交接；若面板需要成对平面，参考 piano 的
   split_commit 实现并替换为本设备实测的对象 ID（一律运行时解析，不得复用 piano 常量）；
5. 触摸：`udevmatch` 定位节点 → `touchdraw` 验证裸链路 → `touchtest` 验证合成器链路。
