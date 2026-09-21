# Compatibility

This contract defines the supported surface for Diff3D 1.x. Consult the
documentation for the package version you use; development documentation can
include unreleased work.

## Public API and versioning

The public API comprises exported names, their documented constructors and
methods, keyword arguments and defaults, return values, and documented object
properties. Examples in the documentation use this surface. Julia indexing is
one-based, camera field of view and rotations use radians, and transform
matrices use column-major storage.

The 1.x series preserves that documented behavior. Compatible additions use a
minor release; incompatible public changes require a major release. A deprecated
API continues to work throughout 1.x and has a documented replacement before
removal in a later major release. Correctness fixes restore the documented
behavior and may change previously incorrect pixels or derivatives.

Unexported helpers, internal cache fields, automatically generated constructors
that are not documented, generated HTML implementation details, and
`window.__diff3dDebug` are internal. Object IDs identify nodes within a running
process; they are not persistent asset identifiers. Floating-point rounding,
exact allocation counts, and compiler-generated code are not compatibility
guarantees.

The [API reference](api.md) is the entry point for supported calls. A matching
three.js name does not imply identical arguments, implementation, or backend
support.

## Rendering backends

| Entry point | Supported role | Boundaries |
|---|---|---|
| `render!`, `render_msaa!` | CPU rendering of scenes, including mesh, instance, skin, line, point, and sprite paths | Hard visibility and depth decisions are discrete. Use the documented options of each entry point. |
| `render_pooled!` | CPU rendering of flat opaque triangle meshes, posed skins, and instances | Skips transparent and wireframe meshes and standalone line/point/sprite primitives. |
| `render_tiled!` | CPU rendering of flat opaque triangle meshes, posed skins, and instances, including mesh wireframes | Standalone line/point/sprite objects are not drawn. Use `render!` for scenes requiring general transparency. |
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

CPU, soft, and browser images are not promised to be pixel-identical. Coverage,
precision, lighting/material implementations, filtering, and antialiasing can
differ. The example registry records the scope of each upstream example match;
its partial examples are not a complete three.js conformance suite.

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

Diff3D 1.x supports Julia 1.10 and later in the 1.x series, as declared in
`Project.toml`. The 1.0 release validation runs the minimum supported version,
Julia 1.10, and the current stable release, Julia 1.13, on Linux, macOS, and
Windows. Both versions are pinned in the workflows so recorded evidence names an
exact runtime; a newer stable Julia is added to the matrix rather than replacing
a supported version silently. Browser export is validated with Chromium, Firefox,
and WebKit; a working WebGL context is required. Chromium and WebKit are
exercised on Linux with software rendering and Firefox on macOS, because
headless Linux Firefox cannot reliably obtain a WebGL context.
Browser engine tests do not certify every device, GPU driver, or vendor browser
build. Release evidence records the exact environments exercised.

Release validation includes normal-compiler correctness/allocation checks,
concurrent rendering, output and gradient oracles, loader failures, resource
lifetimes, and public-API consumer workflows. Performance comparisons state
their hardware, input sizes, accuracy, renderer, and derivative method. They
apply to those measured workloads rather than every scene or platform.
