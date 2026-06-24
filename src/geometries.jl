# --------------------------------------------------------------------------
# BufferGeometry and parametric geometry generators.
# Vertex data stored as flat Float64 arrays; face indices as Int arrays.
# --------------------------------------------------------------------------

struct BufferAttribute{T}
    data::Vector{T}
    item_size::Int  # components per vertex (3 for position, 2 for uv, etc.)
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

"""
    add_group!(geo, start, count, material_index)

Append a draw group to `geo` (three.js `BufferGeometry.addGroup`). `start` is the
1-based index of the first face, `count` the number of consecutive faces, and
`material_index` the 0-based material slot. Returns `geo`.
"""
function add_group!(g::BufferGeometry, start::Integer, count::Integer, material_index::Integer)
    push!(g.groups, (Int(start), Int(count), Int(material_index)))
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
    start_i = Int(start)
    count_i = Int(count)
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

    order = isempty(geo.indices) ? collect(1:geo.n_vertices) : geo.indices
    any(i -> i < 1 || i > geo.n_vertices, order) &&
        throw(ArgumentError("geometry indices must be within 1:n_vertices"))

    draw_distances = zeros(Float64, length(order))
    if mode === :lines
        iseven(length(order)) ||
            throw(ArgumentError("LineSegments distance computation requires an even vertex count"))
        i = 1
        while i <= length(order)
            draw_distances[i] = 0.0
            draw_distances[i + 1] = distance(get_vertex(geo, order[i]),
                                             get_vertex(geo, order[i + 1]))
            i += 2
        end
    elseif !isempty(order)
        total = 0.0
        draw_distances[1] = 0.0
        for i in 2:length(order)
            total += distance(get_vertex(geo, order[i - 1]), get_vertex(geo, order[i]))
            draw_distances[i] = total
        end
    end

    if isempty(geo.indices)
        set_attribute!(geo, :lineDistance, draw_distances, 1)
        return geo
    end

    distances = zeros(Float64, geo.n_vertices)
    seen = fill(false, geo.n_vertices)
    for (idx, value) in zip(order, draw_distances)
        _line_distance_write!(distances, seen, idx, value)
    end
    set_attribute!(geo, :lineDistance, distances, 1)
    return geo
end

function apply_morph_targets(g::BufferGeometry, influences::AbstractVector{<:Real})
    out = [get_vertex(g, vi) for vi in 1:g.n_vertices]
    for (ti, weight) in enumerate(influences)
        weight == 0 && continue
        name = Symbol("morphPosition$(ti - 1)")
        has_attribute(g, name) || continue
        attr = get_attribute(g, name)
        attr.item_size == 3 || error("$name attribute must have item size 3")
        length(attr.data) == g.n_vertices * 3 || error("$name count does not match geometry")
        @inbounds for vi in 1:g.n_vertices
            base = 3vi - 2
            out[vi] = out[vi] + Vec3(attr.data[base], attr.data[base + 1], attr.data[base + 2]) * Float64(weight)
        end
    end
    return out
end

function _object_morph_positions(obj, geo::BufferGeometry)
    hasproperty(obj, :morph_target_influences) || return nothing
    influences = getproperty(obj, :morph_target_influences)
    isempty(influences) && return nothing
    return apply_morph_targets(geo, influences)
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

"""
    apply_morph_normals(geo, influences)

Apply `morphNormal*` target deltas to `geo.normals` and normalize each resulting
normal. Returns a flat normal buffer.
"""
function apply_morph_normals(g::BufferGeometry, influences::AbstractVector{<:Real})
    length(g.normals) >= g.n_vertices * 3 || return copy(g.normals)
    out = copy(g.normals)
    for (ti, weight) in enumerate(influences)
        weight == 0 && continue
        name = Symbol("morphNormal$(ti - 1)")
        has_attribute(g, name) || continue
        attr = get_attribute(g, name)
        attr.item_size >= 3 || error("$name attribute must have at least 3 components")
        length(attr.data) >= g.n_vertices * attr.item_size || error("$name count does not match geometry")
        @inbounds for vi in 1:g.n_vertices
            dst = 3vi - 2
            src = (vi - 1) * attr.item_size + 1
            out[dst] += Float64(attr.data[src]) * Float64(weight)
            out[dst + 1] += Float64(attr.data[src + 1]) * Float64(weight)
            out[dst + 2] += Float64(attr.data[src + 2]) * Float64(weight)
        end
    end
    return _normalize_attribute3!(out, g.n_vertices, 3)
