// Offline-ish ShaderToy renderer for FutureCity.
//
// Reads:
//   FutureCity_BufferA.glsl
//   FutureCity_Image.glsl
//
// Produces:
//   FutureCity output frames or webm
//
// This uses local WebGL2 in Chrome, not shadertoy.com, so it bypasses
// Cloudflare and gives deterministic iTime values per rendered frame.

const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

const WIDTH = Number(process.env.WIDTH || 1280);
const HEIGHT = Number(process.env.HEIGHT || 720);
const FRAMES = Number(process.env.FRAMES || 120);
const DURATION_SECONDS = Number(process.env.DURATION_SECONDS || 60);
const CAPTURE_FPS = FRAMES / DURATION_SECONDS;
const OUTPUT = path.resolve(process.env.OUTPUT || "FutureCity_preview.webm");
const CHROME_EXE = process.env.CHROME_EXE || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const ANGLE_BACKEND = process.env.ANGLE || "d3d11";
const HEADLESS = process.env.HEADLESS !== "0";
const MODE = process.env.MODE || "webm";
const FRAMES_DIR = path.resolve(process.env.FRAMES_DIR || "FutureCity_frames");

const SHADER_FILES = {
  A: "FutureCity_BufferA.glsl",
  Image: "FutureCity_Image.glsl",
};

function readShaderFiles() {
  const shaders = {};
  const missing = [];

  for (const [key, file] of Object.entries(SHADER_FILES)) {
    const abs = path.resolve(file);
    if (!fs.existsSync(abs)) {
      missing.push(file);
    } else {
      shaders[key] = fs.readFileSync(abs, "utf8");
    }
  }

  if (missing.length) {
    throw new Error(
      "Missing shader file(s):\n" +
      missing.map((m) => `  - ${m}`).join("\n") +
      "\n\nSave the ShaderToy pass code into these filenames first."
    );
  }

  return shaders;
}

