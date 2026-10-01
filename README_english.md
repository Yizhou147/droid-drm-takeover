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
installer/              One-command installer & runtime TUI (drm-tui.sh / install-drm-tui.sh /
                        lib/*.sh / lib/components.lock.json = the single source of component
                        versions and sha256 digests)
Makefile                `make` builds everything (Wayland protocol stubs shipped in-repo, no wayland-scanner
                        needed); `make ci` skips storage-rebind, which must be built statically with musl
```

## One-command install & `drm-tui` (installer / runtime TUI)

New users no longer have to copy commands by hand: **`installer/` ships a one-command
installer, and it leaves a `drm-tui` command behind**.

```
bash installer/install-drm-tui.sh          # first command on a fresh container (model gate -> fetch -> verify)
sudo bash installer/drm-tui.sh install     # interactive install (mirror probe -> components -> deps -> shortcuts)
drm-tui                                    # daily use: enter/leave takeover, repair, updates, settings
```

The menu inverts with the detected state: **when a DRM takeover round is live it only offers
"Return to Android"**; "Enter DRM takeover" appears solely in anland / plain-Android states —
**a second takeover entry never exists while a round is alive** (re-running desk-takeover
mid-round kills the working desktop; that is a documented, real incident).
Running a round is no longer "it flashed and I don't know where it stalled": the scripts' own
judge lines are rendered as a stage list (precheck -> nodes/udev -> Android display down ->
kwin on screen -> Plasma -> XWayland -> WiFi) with per-stage timing, and the hand-back chain
gets its own stage table.

Settings can install anything you skipped later: desktop shortcuts, the droid-pc-keyboard input
method, **its sub-option "pop the VKB for X11 apps" (= install the patched kwin; roll back with
`install-anland-kde.sh --uninstall`)**, whether the container takes over WiFi during takeover,
the Bluetooth bridge, the audio bridge, whether handing back relaunches anland (default on),
log directory, UI language and mirror source. The Advanced page holds the GPUFLOOR / PERFMAX
experimental knobs, **all off by default** (their measured payoff and cost are shown inline).

The installer runs 10 steps. **Step 1 establishes the container -> Android adb channel**: the
user enables Wireless debugging on the tablet and pairs once (one IP, but the pairing port and the
connection port are different), then the connection port is pinned to 5555 to make the bridge
durable. This device never shows a USB consent dialog and `adb root` is refused by the production
build, so root only comes from `adb shell su -c`. **Step 10 deploys the Android-side bridge
artifacts**: the audio bridge (`argsloop` + `halsink.sh` + the three piano line-templates) and the
Bluetooth bridge (`bthci-bridge-v2`) are fetched from their own releases, sha256-verified, pushed to
`/data/local/tmp`, then re-checked by "is the file there and executable". Those binaries previously
existed only on the development machine, which is why a fresh install had no sound and no Bluetooth.

All three releases the installer depends on must be **public** (drafts are not mirrored and are
invisible via `latest`): `droid-drm-takeover v0.1.0`, `droid-audio-bridge v0.1.0`,
`droid-bluetooth-bridge v0.1.1`. Components and versions live in
`installer/lib/components.lock.json`; the main repo's own tag/sha256 are filled by CI into the
**standalone** lock asset on the release — the copy embedded in the tar is necessarily empty (that
tar cannot carry its own digest), so for this component the installer queries the release API.

> Status: `v0.1.0` is published for the main repo, and the download chain plus sha256 verification
> measured clean from this container (gh-proxy source, byte-identical). **The full install flow has
> not been run end-to-end on a fresh container yet**; the `extract_release()` case that read the
> empty embedded lock is fixed (it now queries `releases/latest`).

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
| `BT_BIN` | `/data/local/tmp/bthci-bridge-v2` | Which bridge binary to run. The default is already the instrumented v2 (measured in a real 09-30 round: 240 commands forwarded, kernel-side `errors:0`, `outstanding=[]`, every pty write completed with no drops); to fall back to the old build write `echo 'BT_BIN=/data/local/tmp/bthci-bridge' > /run/drm-round.conf` — both binaries stay in place |
| `AUDIO_BRIDGE` | `0` in the scripts, **`1` as written by the installer into `/etc/drm-takeover.conf`** | Route A built-in speaker output during takeover rounds. Running the scripts bare keeps it off because it fights Bluetooth A2DP for the same output route (Route A stops audioserver and claims the deep_buffer/speaker ports, which mutes the headphones — measured). Per the user's decision (10-01) WiFi / Bluetooth / audio are all default-on after an install, and the conf value overrides the script default; to disable temporarily write `echo 'AUDIO_BRIDGE=0' > /run/drm-round.conf`. Failures only warn and **never trigger a rollback** |
| `AUDIO_ROUTE` | `a` | `a` = direct vendor AIDL HAL (`argsloop` SINK + `aa-feeder`, speaker output measured); `b` = fallback AAudio route |

## Subsystem status

| Subsystem | Implementation | Status |
|---|---|---|
| Display | kwinwrap handover + kwin DRM backend | Stable; piano requires split_commit to rewrite single-pipe virtual planes into paired planes (object IDs drift per boot, see known issues) |
| Touch | Synthetic udev properties + libinput calibration matrix, kwin as the sole reader | Working (10-finger) |
| Network | Bare NetworkManager process managing wlan0 directly; SSID/PSK read from Android before takeover; `ip rule` backup/restore of the standard three tables; polkit rules granted, plasma-nm desktop UI can connect and change passwords | Working; association/egress failures only warn, never take the desktop down with them |
| Bluetooth | droid-bluetooth-bridge (vendor HAL binder client → pty H4 → kernel hci0 → container BlueZ); `scripts/bt-keepalive.sh` stays resident during the round | Mouse/HID working; A2DP audio output verified. Inside a round Bluetooth follows the same "on by default, cannot be switched off" policy as WiFi: once the adapter is detected it is explicitly powered on and `Powered: yes` is measured (BT-POWER); a dbus bus policy refuses desktop-user writes to adapter properties and is self-checked every round (BT-LOCK; Bluetooth has no polkit equivalent here); power loss and stalls are handled by the watchdog on a three-step ladder — kernel `hciconfig up` re-kick → relaunch the bridge (kill the old one first, max 2 per round) → stand down and dump `logs/bt-wedge-*.txt` (BT-KICK/BT-RESTART/BT-GIVEUP). Once Bluetooth is powered we clear the **class-level rfkill soft-block** once (`BT-UNBLOCK OK`, `scripts/bt-rfkill-unblock.sh`): this device has two `type=bluetooth` rfkill entries (the vendor's `bt_power` and our `hci0`), and if either one is soft-blocked bluedevil reports "Bluetooth disabled" and draws no tray icon — it reads `BluezQt::isBluetoothBlocked()`, not `Adapter1.Powered` — while the mouse keeps working. This step automates exactly what the user used to do by hand (flip the Bluetooth switch once). As a fallback for shells that still don't re-read, `BT_UI_REFRESH=1` reloads plasmashell after power-on (`BT-UI-REFRESH`). **The trigger is a hard kernel-side signal** (`hciconfig` cannot read the local name and `dmesg`'s `tx timeout` count is climbing → BT-DEADCHANNEL), never bluez's `Powered` — measured still `yes` while the channel was dead. If the `bt_power` rfkill reads soft=1 at round start it only marks `BT-POWER-PENDING`/`BT-CHIP-BLOCKED` and **waits**: measured as a startup transient that clears on its own, after which a single root `power on` brings it up — the very same bridge that was never relaunched jumped from `forwarded=50` to 150+. We never unblock that rfkill by hand (chip power belongs to the vendor HAL/btpower — a project red line) and never relaunch the bridge while waiting, since each relaunch unregisters hci0 and blows away the pending power-up window. Bridge processes are **matched by comm** (`pgrep bthci-bridge`, no `-x`, no `-f`): the bridge lives in the **Android PID namespace**, so `-x bthci-bridge` silently misses the renamed v2 — handover and rollback then fail to kill it and the round-start single-instance probe fails to see it, so a second bridge gets started (two HAL clients on one chip = the worst path); the two container-side `pkill` lines in desk-stop were no-ops from the beginning, i.e. a fake guard. `-f` is worse: the `su -c` wrapper shell self-matches (measured: 5 of 6 "hits" were wrappers). New markers: `BT-BRIDGE ONLY` (exactly one, with pid+comm) / `BT-BRIDGE MULTI` (≥2 ⇒ Bluetooth is untrusted this round, run desk-stop first) / `BT-BRIDGE-AFTER-ROLLBACK` (leftover after rollback) / `BT-LEAK-STILL` (still alive on the Android side after SIGKILL); `BT-HANDOVER OK` is now only printed after actually querying the Android side |
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
