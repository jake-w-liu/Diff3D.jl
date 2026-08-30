# Diff3D.jl

Diff3D.jl is a Julia-native 3D graphics and differentiable rendering package.
It combines a three.js-inspired scene API with CPU rendering, differentiable
soft rasterization, asset loaders, animation/control helpers, and standalone
WebGL HTML export.

## Minimal Render

```julia
using Diff3D

scene = Scene(background = Color3(0.03, 0.04, 0.05))
camera = PerspectiveCamera(fov = pi / 3, aspect = 1.0, near = 0.1, far = 100.0)
camera.position = Vec3(3.0, 2.0, 4.0)

mesh = Mesh(
    BoxGeometry(),
    MeshPhongMaterial(color = Color3(0.2, 0.55, 0.95)),
)
add!(scene, mesh)
add!(scene, AmbientLight(intensity = 0.35))
add!(scene, DirectionalLight(intensity = 1.2))

target = RenderTarget(512, 512)
render!(target, scene, camera)
save_png("cube.png", target.color)
```

## Subsystems

- Math and transforms: vectors, matrices, quaternions, Euler rotations, rays,
  planes, bounding volumes, and frustums.
- Scene graph: objects, groups, meshes, lines, points, sprites, LODs, layers,
  skeletons, and instanced meshes.
- Geometry: primitive, parametric, polyhedral, swept, extruded, wireframe, and
  edge geometries.
- Materials and lights: unlit, Lambert, Phong, PBR-style, physical, toon,
  matcap, normal, depth, sprite, line, point, shader materials, common lights,
  IES profiles, and shadows.
- Rendering: CPU rasterization, tiled rendering, MSAA, post-processing, texture
  maps, clipping/scissor/logarithmic depth, and browser WebGL export.
- Differentiable workflows: soft rasterization, image losses, finite-difference
  checks, ForwardDiff gradients, reverse-mode scalar AD helpers, and inverse
  rendering optimizers.
- I/O: PNG/PPM/PDF output, PNG decoding, OBJ/MTL/STL/PLY/XYZ loading, and
  glTF/GLB loading.

## Feature Tour

The snippets below are a hands-on tour of the major subsystems. Each is
self-contained and runnable as-is; all assume you have already run `using
Diff3D`. They mirror the corresponding three.js concepts while staying pure
Julia and differentiable-friendly. The Differentiable Rendering & Inverse
example additionally uses ForwardDiff, which you can add to your project with
`] add ForwardDiff`.

### Math & Transforms

Diff3D ships a self-contained, ForwardDiff-friendly math core that mirrors three.js conventions: immutable `Vec2`/`Vec3`/`Vec4`, column-major `Mat4`, quaternions and Euler angles, bounding volumes, geometric primitives, spherical/cylindrical coordinates, and frustum culling. Every type is parametric so it flows through automatic differentiation unchanged.

```julia
# Vectors: dot / cross / norm / normalize / lerp / distance (Vec2/Vec3/Vec4)
a, b = Vec3(1.0, 2.0, 2.0), Vec3(4.0, 0.0, 3.0)
n   = normalize(a)                       # unit-length copy, |n| = 1
mid = lerp(a, b, 0.5)                     # midpoint
c   = cross(a, b)                         # perpendicular to a and b
@assert norm(a) ≈ 3.0 && distance(a, b) ≈ norm(a - b)
@assert isapprox(dot(c, a), 0.0; atol=1e-12)
d2  = dot(Vec2(1.0, 2.0), Vec2(3.0, 4.0))
w   = Vec4(1.0, 0.0, 0.0, 1.0)

# Mat4 builders, point/direction transforms and inverse (column-major, three.js order)
M    = mat4_translation(1, 2, 3) * mat4_rotation_y(pi/2) * mat4_scaling(2, 2, 2)
p    = mat4_transform_point(M, Vec3(1.0, 0.0, 0.0))      # includes translation
dir  = mat4_transform_direction(M, Vec3(1.0, 0.0, 0.0))  # ignores translation
back = mat4_transform_point(mat4_inverse(M), p)
@assert isapprox(back.x, 1.0; atol=1e-9)

# Quaternion / Euler: build, compose, interpolate, convert to a rotation matrix
euler = Euler(0.0, pi/2, 0.0)                             # default order :XYZ
q1 = quat_from_euler(euler.x, euler.y, euler.z; order=euler.order)
q2 = quat_from_euler(pi/2, 0.0, 0.0)
qh = quat_slerp(q1, q2, 0.5)                              # halfway rotation
R  = quat_to_mat4(quat_normalize(quat_multiply(q1, q2)))

# Camera matrices + frustum culling
view = mat4_look_at(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
proj = mat4_perspective(deg2rad(60), 16 / 9, 0.1, 100.0)
_    = mat4_orthographic(-1, 1, -1, 1, 0.1, 10.0)
fr   = frustum_from_matrix(proj * view)
@assert frustum_contains_point(fr, Vec3(0.0, 0.0, 0.0))
@assert frustum_intersects_sphere(fr, BoundingSphere(Vec3(0.0, 0.0, 0.0), 1.0))
@assert frustum_intersects_box(fr, Box3(Vec3(-1.0, -1.0, -1.0), Vec3(1.0, 1.0, 1.0)))

# Primitives: Triangle / Plane / Ray / Line3 / Box3
tri  = Triangle(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
area = triangle_area(tri); nrm = triangle_normal(tri)
bc   = triangle_barycentric(tri, Vec3(0.25, 0.25, 0.0))  # (u, v, w)
sd   = plane_distance_to_point(Plane(Vec3(0.0, 1.0, 0.0), 0.0), Vec3(0.0, 5.0, 0.0))
ray  = Ray(Vec3(0.0, 10.0, 0.0), Vec3(0.0, -1.0, 0.0))
cp   = line3_closest_point(Line3(Vec3(0.0, 0.0, 0.0), Vec3(10.0, 0.0, 0.0)), Vec3(3.0, 4.0, 0.0))
box  = box3_expand_by_point(box3_expand_by_point(Box3(), Vec3(-1.0, 0.0, 2.0)), Vec3(3.0, 4.0, -1.0))

# Spherical / Cylindrical round-trips
sc = spherical_to_cartesian(cartesian_to_spherical(Vec3(0.0, 0.0, 5.0)))
cc = cylindrical_to_cartesian(cartesian_to_cylindrical(Vec3(3.0, 2.0, 0.0)))
@assert isapprox(sc.z, 5.0; atol=1e-9) && isapprox(cc.x, 3.0; atol=1e-9)

println("OK math: |a|=$(norm(a)), tri area=$area, plane dist=$sd, closest x=$(cp.x)")
```

### Scene Graph & Hierarchy

Diff3D mirrors the three.js scene graph: a `Scene` (with a background color and optional fog) is the root of a tree of `Group`, `Mesh`, and other `Object3D` nodes linked with `add!`/`remove!`. Each node carries a local `position`/`rotation`/`scale`, and world transforms compose down the parent chain — computed one node at a time with `compute_world_matrix` or in a single cached pass with `compute_world_matrices`.

