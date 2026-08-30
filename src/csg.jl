# --------------------------------------------------------------------------
# Constructive solid geometry over closed triangle BufferGeometry meshes.
# Uses the classic BSP polygon clipping algorithm behind three.js-style CSG
# examples, returning non-indexed BufferGeometry output.
# --------------------------------------------------------------------------

const _CSG_EPS = 1e-5
const _CSG_AREA_EPS = _CSG_EPS * _CSG_EPS

# Evaluate both operands in one canonical frame so BSP tolerances are invariant
# under a shared finite translation and uniform scale.
struct CSGFrame
    center::Vec3{Float64}
    scale::Float64
end

const _CSG_IDENTITY_FRAME = CSGFrame(Vec3(0.0, 0.0, 0.0), 1.0)

struct CSGVertex
    pos::Vec3{Float64}
    normal::Vec3{Float64}
    uv::Vec2{Float64}
end

struct CSGPlane
    normal::Vec3{Float64}
    w::Float64
end

struct CSGPolygon
    vertices::Vector{CSGVertex}
    plane::CSGPlane
end

mutable struct CSGNode
    plane::Union{Nothing,CSGPlane}
    front::Union{Nothing,CSGNode}
    back::Union{Nothing,CSGNode}
    polygons::Vector{CSGPolygon}
end

CSGNode() = CSGNode(nothing, nothing, nothing, CSGPolygon[])

function _csg_vertex(p::Vec3, n::Vec3, uv::Vec2)
    pos = Vec3(Float64(p.x), Float64(p.y), Float64(p.z))
    normal = normalize(Vec3(Float64(n.x), Float64(n.y), Float64(n.z)))
    tex = Vec2(Float64(uv.x), Float64(uv.y))
    return CSGVertex(pos, normal, tex)
end

function _csg_vertex_flip(v::CSGVertex)
    return CSGVertex(v.pos, -v.normal, v.uv)
end

function _csg_vertex_lerp(a::CSGVertex, b::CSGVertex, t::Float64)
    return CSGVertex(lerp(a.pos, b.pos, t),
                     normalize(lerp(a.normal, b.normal, t)),
                     a.uv * (1.0 - t) + b.uv * t)
end

function _csg_plane_from_vertices(vertices::Vector{CSGVertex})
    length(vertices) >= 3 || return nothing
    origin = vertices[1].pos
    for i in 2:(length(vertices) - 1)
        n = cross(vertices[i].pos - origin, vertices[i + 1].pos - origin)
        if norm(n) > _CSG_AREA_EPS
            normal = normalize(n)
            return CSGPlane(normal, dot(normal, origin))
        end
    end
    return nothing
end

function _csg_polygon(vertices::Vector{CSGVertex})
    plane = _csg_plane_from_vertices(vertices)
    plane === nothing && return nothing
    return CSGPolygon(vertices, plane)
end

function _csg_polygon_flip(poly::CSGPolygon)
    vertices = [_csg_vertex_flip(v) for v in Iterators.reverse(poly.vertices)]
    return CSGPolygon(vertices, CSGPlane(-poly.plane.normal, -poly.plane.w))
end

_csg_plane_flip(plane::CSGPlane) = CSGPlane(-plane.normal, -plane.w)

@inline function _csg_vertex_type(plane::CSGPlane, vertex::CSGVertex)
    t = dot(plane.normal, vertex.pos) - plane.w
    return t < -_CSG_EPS ? 2 : (t > _CSG_EPS ? 1 : 0)
end

@inline function _csg_polygon_type(plane::CSGPlane, polygon::CSGPolygon)
    polygon_type = 0
    @inbounds for vertex in polygon.vertices
        polygon_type |= _csg_vertex_type(plane, vertex)
    end
    return polygon_type
end

