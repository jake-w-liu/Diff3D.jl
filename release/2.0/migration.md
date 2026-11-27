# Migrating from Diff3D 1.x to 2.0

Diff3D 2.0 is the result of a full audit against three.js r186. Wherever 1.x
departed from three.js without documenting it, 2.0 follows three.js. Exported
1.x names, documented signatures and keyword names still work; what changes is
default values, vertex orders, color spaces and rendered pixels. This page lists
every such change. The [compatibility contract](../../docs/src/compatibility.md)
lists the differences that remain on purpose.

## Defaults

| API | 1.x | 2.0 (three.js) | To keep the old result |
|---|---|---|---|
| `MeshPhongMaterial` `specular` | `Color3(0.066, 0.066, 0.066)` | linear `0x111111` ≈ `0.0056` | pass `specular=Color3(0.066, 0.066, 0.066)` |
| `SpriteMaterial` `transparent` | `false` | `true` | pass `transparent=false` |
| `MeshPhysicalMaterial` `sheen_color` | white | black | pass `sheen_color=Color3(1, 1, 1)` |
| `DataTexture`, `DepthTexture` filters | bilinear | nearest | pass `filter=:bilinear` |
| `HemisphereLight` `ground_color` | black | white | pass `ground_color=Color3(0, 0, 0)` |
| `RectAreaLight` `width`, `height` | 1 | 10 | pass `width=1, height=1` |
| `edges_geometry` `threshold_angle` | 0.349 rad | 1° | pass `threshold_angle=0.349` |
| `ParametricGeometry` `slices`, `stacks` | 20 | 8 | pass `slices=20, stacks=20` |
| `PointLightHelper` size and color | 0.5, yellow | 1, the light's color | `PointLightHelper(light, 0.5; color=...)` |
| `DirectionalLightHelper`, `SpotLightHelper` color | yellow | the light's color | pass `color=...` |
| `GridHelper`, `PolarGridHelper` color | uniform gray 0.5 | three.js two-tone vertex colors | pass `color=Color3(0.5, 0.5, 0.5)` |
| `SpotLightHelper` `segments` | 16 | 32 | pass `segments=16` |

## Geometry

- `BoxGeometry`, `PolyhedronGeometry` (tetrahedron, octahedron, icosahedron,
  dodecahedron) and `LatheGeometry` emit three.js vertex and index order.
  Anything indexed by vertex or face number changes: hand-built per-vertex
  attributes, `face_index` from raycasts, CSG triangle counts (a union of two
  boxes gives 40 triangles instead of 24; the volume is the same).
- `PlaneGeometry`, `RingGeometry` and `CylinderGeometry` split each quad along
  three.js's diagonal; `SphereGeometry`, `TorusGeometry` and `CircleGeometry`
  use three.js index order; `TorusKnotGeometry` uses three.js's secant frame.
- Segment counts of 1 or 2 are honored for cylinders, cones, tori, torus knots
  and lathes instead of being raised.
- `ParametricGeometry` and `NURBSSurfaceGeometry` use UV `(u, v)` (v is no longer
  flipped), three.js diagonals and finite-difference normals.
- `wireframe_geometry` removes duplicate edges (a box gives 18 segments, not 30)
  and follows three.js segment order. `edges_geometry` welds corners at four
  decimals in absolute units, so a mesh smaller than about `1e-4` units yields
  no edges; scale the mesh up first.
- Open `CatmullRomCurve`s extrapolate their end neighbors, which moves points on
  the first and last segments.
- `TextGeometry` bevels grow outward: lids sit at `-bevel_thickness` and
  `depth + bevel_thickness`.
- `compute_bounding_box` and `compute_bounding_sphere` include morph targets.
- `compute_shadow_map` for a `PointLight` returns a `resolution × 6resolution`
  cube-face depth matrix.

## Rendering

- Standard and Physical direct lighting is the three.js r186 BRDF (GGX,
  height-correlated Smith visibility, DFG multiple scattering, roughness clamped
  at 0.0525). Clearcoat, sheen, iridescence and transmission follow three.js;
  emission sits under the clearcoat layer and the clearcoat lobe uses the
  unperturbed normal unless `clearcoat_normal_map` is set.
- The depth test is less-or-equal: of two surfaces at exactly equal depth the
  later-drawn one wins.
- A mesh whose world matrix mirrors space keeps three.js front faces. 1.x culled
  such meshes inside-out; scenes that compensated with `side=:back` must drop
  that workaround.
