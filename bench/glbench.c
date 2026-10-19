// GLES 2.0 microbenchmark for comparing the emulator's GLES paths.
// ES 2.0 because guest ANGLE on gfxstream/MoltenVK refuses 3.x contexts; the translator does 2.0 too.
// Renders offscreen into an EGL pbuffer; every timed iteration ends in glFinish so host work is counted.
// Build: see bench/run.sh. Run in the guest: /data/local/tmp/glbench
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W 1080
#define H 2400
#define SECONDS 2.0

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec * 1e-9;
}

static void die(const char *what) {
  fprintf(stderr, "glbench: %s failed (egl 0x%x, gl 0x%x)\n", what, eglGetError(), glGetError());
  exit(1);
}

static GLuint shader(GLenum type, const char *src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint ok;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[1024];
    glGetShaderInfoLog(s, sizeof log, NULL, log);
    fprintf(stderr, "shader: %s\n", log);
    exit(1);
  }
  return s;
}

static GLuint program(const char *fs) {
  static const char *vs =
      "attribute vec2 p; uniform vec2 off; uniform float scale; varying vec2 uv;\n"
      "void main() { uv = p * 0.5 + 0.5; gl_Position = vec4(p * scale + off, 0.0, 1.0); }\n";
  GLuint p = glCreateProgram();
  glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
  glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
  glBindAttribLocation(p, 0, "p");
  glLinkProgram(p);
  GLint ok;
  glGetProgramiv(p, GL_LINK_STATUS, &ok);
  if (!ok) die("link");
  return p;
}

// Runs `body` repeatedly for SECONDS (after one warm-up call); returns iterations per second.
#define TIMED(body)                                    \
  ({                                                   \
    body;                                              \
    glFinish();                                        \
    long n = 0;                                        \
    double t0 = now(), t;                              \
    do {                                               \
      body;                                            \
      glFinish();                                      \
      n++;                                             \
    } while ((t = now() - t0) < SECONDS);              \
    n / t;                                             \
  })

int main(void) {
  EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (!eglInitialize(d, NULL, NULL)) die("eglInitialize");
  const EGLint cfgAttr[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  if (!eglChooseConfig(d, cfgAttr, &cfg, 1, &n) || n < 1) die("eglChooseConfig");
  const EGLint surfAttr[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
  EGLSurface s = eglCreatePbufferSurface(d, cfg, surfAttr);
  if (s == EGL_NO_SURFACE) die("eglCreatePbufferSurface");
  const EGLint ctxAttr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLContext c = eglCreateContext(d, cfg, EGL_NO_CONTEXT, ctxAttr);
  if (c == EGL_NO_CONTEXT) die("eglCreateContext");
  if (!eglMakeCurrent(d, s, s, c)) die("eglMakeCurrent");

  // Both paths render into the same 1080x2400 RGBA framebuffer (texture-backed: core ES 2.0).
  GLuint fbo, target;
  glGenTextures(1, &target);
  glBindTexture(GL_TEXTURE_2D, target);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) die("framebuffer");

  printf("renderer\t%s\nversion\t%s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

  static const float quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
  GLuint vbo;
  glGenBuffers(1, &vbo);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
  glViewport(0, 0, W, H);

  GLuint flat = program("precision mediump float; uniform vec4 col;\n"
                        "void main() { gl_FragColor = col; }\n");
  GLuint alu = program(
      "precision highp float; varying vec2 uv;\n"
      "void main() { vec2 z = uv; for (int i = 0; i < 64; i++) z = vec2(sin(z.x * 3.1 + z.y), cos(z.y * 2.7 - z.x));\n"
      "  gl_FragColor = vec4(z * 0.5 + 0.5, 0.0, 1.0); }\n");
  GLuint texd = program("precision mediump float; varying vec2 uv; uniform sampler2D t;\n"
                        "void main() { gl_FragColor = texture2D(t, uv); }\n");

  // 1. Draw calls: 2000 tiny quads per frame, a uniform change each (command-stream bound).
  glUseProgram(flat);
  GLint col = glGetUniformLocation(flat, "col"), off = glGetUniformLocation(flat, "off"),
        scale = glGetUniformLocation(flat, "scale");
  glUniform1f(scale, 0.01f);
  double drawFrames = TIMED({
    for (int i = 0; i < 2000; i++) {
      glUniform2f(off, (i % 50) / 25.0f - 1, (i / 50) / 20.0f - 1);
      glUniform4f(col, i / 2000.0f, 0.5f, 0.2f, 1);
      glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
  });
  printf("draw_calls\t%.0f\tdraws/s\n", drawFrames * 2000);

  // 2. Fill: 8 blended fullscreen quads per frame.
  glUniform1f(scale, 1);
  glUniform2f(off, 0, 0);
  glUniform4f(col, 0.1f, 0.2f, 0.3f, 0.1f);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  double fillFrames = TIMED({ for (int i = 0; i < 8; i++) glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); });
  glDisable(GL_BLEND);
  printf("fill\t%.0f\tMpix/s\n", fillFrames * 8 * W * H / 1e6);

  // 3. Shader ALU: one fullscreen quad of 64 sin/cos iterations per pixel.
  glUseProgram(alu);
  glUniform1f(glGetUniformLocation(alu, "scale"), 1);
  double aluFrames = TIMED(glDrawArrays(GL_TRIANGLE_STRIP, 0, 4));
  printf("shader_alu\t%.0f\tMpix/s\n", aluFrames * W * H / 1e6);

  // 4. Texture upload: 1024x1024 RGBA per iteration, then sample it so the upload can't be skipped.
  enum { T = 1024 };
  unsigned char *pixels = malloc(T * T * 4);
  for (int i = 0; i < T * T * 4; i++) pixels[i] = (unsigned char)(i * 31);
  GLuint tex;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, T, T, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glUseProgram(texd);
  glUniform1f(glGetUniformLocation(texd, "scale"), 1);
  double uploads = TIMED({
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, T, T, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  });
  printf("tex_upload\t%.0f\tMB/s\n", uploads * T * T * 4 / 1e6);

  // 5. Readback: full-frame glReadPixels.
  unsigned char *frame = malloc(W * H * 4);
  double reads = TIMED(glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, frame));
  printf("readback\t%.0f\tMB/s\n", reads * W * H * 4 / 1e6);

  // 6. Round trip: a scissored 1-pixel clear + glFinish; measures guest->host->guest latency.
  glEnable(GL_SCISSOR_TEST);
  glScissor(0, 0, 1, 1);
  double finishes = TIMED(glClear(GL_COLOR_BUFFER_BIT));
  printf("roundtrip\t%.1f\tus\n", 1e6 / finishes);

  if (glGetError() != GL_NO_ERROR) die("gl");
  return 0;
}