function _csg_split_polygon(plane::CSGPlane, polygon::CSGPolygon,
                            coplanar_front::Vector{CSGPolygon},
                            coplanar_back::Vector{CSGPolygon},
                            front::Vector{CSGPolygon},
                            back::Vector{CSGPolygon})
    coplanar = 0
    front_type = 1
    back_type = 2
    spanning = 3
    polygon_type = _csg_polygon_type(plane, polygon)
    n = length(polygon.vertices)

    if polygon_type == coplanar
        if dot(plane.normal, polygon.plane.normal) > 0.0
            push!(coplanar_front, polygon)
        else
            push!(coplanar_back, polygon)
        end
    elseif polygon_type == front_type
        push!(front, polygon)
    elseif polygon_type == back_type
        push!(back, polygon)
    elseif polygon_type == spanning
        f = CSGVertex[]
        b = CSGVertex[]
        sizehint!(f, n + 1)
        sizehint!(b, n + 1)
        for i in 1:n
            j = i == n ? 1 : i + 1
            vi = polygon.vertices[i]
            vj = polygon.vertices[j]
            ti = _csg_vertex_type(plane, vi)
            tj = _csg_vertex_type(plane, vj)
            ti != back_type && push!(f, vi)
            ti != front_type && push!(b, vi)
            if (ti | tj) == spanning
                denom = dot(plane.normal, vj.pos - vi.pos)
                if abs(denom) > _CSG_EPS
                    t = (plane.w - dot(plane.normal, vi.pos)) / denom
                    v = _csg_vertex_lerp(vi, vj, clamp(t, 0.0, 1.0))
                    push!(f, v)
                    push!(b, v)
                end
            end
        end
        fp = _csg_polygon(f)
        bp = _csg_polygon(b)
        fp !== nothing && push!(front, fp)
        bp !== nothing && push!(back, bp)
    end
    return nothing
end

function _csg_build!(node::CSGNode, polygons::Vector{CSGPolygon})
    isempty(polygons) && return node
    node.plane === nothing && (node.plane = polygons[1].plane)
    front = CSGPolygon[]
    back = CSGPolygon[]
    for p in polygons
        _csg_split_polygon(node.plane::CSGPlane, p, node.polygons,
                           node.polygons, front, back)
    end
    if !isempty(front)
        node.front === nothing && (node.front = CSGNode())
        _csg_build!(node.front::CSGNode, front)
    end
    if !isempty(back)
        node.back === nothing && (node.back = CSGNode())
        _csg_build!(node.back::CSGNode, back)
    end
    return node
end

function _csg_node(polygons::Vector{CSGPolygon})
    node = CSGNode()
    _csg_build!(node, polygons)
    return node
end

function _csg_polygon_count(node::CSGNode)
    n = length(node.polygons)
    node.front !== nothing && (n += _csg_polygon_count(node.front::CSGNode))
    node.back !== nothing && (n += _csg_polygon_count(node.back::CSGNode))
    return n
end

function _csg_collect_polygons!(out::Vector{CSGPolygon}, node::CSGNode)
    append!(out, node.polygons)
    node.front !== nothing && _csg_collect_polygons!(out, node.front::CSGNode)
    node.back !== nothing && _csg_collect_polygons!(out, node.back::CSGNode)
    return out
end

function _csg_all_polygons(node::CSGNode)
    out = CSGPolygon[]
    sizehint!(out, _csg_polygon_count(node))
    return _csg_collect_polygons!(out, node)
end

function _csg_invert!(node::CSGNode)
    node.polygons = [_csg_polygon_flip(p) for p in node.polygons]
    node.plane !== nothing && (node.plane = _csg_plane_flip(node.plane))
    node.front !== nothing && _csg_invert!(node.front)
    node.back !== nothing && _csg_invert!(node.back)
    node.front, node.back = node.back, node.front
    return node
end

function _csg_clip_polygons(node::CSGNode, polygons::Vector{CSGPolygon})
    node.plane === nothing && return copy(polygons)
    front = CSGPolygon[]
    back = CSGPolygon[]
    for p in polygons
        _csg_split_polygon(node.plane::CSGPlane, p, front, back, front, back)
    end
    node.front !== nothing && (front = _csg_clip_polygons(node.front, front))
    back = node.back === nothing ? CSGPolygon[] :
           _csg_clip_polygons(node.back, back)
    append!(front, back)
    return front
end

function _csg_clip_to!(node::CSGNode, bsp::CSGNode)
    node.polygons = _csg_clip_polygons(bsp, node.polygons)
    node.front !== nothing && _csg_clip_to!(node.front, bsp)
    node.back !== nothing && _csg_clip_to!(node.back, bsp)
    return node
end

@inline function _csg_frame_point(frame::CSGFrame, point::Vec3)
    return Vec3((Float64(point.x) - frame.center.x) / frame.scale,
                (Float64(point.y) - frame.center.y) / frame.scale,
                (Float64(point.z) - frame.center.z) / frame.scale)
end

@inline function _csg_world_point(frame::CSGFrame, point::Vec3)
    return Vec3(muladd(frame.scale, Float64(point.x), frame.center.x),
                muladd(frame.scale, Float64(point.y), frame.center.y),
                muladd(frame.scale, Float64(point.z), frame.center.z))