const HTML = String.raw`<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <style>
    html, body { margin: 0; overflow: hidden; background: #000; }
    canvas { width: 100vw; height: 100vh; display: block; }
    #log {
      position: fixed; left: 8px; top: 8px; color: #9f9;
      font: 12px/1.35 Consolas, monospace; white-space: pre-wrap;
      background: rgba(0,0,0,.55); padding: 6px 8px;
    }
  </style>
</head>
<body>
<canvas id="c"></canvas>
<pre id="log"></pre>
<script>
const canvas = document.getElementById("c");
const logEl = document.getElementById("log");
let dummyTex = null;
function log(msg) { console.log(msg); logEl.textContent += msg + "\\n"; }

function shaderHeader() {
  return [
    "#version 300 es",
    "precision highp float;",
    "precision highp int;",
    "precision highp sampler2D;",
    "uniform vec3 iResolution;",
    "uniform float iTime;",
    "uniform float iTimeDelta;",
    "uniform int iFrame;",
    "uniform vec4 iMouse;",
    "uniform vec4 iDate;",
    "uniform float iSampleRate;",
    "uniform vec3 iChannelResolution[4];",
    "uniform sampler2D iChannel0;",
    "uniform sampler2D iChannel1;",
    "uniform sampler2D iChannel2;",
    "uniform sampler2D iChannel3;",
    "out vec4 shadertoyOut;",
    "#define texture2D texture",
    "#define fragColor shadertoyOut",
    "",
  ].join("\n");
}

const fullscreenVS = [
  "#version 300 es",
  "precision highp float;",
  "const vec2 p[3] = vec2[3](",
  "  vec2(-1.0, -1.0),",
  "  vec2( 3.0, -1.0),",
  "  vec2(-1.0,  3.0)",
  ");",
  "void main() { gl_Position = vec4(p[gl_VertexID], 0.0, 1.0); }",
  "",
].join("\n");

function wrapFragment(src) {
  src = src.replace(/^\s*#version\s+\d+.*$/gm, "");
  src = src.replace(/^\s*#pragma\s+.*$/gm, "");
  src = src.replace(/^\s*#extension\s+GL_EXT_samplerless_texture_functions\s*:\s*enable\s*$/gm, "");
  return shaderHeader() + "\n" + src + "\nvoid main(){ vec4 c=vec4(0.0); mainImage(c, gl_FragCoord.xy); shadertoyOut=c; }\n";
}

function compile(gl, type, src, name) {
  const sh = gl.createShader(type);
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    const info = gl.getShaderInfoLog(sh);
    throw new Error(name + " shader compile failed:\\n" + info);
  }
  return sh;
}

function makeProgram(gl, fragSrc, name) {
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, fullscreenVS, name + " vertex"));
  gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, wrapFragment(fragSrc), name + " fragment"));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
    throw new Error(name + " link failed:\\n" + gl.getProgramInfoLog(p));
  }
  const uniforms = {};
  for (const u of [
    "iResolution", "iTime", "iTimeDelta", "iFrame", "iMouse", "iDate", "iSampleRate",
    "iChannelResolution[0]", "iChannel0", "iChannel1", "iChannel2", "iChannel3"
  ]) {
    uniforms[u] = gl.getUniformLocation(p, u);
  }
  return { program: p, uniforms, name };
}

function createTex(gl, w, h, linear = true, bytes = null) {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, linear ? gl.LINEAR : gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, linear ? gl.LINEAR : gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, w, h, 0, gl.RGBA, gl.FLOAT, bytes);
  return tex;
}

function createKeyboardTex(gl) {
  return createTex(gl, 256, 3, false);
}

function makeTarget(gl, w, h, name) {
  const tex = createTex(gl, w, h, false);
  const fb = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
  const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
  if (status !== gl.FRAMEBUFFER_COMPLETE) {
    throw new Error(name + " framebuffer incomplete: 0x" + status.toString(16));
  }
  return { tex, fb, w, h, name };
}

function bindTexture(gl, unit, tex) {
  gl.activeTexture(gl.TEXTURE0 + unit);
  gl.bindTexture(gl.TEXTURE_2D, tex || dummyTex);
}

function setCommonUniforms(gl, pass, frame, time, dt, channelRes) {
  gl.uniform3f(pass.uniforms.iResolution, canvas.width, canvas.height, 1);
  gl.uniform1f(pass.uniforms.iTime, time);
  gl.uniform1f(pass.uniforms.iTimeDelta, dt);
  gl.uniform1i(pass.uniforms.iFrame, frame);
  gl.uniform4f(pass.uniforms.iMouse, 0, 0, -1, -1);
  gl.uniform4f(pass.uniforms.iDate, 2026, 5, 20, time);
  gl.uniform1f(pass.uniforms.iSampleRate, 44100);
  const loc = pass.uniforms["iChannelResolution[0]"];
  if (loc) gl.uniform3fv(loc, channelRes.flat());
  for (let i = 0; i < 4; i++) {
    const u = pass.uniforms["iChannel" + i];
    if (u) gl.uniform1i(u, i);
  }
}

function renderPass(gl, pass, target, channels, frame, time, dt) {
  gl.useProgram(pass.program);
  gl.bindFramebuffer(gl.FRAMEBUFFER, target ? target.fb : null);
  gl.viewport(0, 0, target ? target.w : canvas.width, target ? target.h : canvas.height);

  const res = [];
  for (let i = 0; i < 4; i++) {
    const ch = channels[i];
    if (ch) {
      bindTexture(gl, i, ch.tex || ch);
      res.push([ch.w || canvas.width, ch.h || canvas.height, 1]);
    } else {
      bindTexture(gl, i, null);
      res.push([0, 0, 0]);
    }
  }

  setCommonUniforms(gl, pass, frame, time, dt, res);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  const err = gl.getError();
  if (err !== gl.NO_ERROR) {
    throw new Error(pass.name + " draw failed: 0x" + err.toString(16));
  }
}

function statsForTarget(gl, target) {
  gl.bindFramebuffer(gl.FRAMEBUFFER, target ? target.fb : null);
  const w = target ? target.w : canvas.width;
  const h = target ? target.h : canvas.height;
  const sampleW = Math.min(w, 64);
  const sampleH = Math.min(h, 64);
  if (target) {
    const data = new Float32Array(sampleW * sampleH * 4);
    gl.readPixels(0, 0, sampleW, sampleH, gl.RGBA, gl.FLOAT, data);
    let minV = 1e9, maxV = -1e9, sum = 0;
    for (let i = 0; i < data.length; i += 4) {
      const y = 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
      minV = Math.min(minV, y);
      maxV = Math.max(maxV, y);
      sum += y;
    }
    return { mean: sum / (sampleW * sampleH), min: minV, max: maxV };
  }
  const data = new Uint8Array(sampleW * sampleH * 4);
  gl.readPixels(0, 0, sampleW, sampleH, gl.RGBA, gl.UNSIGNED_BYTE, data);
  let minV = 255, maxV = 0, sum = 0;
  for (let i = 0; i < data.length; i += 4) {
    const y = 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
    minV = Math.min(minV, y);
    maxV = Math.max(maxV, y);
    sum += y;
  }
  return { mean: sum / (sampleW * sampleH), min: minV, max: maxV };
}

window.runRender = async function runRender(opts) {
  canvas.width = opts.width;
  canvas.height = opts.height;

  const gl = canvas.getContext("webgl2", {
    alpha: false,
    depth: false,
    stencil: false,
    antialias: false,
    preserveDrawingBuffer: true,
    premultipliedAlpha: false,
  });
  if (!gl) throw new Error("WebGL2 unavailable");
  if (!gl.getExtension("EXT_color_buffer_float")) {
    throw new Error("EXT_color_buffer_float unavailable");
  }
  dummyTex = createTex(gl, 1, 1, false, new Float32Array([0, 0, 0, 1]));

  gl.disable(gl.DEPTH_TEST);
  gl.disable(gl.CULL_FACE);
  gl.clearColor(0, 0, 0, 1);

  log("Compiling passes...");
  const passes = {
    A: makeProgram(gl, opts.shaders.A, "Buffer A"),
    Image: makeProgram(gl, opts.shaders.Image, "Image"),
  };

  const A = [makeTarget(gl, canvas.width, canvas.height, "A0"), makeTarget(gl, canvas.width, canvas.height, "A1")];
  const keyboard = { tex: createKeyboardTex(gl), w: 256, h: 3 };

  let track = null;
  let rec = null;
  const chunks = [];
  if (opts.mode !== "frames") {
    const stream = canvas.captureStream(0);
    track = stream.getVideoTracks()[0];
    let mimeType = "video/webm;codecs=vp9";
    if (!MediaRecorder.isTypeSupported(mimeType)) mimeType = "video/webm;codecs=vp8";
    if (!MediaRecorder.isTypeSupported(mimeType)) mimeType = "video/webm";
    rec = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: opts.bitrate });
    log("MediaRecorder mime: " + rec.mimeType);
    rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
  }

  const dt = opts.durationSeconds / opts.frames;
  if (rec) rec.start(1000);

  log("Rendering " + opts.frames + " frames at " + canvas.width + "x" + canvas.height + "...");
  const renderStartMs = performance.now();
  let ai = 0;
  for (let frame = 0; frame < opts.frames; frame++) {
    const time = frame * dt;
    const ap = A[ai], an = A[1 - ai];

    renderPass(gl, passes.A, an, [ap, keyboard, null, null], frame, time, dt);
    if (opts.debugStats && frame === 0) log("A stats " + JSON.stringify(statsForTarget(gl, an)));
    renderPass(gl, passes.Image, null, [an, null, null, null], frame, time, dt);
    if (opts.debugStats && frame === 0) log("Image stats " + JSON.stringify(statsForTarget(gl, null)));
    gl.finish();

    if (opts.mode === "frames") {
      const dataUrl = canvas.toDataURL("image/png");
      await window.saveFrame(frame, dataUrl);
    } else if (track.requestFrame) {
      track.requestFrame();
    }

    ai = 1 - ai;

    if (frame % 10 === 0 || frame === opts.frames - 1) log("frame " + (frame + 1) + "/" + opts.frames);
    if (opts.mode !== "frames") {
      await new Promise((r) => setTimeout(r, 1000 / opts.captureFps));
    }
  }

  const renderElapsedMs = performance.now() - renderStartMs;
  log(
    "Render time: " +
    renderElapsedMs.toFixed(1) +
    " ms total, " +
    (renderElapsedMs / Math.max(opts.frames, 1)).toFixed(1) +
    " ms/frame"
  );

  if (opts.mode === "frames") return [];

  await new Promise((resolve) => { rec.onstop = resolve; rec.stop(); });
  const blob = new Blob(chunks, { type: rec.mimeType });
  const buf = await blob.arrayBuffer();
  return Array.from(new Uint8Array(buf));
};
</script>
</body>
</html>`;

