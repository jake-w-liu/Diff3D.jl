# --------------------------------------------------------------------------
# Raycaster: ray-mesh intersection for picking and queries (three.js Raycaster).
# Uses the Möller–Trumbore algorithm against world-space triangles.
# --------------------------------------------------------------------------

struct Intersection
    distance::Float64
    point::Vec3{Float64}
    object::AbstractObject3D
    face_index::Int
end

"""
Möller–Trumbore ray/triangle test. Returns the ray parameter `t > 0` at the
hit, or `nothing` if the ray misses. `dir` need not be normalised; `t` is then
in units of `dir`. `side` culls by winding like three.js `Ray.intersectTriangle`:
`:front` rejects backfaces, `:back` rejects frontfaces, `:double` accepts both.
"""
@inline function _ray_triangle_relative_determinant(
        dir::Vec3, a::Vec3, b::Vec3, c::Vec3)
    edge_b_direction = _direction_between(a, b)
    edge_c_direction = _direction_between(a, c)
    return dot(edge_b_direction,
               cross(normalize(dir), edge_c_direction))
end

@inline function _ray_triangle_determinant_visible(
        determinant, eps, side::Symbol)
    if side === :front
        return determinant > eps
    elseif side === :back
        return determinant < -eps
    end
    return abs(determinant) > eps
end

@inline function _ray_triangle_intersect_unchecked(origin::Vec3, dir::Vec3,
                                                   a::Vec3, b::Vec3, c::Vec3,
                                                   eps, side::Symbol)
    e1 = b - a; e2 = c - a
    p = cross(dir, e2)
    det = dot(e1, p)                             # det = -dot(dir, cross(e1, e2))
    relative_det = _ray_triangle_relative_determinant(dir, a, b, c)
    _ray_triangle_determinant_visible(relative_det, eps, side) ||
        return nothing
    inv_det = 1 / det
    tvec = origin - a
    u = dot(tvec, p) * inv_det
    (u < 0 || u > 1) && return nothing
    q = cross(tvec, e1)
    v = dot(dir, q) * inv_det
    (v < 0 || u + v > 1) && return nothing
    t = dot(e2, q) * inv_det
    return t > eps ? t : nothing
end

@inline _ray_float_vector_representation(v::Vec3{T}) where
        {T<:AbstractFloat} = (
    _float_difference_representation(zero(T), v.x),
    _float_difference_representation(zero(T), v.y),
    _float_difference_representation(zero(T), v.z),
)

@inline function _ray_triangle_intersect_unchecked(
        origin::Vec3{T}, dir::Vec3{T}, a::Vec3{T}, b::Vec3{T}, c::Vec3{T},
        eps, side::Symbol) where {T<:AbstractFloat}
    edge_b = _float_vector_difference(a, b)
    edge_c = _float_vector_difference(a, c)
    direction = _ray_float_vector_representation(dir)
    p = _float_representation_cross(direction, edge_c)
    determinant = _float_representation_dot(edge_b, p)
    determinant.nonzero || return nothing
    relative_det = _ray_triangle_relative_determinant(dir, a, b, c)
    _ray_triangle_determinant_visible(relative_det, eps, side) ||
        return nothing

    origin_offset = _float_vector_difference(a, origin)
    u = _float_representation_ratio(
        _float_representation_dot(origin_offset, p), determinant)
    (isfinite(u) && zero(T) <= u <= one(T)) || return nothing
    q = _float_representation_cross(origin_offset, edge_b)
    v = _float_representation_ratio(
        _float_representation_dot(direction, q), determinant)
    (isfinite(v) && v >= zero(T) && u + v <= one(T)) || return nothing
    t = _float_representation_ratio(
        _float_representation_dot(edge_c, q), determinant)
    return t > eps ? t : nothing
end

