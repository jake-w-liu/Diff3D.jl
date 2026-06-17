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
  visibility, layer masks, world matrix computation, and reparenting.
- Cameras: perspective and orthographic camera projection/view basics.
- Geometry: buffer geometry plus common primitives including boxes, planes,
  spheres, cylinders, torus, torus knots, icosahedra, circles, rings, cones,
  capsules, lathes, and text-like/path helpers.
- Objects: `Mesh`, `InstancedMesh`, `PointsObject`, `LineObject`,
  `LineSegments`, `LineLoop`, `Sprite`, `LOD`, `Bone`, `Skeleton`, and
  `SkinnedMesh` data structures.
- Materials: basic, standard, normal, Lambert, Phong, line, points,
  sprite-material data models, common standard-material map/intensity fields,
  simple color/size export behavior, compact browser unlit output for
  `MeshBasicMaterial`, compact browser normal-color output for
  `MeshNormalMaterial`, and compact browser grayscale output for
  `MeshDepthMaterial`, plus compact browser quantized diffuse output for
  `MeshToonMaterial`, compact browser diffuse-only/specular-shininess output
  for `MeshLambertMaterial`/`MeshPhongMaterial`, and procedural or
  texture-backed compact output for `MeshMatcapMaterial`.
- Lights: ambient, directional, point, spot, hemisphere, rectangular area
  light data models used by CPU-side rendering paths.
- Raycaster: mesh, points, line strip, line segments, line loop, perspective
  camera rays, orthographic camera rays, and recursive scene traversal.
- Animation: vector, quaternion, and morph-weight keyframe tracks, linear,
  smooth/cubic, glTF-style cubic spline, discrete/step interpolation, clips,
  actions, and mixer update.
- Loaders: OBJ, STL, PLY, PNG texture loading, and partial glTF/GLB asset
  parsing including meshes, signed/normalized/sparse accessors, and
  core geometry attributes (`TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`, `TANGENT`,
  `JOINTS_0`, `WEIGHTS_0`), glTF material texture binding for common PBR maps
  with per-texture `textureInfo.texCoord` UV-set metadata and
  `KHR_texture_transform` offset/scale/rotation metadata for CPU and compact
  browser paths with per-sampler transform uniforms,
  `KHR_materials_unlit`, `KHR_materials_emissive_strength`, occlusion strength,
  scalar `KHR_materials_clearcoat`, `KHR_materials_transmission`,
  `KHR_materials_ior`, `KHR_materials_sheen`, and
  `KHR_materials_iridescence` fields and texture references plus
  `KHR_materials_specular` mapped into `MeshPhysicalMaterial`,
  and translation/rotation/scale animation tracks including `CUBICSPLINE`,
  linear/step/`CUBICSPLINE` morph-weight animation tracks, cameras, `KHR_lights_punctual`
  directional/point/spot lights, and basic skinned-mesh binding to Diff3D.jl
  `Bone`/`Skeleton`/`SkinnedMesh` objects, and CPU-side morph target position
  evaluation.
- Export/demo: standalone WebGL HTML export for meshes, instancing, points,
  lines, line loops, camera-facing textured sprite quads, material color, albedo, alpha, emissive,
  AO/light maps using exported secondary `uv2` coordinates when present,
  roughness, metalness, normal texture maps, and exported
  environment-map face-color sampling,
  per-vertex `:color` attributes for meshes, lines, and points,
  texture offset/repeat/rotation/center transforms, opacity/alpha blending,
  material side flags, transparent-object sorting, scene-level linear/exp2 fog,
  ambient, directional, point, spot, hemisphere scene lights,
  finite rectangular-area-light approximation, bounded case-level browser clipping planes,
  static mesh morph target influences, animated browser morph-weight playback,
  static skinned-mesh poses, CPU-side animated browser skinned-mesh vertex playback,
  textured browser sprite billboards,
  runtime drawable and light visibility toggles,
  dynamic camera-distance LOD selection for exported browser drawables,
  orbit/zoom interaction, case switching, and exported linear, step,
  Catmull-Rom cubic, and quaternion keyframe playback.

## Partial parity

- WebGL export covers useful demo scenes, but it is a compact custom runtime,
  not three.js `WebGLRenderer`. It supports simple albedo textures, texture
  transforms, alpha maps, material side flags, transparent sorting, and
  ambient/directional/point/spot/hemisphere lights, compact
  none/linear/Reinhard/ACES tone mapping with case-level exposure, and linear
  or sRGB browser output encoding. It still lacks shader chunks, render lists,
  render targets, full WebGL renderer tone-output/color-management parity,
  WebGL state parity, full dynamic shadow-map parity, full LTC rect-area lighting,
  full bone-texture shader skinning and skinned-tangent parity,
  true cube-map sampling/prefiltered environment lighting, and most material
  shader variants.
