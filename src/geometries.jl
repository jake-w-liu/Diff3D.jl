# --------------------------------------------------------------------------
# BufferGeometry and parametric geometry generators.
# Vertex data stored as flat Float64 arrays; face indices as Int arrays.
# --------------------------------------------------------------------------

struct BufferAttribute{T}
    data::Vector{T}
    item_size::Int  # components per vertex (3 for position, 2 for uv, etc.)
end

# Generator keywords are user-controlled and several constructors multiply two
# subdivision axes. Keep the existing one-million-subdivision policy, then cap
# every generated flat buffer at six entries per subdivision (the index cost of
# two triangles). This prevents individually valid axes from becoming
# multi-terabyte cross-products while still allowing million-segment 1D meshes.
const _GEOMETRY_MAX_SUBDIVISIONS = 1_000_000
const _GEOMETRY_MAX_BUFFER_ELEMENTS = 6 * _GEOMETRY_MAX_SUBDIVISIONS

@inline function _geometry_checked_add(a::Int, b::Int, label::String)
    try
        return Base.checked_add(a, b)
    catch err
        err isa OverflowError || rethrow()
        throw(ArgumentError("$label is too large"))
    end
end

@inline function _geometry_checked_mul(a::Int, b::Int, label::String)
    try
        return Base.checked_mul(a, b)
    catch err
        err isa OverflowError || rethrow()
        throw(ArgumentError("$label is too large"))
    end
end

@inline function _geometry_checked_mul(a::Int, b::Int, label::String,
                                       context::String)
    try
        return Base.checked_mul(a, b)
    catch err
        err isa OverflowError || rethrow()
        throw(ArgumentError("$label $context is too large"))
    end
end

function _geometry_mesh_buffer_lengths(n_vertices::Int, n_faces::Int,
                                       label::String)
    n_vertices >= 0 || throw(ArgumentError("$label vertex count is too large"))
    n_faces >= 0 || throw(ArgumentError("$label face count is too large"))
    position_len = _geometry_checked_mul(3, n_vertices, label, "position buffer")
    uv_len = _geometry_checked_mul(2, n_vertices, label, "UV buffer")
    index_len = _geometry_checked_mul(3, n_faces, label, "index buffer")
    max(position_len, uv_len, index_len) <= _GEOMETRY_MAX_BUFFER_ELEMENTS ||
        throw(ArgumentError(
            "$label generated buffer exceeds the " *
            "$_GEOMETRY_MAX_BUFFER_ELEMENTS-element safety limit"))
    return position_len, uv_len, index_len
end

mutable struct BufferGeometry
    positions::Vector{Float64}   # flat: [x1,y1,z1, x2,y2,z2, ...]
    normals::Vector{Float64}     # flat: [nx1,ny1,nz1, ...]
    uvs::Vector{Float64}         # flat: [u1,v1, u2,v2, ...]
    indices::Vector{Int}         # triangle face indices (1-based)
    n_vertices::Int
    n_faces::Int
    attributes::Dict{Symbol, BufferAttribute}   # generic named attributes (e.g. :color, :tangent)
    # Draw groups (three.js BufferGeometry.groups): each tuple is
    # (start, count, material_index) where `start` is the 1-based index of the
    # FIRST face in the group, `count` is the number of consecutive faces, and
    # `material_index` is the 0-based material slot (matching three.js
    # `materialIndex`). Empty means a single material covers the whole geometry.
    # NOTE: three.js measures start/count in index-buffer entries; here they are
    # expressed in faces (triangles), which is this engine's natural draw unit.
    groups::Vector{NTuple{3,Int}}
    # Draw range (three.js BufferGeometry.drawRange) as (start, count), where
    # start is a 1-based draw-entry index and count is the number of entries.
    # Draw entries are the exported/rendered index list, or vertices for
    # unindexed line/point geometry.
    draw_range::Union{Nothing,NTuple{2,Int}}

    # Inner constructors keep every existing positional/0-arg/6-arg call working
    # by defaulting `attributes`, `groups`, and `draw_range`. New fields are LAST so prior
    # callers that pass 6 or 7 positional arguments are unaffected.
    BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces) =
        new(positions, normals, uvs, indices, n_vertices, n_faces,
            Dict{Symbol, BufferAttribute}(), NTuple{3,Int}[], nothing)

    BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces, attributes) =
        new(positions, normals, uvs, indices, n_vertices, n_faces,
            attributes, NTuple{3,Int}[], nothing)

    BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces, attributes, groups) =
        new(positions, normals, uvs, indices, n_vertices, n_faces, attributes, groups, nothing)

    BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces,
                   attributes, groups, draw_range) =
        new(positions, normals, uvs, indices, n_vertices, n_faces,
            attributes, groups, draw_range)
end

function BufferGeometry()
    BufferGeometry(Float64[], Float64[], Float64[], Int[], 0, 0)
end

function _validate_geometry_vertex_count(geo::BufferGeometry, context::String)
    geo.n_vertices >= 0 || throw(ArgumentError("$context n_vertices must be non-negative"))
    geo.n_vertices <= typemax(Int) ÷ 3 ||
        throw(ArgumentError("$context n_vertices is too large"))
    return nothing
end

function _validate_geometry_vertices(geo::BufferGeometry, context::String)
    _validate_geometry_vertex_count(geo, context)
    length(geo.positions) >= 3 * geo.n_vertices ||
        throw(ArgumentError("$context positions length must cover n_vertices"))
    return nothing
end

function _validate_geometry_face_count(geo::BufferGeometry, context::String)
    geo.n_faces >= 0 || throw(ArgumentError("$context n_faces must be non-negative"))
    geo.n_faces <= typemax(Int) ÷ 3 ||
        throw(ArgumentError("$context n_faces is too large"))
    return nothing
end

function _validate_geometry_index_values(geo::BufferGeometry, context::String,
                                         label::String)
    @inbounds for index in geo.indices
        1 <= index <= geo.n_vertices ||
            throw(ArgumentError("$context $label must reference vertices"))
    end
    return nothing
end

function _validate_indexed_geometry(geo::BufferGeometry, context::String)
    _validate_geometry_vertices(geo, context)
    _validate_geometry_index_values(geo, context, "indices")
    return nothing
end

function _validate_triangle_geometry_indices(geo::BufferGeometry, context::String)
    _validate_geometry_vertices(geo, context)
    _validate_geometry_face_count(geo, context)
    length(geo.indices) >= 3 * geo.n_faces ||
        throw(ArgumentError("$context indices length must cover n_faces"))
    _validate_geometry_index_values(geo, context, "face indices")
    return nothing
end

function _geometry_int(value::Integer, label::String)
    value isa Bool && throw(ArgumentError("$label must be an integer"))
    try
        return Int(value)
    catch
        throw(ArgumentError("$label is too large"))
    end
end
_geometry_int(value, label::String) = throw(ArgumentError("$label must be an integer"))

function _geometry_nonnegative_int(value::Integer, label::String)
    n = _geometry_int(value, label)
    n >= 0 || throw(ArgumentError("$label must be non-negative"))
    n <= _GEOMETRY_MAX_SUBDIVISIONS ||
        throw(ArgumentError("$label must not exceed $_GEOMETRY_MAX_SUBDIVISIONS"))
    return n
end
_geometry_nonnegative_int(value, label::String) = throw(ArgumentError("$label must be an integer"))

function _geometry_positive_int(value::Integer, label::String)
    n = _geometry_int(value, label)
    n >= 1 || throw(ArgumentError("$label must be positive"))
    n <= _GEOMETRY_MAX_SUBDIVISIONS ||
        throw(ArgumentError("$label must not exceed $_GEOMETRY_MAX_SUBDIVISIONS"))
    return n
end
_geometry_positive_int(value, label::String) = throw(ArgumentError("$label must be an integer"))

function _geometry_finite_scalar(value, label::String)
    value isa Bool && throw(ArgumentError("$label must be finite"))
    ok = try
        isfinite(value)
    catch
        false
    end
    ok || throw(ArgumentError("$label must be finite"))
    return value
end

function _geometry_finite_float(value, label::String)
    checked = _geometry_finite_scalar(value, label)
    out = try
        Float64(checked)
    catch
        throw(ArgumentError("$label must be representable as Float64"))
    end
    isfinite(out) ||
        throw(ArgumentError("$label must be representable as Float64"))
    return out
end

@inline function _geometry_check_abs_sum(a::Float64, b::Float64,
                                         label::String)
    abs(a) <= floatmax(Float64) - abs(b) ||
        throw(ArgumentError("$label generated positions exceed the Float64 range"))
    return nothing
end

@noinline _geometry_position_range_error(label::String) =
    throw(ArgumentError("$label generated positions exceed the Float64 range"))

@inline function _geometry_check_position(x::Float64, y::Float64, z::Float64,
                                          label::String)
    (isfinite(x) && isfinite(y) && isfinite(z)) ||
        _geometry_position_range_error(label)
    return nothing
end

@inline function _geometry_unit2(x::Float64, y::Float64)
    len = hypot(x, y)
    if len > 0.0
        if isfinite(len)
            return x / len, y / len
        end

        # `hypot(floatmax, floatmax)` can exceed Float64 even though its unit
        # direction is representable. Scale before normalizing in that case.
        scale = max(abs(x), abs(y))
        xs, ys = x / scale, y / scale
        scaled_len = hypot(xs, ys)
        return xs / scaled_len, ys / scaled_len
    end
    return 0.0, 0.0
