# --------------------------------------------------------------------------
# Shadow mapping: render scene depth from a light's viewpoint, then test shaded
# points against that depth map. Directional lights use an orthographic light
# camera sized to the scene; spot lights use a perspective light camera; point
# lights use six 90-degree perspective cameras (a cube shadow map, as three.js
# PointLightShadow renders).
# --------------------------------------------------------------------------

# Cube faces in three.js order with its per-face up vectors
# (src/renderers/webgl/WebGLShadowMap.js `_cubeDirections` / `_cubeUps`).
const _POINT_SHADOW_DIRECTIONS = (
    Vec3(1.0, 0.0, 0.0), Vec3(-1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0),
    Vec3(0.0, -1.0, 0.0), Vec3(0.0, 0.0, 1.0), Vec3(0.0, 0.0, -1.0))
const _POINT_SHADOW_UPS = (
    Vec3(0.0, -1.0, 0.0), Vec3(0.0, -1.0, 0.0), Vec3(0.0, 0.0, 1.0),
    Vec3(0.0, 0.0, -1.0), Vec3(0.0, -1.0, 0.0), Vec3(0.0, -1.0, 0.0))

# Light origin and the six face view-projections of a point-light cube map.
# Heap-allocated so `ShadowMap` stores a pointer rather than inlining ~800 bytes
# into every directional and spot map.
mutable struct _PointShadowCube
    const origin::Vec3{Float64}
    const face_vps::NTuple{6, Mat4{Float64}}
end

"""
    ShadowMap(depth, light_vp, bias, pcf_radius=0; intensity=1.0, normal_bias=0.0)

Light-space depth map queried by [`shadow_visibility`](@ref). `depth` holds NDC
depth from the light (smaller is nearer, `Inf` marks an empty texel) sampled
through the view-projection `light_vp`; `bias` is subtracted from a receiver's
NDC depth before the comparison and `pcf_radius` selects percentage-closer
filtering.

`intensity` (three.js `LightShadow.intensity`, in `[0, 1]`) scales how dark the
shadow is: a query returns `mix(1, lit_fraction, intensity)`. `normal_bias`
(three.js `LightShadow.normalBias`, world units) offsets a query point along the
surface normal passed to [`shadow_visibility`](@ref) before the depth test.

[`compute_shadow_map`](@ref) returns a cube map for a `PointLight`: `depth` then
stores the six square faces side by side (`res × 6res`, faces ordered +X, -X,
+Y, -Y, +Z, -Z as in three.js), each rendered by its own 90° camera, and
`light_vp` is the +X face camera.
"""
struct ShadowMap
    depth::Matrix{Float64}      # NDC depth from the light (smaller = nearer light); Inf = empty
    light_vp::Mat4{Float64}     # light view-projection (+X face camera for a cube map)
    bias::Float64
    pcf_radius::Int             # percentage-closer-filtering radius r; 0 = hard shadow
    cube::Union{Nothing, _PointShadowCube}   # point-light cube faces; nothing = single 2D map
    intensity::Float64          # three.js LightShadow.intensity
    normal_bias::Float64        # three.js LightShadow.normalBias (world units)

    function ShadowMap(depth::Matrix{Float64}, light_vp::Mat4{Float64}, bias, pcf_radius;
                       intensity=1.0, normal_bias=0.0)
        !isempty(depth) || throw(ArgumentError("ShadowMap depth must be non-empty"))
        all(isfinite, light_vp.e) || throw(ArgumentError("ShadowMap light_vp must be finite"))
        b = _validated_shadow_bias(bias)
        b === nothing && throw(ArgumentError("ShadowMap bias must be finite"))
        pcf = _validated_shadow_pcf_radius(pcf_radius)
        pcf === nothing && throw(ArgumentError("ShadowMap pcf_radius must be an integer"))
        return new(depth, light_vp, b, pcf, nothing,
                   _validated_shadow_intensity(intensity),
                   _validated_shadow_normal_bias(normal_bias))
    end

    # Point-light cube map; only built by the shadow pass.
    function ShadowMap(depth::Matrix{Float64}, cube::_PointShadowCube, bias::Float64,
                       pcf_radius::Int, intensity::Float64, normal_bias::Float64,
                       ::Val{:cube})
        res = size(depth, 1)
        res > 0 && size(depth, 2) == 6res ||
            throw(ArgumentError("cube ShadowMap depth must be res × 6res"))
        origin = cube.origin
        isfinite(origin.x) && isfinite(origin.y) && isfinite(origin.z) ||
            throw(ArgumentError("ShadowMap light position must be finite"))
        for vp in cube.face_vps
            all(isfinite, vp.e) || throw(ArgumentError("ShadowMap light_vp must be finite"))
        end
        return new(depth, cube.face_vps[1], bias, pcf_radius, cube,
                   _validated_shadow_intensity(intensity),
                   _validated_shadow_normal_bias(normal_bias))
    end
end

ShadowMap(depth::Matrix{Float64}, light_vp::Mat4, bias, pcf_radius; kwargs...) =
    ShadowMap(depth, convert(Mat4{Float64}, light_vp), bias, pcf_radius; kwargs...)

# Backward-compatible constructor: existing 3-arg callers get a hard shadow (r=0),
# matching the original single-sample depth comparison byte-for-byte.
ShadowMap(depth::Matrix{Float64}, light_vp::Mat4{Float64}, bias::Float64) =
    ShadowMap(depth, light_vp, bias, 0)
