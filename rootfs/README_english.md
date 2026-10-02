[中文](README.md) | English

# Droid RootFS Builder

Builds the Droidspaces container rootfs for the Xiaomi Pad 8 Pro (`piano`):
**Ubuntu 26.04 + KDE Plasma**, with a customizable username. Every build runs in GitHub Actions.

This directory is a narrowed port of [Droidspaces-rootfs-KDE-builder](https://github.com/Yizhou147/Droidspaces-rootfs-KDE-builder).
Upstream offers 7 distributions × 5 desktops × 14 extra switches; here only four form fields remain,
and every other switch is pinned in the machine preset file.

## Prerequisite

This directory is a subdirectory of the `droid-drm-takeover` repository, and builds run in **that
repository's Actions** (the workflow file has to stay at the repository root's
`.github/workflows/build-rootfs.yml`, while all build files live here). The repository root's
`.github/workflows/release.yml` packs takeover artifacts from an explicit file list, so it never
pulls this directory into the takeover tarball.

## Build form (four fields only)

Repository → Actions → 构建 RootFS（piano / Ubuntu-26 / KDE）→ Run workflow:

| Field | Type | Allowed / default |
|---|---|---|
| Machine model | choice | `piano` only |
| Distribution | choice | `Ubuntu-26` only |
| Custom username | string | default `xyz`; 1–32 chars, starts with a letter or `_`, only `[A-Za-z0-9_-]` |
| Desktop | choice | `KDE` only |

All other switches are **absent from the form** and come from `presets/<model>.env`.

## piano preset

`presets/piano.env` is the single place those switches get their values (they equal the
upstream Chinese workflow defaults):

| Switch | Value | Note |
|---|---|---|
| `DESKTOP_AUTOSTART` | `true` | Container enters KDE on start |
| `DISPLAY_BACKEND_INPUT` | `anland-wayland` | Anland backend by default; in this mode the script forces `PulseAudio` down to `none` (Anland carries its own audio path), matching upstream. **piano must keep this value** — the patched KWin only gets installed through it, see below |
| `PulseAudio` | `socket` | Only takes effect on the X11 backend |
| `ENABLE_zh_tz` | `true` | Chinese locale + Asia/Shanghai timezone |
| `ENABLE_mesa` | `true` | Snapdragon GPU (kgsl/Mesa) support |
| `ENABLE_8gen2_wayland` | `false` | piano is SM8750 / Adreno 830; the 8 Gen 2 Turnip UBWC corruption fix is not needed |
| `ENABLE_nosnap` | `true` | Removes Snap/snapd and blocks APT from reinstalling it |
| `ENABLE_srf` | `true` | fcitx5 input method |
| `ENABLE_yj` | `true` | NAT plus Android/Droidspaces hardware recognition |
| `ENABLE_zip` | `true` | Common compression tools |
| `ENABLE_binfmt` | `false` | Cross-architecture support |
| `ENABLE_kfgj` | `false` | Development toolchain |
| `ENABLE_docker` | `false` | Docker inside the rootfs |
| `ENABLE_systemd257` | `false` | Experimental systemd 257 backport for old kernels |
| `ANLAND_RELEASE_REPOSITORY` | `Goldzxcbug/droidspaces-package` | Source of the Anland KDE packages |

One switch below is **not part of upstream's 14** — it belongs to this project:

| Switch | Value | Note |
|---|---|---|
| `ENABLE_drmtui` | `true` | Ship the takeover `drmtui` pre-installed, see below |

Adding a machine = add a `presets/<new-model>.env` and put the model name into the workflow `options`.

## The rootfs ships a fully installed drmtui

The `piano` rootfs ships the DRM takeover **already installed** (`drmtui` command, takeover scripts and
binaries, desktop baseline, shortcuts, sudoers) — not an install script nobody has run yet.

How: a **clearly marked appended block** at the end of `Ubuntu-26.Dockerfile` (absent upstream), active
when `ENABLE_drmtui=true`. It fetches `install-drm-tui.sh` from the newest `droid-drm-takeover` release,
lays down the artifacts, then runs that repository's `installer/drm-tui.sh --preinstall-offline`.

`--preinstall-offline` runs only the five steps of the install flow that **do not need the real device**:
mirror probe, apt dependencies, takeover artifacts with sha256 verification, config/shortcuts/sudoers/
`drmtui` entry, and the desktop baseline. The remaining three steps genuinely cannot run inside a Docker
build and the script **does not pretend otherwise**:

| Step | Why the build cannot do it | Who finishes it |
|---|---|---|
| Establish the Android debug channel | no adb channel to the device inside the image build | first `drmtui` run on the tablet |
| Model gate (`ro.product.device == piano`) | the property only exists on real hardware | same |
| Deploy Android-side bridges (audio sink / Bluetooth bridge) | needs pushing into `/data/local/tmp` | same |

Those three are listed and fixed by `drmtui` → Check installation / repair on the first run on the device.
The appended block ends with two hard checks (`/usr/local/bin/drmtui` exists, `desk-takeover.sh` in place),
so a failure fails the whole rootfs build — no image that merely *looks* installed.