end

@inline function _geometry_unit_delta2(ax::Float64, ay::Float64,
                                       bx::Float64, by::Float64)
    dx, dy = bx - ax, by - ay
    if isfinite(dx) && isfinite(dy)
        return _geometry_unit2(dx, dy)
    end

    # Subtracting opposite, individually finite Float64 endpoints can overflow.
    # Their scaled difference has the same direction and remains representable.
    scale = max(abs(ax), abs(ay), abs(bx), abs(by))
    scale > 0.0 || return 0.0, 0.0
    return _geometry_unit2(
        bx / scale - ax / scale,
        by / scale - ay / scale,
    )
end

@inline function _geometry_delta_norm3(ax::Float64, ay::Float64, az::Float64,
                                       bx::Float64, by::Float64, bz::Float64)
    return hypot(bx - ax, by - ay, bz - az)
end

@inline function _geometry_unit_delta3(ax::Float64, ay::Float64, az::Float64,
                                       bx::Float64, by::Float64, bz::Float64)
    dx, dy, dz = bx - ax, by - ay, bz - az
    if isfinite(dx) && isfinite(dy) && isfinite(dz)
        return normalize(Vec3(dx, dy, dz))
    end

    scale = max(
        max(max(abs(ax), abs(ay)), abs(az)),
        max(max(abs(bx), abs(by)), abs(bz)),
    )
    scale > 0.0 || return Vec3(0.0, 0.0, 0.0)
    return normalize(Vec3(
        bx / scale - ax / scale,
        by / scale - ay / scale,
        bz / scale - az / scale,
    ))
end

function _geometry_nonzero_finite_scalar(value, label::String)
    _geometry_finite_scalar(value, label)
    value != zero(value) || throw(ArgumentError("$label must be finite and non-zero"))
    return value
end

"""
    add_group!(geo, start, count, material_index)

Append a draw group to `geo` (three.js `BufferGeometry.addGroup`). `start` is the
1-based index of the first face, `count` the number of consecutive faces, and
`material_index` the 0-based material slot. Returns `geo`.
"""
function add_group!(g::BufferGeometry, start::Integer, count::Integer, material_index::Integer)
    start_i = _geometry_int(start, "group start")
    count_i = _geometry_int(count, "group count")
    material_i = _geometry_int(material_index, "group material_index")
    start_i >= 1 || throw(ArgumentError("group start must be at least 1"))
    count_i >= 0 || throw(ArgumentError("group count must be non-negative"))
    material_i >= 0 || throw(ArgumentError("group material_index must be non-negative"))
    push!(g.groups, (start_i, count_i, material_i))
    return g
end

"""Draw groups of `geo` as `(start, count, material_index)` tuples (three.js `BufferGeometry.groups`)."""
get_groups(g::BufferGeometry) = g.groups

"""Remove all draw groups (three.js `BufferGeometry.clearGroups`)."""
function clear_groups!(g::BufferGeometry)
    empty!(g.groups)
    return g
end

"""
    set_draw_range!(geo, start, count)

Set the geometry draw range (three.js `BufferGeometry.setDrawRange`). `start` is
the 1-based index of the first draw entry, and `count` is the number of entries.
Draw entries are triangle/line/point index-buffer entries, or vertices for
unindexed line/point geometry. Returns `geo`.
"""
function set_draw_range!(g::BufferGeometry, start::Integer, count::Integer)
    start_i = _geometry_int(start, "draw range start")
    count_i = _geometry_int(count, "draw range count")
    start_i >= 1 || throw(ArgumentError("draw range start must be at least 1"))
    count_i >= 0 || throw(ArgumentError("draw range count must be non-negative"))
    g.draw_range = (start_i, count_i)
    return g
end

"""Draw range of `geo` as `(start, count)`, or `nothing` when the whole geometry is drawn."""
get_draw_range(g::BufferGeometry) = g.draw_range

"""Clear the geometry draw range so the whole geometry is drawn."""
function clear_draw_range!(g::BufferGeometry)
    g.draw_range = nothing
    return g
end

@inline _draw_entry_count(g::BufferGeometry) = isempty(g.indices) ? g.n_vertices : length(g.indices)

function _draw_entry_range(g::BufferGeometry)
    total = _draw_entry_count(g)
    total <= 0 && return 1:0
    g.draw_range === nothing && return 1:total
    start, count = g.draw_range
    first_entry = clamp(start, 1, total + 1)
    clamped_count = min(count, max(total - first_entry + 1, 0))
    return first_entry:(first_entry + clamped_count - 1)
end

@inline _draw_vertex_index(g::BufferGeometry, entry::Int) =
    isempty(g.indices) ? entry : g.indices[entry]

function _draw_face_range(g::BufferGeometry)
    g.n_faces <= 0 && return 1:0
    entries = _draw_entry_range(g)
    isempty(entries) && return 1:0
    first_face = max(1, cld(first(entries) + 2, 3))
    last_face = min(g.n_faces, fld(last(entries), 3))
    return first_face:last_face
end

"""Attach a generic named vertex attribute (three.js `setAttribute`)."""
function set_attribute!(g::BufferGeometry, name::Symbol, data::Vector, item_size::Int)
    item_size > 0 || throw(ArgumentError("geometry attribute item_size must be positive"))
    rem(length(data), item_size) == 0 ||
        throw(ArgumentError("geometry attribute data length must be divisible by item_size"))
    g.attributes[name] = BufferAttribute(data, item_size)
    return g
end

get_attribute(g::BufferGeometry, name::Symbol) = g.attributes[name]
has_attribute(g::BufferGeometry, name::Symbol) = haskey(g.attributes, name)

function _line_distance_write!(distances::Vector{Float64}, seen::Vector{Bool},
                               vertex_index::Int, value::Float64)
    if seen[vertex_index]
        isapprox(distances[vertex_index], value; atol=1e-8, rtol=1e-8) ||
            throw(ArgumentError("indexed dashed lines require one lineDistance per vertex; duplicate vertex $(vertex_index) needs conflicting distances"))
    else
        distances[vertex_index] = value
        seen[vertex_index] = true
    end
    return nothing
end

@inline function _line_distance_checked_index(geo::BufferGeometry, idx::Int)
    1 <= idx <= geo.n_vertices ||
        throw(ArgumentError("geometry indices must be within 1:n_vertices"))
    return idx
end

function _line_distance_output!(geo::BufferGeometry, fill_value::Float64=0.0)
    attr = get(geo.attributes, :lineDistance, nothing)
    if attr isa BufferAttribute{Float64} && attr.item_size == 1 &&
       length(attr.data) == geo.n_vertices
        fill!(attr.data, fill_value)
        return attr.data
    end
    distances = fill(fill_value, geo.n_vertices)
    geo.attributes[:lineDistance] = BufferAttribute(distances, 1)
    return distances
end

"""
    compute_line_distances!(geo; mode=:line_strip)

Compute and attach the `:lineDistance` attribute used by dashed line rendering.
Use `mode=:line_strip` for `LineObject`, `mode=:lines` for `LineSegments`, and
`mode=:line_loop` for `LineLoop`. Returns `geo`.
"""
function compute_line_distances!(geo::BufferGeometry; mode::Symbol=:line_strip)
    mode in (:line_strip, :line_loop, :lines) ||
        throw(ArgumentError("mode must be :line_strip, :line_loop, or :lines"))
    length(geo.positions) == 3 * geo.n_vertices ||
        throw(ArgumentError("geometry positions length must equal 3 * n_vertices"))

    if isempty(geo.indices)
        if mode === :lines
            iseven(geo.n_vertices) ||
                throw(ArgumentError("LineSegments distance computation requires an even vertex count"))
        end
        draw_distances = _line_distance_output!(geo)
        if mode === :lines
            i = 1
            while i <= geo.n_vertices
                draw_distances[i] = 0.0
                draw_distances[i + 1] = distance(get_vertex(geo, i),
                                                 get_vertex(geo, i + 1))
                i += 2
            end
        elseif geo.n_vertices > 0
            total = 0.0
            draw_distances[1] = 0.0
            for i in 2:geo.n_vertices
                total += distance(get_vertex(geo, i - 1), get_vertex(geo, i))
                draw_distances[i] = total
            end
        end
        return geo
    end

    order = geo.indices
    distances = _line_distance_output!(geo, NaN)
    if mode === :lines
        iseven(length(order)) ||
            throw(ArgumentError("LineSegments distance computation requires an even vertex count"))
        i = 1
        while i <= length(order)
            a = _line_distance_checked_index(geo, order[i])
            b = _line_distance_checked_index(geo, order[i + 1])
            _line_distance_write!(distances, a, 0.0)
            _line_distance_write!(distances, b, distance(get_vertex(geo, a),
                                                         get_vertex(geo, b)))
            i += 2
        end
    elseif !isempty(order)
        prev = _line_distance_checked_index(geo, order[1])
        _line_distance_write!(distances, prev, 0.0)
        total = 0.0
        for i in 2:length(order)
            curr = _line_distance_checked_index(geo, order[i])
            total += distance(get_vertex(geo, prev), get_vertex(geo, curr))
            _line_distance_write!(distances, curr, total)
            prev = curr
        end
    end
    @inbounds for i in eachindex(distances)
        isnan(distances[i]) && (distances[i] = 0.0)
    end
    return geo