end

function _csg_operation_frame(a::BufferGeometry, b::BufferGeometry)
    _validate_triangle_geometry_indices(a, "CSG left operand")
    _validate_triangle_geometry_indices(b, "CSG right operand")

    min_x = Inf
    min_y = Inf
    min_z = Inf
    max_x = -Inf
    max_y = -Inf
    max_z = -Inf
    found_vertex = false
    for geo in (a, b)
        @inbounds for fi in 1:geo.n_faces
            base = (fi - 1) * 3
            for offset in 1:3
                vi = geo.indices[base + offset]
                position_base = (vi - 1) * 3
                x = geo.positions[position_base + 1]
                y = geo.positions[position_base + 2]
                z = geo.positions[position_base + 3]
                (isfinite(x) && isfinite(y) && isfinite(z)) ||
                    throw(ArgumentError("CSG positions must be finite"))
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                min_z = min(min_z, z)
                max_x = max(max_x, x)
                max_y = max(max_y, y)
                max_z = max(max_z, z)
                found_vertex = true
            end
        end
    end
    found_vertex || return _CSG_IDENTITY_FRAME

    center = Vec3(_geometry_midpoint(min_x, max_x),
                  _geometry_midpoint(min_y, max_y),
                  _geometry_midpoint(min_z, max_z))
    scale = max(abs(min_x - center.x), abs(max_x - center.x),
                abs(min_y - center.y), abs(max_y - center.y),
                abs(min_z - center.z), abs(max_z - center.z))
    scale == 0.0 && return CSGFrame(center, 1.0)
    return CSGFrame(center, scale)
end

function _csg_geometry_polygons(geo::BufferGeometry,
                                frame::CSGFrame=_CSG_IDENTITY_FRAME)
    polygons = CSGPolygon[]
    sizehint!(polygons, geo.n_faces)
    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        p1 = _csg_frame_point(frame, get_vertex(geo, i1))
        p2 = _csg_frame_point(frame, get_vertex(geo, i2))
        p3 = _csg_frame_point(frame, get_vertex(geo, i3))
        face_normal = triangle_normal(Triangle(p1, p2, p3))
        vertices = Vector{CSGVertex}(undef, 3)
        @inbounds for (out, (idx, p)) in enumerate(((i1, p1), (i2, p2), (i3, p3)))
            n = length(geo.normals) >= 3idx ? get_normal(geo, idx) : face_normal
            norm(n) <= _CSG_EPS && (n = face_normal)
            uv = length(geo.uvs) >= 2idx ? Vec2(geo.uvs[2idx - 1], geo.uvs[2idx]) :
                 Vec2(0.0, 0.0)
            vertices[out] = _csg_vertex(p, n, uv)
        end
        polygon = _csg_polygon(vertices)
        polygon !== nothing && push!(polygons, polygon)
    end
    return polygons
end

function _csg_polygons_to_geometry(polygons::Vector{CSGPolygon},
                                   frame::CSGFrame=_CSG_IDENTITY_FRAME)
    n_faces = 0
    for poly in polygons
        length(poly.vertices) >= 3 || continue
        for i in 2:(length(poly.vertices) - 1)
            tri = (poly.vertices[1], poly.vertices[i], poly.vertices[i + 1])
            norm(cross(tri[2].pos - tri[1].pos,
                       tri[3].pos - tri[1].pos)) > _CSG_AREA_EPS ||
                continue
            n_faces += 1
        end
    end
    n_faces == 0 && return BufferGeometry(Float64[], Float64[], Float64[], Int[], 0, 0)

    n_verts = 3 * n_faces
    positions = Vector{Float64}(undef, 3 * n_verts)
    normals = Vector{Float64}(undef, 3 * n_verts)
    uvs = Vector{Float64}(undef, 2 * n_verts)
    indices = Vector{Int}(undef, n_verts)
    vi = 0
    @inbounds for poly in polygons
        length(poly.vertices) >= 3 || continue
        for i in 2:(length(poly.vertices) - 1)
            tri = (poly.vertices[1], poly.vertices[i], poly.vertices[i + 1])
            norm(cross(tri[2].pos - tri[1].pos,
                       tri[3].pos - tri[1].pos)) > _CSG_AREA_EPS ||
                continue
            for v in tri
                vi += 1
                pbase = 3vi - 2
                world = _csg_world_point(frame, v.pos)
                positions[pbase] = world.x
                positions[pbase + 1] = world.y
                positions[pbase + 2] = world.z
                normals[pbase] = v.normal.x
                normals[pbase + 1] = v.normal.y
                normals[pbase + 2] = v.normal.z
                ubase = 2vi - 1
                uvs[ubase] = v.uv.x
                uvs[ubase + 1] = v.uv.y
                indices[vi] = vi
            end
        end
    end
    return BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