end

"""
    apply_morph_tangents(geo, influences)

Apply `morphTangent*` target deltas to the `:tangent` attribute when present,
normalizing tangent XYZ while preserving the tangent handedness component.
Returns a flat tangent attribute buffer, or an empty vector if no tangent
attribute exists.
"""
function apply_morph_tangents(g::BufferGeometry, influences::AbstractVector{<:Real})
    has_attribute(g, :tangent) || return Float64[]
    base_attr = get_attribute(g, :tangent)
    base_attr.item_size >= 3 && length(base_attr.data) >= g.n_vertices * base_attr.item_size ||
        return copy(Float64.(base_attr.data))
    out = Float64.(copy(base_attr.data))
    for (ti, weight) in enumerate(influences)
        weight == 0 && continue
        name = Symbol("morphTangent$(ti - 1)")
        has_attribute(g, name) || continue
        attr = get_attribute(g, name)
        attr.item_size >= 3 || error("$name attribute must have at least 3 components")
        length(attr.data) >= g.n_vertices * attr.item_size || error("$name count does not match geometry")
        @inbounds for vi in 1:g.n_vertices
            dst = (vi - 1) * base_attr.item_size + 1
            src = (vi - 1) * attr.item_size + 1
            out[dst] += Float64(attr.data[src]) * Float64(weight)
            out[dst + 1] += Float64(attr.data[src + 1]) * Float64(weight)
            out[dst + 2] += Float64(attr.data[src + 2]) * Float64(weight)
        end
    end
    return _normalize_attribute3!(out, g.n_vertices, base_attr.item_size)
end

"""Axis-aligned bounding box of the geometry (three.js `computeBoundingBox`)."""
function compute_bounding_box(g::BufferGeometry)
    g.n_vertices == 0 && return Box3()
    box = Box3()
    @inbounds for vi in 1:g.n_vertices
        box = box3_expand_by_point(box, get_vertex(g, vi))
    end
    return box
end

"""Bounding sphere centred on the box centre (three.js `computeBoundingSphere`)."""
function compute_bounding_sphere(g::BufferGeometry)
    g.n_vertices == 0 && return BoundingSphere(Vec3(), 0.0)
    box = compute_bounding_box(g)
    center = (box.min + box.max) * 0.5
    r2 = 0.0
    @inbounds for vi in 1:g.n_vertices
        d = get_vertex(g, vi) - center
        r2 = max(r2, dot(d, d))
    end
    return BoundingSphere(center, sqrt(r2))
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
    normalize(cross(v2 - v1, v3 - v1))
end

# ========================== Box Geometry ==========================

function _geometry_segment_count(name::String, value)
    try
        n = Int(value)
        n >= 1 || throw(ArgumentError("$name must be at least 1"))
        return n
    catch err
        err isa ArgumentError && rethrow()
        throw(ArgumentError("$name must be a positive integer"))
    end
end