end

function _line_distance_write!(distances::Vector{Float64},
                               vertex_index::Int, value::Float64)
    if isnan(distances[vertex_index])
        distances[vertex_index] = value
    else
        isapprox(distances[vertex_index], value; atol=1e-8, rtol=1e-8) ||
            throw(ArgumentError("indexed dashed lines require one lineDistance per vertex; duplicate vertex $(vertex_index) needs conflicting distances"))
    end
    return nothing
end

@noinline _throw_morph_influence(ti::Int) =
    throw(ArgumentError("morph target influence $ti must be finite"))

function _morph_finite_float(value::Real, ti::Int)
    value isa Bool && _throw_morph_influence(ti)
    out = try
        Float64(value)
    catch
        _throw_morph_influence(ti)
    end
    isfinite(out) || _throw_morph_influence(ti)
    return out
end
_morph_finite_float(value, ti::Int) = _throw_morph_influence(ti)

@inline _morph_influence(weight::Real, ti::Int) =
    _morph_finite_float(weight, ti)

@inline function _morph_active_weight(weight::Real, ti::Int)
    weight isa Bool && _throw_morph_influence(ti)
    iszero(weight) && return 0.0
    return _morph_influence(weight, ti)
end

const _MORPH_SYMBOL_LOCK = ReentrantLock()
const _MORPH_POSITION_SYMBOLS = Dict{Int,Symbol}()
const _MORPH_NORMAL_SYMBOLS = Dict{Int,Symbol}()
const _MORPH_TANGENT_SYMBOLS = Dict{Int,Symbol}()

function _morph_symbol!(cache::Dict{Int,Symbol}, prefix::Symbol,
                        zero_based_index::Int)
    zero_based_index >= 0 || throw(ArgumentError("morph target index must be non-negative"))
    lock(_MORPH_SYMBOL_LOCK)
    try
        cached = get(cache, zero_based_index, nothing)
        cached === nothing || return cached
        name = Symbol(prefix, zero_based_index)
        cache[zero_based_index] = name
        return name
    finally
        unlock(_MORPH_SYMBOL_LOCK)
    end
end

@inline _morph_position_symbol(ti::Int) =
    _morph_symbol!(_MORPH_POSITION_SYMBOLS, :morphPosition, ti - 1)
@inline _morph_normal_symbol(ti::Int) =
    _morph_symbol!(_MORPH_NORMAL_SYMBOLS, :morphNormal, ti - 1)
@inline _morph_tangent_symbol(ti::Int) =
    _morph_symbol!(_MORPH_TANGENT_SYMBOLS, :morphTangent, ti - 1)

_float64_copy(data::Vector{Float64}) = copy(data)
_float64_copy(data) = Float64.(data)

@noinline function _throw_morph_attribute_value(name::Symbol)
    throw(ArgumentError("$name attribute data must be finite"))
end

@inline function _morph_attribute_value(attr::BufferAttribute{Float64}, idx::Int, name::Symbol)
    out = attr.data[idx]
    isfinite(out) || _throw_morph_attribute_value(name)
    return out
end

@inline function _morph_attribute_value(attr::BufferAttribute, idx::Int, name::Symbol)
    value = attr.data[idx]
    value isa Bool && _throw_morph_attribute_value(name)
    out = try
        Float64(value)
    catch
        _throw_morph_attribute_value(name)
    end
    isfinite(out) || _throw_morph_attribute_value(name)
    return out
end

@noinline _throw_morph_position_item_size(name::Symbol) =
    throw(ArgumentError("$name attribute must have item size 3"))

@noinline _throw_morph_vec3_item_size(name::Symbol) =
    throw(ArgumentError("$name attribute must have at least 3 components"))

@noinline _throw_morph_attribute_count(name::Symbol) =
    throw(ArgumentError("$name count does not match geometry"))

@noinline _throw_morph_attribute_size(name::Symbol) =
    throw(ArgumentError("$name attribute buffer is too large"))

function _validate_morph_position_attribute(attr::BufferAttribute, name::Symbol,
                                            n_vertices::Int)
    attr.item_size == 3 || _throw_morph_position_item_size(name)
    0 <= n_vertices <= typemax(Int) ÷ 3 || _throw_morph_attribute_size(name)
    length(attr.data) == 3 * n_vertices || _throw_morph_attribute_count(name)
    @inbounds for vi in 1:n_vertices
        base = 3vi - 2
        _morph_attribute_value(attr, base, name)
        _morph_attribute_value(attr, base + 1, name)
        _morph_attribute_value(attr, base + 2, name)
    end
    return nothing
end

function _validate_morph_vec3_attribute(attr::BufferAttribute, name::Symbol,
                                        n_vertices::Int)
    attr.item_size >= 3 || _throw_morph_vec3_item_size(name)
    0 <= n_vertices <= typemax(Int) ÷ attr.item_size ||
        _throw_morph_attribute_size(name)
    length(attr.data) >= n_vertices * attr.item_size ||
        _throw_morph_attribute_count(name)
    @inbounds for vi in 1:n_vertices
        base = (vi - 1) * attr.item_size + 1
        _morph_attribute_value(attr, base, name)
        _morph_attribute_value(attr, base + 1, name)
        _morph_attribute_value(attr, base + 2, name)
    end
    return nothing
end

function _validate_morph_influences(influences::AbstractVector{<:Real})
    @inbounds for ti in eachindex(influences)
        _morph_active_weight(influences[ti], ti)
    end
    return nothing
end

function _validate_morph_position_targets(g::BufferGeometry,
                                          influences::AbstractVector{<:Real})
    for (ti, weight) in enumerate(influences)
        w = _morph_active_weight(weight, ti)
        w == 0.0 && continue
        name = _morph_position_symbol(ti)
        has_attribute(g, name) || continue
        _validate_morph_position_attribute(get_attribute(g, name), name, g.n_vertices)
    end
    return nothing
end

@inline _morph_vec3_symbol(::Val{:normal}, ti::Int) = _morph_normal_symbol(ti)
@inline _morph_vec3_symbol(::Val{:tangent}, ti::Int) = _morph_tangent_symbol(ti)

function _validate_morph_vec3_targets(g::BufferGeometry,
                                      influences::AbstractVector{<:Real}, kind::Val)
    for (ti, weight) in enumerate(influences)
        w = _morph_active_weight(weight, ti)
        w == 0.0 && continue
        name = _morph_vec3_symbol(kind, ti)
        has_attribute(g, name) || continue
        _validate_morph_vec3_attribute(get_attribute(g, name), name, g.n_vertices)
    end
    return nothing
end

function _apply_morph_position_attr!(out::Vector{Vec3{Float64}}, attr::BufferAttribute,
                                     w::Float64, name::Symbol, n_vertices::Int)
    attr.item_size == 3 || _throw_morph_position_item_size(name)
    0 <= n_vertices <= typemax(Int) ÷ 3 || _throw_morph_attribute_size(name)
    length(attr.data) == n_vertices * 3 || _throw_morph_attribute_count(name)
    @inbounds for vi in 1:n_vertices
        base = 3vi - 2
        delta = Vec3(_morph_attribute_value(attr, base, name),
                     _morph_attribute_value(attr, base + 1, name),
                     _morph_attribute_value(attr, base + 2, name))
        out[vi] = out[vi] + delta * w
    end
    return out
end

@inline function _apply_morph_position_attr_dispatch!(
        out::Vector{Vec3{Float64}}, attr::BufferAttribute,
        w::Float64, name::Symbol, n_vertices::Int)
    if attr isa BufferAttribute{Float64}
        return _apply_morph_position_attr!(out, attr, w, name, n_vertices)
    end
    return _apply_morph_position_attr!(out, attr, w, name, n_vertices)
end

function _apply_morph_targets_validated!(out::Vector{Vec3{Float64}},
                                         g::BufferGeometry,
                                         influences::AbstractVector{<:Real})
    resize!(out, g.n_vertices)
    positions = g.positions
    @inbounds for vi in 1:g.n_vertices
        base = 3vi - 2
        out[vi] = Vec3(positions[base], positions[base + 1], positions[base + 2])
    end
    for (ti, weight) in enumerate(influences)
        w = _morph_active_weight(weight, ti)
        w == 0.0 && continue
        name = _morph_position_symbol(ti)
        has_attribute(g, name) || continue
        attr = get_attribute(g, name)
        _apply_morph_position_attr_dispatch!(out, attr, w, name, g.n_vertices)
    end
    return out
end

function apply_morph_targets!(out::Vector{Vec3{Float64}}, g::BufferGeometry,
                              influences::AbstractVector{<:Real})
    _validate_geometry_vertices(g, "apply_morph_targets")
    _validate_morph_position_targets(g, influences)
    return _apply_morph_targets_validated!(out, g, influences)
end

function apply_morph_targets(g::BufferGeometry, influences::AbstractVector{<:Real})
    _validate_geometry_vertices(g, "apply_morph_targets")
    _validate_morph_position_targets(g, influences)
    return _apply_morph_targets_validated!(
        Vector{Vec3{Float64}}(undef, g.n_vertices), g, influences)
end

