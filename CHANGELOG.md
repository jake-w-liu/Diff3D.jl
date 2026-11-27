# Changelog

## 2.0.0

A major release: the result of a full audit of every subsystem against
three.js r186, with each finding reproduced against the three.js source run
under Node (or, for the exported viewer, in headless Chromium) before it was
changed. Wherever 1.x departed from three.js without documenting it, 2.0 follows
three.js, so default values, vertex orders, color spaces and rendered pixels
change. Exported 1.x names and documented signatures still work.
[`release/2.0/migration.md`](release/2.0/migration.md) lists every behavior
change and how to keep a 1.x result; the
[compatibility contract](docs/src/compatibility.md) lists the differences from
three.js that remain on purpose and the features not yet implemented.

The release also adds 222 exported names (the three.js `Curve`/`Path`/`Shape`
hierarchy, `Object3D` operations, camera view offsets, vector, matrix and
bounding-volume operations, geometry transforms and utilities, keyframe and
clip utilities, tone mapping, and STL/OBJ/PLY/glTF exporters) and makes the hot
paths faster: reverse-mode image gradients by 30-90x with 100-400x less memory,
raycasts on dense meshes by up to 14x, PNG, DEFLATE, STL, OBJ, PLY and glTF
buffer decoding by 2-25x, and `Mat4` products by 1.5-2x, with identical
results. `ForwardDiff` 1.5 is supported.

### Math, scene graph and cameras

- `mat4_decompose` now ignores the projective bottom row and uses the affine
  determinant, matching three.js `Matrix4.decompose`.
- `mat4_look_at` (and camera/OrbitControls look-at) only perturbs exactly
  parallel up vectors, matching three.js; views near the pole no longer lose
  azimuth or roll 90 degrees.
- `mat4_look_at` and `normalize` keep Float32/Int/BigFloat element types
  instead of widening.
- Camera view matrices under Group, Object3D, Scene, Mesh, Bone, camera,
  skinned/instanced mesh, line and points parents no longer allocate.
- Math value types (`Box3`, `BoundingSphere`, `Plane`, `Triangle`, `Line3`,
  `Spherical`, `Cylindrical`) accept mixed numeric arguments, and degenerate
  branches keep the general result element type.
- `Mat4` multiply and transform are about 1.5-2x faster, with identical
  results.
- Added three.js-style `quat_from_axis_angle`, `quat_conjugate`,
  `quat_invert`, `quat_angle_to`, `quat_rotate_towards`, `quat_rotate_vector`,
  `euler_from_rotation_matrix` and `euler_from_quaternion`.
- Added three.js-style Box3 queries: `box3_is_empty`, `box3_center`,
  `box3_size`, `box3_union`, `box3_intersect`, `box3_contains_point`,
  `box3_intersects_box`, `box3_apply_matrix4`.
- Added three.js camera view offsets (set_view_offset!/clear_view_offset!),
  film gauge/offset, focus and focal-length helpers (get/set_focal_length,
  get_effective_fov, get_film_width/height, get_view_bounds/size) to
  PerspectiveCamera, and view offsets to OrthographicCamera. The CPU renderer,
  soft renderer and raycasting honour them; WebGL export rejects them.
- StereoCamera now builds three.js-style off-axis eye frusta from focus and
  eye separation instead of symmetric shifted frusta.
- Added three.js Object3D operations: look_at! (cameras store the matching
  target and up, so the rendered view equals the rotation),
  rotate_on_axis!/rotate_on_world_axis!/rotate_x!/y!/z!,
  translate_on_axis!/translate_x!/y!/z!, local_to_world/world_to_local,
  get_world_position/quaternion/scale/direction,
  traverse_visible/traverse_ancestors, get_object_by_property/name/id,
  attach!, remove_from_parent!, clear_children! (clearing an LOD also drops
  its levels).
- Added three.js Vector3, Matrix3, Matrix4, Sphere, Box3, Plane, Ray, Triangle
  and MathUtils operations (vec3_*, mat3_*, mat4_*, sphere_*, box3_*, plane_*,
  ray_*, triangle_*, map_linear, inverse_lerp, damp, pingpong, smoothstep,
  smootherstep, vec3_project/vec3_unproject). They are generic over element
  types and allocation-free.
- Interpolate_linear returned the raw endpoint value (for example Int) at or
  beyond the keyframe range, making the result type unstable.

### Geometry

- Match three.js r186 triangulation for `PlaneGeometry`, `RingGeometry` and
  `CylinderGeometry`. Each quad is now split along three.js's diagonal, which
  changes displaced planes. The index order of `SphereGeometry`,
  `TorusGeometry` and `CircleGeometry` now matches three.js exactly.