ShadowMap(depth::Matrix{Float64}, light_vp::Mat4, bias) =
    ShadowMap(depth, light_vp, bias, 0)

struct _ShadowQuery{M}
    maps::M
end

@inline function (query::_ShadowQuery)(light, p::Vec3)
    maps = query.maps
    return haskey(maps, light) ? shadow_visibility(maps[light], p) : 1.0
end

@inline function (query::_ShadowQuery)(light, p::Vec3, normal::Vec3)
    maps = query.maps
    return haskey(maps, light) ? shadow_visibility(maps[light], p; normal=normal) : 1.0
end

# Shading-side entry: built-in shadow queries also receive the surface normal
# for `normal_bias`; a caller-supplied `shadow_fn(light, position)` keeps its
# two-argument form.
@inline _shadow_fn_visibility(shadow_fn, light, p::Vec3, normal::Vec3) =
    shadow_fn(light, p)
@inline _shadow_fn_visibility(query::_ShadowQuery, light, p::Vec3, normal::Vec3) =
    query(light, p, normal)

function _validated_shadow_resolution(resolution::Int)
    resolution > 0 || throw(ArgumentError("shadow resolution must be positive"))
    return resolution
end

function _expand_shadow_bounds!(box::Box3, geo, world::Mat4)
    for face_index in _draw_face_range(geo)
        first_entry = 3face_index - 2
        for entry in first_entry:(first_entry + 2)
            vi = _draw_vertex_index(geo, entry)
            p = mat4_transform_point(world, get_vertex(geo, vi))
            isfinite(p.x) && isfinite(p.y) && isfinite(p.z) || continue
            box = box3_expand_by_point(box, p)
        end
    end
    return box
end

_valid_shadow_box(box::Box3) =
    isfinite(box.min.x) && isfinite(box.min.y) && isfinite(box.min.z) &&
    isfinite(box.max.x) && isfinite(box.max.y) && isfinite(box.max.z) &&
    box.min.x <= box.max.x && box.min.y <= box.max.y && box.min.z <= box.max.z

# World-space bounding sphere of visible drawables. The public visibility query
# may be evaluated at any visible surface, regardless of its receive flag.
function _scene_bounds(meshes, instanced)
    box = Box3()
    for mesh in meshes
        is_visible(mesh) || continue
        box = _expand_shadow_bounds!(box, mesh.geometry, compute_world_matrix(mesh))
    end
    for im in instanced
        # collect_instanced traverses without pruning invisible subtrees.
        _visible_in_tree(im) || continue
        _instanced_triangle_drawable(im) || continue
        base = compute_world_matrix(im)
        for M in im.instance_matrices
            box = _expand_shadow_bounds!(box, im.geometry, base * M)
        end
    end
    _valid_shadow_box(box) || return (Vec3(), 1e-3)
    center = Vec3(
        _geometry_midpoint(box.min.x, box.max.x),
        _geometry_midpoint(box.min.y, box.max.y),
        _geometry_midpoint(box.min.z, box.max.z),
    )
    radius = norm(box.max - center)
    return (center, max(radius, 1e-3))
end

_safe_up(dir::Vec3) = abs(dir.y) > 0.99 ? Vec3(1.0, 0.0, 0.0) : Vec3(0.0, 1.0, 0.0)

function _shadow_direction(from::Vec3, to::Vec3)
    direction = to - from
    if isfinite(direction.x) && isfinite(direction.y) &&
       isfinite(direction.z)
        return normalize(direction)
    end
    scaled, _, nonzero =
        _difference_direction_and_logscale(from, to)
    return nonzero ? normalize(scaled) : normalize(direction)
end

function _light_view_proj(light::DirectionalLight, center::Vec3, radius)
    light_position = _light_world_position(light)
    dir = light.rotation_driven ? -_light_emission_direction(light) :
          _shadow_direction(light.target, light_position) # toward the light
    eye = center + dir * (radius * 2.0)
    lv = mat4_look_at(eye, center, _safe_up(dir))
    s = radius * 1.1
    # Scale near with the scene radius: the eye sits at distance 2·radius, so the
    # casters span [radius, 3·radius] from it. A hardcoded near=0.01 exceeds
    # far (radius*4) and clips the whole scene once radius < 0.0025; radius*1e-2
    # keeps near < closest caster < farthest caster < far at every scene scale
    # (and equals the old 0.01 at the common radius≈1).
    lp = mat4_orthographic(-s, s, -s, s, radius * 1e-2, radius * 4.0)
    return lp * lv
end

