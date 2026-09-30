[中文](README.md) | English

# Droid DRM Takeover

On Android devices, the native Linux desktop inside a container (KWin + Plasma) takes
direct ownership of the panel's DRM/KMS, bypassing Android SurfaceFlinger composition and
forwarding entirely. The frame path is zero-copy; latency depends only on the KMS commit
itself.

Fully validated on the **Xiaomi Pad 8 Pro** (codename `piano`, SM8750 / Adreno 830,
kernel 6.6.118-android15, HyperOS): direct 3200x2136@120 drive, multi-touch, Bluetooth
peripherals, on-device speaker audio during takeover rounds, and container-managed WiFi.

> ⚠️ Verified only on the device above. Other devices must re-probe DRM objects and
> parameters following the adaptation flow in [docs/tools_english.md](docs/tools_english.md);
> the known worst case is a long-press power-button forced reboot (data survives, unsaved
> work is lost).

## How it works

The hard part is not the userspace GPU driver (the rendering stack is untouched) but
**who submits frames to the panel**:

1. **Who holds DRM master** — master is held by the Android-side
   `vendor.qti.hardware.display.composer` HAL (not surfaceflinger). Besides `adb shell su`
   `stop`, you must explicitly `setprop ctl.stop vendor.qti.hardware.display.composer`
   (`stop` does not affect `class hal`; the service must be stopped by name) → master frees up.
2. **Missing nodes, not missing drivers** — the vendor only removed
   `/dev/dri/card0` from the filesystem; the driver is still in the kernel. Read the
   major/minor numbers from sysfs and `mknod` it back; no kernel changes needed.
3. **kwinwrap handover** — `src/kwinwrap.c` running as root: acquire master → pre-clean the
   atomic state Android left behind (release planes/CRTCs it occupied, restore connector
   DPMS to On) → `DROP_MASTER` → drop privileges per `KWINWRAP_UID/GID` →
   `exec kwin_wayland`. From then on kwin drives the panel as a normal user via stock
   GBM/EGL + atomic commits.
4. **GPU uses the container's existing Mesa stack** — kwin goes through `renderD128` with
   stock Mesa (measured renderer: `zink Vulkan 1.4 (Adreno, MESA_TURNIP)`, determined by the
   `GPU-WHICH` probe). **Never inject Mesa env vars such as `MESA_LOADER_DRIVER_OVERRIDE=kgsl`**:
   kgsl buffers have no export ioctl and cannot provide dmabuf to KMS; after injection kwin
   sends not a single frame (measured pitch-black on 09-25, reverted; see comments in
   `desk-takeover.sh`). The only valid way to detect software rendering is the renderer string
   from `glxinfo -B`; `Failed to open drm node: ""` in kwin.log is render-node discovery noise
   and is not evidence of software rendering.

## Layout

```
desk-takeover.sh        Fully automatic takeover entry: display + desktop + WiFi + Bluetooth + audio (recommended)
drm-takeover.sh         Single-round/persistent takeover (no full desktop), with rollback; use PERSIST=1 MODE=kwin for persistent
scripts/                desk-stop / drm-stop / storage-fix / kwin-restart / keepbright / dmesg-harvester
                        / vkb-show / aa-feeder / bt-keepalive / bt-power-watcher / bt-anland-baseline / input-node-sync / power-state-sync / log收集
src/                    kwinwrap (core) + KMS probe suite + touchdraw/touchtest/touchinj
configs/                desk-wifi.conf.example (WiFi fallback config sample)
docs/tools.md           Usage manual for all build artifacts + new-device adaptation flow
Makefile                `make` builds everything (Wayland protocol stubs shipped in-repo, no wayland-scanner
                        needed); `make ci` skips storage-rebind, which must be built statically with musl
```

## Quick start