- `BoxGeometry` orients each side's normal by the sign of its signed size, as
  three.js does, so negative dimensions keep outward normals. Subdivided sides
  now share exact edge coordinates.
- `SphereGeometry` keeps the ring radius non-negative like three.js. Sweeps
  outside `[0, π]` fold back onto the sphere, a negative radius mirrors only
  y, and a zero radius yields zero normals.
- `TorusKnotGeometry` builds its tube frame from three.js's curve secant, so
  vertices now match three.js, including negative `p_val`. It falls back to
  the analytic frame only where three.js's construction is not finite.
- Segment counts of 1 or 2 are now kept as in three.js instead of being raised
  to 2 or 3. This covers `CylinderGeometry`/`ConeGeometry` `radial_segments`,
  `TorusGeometry` `radial_segments`/`tubular_segments` and the
  `TorusKnotGeometry` segment counts. A count of 0 still clamps to 1.
- `compute_bounding_box` and `compute_bounding_sphere` include
  `morphPosition<k>` targets, growing the box target by target in index order
  like three.js with relative morph targets. A malformed target raises
  `ArgumentError`. CPU render frustum culling still bounds the posed positions
  it draws.
- Add `compute_tangents!` (three.js `BufferGeometry.computeTangents`).
- `edges_geometry` skips triangles with coincident corners and keeps edges
  whose dihedral angle equals `threshold_angle`, matching three.js
  `EdgesGeometry`.
- `ExtrudeGeometry` with a negative `depth` now gives flat side-wall normals
  that follow the triangle winding.
- `CatmullRomCurve` open curves now extrapolate the missing end neighbours
  (reflection about the endpoints) like three.js `CatmullRomCurve3`, which
  changes points on the first and last segments.
- `wireframe_geometry` deduplicates edges by vertex position like three.js
  `WireframeGeometry`; for example, a `BoxGeometry` now gives 18 line segments
  instead of 30.
- `ConvexGeometry` finds hull faces by gift wrapping, so hulls of hundreds to
  thousands of points are orders of magnitude faster. Output is unchanged
  wherever the previous search produced a closed hull.
- `ConvexGeometry` no longer emits overlapping, non-manifold faces with the
  wrong enclosed volume for near-coplanar input (for example box points with
  float noise) or for faces whose edges carry stacked collinear points; such
  hulls now match three.js `ConvexGeometry`.
- BoxGeometry, PolyhedronGeometry (and its platonic subclasses) and
  LatheGeometry now emit three.js vertex and index order. LatheGeometry
  accepts 1 or 2 segments.
- ParametricGeometry uses three.js UVs (u, v), face diagonals,
  finite-difference normals and its default 8x8 resolution.
  NURBSSurfaceGeometry uses the same construction.
- Edges_geometry defaults to a 1 degree threshold and welds corners to 4
  decimals as three.js EdgesGeometry does (meshes smaller than about 1e-4
  units therefore have no edges). Edge and wireframe segments follow three.js
  order and direction, and wireframe_geometry visits draw groups.
- Added the three.js Curve hierarchy: LineCurve(3), QuadraticBezierCurve(3),
  CubicBezierCurve(3), EllipseCurve, ArcCurve, SplineCurve, CurvePath, Path,
  Shape and ShapePath, with arc-length sampling, tangents, Frenet frames, pen
  commands and to_shapes. CatmullRomCurve is now a Curve. Also added
  TubeGeometry(curve), ShapeGeometry(shape) and ExtrudeGeometry(shape).
- Added RoundedBoxGeometry, BoxLineGeometry, DecalGeometry and
  ParametricFunctions (klein, plane, mobius, mobius3d).
- Added BufferGeometry transforms (apply_matrix4!, apply_quaternion!,
  rotate/translate/scale/look_at/center) and BufferGeometryUtils-style helpers
  (to_non_indexed, normalize_normals!, set_from_points!, delete_attribute!,
  estimate_bytes_used, merge_groups!, to_triangles_draw_mode!,
  to_creased_normals).
- Centripetal and chordal CatmullRomCurve no longer return NaN for control
  points near floatmax.
- CSG operations allocate less with identical output (about 31% less over 30
  mixed operations on Julia 1.13; up to 2.4x less for sphere-box union).
- SphereGeometry pole vertices now coincide exactly as in three.js; spheres
  with extreme radii keep their shape.

### Materials, textures, lights and shadows

- Nearest texture filtering now selects texels the way WebGL does: it reads
  floor(u·W), floor(v·H) and then applies the wrap mode to that texel index.
  This covers mirrored-repeat periods and cube-map faces. Before, samples that
  fell exactly on a texel boundary could read a neighbouring texel.
- `MeshPhongMaterial` specular now defaults to the linear value of three.js
  `Color(0x111111)` (about 0.0056) instead of 0.066.