# Fit the near/far planes of a square perspective light camera (view matrix
# `lv`, half field of view with tangent `tan_half_fov`) to the bounding sphere,
# so NDC depth precision (and the fixed bias) stays meaningful at any light
# distance without clipping casters. Two lower bounds on the view depth z of a
# sphere point inside the frustum hold for any aim: z >= zc - radius (zc = view
# depth of the centre, read from `lv` itself so degenerate aims stay
# consistent), and z >= |p - light| / sqrt(1 + 2 tan^2) >= (d - radius) / ... since
# the frustum's corner rays are the most oblique. Using only the first under-fits
# near for cameras aimed away from the centre (cube faces, off-axis spots).
# `caster_distance` is a lower bound on the distance from the light to every
# shadow caster (`_shadow_caster_distance`); the same corner argument turns it
# into a bound on their view depth. Without it a light inside the bounding sphere
# fell back to near = radius/100, and the fixed NDC `bias` then spanned a
# world-space depth of about bias*z^2/(2 near): a 3e-3 bias erased the shadow of
# a 0.1-thick tile three units below a light in a 10-unit room.
# The floor keeps `near` positive (and the near/far ratio bounded) when the
# light sits inside the bounding sphere and touches a caster.
function _perspective_shadow_planes(lv::Mat4, light_pos::Vec3, center::Vec3, radius,
                                    tan_half_fov, caster_distance=0.0)
    d = norm(light_pos - center)
    zc = -mat4_transform_point(lv, center).z
    corner_scale = sqrt(1 + 2 * tan_half_fov^2)
    corner = (d - radius) / corner_scale
    near = max(zc - radius, corner, caster_distance / corner_scale,
               max(radius, d) * 1e-2)
    far = max(zc + radius, near * (1 + 1e-6))
    return (near, far)
end

_light_view_proj(light::DirectionalLight, center::Vec3, radius, caster_distance) =
    _light_view_proj(light, center, radius)

function _light_view_proj(light::SpotLight, center::Vec3, radius, caster_distance=0.0)
    light_position = _light_world_position(light)
    direction = light.rotation_driven ? _light_emission_direction(light) :
                _shadow_direction(light_position, light.target)
    lv = light.rotation_driven ? _view_from_direction(light_position, direction, _safe_up(direction)) :
         mat4_look_at(light_position, light.target, _safe_up(direction))
    fov = min(light.angle * 2.0, π * 0.9)
    near, far = _perspective_shadow_planes(lv, light_position, center, radius, tan(fov / 2),
                                           caster_distance)
    lp = mat4_perspective(fov, 1.0, near, far)
    return lp * lv
end

# Single 90-degree frustum aimed at the scene centre. The CPU shadow pass uses
# the full cube (`_point_shadow_cube`); this one-map form serves the WebGL
# static export, which stores one 2D depth texture per light.
function _light_view_proj(light::PointLight, center::Vec3, radius, caster_distance=0.0)
    light_position = _light_world_position(light)
    dir = _shadow_direction(light_position, center)
    lv = mat4_look_at(light_position, center, _safe_up(dir))
    near, far = _perspective_shadow_planes(lv, light_position, center, radius, 1.0,
                                           caster_distance)
    lp = mat4_perspective(π/2, 1.0, near, far)
    return lp * lv
end

# Six 90-degree cameras at the light (three.js PointLightShadow, rendered per
# face by WebGLShadowMap.js). Each face fits its own near/far planes to the
# scene bounding sphere. The view is built from the axis itself rather than
# `origin + axis`, which rounds back to `origin` for distant lights.
function _point_shadow_cube(light::PointLight, center::Vec3, radius, caster_distance=0.0)
    origin = _light_world_position(light)
    face_vps = ntuple(Val(6)) do face
        lv = _view_from_direction(origin, _POINT_SHADOW_DIRECTIONS[face],
                                  _POINT_SHADOW_UPS[face])
        near, far = _perspective_shadow_planes(lv, origin, center, radius, 1.0,
                                               caster_distance)
        mat4_perspective(π/2, 1.0, near, far) * lv
    end
    return _PointShadowCube(origin, face_vps)
end

# Distance from `origin` to the axis-aligned box of a world-space triangle: a
# lower bound on the distance to every point of the triangle.
@inline function _shadow_triangle_box_distance(origin::Vec3, a::Vec3, b::Vec3, c::Vec3)
    dx = max(min(a.x, b.x, c.x) - origin.x, origin.x - max(a.x, b.x, c.x), 0.0)
    dy = max(min(a.y, b.y, c.y) - origin.y, origin.y - max(a.y, b.y, c.y), 0.0)
    dz = max(min(a.z, b.z, c.z) - origin.z, origin.z - max(a.z, b.z, c.z), 0.0)
    return sqrt(dx * dx + dy * dy + dz * dz)
end

mutable struct _ShadowCasterDistance
    const origin::Vec3{Float64}
    best::Float64
end

function _shadow_geometry_caster_distance!(state::_ShadowCasterDistance, geo,
                                           world::Mat4{Float64})
    origin = state.origin
    best = state.best
    for face_index in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, face_index)
        a = mat4_transform_point(world, get_vertex(geo, i1))
        b = mat4_transform_point(world, get_vertex(geo, i2))
        c = mat4_transform_point(world, get_vertex(geo, i3))
        distance = _shadow_triangle_box_distance(origin, a, b, c)
        # A non-finite vertex leaves no usable bound; zero falls back to the
        # radius-relative floor of `_perspective_shadow_planes`.
        isfinite(distance) || (best = 0.0; break)
        best = min(best, distance)
    end
    state.best = best
    return nothing
end

# Mesh geometry is untyped; these barriers take only heap references so the
# per-drawable dynamic call does not box a matrix or a return value.
_shadow_mesh_caster_distance!(state::_ShadowCasterDistance, geo, mesh) =
    _shadow_geometry_caster_distance!(state, geo, compute_world_matrix(mesh))