- glTF support parses common mesh and transform animation data and now decodes
  signed, normalized, sparse, and interleaved accessors. It also evaluates
  `CUBICSPLINE` transform animation with explicit glTF tangents, normalizing
  quaternion results after Hermite interpolation. It also instantiates glTF
  perspective/orthographic cameras and `KHR_lights_punctual`
  directional/point/spot lights. Basic skins are bound to `SkinnedMesh` with
  inverse bind matrices for CPU `apply_skinning`. Morph target position deltas
  are parsed and evaluable on CPU via `apply_morph_targets`, with normal/tangent
  target data preserved as geometry attributes. glTF morph-weight animation
  channels using linear/step interpolation bind to CPU `MorphWeightsKeyframeTrack`
  playback and can export to browser vertex-buffer morph playback. Scalar
  physical-material extensions now map to `MeshPhysicalMaterial` fields,
  including texture references for clearcoat, transmission, sheen,
  iridescence, specular, and inherited PBR maps; renderer shading of every
  physical extension remains partial. glTF `CUBICSPLINE` morph-weight tracks
  now bind to CPU playback and browser weight serialization. Static skinned poses and
  animated bone tracks export to browser shader-side uniform skinning for small
  skeletons with CPU-side vertex-buffer fallback for larger skeletons, and
  static morph target influences export to browser geometry positions. It does
  not yet cover the full glTF feature set such as remaining texture/material
  extensions and browser/runtime material extensions.
- Sprites render in the CPU path as camera-facing quads and export to the
  browser showcase as camera-facing textured quads. Browser sprite export now
  carries sampled material maps, `Sprite.center`, `SpriteMaterial.rotation`,
  `SpriteMaterial.sizeAttenuation`, and transparent sorting/depth metadata.
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
  when opacity animation crosses below full opacity.
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
  not shader-compatible with three.js materials.

## Known missing areas

- Full `WebGLRenderer`, `WebGPURenderer`, shader library, node material system,
  post-processing passes, render targets, shadow maps, fog parity, clipping,
  logarithmic depth, full tone-output/color-management parity, and texture
  sampling parity.
- Complete loader ecosystem and full-format parity for GLTFLoader, DRACOLoader,
  KTX2Loader, EXR/RGBE/HDR loaders, SVGLoader, FontLoader, AudioLoader, and
  other three.js examples infrastructure.
- Full controls/event parity such as remaining OrbitControls browser/touch
  details, TransformControls, DragControls, PointerLockControls,
  TrackballControls, keyboard/mouse/touch event interoperability, and DOM
  integration. CPU `OrbitControls` now includes constraint, damping, save-state,
  and reset behavior, and CPU `PointerLockControls` includes pointer speed plus
  polar-angle limits. CPU `TransformControls` now supports mode selection plus
  world/local translation space, but browser DOM/gizmo/event parity is still
  intentionally tracked as incomplete.
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
  contract. Highest-impact short-term gaps are multiple lights per type,
  transparent sorting, material-side flags, and more material maps.
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
  samples each exported `CubeTexture` face by average color instead of using a
  GPU cube sampler or prefiltered reflection mip chain.
  Browser export now recognizes `MeshBasicMaterial` as an explicit unlit
  material mode that applies color, vertex color, texture, opacity, alpha map,
  tone mapping, output color space, and fog while bypassing scene lights.
  Browser export now also recognizes `MeshNormalMaterial` and emits unlit
  normal-to-RGB color from the mesh shader instead of treating it as a fallback
  solid color.
  Browser export now recognizes `MeshDepthMaterial` and emits a compact
  camera-distance grayscale approximation using the material's near/far range;
  exact three.js depth packing variants remain open.
  Browser export now recognizes `MeshToonMaterial` and applies compact
  quantized diffuse light bands from `gradient_steps`; exact three.js
  gradient-map toon ShaderLib behavior remains open.
  Browser export now recognizes `MeshMatcapMaterial` and applies the same
  procedural fallback used by the CPU shading path, or samples a serialized
  `matcap` texture with view-space normal-derived matcap UVs when one is
  present.
  Browser export now recognizes `MeshLambertMaterial` and `MeshPhongMaterial`
  as explicit compact material modes; Lambert suppresses specular terms, and
  Phong serializes `specular` plus `shininess` into the browser shader. Exact
  three.js ShaderLib Lambert/Phong shader chunks remain open.
  Browser export now carries per-vertex color attributes and scalar plus mapped
  `MeshPhysicalMaterial` clearcoat,
  transmission, IOR, sheen, iridescence, and specular controls into the compact
  shader as approximated lobes/terms. CPU flat and smooth shading also sample
  the represented physical extension maps for clearcoat, clearcoat roughness,
  transmission, thickness, sheen color/roughness, iridescence,
  iridescence thickness, specular intensity, and specular color. Clearcoat, transmission, sheen,
  iridescence, and specular physical-extension texture variants are serialized
  and bound by the compact browser runtime through packed physical map textures
  when the WebGL context exposes enough fragment texture units; lower-capability
  contexts keep scalar physical terms instead of failing shader compilation.
  `KHR_materials_volume` scalar thickness, green-channel thickness textures, and
  attenuation distance/color now feed the CPU transmission approximation and
  compact browser shader.
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
  for skeletons up to 64 bones and retains CPU vertex-buffer skinning as a
  fallback for larger skeletons. Vertex normals are skinned in the compact
  shader path; full three.js bone-texture skinning, tangent skinning, and
  renderer-program integration remain renderer work.