```julia
# A Scene owns a background color and (optionally) fog.
scene = Scene(background=Color3(0.05, 0.06, 0.09),
              fog=Fog(color=Color3(0.05, 0.06, 0.09), near=8.0, far=40.0))

box(name) = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                 MeshBasicMaterial(color=Color3(0.9, 0.4, 0.3)); name=name)

ground = box("ground")
add!(scene, ground)

# Nested transforms: an orbit Group holds a planet, which holds a moon.
orbit = Group(name="orbit")
orbit.position = Vec3(10.0, 0.0, 0.0)
planet = box("planet"); planet.position = Vec3(2.0, 0.0, 0.0); planet.scale = Vec3(0.5, 0.5, 0.5)
moon = box("moon");     moon.position = Vec3(0.0, 1.5, 0.0);   moon.rotation = Euler(0.0, π/2, 0.0)
add!(scene, orbit); add!(orbit, planet); add!(planet, moon)

# World matrix composes the parent chain: orbit(10) + planet(2) => world x = 12.
wp = mat4_transform_point(compute_world_matrix(planet), Vec3(0.0, 0.0, 0.0))

# One traversal builds a cache of every object's world matrix (updateMatrixWorld).
cache = compute_world_matrices(scene)

all_meshes = collect_meshes(scene)          # ground, planet, moon
planet.visible = false                       # hides planet AND its subtree (moon)
visible_meshes = collect_meshes(scene)       # just ground

# Swap to exponential fog; traverse walks the whole graph regardless of visibility.
scene.fog = FogExp2(color=Color3(0.05, 0.06, 0.09), density=0.03)
nodes = Ref(0); traverse(scene, _ -> nodes[] += 1)
remove!(planet, moon)

println("OK scene | planet world x=", round(wp.x, digits=2),
        " cached=", length(cache), " all=", length(all_meshes),
        " visible=", length(visible_meshes), " nodes=", nodes[],
        " moon_visible=", is_visible(moon))
```

### Cameras

Diff3D provides three.js-style cameras that produce standard view and projection matrices. `PerspectiveCamera` and `OrthographicCamera` are aimed by setting their `position` and `target` fields, while `StereoCamera`, `CubeCamera`, and `ArrayCamera` compose them for stereo, cube-map, and multi-viewport rendering; matching `*_from_params` helpers build the same matrices from raw scalars for autodiff.

```julia
# Perspective camera: aim it by setting position/target fields.
cam = PerspectiveCamera(fov=pi/4, aspect=16/9, near=0.1, far=100.0)
cam.position = Vec3(0.0, 2.0, 6.0)
cam.target   = Vec3(0.0, 0.0, 0.0)
view = view_matrix(cam)               # world -> camera
proj = projection_matrix(cam)         # camera -> clip (zoom-aware)
view_proj = mat4_multiply(proj, view)

# Orthographic camera with an explicit frustum box.
ortho = OrthographicCamera(left=-2.0, right=2.0, bottom=-2.0, top=2.0, near=0.1, far=10.0)
ortho.position = Vec3(0.0, 0.0, 5.0)

# Stereo pair: left/right eyes offset along the camera's right axis.
stereo = StereoCamera(eye_sep=0.064, aspect=16/9)
stereo_update!(stereo, cam)
eye_gap = distance(stereo.cameraL.position, stereo.cameraR.position)

# Cube camera: six 90-degree face cameras (+x,-x,+y,-y,+z,-z).
cube = CubeCamera(near=0.1, far=50.0, position=Vec3(0.0, 1.0, 0.0))

# Array camera: sub-cameras each owning a screen viewport (x,y,w,h).
arr = ArrayCamera([cam, PerspectiveCamera(aspect=1.0)],
                  [(0, 0, 640, 720), (640, 0, 640, 720)])

# Parametric variants for autodiff: build matrices from raw scalars.
vp = projection_matrix_from_params(pi/4, 16/9, 0.1, 100.0) *
     view_matrix_from_params(0.0, 2.0, 6.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)

println("OK cameras: eye_gap=", round(eye_gap, digits=4),
        " faces=", length(cube.cameras),
        " views=", length(arr.cameras),
        " clip11=", round(mat4_get(vp, 1, 1), digits=4))
```

### Geometry Generators

Diff3D ships a full library of three.js-style geometry generators that build `BufferGeometry` (flat position/normal/UV arrays plus triangle indices). Constructors take keyword arguments mirroring their three.js counterparts, and helpers let you derive wireframes, batch meshes, and inspect vertices and bounds.

```julia
# Primitives — three.js-style keyword constructors
box    = BoxGeometry(width=2.0, height=1.0, depth=1.0)
sphere = SphereGeometry(radius=1.0, width_segments=24, height_segments=16)
cyl    = CylinderGeometry(radius_top=0.5, radius_bottom=1.0, height=2.0)
cone   = ConeGeometry(radius=1.0, height=2.0, radial_segments=24)
torus  = TorusGeometry(radius=1.0, tube=0.3, radial_segments=16, tubular_segments=48)
knot   = TorusKnotGeometry(radius=1.0, tube=0.3, p_val=2, q_val=3)
ring   = RingGeometry(inner_radius=0.4, outer_radius=1.0)
circle = CircleGeometry(radius=1.0, segments=32)
plane  = PlaneGeometry(width=2.0, height=2.0, width_segments=4, height_segments=4)

# Platonic solids (radius + subdivision detail)
ico  = IcosahedronGeometry(radius=1.0, detail=1)
oct  = OctahedronGeometry(radius=1.0, detail=0)
tet  = TetrahedronGeometry(radius=1.0)
dode = DodecahedronGeometry(radius=1.0)

# Swept / profile geometry
lathe = LatheGeometry([Vec2(0.0, -1.0), Vec2(0.6, 0.0), Vec2(0.2, 1.0)]; segments=16)
tube  = TubeGeometry([Vec3(0.0, 0, 0), Vec3(1.0, 1, 0), Vec3(2.0, 0, 1)]; radius=0.2, radial_segments=8)
caps  = CapsuleGeometry(radius=0.5, length=1.5, cap_segments=8, radial_segments=16)

# Curve → line geometry, and the classic Utah teapot
curve    = CatmullRomCurve([Vec3(0.0, 0, 0), Vec3(1.0, 1, 0), Vec3(2.0, -1, 0), Vec3(3.0, 0, 0)]; curve_type=:centripetal)
curvegeo = CatmullRomCurveGeometry(curve; segments=100)
teapot   = TeapotGeometry(1.0, 8)

# Derived geometry: wireframe / feature edges / batching
wire   = wireframe_geometry(box)
edges  = edges_geometry(box)
merged = merge_geometries([box, sphere, torus])

# Inspection helpers
bbox = compute_bounding_box(merged)
bsph = compute_bounding_sphere(sphere)
v1   = get_vertex(box, 1)
f1   = get_face(box, 1)
n1   = get_normal(box, 1)

println("triangles: box=$(count_triangles(box)) knot=$(count_triangles(knot)) merged=$(count_triangles(merged))")
println("wire verts=$(wire.n_vertices) edge verts=$(edges.n_vertices) curve pts=$(curvegeo.n_vertices)")
println("teapot tris=$(count_triangles(teapot)) sphere radius≈$(round(bsph.radius, digits=3))")
println("merged bbox min=$(bbox.min) max=$(bbox.max)")
println("box face $f1 vertex=$v1 normal=$n1")
println("OK geometry")
```