⚠ **Know the self-reference**: this directory lives inside `droid-drm-takeover`, while the preinstall
pulls that repository's **published `releases/latest` artifacts**, not the commit that triggered the build.
After changing `installer/` or the takeover scripts, cut a release first (overwrite or add a tag so the
assets are rebuilt), then run the rootfs build — otherwise the image installs the previous release.

## piano must ship with the patched KWin

Selecting `piano` means the patched KWin (Anland backend + pc-keyd channel C, which the takeover
round needs for the X11 virtual keyboard and combo keys) has to be in the rootfs. That already happens
at build time, so nothing has to be patched after install: with `DISPLAY_BACKEND=anland-wayland`,
`Ubuntu-26.Dockerfile` runs `install-anland-desktop kde` → `install-anland-kde`, which reads
`/etc/os-release`, recognises `ubuntu:26.04`, installs the `anland-kde-ubuntu2604-kwin-*` asset
and holds those package versions.

Two CI gates keep it from being skipped silently:

1. **Before the build**: if piano's preset has `DISPLAY_BACKEND_INPUT` other than `anland-wayland`,
   the run fails — switching to the x11 backend simply does not install the patch, which would ship an
   unpatched rootfs.
2. **Measured inside the artifact**: `libkwin.so.6.*` is extracted from the `.tar.xz` and
   `grep -c PCKEYD_INPUT_SOCKET` must hit. Same judgment as `kwin_patch_present()` in the
   `droid-drm-takeover` installer; no `strings`/binutils, because a fresh environment has neither and
   only the symbol in the binary counts. No release is published if this fails.

## Output

- File name: `piano-Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-Runs<N>.tar.xz`
- The version is the Actions run number (`Runs<N>`), not a form field
- Both a workflow artifact (kept 30 days) and a Release asset are uploaded; the Release is
  **automatically converted from draft to public** (a draft never appears in `releases/latest` and never
  reaches mirrors)
- ⚠ The rootfs Release is pinned to **`prerelease=true`**: it shares this repository's release line with
  the takeover artifacts, and the installer queries `releases/latest` for the takeover tar. A plain
  (non-prerelease) rootfs Release would become `latest` and starve the installer of its asset —
  prereleases are excluded from `releases/latest`, keeping the two lines independent
- The `sha256` of the artifact is reported in the release notes and the job summary

## Provenance and upstream sync

The entire `scripts/` tree (28 files) is a **verbatim copy** of upstream at `2fc5ef2`, md5-identical.
`Ubuntu-26.Dockerfile` is also copied from upstream but carries **two marked additions** (the two `ARG`
lines for the drmtui preinstall plus that trailing `RUN` block); everything in it is otherwise byte-for-byte
upstream. Deliberately no trimmed copy: lines 35–56 of the Dockerfile `COPY` individual `scripts/` entries,
so pruning files would mean editing existing Dockerfile content — introducing build-time breakage and
turning every upstream sync into a file-by-file comparison. The cost is carrying scripts this combination
never selects, most of which (`droidspaces-tui`, `install-mesa`, …) are runtime tools that belong in the
rootfs anyway.

**Changes relative to upstream:**

1. `build_rootfs.sh` (upstream: `build_rootfs-native.sh`), three edits: switch defaults rewritten as
   `: "${VAR:=default}"` so a machine preset can supply them (command-line `-X` still wins), artifact name
   gains the `${DEVICE_MODEL}-` prefix, build banner prints machine model and username
2. `Ubuntu-26.Dockerfile`, append-only: `ARG ENABLE_drmtui_ARG`, `ARG DRMTUI_REPO_SLUG`, and the
   marked drmtui preinstall block at the end
3. New in this directory: `presets/piano.env`, `.github/workflows/build-rootfs.yml`, and this README pair

The other six `*.Dockerfile` files, `build_rootfs-qemu-aarch64.sh` and upstream `docs/` were not copied.

To sync upstream: `git pull` in `~/Documents/Droidspaces-rootfs-KDE-builder`, re-copy `scripts/` and the
Dockerfile (then move the two appended blocks back into the fresh copy), md5-compare `scripts/` and `diff`
the Dockerfile — **the diff must show only those annotated additions**. Upstream ships no LICENSE file, so
this directory invents no license statement and only records where the code came from.

## Changes in this repository that the preinstall depends on

Two edits make the preinstall possible (committed locally as `67a745a`, **not yet pushed**):

- `installer/drm-tui.sh`: new `--preinstall-offline` entry plus `preinstall_offline_flow()`
- `installer/lib/conf.sh`: `drm_conf_defaults` honours `DRM_PREINSTALL_USER`

The second one is mandatory, not cosmetic: the build runs as root with no `SUDO_USER`/`logname`, so the old
derivation resolved the install target to `root` and laid the whole artifact tree plus shortcuts into
`/root` — the real user baked into the image (`xyz`) would have received nothing.

## Status

**Not yet verified with a real build**: the development container has no docker, so locally this was limited
to shell syntax checks, an `installer/drm-tui.sh --version` smoke test of the dispatch, YAML parsing, and
confirming all 15 assembled `--build-arg` values (including `ENABLE_drmtui_ARG=true`) against a docker stub.
Verification completes only after one real CI run, checking the username and its home directory, that the
`drmtui` command and takeover artifacts landed, that the desktop baseline took effect, that the patched
KWin symbol hits, and that the first `drmtui` run on a tablet can still finish the three device-side steps.
