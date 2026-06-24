# --------------------------------------------------------------------------
# Constructive solid geometry over closed triangle BufferGeometry meshes.
# Uses the classic BSP polygon clipping algorithm behind three.js-style CSG
# examples, returning non-indexed BufferGeometry output.
# --------------------------------------------------------------------------

const _CSG_EPS = 1e-5

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
        if norm(n) > _CSG_EPS
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

function _csg_split_polygon(plane::CSGPlane, polygon::CSGPolygon,
                            coplanar_front::Vector{CSGPolygon},
                            coplanar_back::Vector{CSGPolygon},
                            front::Vector{CSGPolygon},
                            back::Vector{CSGPolygon})
    coplanar = 0
    front_type = 1
    back_type = 2
    spanning = 3
    polygon_type = 0
    types = Int[]
    for v in polygon.vertices
        t = dot(plane.normal, v.pos) - plane.w
        ty = t < -_CSG_EPS ? back_type : (t > _CSG_EPS ? front_type : coplanar)
        polygon_type |= ty
        push!(types, ty)
    end

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
        n = length(polygon.vertices)
        for i in 1:n
            j = i == n ? 1 : i + 1
            ti = types[i]
            tj = types[j]
            vi = polygon.vertices[i]
            vj = polygon.vertices[j]
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

function _csg_all_polygons(node::CSGNode)
    out = copy(node.polygons)
    node.front !== nothing && append!(out, _csg_all_polygons(node.front))
    node.back !== nothing && append!(out, _csg_all_polygons(node.back))
    return out
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

function _csg_geometry_polygons(geo::BufferGeometry)
    polygons = CSGPolygon[]
    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        face_normal = compute_face_normal(geo, fi)
        vertices = CSGVertex[]
        for idx in (i1, i2, i3)
            p = get_vertex(geo, idx)
            n = length(geo.normals) >= 3idx ? get_normal(geo, idx) : face_normal
            norm(n) <= _CSG_EPS && (n = face_normal)
            uv = length(geo.uvs) >= 2idx ? Vec2(geo.uvs[2idx - 1], geo.uvs[2idx]) :
                 Vec2(0.0, 0.0)
            push!(vertices, _csg_vertex(p, n, uv))
        end
        polygon = _csg_polygon(vertices)
        polygon !== nothing && push!(polygons, polygon)
    end
    return polygons
end

function _csg_polygons_to_geometry(polygons::Vector{CSGPolygon})
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    vi = 0
    for poly in polygons
        length(poly.vertices) >= 3 || continue
        for i in 2:(length(poly.vertices) - 1)
            tri = (poly.vertices[1], poly.vertices[i], poly.vertices[i + 1])
            norm(cross(tri[2].pos - tri[1].pos, tri[3].pos - tri[1].pos)) > _CSG_EPS ||
                continue
            for v in tri
                push!(positions, v.pos.x, v.pos.y, v.pos.z)
                push!(normals, v.normal.x, v.normal.y, v.normal.z)
                push!(uvs, v.uv.x, v.uv.y)
                vi += 1
                push!(indices, vi)
            end
        end
    end
    return BufferGeometry(positions, normals, uvs, indices, vi, length(indices) ÷ 3)
end

function _csg_clone_polygons(polygons::Vector{CSGPolygon})
    return [CSGPolygon(copy(p.vertices), p.plane) for p in polygons]
end

function _csg_operate(a::BufferGeometry, b::BufferGeometry, operation::Symbol)
    ap = _csg_clone_polygons(_csg_geometry_polygons(a))
    bp = _csg_clone_polygons(_csg_geometry_polygons(b))
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
    return _csg_polygons_to_geometry(_csg_all_polygons(A))
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

function transform_geometry(geo::BufferGeometry, matrix::Mat4)
    normal_matrix = mat4_transpose(mat4_inverse(matrix))
    positions = Float64[]
    normals = Float64[]
    for vi in 1:geo.n_vertices
        p = mat4_transform_point(matrix, get_vertex(geo, vi))
        push!(positions, p.x, p.y, p.z)
        n = length(geo.normals) >= 3vi ? get_normal(geo, vi) : Vec3(0.0, 1.0, 0.0)
        tn = normalize(mat4_transform_direction(normal_matrix, n))
        push!(normals, tn.x, tn.y, tn.z)
    end
    # deepcopy the attributes: copy(Dict) shares the BufferAttribute values' data
    # arrays, so the transformed geometry would alias the source's custom attributes.
    return BufferGeometry(positions, normals, copy(geo.uvs), copy(geo.indices),
                          geo.n_vertices, geo.n_faces,
                          deepcopy(geo.attributes), copy(geo.groups), geo.draw_range)
end