- `SpriteMaterial` now defaults to `transparent=true` like three.js, so sprite
  opacity and map alpha blend by default. Pass `transparent=false` for opaque
  sprites.
- `MeshPhysicalMaterial` `sheen_color` now defaults to black like three.js.
- `MeshPhysicalMaterial` now accepts `attenuation_distance=Inf`, the three.js
  default, meaning no volume attenuation.
- `DataTexture` and `DepthTexture` now default to nearest magnification and
  minification like three.js. An explicit `mag_filter` also sets the base
  `filter` and leaves `min_filter` nearest. Pass `filter=:bilinear` for the
  old behaviour.
- Texture samplers return a single concrete color type for ForwardDiff inputs.
  The primal results of anisotropic and auto-LOD sampling no longer depend on
  the AD number type, and a zero Dual cube direction no longer yields NaN.
- Texture sampling is faster: roughly 1.2x to 1.6x on bilinear, channel, sRGB
  and auto-LOD lookups (measured on Julia 1.10 and 1.13).
- Point-light shadows now render into a six-face cube map (as three.js
  PointLightShadow does), so casters on every side of a PointLight cast
  shadows. Previously only casters inside one 90-degree frustum aimed at the
  scene centre did. For a PointLight, `compute_shadow_map` returns a
  `resolution × 6resolution` depth matrix.
- Spot-light and point-light cube-face shadow near/far planes now fit the
  scene's depth inside each light camera's frustum. Casters near the light but
  off the spot axis are no longer clipped out of the shadow map, and obliquely
  viewed scenes keep their depth precision.
- `ies_candela` and `ies_intensity` (and IES-modulated spot and point lights)
  now propagate ForwardDiff and reverse-mode derivatives with respect to the
  angle; plain real angles still return `Float64`. Angles on a tabulated
  endpoint (for example, on the luminaire axis) take the clamped branch in
  both AD modes.
- `parse_ies` reads `TILT=INCLUDE` tilt tables by value count, so tables that
  wrap across lines parse correctly (as in three.js IESLoader). Unsatisfiable
  angle counts now raise `ArgumentError`.
- `?parse_ies` and `?compute_shadow_map` now show their full docstrings;
  `ShadowMap` gained a docstring.
- Cached shadow passes allocate less per frame (directional and spot about 26%
  less; a point-light cube about as much as the old single frustum).
- SRGB textures now decode each texel before filtering (bilinear, trilinear
  and mip) in the CPU renderers, matching WebGL 2.
- Cube-map lookups clamp at face edges and ignore face UV transforms, as GLES
  does.
- HemisphereLight's ground colour now defaults to white and RectAreaLight to
  10x10, matching three.js.
- Added shadow_intensity and shadow_normal_bias (three.js
  LightShadow.intensity and normalBias) to Directional, Point and Spot lights.
- Point and spot shadow cameras now fit their near plane to the shadow
  casters, so thin casters close to a light keep their shadows.
- LightProbe accepts nine order-2 spherical-harmonic coefficients (sh),
  evaluated unclamped as in three.js; added `light_probe_from_cube_texture`, a
  port of three.js LightProbeGenerator.fromCubeTexture.
- The compact WebGL export rejects SH9 light probes and non-default shadow
  intensity or normal bias instead of silently dropping them.

### Shading and CPU rendering

- MeshStandardMaterial, MeshPhysicalMaterial and `shade_pbr` direct lighting
  now follows the three.js r186 physical BRDF: GGX distribution,
  height-correlated Smith visibility, spherical-Gaussian Schlick Fresnel,
  DFG-table multiple-scattering compensation, and the 0.0525 roughness clamp.
  Smooth surfaces now show a highlight instead of going dark.
- MeshPhysicalMaterial and `shade_pbr` derive the specular F0 from `ior` (1.5
  for `shade_pbr`) and `specular_color`, scaled by `specular_intensity`, and
  use F90 = mix(`specular_intensity`, 1, metalness), as three.js does.
- Physical clearcoat now uses the three.js GGX clearcoat lobe and dims the
  layers beneath it by the clearcoat Fresnel.
- Physical sheen now scales by `sheen`, uses Neubelt visibility, and applies
  the three.js sheen energy compensation for direct and fill light.
- Physical iridescence now uses the three.js Belcour-Barla thin-film Fresnel.
- Physical transmission now replaces the diffuse lobe instead of adding to it.
- Meshes whose world matrix mirrors space (negative determinant) keep three.js
  front faces, so they are no longer culled inside-out, and double-sided
  mirrored faces are lit correctly. For InstancedMesh, culling and two-sided
  lighting follow the object matrix, not the instance matrices, as in
  three.js.
