# android-goldfish-exp

A small Android (goldfish/ranchu) emulator front-end for Apple Silicon. The plan is at `~/.claude/plans/plan-for-a-goldfish-based-swift-comet.md`.

## Status
- **Phase 1 (done):** prebuilt SDK emulator + API 37 arm64 image, with GPU findings and a device oracle captured locally in `oracle/` (gitignored).
- **Phase 2 (done):** `frontend/`, a minimal Cocoa window (`Mini`).
- **Phase 3 (todo):** upstream QEMU + ported goldfish devices.

## Run
```sh
scripts/bundle.sh && open build/Mini.app             # builds MoltenVK on first use, then the app
cd frontend && swift build && .build/debug/Mini goldfish37   # dev run; arg = AVD name
```
Requires `protoc` (`brew install protobuf`) and Xcode at build time. CI (`.github/workflows/build.yml`, macOS 26 arm64) builds and caches the private-API MoltenVK, runs `swift test`, and uploads an unsigned `Mini.zip`. Downloaded builds are ad-hoc signed, so clear quarantine first: `xattr -dr com.apple.quarantine Mini.app`.

**Emulator download.** The SDK license doesn't allow shipping Google's emulator, so Mini doesn't. On first launch Mini shows the license text from Google's SDK repository. Once you accept, it downloads a pinned Android Emulator (Canary 37.3.4, SHA-1 checked) into `~/Library/Application Support/Mini/emulator`. Your SDK's own emulator is untouched. Mini then replaces that copy's `libMoltenVK.dylib` with the one `bundle.sh` bundles: MoltenVK 1.4.2 built with `MVK_USE_METAL_PRIVATE_API=1`, Apache-2.0. That build adds `VK_EXT_provoking_vertex`, which guest ANGLE needs for GLES 3.x. A `swift run` dev build has no bundle, so it keeps Google's MoltenVK, and the guest only gets ES 2.0. System images and AVDs still come from the SDK (`ANDROID_HOME`, default `~/Library/Android/sdk`).

**Pick the AVD** in Settings (⌘,) or pass it as the first argument. `goldfish37` is a phone (1080×2400). `freeform37` uses the "13.5in Freeform" profile: 2560×1440 landscape with freeform app windows enabled, though apps still open fullscreen until you move one into a window.

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
- Frames can tear (single shared buffer, no double buffering).
- Port 8554 is fixed, so you can only run one instance at a time.
