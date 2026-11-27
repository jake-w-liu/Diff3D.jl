# API Reference

These pages are generated from Julia docstrings. Every exported public name is
documented and checked by Documenter.

## Subsystem Map

- Math: vectors, matrices, quaternions, Euler rotations, rays, planes,
  triangles, bounds, and frustums.
- Scene graph: objects, groups, meshes, lines, points, sprites, LODs, layers,
  skeletons, and instancing.
- Cameras: perspective, orthographic, stereo, cube, and array cameras.
- Geometry: buffer attributes, primitive generators, polyhedra, lathe/tube,
  shape/extrude, capsule, wireframe, edge, draw group, and morph helpers;
  curves, paths and shapes; in-place transforms.
- Materials and lights: unlit, Lambert, Phong, PBR-style, physical, toon,
  matcap, normal, depth, sprite, line, point, shader materials, common light
  types, IES profiles, and shadows.
- Rendering: render targets, CPU rasterization, tiled/pooled/MSAA rendering,
  post-processing, tone mapping, color-space conversion, and WebGL export.
- Differentiable rendering: soft rasterization, losses, finite-difference
  checks, reverse-mode scalar AD helpers, and inverse rendering optimizers.
- I/O and loaders: image export; PNG, JPEG, HDR, EXR and KTX2 decoding;
  OBJ/MTL/STL/PLY/XYZ, glTF/GLB, SVG and typeface loading; STL, OBJ, PLY and
  glTF writing; and compression helpers.

## Reference Pages

- [Math, Scene Graph and Cameras](api_math.md)
- [Geometry](api_geometry.md)
- [Materials, Textures and Lights](api_materials.md)
- [Rendering, Objects and Raycasting](api_rendering.md)
- [Controls, Animation and Helpers](api_animation.md)
- [Differentiable Rendering](api_differentiable.md)
- [Image I/O, Loaders and WebGL Export](api_io.md)

## Module and Shared Names

```@autodocs
Modules = [Diff3D]
Private = false
Pages = ["src/Diff3D.jl", "src/docs.jl"]
```
