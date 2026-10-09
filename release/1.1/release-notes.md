# Diff3D.jl 1.1.0

Diff3D 1.1 is a compatible minor release under the 1.x contract documented in
`docs/src/compatibility.md`. It closes the remaining parity items against
three.js r186, replaces the bundled native JPEG codec with a pure-Julia
decoder, adds compatible public API, and reduces allocations on documented
hot paths. No documented call, property, or behaviour was removed or
redefined; correctness fixes change results only where 1.0.0 produced
incorrect pixels or derivatives.

## Changes included

- Diffuse light responses use three.js `BRDF_Lambert` (albedo/π) and the Phong
  specular uses the normalized `BRDF_BlinnPhong` distribution with Schlick
  fresnel. Lit pixels and their derivatives change accordingly — this is the
  intended parity correction, so re-derive image and gradient baselines where
  they pinned the un-normalized values.
- A pure-Julia JPEG decoder (baseline, extended-sequential, and progressive
  Huffman) replaces JpegTurbo; ColorTypes and JpegTurbo are no longer
  dependencies, so the package ships no non-Julia image codec.
- Loader parity with three.js: glTF sampler/minFilter defaults, normalized
  animation output encodings, and strict `alphaMode`/image-source errors;
  OBJ/MTL keyword and map-option semantics; ASCII PLY token streams; STL
  keyword matching; JPEG detection by start-of-image marker.
- Animation follows three.js `AnimationAction` loop timing: finite
  `repetitions` finish when playing backward, backward ping-pong starts
  unmirrored, `repetitions=0` plays one loop, and a repeating clip samples its
  first frame at exact loop multiples. Sample an end pose with
  `loop=:once, clamp_when_finished=true`.
- New public API mirroring three.js: `mat4_compose`, `mat4_decompose`,
  `mat4_determinant`, `quat_from_rotation_matrix`, `MapControls`,
  `Box3Helper`, `ArrowHelper`, `merge_vertices`, `holes` for
  `ShapeGeometry`/`ExtrudeGeometry`, `steps`/opt-in bevels for
  `ExtrudeGeometry`, `closed` tubes, `height_segments` for `CapsuleGeometry`,
  and three.js angular-sweep options for the curved primitives. The public
  export inventory is now 461 names.
- Render-list parity: points, sprites, wireframes and exported viewers blend
  only for `transparent` materials; opaque draws write alpha 1; opaque items
  draw front-to-back and transparent items back-to-front;
  `render_pooled!`/`render_tiled!` honour `flat_shading=false`.
- WebGL export escapes U+2028/U+2029 and raises for non-finite numbers and
  invalid UTF-8 instead of serializing `0` or a script-breaking character.
- Allocation reductions on documented hot paths: `compute_local_matrix`
  composes TRS directly and recursive raycasts no longer box world matrices
  (400-object single-ray cast ~1.37 ms/115 KB → ~0.26 ms/736 B); reverse-mode
  gradients allocate one object per recorded operation and reuse task-local
  tapes (24-face 32×32 soft-render gradient ~65 ms/101 MB → ~25 ms/56 MB);
  single-scan JPEG decode allocates approximately the output array.
- Correctness fixes under the compatibility contract: ForwardDiff gradients
  of `soft_render`/`vertex_render_fn`/`color_render_fn` stay finite for
  `sigma`/`gamma` below ~1e-154; `numerical_gradient` divides by the step
  actually taken; `ADVar` `min`/`max` propagate NaN and signed zeros like
  Base; closed-path extrusions distribute frame twist so non-planar loops no
  longer show a twisted seam.

## Verification

- All six optimized test shards pass under `--require-optimized` (allocation
  assertions enforced at the normal compiler optimization level); the shard
  partition covers every suite unit exactly once.
- `julia --project=. test/test_runner.jl` and `python
  test/test_check_shards.py` structural checks pass; every exported public
  name carries a docstring (462 module names, none undocumented).
- A fresh audit pass over the merged tree — including the source files the
  per-subsystem audit did not touch (`cameras`, `csg`, `io`, `losses`,
  `shadows`, `textures`, `teapot_geometry`, `benchmark`, `docs`) — verified
  texture-transform, decompose/determinant, and cubemap conventions against
  the three.js r186 sources.

Browser/platform matrices and the pinned three.js comparison are run by the
release-validation workflow on the tagged commit; local browser runs are not
authoritative per `release/1.1/evidence.md`.