function BoxGeometry(; width=1.0, height=1.0, depth=1.0,
                     width_segments=1, height_segments=1, depth_segments=1)
    ws = _geometry_segment_count("width_segments", width_segments)
    hs = _geometry_segment_count("height_segments", height_segments)
    ds = _geometry_segment_count("depth_segments", depth_segments)
    w, h, d = width/2, height/2, depth/2

    # Vertices are duplicated per face so each face keeps flat normals and UVs.
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]
    vi = 0  # vertex counter

    function add_quad_face!(p1, p2, p3, p4, n)
        for p in (p1, p2, p3, p4)
            append!(positions, [p.x, p.y, p.z])
            append!(normals_arr, [n.x, n.y, n.z])
        end
        append!(uvs_arr, [0,0, 1,0, 1,1, 0,1])
        base = vi + 1
        append!(indices, [base, base+1, base+2, base, base+2, base+3])
        vi += 4
    end

    function add_grid_face!(p1, p2, p3, p4, n, u_segments::Int, v_segments::Int)
        base = vi + 1
        for j in 0:v_segments
            tv = j / v_segments
            left = p1 * (1 - tv) + p4 * tv
            right = p2 * (1 - tv) + p3 * tv
            for i in 0:u_segments
                tu = i / u_segments
                p = left * (1 - tu) + right * tu
                append!(positions, [p.x, p.y, p.z])
                append!(normals_arr, [n.x, n.y, n.z])
                append!(uvs_arr, [tu, tv])
            end
        end
        row = u_segments + 1
        for j in 0:(v_segments - 1), i in 0:(u_segments - 1)
            a = base + j * row + i
            b = a + 1
            d0 = a + row
            c = d0 + 1
            append!(indices, [a, b, c, a, c, d0])
        end
        vi += row * (v_segments + 1)
    end

    function add_face!(p1, p2, p3, p4, n, u_segments::Int, v_segments::Int)
        if ws == 1 && hs == 1 && ds == 1
            add_quad_face!(p1, p2, p3, p4, n)
        else
            add_grid_face!(p1, p2, p3, p4, n, u_segments, v_segments)
        end
    end

    # +Z face
    add_face!(Vec3(-w,-h,d), Vec3(w,-h,d), Vec3(w,h,d), Vec3(-w,h,d), Vec3(0,0,1), ws, hs)
    # -Z face
    add_face!(Vec3(w,-h,-d), Vec3(-w,-h,-d), Vec3(-w,h,-d), Vec3(w,h,-d), Vec3(0,0,-1), ws, hs)
    # +Y face
    add_face!(Vec3(-w,h,d), Vec3(w,h,d), Vec3(w,h,-d), Vec3(-w,h,-d), Vec3(0,1,0), ws, ds)
    # -Y face
    add_face!(Vec3(-w,-h,-d), Vec3(w,-h,-d), Vec3(w,-h,d), Vec3(-w,-h,d), Vec3(0,-1,0), ws, ds)
    # +X face
    add_face!(Vec3(w,-h,d), Vec3(w,-h,-d), Vec3(w,h,-d), Vec3(w,h,d), Vec3(1,0,0), ds, hs)
    # -X face
    add_face!(Vec3(-w,-h,-d), Vec3(-w,-h,d), Vec3(-w,h,d), Vec3(-w,h,-d), Vec3(-1,0,0), ds, hs)

    n_verts = vi
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Sphere Geometry ==========================

function SphereGeometry(; radius=1.0, width_segments=32, height_segments=16)
    # Clamp to a valid minimum (matching three.js), else degenerate counts produce
    # an empty/NaN sphere from a plausible call.
    width_segments = max(3, Int(floor(width_segments)))
    height_segments = max(2, Int(floor(height_segments)))
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]

    for j in 0:height_segments
        v = j / height_segments
        θ = v * π
        for i in 0:width_segments
            u = i / width_segments
            ϕ = u * 2π

            x = -radius * sin(θ) * cos(ϕ)
            y = radius * cos(θ)
            z = radius * sin(θ) * sin(ϕ)

            nx, ny, nz = -sin(θ)*cos(ϕ), cos(θ), sin(θ)*sin(ϕ)
            nl = sqrt(nx^2 + ny^2 + nz^2)
            if nl > 0
                nx /= nl; ny /= nl; nz /= nl
            end

            append!(positions, [x, y, z])
            append!(normals_arr, [nx, ny, nz])
            append!(uvs_arr, [u, 1.0-v])
        end
    end

    for j in 0:height_segments-1
        for i in 0:width_segments-1
            a = j * (width_segments + 1) + i + 1
            b = a + 1
            c = a + (width_segments + 1)
            d = c + 1

            if j != 0
                append!(indices, [a, d, b])
            end
            if j != height_segments - 1
                append!(indices, [a, c, d])
            end
        end
    end

    n_verts = (height_segments + 1) * (width_segments + 1)
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Plane Geometry ==========================

function PlaneGeometry(; width=1.0, height=1.0, width_segments=1, height_segments=1)
    # Clamp segment counts (matching SphereGeometry/three.js) so a 0 cannot make
    # the per-segment step a 0/0 = NaN that silently poisons positions/UVs.
    width_segments = max(1, Int(floor(width_segments)))
    height_segments = max(1, Int(floor(height_segments)))
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]

    hw, hh = width/2, height/2
    dw = width / width_segments
    dh = height / height_segments

    for iy in 0:height_segments
        y = iy * dh - hh
        for ix in 0:width_segments
            x = ix * dw - hw
            append!(positions, [x, -y, 0.0])
            append!(normals_arr, [0.0, 0.0, 1.0])
            append!(uvs_arr, [ix/width_segments, 1.0 - iy/height_segments])
        end
    end

    for iy in 0:height_segments-1
        for ix in 0:width_segments-1
            a = iy * (width_segments + 1) + ix + 1
            b = a + 1
            c = a + (width_segments + 1)
            d = c + 1
            append!(indices, [a, d, b, a, c, d])
        end
    end

    n_verts = (width_segments + 1) * (height_segments + 1)
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Cylinder Geometry ==========================