### Constructive Solid Geometry (CSG)

Diff3D evaluates boolean operations over closed triangle `BufferGeometry` solids with a BSP polygon-clipping evaluator (the same algorithm behind three.js CSG). `csg_union`, `csg_subtract`, and `csg_intersect` return non-indexed `BufferGeometry` results, `transform_geometry` bakes a `Mat4` into an operand to position it, and `csg_evaluate` is the dispatching entry point that also accepts operation aliases.

```julia
# Two closed triangle solids as CSG operands.
box = BoxGeometry(width=1.6, height=1.6, depth=1.6)
sphere = SphereGeometry(radius=1.0, width_segments=24, height_segments=16)

# Position the sphere operand by baking a transform into its vertices.
offset = mat4_translation(0.8, 0.6, 0.5)
sphere = transform_geometry(sphere, offset)

# Boolean operations over the two BufferGeometry solids.
union_geo     = csg_union(box, sphere)
subtract_geo  = csg_subtract(box, sphere)
intersect_geo = csg_intersect(box, sphere)

# csg_evaluate is the dispatching entry point (accepts operation aliases).
eval_geo = csg_evaluate(box, sphere, :difference)

for (name, g) in (("union", union_geo), ("subtract", subtract_geo),
                  ("intersect", intersect_geo), ("evaluate(:difference)", eval_geo))
    println("$name -> ", count_triangles(g), " triangles")
end

@assert count_triangles(subtract_geo) == count_triangles(eval_geo)
println("OK csg")
```

### Materials

Diff3D.jl mirrors the three.js material hierarchy: every shading model is an `AbstractMaterial` built from keyword arguments, and a small set of query helpers reads the fields they share (opacity, transparency, side, wireframe) uniformly across all of them. The example below constructs one material of each kind, exercises the shared knobs, and renders a lit scene to prove they work.

```julia
# One material per shading model, plus the shared knobs
# (opacity/transparent, side, wireframe, alpha_test).
mats = AbstractMaterial[
    MeshBasicMaterial(color=Color3(0.9, 0.2, 0.2), wireframe=true),
    MeshLambertMaterial(color=Color3(0.2, 0.7, 0.3), emissive=Color3(0.02, 0.02, 0.0)),
    MeshPhongMaterial(color=Color3(0.2, 0.4, 0.9), shininess=80.0),
    MeshStandardMaterial(color=Color3(0.85, 0.7, 0.1), metalness=0.9, roughness=0.25),
    MeshPhysicalMaterial(color=Color3(0.8, 0.1, 0.1), clearcoat=1.0, clearcoat_roughness=0.1),
    MeshToonMaterial(color=Color3(0.9, 0.5, 0.2), gradient_steps=4),
    MeshMatcapMaterial(color=Color3(0.6, 0.6, 0.9)),
    MeshNormalMaterial(),
    MeshDepthMaterial(near=0.1, far=10.0, depth_packing=:rgba),
    MeshBasicMaterial(color=Color3(0.1, 0.8, 0.9), opacity=0.4, transparent=true,
                      side=:double, alpha_test=0.05),
]

# Query helpers read shared fields uniformly across every material type.
glass = mats[end]
@assert material_opacity(glass) == 0.4
@assert is_transparent_material(glass)
@assert material_side(glass) == :double
@assert material_wireframe(mats[1])

# Drop each material on a sphere; render the metallic-roughness one lit.
scene = Scene(background=Color3(0.05, 0.05, 0.06))
geo = SphereGeometry(radius=1.0, width_segments=32, height_segments=16)
for (i, m) in enumerate(mats)
    add!(scene, Mesh(geo, m; name="mat_$i"))
end
add!(scene, DirectionalLight(position=Vec3(3.0, 3.0, 4.0), intensity=1.0))
add!(scene, AmbientLight(intensity=0.3))

cam = PerspectiveCamera(fov=pi / 4, aspect=1.0)
cam.position = Vec3(0.0, 0.0, 4.0)
rt = RenderTarget(96, 96)
render!(rt, scene, cam)

println("OK materials: ", length(mats), " types, pixel-sum=",
        round(sum(rt.color); digits=3))
```

### Textures

Diff3D stores image data as row-major `H×W×C` `Float64` arrays (UV `(0,0)` is bottom-left) and wraps them in a `Texture`, which powers procedural generators, UV sampling with wrap/filter modes and mipmaps, cube maps built from equirectangular environments, and PMREM roughness prefiltering. Textures plug straight into materials via `map=` and render through the standard rasterizer.

```julia
# Procedural checker + grid textures (H×W×3, RGB in [0,1])
checker = checker_texture(n=4, cell=8, a=Color3(0.9, 0.9, 0.9), b=Color3(0.1, 0.1, 0.2))
grid = grid_texture(size_px=64, cell=16, thickness=2)

# DataTexture / CanvasTexture wrap a raw H×W×C array (same backing struct)
img = [Float64((i + j) % 2) for i in 1:16, j in 1:16, c in 1:3]
data = DataTexture(img; colorspace=:linear)
canvas = CanvasTexture(img; filter=:nearest, wrap_s=:clamp, wrap_t=:clamp)

# UV sampling: raw, sRGB→linear, and a discrete mip level
raw = sample_texture(checker, 0.3, 0.7)
lin = sample_texture_linear(checker, 0.3, 0.7)
generate_mipmaps!(checker)                       # box-filtered pyramid down to 1×1
coarse = sample_texture_lod(checker, 0.3, 0.7, 3)

# UV transform matrix from offset/repeat/rotation/center (three.js Texture.matrix)
data.repeat = Vec2(2.0, 2.0); data.rotation = pi / 6; data.center = Vec2(0.5, 0.5)
texture_update_matrix!(data)
ut, vt = texture_transform_uv(data, 0.25, 0.5)

# Equirectangular env map → cube map → directional sampling, then PMREM prefilter
envdata = [c == 3 ? 0.5 : i / 16 for i in 1:16, j in 1:32, c in 1:3]
env_tex = Texture(envdata; colorspace=:linear)
cube = equirectangular_to_cubemap(env_tex; size=8, generate_mipmaps=true)  # CubeTexture
sky = sample_cube(cube, normalize(Vec3(1.0, 0.3, 0.2)))
pmrem = generate_pmrem(cube; levels=3, samples=16)
refl = sample_pmrem(pmrem, Vec3(0.0, 1.0, 0.0), 0.5)

# Apply a texture as a material map and rasterize a lit cube
scene = Scene(background=Color3(0.05, 0.05, 0.08))
add!(scene, Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                 MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0), roughness=0.8, map=checker)))
add!(scene, DirectionalLight(intensity=1.0, position=Vec3(3.0, 4.0, 5.0)))
cam = PerspectiveCamera(fov=pi / 4, aspect=1.0, near=0.1, far=100.0)
cam.position = Vec3(0.0, 0.0, 3.0)
rt = RenderTarget(48, 48)
render!(rt, scene, cam)

println("OK textures | raw=", round(raw.r, digits=3), " lin=", round(lin.r, digits=3),
        " coarse=", round(coarse.r, digits=3), " uv'=(", round(ut, digits=3), ",",
        round(vt, digits=3), ") sky=", round(sky.r, digits=3), " refl=", round(refl.r, digits=3),
        " center=", round(rt.color[24, 24, 1], digits=3))
```

