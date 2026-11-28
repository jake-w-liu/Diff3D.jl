# --------------------------------------------------------------------------
# Raycaster: ray-mesh intersection for picking and queries (three.js Raycaster).
# Uses the Möller–Trumbore algorithm against world-space triangles.
# --------------------------------------------------------------------------

"""
A picking result, the counterpart of a three.js `Raycaster` intersection.

- `distance`, `point`: world-space distance from the ray origin and hit point.
- `object`: the object that was hit.
- `face_index`: mesh face, point vertex, or the draw entry (index-buffer
  position, or vertex for non-indexed geometry) where a line segment starts,
  as three.js `index` (all 1-based); zero for a sprite.
- `instance_id`: 1-based instance for an `InstancedMesh`, otherwise `nothing`.
- `face`: 1-based vertex indices `(a, b, c)` of the hit triangle (three.js
  `face.a/b/c`); `nothing` for points, lines and sprites.
- `face_normal`: unit normal of the hit triangle in the object's local space
  (three.js `face.normal`), from its morphed or posed vertices.
- `normal`: the geometry's vertex normals interpolated at the hit, in local
  space and flipped to face the ray origin (three.js `normal`); `nothing` when
  the geometry has no normals.
- `uv`, `uv1`: first and second (`:uv2` attribute) texture coordinates
  interpolated at the hit; a sprite reports its quad `uv`.
- `barycoord`: barycentric weights of the hit for `face`'s three vertices.
- `distance_to_ray`: for points, the world-space distance from the vertex to
  the ray, in the same units as the world-space `point_threshold` (three.js
  `distanceToRay` is measured in the object's local space, so the two differ
  under a scaled world matrix).
"""
struct Intersection
    distance::Float64
    point::Vec3{Float64}
    object::AbstractObject3D
    face_index::Int
    instance_id::Union{Nothing,Int}
    face::Union{Nothing,NTuple{3,Int}}
    face_normal::Union{Nothing,Vec3{Float64}}
    normal::Union{Nothing,Vec3{Float64}}
    uv::Union{Nothing,Vec2{Float64}}
    uv1::Union{Nothing,Vec2{Float64}}
    barycoord::Union{Nothing,Vec3{Float64}}
    distance_to_ray::Union{Nothing,Float64}
end

Intersection(distance,point,object,face_index) =
    Intersection(distance,point,object,face_index,nothing)

Intersection(distance,point,object,face_index,instance_id) =
    Intersection(distance,point,object,face_index,instance_id,
                 nothing,nothing,nothing,nothing,nothing,nothing,nothing)

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
    worlds::Vector{Mat4{Float64}}  # per-depth world-matrix traversal stack
    camera::Union{Nothing,AbstractCamera}
    vertex_codes::Vector{UInt8}             # lateral pre-filter scratch, one per vertex
    skinned_positions::Vector{Vec3{Float64}} # posed skin vertices, one per vertex
    hits::Vector{Intersection}              # per-cast hit scratch; `raycast` returns a copy
end

Raycaster(ray,near,far,layers,point_threshold,line_threshold,
          skinning_matrices,morph_positions) =
    Raycaster(ray,near,far,layers,point_threshold,line_threshold,
              skinning_matrices,morph_positions,Mat4{Float64}[],nothing)

Raycaster(ray,near,far,layers,point_threshold,line_threshold,
          skinning_matrices,morph_positions,worlds,camera) =
    Raycaster(ray,near,far,layers,point_threshold,line_threshold,
              skinning_matrices,morph_positions,worlds,camera,
              UInt8[],Vec3{Float64}[],Intersection[])

function Raycaster(ray::Ray{Float64}, near::Float64, far::Float64,
                   layers::Layers, point_threshold::Float64,
                   line_threshold::Float64)
    n, f = _raycaster_range(near, far)
    normalized_ray = Ray(_raycaster_vec3(ray.origin, "origin"),
                         _raycaster_direction(ray.direction))
    return Raycaster(normalized_ray, n, f, layers,
                     _raycaster_threshold(point_threshold, "point_threshold"),
                     _raycaster_threshold(line_threshold, "line_threshold"),
                     Mat4{Float64}[], Vec3{Float64}[], Mat4{Float64}[], nothing)
end

_finite_vec3(v::Vec3) = isfinite(v.x) && isfinite(v.y) && isfinite(v.z)

function _raycaster_vec3(v::Vec3, label::AbstractString)
    out = Vec3(Float64(v.x), Float64(v.y), Float64(v.z))
    _finite_vec3(out) || throw(ArgumentError("Raycaster $label must be finite"))
    return out
end

function _raycaster_direction(dir::Vec3)
    d = _raycaster_vec3(dir, "direction")
    # Normalizing an already normalized vector can move it by an ulp, so a
    # raycaster revalidated on every `raycast` would drift between calls. A
    # direction whose squared length is within rounding of one (normalized
    # output is within 3 ulps) is kept as is, which makes this idempotent.
    abs(d.x * d.x + d.y * d.y + d.z * d.z - 1.0) <= 8 * eps(Float64) && return d
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
          layers::Layers=Layers(),
          point_threshold=1.0, line_threshold=1.0,
          camera::Union{Nothing,AbstractCamera}=nothing) = begin
    n, f = _raycaster_range(near, far)
    Raycaster(Ray(_raycaster_vec3(origin, "origin"), _raycaster_direction(dir)),
              n, f, layers,
              _raycaster_threshold(point_threshold, "point_threshold"),
              _raycaster_threshold(line_threshold, "line_threshold"),
              Mat4{Float64}[],Vec3{Float64}[],Mat4{Float64}[],camera)
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

@inline _object_matches_layer_mask(obj::AbstractObject3D, ::Nothing) = true
@inline _object_matches_layer_mask(obj::AbstractObject3D, mask::UInt32) =
    (_object_layer_mask(obj) & mask) != 0

function _filter_object_layers!(objects::Vector, worlds, mask::Union{Nothing,UInt32})
    mask === nothing && return objects
    output = 0
    for i in eachindex(objects)
        object = objects[i]
        _object_matches_layer_mask(object, mask) || continue
        output += 1
        objects[output] = object
        worlds === nothing || (worlds[output] = worlds[i])
    end
    resize!(objects, output)
    worlds === nothing || resize!(worlds, output)
    return objects