function ray_triangle_intersect(origin::Vec3, dir::Vec3, a::Vec3, b::Vec3, c::Vec3;
                                eps=1e-9, side::Symbol=:double)
    side in (:front, :back, :double) ||
        throw(ArgumentError("ray_triangle_intersect side must be one of :front, :back, or :double"))
    isfinite(eps) && eps >= 0 ||
        throw(ArgumentError("ray_triangle_intersect eps must be finite and non-negative"))
    _finite_vec3(origin) || throw(ArgumentError("ray_triangle_intersect origin must be finite"))
    _finite_vec3(dir) || throw(ArgumentError("ray_triangle_intersect direction must be finite"))
    (!iszero(dir.x) || !iszero(dir.y) || !iszero(dir.z)) ||
        throw(ArgumentError("ray_triangle_intersect direction must be non-zero"))
    (_finite_vec3(a) && _finite_vec3(b) && _finite_vec3(c)) ||
        throw(ArgumentError("ray_triangle_intersect triangle vertices must be finite"))
    return _ray_triangle_intersect_unchecked(origin, dir, a, b, c, eps, side)
end

mutable struct Raycaster
    ray::Ray{Float64}
    near::Float64
    far::Float64
    layers::Layers           # only objects sharing a channel are tested (three.js Raycaster.layers)
    point_threshold::Float64 # world-space pick radius for PointsObject vertices (three.js params.Points.threshold)
    line_threshold::Float64  # world-space pick radius for Line/LineSegments segments (three.js params.Line.threshold)
    skinning_matrices::Vector{Mat4{Float64}}
    morph_positions::Vector{Vec3{Float64}}
end

function Raycaster(ray::Ray{Float64}, near::Float64, far::Float64,
                   layers::Layers, point_threshold::Float64,
                   line_threshold::Float64)
    n, f = _raycaster_range(near, far)
    normalized_ray = Ray(_raycaster_vec3(ray.origin, "origin"),
                         _raycaster_direction(ray.direction))
    return Raycaster(normalized_ray, n, f, layers,
                     _raycaster_threshold(point_threshold, "point_threshold"),
                     _raycaster_threshold(line_threshold, "line_threshold"),
                     Mat4{Float64}[], Vec3{Float64}[])
end

_finite_vec3(v::Vec3) = isfinite(v.x) && isfinite(v.y) && isfinite(v.z)

function _raycaster_vec3(v::Vec3, label::AbstractString)
    out = Vec3(Float64(v.x), Float64(v.y), Float64(v.z))
    _finite_vec3(out) || throw(ArgumentError("Raycaster $label must be finite"))
    return out
end

function _raycaster_direction(dir::Vec3)
    d = _raycaster_vec3(dir, "direction")
    scale = max(abs(d.x), abs(d.y), abs(d.z))
    scale > 0.0 || throw(ArgumentError("Raycaster direction must be finite and non-zero"))
    scaled = d / scale
    len = norm(scaled)
    isfinite(len) && len > 0.0 ||
        throw(ArgumentError("Raycaster direction must be finite and non-zero"))
    return scaled / len
end

function _raycaster_range(near, far)
    near isa Real && !(near isa Bool) ||
        throw(ArgumentError("Raycaster near must be finite and non-negative"))
    far isa Real && !(far isa Bool) ||
        throw(ArgumentError("Raycaster far must be greater than or equal to near"))
    n = Float64(near)
    f = Float64(far)
    isfinite(n) && n >= 0.0 ||
        throw(ArgumentError("Raycaster near must be finite and non-negative"))
    !isnan(f) || throw(ArgumentError("Raycaster far must not be NaN"))
    f >= n || throw(ArgumentError("Raycaster far must be greater than or equal to near"))
    return n, f
end

function _raycaster_threshold(value, label::AbstractString)
    value isa Real && !(value isa Bool) ||
        throw(ArgumentError("Raycaster $label must be finite and non-negative"))
    t = Float64(value)
    isfinite(t) && t >= 0.0 ||
        throw(ArgumentError("Raycaster $label must be finite and non-negative"))
    return t
end

