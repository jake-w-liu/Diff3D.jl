# Diff3D.jl

Diff3D.jl is a Julia-native 3D graphics and differentiable rendering package with
an API shaped after three.js. It includes a CPU rasterizer, soft differentiable
rasterization, scene graph primitives, geometry generators, materials, lights,
animation controls, loaders, and self-contained WebGL HTML export.

## Status

Diff3D.jl is pre-1.0. The public API is broad and tested, but may still change
as the package matures.

## Installation

After registration, install the package with:

```julia
using Pkg
Pkg.add("Diff3D")
using Diff3D
```

During registration, or when working from a checkout, use:

```julia
using Pkg
Pkg.develop(path = "path/to/Diff3D.jl")
using Diff3D
```

## Quick Start

```julia
using Diff3D

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
- I/O and loaders: PPM/PNG/PDF output, OBJ/MTL/STL/PLY/XYZ loading, PNG decoding,
  glTF/GLB loading, and base64/DEFLATE helpers.

## Documentation

Julia help mode is available for every exported public name:

```julia
?RenderTarget
?render!
?save_webgl_html
```

Full documentation is available on GitHub Pages:

```text
https://jake-w-liu.github.io/Diff3D.jl/stable/
```

The example gallery is published inside the docs at:

```text
https://jake-w-liu.github.io/Diff3D.jl/stable/gallery/
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

Run the full registered example generation and browser-smoke sweep:

```powershell
python examples/verify_examples_registry.py
```

## Verification

Run the Julia test suite:

```powershell
julia --project=. -e 'using Pkg; Pkg.test()'
```

Run API documentation coverage:

```powershell
julia --project=. -e 'using Diff3D; missing = [n for n in names(Diff3D) if isdefined(Diff3D, n) && !Docs.hasdoc(Diff3D, n)]; @show missing'
```

Run the browser smoke test for a generated HTML export:

```powershell
python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
```

Run browser verification for every non-planned parity registry entry:

```powershell
python examples/verify_examples_registry.py
```
