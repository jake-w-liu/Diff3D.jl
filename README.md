# Three.jl

Three.jl is a Julia-native 3D graphics and differentiable rendering package with
an API shaped after three.js. It includes a CPU rasterizer, soft differentiable
rasterization, scene graph primitives, geometry generators, materials, lights,
animation controls, loaders, and self-contained WebGL HTML export.

## Status

This repository is pre-1.0. The public API is broad and covered by an extensive
test suite, but releases should still follow semantic-versioning caution until
the package is registered and downstream users have validated their workflows.

Current verification performed during the publication audit:

- `Pkg.test()` passes with 2,975 tests.
- Exported API doc coverage is complete: `Docs.hasdoc(Three, name)` is true for
  all exported names.
- `examples/output/live_webgl_showcase.html` passes the headless browser WebGL
  smoke test with Chromium/SwiftShader.

## Installation

From a local checkout:

```julia
using Pkg
Pkg.activate("path/to/Three.jl")
Pkg.instantiate()
using Three
```

For development in another Julia environment:

```julia
using Pkg
Pkg.develop(path = "path/to/Three.jl")
using Three
```

## Quick Start

```julia
using Three

scene = Scene(background = Color3(0.03, 0.04, 0.05))
camera = PerspectiveCamera(fov = pi / 3, aspect = 1.0, near = 0.1, far = 100.0)
camera.position = Vec3(3.0, 2.0, 4.0)

mesh = Mesh(
    BoxGeometry(width = 1.2, height = 1.2, depth = 1.2),
    MeshPhongMaterial(color = Color3(0.2, 0.55, 0.95), shininess = 40.0),
)
add!(scene, mesh)
add!(scene, AmbientLight(color = Color3(0.25, 0.25, 0.25)))
add!(scene, DirectionalLight(color = Color3(1.0, 1.0, 1.0), intensity = 1.5))

target = RenderTarget(512, 512)
render!(target, scene, camera)
save_png("cube.png", target.color)
```

## Core Features

- Scene graph: `Object3D`, `Scene`, `Group`, `Mesh`, `LineObject`,
  `PointsObject`, `Sprite`, `LOD`, layers, skeletons, and instancing.
- Math: `Vec2`, `Vec3`, `Vec4`, `Mat3`, `Mat4`, `Quaternion`, `Euler`,
  bounding volumes, rays, planes, frustums, and interpolation helpers.
- Geometry: boxes, spheres, planes, cylinders, cones, torus variants,
  polyhedra, lathe/tube/extrude/shape/capsule geometries, wireframes, and
  edges.
- Materials and lighting: basic, Lambert, Phong, standard/PBR, physical, toon,
  matcap, normal, depth, line, point, sprite, shader materials, common light
  types, IES profiles, and shadow maps.
- Rendering: CPU rasterization, smooth/flat shading, texture maps, clipping,
  scissor, logarithmic depth, MSAA, tiled rendering, post-processing passes, and
  self-contained WebGL HTML export.
- Differentiable workflows: ForwardDiff-compatible soft rendering, image loss
  functions, numerical/reverse gradients, and inverse-rendering optimizers.
- I/O and loaders: PPM/PNG/PDF output, OBJ/MTL/STL/PLY loading, PNG decoding,
  glTF/GLB loading, and base64/DEFLATE helpers.

## Documentation

Julia help mode is available for every exported public name:

```julia
?RenderTarget
?render!
?save_webgl_html
```

Julia documentation on GitHub Pages:

```text
https://jake-w-liu.github.io/Three.jl/stable/
```

The GitHub Pages documentation is built by
`.github/workflows/documentation.yml` using Documenter.jl. The URL will return
404 until that workflow has run on GitHub and GitHub Pages is enabled for the
repository's `gh-pages` deployment branch.

The example gallery is published inside the docs at:

```text
https://jake-w-liu.github.io/Three.jl/stable/gallery/
```

A Documenter.jl scaffold is provided in `docs/`. To build it locally:

```julia
using Pkg
Pkg.activate("docs")
Pkg.develop(path = "..")
Pkg.instantiate()
include("docs/make.jl")
```

After a successful build, open the local documentation at:

```text
docs/build/index.html
```

## Examples

Generate an interactive WebGL showcase:

```powershell
julia --project=. examples/live_webgl_showcase.jl
python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
```

Generate the example gallery with the animated robot and playback speed control:

```powershell
julia --project=. examples/example_gallery.jl
python examples/browser_webgl_smoke.py examples/output/example_gallery.html
```

The example parity registry is maintained in
`examples/examples_registry.toml`. Generated HTML outputs live under
`examples/output/` and are ignored by git.

## Verification

Run the Julia test suite:

```powershell
julia --project=. -e 'using Pkg; Pkg.test()'
```

Run API documentation coverage:

```powershell
julia --project=. -e 'using Three; missing = [n for n in names(Three) if isdefined(Three, n) && !Docs.hasdoc(Three, n)]; @show missing'
```

Run the browser smoke test for a generated HTML export:

```powershell
python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
```

## Publication Checklist

Before public release or registry submission:

- Choose and commit a license approved by the repository owner.
- Decide whether `Manifest.toml` should remain committed. Julia packages often
  omit it, while applications/reproducible research artifacts often keep it.
- Add CI for `Pkg.test()`, documentation build, and at least one WebGL smoke
  artifact if browser dependencies are available.
- Tag releases only after `Pkg.test()` and the docs build pass from a clean
  checkout.
