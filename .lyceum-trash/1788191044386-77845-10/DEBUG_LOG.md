# Debug Log

## 2026-06-08: Production Aircraft Mesh Rendering

Symptom: A Diff3D-rendered aircraft mesh for a paper figure looked low quality:
thin incidence/mesh lines ignored requested widths, and vertex-colored
scientific surfaces looked flat because specular/fill lighting was suppressed.

Root causes:

- `LineBasicMaterial.linewidth` was stored by the API but ignored by the CPU line
  rasterizer. Lines were always one pixel wide.
- `vertex_colors=true` multiplied the final lit color instead of modulating the
  material albedo before lighting. Dark vertex colors therefore crushed specular
  highlights and reduced perceived 3D depth.

Fix:

- `src/renderer_extra.jl` now applies material linewidth by stamping a
  depth-tested disk around each DDA line sample.
- `src/shading.jl` now creates vertex-color-modulated material copies for
  `MeshBasicMaterial`, `MeshLambertMaterial`, and `MeshStandardMaterial`.
- `src/rasterizer.jl` now passes the modulated material to smooth shading instead
  of multiplying the final lit color.

Regression checks:

- `test/runtests.jl` verifies a wide line renders more than three times as many
  red pixels as a one-pixel line.
- `test/runtests.jl` verifies a black vertex-colored `MeshStandardMaterial`
  still preserves a specular highlight under aligned camera/light geometry.

Manual checks:

- Minimal line smoke test after the fix: linewidth 1 rendered 53 red pixels,
  linewidth 7 rendered 401 red pixels.
- Minimal Standard-material smoke test after the fix preserved a nonzero
  specular response for a black vertex-colored plane.