- Transparent objects sort by the depth of their bounding-sphere center, then
  by id. Transparent double-sided materials draw back faces first.
- Nearest texture sampling picks `floor(u·W), floor(v·H)`. sRGB textures decode
  each texel before filtering. Cube-map lookups clamp at face edges.
- Sprites scale their quad, then rotate it.
- `StereoCamera` eyes use off-axis frusta derived from `focus` and `eye_sep`.

## Browser export

- The viewer's lighting uses the three.js BRDFs with Lambert `albedo/π`, so
  diffuse-lit exports are about π times darker and now match three.js and the
  CPU renderer. Multiply light intensities by π to reproduce a 1.x export.
- Shadows are fully dark (1.x left 35% ambient), shadow depth is packed into
  RGBA, and static point-light shadows cover all six cube faces.
- `flat_shading` meshes render flat; hemisphere lights follow their world
  position; an unclamped finished clip leaves the exported pose.
- Export raises `ArgumentError` for a title containing NUL, a `LightProbe` with
  `sh` coefficients, non-default `shadow_intensity`/`shadow_normal_bias`, and
  cameras with view or film offsets.

## Animation and controls

- `interpolation=:cubic` tracks and `interpolate_catmull_rom` are three.js
  `CubicInterpolant`; unevenly spaced keys sample differently.
- `AnimationMixer` steps like a three.js `AnimationAction`. An unclamped finish
  restores the values the targets had when the mixer was created (1.x sampled
  frame 0) and stays finished until `mixer_reset!` or `mixer_set_time!`. Use
  `clamp_when_finished=true` to hold the last pose. `mixer_set_time!` restarts
  the action before seeking.
- `AnimationClip(name, tracks)` measures its duration from 0.
- A stopped `Clock` returns a zero delta.
- `OrbitControls` and `MapControls` orbit about `camera.up` (1.x always used
  world +y), and `orbit_update!` re-applies the distance, angle and target
  limits on every call.

## Raycasting

- Mesh raycasts use three.js's watertight test in object space: rays through
  shared edges and corners hit, and a ray starting on a surface hits at
  distance 0.
- For an `OrthographicCamera`, `set_from_camera!` starts the ray in the camera
  plane, so distances are larger by `near` and surfaces in front of the near
  plane are picked.
- A line hit's `face_index` is the draw entry (index-buffer position) for
  indexed lines.
- `Intersection` has new fields (`face`, `face_normal`, `normal`, `uv`, `uv1`,
  `barycoord`, `distance_to_ray`); the 4- and 5-argument constructors still
  work.

## Loaders

- `load_ply` vertex colors, `load_mtl` `Kd`/`Ks`/`Ke`, and SVG paint colors are
  converted from sRGB to linear, like the STL, OBJ and XYZ loaders already did.
  Code that converted these itself must stop.
- `load_mtl`: the last of repeated map statements wins; `d` and `Tr` follow
  MTLLoader.
- glTF: `BLEND` materials disable depth writes; points load without size
  attenuation; a primitive without normals is de-indexed and flat-shaded; a
  `weights` channel drives only its target node.
- SVG: `<use>` renders its target as a child of the `use` element (the target's
  own attributes win); `<symbol>` renders only through `<use>`; open subpaths
  with a fill are filled; stroke widths scale with the element transform.
- Parsers are stricter: ASCII STL and OBJ reject trailing non-numeric tokens,
  `inflate` rejects invalid Huffman code sets, and the JSON parser rejects
  invalid UTF-8.

## Math and differentiation

- `mat4_decompose` uses the affine determinant; `mat4_look_at` perturbs the up
  vector only when it is exactly parallel to the view direction.
- `interpolate_linear` returns the interior result type at the endpoints.
- `ADVar` `sind`/`cosd`/`tand` return Base's exact values.
- `soft_render` fades triangles whose doubled screen area is below `config.eps`
  instead of dropping them, and Float32 inputs stay Float32 in the distance
  helpers.

## Structures and names

- Fields were added to `PerspectiveCamera`, `OrthographicCamera`, the shadow
  casting lights, `LightProbe`, `ShadowMap`, `Raycaster`, `Intersection`,
  `AnimationMixer`, `Clock` and `NumberKeyframeTrack`. Keyword constructors and
  the documented positional forms are unchanged; code that relied on
  `fieldcount` or on undocumented positional constructors must be updated.
- 222 names are newly exported, among them the generic `Curve`, `Path`, `Shape`,
  `damp`, `pingpong` and `smoothstep`. If another package in scope exports the
  same name, qualify it (`Diff3D.Shape`).
