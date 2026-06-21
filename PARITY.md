# Diff3D.jl parity with three.js

This project is not yet a 1:1 implementation of three.js. It implements a
Julia-native subset of the scene graph, math types, geometry generators,
materials, loaders, animation helpers, CPU rasterization, and a standalone
WebGL HTML exporter for interactive examples.

The current browser demos are generated from Diff3D.jl scenes by
`save_webgl_html`. They do not embed three.js, and they are not a full
replacement for three.js `WebGLRenderer`.

## Implemented or mostly implemented

- Core math: vectors, matrices, colors, Euler angles, quaternions, boxes,
  spheres, planes, rays, and common transforms.
- Scene graph: `Object3D`, `Scene`, `Group`, parent/child traversal,
  visibility, persistent layer masks, world matrix computation, and reparenting.
- Cameras: perspective and orthographic camera projection/view basics including
  camera `zoom`, CPU `ArrayCamera` viewport compositing, and compact browser
  `ArrayCamera` scissor-split export.
- Geometry: buffer geometry plus common primitives including boxes, planes,
  spheres, cylinders, torus, torus knots, icosahedra, circles, rings, cones,
  capsules, lathes, and text-like/path helpers. Box geometry now supports
  width/height/depth segment counts.
- Objects: `Mesh`, `InstancedMesh`, `PointsObject`, `LineObject`,
  `LineSegments`, `LineLoop`, `Sprite`, `LOD`, `Bone`, `Skeleton`, and
  `SkinnedMesh` data structures.
- Materials: basic, standard, normal, Lambert, Phong, line, points,
  sprite-material data models, common material map/intensity fields,
  simple color/size export behavior, compact browser unlit output for
  `MeshBasicMaterial`, compact browser normal-color output for
  `MeshNormalMaterial`, and compact browser grayscale output for
  `MeshDepthMaterial` with basic/RGBA/RGB/RG depth packing, plus compact browser quantized diffuse output for
  `MeshToonMaterial` with shared albedo, alpha, normal, AO, light, and
  emissive map fields, compact browser diffuse-only/specular-shininess output
  for `MeshLambertMaterial`/`MeshPhongMaterial`, and procedural or
  texture-backed compact output for `MeshMatcapMaterial` with shared albedo,
  alpha, normal, and wireframe fields.
- Lights: ambient, directional, point, spot, hemisphere, rectangular area
  light data models used by CPU-side rendering paths.
- Raycaster: mesh, points, line strip, line segments, line loop, perspective
  camera rays, orthographic camera rays, and recursive scene traversal.
- Animation: vector, quaternion, and morph-weight keyframe tracks, linear,
  smooth/cubic, glTF-style cubic spline, discrete/step interpolation, clips,
  actions, and mixer update.