function CylinderGeometry(; radius_top=1.0, radius_bottom=1.0, height=1.0,
                           radial_segments=32, height_segments=1, open_ended=false)
    # Clamp segment counts so a 0 cannot produce NaN geometry (see PlaneGeometry).
    radial_segments = max(3, Int(floor(radial_segments)))
    height_segments = max(1, Int(floor(height_segments)))
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]
    vi = 0

    half_h = height / 2
    slope = (radius_bottom - radius_top) / height

    # Side
    for y_seg in 0:height_segments
        v = y_seg / height_segments
        r = v * (radius_bottom - radius_top) + radius_top
        y_pos = half_h - v * height

        for x_seg in 0:radial_segments
            u = x_seg / radial_segments
            θ = u * 2π

            x = r * sin(θ)
            z = r * cos(θ)

            nx = sin(θ)
            ny = slope
            nz = cos(θ)
            nl = sqrt(nx^2 + ny^2 + nz^2)
            nx /= nl; ny /= nl; nz /= nl

            append!(positions, [x, y_pos, z])
            append!(normals_arr, [nx, ny, nz])
            append!(uvs_arr, [u, 1.0 - v])
            vi += 1
        end
    end

    for y_seg in 0:height_segments-1
        for x_seg in 0:radial_segments-1
            a = y_seg * (radial_segments + 1) + x_seg + 1
            b = a + 1
            c = a + (radial_segments + 1)
            d = c + 1
            append!(indices, [a, d, b, a, c, d])
        end
    end

    # Caps
    if !open_ended
        for (cap_y, cap_r, cap_ny) in [(half_h, radius_top, 1.0), (-half_h, radius_bottom, -1.0)]
            cap_r > 0 || continue   # skip degenerate zero-radius cap (e.g. cone apex)
            center_idx = vi + 1
            append!(positions, [0.0, cap_y, 0.0])
            append!(normals_arr, [0.0, cap_ny, 0.0])
            append!(uvs_arr, [0.5, 0.5])
            vi += 1

            for x_seg in 0:radial_segments
                u = x_seg / radial_segments
                θ = u * 2π
                x = cap_r * sin(θ)
                z = cap_r * cos(θ)

                append!(positions, [x, cap_y, z])
                append!(normals_arr, [0.0, cap_ny, 0.0])
                append!(uvs_arr, [sin(θ)*0.5+0.5, cos(θ)*0.5+0.5])
                vi += 1
            end

            for x_seg in 0:radial_segments-1
                curr = center_idx + 1 + x_seg
                next_v = curr + 1
                if cap_ny > 0
                    append!(indices, [center_idx, curr, next_v])
                else
                    append!(indices, [center_idx, next_v, curr])
                end
            end
        end
    end

    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, vi, n_faces)
end

# ========================== Cone Geometry ==========================

function ConeGeometry(; radius=1.0, height=1.0, radial_segments=32, height_segments=1,
                       open_ended=false)
    CylinderGeometry(; radius_top=0.0, radius_bottom=radius, height=height,
                      radial_segments=radial_segments, height_segments=height_segments,
                      open_ended=open_ended)
end

# ========================== Torus Geometry ==========================