function _shadow_instanced_caster_distance!(state::_ShadowCasterDistance, geo, im)
    base = compute_world_matrix(im)
    for M in im.instance_matrices
        _shadow_geometry_caster_distance!(state, geo, base * M)
    end
    return nothing
end

# Lower bound on the distance from `origin` to every triangle the shadow pass
# rasterizes (the casters `_raster_shadow_casters!` draws); 0 when unknown.
function _shadow_caster_distance(meshes, instanced, origin::Vec3{Float64})
    state = _ShadowCasterDistance(origin, Inf)
    for mesh in meshes
        is_visible(mesh) || continue
        object_casts_shadow(mesh) || continue
        _shadow_mesh_caster_distance!(state, mesh.geometry, mesh)
    end
    for im in instanced
        _visible_in_tree(im) || continue
        _instanced_triangle_drawable(im) || continue
        object_casts_shadow(im) || continue
        _shadow_instanced_caster_distance!(state, im.geometry, im)
    end
    best = state.best
    return isfinite(best) ? best : 0.0
end

# Cube face whose 90-degree frustum contains the light-to-point offset `d`:
# the face of its dominant axis (ties resolve to the earlier face, whose
# frustum boundary also contains the point).
@inline function _point_shadow_face(d::Vec3)
    ax = abs(d.x); ay = abs(d.y); az = abs(d.z)
    if ax >= ay && ax >= az
        return d.x >= 0 ? 1 : 2
    elseif ay >= az
        return d.y >= 0 ? 3 : 4
    end
    return d.z >= 0 ? 5 : 6
end

# Depth-only triangle rasterization into the shadow buffer. The optional material
# inputs mirror the color rasterizer's alpha-test and clipping discard paths.
@inline _shadow_depth_in_range(z) =
    isfinite(z) && -one(z) <= z <= one(z)

@inline function _raster_depth!(depth::AbstractMatrix{Float64}, W, H,
                                s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3;
                                clipping_planes=_NO_PLANES,
                                wp1::Vec3=_ZERO_V3, wp2::Vec3=_ZERO_V3, wp3::Vec3=_ZERO_V3,
                                iw1::Float64=1.0, iw2::Float64=1.0, iw3::Float64=1.0,
                                alpha_test::Float64=0.0, alpha_base::Float64=1.0,
                                albedo_map=nothing, alpha_map=nothing,
                                uv1::Vec2=_ZERO_V2, uv2::Vec2=_ZERO_V2, uv3::Vec2=_ZERO_V2,
                                uv2_1::Vec2=_ZERO_V2, uv2_2::Vec2=_ZERO_V2, uv2_3::Vec2=_ZERO_V2)
    # Skip triangles with a non-finite projected vertex (no raster footprint).
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    (isfinite(area) && abs(area) >= 1e-12) || return nothing
    inv_area = 1.0 / area
    # Clamp the float extent into [1, W]/[1, H] before the Int conversion so an
    # extreme-but-finite projected vertex cannot overflow floor/ceil(Int, …),
    # matching the color rasterizer's hardened bbox.
    fW = Float64(W); fH = Float64(H)
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1)
    max_x = min(ceil(Int,  clamp(max(s1x, s2x, s3x), 1.0, fW)), W)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1)
    max_y = min(ceil(Int,  clamp(max(s1y, s2y, s3y), 1.0, fH)), H)
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, alpha_base, albedo_map, alpha_map)
    @inbounds for py in min_y:max_y, px in min_x:max_x
        cx = px - 0.5; cy = py - 0.5
        w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
        w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
        w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
        if w0 >= 0 && w1 >= 0 && w2 >= 0
            if has_clip || has_alpha
                iw = w0 * iw1 + w1 * iw2 + w2 * iw3
                iw <= 0 && continue
                a0 = w0 * iw1 / iw; a1 = w1 * iw2 / iw; a2 = w2 * iw3 / iw
                if has_clip
                    wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                              a0*wp1.y + a1*wp2.y + a2*wp3.y,
                              a0*wp1.z + a1*wp2.z + a2*wp3.z)
                    _clip_keep(clipping_planes, wp) || continue
                end
                if has_alpha
                    u = a0*uv1.x + a1*uv2.x + a2*uv3.x
                    v = a0*uv1.y + a1*uv2.y + a2*uv3.y
                    u2 = a0*uv2_1.x + a1*uv2_2.x + a2*uv2_3.x
                    v2 = a0*uv2_1.y + a1*uv2_2.y + a2*uv2_3.y
                    _fragment_alpha(alpha_base, albedo_map, alpha_map, u, v, u2, v2) >= alpha_test ||
                        continue
                end
            end
            z = w0 * z1 + w1 * z2 + w2 * z3
            _shadow_depth_in_range(z) || continue
            z < depth[py, px] && (depth[py, px] = z)
        end
    end
    return nothing
end

