# GitHub Publishing Checklist

Use `FutureCity_GitHub_Submission` as the repository root. The public GitHub repository slug is `SHADERTTOY-Procedural-City-Global-GI`; the display title used in the README is `SHADERTTOY-程序化城市-全局GI`. Do not publish the older benchmark folders from the parent workspace unless you want to archive experiments separately.

## Recommended Commit Contents

Include:

- `README.md`
- `README.zh-CN.md`
- `README.ja.md`
- `docs/TECHNICAL_OVERVIEW.md`
- `docs/TECHNICAL_OVERVIEW.zh-CN.md`
- `docs/TECHNICAL_OVERVIEW.ja.md`
- `docs/GITHUB_PUBLISHING.md`
- `FutureCity_BufferA.glsl`
- `FutureCity_Image.glsl`
- `assets/preview.png`
- `render_future_city_offline.js`
- `package.json`
- `submission/FutureCity_SubmissionNotes.md`
- `submission/FutureCity_SubmissionEmail.md`
- `submission/FutureCity_SubmissionEmail.eml`
- `.gitignore`

Do not include:

- `node_modules/`
- generated frame folders
- generated `.webm` files
- temporary renderer HTML files
- old benchmark or experiment folders from the parent workspace

## Suggested Git Commands

```powershell
cd F:\RandomLightServerLibrary\SHADERTOY\FutureCity_GitHub_Submission
git init
git add .
git commit -m "Add procedural neon metropolis GI shader"
```

Then create an empty GitHub repository and push this folder to it.

## Optional Local Renderer

The renderer is only for local verification. ShaderToy does not need it.

```powershell
cd F:\RandomLightServerLibrary\SHADERTOY\FutureCity_GitHub_Submission
npm install
$env:WIDTH="640"
$env:HEIGHT="360"
$env:FRAMES="4"
$env:DURATION_SECONDS="1"
$env:MODE="frames"
$env:FRAMES_DIR="FutureCity_frames"
node .\render_future_city_offline.js
```

Generated files are ignored by `.gitignore`.
