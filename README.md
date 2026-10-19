# android-goldfish-exp

A small Android (goldfish/ranchu) emulator front-end for Apple Silicon. The plan is at `~/.claude/plans/plan-for-a-goldfish-based-swift-comet.md`.

## Status
- **Phase 1 (done):** prebuilt SDK emulator + API 37 arm64 image, with GPU findings and a device oracle captured locally in `oracle/` (gitignored).
- **Phase 2 (done):** `frontend/`, a minimal Cocoa window (`Mini`).
- **Phase 3 (todo):** upstream QEMU + ported goldfish devices.

## Run
```sh
scripts/bundle.sh && open build/Mini.app             # self-contained app, emulator copied inside
cd frontend && swift build && .build/debug/Mini goldfish37   # dev: uses the SDK's emulator; arg = AVD name
```
Requires `protoc` (`brew install protobuf`) at build time. `bundle.sh` pins a copy of the SDK emulator (~1.3 GB) into `build/Mini.app`, which is gitignored. That copy is for local use only, because the SDK license restricts redistributing it. System images and AVDs still come from the SDK (`ANDROID_HOME`, default `~/Library/Android/sdk`).

**The AVD needs `hw.keyboard=yes`** in `~/.android/avd/<name>.avd/config.ini`, otherwise the guest has no keyboard device and keys are dropped. `avdmanager` defaults it to `no`.

| Input | Action |
|---|---|
| click / drag | touch |
| typing | keys (Mac keycodes → evdev) |
| ⌘⇧H / ⌘⌫ / ⌘O / ⌘P | Home / Back / Overview / Power |
| ⌘Q | quit (saves the quick-boot snapshot) |

How it works: Mini launches `emulator -no-window -gpu host -feature GuestUsesAngle -grpc 8554 -grpc-use-token`, reads `grpc.token` from the emulator's discovery file, streams frames over gRPC into a shared mmap file (`ImageTransport.MMAP`), and sends input over one ordered `streamInputEvent` stream.

## Known limits
- Graphics: guest GLES (3.1) runs on **ANGLE in the guest** over gfxstream Vulkan, and gfxstream renders it with **MoltenVK** on the host. Host-side ANGLE would need a gfxstream source build that matches the emulator's exact commit, and 37.x source isn't public. The local `oracle/README.md` has the details.
- Frames can tear (single shared buffer, no double buffering).
- Port 8554 is fixed, so you can only run one instance at a time.
