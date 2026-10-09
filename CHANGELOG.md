# Changelog

## Unreleased

- Replace the native JpegTurbo/libjpeg-turbo dependency with a pure-Julia JPEG
  decoder covering baseline, extended-sequential, and progressive Huffman JPEG
  (restart intervals, non-interleaved scans, table redefinition, 1–4
  components, arbitrary sampling factors, YCbCr/RGB/grayscale and Adobe
  CMYK/YCCK data). ColorTypes and JpegTurbo are no longer dependencies, so the
  package no longer ships or loads any non-Julia binary image codec.
- Decode single-scan sequential JPEGs through per-band coefficient buffers
  instead of whole-image planes and emit Float64 pixels directly, so
  `_decode_jpeg` allocates approximately the output array and runs at
  ~1.3–1.75x libjpeg-turbo wall time. Declared frames too large for the
  source to fill fail before allocating coefficient planes, and the entropy
  reader widens the Huffman lookahead to 9 bits.
- Parse PLY ASCII bodies as one whitespace-separated token stream so rows
  may share or span lines, headers using bare CR load, and unknown or
  property-less elements consume their token counts, as three.js does.
- Detect JPEG images by the leading start-of-image marker alone, so files
  with trailing padding or appended data load instead of being rejected.
- Align glTF loading with three.js GLTFLoader: an omitted sampler minFilter
  defaults to LinearMipmapLinear, normalized integer encodings are accepted
  for rotation and weights animation outputs, an unknown alphaMode is an
  error, and images or textures without a source raise errors.
- Read OBJ/MTL material statements as three.js does: keywords match
  case-insensitively, `newmtl`/`usemtl`/`mtllib` take the rest of the line,
  an mtllib list falls back to space-separated names and missing libraries
  raise errors, and `map_Ks`/`map_Ke`/`norm`/`map_d` apply `-s`/`-o` as
  texture repeat/offset.
- Match ASCII STL keywords as whole tokens and reject text files that are
  not STL.
- `add!` moves an already-present child to the end like three.js
  `Object3D.add`, preserving the child's LOD registrations.
- `lod_select` and `lod_update!` follow three.js LOD hysteresis, and a
  single-level LOD update leaves its visibility alone.
- Raycasts align with three.js `Raycaster`: an LOD reports hits for the
  level its ray-origin distance selects, point hits report the closest
  point on the ray, line hits accept distance equal to the threshold, the
  default layer channel is 0, and meshes, instances, points and lines skip
  their primitive loop when the ray misses a conservative bounding sphere.
- `quat_slerp` normalizes a linear blend at dot 0.9995 and above, matching
  three.js.
- Add `mat4_compose`, `mat4_decompose`, `mat4_determinant` and
  `quat_from_rotation_matrix` mirroring three.js `Matrix4`/`Quaternion`.
  `compute_local_matrix` composes translation, rotation and scale directly,
  and recursive raycasts no longer box each object's world matrix (a
  400-object single-ray cast: ~1.37 ms/115 KB to ~0.26 ms/736 B).
- Blend points, sprites and wireframes only for `transparent` materials, as
  three.js does, and apply `alphaTest` to material opacity times texture
  alpha on the opaque flat and pooled mesh paths.
- `render_pooled!` and `render_tiled!` honour a mesh's
  `flat_shading=false` with per-pixel shading, matching `render!`.
- Match three.js punctual-light attenuation —
  `pow2(saturate(1-pow4(d/cutoff)))` with a 0.01 floor — and smoothstep spot
  penumbra.
- `HemisphereLight` aims along its normalized world position like three.js
  (new `position` keyword), `MeshNormalMaterial` encodes view-space
  normals, `MeshToonMaterial` supports vertex colors, and point, spot and
  rect-area lights expose the three.js `power` property in lumens.
- Diffuse responses use three.js `BRDF_Lambert` (albedo/π), and the Phong
  specular uses the normalized `BRDF_BlinnPhong` distribution with Schlick
  fresnel.
- Exported WebGL viewers follow three.js render-list semantics: only
  `transparent` materials blend, opaque draws write alpha 1 regardless of
  texture or opacity alpha, and opaque items draw front-to-back while
  transparent items draw back-to-front by bounding-sphere centre.
- WebGL export escapes U+2028/U+2029 in strings and raises errors for
  non-finite numbers and invalid UTF-8 instead of serializing `0` or a
  script-breaking character.
- ForwardDiff gradients of `soft_render`, `vertex_render_fn` and
  `color_render_fn` are finite for `sigma`/`gamma` below ~1e-154 (they were
  NaN because the configured constants were promoted to Duals).
- `ADVar` `min`/`max` propagate NaN and signed zeros like Base.
- `numerical_gradient` divides by the step actually taken, removing an
  `ulp(x)/δ` error for parameters far from zero.
- Reverse-mode gradients allocate one object per recorded operation, reuse
  task-local tapes, and keep per-pixel soft-render constants off the tape
  (a 24-face 32x32 soft-render gradient: ~65 ms / 101 MB to ~25 ms / 56 MB).
- Add `MapControls` (an `OrbitControls` with the new `screen_space_panning=false`
  keyword, panning across the plane orthogonal to `camera.up`), `Box3Helper`,
  and `ArrowHelper`, following three.js.
- Animation loop timing follows three.js `AnimationAction`: finite
  `repetitions` also finish when playing backward, backward ping-pong starts
  unmirrored, `repetitions=0` plays one loop, and a repeating clip samples its
  first frame at exact loop multiples (sample the end pose with
  `loop=:once, clamp_when_finished=true`). Quaternion tracks keep the target's
  Euler order.