- Transparent objects are sorted by the view depth of their world
  bounding-sphere centre (sprites use their origin), with ties broken by
  object id, matching three.js. Opaque depth ties are drawn in object-id order
  and no longer depend on the RenderCache.
- Shared triangle edges and near-plane-clipped edges are now watertight: no
  cracks or double-blended pixels.
- Transparent double-sided materials draw back faces before front faces, like
  three.js.
- Float32 render targets depth-test triangles at Float32 precision, so
  coplanar surfaces resolve as in Float64 targets.
- Cached flat and smooth mesh renders no longer allocate per frame, and smooth
  InstancedMesh renders no longer allocate per instance.
- Added `tone_map(img, mode; exposure)` with the three.js Linear, Reinhard,
  Cineon, ACESFilmic, AgX and Neutral operators. It works on images and on
  `Color3`, and is differentiable with ForwardDiff and reverse mode.
- Added `output_pass(; tone_mapping, exposure, output_color_space)`, a
  post-processing step that tone maps and then sRGB-encodes like three.js
  `OutputPass`.
- Fixed `render_tiled!` drawing wireframes in a different order from `render!`
  and skipping transparent instanced wireframes. Opaque and blended wireframes
  (mesh and instanced) are now drawn, culled and sorted the same way as in
  `render!`.
- Fixed rotated non-square sprites being sheared. Sprite quads are now scaled
  before rotation, as in three.js, for CPU rendering and raycasting.
- Faster wireframe rendering: wireframes no longer clear a full-frame scratch
  buffer per mesh or per instance, and tiled instanced wireframes no longer
  allocate per instance. On a 110-instance wireframe scene, tiled rendering
  allocates about 3.5 KB per frame instead of 0.3-1.2 MB, and runs about
  1.5-4x faster.
- Coplanar surfaces now resolve like three.js LessEqualDepth (the later-drawn
  surface wins) in the CPU renderers and the WebGL export; lines, points and
  sprites are depth-tested at the render target's precision.
- MeshPhysicalMaterial emission now sits under the clearcoat layer, the
  clearcoat lobe uses clearcoatNormal (unperturbed, or clearcoat_normal_map
  when set), and clearcoat_normal_map is no longer ignored by the CPU
  rasterizer.
- Mirrored SkinnedMesh objects keep their front faces in render!,
  render_msaa!, render_pooled!, render_tiled! and shadow maps.
- Line raycast face_index reports the draw entry (three.js `index`), and
  LineLoop closing segments are tested for 1- and 2-vertex ranges.
- Orthographic set_from_camera! rays start in the camera plane, like three.js
  Raycaster.setFromCamera.
- Mesh raycasts use three.js's watertight ray/triangle test in object space;
  rays through shared edges or corners no longer slip through, and extremely
  thin, tiny or far-translated triangles are picked with exact distances.

### Objects and raycasting

- Raycasting now culls front and back faces in the object's local space, as
  three.js does, so meshes, instances and skinned meshes under mirroring
  (negative-determinant) transforms are picked from the correct side.
- Sprites scale their quad before rotating it, matching three.js, so rotated
  non-square sprites pick, render and export to WebGL with the correct shape.
- Reusing one Raycaster for repeated casts now returns identical hits; an
  already-normalized direction is no longer renormalized on every cast.
- Raycasting skips primitives that lie beside the ray before the exact test,
  making picks on dense meshes, skinned meshes, point clouds and lines up to
  about 14x faster with bit-identical results.
- Intersection now reports three.js hit details: face vertex indices,
  face_normal, the interpolated vertex normal, uv and uv1, barycoord, a
  sprite's quad uv, and a point's world-space distance_to_ray. Raycast results
  are allocated at their exact size, so a single-hit pick allocates less than
  before.

### Controls, helpers and animation

- `OrbitControls` (and `MapControls`) now orbit about `camera.up` like
  three.js; previously they always orbited about world +y.
- `orbit_update!` and `orbit_pan!` re-apply the distance, polar, azimuth, and
  target-radius limits as three.js `update()` does, so a camera that starts
  outside the limits, or whose limits are tightened at runtime, moves back
  inside. A damped update now applies rotation, dolly and pan in a single
  three.js-style pass. `orbit_reset!` ends with one update like three.js
  `reset()`: it re-applies the limits and, with `auto_rotate`, turns the
  camera one frame.
- `OrbitControls`/`MapControls` accept an `OrthographicCamera`. Dollying
  changes `camera.zoom` within the new `min_zoom`/`max_zoom` keywords. Every
  update, pan, rotate and reset clamps the zoom to that range, and
  `orbit_save_state!`/`orbit_reset!` save and restore it.
