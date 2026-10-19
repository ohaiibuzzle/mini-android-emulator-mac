# android-goldfish-exp

A small Android (goldfish/ranchu) emulator front-end for Apple Silicon. The plan is at `~/.claude/plans/plan-for-a-goldfish-based-swift-comet.md`.

## Status
- **Phase 1 (done):** prebuilt SDK emulator + API 37 arm64 image, with GPU findings and a device oracle captured locally in `oracle/` (gitignored).
- **Phase 2 (done):** `frontend/`, a minimal Cocoa window (`Mini`).
- **Phase 3 (todo):** gfxstream with host ANGLE, then upstream QEMU.

## Run
```sh
cd frontend && swift build && .build/debug/Mini goldfish37   # AVD name, default goldfish37
```
Requires `protoc` (`brew install protobuf`) at build time.

**The AVD needs `hw.keyboard=yes`** in `~/.android/avd/<name>.avd/config.ini`, otherwise the guest has no keyboard device and keys are dropped. `avdmanager` defaults it to `no`.

| Input | Action |
|---|---|
| click / drag | touch |
| typing | keys (Mac keycodes → evdev) |
| ⌘⇧H / ⌘⌫ / ⌘O / ⌘P | Home / Back / Overview / Power |
| ⌘Q | quit (saves the quick-boot snapshot) |

How it works: Mini launches `emulator -no-window -gpu host -grpc 8554 -grpc-use-token`, reads `grpc.token` from the emulator's discovery file, streams frames over gRPC into a shared mmap file (`ImageTransport.MMAP`), and sends input over one ordered `streamInputEvent` stream.

## Known limits
- GLES uses the emulator's GLES→desktop-GL translator (GLES 3.0), not ANGLE. Vulkan uses MoltenVK. Details are in the local `oracle/README.md`.
- Frames can tear (single shared buffer, no double buffering).
- Port 8554 is fixed, so you can only run one instance at a time.