function _validate_raycaster!(rc::Raycaster)
    origin = _raycaster_vec3(rc.ray.origin, "origin")
    direction = _raycaster_direction(rc.ray.direction)
    near, far = _raycaster_range(rc.near, rc.far)
    point_threshold = _raycaster_threshold(
        rc.point_threshold, "point_threshold")
    line_threshold = _raycaster_threshold(
        rc.line_threshold, "line_threshold")
    rc.ray = Ray(origin, direction)
    rc.near = near
    rc.far = far
    rc.point_threshold = point_threshold
    rc.line_threshold = line_threshold
    return nothing
end

Raycaster(origin::Vec3, dir::Vec3; near=0.0, far=Inf,
          layers::Layers=layers_enable_all!(Layers()),
          point_threshold=1.0, line_threshold=1.0) = begin
    n, f = _raycaster_range(near, far)
    Raycaster(Ray(_raycaster_vec3(origin, "origin"), _raycaster_direction(dir)),
              n, f, layers,
              _raycaster_threshold(point_threshold, "point_threshold"),
              _raycaster_threshold(line_threshold, "line_threshold"))
end

const _OBJECT_LAYER_STORE = WeakKeyDict{AbstractObject3D, Layers}()
const _OBJECT_LAYER_LOCK = ReentrantLock()
const _DEFAULT_OBJECT_LAYER_MASK = UInt32(1)

"""
Layers mask attached to `obj`. Scene-graph objects need not carry a `layers`
field; absent one, `object_layers` initializes persistent channel-0 state.
"""
function object_layers(obj::AbstractObject3D)
    hasproperty(obj, :layers) && return getfield(obj, :layers)
    lock(_OBJECT_LAYER_LOCK)
    try
        return get!(_OBJECT_LAYER_STORE, obj) do
            Layers()
        end
    finally
        unlock(_OBJECT_LAYER_LOCK)
    end
end

function _object_layer_mask(obj::AbstractObject3D)
    hasproperty(obj, :layers) && return getfield(obj, :layers).mask
    lock(_OBJECT_LAYER_LOCK)
    try
        layers = get(_OBJECT_LAYER_STORE, obj, nothing)
        return layers === nothing ? _DEFAULT_OBJECT_LAYER_MASK : layers.mask
    finally
        unlock(_OBJECT_LAYER_LOCK)
    end
end

@inline _layers_test_object(obj::AbstractObject3D, layers::Layers) =
    (_object_layer_mask(obj) & layers.mask) != 0

# Distance from point `p` to the ray, and the ray parameter `t` (in units of the
# ray direction `d`, which `Raycaster` keeps normalised) at the closest approach.
# Returns `(t, dist)`; the projection is clamped to `t >= 0` so points behind the
# origin report their straight-line distance to the origin (three.js behaviour).
function _ray_point_distance(o::Vec3, d::Vec3, p::Vec3)
    w = p - o
    t = dot(w, d)
    if t < 0
        return (zero(t), norm(w))
    end
    closest = o + d * t
    return (t, norm(p - closest))
end

@inline function _ray_representation_sqrt(
        value::_FloatRepresentation{T}) where {T<:AbstractFloat}
    value.nonzero || return zero(T)
    value.mantissa >= zero(T) || return T(NaN)
    mantissa = value.mantissa
    exponent = value.exponent
    if isodd(exponent)
        mantissa *= 2
        exponent -= 1
    end
    return ldexp(sqrt(mantissa), div(exponent, 2))
end

@inline function _ray_residual_distance(offset, direction, parameter)
    T = typeof(parameter)
    parameter_representation =
        _float_difference_representation(zero(T), parameter)
    residual = (
        _float_representation_add(
            offset[1],
            _float_representation_negate(_float_representation_multiply(
                direction[1], parameter_representation))),
        _float_representation_add(
            offset[2],
            _float_representation_negate(_float_representation_multiply(
                direction[2], parameter_representation))),
        _float_representation_add(
            offset[3],
            _float_representation_negate(_float_representation_multiply(
                direction[3], parameter_representation))),
    )
    return _ray_representation_sqrt(
        _float_representation_dot(residual, residual))