```
make                     # build all tools under bin/
                           # storage-rebind must be linked statically with musl (Android has no glibc);
                           # the build aborts with a hint when musl-gcc is missing
make ci                  # everything except storage-rebind: use this for cross builds / CI
                           # (musl-gcc on a runner would emit runner-arch binaries)
# Optional WiFi fallback config. The main path reads the current SSID/PSK dynamically from
# Android before takeover, so networking works even without this file
cp configs/desk-wifi.conf.example /root/desk-wifi.conf
sudo bash desk-takeover.sh       # fully automatic takeover until the Plasma desktop is on screen
sudo bash scripts/desk-stop.sh   # hand the device back to Android (includes watchdog fallback)
```

For single short verification rounds use `drm-takeover.sh` (auto-restores Android after ~150s);
for persistent takeover use `PERSIST=1 MODE=kwin`.

## Runtime switches

| Switch | Default | Description |
|---|---|---|
| `LOG_DIR` | `logs/` next to the repo | Log directory (not in git) |
| `BT_BRIDGE` | `1` (on) | Bluetooth bridge (see related projects) plus its companion `scripts/bt-keepalive.sh` (powers the adapter on, re-powers it if it drops, and relaunches the bridge only on hard kernel-side signals). Set `0` via `/run/drm-round.conf` or an env var; both the bridge and the watchdog carry a self-fuse and exit immediately when the Android framework comes back |
| `BT_BIN` | `/data/local/tmp/bthci-bridge` | Which bridge binary to run. Point it at `-v2` to canary a new build (e.g. `echo 'BT_BIN=/data/local/tmp/bthci-bridge-v2' > /run/drm-round.conf`); rollback is just deleting that line — the old binary is always left in place |
| `AUDIO_BRIDGE` | `0` (**default off since 09-30**) | Route A built-in speaker output during takeover rounds. It is off by default because it fights Bluetooth A2DP for the same output route (Route A stops audioserver and claims the deep_buffer/speaker ports, which mutes the headphones — measured). To get speaker output: `echo 'AUDIO_BRIDGE=1' > /run/drm-round.conf`, then run a round. Failures only warn and **never trigger a rollback** |
| `AUDIO_ROUTE` | `a` | `a` = direct vendor AIDL HAL (`argsloop` SINK + `aa-feeder`, speaker output measured); `b` = fallback AAudio route |

## Subsystem status