function TorusGeometry(; radius=1.0, tube=0.4, radial_segments=16, tubular_segments=48)
    # Clamp segment counts so a 0 cannot produce NaN geometry (see PlaneGeometry).
    radial_segments = max(2, Int(floor(radial_segments)))
    tubular_segments = max(3, Int(floor(tubular_segments)))
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]

    for j in 0:radial_segments
        for i in 0:tubular_segments
            u = i / tubular_segments * 2π
            v = j / radial_segments * 2π

            x = (radius + tube * cos(v)) * cos(u)
            y = (radius + tube * cos(v)) * sin(u)
            z = tube * sin(v)

            cx = radius * cos(u)
            cy = radius * sin(u)
            nx = x - cx
            ny = y - cy
            nz = z
            nl = sqrt(nx^2 + ny^2 + nz^2)
            if nl > 0
                nx /= nl; ny /= nl; nz /= nl
            end

            append!(positions, [x, y, z])
            append!(normals_arr, [nx, ny, nz])
            append!(uvs_arr, [i/tubular_segments, j/radial_segments])
        end
    end

    for j in 1:radial_segments
        for i in 1:tubular_segments
            a = (j - 1) * (tubular_segments + 1) + i
            b = a + 1
            c = j * (tubular_segments + 1) + i
            d = c + 1
            append!(indices, [a, b, d, a, d, c])
        end
    end

    n_verts = (radial_segments + 1) * (tubular_segments + 1)
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== TorusKnot Geometry ==========================

function TorusKnotGeometry(; radius=1.0, tube=0.4, tubular_segments=64,
                            radial_segments=8, p_val=2, q_val=3)
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]

    function knot_point(t)
        cu = cos(t)
        su = sin(t)
        qu_over_p = q_val / p_val * t
        cx = radius * (2 + cos(qu_over_p)) * cu * 0.5
        cy = radius * (2 + cos(qu_over_p)) * su * 0.5
        cz = radius * sin(qu_over_p) * 0.5
        Vec3(cx, cy, cz)
    end

    for i in 0:tubular_segments
        u = i / tubular_segments * p_val * 2π
        p1 = knot_point(u)
        p2 = knot_point(u + 0.01)
        T_vec = normalize(p2 - p1)
        N_vec = normalize(p2 + p1)
        B_vec = normalize(cross(T_vec, N_vec))
        N_vec = cross(B_vec, T_vec)

        for j in 0:radial_segments
            v = j / radial_segments * 2π
            cx = tube * cos(v)
            cy = tube * sin(v)
            px = p1.x + cx * N_vec.x + cy * B_vec.x
            py = p1.y + cx * N_vec.y + cy * B_vec.y
            pz = p1.z + cx * N_vec.z + cy * B_vec.z

            nx = px - p1.x
            ny = py - p1.y
            nz = pz - p1.z
            nl = sqrt(nx^2 + ny^2 + nz^2)
            if nl > 0
                nx /= nl; ny /= nl; nz /= nl
            end

            append!(positions, [px, py, pz])
            append!(normals_arr, [nx, ny, nz])
            append!(uvs_arr, [i/tubular_segments, j/radial_segments])
        end
    end

    for i in 1:tubular_segments
        for j in 1:radial_segments
            a = (i - 1) * (radial_segments + 1) + j
            b = a + 1
            c = i * (radial_segments + 1) + j
            d = c + 1
            append!(indices, [a, b, d, a, d, c])
        end
    end

    n_verts = (tubular_segments + 1) * (radial_segments + 1)
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Ring Geometry ==========================

function RingGeometry(; inner_radius=0.5, outer_radius=1.0, theta_segments=32, phi_segments=1)
    # Clamp segment counts so a 0 cannot produce NaN geometry (see PlaneGeometry).
    theta_segments = max(3, Int(floor(theta_segments)))
    phi_segments = max(1, Int(floor(phi_segments)))
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]

    for j in 0:phi_segments
        v = j / phi_segments
        r = inner_radius + v * (outer_radius - inner_radius)
        for i in 0:theta_segments
            u = i / theta_segments
            θ = u * 2π
            x = r * cos(θ)
            y = r * sin(θ)
            append!(positions, [x, y, 0.0])
            append!(normals_arr, [0.0, 0.0, 1.0])
            append!(uvs_arr, [(x / outer_radius + 1) / 2, (y / outer_radius + 1) / 2])
        end
    end

    for j in 0:phi_segments-1
        for i in 0:theta_segments-1
            a = j * (theta_segments + 1) + i + 1
            b = a + 1
            c = a + (theta_segments + 1)
            d = c + 1
            append!(indices, [a, d, b, a, c, d])
        end
    end

    n_verts = (phi_segments + 1) * (theta_segments + 1)
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Circle Geometry ==========================

