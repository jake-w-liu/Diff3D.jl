# Diff3D.jl

Diff3D.jl is a Julia-native 3D graphics and differentiable rendering package.
It combines a three.js-inspired scene API with CPU rendering, differentiable
soft rasterization, asset loaders, animation/control helpers, and standalone
WebGL HTML export.

## Minimal Render

```julia
using Diff3D

scene = Scene(background = Color3(0.03, 0.04, 0.05))
camera = PerspectiveCamera(fov = pi / 3, aspect = 1.0, near = 0.1, far = 100.0)
camera.position = Vec3(3.0, 2.0, 4.0)

mesh = Mesh(
    BoxGeometry(),
    MeshPhongMaterial(color = Color3(0.2, 0.55, 0.95)),
)
add!(scene, mesh)
add!(scene, AmbientLight(intensity = 0.35))
add!(scene, DirectionalLight(intensity = 1.2))

target = RenderTarget(512, 512)
render!(target, scene, camera)
save_png("cube.png", target.color)
```

## Subsystems

- Math and transforms: vectors, matrices, quaternions, Euler rotations, rays,
  planes, bounding volumes, and frustums.
- Scene graph: objects, groups, meshes, lines, points, sprites, LODs, layers,
  skeletons, and instanced meshes.
- Geometry: primitive, parametric, polyhedral, swept, extruded, wireframe, and
  edge geometries.
- Materials and lights: unlit, Lambert, Phong, PBR-style, physical, toon,
  matcap, normal, depth, sprite, line, point, shader materials, common lights,
  IES profiles, and shadows.
- Rendering: CPU rasterization, tiled rendering, MSAA, post-processing, texture
  maps, clipping/scissor/logarithmic depth, and browser WebGL export.
- Differentiable workflows: soft rasterization, image losses, finite-difference
  checks, ForwardDiff gradients, reverse-mode scalar AD helpers, and inverse
  rendering optimizers.
- I/O: PNG/PPM/PDF output, PNG decoding, OBJ/MTL/STL/PLY loading, and glTF/GLB
  loading.

## Verification

```julia
using Pkg
Pkg.test("Diff3D")
```

The repository also includes a browser smoke test for generated WebGL output:

```powershell
python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
```

To verify every non-planned entry in `examples/examples_registry.toml`, run:

```powershell
python examples/verify_examples_registry.py
```

The gallery-style example includes an animated robot, material turntable,
instancing scene, particle scene, and runtime playback controls:

```powershell
julia --project=. examples/example_gallery.jl
python examples/browser_webgl_smoke.py examples/output/example_gallery.html
```

The published documentation includes the generated gallery on the
[Example Gallery](@ref) page.