end

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
        # Ray parallel to the segment: every point of the overlap is equally
        # close, and three.js `Ray.distanceSqToSegment` (Ray.js:274-277)
        # reports the segment end farthest along the ray.
        s_seg = B < 0 ? zero(C) : one(C)
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
            # Parallel: the segment end farthest along the ray, as three.js
            # `Ray.distanceSqToSegment` does (Ray.js:274-277).
            along = _float_representation_ratio(direction_segment, segment_squared)
            segment_parameter = along < zero(T) ? zero(T) : one(T)
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

# three.js Mesh.raycast culls in the object's local space. Triangles are tested
# here in world space, where a mirroring (negative-determinant) transform
# reverses the winding, so the culled side must be swapped to match.
@inline function _raycast_world_side(side::Symbol, world::Mat4)
    side === :double && return side
    _mat4_linear_orientation_sign(world) < 0 || return side
    return side === :front ? :back : :front
end

# Exact power-of-two rescaling. `ldexp` on each component stays exact where a
# multiplier ldexp(1.0, k) would overflow (k > 1023, i.e. subnormal inputs).
@inline _hit_ldexp(v::Vec3{Float64}, k::Int) =
    Vec3(ldexp(v.x, k), ldexp(v.y, k), ldexp(v.z, k))

@inline _hit_max_abs(v::Vec3{Float64}) = max(abs(v.x), abs(v.y), abs(v.z))

# three.js Triangle.getBarycoord: weights of `p` for (a, b, c), zero for a
# degenerate triangle. Offsets are scaled by an exact power of two first so
# extreme world coordinates neither overflow nor underflow the dot products.
function _hit_barycoord(p::Vec3{Float64}, a::Vec3{Float64}, b::Vec3{Float64},
                        c::Vec3{Float64})
    v0 = c - a
    v1 = b - a
    v2 = p - a
    magnitude = max(_hit_max_abs(v0), _hit_max_abs(v1))
    (isfinite(magnitude) && magnitude > 0.0) || return Vec3(0.0, 0.0, 0.0)
    k = -exponent(magnitude)
    v0 = _hit_ldexp(v0, k)
    v1 = _hit_ldexp(v1, k)
    v2 = _hit_ldexp(v2, k)
    dot00 = dot(v0, v0)
    dot01 = dot(v0, v1)
    dot02 = dot(v0, v2)
    dot11 = dot(v1, v1)
    dot12 = dot(v1, v2)
    denominator = dot00 * dot11 - dot01 * dot01
    denominator == 0.0 && return Vec3(0.0, 0.0, 0.0)
    inverse = 1.0 / denominator
    u = (dot11 * dot02 - dot01 * dot12) * inverse
    v = (dot00 * dot12 - dot01 * dot02) * inverse
    return Vec3(1.0 - u - v, v, u)
end

# three.js Triangle.getInterpolatedAttribute for flat attribute storage.
@inline function _hit_interpolate2(data::AbstractVector, stride::Int, i1::Int,
                                   i2::Int, i3::Int, w::Vec3{Float64})
    b1 = (i1 - 1) * stride
    b2 = (i2 - 1) * stride
    b3 = (i3 - 1) * stride
    return @inbounds Vec2(
        Float64(data[b1 + 1]) * w.x + Float64(data[b2 + 1]) * w.y + Float64(data[b3 + 1]) * w.z,
        Float64(data[b1 + 2]) * w.x + Float64(data[b2 + 2]) * w.y + Float64(data[b3 + 2]) * w.z)
end

@inline function _hit_interpolate_attribute2(attribute::BufferAttribute, i1::Int, i2::Int,
                                             i3::Int, w::Vec3{Float64})
    data = attribute.data
    stride = attribute.item_size
    data isa Vector{Float64} && return _hit_interpolate2(data, stride, i1, i2, i3, w)
    data isa Vector{Float32} && return _hit_interpolate2(data, stride, i1, i2, i3, w)
    return _hit_interpolate2(data, stride, i1, i2, i3, w)
end

@inline function _hit_interpolate3(data::AbstractVector, i1::Int, i2::Int,
                                   i3::Int, w::Vec3{Float64})
    b1 = 3i1 - 3
    b2 = 3i2 - 3
    b3 = 3i3 - 3
    return @inbounds Vec3(
        Float64(data[b1 + 1]) * w.x + Float64(data[b2 + 1]) * w.y + Float64(data[b3 + 1]) * w.z,
        Float64(data[b1 + 2]) * w.x + Float64(data[b2 + 2]) * w.y + Float64(data[b3 + 2]) * w.z,
        Float64(data[b1 + 3]) * w.x + Float64(data[b2 + 3]) * w.y + Float64(data[b3 + 3]) * w.z)
end

# (c - b) × (a - b) with the edges rescaled by a common power of two, so the
# product neither overflows nor underflows at extreme coordinates. Only its
# direction is used.
@inline function _hit_scaled_face_cross(a::Vec3{Float64}, b::Vec3{Float64},
                                        c::Vec3{Float64})
    e1 = c - b
    e2 = a - b
    magnitude = max(_hit_max_abs(e1), _hit_max_abs(e2))
    (isfinite(magnitude) && magnitude > 0.0) || return Vec3(0.0, 0.0, 0.0)
    k = -exponent(magnitude)
    return cross(_hit_ldexp(e1, k), _hit_ldexp(e2, k))
end

# three.js Triangle.getNormal: normalize((c - b) × (a - b)), zero if degenerate.
@inline _hit_triangle_normal(a::Vec3{Float64}, b::Vec3{Float64}, c::Vec3{Float64}) =
    _hit_unit(_hit_scaled_face_cross(a, b, c))

# Unit vector along `v`, zero for a zero or non-finite `v`. The exact
# power-of-two prescale keeps tiny and huge vectors from under/overflowing.
@inline function _hit_unit(v::Vec3{Float64})
    magnitude = _hit_max_abs(v)
    (isfinite(magnitude) && magnitude > 0.0) || return Vec3(0.0, 0.0, 0.0)
    w = _hit_ldexp(v, -exponent(magnitude))
    return w / sqrt(dot(w, w))