end

function _ray_point_distance(
        o::Vec3{T}, d::Vec3{T}, p::Vec3{T}) where {T<:AbstractFloat}
    direction = _ray_float_vector_representation(d)
    direction_squared = _float_representation_dot(direction, direction)
    direction_squared.nonzero || return (zero(T), T(NaN))
    offset = _float_vector_difference(o, p)
    parameter = _float_representation_ratio(
        _float_representation_dot(offset, direction), direction_squared)
    if parameter < zero(T)
        return (zero(T), _ray_representation_sqrt(
            _float_representation_dot(offset, offset)))
    end
    return (parameter, _ray_residual_distance(
        offset, direction, parameter))
end

# Shortest distance between the ray (origin `o`, unit dir `d`) and the segment
# `[a, b]`, plus the ray parameter `t_ray >= 0` at the closest approach on the
# ray and the point `seg_pt` on the segment. Closed-form minimisation of
# |o + t*d - (a + s*seg)|^2 over t >= 0, s in [0,1] (cf. three.js
# `Ray.distanceSqToSegment`), returning the unsquared distance.
function _ray_segment_distance(o::Vec3, d::Vec3, a::Vec3, b::Vec3)
    seg = b - a
    B = dot(d, seg)            # d·seg
    C = dot(seg, seg)          # seg·seg = |seg|^2 (A = d·d = 1, d is unit)
    w0 = o - a
    D = dot(d, w0)             # d·(o-a)
    E = dot(seg, w0)           # seg·(o-a)
    denom = C - B * B          # A*C - B^2 with A = 1; >= 0 (Cauchy–Schwarz)
    if denom > eps(Float64) * (C + one(C))
        s_seg = (E - B * D) / denom        # = (A*E - B*D)/denom with A = 1
    else
        # Ray parallel to the segment: project the origin onto the segment line.
        s_seg = C > 0 ? E / C : zero(C)
    end
    s_seg = clamp(s_seg, zero(s_seg), one(s_seg))
    # Closest ray parameter for the clamped segment point. If it falls behind
    # the origin, clamp t to 0 and re-solve s on that face: project the ray
    # ORIGIN onto the segment (three.js `Ray.distanceSqToSegment` region case).
    seg_pt = a + seg * s_seg
    raw_t = dot(seg_pt - o, d)
    if raw_t < 0
        t_ray = zero(raw_t)
        s_seg = clamp(C > 0 ? E / C : zero(C), zero(C), one(C))
        seg_pt = a + seg * s_seg
    else
        t_ray = raw_t
    end
    ray_pt = o + d * t_ray
    return (t_ray, norm(ray_pt - seg_pt), seg_pt)
end