### Lights & Shadows

Diff3D mirrors the three.js light hierarchy - ambient, hemisphere, probe, point, rect-area, spot, and directional lights - and layers on measured IESNA photometric profiles plus shadow mapping. Lights are gathered from a scene with `collect_lights`, while `compute_shadow_map`/`shadow_visibility` (or simply `render!(...; shadows=true)`) resolve depth-based occlusion.

```julia
# --- Lights mirroring the three.js hierarchy ---
scene = Scene(background=Color3(0.02, 0.02, 0.03))
add!(scene, AmbientLight(color=Color3(0.6, 0.7, 1.0), intensity=0.25))
add!(scene, HemisphereLight(color=Color3(0.8, 0.9, 1.0),
                            ground_color=Color3(0.2, 0.15, 0.1), intensity=0.4))
add!(scene, LightProbe(Color3(0.1, 0.1, 0.12)))          # DC-only ambient probe
add!(scene, PointLight(color=Color3(1.0, 0.8, 0.6), intensity=1.2,
                       distance=20.0, decay=2.0, position=Vec3(2.0, 3.0, 1.0)))
add!(scene, RectAreaLight(color=Color3(1.0, 1.0, 1.0), intensity=2.0,
                          width=2.0, height=1.0, position=Vec3(-3.0, 4.0, 0.0)))

# Photometric spotlight from an in-memory IESNA LM-63 profile
ies_text = """
IESNA:LM-63-2002
TILT=NONE
1 1000 1 5 1 1 1 0 0 0 1 1 100
0 45 90 135 180
0
1000 800 500 200 0
"""
profile = parse_ies(ies_text)                            # -> IESProfile
@assert ies_candela(profile, 90.0) == 500.0              # interpolated candela (cd)
@assert ies_intensity(profile, 90.0) == 0.5             # normalized [0,1] multiplier
spot = SpotLight(color=Color3(1.0, 0.95, 0.85), intensity=3.0, angle=pi/6,
                 penumbra=0.3, position=Vec3(0.0, 6.0, 0.0),
                 ies_profile=profile, cast_shadow=true)
spot.target = Vec3(0.0, 0.0, 0.0)
add!(scene, spot)

# Key directional light casting soft (PCF) shadows onto a receiving ground plane
key = DirectionalLight(color=Color3(1.0, 0.96, 0.9), intensity=1.1,
                       position=Vec3(4.0, 8.0, 5.0), cast_shadow=true, shadow_pcf_radius=2)
key.target = Vec3(0.0, 0.0, 0.0)
add!(scene, key)

ground = Mesh(PlaneGeometry(width=20.0, height=20.0),
              MeshStandardMaterial(color=Color3(0.35, 0.37, 0.4)); receive_shadow=true)
ground.rotation = Euler(-pi/2, 0.0, 0.0)
add!(scene, ground)
box = Mesh(BoxGeometry(width=1.5, height=1.5, depth=1.5),
           MeshStandardMaterial(color=Color3(0.8, 0.3, 0.3)); cast_shadow=true)
box.position = Vec3(0.0, 0.75, 0.0)
add!(scene, box)

lights = collect_lights(scene)                           # visibility-aware traversal

# Direct shadow-map query: a ground point under the box vs. open ground
sm = compute_shadow_map(scene, key; resolution=512)      # -> ShadowMap
occluded = shadow_visibility(sm, Vec3(0.0, 0.01, 0.0))   # 0 = shadowed
lit = shadow_visibility(sm, Vec3(6.0, 0.01, 6.0))        # 1 = fully lit

# Full render with shadow mapping enabled (see examples/official_showcase.jl)
cam = PerspectiveCamera(fov=pi/4, aspect=1.0, near=0.1, far=100.0)
cam.position = Vec3(7.0, 6.0, 8.0); cam.target = Vec3(0.0, 0.5, 0.0)
rt = RenderTarget(240, 240)
render!(rt, scene, cam; shading=:smooth, shadows=true, shadow_resolution=1024)

println("OK lights: ", length(lights), " lights; occluded=", round(occluded, digits=2),
        " lit=", round(lit, digits=2), " ies@90=", ies_candela(profile, 90.0))
```

### Rendering & Render Modes

Diff3D rasterizes a scene into a `RenderTarget` (an H×W×3 color buffer plus a depth buffer) and offers several render entry points — flat vs. smooth shading, pooled/tiled/MSAA variants — followed by a linear-light post-processing pipeline (tone mapping, sRGB encoding, and supersample anti-aliasing). This example walks a small scene through every mode and then tone-maps and encodes the buffer for display.

```julia
# Build a small scene: a box and a sphere lit by an ambient + directional key.
scene = Scene(background = Color3(0.05, 0.06, 0.09))
box = Mesh(BoxGeometry(width = 1.5, height = 1.5, depth = 1.5),
           MeshPhongMaterial(color = Color3(0.9, 0.35, 0.2)))
box.position = Vec3(-1.3, 0.0, 0.0)
sphere = Mesh(SphereGeometry(radius = 1.0, width_segments = 32, height_segments = 24),
              MeshStandardMaterial(color = Color3(0.2, 0.5, 0.9), roughness = 0.4, metalness = 0.1))
sphere.position = Vec3(1.3, 0.0, 0.0)
add!(scene, box); add!(scene, sphere)
add!(scene, AmbientLight(color = Color3(1.0, 1.0, 1.0), intensity = 0.3))
key = DirectionalLight(color = Color3(1.0, 0.95, 0.9), intensity = 1.0, position = Vec3(4.0, 6.0, 5.0))
key.target = Vec3(0.0, 0.0, 0.0); add!(scene, key)

cam = PerspectiveCamera(fov = π / 4, aspect = 16 / 9, near = 0.1, far = 100.0)
cam.position = Vec3(0.0, 2.0, 6.0); cam.target = Vec3(0.0, 0.0, 0.0)

W, H = 160, 90
rt = RenderTarget(W, H)                              # H×W×3 color + depth buffers
clear!(rt, scene.background)                         # explicit buffer reset
render!(rt, scene, cam; shading = :flat)             # per-face flat shading
render!(rt, scene, cam; shading = :smooth)           # per-pixel smooth shading

cache = RenderCache()                                # reusable scratch → bounded allocation
render_pooled!(rt, scene, cam, cache; shading = :flat)          # pooled opaque flat
render_tiled!(rt, scene, cam)                                   # row-banded (threadable)
render_msaa!(rt, scene, cam; samples = 4, shading = :smooth, cache = cache)  # in-renderer AA

# Supersample AA primitives: render 2× then box-downsample, or the convenience wrapper.
big = RenderTarget(W * 2, H * 2); render!(big, scene, cam; shading = :flat)
aa_manual = downsample(big.color, 2)                 # box-average 2× supersample
aa = render_aa(scene, cam, W, H; ss = 2, shading = :smooth)

# Post-process the linear-light buffer: tone map (Reinhard or ACES) then sRGB encode.
tm = tone_map_reinhard(rt.color); tm = tone_map_aces(rt.color)
disp = srgb_encode(tm)                               # linear → sRGB for display
rt.color .= disp                                     # write display buffer back
rgb8 = render_to_rgb8(rt)                            # H×W×3 UInt8 for saving
img = render_target_to_image(rt)                     # H×W×3 Float64 copy

# Per-channel color-space conversions round-trip.
roundtrip = srgb_to_linear(linear_to_srgb(0.5))

println("OK render: rgb8 $(size(rgb8)) $(eltype(rgb8)), img $(size(img)), ",
        "aa $(size(aa)) manual $(size(aa_manual)), srgb roundtrip ≈ $(round(roundtrip, digits = 4))")
```