end

# Hit record for triangle `face` of `geo` (vertices i1, i2, i3), mirroring
# three.js checkGeometryIntersection (src/objects/Mesh.js). `a, b, c` are the
# world-space vertices that were intersected and `m` maps the object's local
# space to world. `local_triangle` holds the local vertices when known;
# otherwise (posed skins) the local face normal is pulled back from world
# space through `m`, since (M e₁) × (M e₂) = det(M) M⁻ᵀ (e₁ × e₂).
function _triangle_intersection(obj, distance::Float64, rc::Raycaster,
                                face::Int, instance_id, geo::BufferGeometry,
                                i1::Int, i2::Int, i3::Int, a::Vec3{Float64},
                                b::Vec3{Float64}, c::Vec3{Float64},
                                local_triangle, m::Mat4{Float64})
    o = rc.ray.origin
    d = rc.ray.direction
    point = o + d * distance
    weights = _hit_barycoord(point, a, b, c)
    n = geo.n_vertices
    uv = length(geo.uvs) >= 2n ? _hit_interpolate2(geo.uvs, 2, i1, i2, i3, weights) : nothing
    uv1_attribute = _uv2_attribute(geo)
    # Attributes are stored with an abstract element type; the barrier keeps
    # the interpolated value concrete instead of boxing it.
    uv1 = uv1_attribute === nothing ? nothing :
          _hit_interpolate_attribute2(uv1_attribute, i1, i2, i3, weights)::Vec2{Float64}
    if local_triangle === nothing
        e = m.e
        world_normal = _hit_scaled_face_cross(a, b, c)
        pulled = Vec3(e[1] * world_normal.x + e[2] * world_normal.y + e[3] * world_normal.z,
                      e[5] * world_normal.x + e[6] * world_normal.y + e[7] * world_normal.z,
                      e[9] * world_normal.x + e[10] * world_normal.y + e[11] * world_normal.z)
        pulled = _mat4_linear_orientation_sign(m) < 0 ? -pulled : pulled
        face_normal = _hit_unit(pulled)
    else
        la, lb, lc = local_triangle
        face_normal = _hit_triangle_normal(la, lb, lc)
    end
    normal = nothing
    if length(geo.normals) >= 3n
        interpolated = _hit_interpolate3(geo.normals, i1, i2, i3, weights)
        local_direction = mat4_transform_direction(mat4_inverse(m), d)
        normal = dot(interpolated, local_direction) > 0.0 ? -interpolated : interpolated
    end
    return Intersection(distance, point, obj, face, instance_id, (i1, i2, i3),
                        face_normal, normal, uv, uv1, weights, nothing)
end

# three.js r186 Ray.intersectTriangle (src/math/Ray.js): the watertight test of
# Woop, Benthin and Wald (JCGT 2(1), 2013). The shear makes an edge shared by
# two triangles evaluate identically for both, so a ray through an edge or a
# corner hits instead of slipping between them, and edges are inclusive.
# Returns the ray parameter `t >= 0` in units of `dir`, or `nothing`. `side`
# culls like three.js checkIntersection: `:front` passes (a, b, c) with
# backface culling, `:back` passes (c, b, a) with culling, `:double` neither.
@inline function _ray_triangle_watertight(origin::Vec3{Float64}, dir::Vec3{Float64},
                                          a::Vec3{Float64}, b::Vec3{Float64},
                                          c::Vec3{Float64}, side::Symbol)
    side === :back && return _ray_triangle_watertight(origin, dir, c, b, a, true)
    return _ray_triangle_watertight(origin, dir, a, b, c, side === :front)
end