function _object_morph_positions(obj, geo::BufferGeometry)
    hasproperty(obj, :morph_target_influences) || return nothing
    influences = getproperty(obj, :morph_target_influences)
    _has_active_morph_influences(influences) || return nothing
    return apply_morph_targets(geo, influences)
end

function _object_morph_positions(obj, geo::BufferGeometry,
                                 scratch::Vector{Vec3{Float64}})
    hasproperty(obj, :morph_target_influences) || return nothing
    influences = getproperty(obj, :morph_target_influences)
    _has_active_morph_influences(influences) || return nothing
    return apply_morph_targets!(scratch, geo, influences)
end

_object_morph_positions(obj, geo::BufferGeometry, ::Nothing) =
    _object_morph_positions(obj, geo)

function _has_active_morph_influences(influences::AbstractVector{<:Real})
    @inbounds for i in eachindex(influences)
        iszero(influences[i]) || return true
    end
    return false
end

@inline _geometry_vertex(geo::BufferGeometry, morphed_positions::Nothing, i::Int) =
    get_vertex(geo, i)
@inline _geometry_vertex(geo::BufferGeometry, morphed_positions::AbstractVector, i::Int) =
    morphed_positions[i]

function _normalize_attribute3!(data::Vector{Float64}, n_vertices::Int, item_size::Int)
    @inbounds for vi in 1:n_vertices
        base = (vi - 1) * item_size + 1
        n = normalize(Vec3(data[base], data[base + 1], data[base + 2]))
        data[base] = n.x
        data[base + 1] = n.y
        data[base + 2] = n.z
    end
    return data
end

function _apply_morph_attribute3_attr!(out::Vector{Float64}, attr::BufferAttribute,
                                       w::Float64, name::Symbol, n_vertices::Int,
                                       dst_item_size::Int)
    attr.item_size >= 3 || _throw_morph_vec3_item_size(name)
    0 <= n_vertices <= typemax(Int) ÷ attr.item_size ||
        _throw_morph_attribute_size(name)
    length(attr.data) >= n_vertices * attr.item_size ||
        _throw_morph_attribute_count(name)
    @inbounds for vi in 1:n_vertices
        dst = (vi - 1) * dst_item_size + 1
        src = (vi - 1) * attr.item_size + 1
        out[dst] += _morph_attribute_value(attr, src, name) * w
        out[dst + 1] += _morph_attribute_value(attr, src + 1, name) * w
        out[dst + 2] += _morph_attribute_value(attr, src + 2, name) * w
    end
    return out
end

@inline function _apply_morph_attribute3_attr_dispatch!(
        out::Vector{Float64}, attr::BufferAttribute, w::Float64,
        name::Symbol, n_vertices::Int, dst_item_size::Int)
    if attr isa BufferAttribute{Float64}
        return _apply_morph_attribute3_attr!(
            out, attr, w, name, n_vertices, dst_item_size)
    end
    return _apply_morph_attribute3_attr!(
        out, attr, w, name, n_vertices, dst_item_size)
end

function _apply_morph_normals_validated!(out::Vector{Float64}, g::BufferGeometry,
                                         influences::AbstractVector{<:Real})
    resize!(out, length(g.normals))
    copyto!(out, 1, g.normals, 1, length(g.normals))
    for (ti, weight) in enumerate(influences)
        w = _morph_active_weight(weight, ti)
        w == 0.0 && continue
        name = _morph_normal_symbol(ti)
        has_attribute(g, name) || continue
        attr = get_attribute(g, name)
        _apply_morph_attribute3_attr_dispatch!(out, attr, w, name, g.n_vertices, 3)
    end
    return _normalize_attribute3!(out, g.n_vertices, 3)
end

"""
    apply_morph_normals(geo, influences)

Apply `morphNormal*` target deltas to `geo.normals` and normalize each resulting
normal. Returns a flat normal buffer.
"""
function apply_morph_normals(g::BufferGeometry, influences::AbstractVector{<:Real})
    _validate_geometry_vertex_count(g, "apply_morph_normals")
    length(g.normals) >= g.n_vertices * 3 || return copy(g.normals)
    _validate_morph_vec3_targets(g, influences, Val(:normal))
    return _apply_morph_normals_validated!(
        Vector{Float64}(undef, length(g.normals)), g, influences)
end

function apply_morph_normals!(out::Vector{Float64}, g::BufferGeometry,
                              influences::AbstractVector{<:Real})
    _validate_geometry_vertex_count(g, "apply_morph_normals")
    if length(g.normals) < g.n_vertices * 3
        resize!(out, length(g.normals))
        length(g.normals) > 0 && copyto!(out, 1, g.normals, 1, length(g.normals))
        return out
    end
    _validate_morph_vec3_targets(g, influences, Val(:normal))
    return _apply_morph_normals_validated!(out, g, influences)
end

"""
    apply_morph_tangents(geo, influences)

Apply `morphTangent*` target deltas to the `:tangent` attribute when present,
normalizing tangent XYZ while preserving the tangent handedness component.
Returns a flat tangent attribute buffer, or an empty vector if no tangent
attribute exists.
"""
function apply_morph_tangents(g::BufferGeometry, influences::AbstractVector{<:Real})
    _validate_geometry_vertex_count(g, "apply_morph_tangents")
    has_attribute(g, :tangent) || return Float64[]
    base_attr = get_attribute(g, :tangent)
    base_attr.item_size >= 3 &&
        g.n_vertices <= typemax(Int) ÷ base_attr.item_size &&
        length(base_attr.data) >= g.n_vertices * base_attr.item_size ||
        return _float64_copy(base_attr.data)
    _validate_morph_vec3_targets(g, influences, Val(:tangent))
    return _apply_morph_tangents_validated!(
        Vector{Float64}(undef, length(base_attr.data)), g, influences, base_attr)
end

function _apply_morph_tangents_validated!(out::Vector{Float64}, g::BufferGeometry,
                                          influences::AbstractVector{<:Real},
                                          base_attr::BufferAttribute)
    resize!(out, length(base_attr.data))
    copyto!(out, 1, base_attr.data, 1, length(base_attr.data))
    for (ti, weight) in enumerate(influences)
        w = _morph_active_weight(weight, ti)
        w == 0.0 && continue
        name = _morph_tangent_symbol(ti)
        has_attribute(g, name) || continue
        attr = get_attribute(g, name)
        _apply_morph_attribute3_attr_dispatch!(
            out, attr, w, name, g.n_vertices, base_attr.item_size)
    end
    return _normalize_attribute3!(out, g.n_vertices, base_attr.item_size)
end

function apply_morph_tangents!(out::Vector{Float64}, g::BufferGeometry,
                               influences::AbstractVector{<:Real})
    _validate_geometry_vertex_count(g, "apply_morph_tangents")
    has_attribute(g, :tangent) || (empty!(out); return out)
    base_attr = get_attribute(g, :tangent)
    if !(base_attr.item_size >= 3 &&
         g.n_vertices <= typemax(Int) ÷ base_attr.item_size &&
         length(base_attr.data) >= g.n_vertices * base_attr.item_size)
        resize!(out, length(base_attr.data))
        length(base_attr.data) > 0 && copyto!(out, 1, base_attr.data, 1, length(base_attr.data))
        return out
    end
    _validate_morph_vec3_targets(g, influences, Val(:tangent))
    return _apply_morph_tangents_validated!(out, g, influences, base_attr)
end

function _compute_bounding_box_validated(g::BufferGeometry)
    box = Box3()
    @inbounds for vi in 1:g.n_vertices
        box = box3_expand_by_point(box, get_vertex(g, vi))
    end
    return box
end

@inline function _geometry_midpoint(a::Float64, b::Float64)
    a == b && return a
    if signbit(a) == signbit(b)
        return a + (b - a) * 0.5
    end
    return a * 0.5 + b * 0.5
end

"""Axis-aligned bounding box of the geometry (three.js `computeBoundingBox`)."""
function compute_bounding_box(g::BufferGeometry)
    _validate_geometry_vertices(g, "compute_bounding_box")
    g.n_vertices == 0 && return Box3()
    return _compute_bounding_box_validated(g)
end

"""Bounding sphere centred on the box centre (three.js `computeBoundingSphere`)."""
function compute_bounding_sphere(g::BufferGeometry)
    _validate_geometry_vertices(g, "compute_bounding_sphere")
    g.n_vertices == 0 && return BoundingSphere(Vec3(), 0.0)
    box = _compute_bounding_box_validated(g)
    center = Vec3(
        _geometry_midpoint(box.min.x, box.max.x),
        _geometry_midpoint(box.min.y, box.max.y),
        _geometry_midpoint(box.min.z, box.max.z),
    )
    radius = 0.0
    @inbounds for vi in 1:g.n_vertices
        d = get_vertex(g, vi) - center
        radius = max(radius, norm(d))
    end
    return BoundingSphere(center, radius)
end

function get_vertex(g::BufferGeometry, i::Int)
    idx = (i - 1) * 3
    Vec3(g.positions[idx+1], g.positions[idx+2], g.positions[idx+3])
end

function get_normal(g::BufferGeometry, i::Int)
    idx = (i - 1) * 3
    Vec3(g.normals[idx+1], g.normals[idx+2], g.normals[idx+3])
end