### Post-Processing

Diff3D renders into a `RenderTarget` that keeps both a color image (`rt.color`) and a depth buffer (`rt.depth`). The `EffectComposer` chains post-processing passes over that color image: color-only passes (bloom, FXAA, tone mapping, sRGB, grayscale) and depth-aware passes (outline, SSAO, bokeh) that capture `rt.depth` when built. You register passes with `add_pass!` and run the whole chain with `compose`.

```julia

# A small lit scene rendered to a RenderTarget (keeps rt.color and rt.depth).
scene = Scene(background=Color3(0.02, 0.03, 0.05))
add!(scene, AmbientLight(color=Color3(0.8, 0.85, 1.0), intensity=0.25))
key = DirectionalLight(color=Color3(1.0, 0.95, 0.8), intensity=1.1, position=Vec3(4.0, 8.0, 6.0))
add!(scene, key)

floor = Mesh(PlaneGeometry(width=16.0, height=16.0), MeshStandardMaterial(color=Color3(0.3, 0.32, 0.4), roughness=0.9))
floor.rotation = Euler(-pi/2, 0.0, 0.0)
add!(scene, floor)
for (i, x) in enumerate((-1.6, 0.0, 1.6))
    ball = Mesh(SphereGeometry(radius=0.6, width_segments=32, height_segments=20),
                MeshStandardMaterial(color=Color3(0.9, 0.4, 0.25), metalness=0.2, roughness=0.35))
    ball.position = Vec3(x, 0.6, 0.8 * (i - 2))   # staggered depth for DoF/SSAO
    add!(scene, ball)
end

cam = PerspectiveCamera(fov=pi/4, aspect=180/120, near=0.1, far=100.0)
cam.position = Vec3(4.5, 4.0, 8.0); cam.target = Vec3(0.0, 0.5, 0.0)
rt = RenderTarget(180, 120)
render!(rt, scene, cam; shading=:smooth, shadows=false)

# Focus plane = median finite depth, used by the depth-of-field pass.
finite = sort!([d for d in vec(rt.depth) if isfinite(d)])
focus = isempty(finite) ? 1.0 : finite[max(1, length(finite) ÷ 2)]

# Depth-aware + tone-mapping pipeline: SSAO and outline read rt.depth, bokeh reads
# depth + focus + aperture, bloom glows bright pixels, then ACES tone map, sRGB
# encode, and FXAA smooth as the final display passes.
composer = EffectComposer()
add_pass!(composer, ssao_pass(rt.depth; radius=2.5, intensity=0.5, samples=8))
add_pass!(composer, outline_pass(rt.depth; threshold=0.04, color=Color3(0.02, 0.03, 0.04)))
add_pass!(composer, bokeh_pass(rt.depth; focus_depth=focus, aperture=6.0))
add_pass!(composer, bloom_pass(threshold=0.6, intensity=0.4, radius=3))
add_pass!(composer, aces_pass)     # HDR -> [0,1] filmic tone map
add_pass!(composer, srgb_pass)     # linear -> sRGB for display
add_pass!(composer, fxaa_pass())
img = compose(composer, rt.color)

# A second composer showing the remaining built-in passes.
gray = compose(add_pass!(add_pass!(EffectComposer(), reinhard_pass), grayscale_pass), rt.color)

println("OK postfx  img=", size(img), "  focus=", round(focus, digits=3),
        "  gray_mean=", round(sum(gray) / length(gray), digits=4))
```

### Instancing, Points, Lines & Sprites

Beyond triangle meshes, Diff3D mirrors the three.js scene-graph primitives for drawing many copies of one geometry cheaply (`InstancedMesh`), rendering raw vertex buffers as point clouds or line primitives, and placing camera-facing billboards (`Sprite`). Point, line, and sprite overlays are drawn with their own passes (`render_points!`, `render_lines!`, `render_sprites!`) on top of the rasterized triangles.

```julia
# Ground BufferGeometry helpers (examples/official_showcase.jl): raw vertex
# positions, no faces — the substrate for point and line primitives.
positions_geometry(pts) =
    BufferGeometry(collect(Iterators.flatten((p.x, p.y, p.z) for p in pts)),
                   Float64[], Float64[], Int[], length(pts), 0)
segment_geometry(segs) =
    BufferGeometry(collect(Iterators.flatten((a.x,a.y,a.z, b.x,b.y,b.z) for (a,b) in segs)),
                   Float64[], Float64[], Int[], 2length(segs), 0)

scene = Scene(background=Color3(0.0, 0.0, 0.0))
add!(scene, DirectionalLight(color=Color3(1.0,1.0,1.0), intensity=1.1, position=Vec3(3.0,5.0,4.0)))

# InstancedMesh: one geometry drawn at many transforms with per-instance color.
inst = InstancedMesh(BoxGeometry(width=0.4, height=0.4, depth=0.4),
                     MeshStandardMaterial(color=Color3(0.8,0.8,0.9)), 9; cast_shadow=true)
for i in 1:instanced_count(inst)
    x = (i - 5) * 0.8
    set_instance_matrix!(inst, i, mat4_translation(x, sin(x), 0.0))
    set_instance_color!(inst, i, Color3(i/9, 0.4, 1 - i/9))
end
add!(scene, inst)

# PointsObject cloud from raw positions.
cloud = PointsObject(positions_geometry([Vec3(cos(t), sin(t), 0.5sin(2t)) for t in range(0, 2pi, length=64)]),
                     PointsMaterial(color=Color3(0.6,0.9,1.0), size=3.0))
add!(scene, cloud)

# LineSegments (disjoint pairs) with a basic line material.
add!(scene, LineSegments(segment_geometry([(Vec3(-2.0,0.0,0.0), Vec3(2.0,0.0,0.0))]),
                         LineBasicMaterial(color=Color3(1.0,0.5,0.2), linewidth=2.0)))

# LineLoop with a dashed material; compute_line_distances! fills the dash parameter.
loop_geo = positions_geometry([Vec3(-1.0,-1.0,0.0), Vec3(1.0,-1.0,0.0), Vec3(0.0,1.2,0.0)])
compute_line_distances!(loop_geo; mode=:line_loop)
add!(scene, LineLoop(loop_geo, LineDashedMaterial(color=Color3(0.4,1.0,0.6), dash_size=0.3, gap_size=0.15)))

# Sprite: a camera-facing billboard.
sprite = Sprite(SpriteMaterial(color=Color3(1.0,0.8,0.3)))
sprite.position = Vec3(0.0, 1.5, 0.0)
add!(scene, sprite)

cam = PerspectiveCamera(fov=pi/4, aspect=16/9)
cam.position = Vec3(4.0, 3.0, 6.0)
cam.target   = Vec3(0.0, 0.0, 0.0)

# Layered draw: triangles first, then the point/line/sprite overlays.
rt = RenderTarget(160, 90)
render!(rt, scene, cam; shading=:flat)   # instanced boxes
render_points!(rt, scene, cam)           # point cloud
render_lines!(rt, scene, cam)            # segments + loop
render_sprites!(rt, scene, cam)          # billboard

sm  = sprite_world_matrix(sprite, cam)                 # camera-facing world matrix
lit = count(>(0.05), sum(rt.color; dims=3))            # pixels that received color
println("OK objects: instances=", instanced_count(inst),
        " collected=", length(collect_instanced(scene)),
        " color5=", get_instance_color(inst, 5),
        " sprite_x=", round(mat4_get(sm, 1, 4); digits=3),
        " lit_px=", lit)
```