@inline function _ray_triangle_watertight(origin::Vec3{Float64}, dir::Vec3{Float64},
                                          a::Vec3{Float64}, b::Vec3{Float64},
                                          c::Vec3{Float64}, backface_culling::Bool)
    # The test is homogeneous in the vertex offsets (u, v, w are quadratic,
    # t_scaled cubic, t linear), so offsets are rescaled by an exact power of
    # two that keeps the products clear of overflow and underflow; the result
    # equals three.js's arithmetic wherever that does not overflow.
    shift = 0
    reach = max(_hit_max_abs(a), _hit_max_abs(b), _hit_max_abs(c),
                _hit_max_abs(origin))
    isfinite(reach) || return nothing
    if reach > 0x1p1020
        a = _hit_ldexp(a, -4); b = _hit_ldexp(b, -4); c = _hit_ldexp(c, -4)
        origin = _hit_ldexp(origin, -4)
        shift = 4
    end
    ao = a - origin
    bo = b - origin
    co = c - origin
    span = max(_hit_max_abs(ao), _hit_max_abs(bo), _hit_max_abs(co))
    span > 0.0 || return nothing
    k = exponent(span)
    ao = _hit_ldexp(ao, -k); bo = _hit_ldexp(bo, -k); co = _hit_ldexp(co, -k)
    shift += k
    dx, dy, dz = dir.x, dir.y, dir.z
    adx, ady, adz = abs(dx), abs(dy), abs(dz)
    # Project along the dominant direction axis kz; kx and ky swap when that
    # component is negative so the winding is preserved.
    if adx >= ady && adx >= adz
        dkz = dx; akz = ao.x; bkz = bo.x; ckz = co.x
        if dx >= 0.0
            dkx = dy; dky = dz
            akx = ao.y; aky = ao.z; bkx = bo.y; bky = bo.z; ckx = co.y; cky = co.z
        else
            dkx = dz; dky = dy
            akx = ao.z; aky = ao.y; bkx = bo.z; bky = bo.y; ckx = co.z; cky = co.y
        end
    elseif ady >= adz
        dkz = dy; akz = ao.y; bkz = bo.y; ckz = co.y
        if dy >= 0.0
            dkx = dz; dky = dx
            akx = ao.z; aky = ao.x; bkx = bo.z; bky = bo.x; ckx = co.z; cky = co.x
        else
            dkx = dx; dky = dz
            akx = ao.x; aky = ao.z; bkx = bo.x; bky = bo.z; ckx = co.x; cky = co.z
        end
    else
        dkz = dz; akz = ao.z; bkz = bo.z; ckz = co.z
        if dz >= 0.0
            dkx = dx; dky = dy
            akx = ao.x; aky = ao.y; bkx = bo.x; bky = bo.y; ckx = co.x; cky = co.y
        else
            dkx = dy; dky = dx
            akx = ao.y; aky = ao.x; bkx = bo.y; bky = bo.x; ckx = co.y; cky = co.x
        end
    end
    dkz == 0.0 && return nothing
    sx = dkx / dkz
    sy = dky / dkz
    sz = 1.0 / dkz
    ax = akx - sx * akz; ay = aky - sy * akz
    bx = bkx - sx * bkz; by = bky - sy * bkz
    cx = ckx - sx * ckz; cy = cky - sy * ckz
    # Each of u, v, w (hence det and t_scaled) is a sum of products of one
    # sheared x and one sheared y coordinate, and t_scaled is linear in the
    # z coordinates. Rescaling the x, y or z coordinates alone by an exact
    # power of two therefore leaves t unchanged (z by the factor tracked in
    # `shift`). After the span normalization a coordinate set far below 1
    # (under 2^-300) means a triangle far thinner along that axis than its
    # extent along the others; it is rescaled so u, v, w and t_scaled cannot
    # underflow to a spurious det == 0 or t == 0. Ordinary inputs never take
    # these branches, so their arithmetic is three.js's.
    x_reach = max(abs(ax), abs(bx), abs(cx))
    if 0.0 < x_reach < 0x1p-300
        j = -exponent(x_reach)
        ax = ldexp(ax, j); bx = ldexp(bx, j); cx = ldexp(cx, j)
    end
    y_reach = max(abs(ay), abs(by), abs(cy))
    if 0.0 < y_reach < 0x1p-300
        j = -exponent(y_reach)
        ay = ldexp(ay, j); by = ldexp(by, j); cy = ldexp(cy, j)
    end
    z_reach = max(abs(akz), abs(bkz), abs(ckz))
    if 0.0 < z_reach < 0x1p-300
        j = -exponent(z_reach)
        akz = ldexp(akz, j); bkz = ldexp(bkz, j); ckz = ldexp(ckz, j)
        shift -= j
    end
    u = cx * by - cy * bx
    v = ax * cy - ay * cx
    w = bx * ay - by * ax
    if backface_culling
        (u < 0.0 || v < 0.0 || w < 0.0) && return nothing
    else
        ((u < 0.0 || v < 0.0 || w < 0.0) && (u > 0.0 || v > 0.0 || w > 0.0)) &&
            return nothing
    end
    det = u + v + w
    det == 0.0 && return nothing
    t_scaled = sz * (u * akz + v * bkz + w * ckz)
    (det > 0.0 ? t_scaled < 0.0 : t_scaled > 0.0) && return nothing
    t = ldexp(t_scaled / det, shift)
    isfinite(t) || return nothing
    return t
end

# The ray in the local space of the affine world matrix `m`, as three.js
# Mesh.raycast does (`ray.applyMatrix4(matrixWorld.invert())`): returns
# `(origin, direction)`, `nothing` when `m` is projective (the caller then
# intersects in world space, where a projective map still carries triangles to
# triangles), or `missing` when `m` is singular (three.js inverts it to the
# zero matrix and finds no hits). The origin is mapped as M⁻¹(o - t), which
# subtracts the translation before the linear map, so a ray near a hugely
# translated object keeps its local precision. The direction is not
# normalized: only hit points, never ray parameters, leave the local frame.
@inline function _raycast_local_ray(rc::Raycaster, m::Mat4{Float64})
    e = m.e
    (e[4] == 0.0 && e[8] == 0.0 && e[12] == 0.0 && e[16] == 1.0) || return nothing
    inverse = mat4_inverse(m).e
    o = rc.ray.origin - Vec3(e[13], e[14], e[15])
    d = rc.ray.direction
    origin = Vec3(inverse[1] * o.x + inverse[5] * o.y + inverse[9] * o.z,
                  inverse[2] * o.x + inverse[6] * o.y + inverse[10] * o.z,
                  inverse[3] * o.x + inverse[7] * o.y + inverse[11] * o.z)
    direction = Vec3(inverse[1] * d.x + inverse[5] * d.y + inverse[9] * d.z,
                     inverse[2] * d.x + inverse[6] * d.y + inverse[10] * d.z,
                     inverse[3] * d.x + inverse[7] * d.y + inverse[11] * d.z)
    (_finite_vec3(origin) && _finite_vec3(direction) &&
     _hit_max_abs(direction) > 0.0) || return missing
    return origin, direction
end

# Lateral pre-filter for a local-space ray: the planes are built from the
# unit local direction and the vertices are classified untransformed.
function _raycast_local_lateral_codes!(rc::Raycaster, geo::BufferGeometry,
                                       positions, origin::Vec3{Float64},
                                       direction::Vec3{Float64})
    unit = _hit_unit(direction)
    filter = _ray_lateral_filter(origin, unit, Mat4{Float64}(), 0.0)
    return _ray_lateral_codes!(rc, geo, positions, filter)
end

# Triangles of `geo` (vertex `positions` or the geometry's own) under the
# object-to-world matrix `m`, culled by material `side` in local space like
# three.js Mesh._computeIntersections/checkIntersection (src/objects/Mesh.js):
# the hit is found on the local triangle, mapped back to world space, and its
# distance is measured there from the world ray origin.
function _raycast_triangles!(hits::Vector{Intersection}, rc::Raycaster, obj,
                             geo::BufferGeometry, positions, m::Mat4{Float64},
                             side::Symbol, instance_id)
    local_ray = _raycast_local_ray(rc, m)
    local_ray === missing && return hits
    local_ray === nothing &&
        return _raycast_world_triangles!(hits, rc, obj, geo, positions, m,
                                         side, instance_id)
    lo, ld = local_ray
    world_step = mat4_transform_direction(m, ld)
    codes = _raycast_local_lateral_codes!(rc, geo, positions, lo, ld)
    @inbounds for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        _ray_lateral_rejects(codes, i1, i2, i3) && continue
        a = _geometry_vertex(geo, positions, i1)
        b = _geometry_vertex(geo, positions, i2)
        c = _geometry_vertex(geo, positions, i3)
        t = _ray_triangle_watertight(lo, ld, a, b, c, side)
        t === nothing && continue
        local_point = lo + ld * t
        point = mat4_transform_point(m, local_point)
        # three.js measures |point - origin|; the world step M·(ld t) is that
        # same vector without the cancellation of two far-from-zero points.
        distance = t * norm(world_step)
        rc.near <= distance <= rc.far || continue
        push!(hits, _local_triangle_intersection(obj, distance, point,
                                                 local_point, ld, fi,
                                                 instance_id, geo, i1, i2, i3,
                                                 a, b, c))
    end
    return hits
