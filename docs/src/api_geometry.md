# Geometry

Buffer geometry, primitive generators, curves, paths and shapes, extrusion, polyhedra, CSG, and geometry utilities.

```@autodocs
Modules = [Diff3D]
Private = false
Pages = ["src/geometries.jl", "src/geometries_extra.jl", "src/teapot_geometry.jl", "src/csg.jl"]
```

## Parametric Surface Functions

`ParametricFunctions` is a submodule, so its surfaces are listed separately.

```@docs
Diff3D.ParametricFunctions
Diff3D.ParametricFunctions.klein
Diff3D.ParametricFunctions.plane
Diff3D.ParametricFunctions.mobius
Diff3D.ParametricFunctions.mobius3d
```