@inline function _raster_depth_plain!(depth::AbstractMatrix{Float64}, W, H,
                                      s1x, s1y, z1, s2x, s2y, z2,
                                      s3x, s3y, z3)
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    (isfinite(area) && abs(area) >= 1e-12) || return nothing
    inv_area = 1.0 / area
    fW = Float64(W); fH = Float64(H)
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1)
    max_x = min(ceil(Int,  clamp(max(s1x, s2x, s3x), 1.0, fW)), W)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1)
    max_y = min(ceil(Int,  clamp(max(s1y, s2y, s3y), 1.0, fH)), H)
    @inbounds for py in min_y:max_y, px in min_x:max_x
        cx = px - 0.5; cy = py - 0.5
        w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
        w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
        w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
        if w0 >= 0 && w1 >= 0 && w2 >= 0
            z = w0 * z1 + w1 * z2 + w2 * z3
            _shadow_depth_in_range(z) || continue
            z < depth[py, px] && (depth[py, px] = z)
        end
    end
    return nothing
end

struct _ShadowClipVertex
    clip::Vec4{Float64}
    world::Vec3{Float64}
    uv::Vec2{Float64}
    uv2::Vec2{Float64}
end

@inline _shadow_near_distance(vertex::_ShadowClipVertex) =
    vertex.clip.z + vertex.clip.w

@inline function _shadow_lerp_clip(a::Vec4, b::Vec4, t)
    return Vec4(a.x + (b.x - a.x) * t,
                a.y + (b.y - a.y) * t,
                a.z + (b.z - a.z) * t,
                a.w + (b.w - a.w) * t)
end

@inline function _shadow_lerp_vertex(a::_ShadowClipVertex,
                                     b::_ShadowClipVertex, t)
    return _ShadowClipVertex(
        _shadow_lerp_clip(a.clip, b.clip, t),
        a.world + (b.world - a.world) * t,
        Vec2(a.uv.x + (b.uv.x - a.uv.x) * t,
             a.uv.y + (b.uv.y - a.uv.y) * t),
        Vec2(a.uv2.x + (b.uv2.x - a.uv2.x) * t,
             a.uv2.y + (b.uv2.y - a.uv2.y) * t),
    )
end

@inline function _shadow_clip_push(n::Int, vertex::_ShadowClipVertex,
                                   c1, c2, c3, c4)
    n += 1
    if n == 1
        c1 = vertex
    elseif n == 2
        c2 = vertex
    elseif n == 3
        c3 = vertex
    else
        c4 = vertex
    end
    return n, c1, c2, c3, c4
end

function _shadow_clip_near_triangle(a::_ShadowClipVertex,
                                    b::_ShadowClipVertex,
                                    c::_ShadowClipVertex)
    out_n = 0
    c1 = c2 = c3 = c4 = a
    previous = c
    previous_distance = _shadow_near_distance(previous)
    previous_inside = previous_distance >= 0.0
    @inbounds for current in (a, b, c)
        current_distance = _shadow_near_distance(current)
        current_inside = current_distance >= 0.0
        if current_inside != previous_inside
            t = previous_distance /
                (previous_distance - current_distance)
            out_n, c1, c2, c3, c4 = _shadow_clip_push(
                out_n, _shadow_lerp_vertex(previous, current, t),
                c1, c2, c3, c4)
        end
        if current_inside
            out_n, c1, c2, c3, c4 = _shadow_clip_push(
                out_n, current, c1, c2, c3, c4)
        end
        previous = current
        previous_distance = current_distance
        previous_inside = current_inside
    end
    return out_n, c1, c2, c3, c4
end

@inline function _shadow_clip_vertex(index::Int, c1, c2, c3, c4)
    index == 1 && return c1
    index == 2 && return c2
    index == 3 && return c3
    return c4
end

@inline function _shadow_project(vertex::_ShadowClipVertex, W::Int, H::Int)
    clip = vertex.clip
    clip.w > 0.0 || return (0.0, 0.0, 0.0, 0.0, false)
    inverse_w = 1.0 / clip.w
    return ((clip.x * inverse_w + 1.0) * 0.5 * W,
            (1.0 - clip.y * inverse_w) * 0.5 * H,
            clip.z * inverse_w, inverse_w, true)
end