- Loaders: OBJ, STL, PLY, XYZ, PNG texture loading, and partial glTF/GLB asset
  parsing including meshes, signed/normalized/sparse accessors, and
  core geometry attributes (`TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `TANGENT`,
  `JOINTS_0`, `WEIGHTS_0`), glTF primitive modes for points, lines, line loops,
  line strips, triangles, triangle strips, and triangle fans, glTF material
  PNG image loading from URI/data/bufferView sources, and glTF material texture
  binding for common PBR maps
  with per-texture `textureInfo.texCoord` UV-set metadata and
  `KHR_texture_transform` offset/scale/rotation metadata for CPU and compact
  browser paths with per-sampler transform uniforms, including mesh, point,
  and sprite texture sampling,
  `KHR_materials_unlit`, `KHR_materials_emissive_strength`, occlusion strength,
  `KHR_materials_pbrSpecularGlossiness` diffuse/specular/glossiness factors
  and packed specular-glossiness texture mapped into `MeshPhongMaterial`,
  scalar `KHR_materials_clearcoat`, `KHR_materials_transmission`,
  `KHR_materials_ior`, `KHR_materials_sheen`, and
  `KHR_materials_iridescence` fields and texture references plus
  `KHR_materials_specular` and `KHR_materials_anisotropy` mapped into
  `MeshPhysicalMaterial`, required glTF extension validation for supported
  loader extensions,
  and translation/rotation/scale animation tracks including `CUBICSPLINE`,
  linear/step/`CUBICSPLINE` morph-weight animation tracks, cameras, `KHR_lights_punctual`
  directional/point/spot lights, and basic skinned-mesh binding to Diff3D.jl
  `Bone`/`Skeleton`/`SkinnedMesh` objects, CPU-side morph target
  position/normal/tangent evaluation, and glTF morph target names.
- Export/demo: standalone WebGL HTML export for meshes, instancing, points,
  lines, line loops, camera-facing textured sprite quads, material color, albedo, alpha, emissive,
  AO/light maps using exported secondary `uv2` coordinates when present,
  roughness, metalness, normal texture maps, and exported cube-texture
  environment maps with face-color fallback,
  per-vertex `:color` attributes for meshes, lines, and points,
  texture offset/repeat/rotation/center transforms, opacity/alpha blending,
  material side flags, transparent-object sorting, scene-level linear/exp2 fog,
  ambient, directional, point, spot, hemisphere scene lights,
  finite rectangular-area-light approximation, bounded case-level browser clipping planes,
  static mesh morph target influences, animated browser morph-weight playback,
  static skinned-mesh poses, CPU-side animated browser skinned-mesh vertex playback,
  textured browser sprite billboards,
  explicit perspective/orthographic camera metadata and zoom for export cases,
  runtime drawable and light visibility toggles,
  dynamic camera-distance LOD selection for exported browser drawables,
  orbit/zoom interaction, case switching, and exported linear, step,
  Catmull-Rom cubic, and quaternion keyframe playback.

## Partial parity

- WebGL export covers useful demo scenes, but it is a compact custom runtime,
  not three.js `WebGLRenderer`. It supports simple albedo textures, texture
  transforms, alpha maps, material side flags, transparent sorting, and
  ambient/directional/point/spot/hemisphere lights, compact
  none/linear/Reinhard/ACES tone mapping with case-level exposure, linear
  or sRGB browser output encoding, and sRGB-to-linear decode for exported color
  texture samplers. It still lacks shader chunks, render lists,
  render targets, full WebGL renderer tone-output/color-management parity,
  WebGL state parity, full dynamic shadow-map parity, full LTC rect-area lighting,
  full three.js skeleton lifecycle and renderer-program parity beyond compact
  uniform/float bone-texture skinning plus attached/detached bind matrices,
  PMREM/prefiltered environment lighting, and most material
  shader variants.
- glTF support parses common mesh and transform animation data, maps point,
  line, loop, strip, triangle, triangle-strip, and triangle-fan primitive modes
  to native objects or indexed triangle meshes, and now decodes
  signed, normalized, sparse, and interleaved accessors. It also evaluates
  `CUBICSPLINE` transform animation with explicit glTF tangents, normalizing
  quaternion results after Hermite interpolation. It also instantiates glTF
  perspective/orthographic cameras and `KHR_lights_punctual`
  directional/point/spot lights. Basic skins are bound to `SkinnedMesh` with
  inverse bind matrices for CPU `apply_skinning`. Morph target position, normal,
  and tangent deltas are parsed and evaluable on CPU via `apply_morph_targets`,
  `apply_morph_normals`, and `apply_morph_tangents`, with glTF target names
  preserved when present in `mesh.extras.targetNames`. glTF morph-weight animation
  channels using linear/step interpolation bind to CPU `MorphWeightsKeyframeTrack`
  playback and can export to browser vertex-buffer morph playback. Scalar
  physical-material extensions now map to `MeshPhysicalMaterial` fields,
  including texture references for clearcoat, clearcoat normals, transmission,
  sheen, iridescence, specular, and inherited PBR maps, plus the scalar
  `KHR_materials_dispersion` field. The legacy glTF
  `KHR_materials_pbrSpecularGlossiness` extension now maps diffuse, specular,
  glossiness, and packed specular-glossiness textures to `MeshPhongMaterial`
  CPU and compact-browser paths. PNG glTF images, including palette/`tRNS`
  payloads and Adam7 interlaced grayscale, grayscale+alpha, RGB, and RGBA PNGs,
  load from URI, data URI, and bufferView sources with
  MIME/extension routing, and external buffer/image URI paths are resolved with
  percent-decoding and clear
  unsupported-scheme errors. glTF data URI resources are validated with strict
  base64 and clear malformed-data errors; JPEG images now decode through
  JpegTurbo, while `.ktx2`/`KHR_texture_basisu` image references fail clearly
  until compressed-texture loading exists. Renderer shading of every physical
  extension remains partial. glTF `CUBICSPLINE` morph-weight tracks
  now bind to CPU playback and browser weight serialization. Static skinned poses and
  animated bone tracks export to browser shader-side uniform skinning for small
  skeletons, compact float bone-texture skinning for larger non-morphed
  skeletons on capable WebGL contexts, and CPU-side vertex-buffer fallback for
  morphed or unsupported skinned meshes. Static mesh morph target influences
  export to browser geometry positions, and animated glTF point/line morph
  weights now stay live through native point/line objects, CPU ray/render paths,
  and compact browser morph buffers. Skinned meshes also carry attached/detached
  bind-mode metadata plus mesh-level bind matrices through CPU skinning, glTF
  loading, and browser export/runtime skinning paths. glTF
  `EXT_mesh_gpu_instancing` mesh nodes load into native `InstancedMesh`
  children for non-skinned, non-morphed point, line, and triangle primitives with
  translation/rotation/scale instance attributes. It does
  not yet cover the full glTF feature set such as remaining texture/material
  extensions and browser/runtime material extensions.
- Sprites render in the CPU path as camera-facing quads and export to the
  browser showcase as camera-facing textured quads. Browser sprite export now
  carries sampled material maps, `Sprite.center`, `SpriteMaterial.rotation`,
  `SpriteMaterial.sizeAttenuation`, alpha maps, alpha tests, and transparent
  sorting/depth metadata.
  Remaining sprite gaps are full DOM renderer integration details rather than
  the core billboard/material fields.
- LOD containers are represented in Julia and browser export now serializes LOD
  levels with group/distance/hysteresis metadata. CPU `lod_update!` mirrors the
  three.js visibility update threshold behavior, and the compact browser runtime
  keeps per-case LOD state so hysteresis is honored while orbiting/zooming.
  Remaining LOD gaps are renderer event/callback integration details rather
  than core level switching.
- Animation supports keyframe playback for exported vector and quaternion
  transforms, including browser export for Catmull-Rom vector curves and
  glTF-style cubic spline vector/quaternion tracks. Direct `.quaternion` tracks
  now alias to object rotation in CPU playback and browser export. Euler
  `rotation` vector/component tracks now bind in CPU playback and generated
  WebGL by converting runtime Euler values to quaternions. Browser transform
  tracks are applied as absolute local position/scale/Euler rotation/quaternion
  values against each node's parent matrix, including exported bone tracks,
  non-renderable parent/group nodes, drawable parent hierarchies, and
  per-instance local matrices, instead of as deltas on an already-flattened
  world matrix. CPU playback also supports
  scalar number tracks for three.js-style component paths such as `position.x`,
  `.scale[y]`, `color.r`, `opacity`, `material.opacity`,
  `material.color.r`, camelCase material aliases such as
  `material.emissiveIntensity`, `material.envMapIntensity`,
  `material.clearcoatRoughness`, and `material.sheenColor.r`, and
  sprite material paths such as `material.rotation` and
  `material.sizeAttenuation`, plus `morphTargetInfluences[0]` and morph-weight
  tracks and glTF `weights` channels with linear/step
  interpolation. CPU playback can now route material scalar/color bindings
  through an object's material, and the browser runtime applies exported
  render-property tracks to drawable material fields such as color, opacity,
  roughness, metalness, Phong shininess/specular color, and physical scalar
  controls. Generated WebGL now reclassifies objects for transparent sorting
  when opacity animation crosses below full opacity. Whole-value string paths
  such as `material.color`, `material.emissive`, `quaternion`, and
  `morphTargetInfluences` now bind through the same constructors as the symbol
  paths for vector/quaternion/morph tracks.
  Browser export updates mesh morph positions from morph-weight tracks by
  streaming updated positions into the vertex buffer. CPU and browser playback
  also support scalar object, parent/group, and light visibility tracks,
  including initially invisible exported drawables and lights targeted by
  animation. It does not yet implement
  the full three.js animation binding system, additive blending behavior, or
  every interpolation/control mode.
- Materials are represented as Julia data structures and used by simplified
  render/export paths. Browser export now carries color, opacity, simple `map`
  textures, texture transforms, material-side flags, selected PBR maps, and
  compact normal/depth/toon/matcap material shader branches, but materials are
  not shader-compatible with three.js materials. CPU `ShaderMaterial` programs
  are supported by CPU shading; browser export rejects `ShaderMaterial` with a
  clear unsupported-material error instead of silently approximating it.

## Known missing areas

- Full `WebGLRenderer`, `WebGPURenderer`, shader library, node material system,
  post-processing passes, render targets, shadow maps, fog parity, clipping,
  logarithmic depth, full tone-output/color-management parity, and texture
  sampling parity.
- Complete loader ecosystem and full-format parity for GLTFLoader, DRACOLoader,
  KTX2Loader, EXR loaders, PMREM/UltraHDR environment-map infrastructure,
  advanced SVG path/style parity, advanced text layout/font-geometry parity,
  compressed/browser AudioLoader parity, and other three.js examples
  infrastructure.
- Full controls/event parity such as remaining OrbitControls browser
  details, TransformControls, DragControls, PointerLockControls,
  TrackballControls, keyboard/mouse event interoperability, and DOM integration.
  CPU `OrbitControls` now includes constraint, damping, save-state, and reset
  behavior, and CPU `PointerLockControls` includes pointer speed, zero-distance
  look fallback, and polar-angle limits. CPU `TransformControls` now supports
  mode selection plus world/local translation space, CPU `TrackballControls`
  covers programmatic rotate/pan/zoom/save/reset, and CPU `DragControls` covers
  direct, recursive, transform-group, and raycast picking through the existing
  CPU raycaster. Browser exported orbit controls now handle pointer-event touch
  and native `touch*` fallback orbit/pinch/pan gestures, while broader browser
  DOM/gizmo/event parity is still intentionally tracked as incomplete.
- Complete examples parity with the official three.js examples site.
  Individual examples should be ported only after the underlying features have
  tests and browser verification.

## Parity policy

- A feature should be marked implemented only when the Julia API exists, unit
  coverage verifies core behavior, and any browser-facing behavior has been
  checked through generated HTML when applicable.
- Demo output under `examples/output/` is generated and intentionally ignored
  by git. Regenerate it with the scripts in `examples/`.
- Prefer honest partial support over silent approximations. Unsupported paths
  should either fail clearly or be documented here until implemented.

## Completion roadmap

The remaining work is tracked as milestones because full three.js parity spans
renderer architecture, loaders, materials, controls, and the examples suite.
Each milestone should land in small verified slices.

### Current audit synthesis

Parallel audits split the remaining work into five critical tracks:

- Renderer/WebGL: move from a showcase shader toward an explicit renderer
  contract. Previously high-impact compact-runtime gaps such as multiple
  lights per type, transparent sorting, material-side/depth flags, common
  material maps, explicit case cameras, texture color-space metadata, and
  parented visibility for drawables/lights are now covered by tests. Remaining
  renderer work is architectural `WebGLRenderer` parity rather than another
  small showcase-shader patch.
- Materials/lights/color: color texture maps now decode sRGB to linear in flat
  and smooth CPU shading while data maps stay raw. Smooth CPU shading now covers
  the same albedo, normal, roughness, metalness, AO, emissive, and light-map
  paths as flat face shading. Flat and smooth CPU shading now sample AO/light
  maps from geometry `:uv2` when present, with primary UV fallback, and smooth
  shading now perspective-correct interpolates
  geometry `:color` attributes when materials opt in with `vertex_colors=true`.
  Common material texture bindings now preserve glTF `textureInfo.texCoord`
  metadata and `KHR_texture_transform` offset/scale/rotation metadata, selecting
  the requested primary or secondary UV set in flat CPU shading, smooth CPU
  rasterization, and compact browser WebGL export with per-texture transform
  uniforms. glTF `normalTexture.scale` now attenuates tangent-space normal-map
  X/Y perturbation in CPU shading, smooth CPU rasterization, and compact browser
  WebGL export. glTF `alphaMode: "MASK"` and `alphaCutoff` now load as material
  alpha-test state and compact browser WebGL fragment discard without forcing
  blended transparent sorting.
  `MeshStandardMaterial` now carries the missing
  standard map/intensity fields (`metalness_map`, `alpha_map`,
  `emissive_intensity`, `ao_map_intensity`, `light_map_intensity`, and
  `env_map_intensity`). Browser export now handles alpha, emissive, AO, light,
  roughness, metalness, normal maps, and a compact environment-map path that
  uploads exported `CubeTexture` faces as a WebGL cube map when fragment
  texture units allow it, retaining average face colors as a fallback. A
  prefiltered reflection mip chain remains open.
  Browser export now recognizes `MeshBasicMaterial` as an explicit unlit
  material mode that applies color, vertex color, texture, opacity, alpha map,
  tone mapping, output color space, and fog while bypassing scene lights.
  Browser export now also recognizes `MeshNormalMaterial` and emits unlit
  normal-to-RGB color from the mesh shader instead of treating it as a fallback
  solid color.
  Browser export now recognizes `MeshDepthMaterial` and emits compact
  view-space depth output using the material's near/far range, with basic,
  RGBA, RGB, and RG packing branches. Depth materials now also share color-map
  alpha, alpha-map discard, alpha-test state, and wireframe draw-mode handling
  with the compact browser material paths.
  Browser export now recognizes `MeshToonMaterial` and applies compact
  quantized diffuse light bands from `gradient_steps`, or samples serialized
  `gradient_map` textures using the three.js toon irradiance coordinate. Toon
  materials now also share normal-map perturbation, AO/light-map modulation,
  emissive-map modulation, and related scalar animation bindings with the
  compact lit material paths. Full three.js ShaderLib toon integration remains
  open.
  Browser export now recognizes `MeshMatcapMaterial` and applies the same
  procedural fallback used by the CPU shading path, or samples a serialized
  `matcap` texture with view-space normal-derived matcap UVs when one is
  present. Matcap materials now also share color-map modulation, normal-map
  perturbation, alpha-map discard, wireframe draw-mode handling, and
  `normalScale` animation binding with the compact browser material paths.
  Browser export now recognizes `MeshLambertMaterial` and `MeshPhongMaterial`
  as explicit compact material modes; Lambert suppresses specular terms, and
  Phong serializes `specular`, `shininess`, `glossiness`, and packed
  specular/glossiness textures into the browser shader. Exact three.js
  ShaderLib Lambert/Phong shader chunks remain open.
  Browser export now carries per-vertex color attributes and scalar plus mapped
  `MeshPhysicalMaterial` clearcoat,
  transmission, IOR, dispersion, sheen, iridescence, specular, and anisotropy controls into
  the compact shader as approximated lobes/terms. CPU flat and smooth shading also sample
  the represented physical extension maps for clearcoat, clearcoat roughness,
  transmission, thickness, sheen color/roughness, iridescence,
  iridescence thickness, specular intensity, specular color, and anisotropy
  strength. Clearcoat, clearcoat normal, transmission, sheen,
  iridescence, specular, and anisotropy physical-extension texture variants are serialized
  and bound by the compact browser runtime through packed physical map textures
  and a gated clearcoat-normal sampler when the WebGL context exposes enough
  fragment texture units; lower-capability contexts keep scalar physical terms
  instead of failing shader compilation.
  `KHR_materials_volume` scalar thickness, green-channel thickness textures, and
  attenuation distance/color now feed the CPU transmission approximation and
  compact browser shader. The compact browser shader also applies the
  `KHR_materials_dispersion` per-channel IOR spread formula to its transmission
  Fresnel term; exact chromatic refraction remains part of broader physical
  renderer parity.
  Remaining work is broader browser material parity for exact three.js BRDFs and
  shadow/filter controls before larger PBR work.
- glTF: accessor correctness is now covered for normalized, sparse, signed,
  and interleaved accessors. Cameras, punctual lights, basic skins, and morph
  target data are loaded. Basic unlit, emissive-strength, and scalar physical
  material extensions are covered, including texture references for the common
  physical extension set. `KHR_materials_volume` now parses thickness factor,
  thickness texture metadata, attenuation distance, and attenuation color.
  Static morph target influences now export as morphed browser
  positions, while skinned meshes export as posed browser positions and can
  update browser vertex buffers from animated bone tracks. The next loader/runtime risks are deeper material
  shader/runtime parity and
  broader animation/runtime binding.
- Controls/examples: an examples parity registry now tracks upstream example
  ids, local scripts, prerequisites, status, deviations, and verification
  commands for current ports. Tests validate the registry and local script
  presence; exact upstream ports are still tracked individually before claiming
  example parity.
- Architecture: exact `WebGLRenderer`/`WebGPURenderer` parity requires a
  renderer-state/material-program abstraction. It should not be claimed from
  incremental `web_export.jl` patches alone.

### Milestone 1: Browser renderer parity baseline

- Done: export and shade spot and hemisphere lights.
- Done: add multi-light arrays for directional, point, spot, and hemisphere
  lights instead of one directional and one point light. Ambient lights are
  accumulated into a single ambient term.
- Done: generate compact WebGL light-array shader caps from exported cases
  instead of truncating directional, point, spot, and hemisphere lights to four
  of each type.
- Done: export rectangular area lights with position, facing basis, and
  width/height data, then shade browser meshes with finite 3x3 rectangular
  quadrature. Full three.js LTC area-light BRDF parity remains renderer work.
- Done: add transparent-object depth sorting in the browser runtime.
- Done: export material side flags plus material `depth_test`/`depth_write`
  fields and honor those depth states per object in the browser runtime.
- Done: add bounded browser clipping-plane export/runtime support for meshes,
  lines, and points via case-level `Plane`s.
- Done: add scene-level `Fog` and `FogExp2` data models plus browser
  export/runtime support for meshes, lines, and points.
- Done: export static morph-target influences to browser geometry positions.
- Done: export static skinned-mesh poses to browser geometry positions.
- Done: add animated browser-side morph-target weight data paths after the
  static object-model paths stayed covered by tests.
- Done: add animated browser-side skinning data paths for exported
  `SkinnedMesh` objects by serializing bone IDs, bind inverses, skin indices,
  and weights. The compact runtime now uses shader-side uniform bone matrices
  for skeletons up to 64 bones, float RGBA bone textures for larger non-morphed
  skeletons when the browser exposes vertex float texture support, and CPU
  vertex-buffer skinning as a fallback for morphed or unsupported skinned
  meshes. Vertex normals are skinned in all paths, and authored tangents are
  serialized, skinned, and used by tangent-space browser normal mapping.
  Skeleton pose/update lifecycle and renderer-program integration remain
  renderer work.
- Done: preserve compact-browser bone parent IDs and recompute exported bone
  hierarchies after animation tracks are sampled, so animated parent bones feed
  child bone matrices before uniform, float bone-texture, or CPU fallback
  skinning updates run.
- Done: add mesh-level skinned bind metadata and attached/detached bind-mode
  semantics. CPU `apply_skinning`, glTF skin loading, browser uniform skinning,
  browser float bone-texture skinning, and browser CPU fallback now apply
  `bindMatrixInverse * boneMatrix * bindMatrix`, and glTF skins without
  `inverseBindMatrices` calculate inverse binds after the node hierarchy is
  fully parented. glTF `skin.skeleton` roots that are not otherwise scene
  reachable now have their root hierarchies linked before inverse-bind
  calculation and binding, without changing `skin.joints` bone order.
  Remaining skinning gaps are full three.js skeleton pose/update lifecycle.
- Done: route visible `SkinnedMesh` objects through CPU flat, smooth,
  transparent, wireframe, cached, tiled, and shadow-depth rendering by building
  deformed render proxies from the current skeleton pose. CPU render proxies
  skin positions and authored normals/tangents while preserving material,
  shadow, UV, color, and draw-group data.
- Done: add `SkeletonHelper(::SkinnedMesh)` parity by delegating to the mesh's
  owned `Skeleton`, while broader three.js skeleton pose/update lifecycle
  parity remains tracked separately.
- Done: evaluate morph normal/tangent deltas for meshes and skinned meshes,
  normalize the resulting direction buffers, and feed them into CPU skinned
  render proxies plus compact browser morph and CPU-skinning fallback paths.
- Done: add case-level browser tone mapping metadata and shader application for
  `:none`, `:linear`, `:reinhard`, and `:aces` with exposure. This closes the
  compact runtime's missing tone-map hook while full three.js
  `WebGLRenderer` color-management and output-transform parity remain open.
- Done: add case-level browser output color-space metadata and shader-side
  linear/sRGB output encoding. This makes generated examples closer to modern
  three.js defaults without claiming display/P3 or full renderer
  output-transform parity.
- Done: serialize explicit `PerspectiveCamera` and `OrthographicCamera`
  metadata for `WebGLExportCase` and use it in the compact browser runtime,
  including camera position, target, up vector, near/far planes, perspective
  FOV/aspect, camera zoom, and orthographic extents. The old radius/height
  orbit fallback remains available for cases without an explicit camera.
- Done: bind browser animation tracks whose target is the active
  `WebGLExportCase.camera`, including camera position, target, up vector,
  perspective FOV/aspect, near/far planes, camera zoom, and orthographic extents.
  Orbit/pan/zoom controls now apply as offsets over the sampled camera state
  instead of forcing the active camera back to its static export pose each
  frame.
- Done: render CPU `ArrayCamera` sub-cameras into their stored viewport
  rectangles, intersecting each viewport with the existing top-left-origin CPU
  scissor rectangle when scissor testing is enabled. Browser export now
  serializes `ArrayCamera` sub-cameras, maps exported viewport rectangles to
  WebGL viewport/scissor rectangles, and draws each sub-camera view with its
  own camera-dependent material state.
- Done: export drawable `visible` state and bind browser `NumberKeyframeTrack`
  playback for `visible`, while preserving initially invisible animated
  drawables in generated scene data.
- Done: preserve ancestor visibility chains for exported browser drawables so
  `visible` animation on parent/group objects propagates to rendered children
  without flattening away each child's own visibility state.
- Done: export light `visible` state and bind browser light visibility
  animation, including initially hidden lights targeted by
  `NumberKeyframeTrack`. Browser-exported lights now also carry ancestor
  visibility states, so parent/group `visible` animation gates light
  contribution the same way it gates drawable objects.
- Done: make browser export honor `LOD` level selection dynamically by
  serializing each level with group/distance/hysteresis metadata and selecting
  the active level from the current browser camera distance each frame.
- Done: add CPU `lod_update!` and browser LOD state so hysteresis matches the
  three.js threshold behavior instead of flickering at exact level boundaries.
- Done: export compact static directional-, point-, and spot-light shadow maps for
  browser mesh shading when `cast_shadow=true` is used. The exporter bakes a
  CPU depth map into generated HTML, uploads it as a WebGL texture, and applies
  a small PCF comparison to the matching directional, point, or spot light term.
  Point-light support uses the compact exporter shadow projection already used
  by the CPU path, not three.js cube shadow maps. Full three.js shadow parity
  remains open for dynamic shadow rendering, cube/cascaded shadows,
  shadow-camera helpers, and renderer-state integration.
- Done: extend compact browser static shadows from a single selected shadow
  light to a bounded two-slot runtime. Generated pages now select up to two
  visible static shadow maps per case, upload fixed WebGL1 shadow samplers, and
  apply each map to its matching directional, point, or spot light contribution.
- Done: add a compact browser dynamic-shadow pass for animated
  `DirectionalLight` shadow transforms. Generated WebGL pages now serialize
  animated shadow-casting directional lights as `directionalDynamic`, allocate a
  color-depth framebuffer, recompute directional light orthographic bounds from
  the visible shadow caster/receiver set, render cast-shadow triangle drawables
  into the map each frame, and feed the updated matrix/texture through the same
  two-slot shadow sampler used by static shadows.
- Done: make browser shadow export invalidate stale baked maps when
  shadow-casting or shadow-receiving drawables animate. Object/group transform,
  visibility, and morph-weight tracks now make static cast-shadow
  `DirectionalLight`s use the dynamic directional pass, while point-light
  shadow maps are serialized as `null` instead of stale baked textures until
  their dynamic cube-shadow path exists.
- Done: add compact browser dynamic spot-light shadow cameras. Generated WebGL
  pages now serialize transform-, target-, angle-, or caster-animated
  cast-shadow `SpotLight`s as `spotDynamic`, allocate the same color-depth
  dynamic shadow target used by directional shadows, compute a perspective
  light matrix from the live spot position/target/angle and scene shadow
  bounds, and feed the updated texture/matrix through the existing two-slot
  spot-light shadow sampler. Cascades and full three.js shadow-camera helper
  and renderer-state parity remain open.
- Done: make compact browser dynamic directional/spot shadow maps respect
  browser-side bone deformation for exported skinned meshes. Bone transform
  tracks on shadow-casting or shadow-receiving `SkinnedMesh` skeletons now mark
  static directional/spot shadow maps dynamic and point-light maps stale, the
  generated depth pass mirrors the main mesh skinning path for uniform and
  bone-texture skinning, and dynamic shadow camera bounds include the same
  deformed vertex positions before rendering casters. Cascaded shadow maps and
  full three.js shadow helper/renderer-state integration remain open.
- Done: add compact browser dynamic point-light cube-shadow rendering. Animated
  cast-shadow `PointLight` positions/distances and animated shadow
  caster/receiver scenes now serialize point lights as `pointDynamic`;
  generated WebGL pages allocate a
  4x2 six-face 2D atlas, render radial-depth point-light faces each frame using
  the same skinned/instanced caster path as other dynamic shadows, and sample
  the atlas through the existing two-slot shadow list for point-light
  contribution. This is a compact atlas implementation rather than three.js's
  full `WebGLCubeRenderTarget`/shadow-camera helper stack; cascades and full
  renderer-state integration remain open.
- Done: make alpha-tested and clipped shadow casters participate consistently in
  CPU, static WebGL, and dynamic WebGL shadow paths. CPU shadow-map rasterization
  now receives material/global clipping state, interpolates world position plus
  UV/UV2 coordinates, and applies the same opacity, albedo-alpha, alpha-map
  green-channel, and clipping-plane discards used by the color rasterizer for
  mesh, instanced, and skinned casters. Browser static shadow export passes case
  clipping planes into the baked map, and dynamic directional/spot/point depth
  shaders bind caster UVs, alpha textures, alpha tests, opacity, and
  object/case clipping planes before writing depth.
- Done: add three.js-style object shadow flags for mesh-like drawables:
  `cast_shadow=false` and `receive_shadow=false` now default off on `Mesh`,
  `InstancedMesh`, and `SkinnedMesh`. CPU shadow maps only rasterize
  shadow-casting mesh/skinned/instanced geometry, CPU shading only applies shadow
  visibility to receiving objects, and browser export serializes
  `castShadow`/`receiveShadow` so generated WebGL pages do not shadow every
  mesh implicitly. Browser shadow parity remains partial: static maps are still
  baked at export time, except for animated directional shadow-light transforms
  handled by the compact dynamic pass above.
- Done: add per-light shadow filter controls for `DirectionalLight`,
  `PointLight`, and `SpotLight`. Optional `shadow_bias` and
  `shadow_pcf_radius` settings now feed CPU shadow-map generation and compact
  browser static/dynamic shadow metadata; the generated shader uses the
  serialized PCF radius for bounded filtering. Full three.js shadow-camera
  helper, cascaded-shadow, and renderer-state parity remain open.
- Done: CPU `RectAreaLight` now uses finite rectangular quadrature with
  width/height, emitter facing, distance attenuation, and area scaling instead
  of treating the rectangle as a center-point directional light. Full three.js
  LTC rectangular-area BRDF parity remains renderer/shader work.
- Done: browser `RectAreaLight` runtime now matches the CPU finite-rectangle
  approximation by serializing position/forward/basis vectors and evaluating
  3x3 rectangular quadrature in the mesh fragment shader. The browser rect
  specular term is also masked by `N·L > 0` to match CPU direct-light behavior
  for samples behind the shaded surface.

### Milestone 2: Material and texture parity

- Done: add browser export for alpha maps where matching Julia material fields
  already exist.
- Done: add `PointsMaterial.alpha_map` and `PointsMaterial.alpha_test`, carry
  glTF masked point primitives through `PointsMaterial`, and apply point
  texture color, map alpha, alpha-map green-channel discard, and alpha-test
  behavior in CPU point rasterization plus compact browser point sprites.
- Done: add `PointsMaterial.size_attenuation`, including constant-size opt-out
  and reference-distance attenuation for CPU and compact browser point sprites.
- Done: add `SpriteMaterial.alpha_map` and `SpriteMaterial.alpha_test`, apply
  map alpha and alpha-map green-channel discard in CPU sprite rasterization,
  and bind sprite alpha textures/tests in the compact browser sprite shader.
- Done: add `MeshBasicMaterial.alpha_map` so basic unlit materials participate
  in the same CPU rasterization and compact browser alpha-map paths as other
  mapped materials.
- Done: add `MeshBasicMaterial.ao_map`, `light_map`, `ao_map_intensity`, and
  `light_map_intensity` parity so Basic materials keep their unlit shading while
  applying baked AO/light modulation in CPU flat/smooth rendering, compact
  browser export/runtime, and material animation bindings.
- Done: add `alpha_map` and `alpha_test` fields to `MeshLambertMaterial` and
  `MeshPhongMaterial`, with CPU flat/smooth raster discard and compact browser
  alpha-texture serialization covered by tests.
- Done: add `map`, `alpha_map`, and `alpha_test` fields to
  `MeshToonMaterial`, with legacy positional constructor compatibility plus CPU
  flat/smooth raster discard and compact browser texture/alpha serialization
  covered by tests.
- Done: add `MeshPhongMaterial.vertex_colors` so Phong participates in the
  same CPU flat/smooth vertex-color modulation and compact browser vertex-color
  export path as other color-aware mesh materials; the
  `webgl_geometry_colors` port now uses flat Phong with `shininess=0.0`.
- Done: add `emissive_map`/`emissive_intensity` field parity for
  `MeshLambertMaterial`, `MeshPhongMaterial`, and `MeshToonMaterial`, with CPU
  emissive-map modulation and compact browser serialization covered by tests.
- Done: add `MeshToonMaterial.normal_map`, `normal_scale`, `ao_map`,
  `light_map`, `ao_map_intensity`, and `light_map_intensity` parity through
  the shared CPU flat/smooth map paths, compact browser `normalTexture`,
  `aoTexture`, and `lightTexture` serialization, browser/runtime scalar
  animation bindings, and legacy positional constructor defaults.
- Done: serialize `LineBasicMaterial.linewidth` into browser export, restore it
  through renderable animation reset state, animate it with number tracks, and
  apply it with a WebGL `ALIASED_LINE_WIDTH_RANGE` clamp for line, line-loop, and
  line-strip draw modes. Platforms whose WebGL line-width range is `[1, 1]`
  still render one-pixel native lines, matching the browser limitation.
- Done: extend material-local `clipping_planes` across mesh material
  constructors for Basic, Lambert, Phong, Standard, Physical, Toon, Matcap,
  Normal, and Depth materials. CPU render tests cover local clipping on the
  expanded mesh-material set, smooth-path coverage includes Phong and Standard,
  and compact browser export serializes both Phong and Standard local planes.
- Done: add browser export for emissive, AO, light, roughness, metalness, and
  normal maps where matching Julia material fields already exist.
- Done: add `Texture.max_anisotropy` metadata and compact browser export support
  for `EXT_texture_filter_anisotropic`, including capped sampler-state setup for
  2D textures and cube maps. CPU `sample_texture_aniso` remains the dedicated
  software filtering path.
- Done: add compact browser `MeshBasicMaterial` support with an explicit unlit
  material-mode shader branch.
- Done: add compact browser `MeshNormalMaterial` support with a material-mode
  uniform and normal-to-RGB shader branch.
- Done: add compact browser `MeshDepthMaterial` support with near/far material
  serialization plus basic/RGBA/RGB/RG depth-packing shader branches.
- Done: make compact browser `MeshDepthMaterial` switch depth conversion for
  orthographic exported cameras instead of always using perspective view-Z
  math.
- Done: add `MeshDepthMaterial.map`, `alpha_map`, `alpha_test`, and
  `wireframe` field parity through CPU flat raster alpha discard, compact
  browser depth map/alpha serialization, depth-branch fragment discard, generic
  wireframe rendering, and legacy positional constructor defaults.
- Done: add compact browser `MeshToonMaterial` support with `gradient_steps`
  serialization, quantized diffuse light bands, and optional `gradient_map`
  sampling.
- Done: add compact browser `MeshMatcapMaterial` support with procedural
  fallback and view-space texture-backed matcap sampling.
- Done: add `MeshMatcapMaterial.map`, `alpha_map`, `alpha_test`,
  `normal_map`, `normal_scale`, and `wireframe` field parity through CPU
  flat/smooth map paths, compact browser matcap map/alpha/normal serialization,
  browser/runtime `normalScale` animation binding, generic wireframe rendering,
  and legacy positional constructor defaults.
- Done: add `KHR_materials_volume` fields to `MeshPhysicalMaterial`, glTF
  parsing, CPU transmission attenuation, green-channel thickness texture
  modulation, and compact browser attenuation.
- Done: add compact browser `MeshLambertMaterial` and `MeshPhongMaterial`
  support with material-mode branches plus Phong `specular`, `shininess`,
  `glossiness`, and packed specular/glossiness texture serialization.
- Done: add `MeshPhongMaterial.wireframe` parity through the same CPU and
  compact browser wireframe paths as Basic/Lambert materials, while preserving
  legacy constructor defaults.
- Done: add `MeshPhongMaterial.normal_map`/`normal_scale` parity, reusing the
  shared tangent-space CPU flat/smooth normal-map path, compact browser
  `normalTexture`/`normalScale` serialization, and material `normalScale`
  animation binding while preserving legacy constructor defaults.
- Done: add `MeshPhongMaterial.ao_map`, `ao_map_intensity`, and
  `light_map_intensity` parity so Phong AO/light maps serialize to the compact
  browser runtime, affect CPU flat/smooth shading with authored strengths, and
  bind through material animation tracks while preserving legacy constructor
  defaults.
- Done: add `MeshLambertMaterial.normal_map`/`normal_scale` parity through the
  same CPU flat/smooth normal-map path, compact browser `normalTexture`/
  `normalScale` serialization, vertex-color-preserving material rewrites, and
  material `normalScale` animation binding while preserving legacy constructor
  defaults.
- Done: add `MeshLambertMaterial.ao_map_intensity` and
  `light_map_intensity` parity so Lambert AO/light maps use authored scalar
  strengths in CPU flat/smooth shading, compact browser export/runtime, and
  material animation binding while preserving legacy constructor defaults.
- Done: add browser export for environment maps where matching Julia material
  fields already exist. The compact browser runtime serializes the six
  `CubeTexture` faces, samples them through a WebGL `samplerCube` when
  available, and falls back to average face colors; full three.js PMREM and
  prefiltered environment BRDF parity remain open.
- Done: add CPU `sample_cube_lod` and make CPU environment-map reflection use
  authored cube-face mipmaps as a roughness-driven LOD when they are present.
  This makes mipped/pre-authored cubemaps affect rough CPU materials without
  claiming PMREM convolution or browser roughness-aware cube filtering.
- Done: serialize authored cube-face mipmaps to the compact browser exporter and
  use `EXT_shader_texture_lod` to select cube-map LOD from material roughness
  when the browser exposes that WebGL extension. Power-of-two cube faces also
  get generated mipmaps for this path. The fallback remains the existing base
  `textureCube`/face-average behavior, and this still does not claim PMREM or
  three.js environment BRDF LUT parity.
- Done: add `Texture.matrix` and `matrix_auto_update` semantics for CPU
  sampling and per-texture browser texture uniforms while retaining
  offset/repeat/rotation/center export for inspectability.
- Done: use `sample_texture_linear` for color textures in CPU flat and smooth
  shading while keeping normal/roughness/AO/light data maps raw.
- Done: bring smooth per-pixel shading to feature parity with flat face shading
  for albedo, normal, AO, emissive, roughness, and light maps.
- Done: route AO and light maps through secondary geometry UVs (`:uv2` /
  glTF `TEXCOORD_1`) in flat CPU shading, smooth CPU rasterization, and the
  compact browser WebGL exporter, with primary UV fallback.
- Done: preserve glTF `textureInfo.texCoord` metadata on loaded textures and
  choose the requested primary or secondary UV set for common material maps in
  flat CPU shading, smooth CPU rasterization, and compact browser WebGL export.
- Done: preserve glTF sampler `minFilter`/`magFilter` metadata on loaded
  textures, generate CPU mipmaps when glTF minification filters request them,
  honor magnification filtering plus nearest/linear minified texel filtering
  and nearest/linear mip-level selection in CPU automatic mipmap sampling, and
  serialize those sampler choices into the compact browser texture setup with
  WebGL mipmap generation for power-of-two textures.
- Done: parse glTF `KHR_texture_transform` offset, scale, rotation, and
  extension-level `texCoord` overrides into `Texture` transform metadata so
  loaded material maps share the same CPU sampling and per-sampler compact
  browser export transform path as native Diff3D.jl textures.
- Done: parse glTF `normalTexture.scale` into material normal-map strength and
  apply it in flat CPU shading, smooth CPU rasterization, and compact browser
  WebGL normal-map shading.
- Done: parse glTF `alphaMode: "MASK"` / `alphaCutoff` into material
  `alpha_test` state and apply it in compact browser WebGL mesh shading while
  keeping masked materials in the opaque render pass.
- Done: apply exported texture transform matrices to compact browser point and
  sprite texture sampling, instead of only mesh texture samplers.
- Done: serialize `Texture.colorspace` into browser texture records and decode
  sRGB color samplers to linear in compact mesh, point, and sprite shaders for
  albedo, emissive, matcap, sheen-color, and specular-color texture paths while
  leaving alpha, normal, roughness, metalness, AO, light, packed scalar, shadow,
  and bone textures raw.
  Broader texture parity still remains open for less-common extension-specific
  sampling semantics and exact three.js renderer integration.
- Done: add CPU smooth-path vertex-color interpolation for RGB/RGBA geometry
  `:color` attributes when materials opt in with `vertex_colors=true`; clipping
  and rasterization now preserve the interpolated color factor per pixel.
  Browser mesh export now follows the same material opt-in and copies RGB from
  RGB or RGBA color attributes, while line and point colors remain per-vertex.
- Done: add standard material fields for `metalness_map`, `alpha_map`,
  `emissive_intensity`, `ao_map_intensity`, `light_map_intensity`, and
  `env_map_intensity`; CPU flat and smooth shading now apply metalness maps and
  map intensities where the CPU renderer has corresponding paths.
- Done: extend CPU and browser tests so material-map behavior is checked against
  deterministic image or pixel-signal expectations.
- Done: export scalar `MeshPhysicalMaterial` physical-extension controls to the
  browser runtime and apply compact approximations for clearcoat, transmission,
  sheen, iridescence, specular tint/intensity, and anisotropy.
- Done: export and bind browser runtime texture maps for the common
  `MeshPhysicalMaterial` physical-extension set: clearcoat,
  clearcoat-roughness, transmission, sheen-color, sheen-roughness,
  iridescence, iridescence-thickness, specular-intensity, specular-color, and
  anisotropy strength when the packed alpha slot is not already occupied by
  thickness.
  Packed scalar maps now keep per-channel texture-coordinate and transform
  uniforms, so maps sharing a packed browser sampler no longer inherit the first
  packed texture's UV set or matrix.
  The compact browser runtime packs these into four extra physical map samplers
  and falls back to scalar physical terms on contexts with fewer than 12
  fragment texture units. Full tangent-space anisotropic GGX and three.js BRDF
  parity remain renderer work.
- Done: export geometry `:color` attributes to browser vertex buffers and
  multiply them into mesh, line, and point shaders. This closes a visible gap for
  helper objects and `webgl_lines_colors`-style examples.

### Milestone 3: glTF loader parity

- Done: implement normalized, signed, sparse, and interleaved accessors before
  adding new loader surface area.
- Done: honor glTF primitive `mode` for points, line segments, line loops, line
  strips, triangles, triangle strips, and triangle fans. Indexed point/line
  primitives expand into CPU renderer order, and strip/fan modes triangulate
  into ordinary indexed meshes.
- Done: preserve glTF `baseColorTexture` maps when converting point primitives
  to native `PointsObject`/`PointsMaterial` objects.
- Done: load core geometry attributes: `TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`,
  `TANGENT`, `JOINTS_0`, and `WEIGHTS_0`; mesh primitives with `COLOR_0` now
  enable material vertex-color modulation on compatible native materials.
- Done: add glTF material texture loading and common PBR texture binding
  (`baseColorTexture`, `metallicRoughnessTexture` as roughness and metalness
  maps, `normalTexture`, `occlusionTexture`, and `emissiveTexture`).
- Done: support glTF `KHR_materials_pbrSpecularGlossiness` as a required
  extension by mapping diffuse/specular/glossiness factors to
  `MeshPhongMaterial`, loading `diffuseTexture` and packed
  `specularGlossinessTexture` as shared `specular_map`/`glossiness_map`,
  applying RGB specular and alpha glossiness in CPU flat/smooth shading,
  preserving vertex-color modulation, and exporting packed glossiness to the
  compact browser Phong shader. Exact glTF spec-gloss BRDF parity remains part
  of broader material-renderer parity.
- Done: preserve `KHR_materials_clearcoat.clearcoatNormalTexture` with its
  normal scale and preserve the ratified `KHR_materials_dispersion.dispersion`
  scalar on `MeshPhysicalMaterial`. Browser export now serializes clearcoat
  normal textures/scales and dispersion, animates the scalar render properties,
  and uses them in the compact clearcoat lobe and transmission Fresnel
  approximations. Exact clearcoat-layer BRDF parity and full chromatic
  refraction remain part of the broader physical-renderer parity work.
- Done: route glTF image data by declared MIME type, data URI MIME, or URI
  extension, including `image/png` bufferView images, palette/`tRNS` PNGs,
  Adam7 interlaced grayscale/grayscale+alpha/RGB/RGBA PNG payloads, and
  `image/jpeg`/`.jpg`/`.jpeg` URI, data URI, and bufferView
  payloads through JpegTurbo. Unsupported `.ktx2` and extension-only
  `KHR_texture_basisu` references still fail with an explicit
  compressed-texture loader error.
- Done: resolve local external glTF buffer and image URI paths with
  percent-decoding, query/fragment stripping, `file:` URI support, and clear
  errors for unsupported external schemes.
- Done: validate glTF data URI resources with strict base64 decoding for both
  embedded buffers and images, while keeping the exported general-purpose
  `base64_decode` helper backward-compatible.
- Done: add Radiance RGBE/HDR texture loading via `load_rgbe`, `load_hdr`, and
  `RGBELoader`, covering flat and standard per-channel RLE scanlines,
  orientation signs, RGBE-to-linear floating-point conversion, and clear errors
  for malformed headers/truncated payloads. EXR, KTX2/Basis, PMREM generation,
  and broader environment-map loader parity remain open.
- Done: expose native JPEG/JPG texture loading via `load_jpeg`, add
  byte-signature `load_image` dispatch for PNG and JPEG, and route
  `TextureLoader` through the shared PNG/JPEG path while preserving RGBE/HDR as
  the explicit `RGBELoader` path. EXR, KTX2/Basis, advanced SVG paths/styles,
  advanced text geometry, audio, and broader loader ecosystem parity remain
  open.
- Done: add a native WAV-backed audio loader surface via `AudioBufferData`,
  `load_wav`, `load_audio`, and `AudioLoader`, covering RIFF/WAVE PCM and
  IEEE-float samples with chunk skipping, alignment validation, normalized
  frame/channel storage, and duration reporting. Browser `AudioLoader`
  compressed-format decode and WebAudio graph integration remain open.
- Done: add a typeface JSON font loader via `FontData`, `FontGlyph`,
  `FontCommand`, `load_font`, and `FontLoader`, plus `font_glyph_shapes` and
  `font_text_shapes` outline flattening for `m`/`l`/`q`/`b` commands into
  `Vec2` loops consumable by text geometry builders. `TextGeometry` now builds
  flat or depth-extruded geometry from glyph contour groups with simple holes.
  Typeface JSON
  `kernings`/`kerning` maps now load into `FontData`, are exposed through
  `font_kerning`, and offset subsequent glyph loops in `font_text_shapes` and
  `TextGeometry`. `TextGeometry` now also supports bevel-enabled glyph contour
  groups, including simple holes, with configurable bevel size, thickness, and
  segment count. Browser font rendering remains open.
- Done: add a native basic SVG loader surface via `SVGDocument`, `SVGPath`,
  `load_svg`, `SVGLoader`, `svg_shapes`, and `svg_geometry`, covering standalone
  `path`, `rect` including `rx`/`ry` rounded corners, `line`, `circle`,
  `ellipse`, `polygon`, and `polyline` elements, plus
  `M`/`L`/`H`/`V`/`Q`/`T`/`C`/`S`/`A`/`Z` path commands with relative variants
  and curve/elliptical-arc subdivision into `Vec2` loops/merged geometry.
  Element transforms and simple nested group transform stacks now apply
  `matrix`, `translate`, `scale`, `rotate`, `skewX`, and `skewY` transform
  lists. Basic inherited fill/stroke presentation attributes and inline
  `style` declarations now attach to `SVGPath`, with `svg_meshes` and
  `svg_strokes` helpers creating styled fill meshes and stroke line objects;
  simple `<style>` stylesheet rules for tag, class, id, and combined
  tag/class/id selectors plus whitespace descendant selectors now feed the same
  cascade, including basic `[attr]` and `[attr=value]` attribute selectors.
  Non-rendering `<defs>` containers and cascaded `display:none` /
  `visibility:hidden` or `collapse` now suppress parsed paths.
  Local `<use href="#id">` / `xlink:href` references can instantiate previously
  parsed path, primitive, and grouped definitions with `x`/`y`, transforms, and
  use-local style overrides.
  Attribute selector operators `~=`, `|=`, `^=`, `$=`, and `*=` are also
  supported, as are direct child (`A > B`), adjacent sibling (`A + B`), and
  general sibling (`A ~ B`) combinators. Forward-evaluable structural pseudo
  classes `:root`, `:first-child`, `:nth-child()`, `:first-of-type`, and
  `:nth-of-type()` plus static functional pseudo classes `:is()`, `:where()`,
  and `:not()` are supported for parsed SVG elements. Browser-state pseudo
  classes such as `:hover`, `:active`, `:focus`, `:visited`, and `:target` are
  parsed as static non-matches so they do not invalidate selector lists or
  `:not()` logic during offline SVG loading; DOM/runtime stateful selector
  evaluation remains open. Basic stroked outline triangle meshes are available
  through `svg_stroke_meshes` using parsed stroke styles and butt-cap
  per-segment quads. `stroke-dasharray` and `stroke-dashoffset` now cascade
  from attributes, inline styles, and parsed stylesheets, then split
  `svg_stroke_meshes` and `svg_strokes` output into visible dash subpaths.
  `stroke-linecap` now parses `butt`, `square`, and `round`, with square and
  round caps expanded by `svg_stroke_meshes` for open solid or dashed stroke
  subpaths. `stroke-linejoin` now parses `miter`, `bevel`, and `round`, honors
  `stroke-miterlimit`, and expands exterior joins in `svg_stroke_meshes`.
  `fill-rule` now cascades from attributes, inline styles, and parsed
  stylesheets; filled meshes and merged SVG geometry group same-element
  compound paths with `nonzero` or `evenodd` hole semantics while preserving
  separate element fills. Bounded local `clip-path:url(#id)` references now
  apply non-rendering `<clipPath>` definitions with one or more user-space
  convex closed clip loops, element-local
  `clipPathUnits="objectBoundingBox"` mapping, deferred container-level
  `objectBoundingBox` clipping against the collected subtree bounds,
  stylesheet/attribute cascade, empty clip paths, container user-space clip
  stacks, bounded CSS `inset(...)`, `rect(...)`, `xywh(...)`, `circle(...)`,
  `ellipse(...)`, simple `polygon(...)`, and simple `path(...)` basic-shape
  clip paths with px/percent coordinates, `rect()` auto edges, non-negative
  `xywh()` sizes, one-/two-value positions, closest/farthest-side radii,
  optional `path()` fill-rule prefixes, fill-rule holes for CSS `path()` and
  same-element URL clip loops, implicit `path()` close for clipping, rounded
  rectangular basic-shape corners via border-radius shorthand, and rounded
  convex `polygon()` vertices via length radii, basic-shape `fill-box`,
  parsed-stroke `stroke-box`, and root `view-box` references, plus centerline
  clipping for open line/polyline paths, triangulated simple non-convex URL
  clip loops, and non-duplicating overlapping URL clip-loop unions for closed
  fills and open path centerlines. CSS layout shape boxes (`content-box`,
  `padding-box`,
  `border-box`, `margin-box`) are accepted as geometry fill-bounds fallbacks for
  parsed SVG elements. Bounded SVG `mask:url(#id)` references now apply positive
  filled vector mask shapes, stylesheet/attribute cascade, empty/black masks,
  and `maskContentUnits="objectBoundingBox"` mapping for element-local and
  deferred container masks, with `mask-type="alpha"`/`mask-type: alpha`
  selecting alpha coverage instead of luminance coverage. Filled vector mask
  sources now multiply clipped path opacity by their computed luminance or alpha
  intensity for simple vector masks. Full SVG clipping/masking semantics
  (complex multi-shape clip unions beyond simple vector loop unions, complete
  CSS basic-shape grammar for browser CSS layout boxes, self-intersecting clip
  paths, overlapping multi-shape mask intensity compositing, raster/gradient
  masks) and DOM-level SVG parsing remain open.
- Done: add `equirectangular_to_cubemap` so loaded HDR/RGBE equirectangular
  textures can feed existing `CubeTexture` environment-map shading and browser
  export paths, with optional generated mip chains for roughness-aware sampling.
  This closes the generated HDR-to-cubemap path without claiming PMREM
  convolution or UltraHDR asset parity.
- Done: parse basic glTF material extensions/properties:
  `KHR_materials_unlit`, `KHR_materials_emissive_strength`, and
  `occlusionTexture.strength`.
- Done: parse glTF `KHR_materials_pbrSpecularGlossiness` into
  `MeshPhongMaterial` diffuse/specular/glossiness state and compact
  specular-glossiness texture sampling.
- Done: parse scalar physical glTF material extensions into existing
  `MeshPhysicalMaterial` fields: `KHR_materials_clearcoat`,
  `KHR_materials_transmission`, `KHR_materials_ior`, `KHR_materials_sheen`,
  `KHR_materials_iridescence`, `KHR_materials_specular`, and
  `KHR_materials_anisotropy`.
- Done: add `MeshPhysicalMaterial` texture slots for inherited PBR maps and
  common physical glTF extension texture variants, and bind glTF texture
  references for clearcoat, transmission, sheen, iridescence, specular, and
  anisotropy.
  Browser export now serializes and samples those common physical texture maps
  in its compact shader approximation, and CPU flat/smooth shading samples the
  same represented maps in its compact physical-material approximation. Full
  shader-model parity remains renderer work.
- Done: parse `EXT_mesh_gpu_instancing` on glTF mesh nodes and map
  non-skinned, non-morphed point, line, and triangle primitives to native
  `InstancedMesh` objects with explicit draw modes. `TRANSLATION`, `ROTATION`,
  and `SCALE` instance accessors compose node-local instance matrices,
  required-extension validation accepts the extension, CPU point/line renderers
  draw instanced non-triangle modes, and unsupported skinned or morphed
  instancing paths fail clearly until represented.
- Done: implement `CUBICSPLINE` transform interpolation for glTF assets and
  browser-exported animation tracks.
- Done: parse and instantiate glTF cameras and `KHR_lights_punctual`
  directional/point/spot lights.
- Done: bind glTF skins to `Bone`/`Skeleton`/`SkinnedMesh` for CPU skinning.
- Done: parse glTF morph target `POSITION`/`NORMAL`/`TANGENT` data, preserve
  `mesh.extras.targetNames`, and evaluate position, normal, and tangent morphs
  on CPU from mesh influences. Static point and line primitive morph weights
  are still baked into loaded geometry when no weight animation targets the
  node, preserving existing static behavior. Animated point and line primitive
  morph weights now remain live on `PointsObject`, `LineObject`, `LineLoop`,
  and `LineSegments`, update through CPU morph-weight tracks, affect CPU
  point/line raycasting and rendering, and serialize to compact browser morph
  buffers.
- Done: reject unsupported `extensionsRequired` entries before reading external
  buffers, while allowing required extensions covered by the current loader.
- Done: parse glTF `weights` animation channels into CPU morph-weight tracks for
  linear, step, and `CUBICSPLINE` interpolation.
- Done: export morph-weight tracks to browser vertex-buffer morph playback.
- Done: add CPU/browser scalar `NumberKeyframeTrack` support for component
  property paths (`position.x`, `.scale[y]`, `quaternion.y`, and
  `morphTargetInfluences[0]`) so simple three.js-style animation binding no
  longer requires full-vector keyframes.
- Done: parse three.js-style `material.*` number track names such as
  `material.opacity`, `material.color.r`, `material.emissiveIntensity`,
  `material.envMapIntensity`, `material.clearcoatRoughness`, and
  `material.sheenColor.r` to the same CPU/browser bindings as direct
  material-field paths.
- Done: extend animation binding for object material fields. CPU animation
  playback now updates immutable material structs by replacing the target
  object's material, and browser export resets/applies render-property tracks
  for material color components, opacity, alpha test, depth test/write, normal
  scale, toon step count, depth near/far, roughness, metalness, emissive, point
  size, Phong shininess/specular color, and compact physical-material
  scalar/color fields, including volume attenuation distance/color, dispersion,
  and physical anisotropy strength and rotation. Sprite material rotation plus
  sprite/point size attenuation now bind through the same CPU/browser animation
  path.
- Done: bind nested material texture transform animation paths such as
  `material.map.offset.x`, `material.map.repeat.y`, `material.map.rotation`,
  `material.map.center.x`, and `material.map.matrixAutoUpdate`. CPU playback mutates the material
  `Texture` object and refreshes its UV matrix when auto-update is enabled;
  browser playback resets serialized texture transform state each frame,
  applies flattened texture tracks, and recomputes sampler matrices before
  rendering.
- Done: export light IDs and bind browser animation tracks to light color,
  ground color, intensity, distance, and decay fields. CPU light color/intensity
  `NumberKeyframeTrack` playback is also covered, so animated lighting changes
  can affect generated WebGL pages instead of remaining static serialized data.
- Done: keep CPU whole-value vector light color tracks type-correct by writing
  `Color3` fields back as `Color3`, including hemisphere `ground_color`, while
  matching browser whole-value light `color`/`groundColor` vector export.
- Done: bind generated-browser light transform and shape animation for the
  compact light fields used by shading: point/spot positions, directional and
  spot targets/directions, spot cone angle/penumbra, and rectangular-area-light
  target/basis/width/height. Transform-animated shadow-casting lights no longer
  export stale baked shadow maps; full dynamic browser shadow-map rendering is
  still tracked as renderer work.
- Done: align CPU `AnimationMixer` and browser-exported animation playback for
  bounded loop timing: repeat, once, ping-pong, finite repetitions,
  clamp-when-finished, and clip time-scale metadata now resolve to the same
  sampled track time.
- Done: bind direct `.quaternion` animation tracks to object rotation in CPU
  playback and generated WebGL runtime playback, matching the existing
  quaternion data path used by rotation tracks.
- Done: normalize generated-browser quaternion animation after scalar component
  tracks such as `quaternion.y` update one component, matching CPU
  `NumberKeyframeTrack` quaternion-component playback.
- Done: fix generated WebGL transform-animation semantics so object and bone
  position/scale/quaternion tracks reset to serialized local base transforms
  and rebuild world matrices from `parentMatrix * localTRS`, matching three.js
  absolute local track behavior for exported scenes.
- Done: bind Euler `rotation` vector and component tracks in CPU playback and
  generated WebGL, converting Euler values to quaternions in the runtime.
- Done: serialize non-renderable transform nodes so animated `Group`/`Object3D`
  parents update child drawable matrices in browser export.
- Done: preserve `InstancedMesh` per-instance local matrices while object or
  parent transform animations rebuild browser world matrices.
- Done: export opaque browser `InstancedMesh` drawables as a single GPU
  instanced draw path using `ANGLE_instanced_arrays`, with a per-instance draw
  fallback when the extension is unavailable. Transparent instanced meshes keep
  the per-instance export path so object-level transparent sorting remains
  deterministic.
- Done: propagate generated WebGL transforms through drawable-to-drawable
  parent hierarchies, not only non-renderable transform nodes.
- Done: reclassify generated WebGL drawables into the transparent pass when
  opacity animation changes their effective opacity.
- Done: add CPU/browser scalar visibility binding for object-level
  `NumberKeyframeTrack` playback, including browser export of initially hidden
  animated drawables.
- Done: add browser visibility binding for parent/group `NumberKeyframeTrack`
  playback by exporting per-drawable ancestor visibility states.
- Done: add CPU/browser scalar visibility binding for light
  `NumberKeyframeTrack` playback, including initially hidden browser-exported
  lights.
- Done: add runtime tests for static skinning and morph export paths before
  expanding them to animated browser WebGL playback.

### Milestone 4: Controls and events

- Done: expand programmatic `OrbitControls` behavior with enabled/no-op gates,
  per-action rotate/zoom/pan gates, damping/inertia, pole-safe pan, zoom, and
  min/max distance, polar-angle, and azimuth-angle constraints.
  Browser exporter controls now support orbit, wheel zoom, middle-button drag
  dolly, and right-drag, shift-drag, ctrl-drag, or meta-drag target panning,
  plus two-pointer touch-style pinch zoom and target pan in the generated
  runtime. The exported canvas is keyboard-focusable and supports arrow-key
  target panning plus `+`/`-` zoom. Higher-level DOM integration details remain
  separate exporter/runtime work.
- Done: add focused programmatic equivalents for `TransformControls`,
  `PointerLockControls`, `TrackballControls`, and `DragControls` where feasible
  in a Julia workflow. Transform controls now support enabled/no-op state, axis
  masks, and translation/rotation/scale snap increments for programmatic
  translate/rotate/scale application. Trackball controls now support rotate,
  pan, zoom, save-state, reset, and enabled/no-op behavior; drag controls now
  support direct managed-object selection, recursive child selection,
  single-group transform selection, and NDC raycast picking through the existing
  CPU raycaster. Browser exported orbit controls now handle pointer-event touch
  and native `touch*` fallback orbit/pinch/pan gestures in generated WebGL
  output. Browser DOM/gizmo event semantics remain open.
- Done: add `examples/browser_webgl_smoke.py`, a reusable Playwright browser
  smoke that opens generated HTML, switches cases, simulates pointer drag and
  wheel zoom, exercises keyboard pan/zoom, verifies middle-button dolly and
  ctrl-left target panning through runtime state, forces an underside orbit
  view, exercises synthetic two-pointer pinch input plus native `touch*`
  fallback gestures, checks that every exported object remains drawn, and checks
  that the WebGL canvas stays drawable.

### Milestone 5: Official examples parity

- Done: add `examples/examples_registry.toml` with upstream example id, local
  script path, prerequisites, status, known deviations, and verification
  coverage, plus unit coverage that validates the registry and local scripts.
- Port examples only after their required engine features are implemented and
  tested.
- Keep generated example output ignored by git.
- For each port, add a Julia scene-generation script, a browser smoke
  verification command, and a note in this document naming unsupported deviations from the original
  three.js example.
- Continue porting official examples one by one beyond the current registry in
  `examples/examples_registry.toml`; keep that registry as the authoritative
  list of upstream IDs, generated scripts, smoke commands, and known deviations.
  `webgl_lines_colors`, and `webgl_helpers` now have either direct standalone
  pages or explicit multi-case showcase coverage tracked in the examples
  registry.
- Added partial `webgl_geometries` coverage through
  `examples/live_webgl_showcase.jl`, using the compact WebGL showcase cases for
  primitive geometry/material/orbit coverage. Exact upstream scene layout and
  `WebGLRenderer` internals remain documented deviations in the registry.
- Added a standalone partial port for `webgl_geometry_cube` via
  `examples/webgl_geometry_cube.jl`, using Diff3D.jl `BoxGeometry`, a generated
  texture map, and quaternion keyframe playback for the rotating cube. Exact
  upstream texture asset and `WebGLRenderer` internals remain documented
  deviations.
- Added a standalone partial port for `webgl_geometry_colors` via
  `examples/webgl_geometry_colors.jl`, using vertex-color `BufferGeometry`
  attributes, deterministic icosahedron color gradients, soft shadow planes,
  and wireframe overlays. Exact upstream mouse-following camera behavior,
  `MeshPhongMaterial` flat-shading/shininess behavior, `Stats`, and
  `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_geometry_colors_lookuptable` via
  `examples/webgl_geometry_colors_lookuptable.jl`, using deterministic
  pressure-surface data, a stored `:pressure` attribute, a Julia-side LUT baked
  into exported vertex colors, Lambert vertex-color shading, and a sprite-based
  legend texture. Upstream `pressure.json`, live `Lut` GUI palette switching,
  the second orthographic UI scene, `renderer.autoClear=false`, and
  `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_geometry_shapes` via
  `examples/webgl_geometry_shapes.jl`, using Diff3D.jl convex
  `ShapeGeometry`, `ExtrudeGeometry`, `LineLoop` outlines, textured shape caps,
  and browser mesh/line export. Upstream curved, holed, and complex
  `Shape` paths, exact `ShapeUtils` triangulation, `Stats`, and
  `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_camera` via
  `examples/webgl_camera.jl`, using Diff3D.jl `PerspectiveCamera`,
  `OrthographicCamera`, `CameraHelper`, point-cloud background data, and
  browser-exported camera metadata across perspective, orthographic, and
  `ArrayCamera` scissor-split cases. Upstream O/P keyboard switching, live
  projection mutation, `Stats`, and `WebGLRenderer` internals remain documented
  deviations.
- Added a standalone partial port for `webgl_lod` via
  `examples/webgl_lod.jl`, using Diff3D.jl `LOD`, `add_lod_level!`,
  `IcosahedronGeometry`, Lambert wireframe rendering, fog, and browser-side LOD
  selection. Upstream `FlyControls`, random 1000-object placement, and
  `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_clipping` via
  `examples/webgl_clipping.jl`, using Diff3D.jl case-level clipping planes,
  `MeshPhongMaterial` local clipping planes, `Plane`, `PlaneHelper`,
  `TorusKnotGeometry`, Phong lighting, and browser clipping shader coverage.
  Upstream GUI mutation, full `localClippingEnabled` renderer semantics,
  `clipShadows`, `alphaToCoverage`, `Stats`, and `WebGLRenderer` internals
  remain documented deviations.
- Added a standalone partial port for `webgl_morphtargets` via
  `examples/webgl_morphtargets.jl`, using Diff3D.jl `BufferGeometry` morph
  attributes, `Mesh.morph_target_influences`, `MorphWeightsKeyframeTrack`, and
  browser runtime morph-target updates. The local port still uses a procedural
  subdivided buffer geometry and omits upstream GUI sliders.
- Added a standalone partial port for `webgl_animation_keyframes` via
  `examples/webgl_animation_keyframes.jl`, using procedural Diff3D.jl geometry
  with vector, scale, and quaternion keyframe tracks. Exact upstream glTF asset
  loading/layout remains a documented deviation.
- Added a standalone partial port for `webgl_lines_colors` via
  `examples/webgl_lines_colors.jl`, driven by exported BufferGeometry `:color`
  attributes. Exact upstream path data remains a documented deviation.
- Added a standalone partial port for `webgl_helpers` via
  `examples/webgl_helpers.jl`, covering Diff3D.jl axes, grid, polar grid, box,
  camera, plane, and light helpers in the browser exporter. Exact upstream
  helper layout remains a documented deviation.
- Added a standalone partial port for `webgl_buffergeometry_uint` via
  `examples/webgl_buffergeometry_uint.jl`, explicitly exercising the browser
  `OES_element_index_uint` path with an index above 65k. Exact upstream stress
  geometry remains a documented deviation.
- Added standalone partial ports for `webgl_buffergeometry` and
  `webgl_buffergeometry_indexed` via `examples/webgl_buffergeometry.jl` and
  `examples/webgl_buffergeometry_indexed.jl`, covering non-indexed triangle
  buffers and indexed mesh buffers outside the multi-case showcase. Exact
  upstream randomized geometry remains a documented deviation.
- Added a standalone partial port for `webgl_buffergeometry_lines` via
  `examples/webgl_buffergeometry_lines.jl`, using raw `BufferGeometry`
  attributes and browser `LineSegments` export. Exact upstream randomized line
  field remains a documented deviation.
- Added a standalone partial port for `webgl_buffergeometry_lines_indexed` via
  `examples/webgl_buffergeometry_lines_indexed.jl`, using explicit
  `BufferGeometry` line indices, per-vertex color attributes, `LineSegments`,
  and keyframed parent rotation. Exact upstream random colors, viewport-scale
  coordinates, `Stats`, and `WebGLRenderer` internals remain documented
  deviations.
- Added a standalone partial port for `webgl_buffergeometry_points` via
  `examples/webgl_buffergeometry_points.jl`, using raw `BufferGeometry`
  attributes and browser point rendering. Exact upstream point data remains a
  documented deviation.
- Added a standalone partial port for `webgl_points_sprites` via
  `examples/webgl_points_sprites.jl`, using textured browser `PointsMaterial`
  point sprites plus billboard `Sprite` proxies with sampled material maps and
  sprite center/rotation/size-attenuation support. Compact browser billboarding
  and `WebGLRenderer` internals remain documented deviations in the registry.
- Added a standalone partial port for `webgl_points_billboards` via
  `examples/webgl_points_billboards.jl`, using deterministic
  `BufferGeometry` point data, a generated disc `Texture`, `PointsMaterial`
  map/alpha-test/size-attenuation fields, `FogExp2`, and keyframed group
  rotation. Upstream randomized data, sprite asset, pointer-following camera,
  and `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_instancing_dynamic` via
  `examples/webgl_instancing_dynamic.jl`, using Diff3D.jl `InstancedMesh`,
  generated instance matrices, shadows, fog, tone mapping, and quaternion/scale
  animation. The compact exporter now emits the opaque instance grid through a
  GPU instanced WebGL draw path; remaining deviations are the procedural scene
  and the compact exporter rather than three.js `WebGLRenderer`.
- Added a standalone partial port for `webgl_materials_normal` via
  `examples/webgl_materials_normal.jl`, using Diff3D.jl `MeshNormalMaterial`,
  primitive geometry generators, orbit interaction, and the browser
  normal-material shader branch. Exact three.js ShaderLib internals and the
  upstream object layout remain documented deviations.
- Added a standalone partial port for `webgl_materials_depth` via
  `examples/webgl_materials_depth.jl`, using Diff3D.jl `MeshDepthMaterial`,
  primitive geometry generators, orbit interaction, and browser depth-material
  branches for basic/RGBA/RGB/RG packing. The exact upstream object layout and
  full three.js ShaderLib integration remain documented deviations.
- Added a standalone partial port for `webgl_materials_variations_basic` via
  `examples/webgl_materials_variations_basic.jl`, using Diff3D.jl
  `MeshBasicMaterial`, primitive geometry generators, orbit interaction,
  texture maps, and the browser unlit material shader branch. Exact three.js
  ShaderLib basic-material internals and the upstream object layout remain
  documented deviations.
- Added a standalone partial port for `webgl_materials_variations_toon` via
  `examples/webgl_materials_variations_toon.jl`, using Diff3D.jl
  `MeshToonMaterial`, primitive geometry generators, orbit interaction, and the
  browser toon-material shader branch with optional serialized gradient maps.
  Full three.js ShaderLib toon internals and the upstream object layout remain
  documented deviations.
- Added a standalone partial port for `webgl_materials_matcap` via
  `examples/webgl_materials_matcap.jl`, using Diff3D.jl `MeshMatcapMaterial`,
  primitive geometry generators, orbit interaction, and the browser matcap
  shader branch with one generated texture-backed material. Exact upstream
  matcap texture assets and object layout remain documented deviations.
- Added standalone partial ports for `webgl_materials_variations_lambert` and
  `webgl_materials_variations_phong` via
  `examples/webgl_materials_variations_lambert.jl` and
  `examples/webgl_materials_variations_phong.jl`, using Diff3D.jl
  `MeshLambertMaterial` and `MeshPhongMaterial`, primitive geometry generators,
  orbit interaction, texture-map coverage, and the compact browser Lambert and
  Phong material branches. Exact three.js ShaderLib internals and upstream
  object layouts remain documented deviations.
- Added a standalone partial port for `webgl_materials_variations_standard` via
  `examples/webgl_materials_variations_standard.jl`, using Diff3D.jl
  `MeshStandardMaterial` roughness/metalness variants, a generated
  equirectangular environment converted to `CubeTexture`, and browser
  environment-map export. Exact three.js ShaderLib standard-material BRDF,
  PMREM environment lighting, upstream assets, and `WebGLRenderer` internals
  remain documented deviations.
- Added a standalone partial port for `webgl_materials_cubemap_mipmaps` via
  `examples/webgl_materials_cubemap_mipmaps.jl`, using generated and authored
  `CubeTexture` mip chains with rough `MeshStandardMaterial` environment
  reflections in the browser exporter. Exact upstream cube assets, PMREM, and
  full three.js cube-map filtering internals remain documented deviations.
- Added a standalone partial port for `webgl_materials_physical_clearcoat` via
  `examples/webgl_materials_physical_clearcoat.jl`, using Diff3D.jl
  `MeshPhysicalMaterial`, scalar clearcoat controls, generated clearcoat and
  clearcoat-roughness texture maps, shadows, fog, tone mapping, animation, and
  the compact browser physical-material shader branch. Exact three.js
  PhysicalMaterial BRDF, PMREM environment lighting, and upstream assets remain
  documented deviations.
- Added a standalone partial port for `webgl_materials_texture_rotation` via
  `examples/webgl_materials_texture_rotation.jl`, using generated UV-grid
  textures and Diff3D.jl `Texture.offset`, `Texture.repeat`,
  `Texture.rotation`, `Texture.center`, `Texture.matrix`, and
  `Texture.matrix_auto_update` semantics in browser export. Exact upstream GUI,
  texture assets, and `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_materials_texture_canvas` via
  `examples/webgl_materials_texture_canvas.jl`, using a generated
  `CanvasTexture` on a rotating `BoxGeometry` cube. Runtime texture
  `needsUpdate` flags now re-upload browser texture payloads on the next frame.
  Live DOM canvas drawing, pointer events, and `WebGLRenderer` internals remain
  documented deviations.
- Added compact browser `ArrayCamera` export and runtime scissor-split drawing,
  plus an `ArrayCamera` split-view case in `examples/webgl_camera.jl`.
- Tightened the official examples parity registry so every registered example
  has focused source/prerequisite assertions in `test/runtests.jl`, preventing
  future parity entries from being tracked only by script existence and smoke
  command strings.
- Added `examples/verify_examples_registry.py`, a registry-driven CRC runner
  that validates each non-planned entry's generation/smoke commands,
  regenerates its HTML, and runs browser smoke against every output.
- Added GitHub Actions CI for package tests, documentation build, and the full
  registered-example browser smoke sweep.
- Added a standalone partial port for `webgl_loader_stl` via
  `examples/webgl_loader_stl.jl`, round-tripping deterministic binary STL
  geometry through Diff3D.jl `save_stl_binary` and `load_stl` before exporting
  it with the compact browser mesh path. The exact upstream PR2 STL asset and
  `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_loader_obj` via
  `examples/webgl_loader_obj.jl`, generating temporary OBJ/MTL assets,
  loading them through Diff3D.jl `load_obj_groups`/`load_mtl`, and exporting
  material-split meshes to the compact browser path. The core OBJ/MTL loaders
  preserve `vt` UVs and bind `map_Kd` diffuse textures. Exact upstream OBJ/MTL
  assets and `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_loader_ply` via
  `examples/webgl_loader_ply.jl`, generating temporary ASCII and
  `binary_little_endian` PLY assets, loading both through Diff3D.jl `load_ply`,
  and exporting vertex-color meshes to the compact browser path. The core PLY
  loader also accepts `binary_big_endian` fixtures and skips unknown binary
  list-property elements without corrupting later elements. Exact upstream PLY
  assets and `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_loader_gltf` via
  `examples/webgl_loader_gltf.jl`, generating a deterministic external-buffer
  glTF asset plus a deterministic binary GLB companion with embedded BIN
  geometry and a PNG image `bufferView`, plus a generated Radiance HDR
  environment map converted to `CubeTexture`, `KHR_lights_punctual` light, and
  transform animation, then loading them through Diff3D.jl `load_gltf_asset`
  and `load_glb_asset` before browser export. Exact upstream sample-asset
  catalogue, DamagedHelmet asset, UltraHDR/PMREM environment path, and
  `WebGLRenderer` internals remain documented deviations.
- Added a standalone partial port for `webgl_loader_xyz` via
  `examples/webgl_loader_xyz.jl`, generating deterministic XYZRGB helix
  point-cloud data, loading it through Diff3D.jl `load_xyz`, and exporting
  colored `PointsObject` browser output with animation. Diff3D.jl validates
  finite coordinates, RGB byte ranges, malformed records, and mixed
  XYZ/XYZRGB layouts instead of silently ignoring or accepting those cases like
  the current three.js parser. The exact upstream `helix_201.xyz` asset,
  `Timer` loop, and WebGLRenderer internals remain documented deviations.

## Next implementation targets

- Expand browser export toward renderer parity: full LTC rect-area lights,
  exact physical-material BRDFs, dynamic shadow rendering including
  cascaded shadow maps, full three.js skeleton lifecycle/renderer integration,
  and broader per-object animation binding.
- Fill glTF gaps in a test-driven order: deeper material texture/runtime parity,
  richer animation/runtime binding, and full three.js skinning parity.
- Port official examples one at a time, using each port to drive missing core
  features rather than adding demo-only shortcuts.