### LOD, Skinning & Layers

Diff3D.jl mirrors three.js's discrete level-of-detail, skeletal animation, and layer-bitmask systems. An `LOD` container swaps child objects by camera distance, a `Skeleton` of `Bone`s drives linear-blend `SkinnedMesh` deformation, and per-object `Layers` masks gate visibility on 32 independent channels.

```julia
# --- LOD: distance-keyed level of detail (three.js LOD) ---
lod = LOD(name="rock")
hi  = Mesh(IcosahedronGeometry(radius=1.0, detail=3), MeshBasicMaterial(); name="hi")
mid = Mesh(IcosahedronGeometry(radius=1.0, detail=1), MeshBasicMaterial(); name="mid")
lo  = Mesh(IcosahedronGeometry(radius=1.0, detail=0), MeshBasicMaterial(); name="lo")
add_lod_level!(lod, 0.0, hi)
add_lod_level!(lod, 8.0, mid; hysteresis=0.1)
add_lod_level!(lod, 20.0, lo)
lod_update!(lod, 12.0)                      # activates the mid level, hides the rest
println("LOD @12 -> ", lod_select(lod, 12.0).name, " (mid visible=", mid.visible, ")")

# --- Bone / Skeleton: capture a bind pose ---
root = Bone(name="root")
tip  = Bone(name="tip"); tip.position = Vec3(0.0, 1.0, 0.0)
add!(root, tip)
skel = Skeleton([root, tip])
calculate_inverses!(skel)                   # inverse bind matrices from current world pose
println("skeleton bones=", length(skeleton_matrices(skel)))

# --- SkinnedMesh: linear blend skinning across two bones ---
geo = PlaneGeometry(width=2.0, height=2.0)  # 4 vertices
idx = fill((1, 2, 1, 1), geo.n_vertices)    # blend bone 1 (root) and bone 2 (tip)
wts = fill((0.5, 0.5, 0.0, 0.0), geo.n_vertices)
skin = SkinnedMesh(geo, MeshBasicMaterial(), skel, idx, wts; name="banner")
bind_skeleton!(skin, skel)                  # rebind, recomputing inverse binds
rest = apply_skinning(skin)                 # deformed vertices at rest
tip.position = Vec3(2.0, 1.0, 0.0)          # pose the tip bone
posed = apply_skinning(skin)
println("skin vtx1 dx=", round(posed[1].x - rest[1].x; digits=3))  # 0.5 weight * 2.0 shift

# --- Layers: three.js channel bitmask ---
lyr = object_layers(skin)                   # per-object mask, default channel 0
layers_set!(lyr, 2)                         # occupy channel 2 only
layers_enable!(lyr, 5)                      # also channel 5
layers_disable!(lyr, 2)                     # drop channel 2
layers_toggle!(lyr, 0)                      # channel 0 back on
cam = layers_set!(Layers(), 5)              # a camera watching channel 5
println("layers share ch5: ", layers_test(lyr, cam))
println("OK lod")
```

### Raycasting

Diff3D's `Raycaster` mirrors three.js: aim a world-space ray (directly or via `set_from_camera!` through NDC screen coordinates), then `raycast` a scene or object tree to get `Intersection`s sorted nearest-first. The lower-level `ray_triangle_intersect` exposes the Möller–Trumbore test used internally.

```julia

# Build a small scene: two unit cubes in front of the camera along -Z.
scene = Scene()
near_cube = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                 MeshBasicMaterial(color=Color3(1.0, 0.3, 0.3), side=:double); name="near")
far_cube  = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                 MeshBasicMaterial(color=Color3(0.3, 0.3, 1.0), side=:double); name="far")
near_cube.position = Vec3(0.0, 0.0, 0.0)
far_cube.position  = Vec3(0.0, 0.0, -4.0)
add!(scene, near_cube); add!(scene, far_cube)

# Camera at +Z looking down -Z; aim the ray through screen-center NDC (0, 0).
camera = PerspectiveCamera(fov=pi / 4, aspect=1.0, near=0.1, far=100.0)
camera.position = Vec3(0.0, 0.0, 5.0)
camera.target   = Vec3(0.0, 0.0, 0.0)

rc = Raycaster(camera.position, camera.target - camera.position;
               near=camera.near, far=camera.far)
set_from_camera!(rc, camera, 0.0, 0.0)

# raycast returns Intersections sorted nearest-first, filtered to [near, far].
hits = raycast(rc, scene; recursive=true)
hit = first(hits)   # nearest Intersection: fields distance, point, object, face_index
println("hits=", length(hits), "  nearest=", hit.object.name,
        "  face=", hit.face_index,
        "  dist=", round(hit.distance, digits=4),
        "  point=", hit.point)

# Direct Möller–Trumbore test against one Triangle's vertices.
tri = Triangle(Vec3(-1.0, -1.0, 0.0), Vec3(1.0, -1.0, 0.0), Vec3(0.0, 1.0, 0.0))
t = ray_triangle_intersect(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, -1.0),
                           tri.a, tri.b, tri.c; side=:double)
println("triangle hit t=", t)
println("OK raycast")
```

### Controls & Animation

Diff3D ships headless counterparts of the three.js `examples/` control rigs, a `Clock`, and a keyframe animation system. All of them mutate a camera or object in place, so you can drive interaction, timing, and animation programmatically and read the resulting state back out.