function _raster_shadow_geometry!(depth::AbstractMatrix{Float64}, W::Int, H::Int,
                                  geo, world_mat::Mat4, mvp::Mat4, mat;
                                  clipping_planes=_NO_PLANES)
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    albedo_map = has_uvs ? _material_field(mat, :map) : nothing
    alpha_map = has_uvs ? _material_field(mat, :alpha_map) : nothing
    alpha_test = material_alpha_test(mat)
    alpha_base = Float64(material_opacity(mat))
    use_fragment_alpha = _needs_fragment_alpha(alpha_test, alpha_base, albedo_map, alpha_map)
    uv2_attr = use_fragment_alpha ? _uv2_attribute(geo) : nothing
    has_clip = !isempty(clipping_planes)
    for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        c1 = mat4_transform_vec4(mvp, _vh(v1))
        c2 = mat4_transform_vec4(mvp, _vh(v2))
        c3 = mat4_transform_vec4(mvp, _vh(v3))
        uv1 = _ZERO_V2; uv2v = _ZERO_V2; uv3 = _ZERO_V2
        uv2_1 = _ZERO_V2; uv2_2 = _ZERO_V2; uv2_3 = _ZERO_V2
        if use_fragment_alpha
            uv1 = has_uvs ? Vec2(geo.uvs[(i1-1)*2+1], geo.uvs[(i1-1)*2+2]) : _ZERO_V2
            uv2v = has_uvs ? Vec2(geo.uvs[(i2-1)*2+1], geo.uvs[(i2-1)*2+2]) : _ZERO_V2
            uv3 = has_uvs ? Vec2(geo.uvs[(i3-1)*2+1], geo.uvs[(i3-1)*2+2]) : _ZERO_V2
            uv2_1 = uv2_attr === nothing ? uv1 : Vec2(_vertex_uv_attr(uv2_attr, i1)...)
            uv2_2 = uv2_attr === nothing ? uv2v : Vec2(_vertex_uv_attr(uv2_attr, i2)...)
            uv2_3 = uv2_attr === nothing ? uv3 : Vec2(_vertex_uv_attr(uv2_attr, i3)...)
        end
        wp1 = has_clip ? mat4_transform_point(world_mat, v1) : _ZERO_V3
        wp2 = has_clip ? mat4_transform_point(world_mat, v2) : _ZERO_V3
        wp3 = has_clip ? mat4_transform_point(world_mat, v3) : _ZERO_V3
        vertex1 = _ShadowClipVertex(c1, wp1, uv1, uv2_1)
        vertex2 = _ShadowClipVertex(c2, wp2, uv2v, uv2_2)
        vertex3 = _ShadowClipVertex(c3, wp3, uv3, uv2_3)
        clipped_count, clip1, clip2, clip3, clip4 =
            _shadow_clip_near_triangle(vertex1, vertex2, vertex3)
        clipped_count >= 3 || continue
        for index in 2:(clipped_count - 1)
            a = clip1
            b = _shadow_clip_vertex(index, clip1, clip2, clip3, clip4)
            c = _shadow_clip_vertex(index + 1, clip1, clip2, clip3, clip4)
            s1x, s1y, z1, iw1, ok1 = _shadow_project(a, W, H)
            s2x, s2y, z2, iw2, ok2 = _shadow_project(b, W, H)
            s3x, s3y, z3, iw3, ok3 = _shadow_project(c, W, H)
            (ok1 && ok2 && ok3) || continue
            if has_clip || use_fragment_alpha
                _raster_depth!(depth, W, H,
                    s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3;
                    clipping_planes=clipping_planes,
                    wp1=a.world, wp2=b.world, wp3=c.world,
                    iw1=iw1, iw2=iw2, iw3=iw3,
                    alpha_test=alpha_test, alpha_base=alpha_base,
                    albedo_map=albedo_map, alpha_map=alpha_map,
                    uv1=a.uv, uv2=b.uv, uv3=c.uv,
                    uv2_1=a.uv2, uv2_2=b.uv2, uv2_3=c.uv2)
            else
                _raster_depth_plain!(depth, W, H,
                    s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3)
            end
        end
    end
    return depth
end

# Columns of a light's depth matrix: a point-light cube stores six square faces.
@inline _shadow_depth_columns(light, res::Int, cube::Bool) =
    cube && light isa PointLight ? 6res : res

# Mesh geometry and material fields are untyped, so each drawable costs one
# dynamic call. Rendering every view of the light (one map, or the six cube
# faces stored side by side in `depth`) behind that single call keeps the cube
# from multiplying the per-mesh dispatch work and allocation by six.
function _raster_shadow_casters!(depth::Matrix{Float64}, res::Int, meshes, instanced,
                                 vps::Vector{Mat4{Float64}}, clipping_planes)
    for mesh in meshes
        is_visible(mesh) || continue
        object_casts_shadow(mesh) || continue
        _raster_shadow_views!(depth, res, vps, mesh.geometry, compute_world_matrix(mesh),
                              mesh.material, clipping_planes)
    end
    for im in instanced
        _visible_in_tree(im) || continue
        _instanced_triangle_drawable(im) || continue
        object_casts_shadow(im) || continue
        base = compute_world_matrix(im)
        for M in im.instance_matrices
            _raster_shadow_views!(depth, res, vps, im.geometry, base * M, im.material,
                                  clipping_planes)
        end
    end
    return depth
end

function _raster_shadow_views!(depth::Matrix{Float64}, res::Int, vps::Vector{Mat4{Float64}},
                               geo, world::Mat4{Float64}, mat, clipping_planes)
    mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                     material_clipping_planes(mat))
    for (view_index, vp) in enumerate(vps)
        columns = ((view_index - 1) * res + 1):(view_index * res)
        _raster_shadow_geometry!(view(depth, :, columns), res, res, geo, world, vp * world, mat;
                                 clipping_planes=mesh_clipping_planes)
    end
    return nothing
end