- `OrbitControls` gains three.js auto-rotation (`auto_rotate`,
  `auto_rotate_speed`, and `orbit_update!(oc, delta_time)`) and target limits
  (`cursor`, `min_target_radius`, `max_target_radius`). A non-finite
  `delta_time` raises `ArgumentError`.
- `TrackballControls` gains `min_distance`/`max_distance`, and
  `trackball_zoom!` ignores non-positive factors like three.js instead of
  collapsing the camera onto the target.
- `DragControls` and `TransformControls` accept an `OrthographicCamera`.
- `PolarGridHelper` places spokes and rings like three.js: spokes start on +z,
  a single sector draws no spoke, and rings run outermost first. `GridHelper`
  uses three.js vertex order, and `AxesHelper` uses three.js tip colors.
- Smooth (`interpolation=:cubic`) keyframe tracks and
  `interpolate_catmull_rom` now match three.js `CubicInterpolant`. They use
  non-uniform tangent weights with zero-curvature endings, so results change
  for unevenly spaced keys; evenly spaced keys are unchanged. The exported
  WebGL player uses the same tangents.
- `AnimationMixer` now applies three.js `AnimationAction` endings to cubic
  tracks: zero slope for `:once` and `:pingpong`, and for `:repeat` zero slope
  at the first start and the last end with wrap-around across loop seams.
- Quaternion keyframe tracks sampled exactly on an interior key now return
  that key, instead of a sign-flipped slerp from the previous key.
- GlTF cubic-spline quaternion tracks now normalize the value at the first key
  time.
- `AnimationClip(name, tracks)` computes its duration from 0, like three.js
  `resetDuration`, so it is never negative.
- `morphTargetInfluences[name]` track paths now resolve morph target names, as
  three.js `PropertyBinding` does.
- `mixer_update!`/`mixer_set_time!` no longer allocate for object, camera,
  light, texture and morph tracks. Per-frame cost no longer grows with key
  count (a 100k-key track went from about 82 us to 0.3 us per update).
- AnimationMixer now steps like a three.js AnimationAction: an unclamped
  finish restores the original values and is sticky, reverse wraps count as
  loops, and cubic tracks cache their interval. mixer_set_time! restarts the
  action. New: mixer_reset!, mixer_stop!, mixer_play!, mixer_is_running,
  mixer_is_scheduled, mixer_set_loop!, and the
  zero_slope_at_start/zero_slope_at_end keywords.
- New keyframe utilities: track_shift!, track_scale!, track_trim,
  track_optimize, track_validate, clip_reset_duration, clip_trim,
  clip_optimize, clip_validate, clip_find_by_name, clip_subclip,
  clip_from_morph_target_sequence, clips_from_morph_target_sequences.
- Clock honours running and auto_start (clock_start!, clock_stop!). New
  FrameTimer mirrors three.js Timer (timer_update!, timer_reset!, timer_delta,
  timer_elapsed).
- Morph-name tracks on a group resolve the name on each driven mesh, in Julia
  and in exported web pages.
- OrbitControls damped zoom no longer overflows exp() and wedges the controls.
- Light, grid and skeleton helpers match three.js geometry and default
  colours: PointLight, DirectionalLight, SpotLight, HemisphereLight, Grid,
  PolarGrid and Skeleton. Passing color= keeps a single colour; color1/color2
  select the vertex colours.
- Web player: an unclamped finished clip leaves the exported pose, like a
  disabled three.js action.

### Loaders and exporters

- Decode progressive JPEG block smoothing at the right image edge like
  libjpeg: each row of the 5x5 DC window now shifts separately.
- Use the T.81 Annex K standard Huffman tables for sequential JPEG frames that
  carry no DHT segment (Motion-JPEG), as libjpeg does.
- Reject JPEG DHT table indices >= 4, progressive DC scans with Se != 0, and
  AC refinement codes whose size is not 1.
- Read the binary STL `COLOR=` header and per-facet 5-bit colours into a
  linear `:color` attribute, as three.js STLLoader does.
- Parse ASCII STL as a whitespace token stream, so CR-only line endings, tabs,
  repeated spaces, records that span lines, and files written on a single line
  load instead of silently giving an empty mesh or failing.
- Load OBJ `v x y z r g b` vertex colours as a linear `:color` attribute (kept
  unless a face uses a vertex without a colour), join lines that end in a
  backslash, and keep file normals when another face lacks `vn` (only corners
  without a usable normal get their face normal).
- Load PLY uvs (`s/t`, `u/v`, `texture_u/texture_v`, `tx/ty`) and the three.js
  PLYLoader property aliases (`px`/`posx`, `normalx`,
  `diffuse_red`/`diffuse_r`), and split quads as (0,1,3), (1,2,3) like
  PLYLoader.
- Add `save_stl_ascii`, `save_obj` and `save_ply` exporters following three.js
  STLExporter, OBJExporter and PLYExporter.