```julia
# --- OrbitControls with inertia: queue moves, ease to a stop via orbit_update! ---
cam = PerspectiveCamera(fov=π/4, aspect=16/9)
cam.position = Vec3(0.0, 0.0, 6.0)
orbit = OrbitControls(cam, Vec3(0.0, 0.0, 0.0); enable_damping=true, damping_factor=0.1)
orbit_rotate!(orbit, π/4, 0.25)   # queue azimuth / polar deltas (radians)
orbit_zoom!(orbit, 0.6)           # queue a dolly-in (factor < 1)
orbit_pan!(orbit, 0.2, 0.1)       # queue a screen-space pan
for _ in 1:250; orbit_update!(orbit); end   # damped residual converges
println("orbit  -> ", round.((cam.position.x, cam.position.y, cam.position.z), digits=3))

# --- TrackballControls / FlyControls share the same camera basis ---
trackball_rotate!(TrackballControls(cam), 0.15, -0.1)
fly = FlyControls(cam)
fly_translate!(fly, 0.5, 0.2, 0.0)   # move along forward / right / up
fly_rotate!(fly, 0.1, 0.05)          # yaw / pitch in place
println("fly    -> ", round.((cam.position.x, cam.position.y, cam.position.z), digits=3))

# --- Object controls: world-space drag, then a transform gizmo (rotate + translate) ---
cube = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
            MeshBasicMaterial(color=Color3(1.0, 0.45, 0.2)); name="cube")
drag = DragControls([cube], cam)
drag_start!(drag, cube); drag_move!(drag, Vec3(0.5, 0.0, -0.5)); drag_end!(drag)
gizmo = TransformControls(cam)
transform_attach!(gizmo, cube)
transform_set_mode!(gizmo, :rotate);    transform_apply!(gizmo, Vec3(0.0, π/2, 0.0))
transform_set_mode!(gizmo, :translate); transform_apply!(gizmo, Vec3(0.0, 1.0, 0.0))
println("cube   -> pos ", (cube.position.x, cube.position.y, cube.position.z),
        " rot.y ", round(cube.rotation.y, digits=3))

# --- Clock: frame timing (explicit `now` keeps the doc run deterministic) ---
clk = Clock()
dt = clock_delta!(clk, clk.start_time + 1/60)
println("clock  -> dt ", round(dt, digits=4),
        " elapsed ", round(clock_elapsed(clk, clk.start_time + 0.5), digits=3))

# --- Keyframe animation: a mixer drives an object along a clip ---
mover = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
             MeshBasicMaterial(color=Color3(0.2, 0.6, 1.0)); name="mover")
clip = AnimationClip("demo", 2.0, AbstractKeyframeTrack[
    NumberKeyframeTrack(mover, "position[y]", [0.0, 1.0, 2.0], [0.0, 2.0, 0.0]),
    QuaternionKeyframeTrack(mover, :quaternion, [0.0, 1.0, 2.0],
        [Quaternion(), quat_from_euler(0.0, π, 0.0), quat_from_euler(0.0, 2π, 0.0)]),
]; loop=:repeat)
mixer = AnimationMixer(clip)
mixer_set_time!(mixer, 0.5)          # sample an absolute clip time
println("mixer  -> t=0.5 y=", round(mover.position.y, digits=3),
        " rot.y=", round(mover.rotation.y, digits=3))
mixer_update!(mixer, 0.5)            # advance by dt to t=1.0
println("mixer  -> t=1.0 y=", round(mover.position.y, digits=3))

# --- Line-based scene helpers ---
axes = AxesHelper(2.0); grid = GridHelper(10.0, 10); bbox = BoxHelper(mover)
println("helper -> ", (axes.geometry.n_vertices, grid.geometry.n_vertices, bbox.geometry.n_vertices))
println("OK controls")
```

### Differentiable Rendering & Inverse

Diff3D ships a fully differentiable soft rasterizer whose RGB output is smooth with respect to vertices, per-face materials, and camera, so image-space losses can be back-propagated to scene parameters. Gradients flow through either ForwardDiff duals or the package's own reverse-mode `ADVar` tape, and the `inverse_render_*` optimizers drive a rendered image toward a target — here recovering a cube's per-face colors from a single view.

```julia
using ForwardDiff

# A cube with one differentiable RGB color per triangular face.
geo   = BoxGeometry(width = 1.6, height = 1.6, depth = 1.6)
verts = [get_vertex(geo, i) for i in 1:geo.n_vertices]
faces = [get_face(geo, i)   for i in 1:geo.n_faces]
nf    = geo.n_faces

# Fixed camera -> combined view-projection matrix (parametric so AD duals flow).
view_proj(T) = projection_matrix_from_params(T(pi/4), one(T), T(0.1), T(100)) *
               view_matrix_from_params(T(2.4), T(1.8), T(3.0),
                                       zero(T), zero(T), zero(T),
                                       zero(T), one(T), zero(T))

# Differentiable soft rasterization from a flat per-face color vector.
function render_params(p::AbstractVector{T}, npx::Int) where {T}
    vts = [Vec3(T(v.x), T(v.y), T(v.z)) for v in verts]
    cls = [Color3(p[3i-2], p[3i-1], p[3i]) for i in 1:nf]
    cfg = SoftRasterizerConfig(sigma = T(0.7), gamma = one(T),
                               bg_color = Color3(T(0.08), T(0.09), T(0.12)), eps = T(1e-8))
    soft_render(vts, faces, cls, view_proj(T), npx, npx, cfg)
end

W       = 28
target  = Float64[0.5 + 0.4*sin(2pi*(i-1)/nf + φ) for i in 1:nf for φ in (0.0, 2.1, 4.2)]
tgt_img = render_params(target, W)
init    = fill(0.5, 3nf)

# Image-space losses (all ForwardDiff-friendly).
img0 = render_params(init, W)
println("losses  mse=", round(loss_mse(img0, tgt_img); sigdigits=3),
        " l1=",   round(loss_l1(img0, tgt_img); sigdigits=3),
        " ssim=", round(loss_ssim(img0, tgt_img); sigdigits=3),
        " iou=",  round(loss_silhouette_iou(img0, tgt_img); sigdigits=3))

# Forward-mode gradient of the loss vs. a finite-difference oracle.
objective(p) = loss_mse(render_params(p, W), tgt_img)
g_fd  = ForwardDiff.gradient(objective, init)
g_num = numerical_gradient(objective, init)
@assert maximum(abs, g_fd .- g_num) < 1e-3
println("forward vs numerical grad  max|Δ| = ", round(maximum(abs, g_fd .- g_num); sigdigits=3))

# Reverse-mode AD: an ADVar tape gives value + gradient of a scalar in one backward pass.
f(x) = sin(x[1]) * exp(0.5x[2]) + x[3]^2
x0   = [0.3, -0.4, 1.2]
val, g_rev = reverse_value_gradient(f, x0)
@assert reverse_gradient(f, x0) ≈ g_rev ≈ ForwardDiff.gradient(f, x0)
println("reverse-AD  f=", round(val; sigdigits=4), "  grad=", round.(g_rev; sigdigits=3))

# Inverse rendering: recover the per-face materials (Adam + vanilla gradient descent).
est, hist   = inverse_render_adam(copy(init), tgt_img, p -> render_params(p, W),
                                  loss_mse; lr = 0.06, n_iters = 40, verbose = false)
_,  hist_gd = inverse_render_optimize(copy(init), tgt_img, p -> render_params(p, W),
                                      loss_mse; lr = 0.5, n_iters = 20, verbose = false)
@assert hist[end] < hist[1] && hist_gd[end] < hist_gd[1]
println("inverse  adam ", round(hist[1]; sigdigits=3), " -> ", round(hist[end]; sigdigits=3),
        " | gd ", round(hist_gd[1]; sigdigits=3), " -> ", round(hist_gd[end]; sigdigits=3),
        "   OK diff")
```

### Image & Mesh I/O

Diff3D ships pure-Julia readers and writers for the common image and mesh formats, so a rendered `H×W×3` buffer can be exported to PNG, PPM, or PDF, and meshes can round-trip through STL, OBJ, PLY, and XYZ without any external dependencies. Larger binary assets (HDR, EXR, JPEG, KTX2, glTF/GLB) load from file paths.