function _csg_clone_polygons(polygons::Vector{CSGPolygon})
    return [CSGPolygon(copy(p.vertices), p.plane) for p in polygons]
end

function _csg_operate(a::BufferGeometry, b::BufferGeometry, operation::Symbol)
    frame = _csg_operation_frame(a, b)
    ap = _csg_geometry_polygons(a, frame)
    bp = _csg_geometry_polygons(b, frame)
    # An empty operand has a degenerate BSP (root plane === nothing), which the
    # clip step would otherwise pass through wholesale, returning the other solid.
    # Resolve set-theoretically instead: ∅∪X=X, ∅-X=∅, X-∅=X, ∅∩X=∅.
    if isempty(ap) || isempty(bp)
        result = if operation === :union
            isempty(ap) ? bp : ap
        elseif operation === :subtract
            isempty(ap) ? CSGPolygon[] : ap
        elseif operation === :intersect
            CSGPolygon[]
        else
            throw(ArgumentError("unsupported CSG operation: $operation"))
        end
        return _csg_polygons_to_geometry(result, frame)
    end
    A = _csg_node(ap)
    B = _csg_node(bp)

    if operation === :union
        _csg_clip_to!(A, B)
        _csg_clip_to!(B, A)
        _csg_invert!(B)
        _csg_clip_to!(B, A)
        _csg_invert!(B)
        _csg_build!(A, _csg_all_polygons(B))
    elseif operation === :subtract
        _csg_invert!(A)
        _csg_clip_to!(A, B)
        _csg_clip_to!(B, A)
        _csg_invert!(B)
        _csg_clip_to!(B, A)
        _csg_invert!(B)
        _csg_build!(A, _csg_all_polygons(B))
        _csg_invert!(A)
    elseif operation === :intersect
        _csg_invert!(A)
        _csg_clip_to!(B, A)
        _csg_invert!(B)
        _csg_clip_to!(A, B)
        _csg_clip_to!(B, A)
        _csg_build!(A, _csg_all_polygons(B))
        _csg_invert!(A)
    else
        throw(ArgumentError("unsupported CSG operation: $operation"))
    end
    return _csg_polygons_to_geometry(_csg_all_polygons(A), frame)
end

"""Boolean union of two closed triangle `BufferGeometry` meshes."""
csg_union(a::BufferGeometry, b::BufferGeometry) = _csg_operate(a, b, :union)

"""Boolean subtraction `a - b` for two closed triangle `BufferGeometry` meshes."""
csg_subtract(a::BufferGeometry, b::BufferGeometry) = _csg_operate(a, b, :subtract)

"""Boolean intersection of two closed triangle `BufferGeometry` meshes."""
csg_intersect(a::BufferGeometry, b::BufferGeometry) = _csg_operate(a, b, :intersect)

function csg_evaluate(a::BufferGeometry, b::BufferGeometry, operation::Symbol)
    operation in (:union, :addition, :add) && return csg_union(a, b)
    operation in (:subtract, :subtraction, :difference) && return csg_subtract(a, b)
    operation in (:intersect, :intersection) && return csg_intersect(a, b)
    throw(ArgumentError("unsupported CSG operation: $operation"))
end

function _validate_transform_geometry(geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "transform_geometry")
    required_normal_values = 3 * geo.n_vertices
    (isempty(geo.normals) || length(geo.normals) >= required_normal_values) ||
        throw(ArgumentError(
            "transform_geometry normals length must cover n_vertices"))
    has_attribute(geo, :tangent) || return nothing
    tangent = get_attribute(geo, :tangent)
    tangent.item_size >= 3 ||
        throw(ArgumentError(
            "transform_geometry tangent item_size must be at least 3"))
    geo.n_vertices <= typemax(Int) ÷ tangent.item_size ||
        throw(ArgumentError("transform_geometry tangent buffer is too large"))
    length(tangent.data) >= geo.n_vertices * tangent.item_size ||
        throw(ArgumentError(
            "transform_geometry tangent data must cover n_vertices"))
    return nothing
end