- Speed up mesh loading with identical output: binary STL about 4-10x faster,
  ASCII STL about 2.5x, OBJ about 2.5x, ASCII PLY about 5-8x and binary PLY
  about 10-16x.
- ASCII STL numbers follow the decimal grammar shared with the PLY/XYZ
  loaders: hexadecimal floats are rejected, and values that underflow load as
  zero.
- `inflate`/`zlib_inflate` now reject invalid Huffman code sets
  (over-subscribed or incomplete, as zlib does), HLIT above 286, and data
  between the DEFLATE stream and its Adler-32 checksum. Decoding is 3-25x
  faster.
- `load_rgbe`/`RGBELoader` now accept flat (non-RLE) files whose pixels look
  like RLE headers, and any `#?` program name, following three.js HDRLoader.
  Decoding is about 3-5x faster.
- OpenEXR PIZ decoding now rejects corrupt Huffman payload sizes with an error
  instead of hanging or returning wrong pixels. ZIP/PXR24 EXR decoding is
  faster and allocates less.
- PNG decoding is 2-6x faster, with identical output.
- The glTF/typeface JSON parser no longer overflows the stack on deeply nested
  input or throws `StringIndexError` on some malformed text. Numbers that
  underflow parse as 0 like `JSON.parse`. Invalid UTF-8 inside a JSON string
  is now an error for String input too, as it already was for bytes. Parsing
  is about 1.3-2.7x faster.
- `load_mtl` applies `d` and `Tr` like three.js MTLLoader: the last `d` and
  the last `Tr` of a material are applied in first-seen order, and only `d <
  1` or `Tr > 0` changes the opacity. So `Tr 0` next to `d 0.5` keeps the
  material translucent, while `d 0.5` followed by `d 1` leaves it opaque.
- Uncompressed KTX2 decoding is faster (RGBA8 about 5x), with identical
  output.
- GlTF materials with alphaMode BLEND now disable depth writes, matching
  three.js.
- GlTF point primitives now load with size 1 and no size attenuation, matching
  three.js.
- GlTF vertices whose skin weights are all zero now bind fully to the first
  joint instead of throwing.
- GlTF `weights` animation channels now drive only the targeted node's own
  primitives, not the meshes of child nodes.
- GlTF morph influences now start at one zero per target, with mesh `weights`
  and then node `weights` written over them element by element, as in
  three.js.
- Added KHR_mesh_quantization support to the glTF loader.
- EXT_mesh_gpu_instancing `_COLOR_0` now sets per-instance colors.
- GlTF accessor decoding is more than 10x faster on large buffers, and
  data-URI base64 decoding is about 3x faster.
- Load_ply reads PLY colours as sRGB and stores them linear, like three.js
  PLYLoader; face texcoord lists and face colours are supported, and new
  property_name_mapping / custom_property_mapping keywords mirror
  setPropertyNameMapping / setCustomPropertyNameMapping.
- Load_mtl converts Kd/Ks/Ke from sRGB to linear, uses the last of repeated
  map statements like MTLLoader, and rejects d/Tr values that give a negative
  opacity with a named error.
- Load_obj_groups shares load_obj's parser (continuations, vertex colours,
  inline comments, normal fill).
- New load_obj_scene returns OBJLoader-style objects: meshes per object and
  material, `l` records as LineSegments and `p` records as Points; with an
  mtllib it follows OBJLoader.setMaterials (library colour and opacity on
  lines and points, vertex colours off), without one OBJLoader's defaults.
- GlTF primitives without NORMAL are flat-shaded with per-triangle face
  normals; KHR_materials_ior ior 0 maps to 1000; weights channels on meshes
  without morph targets and textures on TEXCOORD_2/3 raise clear errors.
- New save_gltf writes .gltf/.glb files (node hierarchy, mesh/line/point
  primitives, morph targets, untextured materials, transform and morph-weight
  animations), readable by load_gltf and three.js GLTFLoader.

### Fonts and SVG

- SVG path arc flags written without separators (e.g. `a10 10 0 0110 10`) now
  parse like three.js SVGLoader.
- SVG `<use>` now renders its target as a child of the `use` element. The
  target keeps its own transform and presentation attributes and inherits the
  rest from `use`, not from its original ancestors. Clip paths and masks on
  the target move with each instance. Forward references to the target work.
  Circular, unknown or clipPath/mask references raise errors.
- SVG stroke width, dash array and dash offset now scale with the element
  transform (sqrt|det|), as in three.js.
- Glyph contours and SVG fills are grouped into shapes and holes by the
  nonzero/evenodd rule like three.js ShapePath.toShapes. Overlapping glyph
  contours no longer error, and same-winding nested contours are no longer
  punched out as holes.
