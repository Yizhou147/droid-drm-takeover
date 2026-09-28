[中文](tools.md) | English

# Tool inventory (bin/ artifacts)

`make` builds every tool into `bin/` (18 binaries + `atomicspy.so`). The takeover flow invokes
them automatically via `desk-takeover.sh` / `drm-takeover.sh`; you never need to run any of them
manually day-to-day. This document is for new-device adaptation and troubleshooting.

Premise: every tool that needs DRM master (including TEST_ONLY probes) must run as root **after**
the Android display stack is stopped, otherwise atomic ioctls all return `EACCES`. Running any
tool without arguments prints its usage.

## ① Takeover core (invoked automatically by the scripts)

| Tool | Purpose | Manual usage example |
|---|---|---|
| `kwinwrap` | Handover bridge: root acquires DRM master → pre-cleans the atomic state Android left behind (releases its planes/CRTCs, restores connector DPMS to On) → `DROP_MASTER` → drops privileges per `KWINWRAP_UID/GID` → `exec`s the target program. Optional `KWINWRAP_BRIGHTNESS` pins the backlight. For dual-DSI panels like piano it also implements **split_commit**: ptrace-rewrites single-pipe virtual planes in commits into paired plane sets (object IDs are a piano snapshot; other devices must re-probe) | `kwinwrap --out /tmp/atomic.log -- env KWIN_DRM_DEVICES=/dev/dri/card0 kwin_wayland --socket=taketest` |
| `setbright` | Directly write/read backlight brightness (the Android shutdown flow zeroes it; after takeover you must light it yourself) | `setbright 2048`; no args = print range and current value |
| `setprop` | Directly write a connector DRM property (DPMS by default; `0` = On) | `setprop 0 DPMS`; property name / connector id accepted as args 2/3 |
| `atomicspy.so` | ptrace-attach recorder: attaches to a target process and logs every `DRM_IOCTL_MODE_ATOMIC` object/property/errno without changing behavior. Built with `-shared` and a `.so` suffix but run directly as an executable (not LD_PRELOAD) | `bin/atomicspy.so <pid> [seconds]` |

## ② Touch verification (replaces getevent eavesdropping, which trips the vendor security interlock)

| Tool | Purpose | Usage |
|---|---|---|
| `touchtest` | Standard compositor-routed verification canvas: draws every contact point and logs instrumentation, validating the full "finger → driver → kwin → rendering" chain | `WAYLAND_DISPLAY=taketest touchtest [seconds]` |
| `touchdraw` | Bypasses the compositor: bare atomic commits light up a framebuffer directly to draw touch points, verifying panel + touch chain without kwin | Needs DRM master (run `touchdraw` directly) |
| `touchinj` | Injects synthetic touch through kwin's fake-input extension for end-to-end tests without real fingers | `WAYLAND_DISPLAY=... touchinj [seconds]` |
| `udevprobe` / `udevmatch` | Enumerate/match touch event nodes via udev (`eventN` numbers change per boot; never hardcode) | run directly, prints |

## ③ KMS diagnostic probes (first step for new-device adaptation)

| Tool | Purpose | Usage |
|---|---|---|
| `rawprobe` | First look at a new device: enumerates connector/encoder/crtc/plane and prints raw errno per property | `rawprobe [card=/dev/dri/card0]` |
| `drmatomic` | General-purpose atomic commit CLI (mode setting + colorbar on screen + dual-pipe split demo) | `drmatomic [card] [seconds]` |
| `atombisect` | When an atomic TEST returns -22, bisects to the property the kernel rejects (all TEST_ONLY, non-destructive) | `atombisect [card]` |
| `stageprobe` | Staged commit verification using the same configuration as `drmatomic` | `stageprobe [card]` |
| `replicate` | Replays TEST_ONLY variants against properties that returned -ENOENT during takeover | run directly |
| `connprops` | Query connector property IDs (DPMS/mode etc.) without master | `connprops [card]` |
| `planecrtc` | plane↔CRTC possible_crtcs matrix (identifies virtual/overlay planes) | run directly |
| `informats` | List framebuffer pixel formats and modifiers supported by the GPU | `informats [card]` |
| `crtcstate` | Dump current CRTC state (on-screen forensics) | run directly |
| `masterprobe` | Query who currently holds DRM master | run directly |
| `kwinprobe` | Borrow the card fd already held by kwin (attach by pid) to measure in the real context | `kwinprobe <pid>` |

## ④ Android-side performance/frequency tools (over adb root, outside the DRM path)

| Tool | Purpose | Usage |
| --- | --- | --- |
| `scripts/perfmax.sh` | Turns every sysfs-reachable performance knob on the device to its maximum and **restores it**: both CPU clusters' `scaling_min/max_freq`, GPU (`min_pwrlevel`/`pwrscale`/`hwcg`/`ifpc`), DDR/LLCC frequency floors. Subcommands `pin`/`loop`/`stop`/`restore`/`status`; original values and modes are recorded on the Android side at `/data/local/tmp/perfmax.orig` — **if the recording fails, nothing is pinned**; `loop` re-asserts every 2s (the perf daemon overwrites single writes) and auto-exits after 60min | Invoked automatically by the 1d) PERFMAX section of `desk-takeover.sh` (`PERFMAX=1` to enable); manually: `adb -s <EP> push scripts/perfmax.sh /data/local/tmp/` then `adb -s <EP> shell "su -c 'sh /data/local/tmp/perfmax.sh pin'"` |
| `scripts/cpu-prof.sh` | Attribution probe: a 5s `/proc/stat` delta gives **per-core utilization**, the **actual cores** each thread of the measured process lands on, per-core current frequency, policy min/max, GPU frequency level and `throttling` | Push to `/data/local/tmp/` then `adb -s <EP> shell "su -c 'sh /data/local/tmp/cpu-prof.sh vkmark'"`; only one measured process at a time, otherwise utilization gets mixed |

> Note: the perf HALs (QTI `perf2.IPerf` and Xiaomi `miperf2.IMiPerf`) enforce a
> **caller-package allowlist**; root/uid 0 issuing `perfLockAcquire`/`perfHint` is always rejected
> (`EX_SERVICE_SPECIFIC`), so performance tuning on this device goes through the sysfs path above
> rather than perflock. Method tables, transaction codes, resource opcodes and allowlist evidence
> are recorded in the internal work summary §48.

## Shortest path for new-device adaptation

1. `rawprobe` + `planecrtc` + `informats` — map the panel's resource topology;
2. `drmatomic` — light up a colorbar manually once, verifying the KMS path;
3. when atomic TEST returns -22/-ENOENT, locate the exact property with `atombisect` / `replicate`;
4. get the handover working with `kwinwrap` + `kwin_wayland`; if the panel needs paired planes,
   refer to piano's split_commit implementation and substitute this device's measured object IDs
   (resolve at runtime — never reuse piano constants);
5. Touch: locate nodes with `udevmatch` → verify the bare chain with `touchdraw` → verify the
   compositor chain with `touchtest`.
