# android-goldfish-exp

A small Android (goldfish/ranchu) emulator front-end for Apple Silicon. The plan is at `~/.claude/plans/plan-for-a-goldfish-based-swift-comet.md`.

## Status
- **Phase 1 (done):** prebuilt SDK emulator + API 37 arm64 image, with GPU findings and a device oracle captured locally in `oracle/` (gitignored).
- **Phase 2 (done):** `frontend/`, a minimal Cocoa window (`Mini`).
- **Phase 3 (works):** Mini's own engine. Upstream QEMU 11.1.2 with `patches/qemu`, plus gfxstream and rutabaga built from source, boots the stock goldfish image. It is now Mini's only engine: the Android Emulator backend is gone.

## Run
```sh
scripts/bundle.sh && open build/Mini.app             # builds MoltenVK and QEMU on first use, then the app
cd frontend && swift build && .build/debug/Mini --start goldfish37   # dev run
scripts/build-mini.sh [device]                       # rebuild, quit Mini, reopen (on device, or in Devices)
```
Requires Xcode at build time. CI (`.github/workflows/build.yml`, macOS 26 arm64) builds and caches the private-API MoltenVK, runs `swift test`, and uploads an unsigned `Mini.zip`. Downloaded builds are ad-hoc signed, so clear quarantine first: `xattr -dr com.apple.quarantine Mini.app`.

**Downloads.** Google's SDK license doesn't allow shipping adb or system images, so Mini doesn't. On first launch Mini shows the license text from Google's SDK repository. Once you accept, it downloads pinned platform-tools (37.0.1, SHA-1 checked) into `~/Library/Application Support/Mini/platform-tools`; Mini drives the guest with that adb. The API 37 Google APIs image is offered the same way when you create the first device. Everything Mini keeps lives in that folder: `system-images/` in the SDK's layout, and `Devices/<name>/` with each device's `config.ini` and disks. Android Studio's SDK and AVDs are not used.

**LineageOS image (optional).** `scripts/build-lineage.sh` builds a LineageOS 24.0 (Android 17, API 37) `sdk_phone_arm64` userdebug image from source. Run it on a Linux x86_64 box with about 32 GB RAM and 300 GB disk, since AOSP doesn't build on macOS and GitHub's free runners are too small. It writes `build/lineage/<branch>-sdk_phone_arm64-<date>.zip` plus a `.sha256`. Unzip it into `~/Library/Application Support/Mini/system-images/android-37/lineage/` and create a device from it in Devices.

**Devices** (⇧⌘D) lists your devices. From there you can create one from any installed system image, set its screen size, memory, storage (changing it erases the device's data, since only a fresh data disk takes a new size), desktop windowing (freeform) and refresh rate (60/90/120 Hz; above 60 Mini lifts Android's 60 Hz default cap over adb after boot), Start it (Mini restarts on it), or move it to the Trash. Mini opens to this window; `--start <device>` boots that device directly (`open build/Mini.app --args --start goldfish37`). Mini can download Google's API 37 Google APIs image (about 2.2 GB, license shown first, SHA-1 checked).

**Import GSI** (in Devices) turns an arm64 GSI (`.img` or `.img.xz`) into a device. It uses `scripts/gsi-image.py`, which is bundled in Mini.app and needs `brew install lz4 e2fsprogs`. The GSI boots on Google's API 37 kernel, vendor and ramdisk, with no super partition: the stock image's fstab is rewritten to mount plain GPT partitions. The result goes to `system-images/android-37.0/gsi_<name>/`. It contains Google's vendor, so don't redistribute it.

**QEMU engine.** `scripts/build-qemu.sh` builds the engine into `third_party/install`; it needs `brew install meson ninja rust pkg-config glib pixman libslirp vulkan-loader`. `bundle.sh` runs it and copies QEMU, with its libraries rewritten to load from inside the app, into `Mini.app/Contents/Resources/qemu`. The patches:
- `qemu/0001`: gfxstream feature flags and the display size for rutabaga.
- `qemu/0002`: `android-vsock-pci`, a userspace virtio-vsock device. The goldfish vendor talks to the host over vsock: qemud boot properties and sensors on port 5000, adbd on 5555. The device serves those, including an accelerometer that follows Mini's rotate buttons.
- `qemu/0003`: `mini-display`. It copies frames, rotated, into double-buffered POSIX shared memory that Mini maps, and takes touch, key and rotation messages over a socket.
- `qemu/0004`: a fixed goldfish battery on `virt`: on AC, charging, 100%.
- `qemu/0005`: display surfaces in POSIX shared memory (`qemu_shm_alloc`) on macOS, where QEMU's memfd fallback would use a temp file that gets written to disk every frame.
- `rutabaga_gfx/0001`: the display size in rutabaga's C interface.

Mini also answers the guest's Bluetooth itself: `bt_vhci_forwarder` bridges `/dev/vhci` to a virtio-console port, and
`frontend/Sources/Mini/Bluetooth.swift` plays a dummy HCI controller on the host end. With nothing there, the kernel's
HCI setup never finishes, `hci0` stays hidden from mgmt and Android's Bluetooth HAL spins a core; with it, Bluetooth
switches on (Classic only, no LE) and idles.

The guest uses ANGLE on gfxstream Vulkan over virtio-gpu, with minigbm gralloc. Mini writes the bootconfig itself (`Devices/<name>/initrd-mini`). After boot it registers the guest with adb as `emulator-5554` and, through `adb root`, wraps eth0 in the guest's `virt_wifi` driver. That driver shows QEMU's user network to Android as the "VirtWifi" access point, since the image only routes through Wi-Fi. A new device gets an ext4 data disk made with `mke2fs` (`brew install e2fsprogs`). Quitting runs `svc power shutdown` while the window shows "Android is shutting down…", so /data unmounts cleanly.

| Input | Action |
|---|---|
| click / drag | touch |
| typing | keys (Mac keycodes → evdev) |
| title bar | Back, Home, Overview, Rotate ⟲/⟳, Volume −/+, Power, Screenshot (saved to Desktop) |
| ⌘⇧H / ⌘⌫ / ⌘O / ⌘P | Home / Back / Overview / Power |
| ⌘, / ⌘L | Settings / log (`~/Library/Logs/Mini/<device>.log`) |
| ⌘Q | quit (Android shuts down first) |

### Settings
One option, applied the next time a device starts: **Kernel console and logcat** written next to the log (`<device>-kernel.log`, `<device>-logcat.log`). Otherwise they go nowhere.

Frames are letterboxed and never stretched. Clicks are mapped back through the letterbox and the current rotation into panel coordinates. `swift test` covers that mapping.

## Known limits
- Graphics: guest GLES (3.1) runs on **ANGLE in the guest** over gfxstream Vulkan, and gfxstream renders it with **MoltenVK** on the host. Every guest flush is copied once on the CPU.
- No camera, GPS or quick boot. Overview goes through `adb shell input` (QEMU has no key code for KEY_APPSELECT). On images without an Ethernet service, internet needs an adbd that allows root: Google APIs images do, Play Store and most GSI user builds don't.
- The adb port (5555, `emulator-5554`) is fixed, so you can only run one device at a time.