| Subsystem | Implementation | Status |
|---|---|---|
| Display | kwinwrap handover + kwin DRM backend | Stable; piano requires split_commit to rewrite single-pipe virtual planes into paired planes (object IDs drift per boot, see known issues) |
| Touch | Synthetic udev properties + libinput calibration matrix, kwin as the sole reader | Working (10-finger) |
| Network | Bare NetworkManager process managing wlan0 directly; SSID/PSK read from Android before takeover; `ip rule` backup/restore of the standard three tables; polkit rules granted, plasma-nm desktop UI can connect and change passwords | Working; association/egress failures only warn, never take the desktop down with them |
| Bluetooth | droid-bluetooth-bridge (vendor HAL binder client → pty H4 → kernel hci0 → container BlueZ); `scripts/bt-keepalive.sh` stays resident during the round | Mouse/HID working; A2DP audio output verified. Inside a round Bluetooth follows the same "on by default, cannot be switched off" policy as WiFi: once the adapter is detected it is explicitly powered on and `Powered: yes` is measured (BT-POWER); a dbus bus policy refuses desktop-user writes to adapter properties and is self-checked every round (BT-LOCK; Bluetooth has no polkit equivalent here); power loss and stalls are handled by the watchdog on a three-step ladder — kernel `hciconfig up` re-kick → relaunch the bridge (kill the old one first, max 2 per round) → stand down and dump `logs/bt-wedge-*.txt` (BT-KICK/BT-RESTART/BT-GIVEUP). **The trigger is a hard kernel-side signal** (`hciconfig` cannot read the local name and `dmesg`'s `tx timeout` count is climbing → BT-DEADCHANNEL), never bluez's `Powered` — measured still `yes` while the channel was dead. If the `bt_power` rfkill reads soft=1 at round start it only marks `BT-POWER-PENDING`/`BT-CHIP-BLOCKED` and **waits**: measured as a startup transient that clears on its own, after which a single root `power on` brings it up — the very same bridge that was never relaunched jumped from `forwarded=50` to 150+. We never unblock that rfkill by hand (chip power belongs to the vendor HAL/btpower — a project red line) and never relaunch the bridge while waiting, since each relaunch unregisters hci0 and blows away the pending power-up window |
| Audio | Route A: direct vendor AIDL HAL (`argsloop` SINK fed via FMQ + `aa-feeder` capturing the PipeWire monitor) | Built-in speaker output measured inside takeover rounds; **default off since 09-30** — it contends with Bluetooth A2DP for the same output route (with both on, the headphones go silent). Coexisting properly is an open item (see 工作总结 §58 item 5) |
| Input method | Final 09-29 layout: plasma-keyboard holds the seat and kwin pops it on window activation via `KWIN_IM_SHOW_ALWAYS=1` (X11 + Wayland); a bystander fcitx5 daemon (FCITX5-BYST: starts with WAYLAND_DISPLAY but after the seat, so it only serves as the XIM front, default English) composes Chinese for X11 apps; PC-page Ctrl+Space is special-cased in pc-keyd to `fcitx5-remote -T` over DBus; each mode pins kwinrc InputMethod on entry (round=plasma-keyboard, anland=fcitx5) | Working |
| Key combos | pc-keyd v2 (XTEST/EIS primary channel; channel C via the kwin pkeyd patch, uinput only as last resort) | Verified for X11 apps; Wayland apps pending channel-C on-device verification |

## Safety boundaries

- **Zero admin-state changes on wlan0, in both directions**: neither takeover nor handover may
  perform admin down/up on wlan0. The cnss driver, in idle state, enters
  MHI -110 → recovery → ASSERT on any up after a down (regardless of who issues it); the D-state
  process holds rtnl forever and userspace cannot fix it — a full reboot is the only way out.
  Takeover only does L3 cleanup (addresses/routes/neighbours), the interface stays UP as-is
  (settled in 5.36).
- **uinput anti-abuse**: the kernel protects against rapid uinput device create/destroy cycles;
  once triggered, all injection in that boot session is silently dropped. Do not repeatedly
  start/stop uinput daemons; modifier key releases must be re-sent unconditionally (finally),
  otherwise the kernel gets stuck keys. pc-keyd v2 does not create a uinput device by default.

## Known issues & mitigations (all built into the scripts)

1. **system_server watchdog**: ~120s after SF stops, the Android watchdog kills system_server,
   and init cascades SIGKILLs to wpa_supplicant/netd/zygote → WiFi drops completely. Mitigation:
   persistent rounds disarm the watchdog (`watchdog_timeout` / `nativehang` / `stay_on`) + wake_lock.
2. **Two desktops share one HOME**: the anland and DRM desktops share the same container and
   `/etc`; any global change (`/etc/environment`, kwinrc, etc.) must be regression-tested in both
   modes. Historical incident: deleting the global `QT_IM_MODULE=fcitx5` (necessary on the DRM
   side) broke anland Chinese input — fixed by injecting it per-session inside the anland launcher.
3. **No getevent for touch verification**: running getevent on touch nodes triggers Xiaomi's
   security interlock and kills the network (confirmed multiple times). The touch chain keeps
   kwin as the only reader; verify via instrumented `bin/touchtest` logs.
4. **kactivitymanagerd must be started explicitly**: relying on dbus auto-activation times out and
   plasmashell aborts with `Aborting shell load`, which looks like "kwin alive, touch events
   arriving, panel has a mode — but the screen is pitch black". The scripts start it first and
   wait for `org.kde.ActivityManager` on the bus before launching plasmashell (requires
   `QT_QPA_PLATFORM=wayland`).
5. **xdg-desktop-portal**: must be started with `XDG_CURRENT_DESKTOP=KDE`, otherwise there is no
   KDE backend and the task bar cannot open apps.
6. **DRM object IDs drift per boot**: connector/crtc/plane IDs change on every reboot. Touch nodes
   and the kgsl major number are resolved at runtime; the plane-pair IDs inside kwinwrap are piano
   snapshot values and must be re-probed when adapting other devices (see docs).
7. **Benign noise**: vendor vblank timestamps are 0 (kwin self-silences after a few lines); some
   atomic TESTs during kwin startup return -22/-ENOENT yet the commit still succeeds. Neither needs action.

## Requirements

- Android side: rootable (KernelSU/Magisk), Qualcomm platform (this project stops the composer HAL
  by name; other platforms need adjustments)
- Linux container: Ubuntu aarch64, KWin 6.6 + Plasma 6.x, `libdrm`/`libwayland` dev packages,
  NetworkManager + plasma-nm (main network path; `wpa_supplicant` as its D-Bus backend;
  `dhcpcd` only used by the legacy fallback section)
- Control channel: adb inside the container (local adbd preferred, `emulator-5554`; does not
  depend on the WiFi radio)

## Tools

`make` produces 19 binaries plus `atomicspy.so`. **The takeover flow invokes them automatically;
you never need to run them manually day-to-day.** They fall into four roles — takeover core,
touch verification, KMS diagnostic probes, storage — full usage and the new-device adaptation flow
are in [docs/tools_english.md](docs/tools_english.md).

## Android storage

The container's `/storage/emulated/0` is a bind of **one particular** Android FUSE superblock, taken
when the container booted. Every framework restart (the `start` during handover, a MediaProvider
crash, user unlock) mounts a new superblock, so the container keeps holding the dead one and every
access returns `ENOTCONN` — it shows up as "access denied" and no permission change can fix it.

- **Auto-repair after handover**: `scripts/storage-fix.sh` compares major:minor of the same mount
  point in the host and in the container and, on mismatch, re-attaches the currently live mount into
  the container namespace with `open_tree`+`setns`+`move_mount`. It is wired into the handover paths
  of `desk-stop.sh` and `drm-stop.sh` (background), with verdicts `STORAGE-OK` / `STORAGE-STALE` in
  `logs/storage-fix.log`. Remounts *not* triggered by a takeover do not self-heal; run
  `bash scripts/storage-fix.sh 90` manually.
- **Inside a takeover round use `/Android`**: the Android framework is stopped then, so there is no
  live FUSE to attach at all. `/Android` comes from the `bind_mounts` entry for `/data/media/0` in
  `container.config` (the storage itself, on `/data`, so it never goes stale). The price: per-app
  storage permissions are bypassed, `chmod`/`chown` really take effect, and new files are not indexed
  by MediaStore. Treat it as a transfer channel during rounds.

## Risk & rollback

During takeover the Android UI and network stacks are entirely stopped. The scripts contain
rollback logic (`desk-stop.sh` includes a 50s watchdog fallback) but do not promise to cover every
abnormal path; the worst case is a long-press power-button forced reboot. For a first run make
sure: battery >50%, a person is present, and one reboot is acceptable.

## Related projects

- [droid-pc-keyboard](https://github.com/Yizhou147/droid-pc-keyboard) — PC-layout virtual keyboard,
  Pinyin and the pc-keyd key-combo daemon (this repo starts `/usr/local/bin/pc-keyd.py` as the
  session user once the desktop is up)
- [droid-bluetooth-bridge](https://github.com/Yizhou147/droid-bluetooth-bridge) — binder client
  bridge to the vendor Bluetooth HAL, providing the container with a native `hci0`
- [droid-audio-bridge](https://github.com/Yizhou147/droid-audio-bridge) — direct-HAL audio during
  takeover rounds (route A) and the AAudio loopback for anland mode

## License

GPLv3 (GNU General Public License v3, full text in [LICENSE](LICENSE)).