function CircleGeometry(; radius=1.0, segments=32)
    # Clamp segments so a 0 cannot make the angular step a 0/0 = NaN (see PlaneGeometry).
    segments = max(3, Int(floor(segments)))
    positions = Float64[0.0, 0.0, 0.0]  # center
    normals_arr = Float64[0.0, 0.0, 1.0]
    uvs_arr = Float64[0.5, 0.5]
    indices = Int[]

    for i in 0:segments
        θ = i / segments * 2π
        x = radius * cos(θ)
        y = radius * sin(θ)
        append!(positions, [x, y, 0.0])
        append!(normals_arr, [0.0, 0.0, 1.0])
        append!(uvs_arr, [cos(θ)*0.5+0.5, sin(θ)*0.5+0.5])
    end

    for i in 1:segments
        append!(indices, [1, i+1, i+2])
    end

    n_verts = segments + 2
    n_faces = length(indices) ÷ 3
    BufferGeometry(positions, normals_arr, uvs_arr, indices, n_verts, n_faces)
end

# ========================== Icosahedron Geometry ==========================

function IcosahedronGeometry(; radius=1.0, detail=0)
    t = (1 + sqrt(5)) / 2

    # Base vertices (un-normalized): PolyhedronGeometry projects each to the sphere.
    base_verts = [
        Vec3(-1.0,  t,  0.0), Vec3( 1.0,  t,  0.0), Vec3(-1.0, -t,  0.0), Vec3( 1.0, -t,  0.0),
        Vec3( 0.0, -1.0,  t), Vec3( 0.0,  1.0,  t), Vec3( 0.0, -1.0, -t), Vec3( 0.0,  1.0, -t),
        Vec3( t,  0.0, -1.0), Vec3( t,  0.0,  1.0), Vec3(-t,  0.0, -1.0), Vec3(-t,  0.0,  1.0)
    ]

    # 20 base faces (1-based vertex indices into base_verts).
    base_faces = NTuple{3,Int}[
        (1,12,6), (1,6,2), (1,2,8), (1,8,11), (1,11,12),
        (2,6,10), (6,12,5), (12,11,3), (11,8,7), (8,2,9),
        (4,10,5), (4,5,3), (4,3,7), (4,7,9), (4,9,10),
        (10,6,5), (5,12,3), (3,11,7), (7,8,9), (9,2,10)
    ]

    PolyhedronGeometry(base_verts, base_faces; radius=radius, detail=detail)
end

# ========================== Utility ==========================

function count_triangles(g::BufferGeometry)
    g.n_faces
end

"""
    merge_geometries(geos; with_groups=true)

Merge multiple `BufferGeometry` objects into one (for batching). The merged
positions/normals/uvs/indices and carried-over named attributes are identical to
the previous behaviour. When `with_groups=true` (default), a draw group is
appended per input geometry recording which faces came from which sub-mesh:
`(start, count, material_index)` with 1-based `start`, `count` equal to that
input's face count, and `material_index` equal to its 0-based position in `geos`.
Inputs that contribute no faces are skipped so empty groups are not emitted.
"""
function merge_geometries(geos::Vector{BufferGeometry}; with_groups::Bool=true)
    positions = Float64[]
    normals_arr = Float64[]
    uvs_arr = Float64[]
    indices = Int[]
    offset = 0
    total_verts = 0
    total_faces = 0
    groups = NTuple{3,Int}[]

    for (mat_idx, g) in enumerate(geos)
        append!(positions, g.positions)
        append!(normals_arr, g.normals)
        append!(uvs_arr, g.uvs)
        for idx in g.indices
            push!(indices, idx + offset)
        end
        if with_groups && g.n_faces > 0
            # mat_idx is 1-based; material_index is 0-based (three.js convention).
            push!(groups, (total_faces + 1, g.n_faces, mat_idx - 1))
        end
        offset += g.n_vertices
        total_verts += g.n_vertices
        total_faces += g.n_faces
    end

    merged = BufferGeometry(positions, normals_arr, uvs_arr, indices, total_verts, total_faces)
    if with_groups
        append!(merged.groups, groups)
    end

    # Carry over named attributes present on every input with matching item_size.
    if !isempty(geos)
        for (name, attr) in geos[1].attributes
            keep = all(g -> has_attribute(g, name) &&
                            get_attribute(g, name).item_size == attr.item_size, geos)
            keep || continue
            data = similar(attr.data, 0)
            for g in geos
                append!(data, get_attribute(g, name).data)
            end
            set_attribute!(merged, name, data, attr.item_size)
        end
    end

    return merged
end