# `cube=false` renders a point light into one frustum aimed at the scene centre
# (the WebGL static export's single-texture format); otherwise point lights get
# the six-face cube map.
function _compute_shadow_map_from_drawables(meshes, instanced, light,
                                            depth::Matrix{Float64};
                                            resolution::Int=512, bias=nothing,
                                            pcf_radius=nothing,
                                            clipping_planes=_NO_PLANES,
                                            cube::Bool=true)
    _validate_light_object(light)
    res = _validated_shadow_resolution(resolution)
    point_cube = cube && light isa PointLight
    size(depth) == (res, _shadow_depth_columns(light, res, cube)) ||
        throw(ArgumentError("shadow depth scratch must match resolution"))
    for mesh in meshes
        _validate_triangle_geometry_indices(_mesh_geometry(mesh), "compute_shadow_map")
    end
    for im in instanced
        _validate_instanced_mesh(im, "compute_shadow_map")
        _instanced_triangle_drawable(im) || continue
        _validate_triangle_geometry_indices(_instanced_geometry(im), "compute_shadow_map")
    end
    fill!(depth, Inf)
    shadow_bias = bias === nothing ? _light_shadow_bias(light, 3e-3) :
                  _validated_shadow_bias(bias)
    pcf = pcf_radius === nothing ? _light_shadow_pcf_radius(light, 0) :
          _validated_shadow_pcf_radius(pcf_radius)
    pcf === nothing && (pcf = 0)
    has_caster = any(m -> is_visible(m) && object_casts_shadow(m), meshes) ||
                 any(im -> _visible_in_tree(im) && _instanced_triangle_drawable(im) &&
                           object_casts_shadow(im), instanced)
    intensity = _light_shadow_intensity(light)
    normal_bias = _light_shadow_normal_bias(light)
    has_caster ||
        return ShadowMap(depth, Mat4{Float64}(), shadow_bias, pcf;
                         intensity=intensity, normal_bias=normal_bias)
    center, radius = _scene_bounds(meshes, instanced)
    caster_distance = light isa DirectionalLight ? 0.0 :
        _shadow_caster_distance(meshes, instanced, _light_world_position(light))
    if point_cube
        faces = _point_shadow_cube(light, center, radius, caster_distance)
        _raster_shadow_casters!(depth, res, meshes, instanced, collect(faces.face_vps),
                                clipping_planes)
        return ShadowMap(depth, faces, shadow_bias, pcf, intensity, normal_bias, Val(:cube))
    end
    vp = _light_view_proj(light, center, radius, caster_distance)
    _raster_shadow_casters!(depth, res, meshes, instanced, [vp], clipping_planes)
    return ShadowMap(depth, vp, shadow_bias, pcf; intensity=intensity,
                     normal_bias=normal_bias)
end

function _compute_scene_shadow_map(scene, light, cube::Bool; resolution::Int=512,
                                   bias=nothing, pcf_radius=nothing,
                                   clipping_planes=_NO_PLANES)
    _validate_light_object(light)
    res = _validated_shadow_resolution(resolution)
    meshes = collect_meshes(scene)
    _prepare_morph_render_meshes!(meshes)
    _append_skinned_render_meshes!(meshes, scene)
    instanced = collect_instanced(scene)
    depth = Matrix{Float64}(undef, res, _shadow_depth_columns(light, res, cube))
    return _compute_shadow_map_from_drawables(meshes, instanced, light, depth;
        resolution=res, bias=bias, pcf_radius=pcf_radius, clipping_planes=clipping_planes,
        cube=cube)
end

"""
    compute_shadow_map(scene, light; resolution=512, bias=nothing, pcf_radius=nothing, clipping_planes=_NO_PLANES)

Render the scene's depth from `light`'s viewpoint into a [`ShadowMap`].

Directional and spot lights render one `resolution × resolution` map. A
`PointLight` renders a cube map, one `resolution × resolution` face per axis
direction, so casters on every side of the light shadow (three.js
`PointLightShadow`).

`pcf_radius` selects percentage-closer filtering (PCF) soft shadows when querying
the map with [`shadow_visibility`](@ref): a value `r` samples a `(2r+1)x(2r+1)`
neighbourhood of the depth map and returns the lit fraction in `[0,1]`. When
`pcf_radius` or `bias` is `nothing`, three.js-style per-light `shadow_pcf_radius`
or `shadow_bias` settings are used when present; otherwise the historical hard
shadow (`pcf_radius=0`) and `bias=3e-3` defaults are preserved.
"""
compute_shadow_map(scene, light; resolution::Int=512, bias=nothing, pcf_radius=nothing,
                   clipping_planes=_NO_PLANES) =
    _compute_scene_shadow_map(scene, light, true; resolution=resolution, bias=bias,
                              pcf_radius=pcf_radius, clipping_planes=clipping_planes)

# One 2D map per light, including point lights (aimed at the scene centre): the
# WebGL static export uploads a single depth texture per light.
_compute_single_shadow_map(scene, light; resolution::Int=512, bias=nothing,
                           pcf_radius=nothing, clipping_planes=_NO_PLANES) =
    _compute_scene_shadow_map(scene, light, false; resolution=resolution, bias=bias,
                              pcf_radius=pcf_radius, clipping_planes=clipping_planes)

@inline _vh(v::Vec3) = Vec4(v.x, v.y, v.z, 1.0)