function get_face(g::BufferGeometry, i::Int)
    idx = (i - 1) * 3
    (g.indices[idx+1], g.indices[idx+2], g.indices[idx+3])
end

function compute_face_normal(g::BufferGeometry, face_idx::Int)
    i1, i2, i3 = get_face(g, face_idx)
    v1 = get_vertex(g, i1)
    v2 = get_vertex(g, i2)
    v3 = get_vertex(g, i3)
    triangle_normal(Triangle(v1, v2, v3))
end

# ========================== Box Geometry ==========================

function _geometry_segment_count(name::String, value)
    value isa Bool &&
        throw(ArgumentError("$name must be a positive integer"))
    try
        n = Int(value)
        n >= 1 || throw(ArgumentError("$name must be at least 1"))
        n <= _GEOMETRY_MAX_SUBDIVISIONS ||
            throw(ArgumentError(
                "$name must not exceed $_GEOMETRY_MAX_SUBDIVISIONS"))
        return n
    catch err
        err isa ArgumentError && rethrow()
        throw(ArgumentError("$name must be a positive integer"))
    end
end

function _box_write_vertex!(positions::Vector{Float64}, normals_arr::Vector{Float64},
                            uvs_arr::Vector{Float64}, dst::Int, p, n, u, v)
    pbase = 3dst - 2
    ubase = 2dst - 1
    positions[pbase] = p.x
    positions[pbase + 1] = p.y
    positions[pbase + 2] = p.z
    normals_arr[pbase] = n.x
    normals_arr[pbase + 1] = n.y
    normals_arr[pbase + 2] = n.z
    uvs_arr[ubase] = u
    uvs_arr[ubase + 1] = v
    return nothing
end

function _box_add_quad_face!(positions::Vector{Float64}, normals_arr::Vector{Float64},
                             uvs_arr::Vector{Float64}, indices::Vector{Int},
                             vi::Int, out::Int, p1, p2, p3, p4, n)
    base = vi + 1
    _box_write_vertex!(positions, normals_arr, uvs_arr, base, p1, n, 0.0, 0.0)
    _box_write_vertex!(positions, normals_arr, uvs_arr, base + 1, p2, n, 1.0, 0.0)
    _box_write_vertex!(positions, normals_arr, uvs_arr, base + 2, p3, n, 1.0, 1.0)
    _box_write_vertex!(positions, normals_arr, uvs_arr, base + 3, p4, n, 0.0, 1.0)
    indices[out] = base
    indices[out + 1] = base + 1
    indices[out + 2] = base + 2
    indices[out + 3] = base
    indices[out + 4] = base + 2
    indices[out + 5] = base + 3
    return vi + 4, out + 6
end

function _box_add_grid_face!(positions::Vector{Float64}, normals_arr::Vector{Float64},
                             uvs_arr::Vector{Float64}, indices::Vector{Int},
                             vi::Int, out::Int, p1, p2, p3, p4, n,
                             u_segments::Int, v_segments::Int)
    base = vi + 1
    row = u_segments + 1
    for j in 0:v_segments
        tv = j / v_segments
        left = p1 * (1 - tv) + p4 * tv
        right = p2 * (1 - tv) + p3 * tv
        for i in 0:u_segments
            tu = i / u_segments
            p = left * (1 - tu) + right * tu
            _box_write_vertex!(positions, normals_arr, uvs_arr,
                               base + j * row + i, p, n, tu, tv)
        end
    end
    for j in 0:(v_segments - 1), i in 0:(u_segments - 1)
        a = base + j * row + i
        b = a + 1
        d0 = a + row
        c = d0 + 1
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = c
        indices[out + 3] = a
        indices[out + 4] = c
        indices[out + 5] = d0
        out += 6
    end
    return vi + row * (v_segments + 1), out
end

function _box_add_face!(positions::Vector{Float64}, normals_arr::Vector{Float64},
                        uvs_arr::Vector{Float64}, indices::Vector{Int},
                        vi::Int, out::Int, use_quad_faces::Bool,
                        p1, p2, p3, p4, n, u_segments::Int, v_segments::Int)
    return use_quad_faces ?
        _box_add_quad_face!(positions, normals_arr, uvs_arr, indices,
                            vi, out, p1, p2, p3, p4, n) :
        _box_add_grid_face!(positions, normals_arr, uvs_arr, indices,
                            vi, out, p1, p2, p3, p4, n, u_segments, v_segments)
end

function BoxGeometry(; width=1.0, height=1.0, depth=1.0,
                     width_segments=1, height_segments=1, depth_segments=1)
    width = _geometry_finite_float(width, "BoxGeometry width")
    height = _geometry_finite_float(height, "BoxGeometry height")
    depth = _geometry_finite_float(depth, "BoxGeometry depth")
    ws = _geometry_segment_count("width_segments", width_segments)
    hs = _geometry_segment_count("height_segments", height_segments)
    ds = _geometry_segment_count("depth_segments", depth_segments)
    w, h, d = width/2, height/2, depth/2

    # Vertices are duplicated per face so each face keeps flat normals and UVs.
    n_verts = 2 * ((ws + 1) * (hs + 1) +
                   (ws + 1) * (ds + 1) +
                   (ds + 1) * (hs + 1))
    n_faces = 4 * (ws * hs + ws * ds + ds * hs)
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "BoxGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    use_quad_faces = ws == 1 && hs == 1 && ds == 1

    vi = 0
    out = 1

    # +Z face
    vi, out = _box_add_face!(positions, normals_arr, uvs_arr, indices, vi, out,
                             use_quad_faces, Vec3(-w,-h,d), Vec3(w,-h,d),
                             Vec3(w,h,d), Vec3(-w,h,d), Vec3(0,0,1), ws, hs)
    # -Z face
    vi, out = _box_add_face!(positions, normals_arr, uvs_arr, indices, vi, out,
                             use_quad_faces, Vec3(w,-h,-d), Vec3(-w,-h,-d),
                             Vec3(-w,h,-d), Vec3(w,h,-d), Vec3(0,0,-1), ws, hs)
    # +Y face
    vi, out = _box_add_face!(positions, normals_arr, uvs_arr, indices, vi, out,
                             use_quad_faces, Vec3(-w,h,d), Vec3(w,h,d),
                             Vec3(w,h,-d), Vec3(-w,h,-d), Vec3(0,1,0), ws, ds)
    # -Y face
    vi, out = _box_add_face!(positions, normals_arr, uvs_arr, indices, vi, out,
                             use_quad_faces, Vec3(-w,-h,-d), Vec3(w,-h,-d),
                             Vec3(w,-h,d), Vec3(-w,-h,d), Vec3(0,-1,0), ws, ds)
    # +X face
    vi, out = _box_add_face!(positions, normals_arr, uvs_arr, indices, vi, out,
                             use_quad_faces, Vec3(w,-h,d), Vec3(w,-h,-d),
                             Vec3(w,h,-d), Vec3(w,h,d), Vec3(1,0,0), ds, hs)
    # -X face
    vi, out = _box_add_face!(positions, normals_arr, uvs_arr, indices, vi, out,
                             use_quad_faces, Vec3(-w,-h,-d), Vec3(-w,-h,d),
                             Vec3(-w,h,d), Vec3(-w,h,-d), Vec3(-1,0,0), ds, hs)

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# Coerce a segment-count keyword to an Int >= lo, finite-safe. A non-finite
# (NaN/Inf) or absurdly large value would throw InexactError in Int(floor(...));
# clamp into the generator subdivision range first and map non-finite to the
# minimum.
function _clamp_seg(s::Real, lo::Int, label::String)
    s isa Bool && throw(ArgumentError("$label must be numeric"))
    sf = try
        Float64(s)
    catch
        throw(ArgumentError("$label must be numeric"))
    end
    return isfinite(sf) ?
           Int(floor(clamp(sf, Float64(lo),
                           Float64(_GEOMETRY_MAX_SUBDIVISIONS)))) : lo
end
_clamp_seg(s, lo::Int, label::String) = throw(ArgumentError("$label must be numeric"))
@inline _clamp_seg(s, lo::Int) = _clamp_seg(s, lo, "segment count")

# ========================== Sphere Geometry ==========================

function SphereGeometry(; radius=1.0, width_segments=32, height_segments=16)
    radius = _geometry_finite_float(radius, "SphereGeometry radius")
    # Clamp to a valid minimum (matching three.js), else degenerate counts produce
    # an empty/NaN sphere from a plausible call.
    width_segments = _clamp_seg(width_segments, 3, "SphereGeometry width_segments")
    height_segments = _clamp_seg(height_segments, 2, "SphereGeometry height_segments")
    n_verts = (height_segments + 1) * (width_segments + 1)
    n_faces = 2 * width_segments * (height_segments - 1)
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "SphereGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    for j in 0:height_segments
        v = j / height_segments
        θ = v * π
        sinθ = sin(θ)
        cosθ = cos(θ)
        for i in 0:width_segments
            u = i / width_segments
            ϕ = u * 2π
            sinϕ = sin(ϕ)
            cosϕ = cos(ϕ)

            x = -radius * sinθ * cosϕ
            y = radius * cosθ
            z = radius * sinθ * sinϕ

            nx, ny, nz = -sinθ * cosϕ, cosθ, sinθ * sinϕ
            nl = hypot(nx, ny, nz)
            if nl > 0
                nx /= nl; ny /= nl; nz /= nl
            end

            vi = j * (width_segments + 1) + i + 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = x
            positions[pbase + 1] = y
            positions[pbase + 2] = z
            normals_arr[pbase] = nx
            normals_arr[pbase + 1] = ny
            normals_arr[pbase + 2] = nz
            uvs_arr[ubase] = u
            uvs_arr[ubase + 1] = 1.0 - v
        end
    end

    out = 1
    for j in 0:height_segments-1
        for i in 0:width_segments-1
            a = j * (width_segments + 1) + i + 1
            b = a + 1
            c = a + (width_segments + 1)
            d = c + 1

            if j != 0
                indices[out] = a
                indices[out + 1] = d
                indices[out + 2] = b
                out += 3
            end
            if j != height_segments - 1
                indices[out] = a
                indices[out + 1] = c
                indices[out + 2] = d
                out += 3
            end
        end
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Plane Geometry ==========================

