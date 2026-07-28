# SHADERTTOY-程序化城市-全局GI

## ShaderToy tabs

Separate tab files:

- `Buffer A`: paste `FutureCity_BufferA.glsl`
- `Image`: paste `FutureCity_Image.glsl`

Channel setup:

- Buffer A `iChannel0`: Buffer A itself, for camera state and temporal accumulation
- Buffer A `iChannel1`: Keyboard
- Image `iChannel0`: Buffer A

The first four pixels of Buffer A store camera position, rotation, mouse state,
and accumulated sample count. The Image pass shifts these state pixels out of
the visible image region before display.

## Short submission description

SHADERTTOY-程序化城市-全局GI is a ShaderToy-based real-time procedural global
illumination experiment. The scene is a large hash-driven cyberpunk city built
from an infinite grid of procedural cells. Each cell deterministically chooses
road, plaza, podium, tower, glass needle, dark metal slab, stepped mid-rise, or
brick/composite building archetypes. A spine mask and landmark mask organize the
city into a strong central street canyon, distant high-rise clusters, and more
readable skyline hierarchy, avoiding a purely uniform random city layout.

The geometry is generated at runtime from cell hashes and analytic boxes/spheres:
roads, elevated rail infrastructure, plazas, podiums, towers, roof equipment,
spires, neon signs, glass curtain walls, metal panels, warm brick, and wood-like
facade accents. A 2D DDA traversal over city cells keeps primary intersections
bounded while still presenting a large procedural scene.

## Global illumination technique

The shader uses a hybrid physically-based and deterministic GI approach designed
for ShaderToy constraints. Primary visibility, direct sun lighting, hard sun
shadow rays, GGX materials, thin-glass reflections, glossy continuation, and up
to three true stochastic path-traced surface hits are evaluated explicitly while
the camera is still. Secondary path hits also receive shadowed sun lighting, and
stochastic paths that hit emissive windows or neon signs contribute indirect
emission. Diffuse GI is reinforced by a deterministic procedural city irradiance
field generated from the same hash cells that create the city geometry.

The city irradiance field includes:

- Sky visibility estimated from height, surface normal, road openness, and nearby
  building occlusion.
- Warm sun-to-ground bounce from lit road/plaza surfaces onto nearby walls.
- Local neon and window color bleeding from nearby procedural cells.
- Facade-to-facade low-frequency diffuse bounce in street canyons.
- Cheap multi-bounce amplification in occluded canyon areas.
- Deterministic city specular/reflection field for metal and glass, so reflective
  materials show nearby windows, neon, roads, and far-city horizon color instead
  of relying on rare stochastic bounces.

This is intentionally a controllable GI approximation rather than a fully random
multi-bounce path tracer. With only a few samples per frame, stochastic paths
rarely hit small emissive windows or signs. The procedural city therefore
contributes stable low-frequency radiance directly to diffuse and glossy
surfaces, making indirect lighting and color bleeding visible at ShaderToy
rendering speeds.

## Performance notes

Current quality/performance settings:

- Samples per frame: `c_spp = 2`
- Maximum bounces: moving camera `1`; static camera uses temporal checkerboard
  deep samples with `3` bounces and regular samples with `2` bounces
- Direct lighting: one shadowed directional sun sample
- Next-event direct sun bounces: moving camera `1`; checkerboard deep static
  samples `2`
- Temporal accumulation: Buffer A accumulates while the camera is still
- Main traversal: bounded 2D DDA through procedural city cells
- Shadow/GI proxies: simplified building proxy bounds for sun shadows, AO, GI,
  and specular field queries

Local verification:

- Renderer: `render_future_city_offline.js`
- Browser path: local Chrome/WebGL2 via ANGLE D3D11
- Test resolution: `640x360`
- Test run: 4 frames
- Measured render time after compile with temporal checkerboard 3-bounce
  samples: about `84.6 ms/frame`
- Preview output:
  `FutureCity_cleanup_640/frame_0003.png`

Shader compilation is heavier than the per-frame render cost because ANGLE has
to compile a large procedural shader with many material and lighting branches.
After compile, the shader remains stable in the local renderer. For slower GPUs
or stricter browser environments, reduce one or more of:

- `CITY_MAX_CELLS` from `56` to `40`
- `CITY_MAX_SHADOW_CELLS` from `28` to `20`
- `c_spp` from `2` to `1`
- Static checkerboard deep sample `maxBounces` from `3` to `2` or `1`

## Controls

- `W/S`: forward/back
- `A/D`: left/right
- `E/Q`: up/down
- Mouse drag: look around
- `Shift`: faster movement
- `R`: reset camera

## Creative features

- Vast procedural city generated entirely from hash cells.
- Central street-canyon composition instead of uniform random tiling.
- Multiple deterministic architectural archetypes: glass needles, dark slabs,
  brick/composite mid-rises, stepped podium towers.
- Procedural facade material mixture: brick, metal, glass, wood accents, neon,
  warm/cool windows.
- Hybrid GI: explicit sun shadows plus deterministic city irradiance and
  reflection fields.
- GI sources are tied to the same procedural rules that generate visible
  windows, neon, roads, and plazas.

## Submission checklist

- [ ] Upload/paste `FutureCity_BufferA.glsl` and `FutureCity_Image.glsl` into a
  ShaderToy project.
- [ ] Configure Buffer A channels: `iChannel0 = Buffer A`, `iChannel1 = Keyboard`.
- [ ] Configure Image channel: `iChannel0 = Buffer A`.
- [ ] Let the shader run for several seconds while static to accumulate samples.
- [ ] Confirm the default camera shows the central city canyon.
- [ ] Copy the final ShaderToy URL into `FutureCity_SubmissionEmail.md`.
- [ ] Confirm the author, affiliation, student status, and eligibility
  statement in the email.
- [ ] Send the email to `studentcompetition@highperformancegraphics.org`.
- [ ] If no confirmation arrives, retry the submission email; the official page
  notes prior email delivery issues.