end

# World-space fallback for projective matrices, which do not map a ray
# direction through `mat4_transform_direction`.
function _raycast_world_triangles!(hits::Vector{Intersection}, rc::Raycaster,
                                   obj, geo::BufferGeometry, positions,
                                   m::Mat4{Float64}, side::Symbol, instance_id)
    o = rc.ray.origin; d = rc.ray.direction
    world_side = _raycast_world_side(side, m)
    @inbounds for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        la = _geometry_vertex(geo, positions, i1)
        lb = _geometry_vertex(geo, positions, i2)
        lc = _geometry_vertex(geo, positions, i3)
        a = mat4_transform_point(m, la)
        b = mat4_transform_point(m, lb)
        c = mat4_transform_point(m, lc)
        t = _ray_triangle_watertight(o, d, a, b, c, world_side)
        if t !== nothing && rc.near <= t <= rc.far
            push!(hits, _triangle_intersection(obj, t, rc, fi, instance_id, geo,
                                               i1, i2, i3, a, b, c,
                                               (la, lb, lc), m))
        end
    end
    return hits
end

# Hit record for a local-space triangle hit (three.js checkGeometryIntersection):
# barycentric weights, face normal and the ray-facing interpolated normal all
# come from the local triangle and the local ray direction `ld`.
function _local_triangle_intersection(obj, distance::Float64, point::Vec3{Float64},
                                      local_point::Vec3{Float64}, ld::Vec3{Float64},
                                      face::Int, instance_id, geo::BufferGeometry,
                                      i1::Int, i2::Int, i3::Int, a::Vec3{Float64},
                                      b::Vec3{Float64}, c::Vec3{Float64})
    weights = _hit_barycoord(local_point, a, b, c)
    n = geo.n_vertices
    uv = length(geo.uvs) >= 2n ? _hit_interpolate2(geo.uvs, 2, i1, i2, i3, weights) : nothing
    uv1_attribute = _uv2_attribute(geo)
    # Attributes are stored with an abstract element type; the barrier keeps
    # the interpolated value concrete instead of boxing it.
    uv1 = uv1_attribute === nothing ? nothing :
          _hit_interpolate_attribute2(uv1_attribute, i1, i2, i3, weights)::Vec2{Float64}
    face_normal = _hit_triangle_normal(a, b, c)
    normal = nothing
    if length(geo.normals) >= 3n
        interpolated = _hit_interpolate3(geo.normals, i1, i2, i3, weights)
        normal = dot(interpolated, ld) > 0.0 ? -interpolated : interpolated
    end
    return Intersection(distance, point, obj, face, instance_id, (i1, i2, i3),
                        face_normal, normal, uv, uv1, weights, nothing)
end

@inline function _raycast_morph_positions(rc::Raycaster, obj, geo::BufferGeometry)
    return _object_morph_positions(obj, geo, rc.morph_positions)
end

@inline function _raycast_skinned_vertex(sm::SkinnedMesh, geo::BufferGeometry,
                                         mats, morphed, vi::Int)
    p0 = morphed === nothing ? get_vertex(geo, vi) : morphed[vi]
    return _skin_position(mats, sm.skin_indices[vi], sm.skin_weights[vi], p0)
end

# Lateral pre-filter. Two orthogonal planes contain the ray; a primitive whose
# vertices all lie beyond the same plane by more than `pad` plus a rounding
# margin cannot meet the ray, so the exact test is skipped for it. The planes
# are pulled back through the affine matrix `m` (u = (Mᵀn)·p + n·(t - o)), so
# local vertices are classified without a world transform. The margin is 1e-9
# relative to the coordinate magnitudes involved, many orders above the
# rounding error of either computation, so the filter never rejects anything
# the exact test could accept; non-finite values disable it.
struct _RayLateralFilter
    au::Vec3{Float64}
    bu::Float64
    av::Vec3{Float64}
    bv::Float64
    linear_scale::Float64   # largest |entry| of the linear part of `m`
    offset_scale::Float64   # |translation|₁ + |ray origin|₁
    pad::Float64            # pick radius for points and lines, zero for triangles
end

_ray_lateral_filter(rc::Raycaster, m::Mat4{Float64}, pad::Float64) =
    _ray_lateral_filter(rc.ray.origin, rc.ray.direction, m, pad)

# `d` must be a unit vector.
function _ray_lateral_filter(o::Vec3{Float64}, d::Vec3{Float64},
                             m::Mat4{Float64}, pad::Float64)
    e = m.e
    (e[4] == 0.0 && e[8] == 0.0 && e[12] == 0.0 && e[16] == 1.0) || return nothing
    ax, ay, az = abs(d.x), abs(d.y), abs(d.z)
    helper = ax <= ay && ax <= az ? Vec3(1.0, 0.0, 0.0) :
             ay <= az ? Vec3(0.0, 1.0, 0.0) : Vec3(0.0, 0.0, 1.0)
    nu = normalize(cross(d, helper))
    nv = cross(d, nu)
    c1 = Vec3(e[1], e[2], e[3])
    c2 = Vec3(e[5], e[6], e[7])
    c3 = Vec3(e[9], e[10], e[11])
    t = Vec3(e[13], e[14], e[15])
    relative = t - o
    au = Vec3(dot(c1, nu), dot(c2, nu), dot(c3, nu))
    av = Vec3(dot(c1, nv), dot(c2, nv), dot(c3, nv))
    bu = dot(relative, nu)
    bv = dot(relative, nv)
    linear_scale = max(abs(e[1]), abs(e[2]), abs(e[3]), abs(e[5]), abs(e[6]),
                       abs(e[7]), abs(e[9]), abs(e[10]), abs(e[11]))
    offset_scale = abs(t.x) + abs(t.y) + abs(t.z) + abs(o.x) + abs(o.y) + abs(o.z)
    (_finite_vec3(au) && _finite_vec3(av) && isfinite(bu) && isfinite(bv) &&
     isfinite(linear_scale) && isfinite(offset_scale)) || return nothing
    return _RayLateralFilter(au, bu, av, bv, linear_scale, offset_scale, pad)
