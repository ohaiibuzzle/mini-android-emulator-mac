# android-goldfish-exp

A small Android (goldfish/ranchu) emulator front-end for Apple Silicon. The plan is at `~/.claude/plans/plan-for-a-goldfish-based-swift-comet.md`.

## Status
- **Phase 1 (done):** prebuilt SDK emulator + API 37 arm64 image, with GPU findings and a device oracle captured locally in `oracle/` (gitignored).
- **Phase 2 (done):** `frontend/`, a minimal Cocoa window (`Mini`).
- **Phase 3 (works):** Mini's own engine. Upstream QEMU 11.1.2 with `patches/qemu`, plus gfxstream and rutabaga built from source, boots the stock goldfish image with no Google host binaries.

## Run
```sh
scripts/bundle.sh && open build/Mini.app             # builds MoltenVK on first use, then the app
cd frontend && swift build && .build/debug/Mini --start goldfish37   # dev run
scripts/build-mini.sh [avd]                          # rebuild, quit Mini, reopen (on avd, or in Devices)
```
Requires `protoc` (`brew install protobuf`) and Xcode at build time. CI (`.github/workflows/build.yml`, macOS 26 arm64) builds and caches the private-API MoltenVK, runs `swift test`, and uploads an unsigned `Mini.zip`. Downloaded builds are ad-hoc signed, so clear quarantine first: `xattr -dr com.apple.quarantine Mini.app`.

**Emulator download.** The SDK license doesn't allow shipping Google's emulator, so Mini doesn't. On first launch Mini shows the license text from Google's SDK repository. Once you accept, it downloads a pinned Android Emulator (Canary 37.3.4, SHA-1 checked) into `~/Library/Application Support/Mini/emulator`. Your SDK's own emulator is untouched. Mini then replaces that copy's `libMoltenVK.dylib` with the one `bundle.sh` bundles: MoltenVK 1.4.2 built with `MVK_USE_METAL_PRIVATE_API=1`, Apache-2.0. That build adds `VK_EXT_provoking_vertex`, which guest ANGLE needs for GLES 3.x. A `swift run` dev build has no bundle, so it keeps Google's MoltenVK, and the guest only gets ES 2.0. System images and AVDs still come from the SDK (`ANDROID_HOME`, default `~/Library/Android/sdk`).

**LineageOS image (optional).** `scripts/build-lineage.sh` builds a LineageOS 24.0 (Android 17, API 37) `sdk_phone_arm64` userdebug image from source, so Google's emulator is the only part we don't build. Run it on a Linux x86_64 box with about 32 GB RAM and 300 GB disk, since AOSP doesn't build on macOS and GitHub's free runners are too small. It writes `build/lineage/<branch>-sdk_phone_arm64-<date>.zip` plus a `.sha256`. Unzip it into `$ANDROID_HOME/system-images/android-37/lineage/` and create an AVD from it with `avdmanager`.

**Devices** (⇧⌘D) lists your AVDs. From there you can create one from any installed system image, set its screen size, memory, storage (changing it erases the device's data, since the emulator only sizes a fresh data partition), desktop windowing (freeform) and refresh rate (60/90/120 Hz; above 60 Mini lifts Android's 60 Hz default cap over adb after boot), Start it (Mini restarts on it), or move it to the Trash. Mini opens to this window; `--start <avd>` boots that device directly (`open build/Mini.app --args --start goldfish37`). Mini can download Google's API 37 Google APIs image (about 2.2 GB, license shown first, SHA-1 checked) into the SDK.

**Import GSI** (in Devices) turns an arm64 GSI (`.img` or `.img.xz`) into a device. It uses `scripts/gsi-image.py`, which is bundled in Mini.app and needs `brew install lz4 e2fsprogs`. The GSI boots on Google's API 37 kernel, vendor and ramdisk, with no super partition: the stock image's fstab is rewritten to mount plain GPT partitions. The result goes to `system-images/android-37.0/gsi_<name>/`. It contains Google's vendor, so don't redistribute it.