async function main() {
  const shaders = readShaderFiles();
  const root = path.resolve("wXdfzj_renderer.html");
  fs.writeFileSync(root, HTML, "utf8");

  const browser = await chromium.launch({
    headless: HEADLESS,
    executablePath: CHROME_EXE,
    args: [
      "--ignore-gpu-blocklist",
      "--enable-webgl",
      "--autoplay-policy=no-user-gesture-required",
      `--use-angle=${ANGLE_BACKEND}`,
    ],
  });
  const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: 1 });
  page.on("console", (msg) => console.log(`[browser:${msg.type()}] ${msg.text()}`));
  page.on("pageerror", (err) => console.error("[browser pageerror]", err.message));

  if (MODE === "frames") {
    fs.rmSync(FRAMES_DIR, { recursive: true, force: true });
    fs.mkdirSync(FRAMES_DIR, { recursive: true });
    await page.exposeFunction("saveFrame", (frame, dataUrl) => {
      const comma = dataUrl.indexOf(",");
      const b64 = dataUrl.slice(comma + 1);
      const file = path.join(FRAMES_DIR, `frame_${String(frame).padStart(4, "0")}.png`);
      fs.writeFileSync(file, Buffer.from(b64, "base64"));
    });
  }

  await page.goto("file:///" + root.replace(/\\/g, "/"), { waitUntil: "load" });
  const bytes = await page.evaluate(
    async (opts) => window.runRender(opts),
    {
      width: WIDTH,
      height: HEIGHT,
      frames: FRAMES,
      durationSeconds: DURATION_SECONDS,
      captureFps: CAPTURE_FPS,
      bitrate: 16_000_000,
      mode: MODE,
      debugStats: process.env.DEBUG_STATS === "1",
      shaders,
    }
  );

  if (MODE === "frames") {
    console.log(`Saved frames to ${FRAMES_DIR}`);
  } else {
    fs.writeFileSync(OUTPUT, Buffer.from(bytes));
    console.log(`Saved ${OUTPUT}`);
  }
  await browser.close();
}

main().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