end

# Bit set of the half-spaces (u > s, u < -s, v > s, v < -s) holding `p`; a
# primitive is beyond a plane when the codes of all its vertices share a bit.
@inline function _ray_lateral_code(f::_RayLateralFilter, p::Vec3{Float64})
    u = dot(f.au, p) + f.bu
    v = dot(f.av, p) + f.bv
    slack = f.pad + 1.0e-9 * (f.pad + f.offset_scale +
                              f.linear_scale * (abs(p.x) + abs(p.y) + abs(p.z)))
    (isfinite(u) && isfinite(v) && isfinite(slack)) || return 0x00
    return (u > slack ? 0x01 : 0x00) | (u < -slack ? 0x02 : 0x00) |
           (v > slack ? 0x04 : 0x00) | (v < -slack ? 0x08 : 0x00)
end

# Codes for every vertex of `geo` (optionally morphed); `nothing` when the
# filter is unavailable for this matrix.
_ray_lateral_codes!(rc::Raycaster, geo::BufferGeometry, positions,
                    m::Mat4{Float64}, pad::Float64) =
    _ray_lateral_codes!(rc, geo, positions,
                        _ray_lateral_filter(rc, m, pad))

function _ray_lateral_codes!(rc::Raycaster, geo::BufferGeometry, positions,
                             filter::Union{Nothing,_RayLateralFilter})
    filter === nothing && return nothing
    codes = rc.vertex_codes
    n = geo.n_vertices
    length(codes) < n && resize!(codes, n)
    @inbounds for vi in 1:n
        codes[vi] = _ray_lateral_code(filter, _geometry_vertex(geo, positions, vi))
    end
    return codes
end

@inline _ray_lateral_rejects(::Nothing, i1::Int, i2::Int, i3::Int) = false
@inline _ray_lateral_rejects(codes::Vector{UInt8}, i1::Int, i2::Int, i3::Int) =
    @inbounds((codes[i1] & codes[i2] & codes[i3]) != 0x00)
@inline _ray_lateral_rejects(::Nothing, i1::Int, i2::Int) = false
@inline _ray_lateral_rejects(codes::Vector{UInt8}, i1::Int, i2::Int) =
    @inbounds((codes[i1] & codes[i2]) != 0x00)

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
    projection = projection_matrix(camera)
    inv_vp = mat4_inverse(projection * view_matrix(camera))
    p_near = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, -1.0))
    p_far  = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, 1.0))
    # Orthographic rays share no apex; three.js Raycaster.setFromCamera puts
    # the origin in the camera plane by unprojecting NDC z =
    # projectionMatrix.elements[14] (view-space z = 0), so surfaces between the
    # camera and its near plane are hit too and distances start at the camera.
    origin = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, mat4_get(projection, 3, 4)))
    Ray(_raycaster_vec3(origin, "origin"), _raycaster_direction(p_far - p_near))
end

"""Aim through screen NDC `(x,y)` and retain the camera for sprite picking."""
function set_from_camera!(rc::Raycaster, camera::AbstractCamera, ndc_x, ndc_y)
    x = Float64(ndc_x)
    y = Float64(ndc_y)
    isfinite(x) && isfinite(y) ||
        throw(ArgumentError("set_from_camera! NDC coordinates must be finite"))
    rc.ray = _camera_ray(camera, x, y)
    rc.camera = camera
    return rc
end

# Conservative bounding-sphere rejection (three.js tests geometry.boundingSphere
# before any primitive). The sphere encloses the vertex AABB; any non-finite or
# non-affine quantity disables the shortcut instead of risking a missed hit.
function _raycast_local_bounds(geo::BufferGeometry, morphed_positions)
    n = geo.n_vertices
    n > 0 || return Vec3(NaN, NaN, NaN), Vec3(NaN, NaN, NaN)
    lo = hi = _geometry_vertex(geo, morphed_positions, 1)
    @inbounds for i in 2:n
        p = _geometry_vertex(geo, morphed_positions, i)
        lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
        hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
    end
    half = (hi - lo) * 0.5
    return lo + half, half
end

_raycast_bounds_miss(rc::Raycaster, geo::BufferGeometry, morphed_positions,
                     wm::Mat4, pad::Float64) =
    _raycast_bounds_miss(rc, _raycast_local_bounds(geo, morphed_positions), wm, pad)

function _raycast_bounds_miss(rc::Raycaster, bounds::NTuple{2,Vec3{Float64}},
                              wm::Mat4, pad::Float64)
    e = wm.e
    (e[4] == 0.0 && e[8] == 0.0 && e[12] == 0.0 && e[16] == 1.0) || return false
    local_center, half = bounds
    _finite_vec3(local_center) && _finite_vec3(half) || return false
    scale = _mat4_linear_max_scale(wm)
    center = mat4_transform_point(wm, local_center)
    radius = norm(half) * scale + pad
    origin = rc.ray.origin
    magnitude = norm(center) + norm(local_center) * scale + hypot(e[13], e[14], e[15])
    reach = radius + 1.0e-9 * (radius + norm(center - origin) + magnitude)
    isfinite(reach) && _finite_vec3(center) || return false
    _, gap = _ray_point_distance(origin, rc.ray.direction, center)
    return isfinite(gap) && gap > reach
end

function _raycast_points!(hits,rc::Raycaster,obj,geo::BufferGeometry,wm::Mat4,
                            morphed_positions,instance_id=nothing)
    o,d = rc.ray.origin,rc.ray.direction
    thr = rc.point_threshold
    _raycast_bounds_miss(rc, geo, morphed_positions, wm, thr) && return hits
    filter = _ray_lateral_filter(rc, wm, thr)
    @inbounds for entry in _draw_entry_range(geo)
        vi = _draw_vertex_index(geo, entry)
        local_point = _geometry_vertex(geo, morphed_positions, vi)
        filter === nothing || _ray_lateral_code(filter, local_point) == 0x00 || continue
        p = mat4_transform_point(wm, local_point)
        t, dist = _ray_point_distance(o, d, p)
        if dist < thr && rc.near <= t <= rc.far
            # Hit location is the closest ray point (three.js Points testPoint);
            # face_index = vertex index.
            push!(hits, Intersection(t, o + d * t, obj, vi, instance_id,
                                     nothing, nothing, nothing, nothing, nothing,
                                     nothing, dist))
        end
    end
    return hits
