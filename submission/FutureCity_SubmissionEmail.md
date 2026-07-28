Subject: HPG 2026 Student Competition Submission - SHADERTTOY-程序化城市-全局GI

To: studentcompetition@highperformancegraphics.org

Dear HPG 2026 Student Competition Committee,

I would like to submit my entry to the HPG 2026 Student Competition.

Title: SHADERTTOY-程序化城市-全局GI

ShaderToy link: https://www.shadertoy.com/view/sXBGRw

Author: Haowen Guo

Affiliation: Huazhong University of Science and Technology

Student status: Master's student

Eligibility statement: I was a student at the time this work was completed.

Short description:

SHADERTTOY-程序化城市-全局GI is a ShaderToy-based procedural global
illumination shader showing a large hash-generated cyberpunk city. The scene is
generated entirely at runtime from procedural cells, including roads, plazas,
towers, podiums, glass needle towers, metal slabs, brick/composite facades,
neon signs, and warm/cool window patterns. A central spine mask and landmark
masks organize the city into a readable street canyon and high-rise skyline
instead of a uniform random grid.

Procedural approach:

The city is generated from deterministic cell hashes and analytic geometry.
Each cell chooses its role and architectural archetype procedurally: road,
plaza, podium tower, dark metal slab, glass needle, stepped mid-rise, or
brick/composite block. A bounded 2D DDA traversal over city cells is used for
primary visibility and shadow/proxy queries, allowing the shader to present a
large procedural city while keeping the traversal finite and stable inside
ShaderToy.

Global illumination technique:

The shader uses a hybrid GI approach. Primary visibility, GGX materials,
thin-glass reflection, direct sun lighting, and hard sun shadow rays are traced
explicitly. While the camera is static, temporal checkerboard samples trace up
to three stochastic path-traced surface hits, while regular samples trace two
surface hits. Secondary path hits can receive shadowed sun lighting, and paths
that hit emissive windows or neon signs contribute indirect emission.

To make indirect lighting visible at low sample counts, the stochastic path
tracing is reinforced by a deterministic procedural city irradiance field
derived from the same hash cells that generate the city. This field estimates
sky visibility, nearby building occlusion, warm road bounce, facade-to-facade
bounce, neon/window color bleeding, and street-canyon multi-bounce
amplification. Metallic and glass surfaces also sample a deterministic city
reflection field so nearby windows, neon, road glow, and far-city horizon colors
remain visible without requiring many random emissive hits.

Performance notes:

- ShaderToy implementation: Buffer A plus Image pass.
- Samples per frame: 2.
- Maximum path depth: 1 bounce while moving; while static, temporal checkerboard
  samples trace up to 3 surface hits and regular samples trace up to 2.
- Direct lighting: one shadowed directional sun ray, evaluated on primary hits
  and selected secondary path hits.
- Accumulation: Buffer A temporal accumulation while the camera is still.
- Geometry traversal: bounded 2D DDA over procedural city cells.
- Local test setup: Chrome/WebGL2 through ANGLE D3D11.
- Local test resolution: 640 x 360, 4 frames.
- Measured performance on my test setup: approximately 84.6 ms/frame after
  shader compilation with temporal checkerboard 3-bounce samples enabled.

Creative features:

- Vast procedural city generated entirely at runtime.
- Deterministic city layout rules with a central canyon and landmark skyline.
- Procedural architectural archetypes and mixed facade materials.
- Stable visible GI and color bleeding from windows, neon, roads, and nearby
  facades.
- Direct sun shadows combined with controllable low-frequency city irradiance
  and true stochastic multi-bounce path samples.

Thank you for considering my submission.

Sincerely,

Haowen Guo
Master's Student
Huazhong University of Science and Technology
Email: 1910481404@qq.com
