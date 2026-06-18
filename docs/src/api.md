# API Reference

This page is generated from Julia docstrings. Every exported public name is
documented and checked by Documenter.

## Subsystem Map

- Math: vectors, matrices, quaternions, Euler rotations, rays, planes,
  triangles, bounds, and frustums.
- Scene graph: objects, groups, meshes, lines, points, sprites, LODs, layers,
  skeletons, and instancing.
- Cameras: perspective, orthographic, stereo, cube, and array cameras.
- Geometry: buffer attributes, primitive generators, polyhedra, lathe/tube,
  shape/extrude, capsule, wireframe, edge, draw group, and morph helpers.
- Materials and lights: unlit, Lambert, Phong, PBR-style, physical, toon,
  matcap, normal, depth, sprite, line, point, shader materials, common light
  types, IES profiles, and shadows.
- Rendering: render targets, CPU rasterization, tiled/pooled/MSAA rendering,
  post-processing, tone mapping, color-space conversion, and WebGL export.
- Differentiable rendering: soft rasterization, losses, finite-difference
  checks, reverse-mode scalar AD helpers, and inverse rendering optimizers.
- I/O and loaders: image export, PNG decoding, OBJ/MTL/STL/PLY/XYZ loading,
  glTF/GLB loading, and compression helpers.

## Complete Exported API

```@autodocs
Modules = [Diff3D]
Private = false
```