- TextGeometry bevels now grow outward like three.js ExtrudeGeometry. The lids
  sit at -bevel_thickness and depth+bevel_thickness, and the body is widened
  by bevel_size. Previously the bevel cut an inward groove.
- Text layout handles `\n` (the next line starts one `FontData.line_height`
  lower) and draws characters missing from the font with the `?` glyph, like
  three.js Font.generateShapes.
- SVG paint accepts all 148 CSS colour keywords, `hsl()`/`hsla()` and `rgba()`
  (alpha ignored, as in three.js).
- SVG lengths accept `mm`, `cm`, `in`, `pt` and `pc` at three.js's 90 DPI.
- SVG paint colours are stored in the linear working colour space, matching
  three.js SVGLoader's Color.setStyle(..., SRGBColorSpace); mask luminance is
  still evaluated in sRGB.
- Open SVG subpaths with a fill are filled as if closed, and clipPath accepts
  open paths and lines.
- SVG clip-path and mask content is resolved in the referencing element's user
  space (own and ancestor transforms; userSpaceOnUse and objectBoundingBox).
- SVG clip-path, mask and use may reference elements defined later in the
  document; circular references and clip/mask nesting deeper than 256 levels
  are rejected with an error.
- SVG <symbol> renders only through <use>, as a nested viewport with viewBox,
  preserveAspectRatio and overflow clipping; percentages inside it refer to
  the symbol's viewport.
- SVG percentage lengths resolve against the current viewport; root
  width/height percentages no longer error.
- SVG miter joins cover the whole stroke corner.
- Self-intersecting and overlapping SVG fill loops are filled exactly under
  nonzero/evenodd instead of with ShapePath.toShapes' overlapping triangles.
- SVG <style> cascade: tuple specificity, !important, structural
  pseudo-classes over the full element tree,
  :last-child/:only-child/:nth-last-child/:last-of-type/:only-of-type/:nth-last-of-type,
  repeated id selectors. XML comments are ignored, CDATA is respected, and
  @keyframes/@font-face/@page-style at-rules are skipped. Unsupported
  selectors raise an error instead of being dropped silently.
- Faster SVG fill triangulation (including exact fills of crossing loops),
  text geometry, stylesheet matching and path parsing, with unchanged output.

### WebGL export

- WebGL export: transparent wireframes now blend in the browser viewer as in
  three.js. Line and dashed-line materials with opacity below one also blend,
  matching the CPU renderer (Diff3D line materials have no `transparent`
  flag).
- WebGL export: NUL and other C0 control characters in names and strings are
  escaped, so they survive the HTML script block.
- WebGL export: HemisphereLight data now includes its sky direction
  (normalized world position), as in three.js.
- WebGL export: two-channel (luminance-alpha) cube-map faces no longer produce
  a green environment fallback colour.
- WebGL export: data serialization is about 3-5x faster and allocates about
  40-45% less per object; number and integer text is byte-identical.
- Exported WebGL viewer: animation clip loop time now matches
  `AnimationMixer`. Zero repetitions, exact loop boundaries and reverse
  finishes previously differed.
- Exported WebGL viewer: the shadow depth pass divides clip z by w per
  fragment, as three.js does. This removes depth errors from spot-light
  (perspective) shadows that self-shadowed lit surfaces.
- Exported WebGL viewer: the bounding sphere of morph-targeted meshes, used
  for sorting and culling, now matches three.js `computeBoundingSphere`.
- Exported WebGL viewer: point and spot light distance attenuation now uses
  three.js `getDistanceAttenuation`, matching the CPU renderer.
- Exported WebGL viewer: morph-target animation reuses its vertex arrays,
  normalizes without `Math.hypot`, and skips the re-upload when weights are
  unchanged (about 2x faster per animated frame on large meshes).
- WebGL viewer: lighting now uses the three.js r186 BRDFs, including 1/pi
  Lambert diffuse; diffuse-lit exports render about pi times darker, matching
  three.js.
- WebGL viewer: mirrored meshes use clockwise front faces, and normal-mapped
  mirrored meshes keep their tangent handedness.
- WebGL viewer: static point-light shadows cover all six cube faces (default
  PCF fallback for static point lights is now 0); shadow depth is packed into
  RGBA8; shadows are fully dark (intensity 1).
- WebGL viewer: hemisphere-light direction follows the light's world position;
  flat_shading uses face normals; IBL reflections bend by roughness^4.
- WebGL viewer: cubic animation interpolation matches three.js
  CubicInterpolant; save_webgl_html rejects titles HTML cannot carry.

### Differentiable rendering

- Fixed NaN ForwardDiff gradients from `soft_render` when depth weights
  underflow or relative-depth faces tie.