function PlaneGeometry(; width=1.0, height=1.0, width_segments=1, height_segments=1)
    width = _geometry_finite_float(width, "PlaneGeometry width")
    height = _geometry_finite_float(height, "PlaneGeometry height")
    # Clamp segment counts (matching SphereGeometry/three.js) so a 0 cannot make
    # the per-segment step a 0/0 = NaN that silently poisons positions/UVs.
    width_segments = _clamp_seg(width_segments, 1, "PlaneGeometry width_segments")
    height_segments = _clamp_seg(height_segments, 1, "PlaneGeometry height_segments")
    n_verts = (width_segments + 1) * (height_segments + 1)
    n_faces = 2 * width_segments * height_segments
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "PlaneGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    hw, hh = width/2, height/2
    for iy in 0:height_segments
        ty = iy / height_segments
        y = (1.0 - ty) * (-hh) + ty * hh
        for ix in 0:width_segments
            tx = ix / width_segments
            x = (1.0 - tx) * (-hw) + tx * hw
            vi = iy * (width_segments + 1) + ix + 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = x
            positions[pbase + 1] = -y
            positions[pbase + 2] = 0.0
            normals_arr[pbase] = 0.0
            normals_arr[pbase + 1] = 0.0
            normals_arr[pbase + 2] = 1.0
            uvs_arr[ubase] = ix / width_segments
            uvs_arr[ubase + 1] = 1.0 - iy / height_segments
        end
    end

    out = 1
    for iy in 0:height_segments-1
        for ix in 0:width_segments-1
            a = iy * (width_segments + 1) + ix + 1
            b = a + 1
            c = a + (width_segments + 1)
            d = c + 1
            indices[out] = a
            indices[out + 1] = d
            indices[out + 2] = b
            indices[out + 3] = a
            indices[out + 4] = c
            indices[out + 5] = d
            out += 6
        end
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Cylinder Geometry ==========================

function CylinderGeometry(; radius_top=1.0, radius_bottom=1.0, height=1.0,
                           radial_segments=32, height_segments=1, open_ended=false)
    radius_top = _geometry_finite_float(radius_top, "CylinderGeometry radius_top")
    radius_bottom = _geometry_finite_float(radius_bottom, "CylinderGeometry radius_bottom")
    height = _geometry_finite_float(height, "CylinderGeometry height")
    # Clamp segment counts so a 0 cannot produce NaN geometry (see PlaneGeometry).
    radial_segments = _clamp_seg(radial_segments, 3, "CylinderGeometry radial_segments")
    height_segments = _clamp_seg(height_segments, 1, "CylinderGeometry height_segments")
    side_vertices = (height_segments + 1) * (radial_segments + 1)
    top_cap = !open_ended && radius_top > 0
    bottom_cap = !open_ended && radius_bottom > 0
    cap_count = (top_cap ? 1 : 0) + (bottom_cap ? 1 : 0)
    n_verts = side_vertices + cap_count * (radial_segments + 2)
    n_faces = 2 * radial_segments * height_segments + cap_count * radial_segments
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "CylinderGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    vi = 0

    half_h = height / 2
    # Normalize `(1, (radius_bottom-radius_top)/height)` without first forming
    # an overflowing radius difference or quotient. Preserve the established
    # radial fallback for a zero-height, degenerate cylinder.
    side_radial, side_y = if height == 0.0
        (1.0, 0.0)
    else
        h_component, radius_component = _geometry_unit_delta2(
            0.0, radius_top, height, radius_bottom)
        height_sign = sign(height)
        (h_component * height_sign, radius_component * height_sign)
    end

    # Side
    for y_seg in 0:height_segments
        v = y_seg / height_segments
        r = (1.0 - v) * radius_top + v * radius_bottom
        y_pos = half_h - v * height

        for x_seg in 0:radial_segments
            u = x_seg / radial_segments
            θ = u * 2π
            sinθ = sin(θ)
            cosθ = cos(θ)

            x = r * sinθ
            z = r * cosθ

            nx = side_radial * sinθ
            ny = side_y
            nz = side_radial * cosθ
            nl = hypot(nx, ny, nz)
            nx /= nl; ny /= nl; nz /= nl

            vi += 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = x
            positions[pbase + 1] = y_pos
            positions[pbase + 2] = z
            normals_arr[pbase] = nx
            normals_arr[pbase + 1] = ny
            normals_arr[pbase + 2] = nz
            uvs_arr[ubase] = u
            uvs_arr[ubase + 1] = 1.0 - v
        end
    end

    out = 1
    for y_seg in 0:height_segments-1
        for x_seg in 0:radial_segments-1
            a = y_seg * (radial_segments + 1) + x_seg + 1
            b = a + 1
            c = a + (radial_segments + 1)
            d = c + 1
            indices[out] = a
            indices[out + 1] = d
            indices[out + 2] = b
            indices[out + 3] = a
            indices[out + 4] = c
            indices[out + 5] = d
            out += 6
        end
    end

    # Caps
    if !open_ended
        for cap_index in 1:2
            cap_y = cap_index == 1 ? half_h : -half_h
            cap_r = cap_index == 1 ? radius_top : radius_bottom
            cap_ny = cap_index == 1 ? 1.0 : -1.0
            cap_r > 0 || continue   # skip degenerate zero-radius cap (e.g. cone apex)
            center_idx = vi + 1
            vi += 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = 0.0
            positions[pbase + 1] = cap_y
            positions[pbase + 2] = 0.0
            normals_arr[pbase] = 0.0
            normals_arr[pbase + 1] = cap_ny
            normals_arr[pbase + 2] = 0.0
            uvs_arr[ubase] = 0.5
            uvs_arr[ubase + 1] = 0.5

            for x_seg in 0:radial_segments
                u = x_seg / radial_segments
                θ = u * 2π
                sinθ = sin(θ)
                cosθ = cos(θ)
                x = cap_r * sinθ
                z = cap_r * cosθ

                vi += 1
                pbase = 3vi - 2
                ubase = 2vi - 1
                positions[pbase] = x
                positions[pbase + 1] = cap_y
                positions[pbase + 2] = z
                normals_arr[pbase] = 0.0
                normals_arr[pbase + 1] = cap_ny
                normals_arr[pbase + 2] = 0.0
                uvs_arr[ubase] = sinθ * 0.5 + 0.5
                uvs_arr[ubase + 1] = cosθ * 0.5 + 0.5
            end

            for x_seg in 0:radial_segments-1
                curr = center_idx + 1 + x_seg
                next_v = curr + 1
                if cap_ny > 0
                    indices[out] = center_idx
                    indices[out + 1] = curr
                    indices[out + 2] = next_v
                else
                    indices[out] = center_idx
                    indices[out + 1] = next_v
                    indices[out + 2] = curr
                end
                out += 3
            end
        end
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, vi, n_faces)
end

# ========================== Cone Geometry ==========================

function ConeGeometry(; radius=1.0, height=1.0, radial_segments=32, height_segments=1,
                       open_ended=false)
    radius = _geometry_finite_float(radius, "ConeGeometry radius")
    height = _geometry_finite_float(height, "ConeGeometry height")
    CylinderGeometry(; radius_top=0.0, radius_bottom=radius, height=height,
                      radial_segments=radial_segments, height_segments=height_segments,
                      open_ended=open_ended)
end

# ========================== Torus Geometry ==========================