"""
    shadow_visibility(sm, p; pcf_radius=sm.pcf_radius, normal=nothing)

Visibility of a world-space point from the shadow map's light: `1` lit, `0`
fully occluded. With `pcf_radius = r > 0`, a `(2r+1)x(2r+1)` neighbourhood of the
projected texel is sampled and the lit fraction in `[0,1]` is returned, giving a
soft penumbra (percentage-closer filtering, matching three.js `PCFShadowMap`).
The neighbourhood is clamped to the map bounds (to the sampled face of a
point-light cube map). `pcf_radius=0` reproduces the single-sample hard shadow
exactly.

The result is `mix(1, visibility, sm.intensity)` (three.js `getShadow`). When a
unit surface `normal` is given, the lookup point is first moved to
`p + normal * sm.normal_bias` (three.js `shadowmap_vertex`). The CPU renderers
pass the shaded surface normal, which includes any normal-map perturbation,
where three.js uses the interpolated vertex normal.
"""
function shadow_visibility(sm::ShadowMap, p::Vec3; pcf_radius::Int=sm.pcf_radius,
                           normal::Union{Nothing,Vec3}=nothing)
    r = _validated_shadow_pcf_radius(pcf_radius)::Int
    isfinite(p.x) && isfinite(p.y) && isfinite(p.z) ||
        throw(ArgumentError("shadow_visibility point must be finite"))
    if normal !== nothing && sm.normal_bias != 0.0
        p = p + normal * sm.normal_bias
        isfinite(p.x) && isfinite(p.y) && isfinite(p.z) ||
            throw(ArgumentError("shadow_visibility normal must be finite"))
    end
    H, W = size(sm.depth)
    cube = sm.cube
    visibility = if cube === nothing
        _shadow_lookup(sm.depth, sm.light_vp, sm.bias, r, p, 0, W, H)
    else
        face = _point_shadow_face(p - cube.origin)
        _shadow_lookup(sm.depth, cube.face_vps[face], sm.bias, r, p, (face - 1) * H, H, H)
    end
    intensity = sm.intensity
    intensity == 1.0 && return visibility
    # GLSL mix(1, shadow, intensity) = 1 * (1 - intensity) + shadow * intensity.
    return (1.0 - intensity) + visibility * intensity
end

# Depth test of `p` against the `W × H` map stored in columns
# `offset+1:offset+W` of `depth`.
@inline function _shadow_lookup(depth::Matrix{Float64}, vp::Mat4{Float64}, bias::Float64,
                                r::Int, p::Vec3, offset::Int, W::Int, H::Int)
    c = mat4_transform_vec4(vp, _vh(p))
    isfinite(c.w) || return 1.0
    c.w <= 1e-6 && return 1.0
    ndcx = c.x / c.w; ndcy = c.y / c.w; ndcz = c.z / c.w
    isfinite(ndcx) && isfinite(ndcy) && isfinite(ndcz) || return 1.0
    (abs(ndcx) > 1 || abs(ndcy) > 1 || ndcz < -1 || ndcz > 1) &&
        return 1.0                                          # outside the light frustum
    px = clamp(floor(Int, (ndcx + 1) * 0.5 * W) + 1, 1, W)
    py = clamp(floor(Int, (1 - ndcy) * 0.5 * H) + 1, 1, H)

    if r <= 0                                               # hard shadow: single sample
        d = depth[py, offset + px]
        isinf(d) && return 1.0
        return ndcz - bias > d ? 0.0 : 1.0                  # something nearer the light occludes
    end

    # Soft shadow: average the unoccluded fraction over the texel neighbourhood,
    # clamped to the map bounds. Empty (Inf) texels count as lit, matching the
    # single-sample early-out above.
    x0 = r >= px - 1 ? 1 : px - r
    x1 = r >= W - px ? W : px + r
    y0 = r >= py - 1 ? 1 : py - r
    y1 = r >= H - py ? H : py + r
    lit = 0
    total = 0
    thresh = ndcz - bias
    @inbounds for sy in y0:y1, sx in x0:x1
        total += 1
        d = depth[sy, offset + sx]
        if isinf(d) || thresh <= d
            lit += 1
        end
    end
    total == 0 && return 1.0
    return lit / total
end

# Build shadow maps for all shadow-casting lights and a closure to query them.
# `pcf_radius=0` keeps the original hard-shadow behaviour; a positive radius bakes
# percentage-closer soft shadows into every map, so the query closure returns the
# lit fraction in [0,1] via the radius stored on each `ShadowMap`.
@inline function _light_casts_shadow(light)
    return !_is_fill_light(light) && hasfield(typeof(light), :cast_shadow) &&
           getfield(light, :cast_shadow)
end

function _shadow_depth!(depths::Vector{Matrix{Float64}}, slot::Int, res::Int, columns::Int)
    while length(depths) < slot
        push!(depths, Matrix{Float64}(undef, 0, 0))
    end
    depth = depths[slot]
    if size(depth) != (res, columns)
        depth = Matrix{Float64}(undef, res, columns)
        depths[slot] = depth
    end
    return depth
end

function _build_shadow_query_from_drawables!(maps::IdDict{AbstractLight,ShadowMap},
                                             depths::Union{Nothing,Vector{Matrix{Float64}}},
                                             lights, meshes, instanced;
                                             resolution::Int=512, bias=nothing,
                                             pcf_radius=nothing,
                                             clipping_planes=_NO_PLANES)
    res = _validated_shadow_resolution(resolution)
    empty!(maps)
    shadow_slot = 0
    for light in lights
        if _light_casts_shadow(light)
            shadow_slot += 1
            columns = _shadow_depth_columns(light, res, true)
            depth = depths === nothing ? Matrix{Float64}(undef, res, columns) :
                    _shadow_depth!(depths, shadow_slot, res, columns)
            maps[light] = _compute_shadow_map_from_drawables(meshes, instanced, light, depth;
                resolution=res, bias=bias, pcf_radius=pcf_radius,
                clipping_planes=clipping_planes)
        end
    end
    isempty(maps) && return nothing
    return _ShadowQuery(maps)
end
