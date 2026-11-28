# Compatibility

This contract defines the supported surface for Diff3D 2.x. Consult the
documentation for the package version you use; development documentation can
include unreleased work.

## Public API and versioning

The public API comprises exported names, their documented constructors and
methods, keyword arguments and defaults, return values, and documented object
properties. Examples in the documentation use this surface. Julia indexing is
one-based, camera field of view and rotations use radians, and transform
matrices use column-major storage.

The 2.x series preserves that documented behavior. Compatible additions use a
minor release; incompatible public changes require a major release. A deprecated
API continues to work throughout 2.x and has a documented replacement before
removal in a later major release. Correctness fixes restore the documented
behavior and may change previously incorrect pixels or derivatives.

Where three.js r186 defines a behavior or a default and this page does not list
a deliberate difference, the three.js behavior is the documented behavior.
Version 2.0 changed defaults, vertex orders, color spaces and lighting where 1.x
departed from three.js without saying so; the
[migration notes](https://github.com/jake-w-liu/Diff3D.jl/blob/main/release/2.0/migration.md)
list every such change.

Unexported helpers, internal cache fields, automatically generated constructors
that are not documented, generated HTML implementation details, and
`window.__diff3dDebug` are internal. Object IDs identify nodes within a running
process; they are not persistent asset identifiers. Floating-point rounding,
exact allocation counts, and compiler-generated code are not compatibility
guarantees.

The [API reference](api.md) is the entry point for supported calls. A matching
three.js name does not imply identical arguments, implementation, or backend
support.

Geometry generators follow three.js r186 vertex placement, vertex and index
order, UVs, normals, and defaults, with these deliberate differences:
`ExtrudeGeometry` defaults to `bevel_enabled=false` (three.js enables a bevel by
default); extrusion along a polyline `extrude_path` keeps smooth shared side
normals and per-ring UVs rather than three.js's flat faces and world-space UVs;
`ShapeGeometry` and `ExtrudeGeometry` triangulate with Diff3D's ear clipper
rather than Earcut, so triangle and vertex order differ; generators do not add
three.js's per-part draw groups, because the renderers draw a mesh with one
material; `CylinderGeometry` caps share one center vertex instead of one per
segment; and where three.js returns NaN or a collapsed shape from overflow or
underflow (extreme radii, control points near `floatmax`, zero-height open
cylinders), Diff3D returns the finite geometry. `merge_geometries` keeps
`with_groups=true` as its default, and the `apply_matrix4!` family also
transforms morph targets.

## Rendering backends

| Entry point | Supported role | Boundaries |
|---|---|---|
| `render!`, `render_msaa!` | CPU rendering of scenes, including mesh, instance, skin, line, point, and sprite paths | Hard visibility and depth decisions are discrete. Use the documented options of each entry point. |
| `render_pooled!` | CPU rendering of opaque triangle meshes, posed skins, and instances; flat shading unless a mesh sets `flat_shading=false` | Skips transparent and wireframe meshes and standalone line/point/sprite primitives. |
| `render_tiled!` | CPU rendering of opaque triangle meshes, posed skins, and instances, including mesh wireframes; flat shading unless a mesh sets `flat_shading=false` | Standalone line/point/sprite objects are not drawn. Use `render!` for scenes requiring general transparency. |
| `soft_render` | Soft triangle rasterization from explicit vertices, faces, face colors, and a view-projection matrix | Soft coverage and depth blending define a different image model from hard rasterization. |
| `differentiable_render` | Build explicit soft-render inputs from a parameter vector | `setup_fn(params)` must return the documented five values and preserve differentiated scalar types. |
| `soft_render_scene` | Extract and soft-render visible triangle meshes, posed skins, and triangle instances | Scene extraction stores `Float64` geometry/colors; use explicit inputs for geometry/camera derivatives. |
| `save_webgl_html` | Standalone interactive browser export | Uses WebGL 1 and built-in exported materials. It does not execute Julia callbacks or support arbitrary `ShaderMaterial` GLSL, WebGPU, or WebXR. |

`ShaderMaterial(program=...)` executes a Julia CPU fragment callback. Its GLSL
string fields do not constitute a browser shader implementation. Export rejects
this material instead of replacing its effect. Browser export is a scene export,
not a live connection to subsequent Julia scene mutations.

Exported fragment shaders request `highp` float precision when the browser's
context reports it and fall back to `mediump` otherwise. WebGL 1 only guarantees
10-bit `mediump` floats, which is too coarse for interpolated texture
coordinates. A context without fragment `highp` support therefore renders
textured surfaces less precisely than the validated environments.

WebGL 1 textures whose dimensions are not powers of two use clamp-to-edge
wrapping and base-level nearest or linear filtering. Exported cube maps follow
the same restriction: their authored mipmaps are not uploaded and their maximum
LOD is zero. Use power-of-two faces for mipmapped browser environment maps.
For a partial power-of-two authored chain, the exporter fills the physical mip
pyramid from the base before uploading the authored levels. Explicit environment
LOD remains capped at the last authored level; automatic minification can reach
the generated tail. Supply a complete chain to author every sampled level.

Cache call forms are `render!(target, scene, camera; cache=RenderCache())`,
`render_pooled!(target, scene, camera, RenderCache())`, and
`render_tiled!(target, scene, camera; tiles=1, cache=[RenderCache()])`.
For tiled rendering, supply at least
`min(tiles, target.height, Threads.nthreads())` distinct caches. The function
does not enlarge a caller-supplied cache vector.

The browser export raises `ArgumentError` for scene content its viewer cannot
represent rather than dropping it: `ShaderMaterial`, a `LightProbe` with
second-order `sh` coefficients, shadow-casting lights with a non-default
`shadow_intensity` or `shadow_normal_bias`, and cameras with a view offset or a
film offset (including `StereoCamera` eyes). The WebGL 1 viewer decodes sRGB
textures after filtering; the CPU renderers decode each texel first, as WebGL 2
does.

CPU, soft, and browser images are not promised to be pixel-identical. Coverage,
precision, lighting/material implementations, filtering, and antialiasing can
differ. The example registry records the scope of each upstream example match;
its partial examples are not a complete three.js conformance suite.

## Deliberate differences from three.js

Besides the geometry and export differences above, these behaviors differ from
three.js r186 on purpose:

- Rendering: opaque triangles use an inclusive edge rule rather than the GPU
  top-left rule, so the owner of a shared-edge pixel at exactly equal depth is
  the later-drawn triangle. Opaque meshes are ordered by depth and object id,
  not grouped by material. Each instance of a transparent `InstancedMesh` is
  sorted by its own depth. Lines are sampled at integer pixel positions, and
  point size attenuation scales with the camera-to-target distance.
- Shading: ambient and fill light, the transmission background, anisotropy
  (isotropic broadening) and rect-area lights (a 3x3 quadrature of the
  point-light BRDF rather than LTC) use Diff3D's own models. Direct lighting of
  the Standard and Physical materials follows the three.js BRDF. The browser
  export evaluates ambient light the three.js way, so a metallic surface lit
  mostly by ambient light renders brighter on the CPU than in the browser.
- Lights and shadows: IES profiles normalize candela linearly (three.js squares
  it). The shadow bias is a positive depth offset with default `3e-3` and a
  default PCF radius of 0. `shadow_normal_bias` offsets along the shaded normal.
- Textures: `Texture` keeps its own defaults for wrap mode, color space and
  minification filter, and the first row of a `DataTexture` array is the top
  of the image (in three.js, with `flipY = false`, it is the bottom). Cube textures
  are not mirrored in X, so `light_probe_from_cube_texture` coefficients 4, 5
  and 8 have the opposite sign to three.js for the same images.
- Cameras and lights keep their 1.x construction defaults: `PerspectiveCamera`
  has a 45° field of view and `far = 1000` (three.js: 50° and 2000),
  `OrthographicCamera` has `far = 1000` (three.js: 2000), both start at
  position `(0, 0, 5)` (three.js: the origin), and a `RectAreaLight` starts at
  `(0, 1, 0)` (three.js: the origin).
- Raycasting: point and line thresholds, and a point hit's `distance_to_ray`,
  are measured in world space. Sphere tests treat a negative radius as empty.
- Animation: one `AnimationMixer` drives one clip and uses a single
  `time_scale`. `Clock()` starts at construction. Keyframe times must be finite
  and strictly increasing. A morph-name track on a parent resolves the name on
  each driven mesh.
- Helpers are built once from the object's state at construction. `CameraHelper`
  and `PlaneHelper` draw Diff3D's own line sets, and `color=` on a helper draws a
  single color.
- Loaders: `load_rgbe` decodes with the reference `rgbe.c` scale
  (`mantissa * 2^(e-136)`), about 0.39% darker than three.js. PLY integer colors
  are normalized by their type maximum, and polygons with more than four
  vertices are fan-triangulated. glTF primitives without normals are de-indexed
  with face normals. `load_obj_scene` gives each material its own `Mesh`.
  The JSON parser matches `JSON.parse` except that numbers rounding to infinity,
  unpaired surrogates and invalid UTF-8 are errors.
- SVG: `<symbol>` renders only through `<use>`; percentage lengths resolve
  against the current viewport; crossing or overlapping fill loops are filled
  exactly under the fill rule; and the `<style>` cascade implements a CSS
  subset (unsupported selectors are errors) rather than three.js's class and id
  matching.
- Reverse mode: at kinks of `min`, `max`, `abs`, `mod`, `rem` and `hypot`, an
  `ADVar` returns a one-sided derivative; ties of `min` and `max` select the
  first argument.

## Not implemented

These three.js r186 features have no Diff3D counterpart yet: `renderOrder`;
`Object3D.clone`/`copy`; blending modes other than normal alpha blending and
`premultipliedAlpha`; environment maps on the Basic, Lambert and Phong
materials; bump and displacement maps; `alphaHash`; lines and points as shadow
casters; simultaneous actions on one mixer (weights, fades, cross-fades, warps,
additive clips); `FirstPersonControls`, `ArcballControls` and three.js's
`FlyControls` behavior; `TTFLoader`; and `Color` HSL and CSS-style helpers.
`save_gltf` writes node hierarchies, mesh, line and point primitives, morph
targets, untextured materials, and transform and morph-weight animations; it
raises an error for textures, cameras, lights, skins and instancing. WebGPU,
TSL node materials, WebXR and audio playback are outside the package's scope.

## Numeric and differentiation inputs

The mutable scene graph and cameras store `Float64` transforms. Parametric math
types and explicit soft-render inputs support floating-point and differentiated
scalars without requiring those values to be stored in mutable scene objects.
Use `view_matrix_from_params` and `projection_matrix_from_params` for
differentiated camera parameters.

ForwardDiff operates through scalar-type-preserving math and soft rendering.
The built-in reverse engine uses `ADVar`, whose primal values and adjoints are
`Float64`. It is not an arbitrary-precision reverse engine. `BigFloat` can be
used by the generic numerical paths covered by their API documentation; it does
not turn the entire scene, browser, or reverse pipeline into a high-precision
renderer.

Keep integer face indices and topology fixed when differentiating a soft image.
Discrete changes such as topology, LOD selection, indexing, and hard clipping
are not differentiable operations. At mathematically nonsmooth points, a
selected branch derivative is not a promise of a unique derivative. Loss,
gradient, and optimizer APIs document the objective and parameter representation
they consume.

## Mutation, ownership, and concurrency

- Change a scene hierarchy through `add!` and `remove!`; direct edits to parent
  and child storage can violate its tree invariants. `add!` reparents an existing
  child and rejects cycles.
- Render targets own mutable image/depth buffers. Mutating render functions
  overwrite their target. Copy an output when it must survive another render.
- A soft workspace owns its returned image. A later call using the same
  workspace and dimensions overwrites that image. A workspace's scalar type must
  match the promoted rendering type; use a matching workspace for AD inputs.
- `RenderCache` and soft workspaces retain reusable numeric scratch storage.
  Rendering a replacement scene releases inactive scene/AD references, but does
  not promise that scratch capacity or operating-system memory immediately
  shrinks. Exceptional high-precision numerical paths may allocate.
- Concurrent independent renders use distinct targets, caches, workspaces, and
  mutable scenes. Do not mutate a scene, geometry, material, or texture while a
  render reads it. `render_tiled!` manages its own internal workers; that does
  not make a shared caller-owned cache reentrant.
- Reverse-gradient tapes are task-local. Independent calls can run in separate
  tasks; mutable `ADVar` nodes and externally mutated objective state must not be
  shared between concurrent gradient evaluations.

## Assets and errors

Loaders support their documented format subsets. Unknown required glTF
extensions are errors. Optional extensions can be ignored as permitted by glTF;
applications requiring their effect must check the supported list. The following
list comes directly from the loader's required-extension validator:

```@eval
using Markdown
using Diff3D
Markdown.parse(join(["- `" * name * "`" for name in
                     sort!(collect(Diff3D._GLTF_SUPPORTED_EXTENSIONS))], "\n"))
```

Draco and Meshopt geometry compression and Basis textures are outside this
loader's supported subset. Standalone KTX2 loading accepts the documented
uncompressed formats; it does not provide Basis transcoding, compressed texture
arrays, or a general KTX2 mip-chain loader. See `load_gltf_asset`, `load_glb_asset`,
`load_ktx2`, and the other loader docstrings for their detailed input rules.

Invalid arguments and unsupported inputs must produce an error rather than a
successful-looking replacement result. Exception types explicitly documented
for an API are part of its contract. Diagnostic wording may become more precise;
applications should not parse error strings as a machine protocol. Numerical
domain and representability limits continue to follow each operation's
documented rules, including deliberate non-finite results where applicable.

## Extension points

Julia fragment callbacks and explicit differentiable setup functions are
supported programmable entry points. Public abstract types identify dispatch
families; subtyping alone does not supply scene collection or renderer
integration. For example, scene light storage accepts built-in light types,
while direct CPU shading can use a custom `light_contribution` method. Internal
renderer dispatch and generated browser JavaScript are not plugin interfaces.

## Platform and validation policy

Diff3D 2.x supports Julia 1.10 and later in the 1.x series, as declared in
`Project.toml`. Release validation runs the minimum supported version,
Julia 1.10, and the current stable release, Julia 1.13, on Linux, macOS, and
Windows. Both versions are pinned in the workflows so recorded evidence names an
exact runtime; a newer stable Julia is added to the matrix rather than replacing
a supported version silently. Browser export is validated with Chromium, Firefox,
and WebKit; a working WebGL context is required. All three engines run on Linux
with software rendering — Chromium through SwiftShader, Firefox and WebKit
through Mesa — and each runs the full rendering-contract suite and the
registered-example sweep. Firefox is not validated on the hosted macOS runners:
they have no GPU, so Firefox falls back to Apple's software OpenGL renderer,
which drops triangles that need clipping and loses geometry from correct WebGL
content, three.js included. The validation harness refuses that renderer.
Firefox on a Mac with a GPU was checked separately on Apple silicon.
Browser engine tests do not certify every device, GPU driver, or vendor browser
build. Release evidence records the exact environments exercised.

Release validation includes normal-compiler correctness/allocation checks,
concurrent rendering, output and gradient oracles, loader failures, resource
lifetimes, and public-API consumer workflows. Performance comparisons state
their hardware, input sizes, accuracy, renderer, and derivative method. They
apply to those measured workloads rather than every scene or platform.