function _transform_geometry_tangents!(attributes::Dict{Symbol,BufferAttribute},
                                       geo::BufferGeometry, matrix::Mat4,
                                       reverse_orientation::Bool)
    has_attribute(geo, :tangent) || return attributes
    source = get_attribute(geo, :tangent)
    item_size = source.item_size
    data = Vector{Float64}(undef, length(source.data))
    @inbounds for i in eachindex(source.data)
        data[i] = _geometry_finite_float(
            source.data[i], "transform_geometry tangent data")
    end
    @inbounds for vi in 1:geo.n_vertices
        base = (vi - 1) * item_size
        tangent = Vec3(data[base + 1], data[base + 2], data[base + 3])
        transformed = normalize(mat4_transform_direction(matrix, tangent))
        data[base + 1] = transformed.x
        data[base + 2] = transformed.y
        data[base + 3] = transformed.z
        reverse_orientation && item_size >= 4 &&
            (data[base + 4] = -data[base + 4])
    end
    attributes[:tangent] = BufferAttribute(data, item_size)
    return attributes
end

function _mat4_linear_orientation_sign(matrix::Mat4)
    values = matrix.e
    a, b, c = values[1], values[5], values[9]
    d, e, f = values[2], values[6], values[10]
    g, h, i = values[3], values[7], values[11]
    scale = maximum(abs, (a, b, c, d, e, f, g, h, i))
    iszero(scale) && return 0
    an, bn, cn = a / scale, b / scale, c / scale
    dn, en, fn = d / scale, e / scale, f / scale
    gn, hn, inn = g / scale, h / scale, i / scale
    terms = (
        an * en * inn, -an * fn * hn,
        -bn * dn * inn, bn * fn * gn,
        cn * dn * hn, -cn * en * gn,
    )
    determinant = sum(terms)
    permanent = sum(abs, terms)
    error_bound = 64 * eps(Float64) * permanent
    isfinite(determinant) && abs(determinant) > error_bound &&
        return determinant < 0.0 ? -1 : 1
    return setprecision(BigFloat, 256) do
        ab, bb, cb = BigFloat(a), BigFloat(b), BigFloat(c)
        db, eb, fb = BigFloat(d), BigFloat(e), BigFloat(f)
        gb, hb, ib = BigFloat(g), BigFloat(h), BigFloat(i)
        determinant_b = ab * (eb * ib - fb * hb) -
                        bb * (db * ib - fb * gb) +
                        cb * (db * hb - eb * gb)
        determinant_b < 0 ? -1 : determinant_b > 0 ? 1 : 0
    end
end

function transform_geometry(geo::BufferGeometry, matrix::Mat4)
    _validate_transform_geometry(geo)
    reverse_orientation = _mat4_linear_orientation_sign(matrix) < 0
    normal_matrix = mat4_transpose(mat4_inverse(matrix))
    positions = Vector{Float64}(undef, 3 * geo.n_vertices)
    normals = Vector{Float64}(undef, 3 * geo.n_vertices)
    @inbounds for vi in 1:geo.n_vertices
        p = mat4_transform_point(matrix, get_vertex(geo, vi))
        pbase = 3vi - 2
        positions[pbase] = p.x
        positions[pbase + 1] = p.y
        positions[pbase + 2] = p.z
        n = length(geo.normals) >= 3vi ? get_normal(geo, vi) : Vec3(0.0, 1.0, 0.0)
        tn = normalize(mat4_transform_direction(normal_matrix, n))
        normals[pbase] = tn.x
        normals[pbase + 1] = tn.y
        normals[pbase + 2] = tn.z
    end
    uvs = copy(geo.uvs)
    indices = copy(geo.indices)
    if reverse_orientation
        @inbounds for fi in 1:geo.n_faces
            base = 3fi - 2
            indices[base + 1], indices[base + 2] =
                indices[base + 2], indices[base + 1]
        end
    end
    if isempty(geo.attributes) && isempty(geo.groups) && geo.draw_range === nothing
        return BufferGeometry(positions, normals, uvs, indices, geo.n_vertices, geo.n_faces)
    end
    # deepcopy the attributes: copy(Dict) shares the BufferAttribute values' data
    # arrays, so the transformed geometry would alias the source's custom attributes.
    attributes = deepcopy(geo.attributes)
    _transform_geometry_tangents!(
        attributes, geo, matrix, reverse_orientation)
    return BufferGeometry(positions, normals, uvs, indices, geo.n_vertices, geo.n_faces,
                          attributes, copy(geo.groups), geo.draw_range)
end
