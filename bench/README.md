# GLES path benchmark: desktop-GL translator vs guest ANGLE

`bench/run.sh [avd] [runs]` cross-compiles `glbench.c` with the NDK and cold-boots the AVD headless once per mode. It runs the benchmark `runs` times per mode and prints medians. Each test lasts 2 s, and every iteration ends in `glFinish`, so host-side work is counted.

| Mode | Guest GLES stack |
|---|---|
| translator (`-gpu host`) | `libGLESv2_emulation` → goldfish pipe → host GLES translator → Apple desktop GL 4.1 (on Metal) |
| angle (`-gpu host -feature GuestUsesAngle`) | guest ANGLE → Vulkan → gfxstream → MoltenVK → Metal |

## Results (2026-10-19, emulator 37.2.12, API 37 `goldfish37`, M1 Pro, macOS 27)
Medians of 3 runs, 1080×2400 RGBA offscreen target. Run-to-run spread was under 5%.

| metric | translator | angle | unit | winner |
|---|---:|---:|---|---|
| draw_calls (2000 tiny draws + uniforms per frame) | 658,980 | 913,515 | draws/s | ANGLE +39% |
| fill (8 blended fullscreen quads) | 20,600 | 15,938 | Mpix/s | translator +29% |
| shader_alu (64× sin/cos per pixel) | 978 | 891 | Mpix/s | translator +10% |
| tex_upload (1024² RGBA per iteration) | 2,108 | 4,144 | MB/s | ANGLE ~2× |
| readback (full-frame `glReadPixels`) | 3,283 | 6,580 | MB/s | ANGLE ~2× |
| roundtrip (tiny clear + `glFinish`) | 353 | 643 | µs | translator ~1.8× |

## Reading it
- **API level matters more than speed. ANGLE here is GLES 2.0 only.** It refuses every 3.x context (`EGL_BAD_MATCH`), even though Android advertises 3.1 (`ro.opengles.version=196609`). The translator gives a real GLES 3.0. Apps that need ES 3.x (most games, and Chrome/WebGL2) lose out under ANGLE. That's why the benchmark sticks to ES 2.0.
- **ANGLE wins when many calls are batched or data moves in bulk.** Guest ANGLE records GL calls into Vulkan command buffers and sends them in batches. Texture data goes through gfxstream's mapped host memory instead of being copied through the pipe.
- **The translator wins on GPU-bound pixel work and sync latency.** That path has one fewer translation layer (Apple's GL-on-Metal vs ANGLE→Vulkan→MoltenVK→Metal), and `glFinish` maps to a cheaper round trip.
- **UI isn't affected either way.** App UI (HWUI `skiavk`) renders through Vulkan in both modes, so these numbers only matter for GLES apps and, in ANGLE mode, SurfaceFlinger.

Not measured: real games, frame pacing, CPU usage, and Vulkan apps. Vulkan follows the same gfxstream→MoltenVK path in both modes.