end

function _raycast_lines!(hits,rc::Raycaster,obj,geo::BufferGeometry,wm::Mat4,
                           morphed_positions,mode::Symbol,instance_id=nothing)
    o,d = rc.ray.origin,rc.ray.direction
    thr = rc.line_threshold
    # LineSegments: disjoint pairs. LineObject: consecutive vertices.
    # LineLoop closes the final vertex back to the first, matching three.js.
    step = mode === :lines ? 2 : 1
    entries = _draw_entry_range(geo)
    isempty(entries) && return hits
    _raycast_bounds_miss(rc, geo, morphed_positions, wm, thr) && return hits
    codes = _ray_lateral_codes!(rc, geo, morphed_positions, wm, thr)
    first_entry = first(entries)
    last_entry = last(entries)
    @inbounds for entry in first_entry:step:(last_entry - 1)
        vi1 = _draw_vertex_index(geo, entry)
        vi2 = _draw_vertex_index(geo, entry + 1)
        _ray_lateral_rejects(codes, vi1, vi2) && continue
        a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi1))
        b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi2))
        t, dist, seg_pt = _ray_segment_distance(o, d, a, b)
        if dist <= thr && rc.near <= t <= rc.far
            # face_index = the segment's first draw entry, which three.js
            # reports as `index: i` (Line.js checkIntersection); it is the
            # start vertex for non-indexed geometry.
            push!(hits, Intersection(t, seg_pt, obj, entry, instance_id))
        end
    end
    # three.js Line.raycast tests a LineLoop's closing segment (last entry back
    # to the first) for any non-empty range, including one or two vertices.
    if mode === :line_loop
        vi1 = _draw_vertex_index(geo, last_entry)
        vi2 = _draw_vertex_index(geo, first_entry)
        _ray_lateral_rejects(codes, vi1, vi2) && return hits
        a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi1))
        b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi2))
        t, dist, seg_pt = _ray_segment_distance(o, d, a, b)
        if dist <= thr && rc.near <= t <= rc.far
            push!(hits, Intersection(t, seg_pt, obj, last_entry, instance_id))
        end
    end
    return hits
end

function _raycast_sprite!(hits,rc::Raycaster,obj::Sprite,wm::Mat4)
    camera = rc.camera
    camera === nothing && throw(ArgumentError(
        "Sprite picking requires a camera; call set_from_camera! or pass camera to Raycaster"))
    _validate_sprite_center(obj,"Sprite raycast")
    _validate_material_parameters(obj.material)
    a,b,c,d = _sprite_quad_corners(obj,obj.material,camera,wm,view_matrix(camera))
    origin,direction = rc.ray.origin,rc.ray.direction
    first_hit = _ray_triangle_intersect_unchecked(origin,direction,a,b,c,1e-9,:double)
    second_hit = _ray_triangle_intersect_unchecked(origin,direction,a,c,d,1e-9,:double)
    distance = first_hit === nothing ? second_hit :
               second_hit === nothing ? first_hit : min(first_hit,second_hit)
    if distance !== nothing && rc.near <= distance <= rc.far
        point = origin + direction * distance
        # three.js Sprite.raycast interpolates the corner UVs (0,0), (1,0),
        # (1,1) over the first triangle, or (0,0), (0,1), (1,1) over (a, d, c).
        uv = if distance === first_hit
            w = _hit_barycoord(point, a, b, c)
            Vec2(w.y + w.z, w.z)
        else
            w = _hit_barycoord(point, a, d, c)
            Vec2(w.z, w.y + w.z)
        end
        push!(hits, Intersection(distance, point, obj, 0, nothing, nothing, nothing,
                                 nothing, uv, nothing, nothing, nothing))
    end
    return hits
end