function _ray_segment_distance(
        o::Vec3{T}, d::Vec3{T}, a::Vec3{T},
        b::Vec3{T}) where {T<:AbstractFloat}
    direction = _ray_float_vector_representation(d)
    segment = _float_vector_difference(a, b)
    origin_offset = _float_vector_difference(a, o)
    direction_squared = _float_representation_dot(direction, direction)
    segment_squared = _float_representation_dot(segment, segment)
    direction_squared.nonzero ||
        return (zero(T), T(NaN), Vec3(T(NaN), T(NaN), T(NaN)))

    if segment_squared.nonzero
        direction_segment = _float_representation_dot(direction, segment)
        direction_offset = _float_representation_dot(
            direction, origin_offset)
        segment_offset = _float_representation_dot(segment, origin_offset)
        perpendicular = _float_representation_cross(direction, segment)
        denominator = _float_representation_dot(perpendicular, perpendicular)
        segment_scale = _float_representation_add(
            segment_squared,
            _float_difference_representation(zero(T), one(T)),
        )
        relative_denominator =
            _float_representation_ratio(denominator, segment_scale)
        if denominator.nonzero && relative_denominator > eps(T)
            numerator = _float_representation_add(
                _float_representation_multiply(
                    direction_squared, segment_offset),
                _float_representation_negate(
                    _float_representation_multiply(
                        direction_segment, direction_offset)),
            )
            segment_parameter =
                _float_representation_ratio(numerator, denominator)
        else
            segment_parameter = _float_representation_ratio(
                segment_offset, segment_squared)
        end
        segment_parameter =
            clamp(segment_parameter, zero(T), one(T))
    else
        segment_parameter = zero(T)
    end

    segment_point = line3_at(Line3(a, b), segment_parameter)
    ray_offset = _float_vector_difference(o, segment_point)
    ray_parameter = _float_representation_ratio(
        _float_representation_dot(ray_offset, direction),
        direction_squared,
    )
    if ray_parameter < zero(T)
        ray_parameter = zero(T)
        if segment_squared.nonzero
            segment_offset =
                _float_representation_dot(segment, origin_offset)
            segment_parameter = clamp(
                _float_representation_ratio(
                    segment_offset, segment_squared),
                zero(T),
                one(T),
            )
            segment_point = line3_at(Line3(a, b), segment_parameter)
            ray_offset = _float_vector_difference(o, segment_point)
        end
    end
    distance = _ray_residual_distance(
        ray_offset, direction, ray_parameter)
    return (ray_parameter, distance, segment_point)
end

@inline function _raycast_morph_positions(rc::Raycaster, obj, geo::BufferGeometry)
    return _object_morph_positions(obj, geo, rc.morph_positions)
end

@inline function _raycast_skinned_vertex(sm::SkinnedMesh, geo::BufferGeometry,
                                         mats, morphed, vi::Int)
    p0 = morphed === nothing ? get_vertex(geo, vi) : morphed[vi]
    return _skin_position(mats, sm.skin_indices[vi], sm.skin_weights[vi], p0)
end

# Build the world-space ray through normalized device coords (x,y ∈ [-1,1]).
function _camera_ray(camera::PerspectiveCamera, ndc_x, ndc_y)
    inv_vp = mat4_inverse(projection_matrix(camera) * view_matrix(camera))
    # NDC z=1 is the point at infinity when the perspective far plane is
    # infinite. Any finite interior depth lies on the same camera ray; 0.5
    # stays inside the clip interval and remains finite for both far modes.
    point = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, 0.5))
    origin = _raycaster_vec3(
        _camera_world_position(camera), "origin")
    return Ray(origin, _raycaster_direction(point - origin))
end

function _camera_ray(camera::AbstractCamera, ndc_x, ndc_y)
    inv_vp = mat4_inverse(projection_matrix(camera) * view_matrix(camera))
    p_near = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, -1.0))
    p_far  = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, 1.0))
    # Orthographic rays originate at the unprojected near-plane point because
    # they do not share a camera apex.
    Ray(_raycaster_vec3(p_near, "origin"), _raycaster_direction(p_far - p_near))
end

"""Aim the raycaster through screen NDC `(x,y)` from a camera (three.js `setFromCamera`)."""
function set_from_camera!(rc::Raycaster, camera::AbstractCamera, ndc_x, ndc_y)
    x = Float64(ndc_x)
    y = Float64(ndc_y)
    isfinite(x) && isfinite(y) ||
        throw(ArgumentError("set_from_camera! NDC coordinates must be finite"))
    rc.ray = _camera_ray(camera, x, y)
    return rc
end