function TorusGeometry(; radius=1.0, tube=0.4, radial_segments=16, tubular_segments=48)
    radius = _geometry_finite_float(radius, "TorusGeometry radius")
    tube = _geometry_finite_float(tube, "TorusGeometry tube")
    _geometry_check_abs_sum(radius, tube, "TorusGeometry")
    # Clamp segment counts so a 0 cannot produce NaN geometry (see PlaneGeometry).
    radial_segments = _clamp_seg(radial_segments, 2, "TorusGeometry radial_segments")
    tubular_segments = _clamp_seg(tubular_segments, 3, "TorusGeometry tubular_segments")
    n_verts = (radial_segments + 1) * (tubular_segments + 1)
    n_faces = 2 * radial_segments * tubular_segments
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "TorusGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    tube_direction = sign(tube)

    for j in 0:radial_segments
        vj = j / radial_segments
        v = vj * 2π
        cosv = cos(v)
        sinv = sin(v)
        r_tube = radius + tube * cosv
        for i in 0:tubular_segments
            ui = i / tubular_segments
            u = ui * 2π
            cosu = cos(u)
            sinu = sin(u)
            vi = j * (tubular_segments + 1) + i + 1
            pbase = 3vi - 2
            ubase = 2vi - 1

            x = r_tube * cosu
            y = r_tube * sinu
            z = tube * sinv

            # Recovering the normal as `position - ring_center` loses a small
            # tube completely when the major radius is very large. Its analytic
            # direction is independent of the major radius.
            nx = tube_direction * cosv * cosu
            ny = tube_direction * cosv * sinu
            nz = tube_direction * sinv
            nl = hypot(nx, ny, nz)
            if nl > 0
                nx /= nl; ny /= nl; nz /= nl
            end

            positions[pbase] = x
            positions[pbase + 1] = y
            positions[pbase + 2] = z
            normals_arr[pbase] = nx
            normals_arr[pbase + 1] = ny
            normals_arr[pbase + 2] = nz
            uvs_arr[ubase] = ui
            uvs_arr[ubase + 1] = vj
        end
    end

    out = 1
    for j in 1:radial_segments
        for i in 1:tubular_segments
            a = (j - 1) * (tubular_segments + 1) + i
            b = a + 1
            c = j * (tubular_segments + 1) + i
            d = c + 1
            indices[out] = a
            indices[out + 1] = b
            indices[out + 2] = d
            indices[out + 3] = a
            indices[out + 4] = d
            indices[out + 5] = c
            out += 6
        end
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== TorusKnot Geometry ==========================

@inline function _torus_knot_phase(frequency::Float64, parameter::Float64)
    turns = frequency * parameter
    phase = turns * (2pi)
    return isfinite(phase) ? phase : rem(turns, 1.0) * (2pi)
end

function _torus_knot_point(radius::Float64, p_val::Float64,
                           q_val::Float64, parameter::Float64)
    p_phase = _torus_knot_phase(p_val, parameter)
    q_phase = _torus_knot_phase(q_val, parameter)
    half_radius = radius * 0.5
    radial = half_radius * (2.0 + cos(q_phase))
    point = Vec3(radial * cos(p_phase), radial * sin(p_phase),
                 half_radius * sin(q_phase))
    return point, p_phase, q_phase
end

function _torus_knot_tangent(radius::Float64, p_val::Float64,
                             q_val::Float64, p_phase::Float64,
                             q_phase::Float64)
    half_radius = radius * 0.5
    radial = half_radius * (2.0 + cos(q_phase))
    radial_derivative = -half_radius * q_val * sin(q_phase)
    tangent = Vec3(
        radial_derivative * cos(p_phase) -
            radial * p_val * sin(p_phase),
        radial_derivative * sin(p_phase) +
            radial * p_val * cos(p_phase),
        half_radius * q_val * cos(q_phase),
    )
    tangent_length = norm(tangent)
    if isfinite(tangent_length) && tangent_length > 0.0
        return tangent / tangent_length
    end
    return setprecision(BigFloat, 256) do
        half = BigFloat(radius) / 2
        p = BigFloat(p_val)
        q = BigFloat(q_val)
        cp = BigFloat(cos(p_phase))
        sp = BigFloat(sin(p_phase))
        cq = BigFloat(cos(q_phase))
        sq = BigFloat(sin(q_phase))
        r = half * (2 + cq)
        dr = -half * q * sq
        dx = dr * cp - r * p * sp
        dy = dr * sp + r * p * cp
        dz = half * q * cq
        length_big = sqrt(dx * dx + dy * dy + dz * dz)
        iszero(length_big) && return Vec3(0.0, 0.0, 1.0)
        Vec3(Float64(dx / length_big), Float64(dy / length_big),
             Float64(dz / length_big))
    end
end

function _torus_knot_frame(tangent::Vec3{Float64}, center::Vec3{Float64})
    seed = normalize(center)
    binormal = cross(tangent, seed)
    if iszero(norm(binormal))
        axis = abs(tangent.z) < 0.9 ? Vec3(0.0, 0.0, 1.0) :
               Vec3(0.0, 1.0, 0.0)
        binormal = cross(tangent, axis)
    end
    binormal = normalize(binormal)
    normal = cross(binormal, tangent)
    return normal, binormal
end

function TorusKnotGeometry(; radius=1.0, tube=0.4, tubular_segments=64,
                            radial_segments=8, p_val=2, q_val=3)
    radius = _geometry_finite_float(radius, "TorusKnotGeometry radius")
    tube = _geometry_finite_float(tube, "TorusKnotGeometry tube")
    abs(radius) <= (floatmax(Float64) - abs(tube)) / 1.5 ||
        throw(ArgumentError(
            "TorusKnotGeometry generated positions exceed the Float64 range"))
    p_val = _geometry_finite_float(
        _geometry_nonzero_finite_scalar(
            p_val, "TorusKnotGeometry p_val"),
        "TorusKnotGeometry p_val")
    !iszero(p_val) ||
        throw(ArgumentError(
            "TorusKnotGeometry p_val must be representable as non-zero Float64"))
    q_val = _geometry_finite_float(
        _geometry_finite_scalar(q_val, "TorusKnotGeometry q_val"),
        "TorusKnotGeometry q_val")
    # Clamp segment counts so a 0 can't make i/tubular_segments or j/radial_segments
    # a 0/0 = NaN, matching every sibling generator in this file.
    tubular_segments = _clamp_seg(tubular_segments, 3, "TorusKnotGeometry tubular_segments")
    radial_segments = _clamp_seg(radial_segments, 3, "TorusKnotGeometry radial_segments")
    n_verts = (tubular_segments + 1) * (radial_segments + 1)
    n_faces = 2 * tubular_segments * radial_segments
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "TorusKnotGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    for i in 0:tubular_segments
        ui = i / tubular_segments
        p1, p_phase, q_phase = _torus_knot_point(
            radius, p_val, q_val, ui)
        T_vec = _torus_knot_tangent(
            radius, p_val, q_val, p_phase, q_phase)
        N_vec, B_vec = _torus_knot_frame(T_vec, p1)

        for j in 0:radial_segments
            vj = j / radial_segments
            v = vj * 2π
            cx = tube * cos(v)
            cy = tube * sin(v)
            px = p1.x + cx * N_vec.x + cy * B_vec.x
            py = p1.y + cx * N_vec.y + cy * B_vec.y
            pz = p1.z + cx * N_vec.z + cy * B_vec.z

            # Use the already available local displacement. Subtracting it
            # back from a large knot position can erase the tube by cancellation.
            nx = cx * N_vec.x + cy * B_vec.x
            ny = cx * N_vec.y + cy * B_vec.y
            nz = cx * N_vec.z + cy * B_vec.z
            nl = hypot(nx, ny, nz)
            if nl > 0
                nx /= nl; ny /= nl; nz /= nl
            end
            isfinite(px) && isfinite(py) && isfinite(pz) ||
                throw(ArgumentError(
                    "TorusKnotGeometry generated non-finite positions"))
            isfinite(nx) && isfinite(ny) && isfinite(nz) ||
                throw(ArgumentError(
                    "TorusKnotGeometry generated non-finite normals"))

            vi = i * (radial_segments + 1) + j + 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = px
            positions[pbase + 1] = py
            positions[pbase + 2] = pz
            normals_arr[pbase] = nx
            normals_arr[pbase + 1] = ny
            normals_arr[pbase + 2] = nz
            uvs_arr[ubase] = ui
            uvs_arr[ubase + 1] = vj
        end
    end

    out = 1
    for i in 1:tubular_segments
        for j in 1:radial_segments
            a = (i - 1) * (radial_segments + 1) + j
            b = a + 1
            c = i * (radial_segments + 1) + j
            d = c + 1
            indices[out] = a
            indices[out + 1] = b
            indices[out + 2] = d
            indices[out + 3] = a
            indices[out + 4] = d
            indices[out + 5] = c
            out += 6
        end
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Ring Geometry ==========================

function RingGeometry(; inner_radius=0.5, outer_radius=1.0, theta_segments=32, phi_segments=1)
    inner_radius = _geometry_finite_float(inner_radius, "RingGeometry inner_radius")
    outer_radius = _geometry_finite_float(outer_radius, "RingGeometry outer_radius")
    if !iszero(outer_radius)
        isfinite(inner_radius / outer_radius) ||
            throw(ArgumentError(
                "RingGeometry radii produce unrepresentable UV coordinates"))
    end
    # Clamp segment counts so a 0 cannot produce NaN geometry (see PlaneGeometry).
    theta_segments = _clamp_seg(theta_segments, 3, "RingGeometry theta_segments")
    phi_segments = _clamp_seg(phi_segments, 1, "RingGeometry phi_segments")
    n_verts = (phi_segments + 1) * (theta_segments + 1)
    n_faces = 2 * theta_segments * phi_segments
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "RingGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    uvd = outer_radius == 0 ? 1.0 : outer_radius

    for j in 0:phi_segments
        v = j / phi_segments
        r = (1.0 - v) * inner_radius + v * outer_radius
        for i in 0:theta_segments
            u = i / theta_segments
            θ = u * 2π
            x = r * cos(θ)
            y = r * sin(θ)
            vi = j * (theta_segments + 1) + i + 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = x
            positions[pbase + 1] = y
            positions[pbase + 2] = 0.0
            normals_arr[pbase] = 0.0
            normals_arr[pbase + 1] = 0.0
            normals_arr[pbase + 2] = 1.0
            # outer_radius==0 is a degenerate ring (x=y=0); avoid 0/0=NaN UVs.
            uvs_arr[ubase] = (x / uvd + 1) / 2
            uvs_arr[ubase + 1] = (y / uvd + 1) / 2
        end
    end

    out = 1
    for j in 0:phi_segments-1
        for i in 0:theta_segments-1
            a = j * (theta_segments + 1) + i + 1
            b = a + 1
            c = a + (theta_segments + 1)
            d = c + 1
            indices[out] = a
            indices[out + 1] = d
            indices[out + 2] = b
            indices[out + 3] = a
            indices[out + 4] = c
            indices[out + 5] = d
            out += 6
        end
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Circle Geometry ==========================