# Test a single object's own geometry against the ray, appending any hits to
# `hits`. Layers and visibility are already checked by the caller. Mesh uses the
# Möller–Trumbore triangle path; PointsObject uses per-vertex pick radius;
# LineObject/LineSegments use per-segment pick radius. Other object types (Group,
# Scene, Bone, ...) carry no testable geometry and add nothing. Sprites use
# their camera-facing quad.
function _raycast_object!(hits::Vector{Intersection}, rc::Raycaster,
                          obj::AbstractObject3D, wm::Mat4{Float64})
    o = rc.ray.origin; d = rc.ray.direction
    obj isa InstancedMesh && _validate_instanced_mesh(obj, "raycast")
    if obj isa Mesh
        geo = _mesh_geometry(obj)
        _validate_triangle_geometry_indices(geo, "raycast")
        morphed_positions = _raycast_morph_positions(rc, obj, geo)
        _raycast_bounds_miss(rc, geo, morphed_positions, wm, 0.0) && return hits
        # Cull by material side like three.js Mesh.raycast (default :front).
        _raycast_triangles!(hits, rc, obj, geo, morphed_positions, wm,
                            material_side(_mesh_material(obj)), nothing)
    elseif obj isa InstancedMesh
        geo = _instanced_geometry(obj)
        triangle_mode = _instanced_triangle_drawable(obj)
        if triangle_mode
            _validate_triangle_geometry_indices(geo,"raycast")
        else
            _validate_indexed_geometry(geo,"raycast")
        end
        side = triangle_mode ? material_side(_instanced_material(obj)) : :double
        bounds = _raycast_local_bounds(geo, nothing)
        @inbounds for (instance_index,im) in pairs(obj.instance_matrices)
            m = wm*im
            if triangle_mode
                _raycast_bounds_miss(rc, bounds, m, 0.0) && continue
                _raycast_triangles!(hits, rc, obj, geo, nothing, m, side,
                                    instance_index)
            elseif _instanced_point_drawable(obj)
                _raycast_points!(hits,rc,obj,geo,m,nothing,instance_index)
            else
                _raycast_lines!(hits,rc,obj,geo,m,nothing,obj.draw_mode,instance_index)
            end
        end
    elseif obj isa SkinnedMesh
        # Raycast the posed (skinned) geometry the rasterizer actually renders, so
        # a visibly-rendered skinned mesh is pickable (was silently skipped).
        geo = _skinned_buffer_geometry(obj)
        _validate_triangle_geometry_indices(geo, "raycast")
        _validate_skinned_mesh(obj, "SkinnedMesh")
        mats = _skinning_matrices!(rc.skinning_matrices, obj, :world)
        morphed_positions = _raycast_morph_positions(rc, obj, geo)
        side = _raycast_world_side(material_side(obj.material), wm)
        # Pose each vertex once (faces share vertices); skinned positions are
        # already in world space.
        posed = rc.skinned_positions
        resize!(posed, geo.n_vertices)
        @inbounds for vi in 1:geo.n_vertices
            posed[vi] = _raycast_skinned_vertex(obj, geo, mats, morphed_positions, vi)
        end
        codes = _ray_lateral_codes!(rc, geo, posed, Mat4{Float64}(), 0.0)
        @inbounds for fi in _draw_face_range(geo)
            i1, i2, i3 = get_face(geo, fi)
            _ray_lateral_rejects(codes, i1, i2, i3) && continue
            a = posed[i1]
            b = posed[i2]
            c = posed[i3]
            t = _ray_triangle_watertight(o, d, a, b, c, side)
            if t !== nothing && rc.near <= t <= rc.far
                push!(hits, _triangle_intersection(obj, t, rc, fi, nothing, geo,
                                                   i1, i2, i3, a, b, c,
                                                   nothing, wm))
            end
        end
    elseif obj isa PointsObject
        geo = _points_geometry(obj)
        _validate_indexed_geometry(geo,"raycast")
        morphed_positions = _raycast_morph_positions(rc,obj,geo)
        _raycast_points!(hits,rc,obj,geo,wm,morphed_positions)
    elseif obj isa LineObject || obj isa LineSegments || obj isa LineLoop
        geo = _line_geometry(obj)
        _validate_indexed_geometry(geo,"raycast")
        morphed_positions = _raycast_morph_positions(rc,obj,geo)
        mode = obj isa LineSegments ? :lines : obj isa LineLoop ? :line_loop : :line_strip
        _raycast_lines!(hits,rc,obj,geo,wm,morphed_positions,mode)
    elseif obj isa Sprite
        _raycast_sprite!(hits,rc,obj,wm)
    elseif obj isa LOD
        _raycast_lod!(hits,rc,obj,wm)
    end
    return hits
end

# three.js LOD.raycast: test only the level chosen for the ray-origin distance.
function _raycast_lod!(hits::Vector{Intersection}, rc::Raycaster, lod::LOD,
                       wm::Mat4{Float64})
    isempty(lod.levels) && return hits
    origin = Vec3(wm.e[13], wm.e[14], wm.e[15])
    level = lod_select(lod, min(distance(rc.ray.origin, origin), floatmax(Float64)))
    return _raycast_object!(hits, rc, level, wm * compute_local_matrix(level))
end

_raycast_object!(hits::Vector{Intersection}, rc::Raycaster, obj::AbstractObject3D) =
    _raycast_object!(hits, rc, obj, compute_world_matrix(obj))

# Parent world matrices live in a per-depth stack: passing an isbits Mat4
# through the dynamically dispatched child call would box it per object.
function _raycast_recursive_child!(hits::Vector{Intersection}, rc::Raycaster,
                                   child::AbstractObject3D,
                                   worlds::Vector{Mat4{Float64}}, depth::Int)
    child_world = @inbounds(worlds[depth]) * compute_local_matrix(child)
    return _raycast_recursive!(hits, rc, child, child_world, worlds, depth + 1)
end

function _raycast_recursive!(hits::Vector{Intersection}, rc::Raycaster,
                             obj::AbstractObject3D, world::Mat4{Float64},
                             worlds::Vector{Mat4{Float64}}=Mat4{Float64}[],
                             depth::Int=1)
    is_visible(obj) || return hits
    _layers_test_object(obj, rc.layers) && _raycast_object!(hits, rc, obj, world)
    children = get_children(obj)
    isempty(children) && return hits
    length(worlds) < depth && resize!(worlds, depth)
    @inbounds worlds[depth] = world
    for child in children
        is_visible(child) || continue
        _raycast_recursive_child!(hits, rc, child, worlds, depth)
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
vertices and line segments, including instanced draw modes, use the raycaster's
`point_threshold`/`line_threshold` pick radii (three.js `params.Points`/`Line`).
Instance hits carry a 1-based `instance_id`. Sprites use their camera-facing quad;
configure their camera with `set_from_camera!` or `Raycaster(...; camera=camera)`.
Objects whose layer mask shares no channel with `rc.layers` are skipped (their
children are still traversed when `recursive`). Invisible objects are skipped
hierarchically, matching the renderer: an object inside a `visible = false`
ancestor is not pickable. Like three.js `LOD.raycast`, an `LOD` itself tests the
level `lod_select` picks for the ray-origin distance; a recursive cast then also
visits the LOD's visible children, so that level can be reported twice.
"""
function raycast(rc::Raycaster, root::AbstractObject3D; recursive::Bool=true)
    _validate_raycaster!(rc)
    # Hits collect in the raycaster's scratch vector and are copied out at
    # their exact count: an Intersection is 256 bytes, and growing a fresh
    # vector by push! would reserve several of them even for a single hit.
    hits = rc.hits
    empty!(hits)
    try
        if recursive
            _visible_in_tree(root) &&
                _raycast_recursive!(hits, rc, root, compute_world_matrix(root),
                                    rc.worlds)
        else
            if _visible_in_tree(root) && _layers_test_object(root, rc.layers)
                _raycast_object!(hits, rc, root, compute_world_matrix(root))
            end
        end
        sort!(hits; lt=_intersection_distance_lt)
        return copy(hits)
    finally
        # Drop the scratch references so hit objects are not kept alive.
        empty!(hits)
    end
end