```julia
dir = mktempdir()  # all written files stay contained here

# --- Image export: a rendered H×W×3 buffer in [0,1] -> PNG / PPM / PDF ---
img = test_pattern(32, 24)                       # 24×32×3 Float64 in [0,1]
save_png(joinpath(dir, "frame.png"), img)        # 8-bit RGB PNG (pure Julia)
save_ppm(joinpath(dir, "frame.ppm"), img)        # portable pixmap, no deps
save_pdf(joinpath(dir, "frame.pdf"), img; dpi=150) # single-page PDF XObject
save_png16(joinpath(dir, "depth.png"), img[:, :, 1])            # 16-bit grayscale
rgba = cat(img, fill(0.8, 24, 32); dims=3)
save_png_rgba(joinpath(dir, "frame_rgba.png"), rgba)           # 8-bit RGBA

# PNG round-trip: decode back to an H×W×3 array in [0,1]
decoded = load_png(joinpath(dir, "frame.png"))
@assert size(decoded) == (24, 32, 3)

# --- STL round-trip: build a tetrahedron, write binary STL, reload ---
positions = [0.0,0.0,0.0, 1.0,0.0,0.0, 0.0,1.0,0.0, 0.0,0.0,1.0]
faces = [1,2,3, 1,4,2, 1,3,4, 2,4,3]
tetra = BufferGeometry(positions, Float64[], Float64[], faces, 4, 4)
save_stl_binary(joinpath(dir, "tetra.stl"), tetra)
mesh = load_stl(joinpath(dir, "tetra.stl"))
compute_vertex_normals!(mesh)                    # smooth per-vertex normals

# --- OBJ (+ MTL + groups) from an in-code string ---
write(joinpath(dir, "mat.mtl"), "newmtl red\nKd 0.8 0.1 0.1\nNs 40\n")
write(joinpath(dir, "tri.obj"), """
mtllib mat.mtl
usemtl red
v 0 0 0
v 1 0 0
v 0 1 0
vt 0 0
vt 1 0
vt 0 1
vn 0 0 1
f 1/1/1 2/2/1 3/3/1
""")
obj = load_obj(joinpath(dir, "tri.obj"))
grp_geo, face_mtls, mats = load_obj_groups(joinpath(dir, "tri.obj"))
mtls = load_mtl(joinpath(dir, "mat.mtl"))

# --- PLY (ASCII, with per-vertex color) ---
write(joinpath(dir, "tri.ply"), """
ply
format ascii 1.0
element vertex 3
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
element face 1
property list uchar int vertex_indices
end_header
0 0 0 255 0 0
1 0 0 0 255 0
0 1 0 0 0 255
3 0 1 2
""")
ply = load_ply(joinpath(dir, "tri.ply"))

# --- XYZ point cloud: parse a string, and load from disk ---
cloud = parse_xyz("0 0 0 255 0 0\n1 1 1 0 255 0\n2 0 1 0 0 255\n")
write(joinpath(dir, "pts.xyz"), "0 0 0\n1 2 3\n4 5 6\n")
disk_cloud = load_xyz(joinpath(dir, "pts.xyz"))

# --- Binary asset loaders take a file path; not run in this doc harness ---
# env  = load_hdr("studio.hdr")        # Radiance RGBE -> H×W×3 linear HDR
# exr  = load_exr("render.exr")        # OpenEXR half/float
# tex  = load_jpeg("albedo.jpg")       # baseline JPEG -> H×W×3 in [0,1]
# ktx  = load_ktx2("cubemap.ktx2")     # KTX2 uncompressed formats
# scene = load_gltf("model.gltf")      # glTF -> Scene (load_glb for .glb)

println("OK io: png $(size(decoded)), stl faces=$(mesh.n_faces), ",
        "obj v=$(obj.n_vertices), ply faces=$(ply.n_faces), ",
        "cloud pts=$(cloud.n_vertices), mtls=$(collect(keys(mtls)))")
```

### Interactive WebGL HTML Export

Diff3D.jl can serialize a scene into a standalone, interactive WebGL page: wrap a `Scene` (plus optional camera, tone mapping, clipping planes, and animation clips) in a `WebGLExportCase`, then pass a vector of cases to `save_webgl_html` to write a single self-contained `.html` file with a small embedded runtime.

```julia

# Build a lit scene from Diff3D.jl objects, geometries, and materials.
scene = Scene(background=Color3(0.02, 0.03, 0.05))
add!(scene, AmbientLight(color=Color3(0.3, 0.34, 0.4), intensity=0.6))
add!(scene, DirectionalLight(color=Color3(1.0, 0.95, 0.85), intensity=1.2,
                             position=Vec3(4.0, 6.0, 3.0)))

floor = Mesh(PlaneGeometry(width=12.0, height=12.0),
             MeshStandardMaterial(color=Color3(0.4, 0.42, 0.46), roughness=0.9))
floor.rotation = Euler(-pi/2, 0.0, 0.0)
add!(scene, floor)

hero = Mesh(TorusKnotGeometry(radius=1.0, tube=0.32),
            MeshStandardMaterial(color=Color3(0.2, 0.8, 1.0), metalness=0.3, roughness=0.35);
            name="hero")
hero.position = Vec3(0.0, 1.2, 0.0)
add!(scene, hero)

# A keyframe animation that the browser runtime plays back.
spin = QuaternionKeyframeTrack(hero, :rotation, [0.0, 2.0, 4.0],
    [Quaternion(), quat_from_euler(0.0, pi, 0.0), quat_from_euler(0.0, 2pi, 0.0)])
clip = AnimationClip("spin", AbstractKeyframeTrack[spin])

# An explicit camera plus tone mapping and a section-cut clipping plane.
cam = PerspectiveCamera(fov=45pi/180, aspect=16/9, near=0.1, far=100.0)
case = WebGLExportCase("hero", "Interactive Hero", "TorusKnot exported to live WebGL.",
                       scene; camera=cam, target=Vec3(0.0, 1.0, 0.0), radius=7.0,
                       tone_mapping=:aces, output_color_space=:srgb,
                       clipping_planes=[Plane(Vec3(0.0, 1.0, 0.0), 0.0)],
                       animations=[clip])

# save_webgl_html takes a Vector of cases and writes a self-contained HTML file.
out = joinpath(tempdir(), "diff3d_webgl_demo.html")
save_webgl_html(out, [case]; title="Diff3D.jl WebGL Demo")

bytes = filesize(out)
println("OK webgl: wrote $(bytes) bytes to $(out)")
```

## Verification

```julia
using Pkg
Pkg.test("Diff3D")
```

The repository also includes a browser smoke test for generated WebGL output:

```powershell
python examples/browser_webgl_smoke.py examples/output/live_webgl_showcase.html
```

To verify every non-planned entry in `examples/examples_registry.toml`, run:

```powershell
python examples/verify_examples_registry.py
```

The gallery-style example includes an animated robot, material turntable,
instancing scene, particle scene, and runtime playback controls:

```powershell
julia --project=. examples/example_gallery.jl
python examples/browser_webgl_smoke.py examples/output/example_gallery.html
```

The published documentation includes the generated gallery on the
[Example Gallery](@ref) page.