function CircleGeometry(; radius=1.0, segments=32)
    radius = _geometry_finite_float(radius, "CircleGeometry radius")
    # Clamp segments so a 0 cannot make the angular step a 0/0 = NaN (see PlaneGeometry).
    segments = _clamp_seg(segments, 3, "CircleGeometry segments")
    n_verts = segments + 2
    n_faces = segments
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "CircleGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals_arr = Vector{Float64}(undef, position_len)
    uvs_arr = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    positions[1] = 0.0
    positions[2] = 0.0
    positions[3] = 0.0
    normals_arr[1] = 0.0
    normals_arr[2] = 0.0
    normals_arr[3] = 1.0
    uvs_arr[1] = 0.5
    uvs_arr[2] = 0.5

    for i in 0:segments
        θ = i / segments * 2π
        cosθ = cos(θ)
        sinθ = sin(θ)
        vi = i + 2
        pbase = 3vi - 2
        ubase = 2vi - 1
        positions[pbase] = radius * cosθ
        positions[pbase + 1] = radius * sinθ
        positions[pbase + 2] = 0.0
        normals_arr[pbase] = 0.0
        normals_arr[pbase + 1] = 0.0
        normals_arr[pbase + 2] = 1.0
        uvs_arr[ubase] = cosθ * 0.5 + 0.5
        uvs_arr[ubase + 1] = sinθ * 0.5 + 0.5
    end

    out = 1
    for i in 1:segments
        indices[out] = 1
        indices[out + 1] = i + 1
        indices[out + 2] = i + 2
        out += 3
    end

    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Icosahedron Geometry ==========================

const _ICOSAHEDRON_T = (1 + sqrt(5.0)) / 2

const _ICOSAHEDRON_BASE_VERTS = Vec3{Float64}[
    Vec3(-1.0,  _ICOSAHEDRON_T,  0.0),
    Vec3( 1.0,  _ICOSAHEDRON_T,  0.0),
    Vec3(-1.0, -_ICOSAHEDRON_T,  0.0),
    Vec3( 1.0, -_ICOSAHEDRON_T,  0.0),
    Vec3( 0.0, -1.0,  _ICOSAHEDRON_T),
    Vec3( 0.0,  1.0,  _ICOSAHEDRON_T),
    Vec3( 0.0, -1.0, -_ICOSAHEDRON_T),
    Vec3( 0.0,  1.0, -_ICOSAHEDRON_T),
    Vec3( _ICOSAHEDRON_T,  0.0, -1.0),
    Vec3( _ICOSAHEDRON_T,  0.0,  1.0),
    Vec3(-_ICOSAHEDRON_T,  0.0, -1.0),
    Vec3(-_ICOSAHEDRON_T,  0.0,  1.0),
]

const _ICOSAHEDRON_BASE_FACES = NTuple{3,Int}[
    (1,12,6), (1,6,2), (1,2,8), (1,8,11), (1,11,12),
    (2,6,10), (6,12,5), (12,11,3), (11,8,7), (8,2,9),
    (4,10,5), (4,5,3), (4,3,7), (4,7,9), (4,9,10),
    (10,6,5), (5,12,3), (3,11,7), (7,8,9), (9,2,10),
]

function IcosahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_float(radius, "IcosahedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "IcosahedronGeometry detail")
    PolyhedronGeometry(_ICOSAHEDRON_BASE_VERTS, _ICOSAHEDRON_BASE_FACES;
                       radius=radius, detail=detail)
end

# ========================== Utility ==========================

function count_triangles(g::BufferGeometry)
    g.n_faces
end

"""
    merge_geometries(geos; with_groups=true)

Merge multiple `BufferGeometry` objects into one (for batching). The merged
positions, normals, UVs, indices, and carried-over named attributes contain each
input's logical `n_vertices`/`n_faces` payload; surplus backing-array elements
are ignored. Normals are retained only when every nonempty input supplies a
complete logical normal buffer; otherwise the merged normals are left empty for
downstream recomputation. UVs follow the same all-or-empty rule. When
`with_groups=true` (default), a draw group is appended per input geometry
recording which faces came from which sub-mesh:
`(start, count, material_index)` with 1-based `start`, `count` equal to that
input's face count, and `material_index` equal to its 0-based position in `geos`.
Inputs that contribute no faces are skipped so empty groups are not emitted.
"""
function merge_geometries(geos::Vector{BufferGeometry}; with_groups::Bool=true)
    n_positions = 0
    n_normals = 0
    n_uvs = 0
    n_indices = 0
    total_verts = 0
    total_faces = 0
    merge_normals = true
    merge_uvs = true
    for g in geos
        _validate_triangle_geometry_indices(g, "merge_geometries")
        position_length = _geometry_checked_mul(
            g.n_vertices, 3, "merge_geometries positions length")
        merge_normals &= g.n_vertices == 0 ||
                         length(g.normals) >= position_length
        uv_length = _geometry_checked_mul(
            g.n_vertices, 2, "merge_geometries UV length")
        merge_uvs &= g.n_vertices == 0 || length(g.uvs) >= uv_length
        index_length = _geometry_checked_mul(
            g.n_faces, 3, "merge_geometries indices length")
        n_positions = _geometry_checked_add(
            n_positions, position_length, "merge_geometries positions length")
        n_indices = _geometry_checked_add(
            n_indices, index_length, "merge_geometries indices length")
        total_verts = _geometry_checked_add(
            total_verts, g.n_vertices, "merge_geometries vertex count")
        total_faces = _geometry_checked_add(
            total_faces, g.n_faces, "merge_geometries face count")
    end
    n_normals = merge_normals ? n_positions : 0
    n_uvs = merge_uvs ? _geometry_checked_mul(
        total_verts, 2, "merge_geometries UV length") : 0
    positions = Vector{Float64}(undef, n_positions)
    normals_arr = Vector{Float64}(undef, n_normals)
    uvs_arr = Vector{Float64}(undef, n_uvs)
    indices = Vector{Int}(undef, n_indices)
    offset = 0
    face_offset = 0
    groups = NTuple{3,Int}[]
    with_groups && sizehint!(groups, length(geos))
    pout = 1
    nout = 1
    uout = 1
    iout = 1

    for (mat_idx, g) in enumerate(geos)
        position_length = 3 * g.n_vertices
        normal_length = merge_normals ? position_length : 0
        uv_length = merge_uvs ? 2 * g.n_vertices : 0
        index_length = 3 * g.n_faces
        copyto!(positions, pout, g.positions, 1, position_length)
        if merge_normals
            copyto!(normals_arr, nout, g.normals, 1, normal_length)
        end
        if merge_uvs
            copyto!(uvs_arr, uout, g.uvs, 1, uv_length)
        end
        @inbounds for slot in 1:index_length
            indices[iout] = g.indices[slot] + offset
            iout += 1
        end
        if with_groups && g.n_faces > 0
            # mat_idx is 1-based; material_index is 0-based (three.js convention).
            push!(groups, (face_offset + 1, g.n_faces, mat_idx - 1))
        end
        pout += position_length
        nout += normal_length
        uout += uv_length
        offset += g.n_vertices
        face_offset += g.n_faces
    end

    merged_groups = with_groups ? groups : NTuple{3,Int}[]
    merged = BufferGeometry(positions, normals_arr, uvs_arr, indices,
                            total_verts, total_faces,
                            Dict{Symbol, BufferAttribute}(), merged_groups)

    # Carry over named attributes present on every input with matching item_size.
    if !isempty(geos)
        for (name, attr) in geos[1].attributes
            keep = all(g -> has_attribute(g, name) &&
                            get_attribute(g, name).item_size == attr.item_size &&
                            length(get_attribute(g, name).data) >=
                                _geometry_checked_mul(
                                    g.n_vertices, attr.item_size,
                                    "merge_geometries attribute length"), geos)
            keep || continue
            data_length = 0
            for g in geos
                logical_length = _geometry_checked_mul(
                    g.n_vertices, attr.item_size,
                    "merge_geometries attribute length")
                data_length = _geometry_checked_add(
                    data_length, logical_length,
                    "merge_geometries attribute length")
            end
            data = similar(attr.data, data_length)
            out = 1
            for g in geos
                src = get_attribute(g, name).data
                logical_length = g.n_vertices * attr.item_size
                copyto!(data, out, src, 1, logical_length)
                out += logical_length
            end
            set_attribute!(merged, name, data, attr.item_size)
        end
    end

    return merged
end