# Test a single object's own geometry against the ray, appending any hits to
# `hits`. Layers and visibility are already checked by the caller. Mesh uses the
# Möller–Trumbore triangle path; PointsObject uses per-vertex pick radius;
# LineObject/LineSegments use per-segment pick radius. Other object types (Group,
# Scene, Bone, Sprite, ...) carry no testable geometry and add nothing.
function _raycast_object!(hits::Vector{Intersection}, rc::Raycaster,
                          obj::AbstractObject3D, wm::Mat4{Float64})
    o = rc.ray.origin; d = rc.ray.direction
    obj isa InstancedMesh && _validate_instanced_mesh(obj, "raycast")
    if obj isa Mesh
        geo = _mesh_geometry(obj)
        _validate_triangle_geometry_indices(geo, "raycast")
        # Cull by material side like three.js Mesh.raycast (default :front).
        side = material_side(_mesh_material(obj))
        @inbounds for fi in _draw_face_range(geo)
            i1, i2, i3 = get_face(geo, fi)
            a = mat4_transform_point(wm, get_vertex(geo, i1))
            b = mat4_transform_point(wm, get_vertex(geo, i2))
            c = mat4_transform_point(wm, get_vertex(geo, i3))
            t = _ray_triangle_intersect_unchecked(o, d, a, b, c, 1e-9, side)
            if t !== nothing && rc.near <= t <= rc.far
                push!(hits, Intersection(t, o + d * t, obj, fi))
            end
        end
    elseif obj isa InstancedMesh && _instanced_triangle_drawable(obj)
        # Each instance is the geometry under world_matrix * instance_matrix; test
        # all of them (was silently skipped, so instanced scenes returned no hits).
        geo = _instanced_geometry(obj)
        _validate_triangle_geometry_indices(geo, "raycast")
        side = material_side(_instanced_material(obj))
        @inbounds for im in obj.instance_matrices
            m = wm * im
            for fi in _draw_face_range(geo)
                i1, i2, i3 = get_face(geo, fi)
                a = mat4_transform_point(m, get_vertex(geo, i1))
                b = mat4_transform_point(m, get_vertex(geo, i2))
                c = mat4_transform_point(m, get_vertex(geo, i3))
                t = _ray_triangle_intersect_unchecked(o, d, a, b, c, 1e-9, side)
                if t !== nothing && rc.near <= t <= rc.far
                    push!(hits, Intersection(t, o + d * t, obj, fi))
                end
            end
        end
    elseif obj isa SkinnedMesh
        # Raycast the posed (skinned) geometry the rasterizer actually renders, so
        # a visibly-rendered skinned mesh is pickable (was silently skipped).
        geo = _skinned_buffer_geometry(obj)
        _validate_triangle_geometry_indices(geo, "raycast")
        _validate_skinned_mesh(obj, "SkinnedMesh")
        mats = _skinning_matrices!(rc.skinning_matrices, obj)
        morphed_positions = _raycast_morph_positions(rc, obj, geo)
        side = material_side(obj.material)
        @inbounds for fi in _draw_face_range(geo)
            i1, i2, i3 = get_face(geo, fi)
            a = mat4_transform_point(wm, _raycast_skinned_vertex(obj, geo, mats, morphed_positions, i1))
            b = mat4_transform_point(wm, _raycast_skinned_vertex(obj, geo, mats, morphed_positions, i2))
            c = mat4_transform_point(wm, _raycast_skinned_vertex(obj, geo, mats, morphed_positions, i3))
            t = _ray_triangle_intersect_unchecked(o, d, a, b, c, 1e-9, side)
            if t !== nothing && rc.near <= t <= rc.far
                push!(hits, Intersection(t, o + d * t, obj, fi))
            end
        end
    elseif obj isa PointsObject
        geo = _points_geometry(obj)
        _validate_indexed_geometry(geo, "raycast")
        morphed_positions = _raycast_morph_positions(rc, obj, geo)
        thr = rc.point_threshold
        @inbounds for entry in _draw_entry_range(geo)
            vi = _draw_vertex_index(geo, entry)
            p = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi))
            t, dist = _ray_point_distance(o, d, p)
            if dist < thr && rc.near <= t <= rc.far
                # Report the point itself as the hit location; face_index = vertex index.
                push!(hits, Intersection(t, p, obj, vi))
            end
        end
    elseif obj isa LineObject || obj isa LineSegments || obj isa LineLoop
        geo = _line_geometry(obj)
        _validate_indexed_geometry(geo, "raycast")
        morphed_positions = _raycast_morph_positions(rc, obj, geo)
        thr = rc.line_threshold
        # LineSegments: disjoint pairs. LineObject: consecutive vertices.
        # LineLoop closes the final vertex back to the first, matching three.js.
        step = obj isa LineSegments ? 2 : 1
        entries = _draw_entry_range(geo)
        isempty(entries) && return hits
        first_entry = first(entries)
        last_entry = last(entries)
        @inbounds for entry in first_entry:step:(last_entry - 1)
            vi1 = _draw_vertex_index(geo, entry)
            vi2 = _draw_vertex_index(geo, entry + 1)
            a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi1))
            b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi2))
            t, dist, seg_pt = _ray_segment_distance(o, d, a, b)
            if dist < thr && rc.near <= t <= rc.far
                # face_index = the segment's start vertex index (three.js index).
                push!(hits, Intersection(t, seg_pt, obj, vi1))
            end
        end
        if obj isa LineLoop && last_entry - first_entry + 1 > 2
            vi1 = _draw_vertex_index(geo, last_entry)
            vi2 = _draw_vertex_index(geo, first_entry)
            a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi1))
            b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi2))
            t, dist, seg_pt = _ray_segment_distance(o, d, a, b)
            if dist < thr && rc.near <= t <= rc.far
                push!(hits, Intersection(t, seg_pt, obj, vi1))
            end
        end
    end
    return hits
