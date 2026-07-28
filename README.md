# SHADERTTOY-程序化城市-全局GI

ShaderToy entry for the HPG 2026 Student Competition theme: **Vast Proceduralism and Global Illumination**.

ShaderToy link: https://www.shadertoy.com/view/sXBGRw

Languages: [English](README.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md)

![Preview](assets/preview.png)

## Overview

SHADERTTOY-程序化城市-全局GI is a two-pass ShaderToy shader that renders a large hash-generated cyberpunk city with hybrid global illumination. The scene is built entirely at runtime from deterministic procedural cells: roads, plazas, rail infrastructure, podiums, towers, glass needles, dark metal slabs, brick/composite facades, neon signs, warm/cool windows, metal panels, glass curtain walls, and wood-like accents.

The renderer combines a small stochastic path tracer with a deterministic city irradiance field. Primary hits, direct sun, hard sun shadows, GGX materials, thin-glass reflections, selected secondary bounces, and emissive path hits are traced explicitly. Diffuse and glossy indirect lighting are reinforced by stable procedural fields derived from the same cell hashes that generate the visible city.

## Repository Layout

- `FutureCity_BufferA.glsl`  
  Main ShaderToy Buffer A pass. It contains the procedural city, path tracer, GI field, camera state, and temporal accumulation.
- `FutureCity_Image.glsl`  
  Display pass. It hides the first four Buffer A state pixels and presents the accumulated image.
- `render_future_city_offline.js`  
  Optional local WebGL2 renderer for preview frames or video capture.
- `assets/preview.png`  
  Local verification preview at `640 x 360`.
- `docs/TECHNICAL_OVERVIEW.md`  
  Detailed code and rendering analysis.
- `docs/TECHNICAL_OVERVIEW.zh-CN.md`  
  Chinese technical overview.
- `docs/TECHNICAL_OVERVIEW.ja.md`  
  Japanese technical overview.
- `docs/BLOG_CHAMPION_TECHNICAL_RETROSPECTIVE.zh-CN.md`  
  Detailed Chinese champion-project technical retrospective and publishable blog article.
- `submission/`  
  Competition notes and email draft.

## ShaderToy Setup

Use two ShaderToy passes:

- `Buffer A`: paste `FutureCity_BufferA.glsl`
- `Image`: paste `FutureCity_Image.glsl`

Channel setup:

- Buffer A `iChannel0`: Buffer A itself
- Buffer A `iChannel1`: Keyboard
- Image `iChannel0`: Buffer A

Buffer A uses its first four pixels as persistent state:

- `(0,0)`: camera position
- `(1,0)`: yaw, pitch, camera moved flag
- `(2,0)`: mouse position and mouse down flag
- `(3,0)`: accumulated sample count

The Image pass shifts those state pixels out of the visible output region.

## Controls

- `W/S`: forward/back
- `A/D`: left/right
- `E/Q`: up/down
- Mouse drag: look around
- `Shift`: faster movement
- `R`: reset camera

## Current Render Settings

- Samples per frame: `c_spp = 2`
- Moving camera: 1 surface hit
- Static camera: regular samples use 2 surface hits
- Static camera deep samples: temporal checkerboard subset uses 3 surface hits
- Direct lighting: one shadowed directional sun ray
- Direct lighting on path continuation: selected secondary hits
- Main traversal: bounded 2D DDA through procedural city cells
- Shadow traversal: shorter bounded DDA with simplified proxy bounds
- Temporal accumulation: Buffer A accumulates while the camera is still

## Global Illumination Summary

The GI is intentionally hybrid:

1. **Explicit traced transport**  
   Primary visibility, direct sun shadows, GGX reflection, thin glass, and selected secondary stochastic bounces are traced.

2. **Procedural diffuse irradiance field**  
   Nearby cells estimate sky visibility, road/plaza bounce, facade-to-facade bounce, window/neon color bleeding, local canyon occlusion, and cheap second-bounce energy.

3. **Procedural specular/reflection field**  
   Metal and glass sample a deterministic city reflection field so nearby neon, lit windows, roads, plazas, and far skyline colors appear even at low sample counts.

This makes the indirect lighting readable without relying on rare random paths hitting tiny emissive windows or neon strips.

## Local Verification

The optional renderer uses local Chrome/WebGL2 through Playwright.

Example PowerShell run:

```powershell
cd FutureCity_GitHub_Submission
npm install
$env:WIDTH="640"
$env:HEIGHT="360"
$env:FRAMES="4"
$env:DURATION_SECONDS="1"
$env:MODE="frames"
$env:FRAMES_DIR="FutureCity_frames"
node .\render_future_city_offline.js
```

Measured local verification for the submitted shader:

- Resolution: `640 x 360`
- Test run: 4 frames
- Browser path: Chrome/WebGL2 through ANGLE D3D11
- Render time after shader compilation: about `84.6 ms/frame`

Shader compilation can still take noticeably longer than steady-state rendering because the shader is large and branch-heavy.

## Competition Submission Files

The `submission/` folder contains:

- `FutureCity_SubmissionNotes.md`: setup, GI summary, performance notes, and checklist
- `FutureCity_SubmissionEmail.md`: email body draft
- `FutureCity_SubmissionEmail.eml`: email-style draft

The official submission target in the call for entries is:

`studentcompetition@highperformancegraphics.org`