- `OrbitControls` applies azimuth limits only when both are finite and clamps
  the polar angle with three.js's `1e-6` pole margin. `trackball_rotate!`
  follows three.js `TrackballControls`: it turns the eye and `camera.up` about
  the axis perpendicular to the drag, so the camera can pass over the poles
  (a positive `dx` now orbits the camera to its left, like dragging right).
  Fly and pointer-lock controls now steer rotation-driven (glTF) cameras.
- `BoxHelper` bounds the object and its descendants in world space and
  `HemisphereLightHelper` sits at the light's world position, as in three.js;
  `CameraHelper` reports unbounded frusta explicitly.

## 1.0.0

The first 1.x compatibility contract covers documented public calls, properties,
numeric and AD inputs, extension points, errors, and ownership of mutable data.
Compatible additions use minor releases; incompatible public changes require a
major release. See [compatibility](docs/src/compatibility.md) and the
[0.1.8 migration guide](release/1.0/migration.md).

This release is breaking relative to the registered 0.1.8, which carried no
compatibility promise. Corrected numerical, shading, deformation and loader
behaviour changes previously incorrect pixels and derivatives, failed WebGL
exports and destination symlinks are now handled differently, and mutable
render caches and soft workspaces have explicit ownership rules. Recheck
application baselines rather than accepting every changed result as equivalent.

Changes included in this release:

- Correct gradient propagation through zero means, planar triangle normals and
  areas, scaled vector differences, and zero line-projection parameters.
- Preserve existing WebGL exports when serialization fails. Replace destination
  symlinks without changing their targets and preserve POSIX regular-file modes.
- Format exported numbers through Julia's reusable Printf buffer on every
  platform, preserving Float64 precision and exact integer IDs on Windows.
- Share mutually exclusive material samplers so the full physical-texture path
  fits the tested 16-sampler contexts. Reuse linked-program shader locations
  during repeated browser rendering.
- Keep non-power-of-two browser cube maps at level zero, preventing invalid
  WebGL mip uploads in exported environments such as the glTF loader example.
  Complete the physical mip pyramid for a partial authored power-of-two chain so
  those environments keep sampling their authored levels.
- Request `highp` fragment precision in exported shaders wherever the browser
  reports it, so texture coordinates survive contexts that honour the 10-bit
  WebGL 1 `mediump` minimum.
- Keep the exported viewer's frame loop alive when a frame raises, and bound the
  retry so a viewer that fails every frame stops instead of rethrowing about sixty
  times a second. Report the completed-frame count, the last frame error and the
  context-loss state, so a canvas showing only its background can be told apart
  from a loop that died, a frame that drew nothing, and a draw that rasterised
  nothing without another validation round trip.
- Recover a lost WebGL context the way three.js does: prevent its default so the
  browser restores it, draw nothing while it is lost, and rebuild every buffer,
  texture and program from the scene's CPU data through the same resource path
  used at start-up.
- Link viewer programs once and enumerate their active uniforms and attributes
  into a link-time table, replacing the by-name cache that could keep a null
  location forever. Write every uniform through one typed writer: an inactive
  name stays a no-op, while a misspelt required name, a wrong component count
  and a type the call cannot write throw instead of leaving a zero matrix or a
  zero opacity behind.
- Re-declare the vertex arrays a draw uses and disable every other one before
  drawing, bind `aPosition` to attribute 0 in every program, and draw instanced
  only for objects that own instance matrices instead of routing every object
  through a shared identity buffer.
- Establish the GL state a frame depends on at the top of the frame and around
  each shadow pass, unbind the shadow framebuffer when a pass throws, and keep
  a reported error on a persistent banner instead of letting the next frame
  erase it.
- Reduce allocations in affine morph transforms, exact integer serialization,
  CSG clipping/inversion, and standard-material lighting with ambient occlusion.
- Execute all tutorials and publish versioned documentation. Main-branch docs
  use `/dev/`; version tags provide versioned pages and the stable alias.
- Add complete optimized test shards, release platform/browser matrices, fresh
  package-consumer checks, and pinned comparisons with three.js 0.186.0 on both
  a software-rendering Linux runner and a hardware-GPU macOS host.
- Validate Firefox on Linux with Mesa's llvmpipe instead of on the hosted macOS
  runners, which have no GPU and give Firefox Apple's software OpenGL renderer.
  That renderer drops triangles that need clipping, so the browser harness now
  records each engine's unsanitised renderer and refuses it.
- Reject machine-specific filesystem paths anywhere in the published package
  tree, including inside the committed release evidence archives.

Julia 1.10 or later in the 1.x series is supported. Release validation runs the
minimum supported Julia 1.10 and the current stable Julia 1.13 on Linux, macOS
and Windows, with browser export checked in Chromium, Firefox and WebKit on Linux
and in Firefox and WebKit on an Apple silicon GPU. CPU rendering, soft
differentiable rendering and WebGL export have distinct contracts. Browser
export uses WebGL 1 and built-in materials; it does not export `ShaderMaterial`
callbacks. Required Draco, Meshopt and Basis glTF extensions remain unsupported.
A matching three.js API name does not imply matching backend coverage or speed.

The [release tracker](RELEASE_PLAN.md) records the candidate's validation status;
its checks must pass before publication. The
[comparison report](release/1.0/comparison.md) includes both measurement orders,
raw data, observed advantages and unfavorable results; the
[protocol](benchmarks/threejs/README.md) describes how to reproduce it.