- Done: add case-level browser tone mapping metadata and shader application for
  `:none`, `:linear`, `:reinhard`, and `:aces` with exposure. This closes the
  compact runtime's missing tone-map hook while full three.js
  `WebGLRenderer` color-management and output-transform parity remain open.
- Done: add case-level browser output color-space metadata and shader-side
  linear/sRGB output encoding. This makes generated examples closer to modern
  three.js defaults without claiming display/P3, texture color-space, or full
  renderer output-transform parity.
- Done: export drawable `visible` state and bind browser `NumberKeyframeTrack`
  playback for `visible`, while preserving initially invisible animated
  drawables in generated scene data.
- Done: preserve ancestor visibility chains for exported browser drawables so
  `visible` animation on parent/group objects propagates to rendered children
  without flattening away each child's own visibility state.
- Done: export light `visible` state and bind browser light visibility
  animation, including initially hidden lights targeted by
  `NumberKeyframeTrack`.
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
- Done: add three.js-style object shadow flags for mesh-like drawables:
  `cast_shadow=false` and `receive_shadow=false` now default off on `Mesh`,
  `InstancedMesh`, and `SkinnedMesh`. CPU shadow maps only rasterize
  shadow-casting mesh/instanced geometry, CPU shading only applies shadow
  visibility to receiving objects, and browser export serializes
  `castShadow`/`receiveShadow` so generated WebGL pages do not shadow every
  mesh implicitly. Static browser shadows still remain baked at export time,
  not re-rendered dynamically like `WebGLRenderer.shadowMap`.
- Done: CPU `RectAreaLight` now uses finite rectangular quadrature with
  width/height, emitter facing, distance attenuation, and area scaling instead
  of treating the rectangle as a center-point directional light. Full three.js
  LTC rectangular-area BRDF parity remains renderer/shader work.
- Done: browser `RectAreaLight` runtime now matches the CPU finite-rectangle
  approximation by serializing position/forward/basis vectors and evaluating
  3x3 rectangular quadrature in the mesh fragment shader.

### Milestone 2: Material and texture parity

- Done: add browser export for alpha maps where matching Julia material fields
  already exist.
- Done: add browser export for emissive, AO, light, roughness, metalness, and
  normal maps where matching Julia material fields already exist.
- Done: add compact browser `MeshBasicMaterial` support with an explicit unlit
  material-mode shader branch.
- Done: add compact browser `MeshNormalMaterial` support with a material-mode
  uniform and normal-to-RGB shader branch.
- Done: add compact browser `MeshDepthMaterial` support with near/far material
  serialization and a camera-distance grayscale shader branch.
- Done: add compact browser `MeshToonMaterial` support with `gradient_steps`
  serialization and quantized diffuse light bands.
- Done: add compact browser `MeshMatcapMaterial` support with procedural
  fallback and view-space texture-backed matcap sampling.
- Done: add `KHR_materials_volume` fields to `MeshPhysicalMaterial`, glTF
  parsing, CPU transmission attenuation, green-channel thickness texture
  modulation, and compact browser attenuation.