- Fixed the reverse-mode derivative of `rem` with respect to the divisor near
  quotient boundaries, and `sign` on `ADVar` now has zero derivative.
- Reverse-mode `soft_render` now differentiates the pixel stage with one fused
  pullback. Gradients of image losses are 30-90x faster and use 100-400x less
  memory.
- Reverse-mode `loss_mse` and `loss_l1` record a single tape node. Results are
  unchanged.
- Reverse-mode `soft_render` transforms each shared vertex once, cutting tape
  size per face about 4x.
- ForwardDiff `soft_render` is about 2x faster: per-triangle depth logits are
  now computed once per triangle.
- Reverse mode: add ADVar rules for asinh/acosh/atanh,
  sinpi/cospi/sincospi/tanpi, sinc/cosc, rem2pi/mod2pi, ldexp, fma and
  fld/cld, plus numeric type traits. sind/cosd/tand now return exact Base
  values, and the cosc derivative at 0 is fixed.
- Soft_render_scene: instanced meshes use the object-matrix front-face flip,
  matching render! and three.js frontFaceCW.
- Soft_render: near-degenerate triangles (|doubled area| < eps) fade out
  continuously instead of disappearing abruptly.
- Float32 soft distance helpers no longer promote to Float64.
- Soft_render and loss_ssim use multiple threads when available, with
  bit-identical results for any thread count.
- Docs: remove unreachable fallback summaries and correct the loss and soft
  rasterizer docstrings.

## 1.1.1

A compatible patch release under the 1.x contract: it fixes the Julia 1.10
allocation regressions and the exported-viewer shadow pass that the 1.1.0
release CI caught.

- `ExtrudeGeometry` meets its documented allocation budgets on Julia 1.10
  again: shape and path cleanup construct `Vec2{Float64}`/`Vec3{Float64}`
  directly instead of splatting `promote` tuples, vertex emission uses typed
  top-level helpers instead of closures the 1.10 compiler cannot infer, and
  `_geometry_finite_float` gains an allocation-free Float64 path.
- `raycast` keeps its per-depth world-matrix stack as scratch storage on the
  `Raycaster` instead of resizing a fresh vector per call, restoring the
  documented 1024-byte allocation bound on Julia 1.10.
- Dynamic shadow-map passes in the WebGL export unbind the shadow sampler
  units before rendering into the shadow framebuffer. Sampling the texture
  being written formed a feedback loop that made every `drawElements` raise
  `INVALID_OPERATION` and blanked shadowed views on all WebGL engines.
- The browser-validation harness tolerates `platform.platform()` failing
  where OS release data is unavailable instead of aborting the run.

## 1.1.0

A compatible minor release under the 1.x contract: it closes the remaining
three.js r186 parity items, replaces the bundled native JPEG codec with a
pure-Julia decoder, adds compatible public API (`mat4_compose`,
`mat4_decompose`, `mat4_determinant`, `quat_from_rotation_matrix`,
`MapControls`, `Box3Helper`, `ArrowHelper`, `merge_vertices`, geometry
options, and a `vertex_colors` field on `MeshToonMaterial`), and reduces
allocations on documented hot paths. Diffuse light responses now use three.js
`BRDF_Lambert` (albedo/π), so lit pixels and their derivatives change where
the previous un-normalized form was incorrect — a documented correctness fix
under the compatibility contract.

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
- Align geometry generators with three.js r186: cones and other zero-radius
  cylinder poles no longer carry degenerate side triangles; cylinder cap,
  sphere pole, capsule (arc-length v, pole offsets, r186 row layout and
  defaults), torus knot, polyhedron (atan2(z, -x) azimuth with pole/seam
  correction) and extrusion cap/side UVs match three.js; polyhedra are flat
  shaded at `detail=0`; `LatheGeometry` uses the three.js phase and clamps
  `phi_length`; `TorusGeometry` defaults to 12 radial segments.
- Add `merge_vertices` (BufferGeometryUtils.mergeVertices), `holes` for
  `ShapeGeometry`/`ExtrudeGeometry`, `steps` and opt-in bevels for
  `ExtrudeGeometry`, `closed` tubes, `height_segments` for `CapsuleGeometry`,
  and three.js angular sweep options (`phi_start`/`phi_length`/
  `theta_start`/`theta_length`/`arc`) for sphere, cylinder, cone, circle, ring
  and torus geometry.
- Closed-path extrusions distribute the frame twist around the loop so
  non-planar loops no longer show a twisted seam.

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

The [release tracker](release/1.0/plan.md) records the candidate's validation status;
its checks must pass before publication. The
[comparison report](release/1.0/comparison.md) includes both measurement orders,
raw data, observed advantages and unfavorable results; the
[protocol](benchmarks/threejs/README.md) describes how to reproduce it.
