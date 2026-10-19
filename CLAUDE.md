# Mini

A macOS (Apple Silicon) front-end that boots Google's goldfish/ranchu Android images on its own engine: upstream QEMU 11.1.2 + `patches/qemu`, with gfxstream and rutabaga built from source. The Swift app is in `frontend/`. The README covers what it does for users; this file covers how to work on it.

## Layout
- `frontend/Sources/Mini/`: the app (SwiftPM, no dependencies). `main.swift` holds the window, input and frame loop; `Qemu.swift` builds the command line, bootconfig and disks, and holds `GuestSetup`, which drives adb. `Modem.swift`, `Bluetooth.swift` play the host side of the guest's modem and HCI. `Devices.swift`, `Setup.swift` and `Settings.swift` are the windows and the downloads.
- `frontend/Sources/CShm/`: a C shim, because Swift can't call the variadic `shm_open`.
- `patches/qemu/000N-*.patch`, `patches/rutabaga_gfx/`: our changes to the third-party trees.
- `third_party/` (git-ignored): `qemu`, `gfxstream`, `rutabaga_gfx` checkouts, plus `install/` (the built engine).
- `scripts/`: `build-qemu.sh` (engine + MoltenVK), `bundle.sh` (→ `build/Mini.app`), `build-mini.sh [device]` (rebundle and relaunch), `gsi-image.py` (GSI import, bundled into the app), `build-shadertranslator.sh` (CI only, see below).
- `assets/`: the app icon (`icon.svg`, rendered into the committed `Mini.icns` by `scripts/make-icon.sh`).
- Runtime data lives in `~/Library/Application Support/Mini`: `platform-tools/`, `system-images/` (SDK layout), and `Devices/<name>/` (`config.ini` in the emulator's keys, the qcow2 overlays, `initrd-mini`). Logs go to `~/Library/Logs/Mini/<device>.log`.

## Commands
```sh
swift test --package-path frontend          # unit tests (fast; no VM)
scripts/bundle.sh                            # full app build, including QEMU
scripts/build-mini.sh <device>               # rebuild, quit Mini gracefully, reopen on <device>
ninja -C third_party/qemu/build-mini qemu-system-aarch64   # quick QEMU rebuild
third_party/qemu/build-mini/pyvenv/bin/meson configure third_party/qemu/build-mini -D...  # meson isn't on PATH
```
- Try a change without touching the user's devices: run `MINI_HOME=<scratch dir> build/Mini.app/Contents/MacOS/Mini --start <device>`. Use `cp -c` to clone a system image into the scratch dir for free.
- The guest is `emulator-5554`; use `<Mini home>/platform-tools/adb`.
- To quit Mini, use `osascript -e 'quit app "Mini"'`. That lets Android shut down; killing QEMU risks /data.

## QEMU patches
- Edit inside `third_party/qemu`, then export: `git -C third_party/qemu diff -- <files> > patches/qemu/000N-<name>.patch`, one patch per concern.
- `build-qemu.sh` applies each patch file unless it's already applied, so the files in `patches/` are what a build uses. If a working-tree edit isn't exported yet, `bundle.sh` fails with "patch does not apply".
- `qemu-system-aarch64` must be signed with `accel/hvf/entitlements.plist`, or HVF refuses it. `bundle.sh` does this.

## Traps already paid for
- **No mapped files for anything hot.** macOS writes the dirty pages of an mmap'd regular file back to disk: gigabytes per minute for frame buffers. Use POSIX shm (`qemu_shm_alloc` in QEMU, `CShm` in Swift).
- **shm sizes round up to a page** (16 KB), and `fstat` reports the rounded size. A shm object can't be `ftruncate`d twice. Any size two processes share must be page-aligned (see `FrameBuffer`).
- **`FileHandle.bytes` shares one serial queue across all handles.** A blocking idle reader stalls every other stream, including frames. Put long-lived blocking readers on their own `Thread` (see `Modem.run`).
- **The radio HAL aborts on any reply it can't parse**, and that takes telephony down. Every `Modem` reply must match a parser in the HAL's `AtResponse.cpp`, and lines end in a bare `\r`.
- **`/dev/vport7pN` names depend on device order**: the seven virtio-mmio disks/net/rng come first, then the virtio-serial ports. Adding or reordering devices renumbers them, and the boot-props in `Qemu.arguments` must follow.
- **`adb shell svc power shutdown` returns failure on success**, because the guest drops the connection. Never read its result as "the guest didn't get it".
- **Data disks are made pre-zeroed** (`mke2fs -E lazy_itable_init=0,lazy_journal_init=0,assume_storage_prezeroed=1`). Without this, the guest's ext4lazyinit writes the whole disk and stalls boot.
- **Host GLES needs `libshadertranslator.dylib`, and it's never built on a dev machine.** CI's `shadertranslator` job builds it. To bundle it locally, download that artifact into `build/shadertranslator/`. Without it, `bundle.sh` warns and the OpenGL ES picker stays on ANGLE. Its header (`third_party/angle-st`) and the dylib come from the same pinned AOSP ANGLE revision, so they must stay matched.
- When a fix is a known shortcut, mark it with a `shortcut: <limit>, <when to upgrade>` comment; the codebase uses these as its debt list.

## Licensing (hard rules)
- **Never bundle or publish Google's binaries.** That covers the emulator, adb/platform-tools and system images, all under the Android SDK license. Mini downloads them after showing the license (`SDKDownload`).
- **Never redistribute GSI-derived images.** They contain Google's vendor.
- **`oracle/`** (captured device data, git-ignored) is never shipped or published.
- **QEMU is GPL.** A Mini.app handed to anyone needs the source offer and the Homebrew libraries' licenses, which `bundle.sh` doesn't copy yet.

## Working rules
- Commit or push only when asked. No `Claude-Session` or other attribution lines in commits or PRs.
- Never post synthetic clicks or keystrokes to the user's desktop. To check the UI, capture Mini's own window (`screencapture -l <window id>`).
- The plan and its history are in `~/.claude/plans/plan-for-a-goldfish-based-swift-comet.md`.