- Done: add compact browser `MeshLambertMaterial` and `MeshPhongMaterial`
  support with material-mode branches plus Phong `specular`/`shininess`
  serialization.
- Done: add browser export for environment maps where matching Julia material
  fields already exist. The compact browser runtime serializes the six
  `CubeTexture` faces as average colors and chooses a face by reflection
  direction; full three.js cubemap filtering/prefilter parity remains open.
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
  Broader texture parity still remains open for less-common extension-specific
  sampling semantics and exact three.js renderer integration.
- Done: add CPU smooth-path vertex-color interpolation for RGB/RGBA geometry
  `:color` attributes when materials opt in with `vertex_colors=true`; clipping
  and rasterization now preserve the interpolated color factor per pixel.
- Done: add standard material fields for `metalness_map`, `alpha_map`,
  `emissive_intensity`, `ao_map_intensity`, `light_map_intensity`, and
  `env_map_intensity`; CPU flat and smooth shading now apply metalness maps and
  map intensities where the CPU renderer has corresponding paths.
- Done: extend CPU and browser tests so material-map behavior is checked against
  deterministic image or pixel-signal expectations.
- Done: export scalar `MeshPhysicalMaterial` physical-extension controls to the
  browser runtime and apply compact approximations for clearcoat, transmission,
  sheen, iridescence, and specular tint/intensity.
- Done: export and bind browser runtime texture maps for the common
  `MeshPhysicalMaterial` physical-extension set: clearcoat,
  clearcoat-roughness, transmission, sheen-color, sheen-roughness,
  iridescence, iridescence-thickness, specular-intensity, and specular-color.
  The compact browser runtime packs these into four extra physical map samplers
  and falls back to scalar physical terms on contexts with fewer than 12
  fragment texture units. Full three.js BRDF parity remains renderer work.
- Done: export geometry `:color` attributes to browser vertex buffers and
  multiply them into mesh, line, and point shaders. This closes a visible gap for
  helper objects and `webgl_lines_colors`-style examples.

### Milestone 3: glTF loader parity

- Done: implement normalized, signed, sparse, and interleaved accessors before
  adding new loader surface area.
- Done: load core geometry attributes: `TEXCOORD_0`, `TEXCOORD_1`, `COLOR_0`,
  `TANGENT`, `JOINTS_0`, and `WEIGHTS_0`.
- Done: add glTF material texture loading and common PBR texture binding
  (`baseColorTexture`, `metallicRoughnessTexture` as roughness and metalness
  maps, `normalTexture`, `occlusionTexture`, and `emissiveTexture`).
- Done: parse basic glTF material extensions/properties:
  `KHR_materials_unlit`, `KHR_materials_emissive_strength`, and
  `occlusionTexture.strength`.
- Done: parse scalar physical glTF material extensions into existing
  `MeshPhysicalMaterial` fields: `KHR_materials_clearcoat`,
  `KHR_materials_transmission`, `KHR_materials_ior`, `KHR_materials_sheen`,
  `KHR_materials_iridescence`, and `KHR_materials_specular`.
- Done: add `MeshPhysicalMaterial` texture slots for inherited PBR maps and
  common physical glTF extension texture variants, and bind glTF texture
  references for clearcoat, transmission, sheen, iridescence, and specular.
  Browser export now serializes and samples those common physical texture maps
  in its compact shader approximation, and CPU flat/smooth shading samples the
  same represented maps in its compact physical-material approximation. Full
  shader-model parity remains renderer work.
- Done: implement `CUBICSPLINE` transform interpolation for glTF assets and
  browser-exported animation tracks.
- Done: parse and instantiate glTF cameras and `KHR_lights_punctual`
  directional/point/spot lights.
- Done: bind glTF skins to `Bone`/`Skeleton`/`SkinnedMesh` for CPU skinning.
- Done: parse glTF morph target `POSITION`/`NORMAL`/`TANGENT` data and evaluate
  position morphs on CPU from mesh influences.
- Done: parse glTF `weights` animation channels into CPU morph-weight tracks for
  linear, step, and `CUBICSPLINE` interpolation.