end

_raycast_object!(hits::Vector{Intersection}, rc::Raycaster, obj::AbstractObject3D) =
    _raycast_object!(hits, rc, obj, compute_world_matrix(obj))

@inline function _raycast_recursive_child!(hits::Vector{Intersection}, rc::Raycaster,
                                           child::T,
                                           parent_world::Mat4{Float64}) where {T<:AbstractObject3D}
    child_world = parent_world * compute_local_matrix(child)
    return _raycast_recursive!(hits, rc, child, child_world)
end

function _raycast_recursive!(hits::Vector{Intersection}, rc::Raycaster,
                             obj::AbstractObject3D, world::Mat4{Float64})
    is_visible(obj) || return hits
    _layers_test_object(obj, rc.layers) && _raycast_object!(hits, rc, obj, world)
    for child in get_children(obj)
        is_visible(child) || continue
        _raycast_recursive_child!(hits, rc, child, world)
    end
    return hits
end

function _raycast_recursive!(hits::Vector{Intersection}, rc::Raycaster,
                             obj::AbstractObject3D)
    return _raycast_recursive!(hits, rc, obj, compute_world_matrix(obj))
end

_intersection_distance_lt(a::Intersection, b::Intersection) =
    a.distance < b.distance

"""
    raycast(rc, root; recursive=true)

Intersect the ray with `root` and (when `recursive`) every descendant, returning
`Intersection`s sorted by distance (nearest first) and filtered to `[near, far]`.

Meshes are tested with the Möller–Trumbore triangle path; `PointsObject`
vertices and `LineObject`/`LineSegments` segments use the raycaster's
`point_threshold`/`line_threshold` pick radii (three.js `params.Points`/`Line`).
Objects whose layer mask shares no channel with `rc.layers` are skipped (their
children are still traversed when `recursive`). Invisible objects are skipped
hierarchically, matching the renderer: an object inside a `visible = false`
ancestor is not pickable.
"""
function raycast(rc::Raycaster, root::AbstractObject3D; recursive::Bool=true)
    _validate_raycaster!(rc)
    hits = Intersection[]
    if recursive
        _visible_in_tree(root) &&
            _raycast_recursive!(hits, rc, root, compute_world_matrix(root))
    else
        if _visible_in_tree(root) && _layers_test_object(root, rc.layers)
            _raycast_object!(hits, rc, root, compute_world_matrix(root))
        end
    end
    sort!(hits; lt=_intersection_distance_lt)
    return hits
end