**QEMU engine.** Each device's *Runs on* picker (Devices) chooses Google's emulator or Mini's QEMU. Both use the same image and the same data disks, and starting on QEMU discards the emulator's quick-boot snapshot. `scripts/build-qemu.sh` builds the engine into `third_party/install`; it needs `brew install meson ninja rust pkg-config glib pixman libslirp vulkan-loader`. `bundle.sh` runs it and copies QEMU, with its libraries rewritten to load from inside the app, into `Mini.app/Contents/Resources/qemu`. The patches:
- `qemu/0001`: gfxstream feature flags and the display size for rutabaga.
- `qemu/0002`: `android-vsock-pci`, a userspace virtio-vsock device. The goldfish vendor talks to the host over vsock: qemud boot properties and sensors on port 5000, adbd on 5555. The device serves those, including an accelerometer that follows Mini's rotate buttons.
- `qemu/0003`: `mini-display`. It copies frames, rotated, into a double-buffered shared file that Mini maps, and takes touch, key and rotation messages over a socket.
- `rutabaga_gfx/0001`: the display size in rutabaga's C interface.

Mini also answers the guest's Bluetooth itself: `bt_vhci_forwarder` bridges `/dev/vhci` to a virtio-console port, and
`frontend/Sources/Mini/Bluetooth.swift` plays a dummy HCI controller on the host end. With nothing there, the kernel's
HCI setup never finishes, `hci0` stays hidden from mgmt and Android's Bluetooth HAL spins a core; with it, Bluetooth
switches on (Classic only, no LE) and idles.

The guest uses ANGLE on gfxstream Vulkan over virtio-gpu, with minigbm gralloc. Mini writes the bootconfig itself (`<avd>.avd/initrd-mini`). After boot it registers the guest with adb as `emulator-5554` and, through `adb root`, wraps eth0 in the guest's `virt_wifi` driver. That driver shows QEMU's user network to Android as the "VirtWifi" access point, since the image only routes through Wi-Fi. A new device on QEMU gets an ext4 data disk made with `mke2fs` (`brew install e2fsprogs`). Quitting runs `svc power shutdown`, so /data unmounts cleanly.

**The AVD needs `hw.keyboard=yes`** in `~/.android/avd/<name>.avd/config.ini`, otherwise the guest has no keyboard device and keys are dropped. `avdmanager` defaults it to `no`.

| Input | Action |
|---|---|
| click / drag | touch |
| typing | keys (Mac keycodes → evdev) |
| title bar | Back, Home, Overview, Rotate ⟲/⟳, Volume −/+, Power, Screenshot (saved to Desktop) |
| ⌘⇧H / ⌘⌫ / ⌘O / ⌘P | Home / Back / Overview / Power |
| ⌘, / ⌘L | Settings / emulator log (`~/Library/Logs/Mini/<avd>.log`) |
| ⌘Q | quit (saves the quick-boot snapshot) |

### Settings
They apply the next time the emulator starts. Anything that costs performance is off by default:
- **OpenGL ES:** ANGLE in the guest (default) or the host desktop-GL translator.
- **Audio** (`-no-audio` when off).
- **Radios:** Bluetooth, UWB and the cellular modem. When off, these features are disabled and `netsimd` doesn't run. Wi-Fi always stays on because it's the guest's only route to the internet.
- **Cameras** (`none` when off).
- **Kernel console and logcat** in the emulator log. The serial console is otherwise `-serial null`.

How it works: Mini launches `emulator -no-window -gpu host -grpc 8554 -grpc-use-token` plus the flags from Settings, reads `grpc.token` from the emulator's discovery file, streams frames over gRPC into a shared mmap file (`ImageTransport.MMAP`), and sends input over one ordered `streamInputEvent` stream.

Frames are letterboxed and never stretched. Clicks are mapped back through the letterbox and the current rotation into panel coordinates. `swift test` covers that mapping.

## Known limits
- Graphics: guest GLES (3.1) runs on **ANGLE in the guest** over gfxstream Vulkan, and gfxstream renders it with **MoltenVK** on the host. Host-side ANGLE would need a gfxstream source build that matches the emulator's exact commit, and 37.x source isn't public. The local `oracle/README.md` has the details.
- Frames can tear on the emulator engine (single shared buffer, no double buffering). On QEMU, every guest flush is copied once on the CPU.
- QEMU engine: no audio, camera, GPS, modem or quick boot, and the refresh rate stays at the guest default. Overview goes through `adb shell input` (QEMU has no key code for KEY_APPSELECT). Internet needs an image whose adbd allows root: Google APIs images do, Play Store and most GSI user builds don't.
- Port 8554 is fixed, so you can only run one instance at a time.