- Done: export morph-weight tracks to browser vertex-buffer morph playback.
- Done: add CPU/browser scalar `NumberKeyframeTrack` support for component
  property paths (`position.x`, `.scale[y]`, and
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
  for material color components, opacity, roughness, metalness, emissive,
  point size, Phong shininess/specular color, and compact physical-material
  scalar fields. Sprite material rotation and size attenuation now bind through
  the same CPU/browser animation path.
- Done: export light IDs and bind browser animation tracks to light color,
  ground color, intensity, distance, and decay fields. CPU light color/intensity
  `NumberKeyframeTrack` playback is also covered, so animated lighting changes
  can affect generated WebGL pages instead of remaining static serialized data.
- Done: align CPU `AnimationMixer` and browser-exported animation playback for
  bounded loop timing: repeat, once, ping-pong, finite repetitions,
  clamp-when-finished, and clip time-scale metadata now resolve to the same
  sampled track time.
- Done: bind direct `.quaternion` animation tracks to object rotation in CPU
  playback and generated WebGL runtime playback, matching the existing
  quaternion data path used by rotation tracks.
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

- Done: expand programmatic `OrbitControls` behavior with damping/inertia, pan,
  zoom, and min/max distance, polar-angle, and azimuth-angle constraints.
  Browser exporter controls now support orbit, wheel zoom, and right-drag or
  shift-drag target panning, plus two-pointer touch-style pinch zoom and target
  pan in the generated runtime. The exported canvas is keyboard-focusable and
  supports arrow-key target panning plus `+`/`-` zoom. Higher-level DOM
  integration details remain separate exporter/runtime work.
- Done: add focused programmatic equivalents for `TransformControls`,
  `DragControls`, `PointerLockControls`, and `TrackballControls` where feasible
  in a Julia workflow. Browser DOM/touch event semantics remain open.
- Done: add `examples/browser_webgl_smoke.py`, a reusable Playwright browser
  smoke that opens generated HTML, switches cases, simulates pointer drag and
  wheel zoom, exercises keyboard pan/zoom, forces an underside orbit view,
  exercises synthetic two-pointer pinch input, checks that every exported
  object remains drawn, and checks that the WebGL canvas stays drawable.

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
- Added a standalone partial port for `webgl_geometry_cube` via
  `examples/webgl_geometry_cube.jl`, using Diff3D.jl `BoxGeometry`, a generated
  texture map, and quaternion keyframe playback for the rotating cube. Exact
  upstream texture asset and `WebGLRenderer` internals remain documented
  deviations.
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
- Added a standalone partial port for `webgl_buffergeometry_points` via
  `examples/webgl_buffergeometry_points.jl`, using raw `BufferGeometry`
  attributes and browser point rendering. Exact upstream point data remains a
  documented deviation.
- Added a standalone partial port for `webgl_points_sprites` via
  `examples/webgl_points_sprites.jl`, using browser billboard Sprite proxies
  with sampled material maps plus sprite center/rotation/size-attenuation
  support.
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
  primitive geometry generators, orbit interaction, and the browser
  depth-material shader branch. Exact three.js depth-packing variants and the
  upstream object layout remain documented deviations.
- Added a standalone partial port for `webgl_materials_variations_basic` via
  `examples/webgl_materials_variations_basic.jl`, using Diff3D.jl
  `MeshBasicMaterial`, primitive geometry generators, orbit interaction,
  texture maps, and the browser unlit material shader branch. Exact three.js
  ShaderLib basic-material internals and the upstream object layout remain
  documented deviations.
- Added a standalone partial port for `webgl_materials_variations_toon` via
  `examples/webgl_materials_variations_toon.jl`, using Diff3D.jl
  `MeshToonMaterial`, primitive geometry generators, orbit interaction, and the
  browser toon-material shader branch. Exact three.js gradient-map behavior and
  the upstream object layout remain documented deviations.
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
- Added a standalone partial port for `webgl_materials_physical_clearcoat` via
  `examples/webgl_materials_physical_clearcoat.jl`, using Diff3D.jl
  `MeshPhysicalMaterial`, scalar clearcoat controls, generated clearcoat and
  clearcoat-roughness texture maps, shadows, fog, tone mapping, animation, and
  the compact browser physical-material shader branch. Exact three.js
  PhysicalMaterial BRDF, PMREM environment lighting, and upstream assets remain
  documented deviations.

## Next implementation targets

- Expand browser export toward renderer parity: full LTC rect-area lights,
  exact physical-material BRDFs, dynamic shadow rendering including
  point-light cube shadows and cascaded shadow maps,
  bone-texture/skinned-tangent skinning parity, and broader per-object
  animation binding.
- Fill glTF gaps in a test-driven order: deeper material texture/runtime parity,
  richer animation/runtime binding, and full three.js skinning parity.
- Port official examples one at a time, using each port to drive missing core
  features rather than adding demo-only shortcuts.
