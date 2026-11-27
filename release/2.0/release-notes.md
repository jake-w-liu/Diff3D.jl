# Diff3D.jl 2.0.0

Diff3D 2.0 is the result of a full audit of every subsystem against three.js
r186. Each finding was reproduced against the three.js source run under Node
(or, for the exported viewer, in headless Chromium) before it was changed, and
every fix carries a regression test.

## Breaking changes

Exported 1.x names and documented signatures still work. What changes is
behavior that 1.x got wrong against three.js without documenting it:

- Defaults now follow three.js: `MeshPhongMaterial` specular (linear `0x111111`),
  `SpriteMaterial` `transparent=true`, `MeshPhysicalMaterial` black sheen color,
  nearest filtering for `DataTexture`/`DepthTexture`, a white `HemisphereLight`
  ground color, a 10x10 `RectAreaLight`, a 1° `edges_geometry` threshold, 8x8
  `ParametricGeometry`, and the light, grid and skeleton helpers' sizes and
  colors.
- `BoxGeometry`, the polyhedra, `LatheGeometry` and `ParametricGeometry` emit
  three.js vertex, index and UV order; plane, ring and cylinder quads use
  three.js diagonals; `wireframe_geometry` and `edges_geometry` weld and order
  edges like three.js. Code that addresses vertices or faces by number changes.
- Standard and Physical direct lighting is the three.js r186 BRDF. The exported
  browser viewer uses the same BRDFs with Lambert `albedo/π`, so diffuse-lit
  exports are about π times darker and now match three.js and the CPU renderer.
- Mirrored (negative-determinant) meshes keep three.js front faces; the depth
  test is less-or-equal; transparent objects sort like three.js; nearest
  texture sampling, sRGB decoding and cube-map edges follow the GL rules.
- PLY vertex colors, MTL `Kd`/`Ks`/`Ke` and SVG paint colors are converted from
  sRGB to linear. glTF primitives without normals load flat-shaded.
- `AnimationMixer` steps like a three.js `AnimationAction`: an unclamped finish
  restores the original values, and smooth tracks use `CubicInterpolant`.
  `OrbitControls` orbit about `camera.up`.
- Mesh raycasts use three.js's watertight object-space test; orthographic rays
  start in the camera plane; `Intersection` reports face, normal, UV and
  barycentric data.
- Structs gained fields (cameras, lights, `Intersection`, `AnimationMixer`,
  `Clock`); keyword constructors are unchanged.

`release/2.0/migration.md` lists every change with the way to keep a 1.x
result. `docs/src/compatibility.md` lists the differences from three.js that
remain on purpose and the features not yet implemented.

## Added

222 exported names: the three.js `Curve`/`Path`/`Shape` hierarchy; `Object3D`
operations (`look_at!`, `attach!`, rotate/translate on axis, world-space
getters, traversal and lookup); camera view offsets, film gauge and focal
length; vector, matrix, quaternion, Euler, box, sphere, plane, ray and triangle
operations; in-place geometry transforms and BufferGeometryUtils-style helpers;
`RoundedBoxGeometry`, `BoxLineGeometry`, `DecalGeometry`, `ParametricFunctions`;
keyframe and clip utilities, `FrameTimer`; `tone_map` and `output_pass` with the
three.js operators; shadow intensity and normal bias; second-order light
probes; `save_stl_ascii`, `save_obj`, `save_ply`, `save_gltf`, `load_obj_scene`.

## Fixed and faster

About 150 defects are fixed across math, geometry, shading, rasterization,
shadows, textures, raycasting, controls, animation, the loaders (JPEG, PNG,
DEFLATE, EXR, HDR, KTX2, STL, OBJ, MTL, PLY, glTF, SVG, fonts), the WebGL export
and reverse-mode differentiation; `CHANGELOG.md` lists them. Reverse-mode image
gradients are 30-90x faster with 100-400x less memory, raycasts on dense meshes
up to 14x faster, PNG, DEFLATE, STL, OBJ, PLY and glTF buffer decoding 2-25x
faster, and `Mat4` products 1.5-2x faster, with identical results.
ForwardDiff 1.5 is supported.
