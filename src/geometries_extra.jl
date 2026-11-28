# --------------------------------------------------------------------------
# Additional geometry generators mirroring three.js: the platonic-solid family
# via a subdividing PolyhedronGeometry, convex hulls, surfaces of revolution /
# sweeps (Lathe, Tube), profile extrusion (Shape/Extrude), Capsule, and the
# Edges/Wireframe line geometries.
# --------------------------------------------------------------------------

# ========================== PolyhedronGeometry ==========================
# Subdivide each base triangle into (detail+1)² faces and project to a sphere
# of the given radius. Vertices are non-indexed (3 per face).

# Vector3.lerp: `x + (target.x - x) * alpha`.
@inline _polyhedron_lerp(a::Vec3{Float64}, b::Vec3{Float64}, alpha::Float64) =
    Vec3(a.x + (b.x - a.x) * alpha, a.y + (b.y - a.y) * alpha, a.z + (b.z - a.z) * alpha)

# PolyhedronGeometry.js:113-140 `subdivideFace` grid point v[i][j]: row `i`
# runs from lerp(a, c, i / cols) to lerp(b, c, i / cols) in `cols - i` steps.
@inline function _polyhedron_grid(a::Vec3{Float64}, b::Vec3{Float64}, c::Vec3{Float64},
                                  cols::Int, i::Int, j::Int)
    aj = _polyhedron_lerp(a, c, i / cols)
    j == 0 && i == cols && return aj
    bj = _polyhedron_lerp(b, c, i / cols)
    return _polyhedron_lerp(aj, bj, j / (cols - i))
end

# three.js PolyhedronGeometry `azimuth`: angle about +y measured from -x.
@inline _polyhedron_azimuth(v::Vec3) = atan(v.z, -v.x)

@inline function _polyhedron_write!(data::Vector{Float64}, vi::Int, v::Vec3)
    base = 3vi - 2
    data[base] = v.x
    data[base + 1] = v.y
    data[base + 2] = v.z
    return nothing
end

function _polyhedron_emit_triangle!(positions::Vector{Float64}, normals::Vector{Float64},
                                    uvs::Vector{Float64}, indices::Vector{Int},
                                    vi::Int, out::Int, a::Vec3, b::Vec3,
                                    c::Vec3, radius::Float64, flat::Bool)
    # Unit directions are radius independent; `w` follows the sign of the
    # radius like three.js's projected positions, but stays finite at zero.
    da = normalize(a); db = normalize(b); dc = normalize(c)
    s = radius < 0 ? -1.0 : 1.0
    wa = da * s; wb = db * s; wc = dc * s
    face_normal = flat ? normalize(cross(db - da, dc - da)) : Vec3(0.0, 0.0, 0.0)
    centroid_azimuth = _polyhedron_azimuth(wa + wb + wc)
    us = (0.0, 0.0, 0.0)
    for (k, (d, w)) in enumerate(((da, wa), (db, wb), (dc, wc)))
        dst = vi + k
        _polyhedron_write!(positions, dst, d * radius)
        _polyhedron_write!(normals, dst, flat ? face_normal : w)
        u = _polyhedron_azimuth(w) / 2 / π + 0.5
        (centroid_azimuth < 0 && u == 1) && (u -= 1)
        (w.x == 0 && w.z == 0) && (u = centroid_azimuth / 2 / π + 0.5)
        us = Base.setindex(us, u, k)
        uvs[2dst] = asin(clamp(w.y, -1.0, 1.0)) / π + 0.5
    end
    # Faces straddling the azimuth seam (three.js `correctSeam`).
    if maximum(us) > 0.9 && minimum(us) < 0.1
        us = map(u -> u < 0.2 ? u + 1 : u, us)
    end
    for k in 1:3
        uvs[2(vi + k) - 1] = us[k]
        indices[out + k - 1] = vi + k
    end
    return vi + 3, out + 3
end

function PolyhedronGeometry(base_verts::Vector{<:Vec3}, base_faces::Vector{NTuple{3,Int}};
                            radius=1.0, detail=0)
    radius = _geometry_finite_float(radius, "PolyhedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "PolyhedronGeometry detail")
    verts = Vector{Vec3{Float64}}(undef, length(base_verts))
    for (i, v) in enumerate(base_verts)
        verts[i] = Vec3(_geometry_finite_float(v.x, "PolyhedronGeometry base vertex $i"),
                        _geometry_finite_float(v.y, "PolyhedronGeometry base vertex $i"),
                        _geometry_finite_float(v.z, "PolyhedronGeometry base vertex $i"))
    end
    nbase = length(verts)
    for face in base_faces
        i1, i2, i3 = face
        (1 <= i1 <= nbase && 1 <= i2 <= nbase && 1 <= i3 <= nbase) ||
            throw(ArgumentError("PolyhedronGeometry face indices must reference base vertices"))
    end
    cols = detail + 1
    face_columns = _geometry_checked_mul(
        cols, cols, "PolyhedronGeometry subdivision count")
    n_faces = _geometry_checked_mul(
        length(base_faces), face_columns, "PolyhedronGeometry face count")
    n_verts = _geometry_checked_mul(3, n_faces, "PolyhedronGeometry vertex count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "PolyhedronGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    vi = 0
    out = 1
    # three.js shades detail 0 flat (computeVertexNormals) and smooth otherwise.
    flat = detail == 0
    for (i1, i2, i3) in base_faces
        A = verts[i1]; B = verts[i2]; C = verts[i3]
        # PolyhedronGeometry.js:142-164 emits each grid row's triangles in
        # this order and corner order.
        for i in 0:(cols - 1), j in 0:(2 * (cols - i) - 2)
            k = j ÷ 2
            if iseven(j)
                vi, out = _polyhedron_emit_triangle!(
                    positions, normals, uvs, indices, vi, out,
                    _polyhedron_grid(A, B, C, cols, i, k + 1),
                    _polyhedron_grid(A, B, C, cols, i + 1, k),
                    _polyhedron_grid(A, B, C, cols, i, k), radius, flat)
            else
                vi, out = _polyhedron_emit_triangle!(
                    positions, normals, uvs, indices, vi, out,
                    _polyhedron_grid(A, B, C, cols, i, k + 1),
                    _polyhedron_grid(A, B, C, cols, i + 1, k + 1),
                    _polyhedron_grid(A, B, C, cols, i + 1, k), radius, flat)
            end
        end
    end
    BufferGeometry(positions, normals, uvs, indices, vi, n_faces)
end

function OctahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_float(radius, "OctahedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "OctahedronGeometry detail")
    v = [Vec3(1.0,0,0), Vec3(-1.0,0,0), Vec3(0.0,1.0,0), Vec3(0.0,-1.0,0),
         Vec3(0.0,0,1.0), Vec3(0.0,0,-1.0)]
    f = NTuple{3,Int}[(1,3,5),(1,5,4),(1,4,6),(1,6,3),(2,3,6),(2,6,4),(2,4,5),(2,5,3)]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

function TetrahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_float(radius, "TetrahedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "TetrahedronGeometry detail")
    v = [Vec3(1.0,1,1), Vec3(-1.0,-1,1), Vec3(-1.0,1,-1), Vec3(1.0,-1,-1)]
    f = NTuple{3,Int}[(3,2,1),(1,4,3),(2,4,1),(3,4,2)]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

function DodecahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_float(radius, "DodecahedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "DodecahedronGeometry detail")
    t = (1 + sqrt(5)) / 2
    r = 1 / t
    v = [Vec3(-1.0,-1,-1), Vec3(-1.0,-1,1), Vec3(-1.0,1,-1), Vec3(-1.0,1,1),
         Vec3(1.0,-1,-1), Vec3(1.0,-1,1), Vec3(1.0,1,-1), Vec3(1.0,1,1),
         Vec3(0.0,-r,-t), Vec3(0.0,-r,t), Vec3(0.0,r,-t), Vec3(0.0,r,t),
         Vec3(-r,-t,0.0), Vec3(-r,t,0.0), Vec3(r,-t,0.0), Vec3(r,t,0.0),
         Vec3(-t,0.0,-r), Vec3(t,0.0,-r), Vec3(-t,0.0,r), Vec3(t,0.0,r)]
    f0 = [(3,11,7),(3,7,15),(3,15,13),(7,19,17),(7,17,6),(7,6,15),(17,4,8),(17,8,10),
          (17,10,6),(8,0,16),(8,16,2),(8,2,10),(0,12,1),(0,1,18),(0,18,16),(6,10,2),
          (6,2,13),(6,13,15),(2,16,18),(2,18,3),(2,3,13),(18,1,9),(18,9,11),(18,11,3),
          (4,14,12),(4,12,0),(4,0,8),(11,9,5),(11,5,19),(11,19,7),(19,5,14),(19,14,4),
          (19,4,17),(1,12,14),(1,14,5),(1,5,9)]
    f = NTuple{3,Int}[(a+1, b+1, c+1) for (a, b, c) in f0]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

# ========================== ConvexGeometry ==========================
# Triangulate the boundary of the convex hull of a 3D point set. Faces are
# emitted non-indexed so each hull triangle keeps a flat outward normal.

function _convex_clean_points(points::AbstractVector{<:Vec3})
    raw = Vector{Vec3{Float64}}(undef, length(points))
    for (i, p) in pairs(points)
        q = Vec3(_geometry_finite_float(p.x, "ConvexGeometry points"),
                 _geometry_finite_float(p.y, "ConvexGeometry points"),
                 _geometry_finite_float(p.z, "ConvexGeometry points"))
        raw[i] = q
    end
    isempty(raw) && throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    xmin = minimum(point -> point.x, raw)
    xmax = maximum(point -> point.x, raw)
    ymin = minimum(point -> point.y, raw)
    ymax = maximum(point -> point.y, raw)
    zmin = minimum(point -> point.z, raw)
    zmax = maximum(point -> point.z, raw)
    center = Vec3(_geometry_midpoint(xmin, xmax),
                  _geometry_midpoint(ymin, ymax),
                  _geometry_midpoint(zmin, zmax))
    scale = maximum((abs(xmin - center.x), abs(xmax - center.x),
                     abs(ymin - center.y), abs(ymax - center.y),
                     abs(zmin - center.z), abs(zmax - center.z)))
    scale > 0.0 ||
        throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    eps = 1e-9

    # Centering makes duplicate and hull predicates translation-invariant;
    # scaling keeps their arithmetic finite for both tiny and huge inputs.
    normalized = Vector{Vec3{Float64}}(undef, length(raw))
    for i in eachindex(raw)
        point = raw[i]
        normalized[i] = Vec3((point.x - center.x) / scale,
                             (point.y - center.y) / scale,
                             (point.z - center.z) / scale)
    end

    # Compact the original and normalized points together.
    out = 0
    for read_index in eachindex(raw)
        p = raw[read_index]
        p_scaled = normalized[read_index]
        duplicate = false
        for existing_index in 1:out
            if norm(p_scaled - normalized[existing_index]) <= eps
                duplicate = true
                break
            end
        end
        if !duplicate
            out += 1
            raw[out] = p
            normalized[out] = p_scaled
        end
    end
    resize!(raw, out)
    resize!(normalized, out)
    length(raw) >= 4 ||
        throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))

    # All hull predicates run in this normalized coordinate system. Convex
    # incidence and winding are invariant under a positive uniform scale, and
    # values bounded by one cannot overflow cross products, volume tests, or
    # face-centroid sums. The original coordinates remain available for output.
    return raw, normalized, eps
end

function _convex_has_volume(points::Vector{Vec3{Float64}}, eps::Float64)
    n = length(points)
    threshold = eps^3
    for i in 1:(n - 3), j in (i + 1):(n - 2), k in (j + 1):(n - 1)
        nrm = cross(points[j] - points[i], points[k] - points[i])
        norm(nrm) > eps || continue
        for l in (k + 1):n
            abs(dot(nrm, points[l] - points[i])) > threshold && return true
        end
    end
    return false
end

# Support-plane test for the triangle (i, j, k): returns the outward unit
# normal, or `nothing` when the triangle is degenerate or points lie on both
# sides of its plane beyond `plane_eps`.
@inline function _convex_triple_normal(points::Vector{Vec3{Float64}}, i::Int, j::Int,
                                       k::Int, plane_eps::Float64)
    normal = cross(points[j] - points[i], points[k] - points[i])
    len = norm(normal)
    len > plane_eps || return nothing
    normal = normal * (1 / len)
    pos = false
    neg = false
    @inbounds for p in points
        side = dot(normal, p - points[i])
        pos |= side > plane_eps
        neg |= side < -plane_eps
        pos && neg && break
    end
    pos && neg && return nothing
    pos && (normal = -normal)
    return normal
end

function _convex_coplanar(points::Vector{Vec3{Float64}}, origin::Int,
                          normal::Vec3{Float64}, plane_eps::Float64)
    coplanar = Int[]
    @inbounds for idx in eachindex(points)
        abs(dot(normal, points[idx] - points[origin])) <= plane_eps &&
            push!(coplanar, idx)
    end
    return coplanar
end

# Reference enumeration: every triple whose plane supports the point set, in
# lexicographic triple order, deduplicated by coplanar point set. O(n^4); the
# gift-wrapping search below reproduces its faces and order and falls back to
# this when it cannot certify a closed hull.
function _convex_support_faces(points::Vector{Vec3{Float64}}, eps::Float64)
    n = length(points)
    faces = Tuple{Vector{Int},Vec3{Float64}}[]
    sizehint!(faces, n)
    seen = Set{Vector{Int}}()
    sizehint!(seen, n)
    plane_eps = 64 * eps
    for i in 1:(n - 2), j in (i + 1):(n - 1), k in (j + 1):n
        normal = _convex_triple_normal(points, i, j, k, plane_eps)
        normal === nothing && continue
        coplanar = _convex_coplanar(points, i, normal, plane_eps)
        if !(coplanar in seen)
            push!(seen, coplanar)
            push!(faces, (coplanar, normal))
        end
    end
    return faces
end

# The face that the reference enumeration reports for the support plane
# containing `candidates` (sorted): its first valid triple in lexicographic
# order, that triple's outward normal and its coplanar set.
function _convex_canonical_face(points::Vector{Vec3{Float64}}, candidates::Vector{Int},
                                plane_eps::Float64)
    m = length(candidates)
    @inbounds for a in 1:(m - 2), b in (a + 1):(m - 1), c in (b + 1):m
        i = candidates[a]; j = candidates[b]; k = candidates[c]
        normal = _convex_triple_normal(points, i, j, k, plane_eps)
        normal === nothing && continue
        return (i, j, k), _convex_coplanar(points, i, normal, plane_eps), normal
    end
    return nothing
end

# Gift wrapping across the edge u -> v of a face (counter-clockwise about that
# face's outward normal): the neighbouring face lists the edge as v -> u, so
# its outward normal is cross(u - v, w - v) for the point w that leaves every
# point behind the plane. Returns the support plane's points (sorted).
function _convex_wrap_edge(points::Vector{Vec3{Float64}}, u::Int, v::Int,
                           plane_eps::Float64)
    pu = points[u]
    pv = points[v]
    edge = pu - pv
    best = 0
    normal = Vec3(0.0, 0.0, 0.0)
    @inbounds for idx in eachindex(points)
        (idx == u || idx == v) && continue
        candidate = cross(edge, points[idx] - pv)
        len = norm(candidate)
        len > plane_eps || continue
        if best == 0 || dot(normal, points[idx] - pv) > plane_eps
            best = idx
            normal = candidate * (1 / len)
        end
    end
    best == 0 && return nothing
    return _convex_coplanar(points, v, normal, plane_eps)
end

function _convex_add_wrapped_face!(faces, seen::Set{Vector{Int}},
                                   edges::Set{Tuple{Int,Int}}, open_edges::Vector{Tuple{Int,Int}},
                                   points::Vector{Vec3{Float64}}, candidates::Vector{Int},
                                   eps::Float64, plane_eps::Float64)
    canonical = _convex_canonical_face(points, candidates, plane_eps)
    canonical === nothing && return false
    triple, coplanar, normal = canonical
    coplanar in seen && return true
    push!(seen, coplanar)
    hull = _convex_face_hull(points, coplanar, normal, eps)
    length(hull) >= 3 || return false
    push!(faces, (triple, coplanar, normal, hull))
    m = length(hull)
    @inbounds for k in 1:m
        edge = (hull[k], hull[k == m ? 1 : k + 1])
        edge in edges && return false     # an edge already bounds another face
        push!(edges, edge)
        push!(open_edges, edge)
    end
    return true
end

# Output-sensitive search for the reference enumeration's faces: wrap from one
# support plane across every hull edge. Returns each face's coplanar points,
# outward normal and boundary polygon (`_convex_face_hull` with this `eps`),
# or `nothing` unless the faces close up into a consistently oriented surface.
function _convex_wrapped_support_faces(points::Vector{Vec3{Float64}}, eps::Float64)
    n = length(points)
    plane_eps = 64 * eps
    # Start from the lowest point in (x, y, z) order and the next counter-
    # clockwise point of the xy-projected hull; the vertical plane through
    # them supports every point, so wrapping about that segment reaches a face.
    a = 1
    @inbounds for idx in 2:n
        points[idx].x < points[a].x ||
            (points[idx].x == points[a].x && (points[idx].y, points[idx].z) <
                                             (points[a].y, points[a].z)) || continue
        a = idx
    end
    b = 0
    @inbounds for idx in eachindex(points)
        idx == a && continue
        d = points[idx] - points[a]
        hypot(d.x, d.y) > plane_eps || continue
        if b == 0
            b = idx
            continue
        end
        db = points[b] - points[a]
        turn = db.x * d.y - db.y * d.x
        if turn < 0 || (turn == 0 && hypot(d.x, d.y) > hypot(db.x, db.y))
            b = idx
        end
    end
    b == 0 && return nothing
    faces = Tuple{NTuple{3,Int},Vector{Int},Vec3{Float64},Vector{Int}}[]
    seen = Set{Vector{Int}}()
    edges = Set{Tuple{Int,Int}}()
    open_edges = Tuple{Int,Int}[]
    started = false
    for (u, v) in ((a, b), (b, a))
        candidates = _convex_wrap_edge(points, u, v, plane_eps)
        candidates === nothing && continue
        _convex_add_wrapped_face!(faces, seen, edges, open_edges, points,
                                  candidates, eps, plane_eps) || return nothing
        started = !isempty(faces)
        started && break
    end
    started || return nothing
    while !isempty(open_edges)
        u, v = pop!(open_edges)
        (v, u) in edges && continue
        candidates = _convex_wrap_edge(points, u, v, plane_eps)
        candidates === nothing && return nothing
        before = length(faces)
        _convex_add_wrapped_face!(faces, seen, edges, open_edges, points,
                                  candidates, eps, plane_eps) || return nothing
        # The neighbour must be new and must close the edge it was found from.
        length(faces) > before && (v, u) in edges || return nothing
    end
    sort!(faces; by=first)
    return [(coplanar, normal, hull) for (_, coplanar, normal, hull) in faces]
end

function _convex_face_hull(points::Vector{Vec3{Float64}}, face_indices::Vector{Int},
                           normal::Vec3{Float64}, eps::Float64)
    center = Vec3(0.0, 0.0, 0.0)
    for idx in face_indices
        center += points[idx]
    end
    center *= 1 / length(face_indices)

    u = Vec3(0.0, 0.0, 0.0)
    for idx in face_indices
        candidate = points[idx] - center
        if norm(candidate) > eps
            u = normalize(candidate)
            break
        end
    end
    norm(u) > eps || return Int[]
    v = cross(normal, u)

    projected = Tuple{Float64,Float64,Int}[]
    sizehint!(projected, length(face_indices))
    for idx in face_indices
        d = points[idx] - center
        push!(projected, (dot(d, u), dot(d, v), idx))
    end
    sort!(projected, by=t -> (t[1], t[2], t[3]))
    # Points whose first coordinates differ only by rounding (for example the
    # stacked points of an edge that projects vertically) must reach the
    # monotone chain in order along that edge, as exact ties would. Snap each
    # run of first coordinates within `eps` of its start and re-sort by the
    # second coordinate inside the run.
    run_start = 1
    @inbounds for k in 2:length(projected)
        if projected[k][1] - projected[run_start][1] <= eps
            projected[k] = (projected[run_start][1], projected[k][2], projected[k][3])
        else
            run_start = k
        end
    end
    sort!(projected, by=t -> (t[1], t[2], t[3]))

    filtered = Tuple{Float64,Float64,Int}[]
    sizehint!(filtered, length(projected))
    for p in projected
        if isempty(filtered) ||
           hypot(p[1] - filtered[end][1], p[2] - filtered[end][2]) > eps
            push!(filtered, p)
        end
    end

    cross2(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) -
                      (a[2] - o[2]) * (b[1] - o[1])
    lower = Tuple{Float64,Float64,Int}[]
    sizehint!(lower, length(filtered))
    for p in filtered
        while length(lower) >= 2 &&
              cross2(lower[end - 1], lower[end], p) <= eps
            pop!(lower)
        end
        push!(lower, p)
    end
    upper = Tuple{Float64,Float64,Int}[]
    sizehint!(upper, length(filtered))
    for p in Iterators.reverse(filtered)
        while length(upper) >= 2 &&
              cross2(upper[end - 1], upper[end], p) <= eps
            pop!(upper)
        end
        push!(upper, p)
    end
    hull = Int[]
    sizehint!(hull, length(lower) + length(upper) - 2)
    for i in 1:(length(lower) - 1)
        push!(hull, lower[i][3])
    end
    for i in 1:(length(upper) - 1)
        push!(hull, upper[i][3])
    end
    length(hull) >= 3 || return Int[]
    face_normal = cross(points[hull[2]] - points[hull[1]],
                        points[hull[3]] - points[hull[1]])
    dot(face_normal, normal) < 0.0 && reverse!(hull)
    return hull
end

# Rounding-level tolerance in the normalized coordinates (|x| <= 1): 64x this
# stays well above the rounding error of a plane-distance evaluation (a few
# 1e-16), comparable to three.js ConvexHull's 3 * EPSILON * (|x| + |y| + |z|).
const _CONVEX_TIGHT_EPS = 1e-15

"""
    ConvexGeometry(points)

Build a flat-shaded triangle `BufferGeometry` for the convex hull of a
non-coplanar 3D point set.
"""
function ConvexGeometry(points::AbstractVector{<:Vec3})
    clean, normalized, eps = _convex_clean_points(points)
    _convex_has_volume(normalized, eps) ||
        throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    # Gift wrapping certifies a closed hull surface. Points within the `eps`
    # plane tolerance of one another's faces can make those tolerant face sets
    # inconsistent; resolving them at rounding-level tolerance instead (as
    # three.js ConvexHull does) splits them into separate facets. The
    # exhaustive enumeration is the last resort.
    wrapped = _convex_wrapped_support_faces(normalized, eps)
    wrapped === nothing &&
        (wrapped = _convex_wrapped_support_faces(normalized, _CONVEX_TIGHT_EPS))
    hulls = Tuple{Vector{Int},Vec3{Float64}}[]
    if wrapped === nothing
        support_faces = _convex_support_faces(normalized, eps)
        isempty(support_faces) &&
            throw(ArgumentError("ConvexGeometry could not find hull support faces"))
        sizehint!(hulls, length(support_faces))
        for (face_indices, normal) in support_faces
            hull = _convex_face_hull(normalized, face_indices, normal, eps)
            length(hull) >= 3 && push!(hulls, (hull, normal))
        end
    else
        sizehint!(hulls, length(wrapped))
        for (_, normal, hull) in wrapped
            push!(hulls, (hull, normal))
        end
    end
    n_faces = 0
    for (hull, _) in hulls
        n_faces = _geometry_checked_add(
            n_faces, length(hull) - 2, "ConvexGeometry face count")
    end
    n_faces >= 4 ||
        throw(ArgumentError("ConvexGeometry produced no non-degenerate hull volume"))

    n_verts = _geometry_checked_mul(3, n_faces, "ConvexGeometry vertex count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "ConvexGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    vi = 0
    @inbounds for (hull, normal) in hulls
        origin = clean[hull[1]]
        for k in 2:(length(hull) - 1)
            p1 = origin
            p2 = clean[hull[k]]
            p3 = clean[hull[k + 1]]
            face_normal = normal
            for p in (p1, p2, p3)
                vi += 1
                pbase = 3vi - 2
                positions[pbase] = p.x
                positions[pbase + 1] = p.y
                positions[pbase + 2] = p.z
                normals[pbase] = face_normal.x
                normals[pbase + 1] = face_normal.y
                normals[pbase + 2] = face_normal.z
                ubase = 2vi - 1
                uvs[ubase] = p.x
                uvs[ubase + 1] = p.y
                indices[vi] = vi
            end
        end
    end
    return BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

# ========================== LatheGeometry ==========================
# Revolve a 2D profile (x = radius, y = height) about the y-axis.

function _validate_lathe_points(points::Vector{<:Vec2})
    length(points) >= 2 || throw(ArgumentError("LatheGeometry needs at least two profile points"))
    for (i, pt) in pairs(points)
        _geometry_finite_float(pt.x, "LatheGeometry profile point $i")
        _geometry_finite_float(pt.y, "LatheGeometry profile point $i")
    end
    return nothing
end

function LatheGeometry(points::Vector{<:Vec2}; segments=12, phi_start=0.0, phi_length=2π)
    np = length(points)
    _validate_lathe_points(points)
    phi_start = _geometry_finite_scalar(phi_start, "LatheGeometry phi_start")
    phi_length = _geometry_finite_scalar(phi_length, "LatheGeometry phi_length")
    # LatheGeometry.js:56 accepts any segment count >= 1; 0 would make
    # i / segments NaN, so it is raised to 1.
    segments = _clamp_seg(segments, 1, "LatheGeometry segments")
    phi_length = clamp(phi_length, zero(phi_length), 2π)          # three.js clamps the sweep

    n_verts = _geometry_checked_mul(
        segments + 1, np, "LatheGeometry vertex count")
    n_faces = _geometry_checked_mul(
        2 * segments, np - 1, "LatheGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "LatheGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    for i in 0:segments
        u = i / segments
        phi = phi_start + u * phi_length
        c = cos(phi); s = sin(phi)
        for j in 1:np
            pt = points[j]
            vi = i * np + j
            pbase = 3vi - 2
            ubase = 2vi - 1
            # three.js phase: phi = 0 lies on +z, sweeping towards +x.
            positions[pbase] = pt.x * s
            positions[pbase + 1] = pt.y
            positions[pbase + 2] = pt.x * c
            jm = max(j-1, 1); jp = min(j+1, np)
            dx, dy = _geometry_unit_delta2(
                Float64(points[jm].x), Float64(points[jm].y),
                Float64(points[jp].x), Float64(points[jp].y))
            nr = dy; nh = -dx                      # outward profile normal
            nx = nr*s; ny = nh; nz = nr*c
            nl = hypot(nx, ny, nz); nl > 0 && (nx/=nl; ny/=nl; nz/=nl)
            normals[pbase] = nx
            normals[pbase + 1] = ny
            normals[pbase + 2] = nz
            uvs[ubase] = u
            uvs[ubase + 1] = (j - 1) / (np - 1)
        end
    end
    out = 1
    for i in 0:segments-1, j in 0:np-2
        a = i*np + j + 1; b = (i+1)*np + j + 1
        c = (i+1)*np + j + 2; d = i*np + j + 2
        # LatheGeometry.js:176-177 emits (a, b, d) and (c, d, b).
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = d
        indices[out + 3] = c
        indices[out + 4] = d
        indices[out + 5] = b
        out += 6
    end
    BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

# ========================== TubeGeometry ==========================
# Sweep a circle of `radius` along a polyline `path`.

function _validate_tube_path(path::Vector{<:Vec3})
    length(path) >= 2 || throw(ArgumentError("TubeGeometry needs at least two path points"))
    for (i, pt) in pairs(path)
        _geometry_finite_float(pt.x, "TubeGeometry path point $i")
        _geometry_finite_float(pt.y, "TubeGeometry path point $i")
        _geometry_finite_float(pt.z, "TubeGeometry path point $i")
    end
    return nothing
end

@inline function _tube_unit_delta(a::Vec3, b::Vec3)
    return _geometry_unit_delta3(
        Float64(a.x), Float64(a.y), Float64(a.z),
        Float64(b.x), Float64(b.y), Float64(b.z),
    )
end

@inline function _tube_tangent(path::AbstractVector{<:Vec3}, i::Int, n::Int,
                               closed::Bool=false)
    prev = closed ? path[mod1(i - 1, n)] : path[max(i - 1, 1)]
    next = closed ? path[mod1(i + 1, n)] : path[min(i + 1, n)]
    tangent = _tube_unit_delta(prev, next)
    norm(tangent) > 0.0 && return tangent
    # A 180-degree reversal can make the centered difference zero despite both
    # adjacent segments being valid. Prefer the forward segment at the cusp.
    (closed || i < n) && return _tube_unit_delta(path[i], path[mod1(i + 1, n)])
    return _tube_unit_delta(path[i - 1], path[i])
end

# Rotate `v` about the unit `axis` by `angle` (three.js Matrix4.makeRotationAxis).
@inline _tube_rotate(v::Vec3, axis::Vec3, angle::Float64) =
    v * cos(angle) + cross(axis, v) * sin(angle) + axis * (dot(axis, v) * (1 - cos(angle)))

@inline function _tube_transport(N::Vec3, B::Vec3, T::Vec3)
    Np = N - T*dot(N, T)               # project previous N off the new tangent
    N = norm(Np) > 1e-9 ? normalize(Np) : normalize(cross(B, T))
    return N, cross(T, N)
end

"""
    TubeGeometry(path; radius=1.0, radial_segments=8, closed=false)

Sweep a circle of `radius` along the polyline `path` with parallel-transported
frames (three.js `TubeGeometry`). With `closed=true` the path wraps from its last
point back to the first, frames are twisted so the seam matches
(three.js `computeFrenetFrames(segments, true)`), and the final ring duplicates
the first one with `u = 1`.
"""
function TubeGeometry(path::Vector{<:Vec3}; radius=1.0, radial_segments=8, closed::Bool=false)
    _validate_tube_path(path)
    @inbounds for i in 2:length(path)
        _geometry_delta_norm3(
            Float64(path[i - 1].x), Float64(path[i - 1].y),
            Float64(path[i - 1].z), Float64(path[i].x),
            Float64(path[i].y), Float64(path[i].z)) > 0.0 ||
            throw(ArgumentError(
                "TubeGeometry path needs consecutive distinct points"))
    end
    if closed && path[end] == path[1]
        path = path[1:end-1]
    end
    n = length(path)
    closed && n < 3 &&
        throw(ArgumentError("closed TubeGeometry needs at least three distinct points"))
    radius = _geometry_finite_float(radius, "TubeGeometry radius")
    radial_segments = _clamp_seg(radial_segments, 3, "TubeGeometry radial_segments")   # clamp so 0 can't make j/radial_segments NaN

    rs1 = radial_segments + 1
    rings = closed ? n + 1 : n
    n_verts = _geometry_checked_mul(rings, rs1, "TubeGeometry vertex count")
    n_faces = _geometry_checked_mul(
        2 * (rings - 1), radial_segments, "TubeGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "TubeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    # Initial frame from the first tangent, parallel-transported along the path
    # (as in three.js computeFrenetFrames) so the frame never flips between rings.
    T1 = _tube_tangent(path, 1, n, closed)
    refv = abs(T1.y) < 0.99 ? Vec3(0.0,1.0,0.0) : Vec3(1.0,0.0,0.0)
    N1 = normalize(cross(refv, T1))
    twist = 0.0
    if closed
        N = N1; B = cross(T1, N1)
        for i in 2:n
            N, B = _tube_transport(N, B, _tube_tangent(path, i, n, closed))
        end
        N_end, _ = _tube_transport(N, B, T1)
        twist = acos(clamp(dot(N1, N_end), -1.0, 1.0)) / n
        dot(T1, cross(N1, N_end)) > 0 && (twist = -twist)
    end
    N = N1; B = cross(T1, N1)
    for ring in 1:rings
        i = ring > n ? 1 : ring
        T = i == 1 ? T1 : _tube_tangent(path, i, n, closed)
        if ring > n
            N = N1; B = cross(T1, N1)
        elseif i > 1
            N, B = _tube_transport(N, B, T)
        end
        Nr, Br = N, B
        if closed && 1 < ring <= n
            Nr = _tube_rotate(N, T, twist * (ring - 1))
            Br = cross(T, Nr)
        end
        for j in 0:radial_segments
            vj = j / radial_segments
            v = vj * 2π
            normal = Nr * cos(v) + Br * sin(v)
            p = path[i] + normal * radius
            _geometry_check_position(
                Float64(p.x), Float64(p.y), Float64(p.z), "TubeGeometry")
            vi = (ring - 1) * rs1 + j + 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = p.x
            positions[pbase + 1] = p.y
            positions[pbase + 2] = p.z
            normals[pbase] = normal.x
            normals[pbase + 1] = normal.y
            normals[pbase + 2] = normal.z
            uvs[ubase] = (ring - 1) / (rings - 1)
            uvs[ubase + 1] = vj
        end
    end

    out = 1
    for i in 0:rings-2, j in 0:radial_segments-1
        a = i*rs1 + j + 1; b = (i+1)*rs1 + j + 1
        c = (i+1)*rs1 + j + 2; d = i*rs1 + j + 2
        indices[out] = a
        indices[out + 1] = d
        indices[out + 2] = b
        indices[out + 3] = b
        indices[out + 4] = d
        indices[out + 5] = c
        out += 6
    end
    BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

# ========================== Curves (three.js extras) ==========================
# Curve.js, curves/*.js, CurvePath.js, Path.js, Shape.js. Curves evaluate in
# Float64; arc lengths are recomputed on demand (three.js caches them, which
# does not change any result).

"""
    Curve{P}

Abstract parametric curve with points of type `P` (`Vec2{Float64}` or
`Vec3{Float64}`), the counterpart of three.js `Curve`. Every curve supports
[`get_point`](@ref), [`get_point_at`](@ref), [`get_points`](@ref),
[`get_spaced_points`](@ref), [`get_length`](@ref), [`get_lengths`](@ref),
[`get_u_to_t_mapping`](@ref), [`get_tangent`](@ref) and
[`get_tangent_at`](@ref); 3D curves also support
[`compute_frenet_frames`](@ref) and [`TubeGeometry`](@ref). `t` is the curve
parameter and `u ∈ [0, 1]` the fraction of arc length, approximated as in
three.js from 200 chords.

Implementations: [`LineCurve`](@ref), [`LineCurve3`](@ref),
[`QuadraticBezierCurve`](@ref), [`QuadraticBezierCurve3`](@ref),
[`CubicBezierCurve`](@ref), [`CubicBezierCurve3`](@ref),
[`EllipseCurve`](@ref) (and [`ArcCurve`](@ref)), [`SplineCurve`](@ref),
[`CatmullRomCurve`](@ref), and the composite [`CurvePath`](@ref),
[`Path`](@ref) and [`Shape`](@ref).
"""
abstract type Curve{P} end

const _CURVE_ARC_LENGTH_DIVISIONS = 200

_curve_vec2(p::Vec2, label::String) =
    Vec2(_geometry_finite_float(p.x, label), _geometry_finite_float(p.y, label))
_curve_vec3(p::Vec3, label::String) =
    Vec3(_geometry_finite_float(p.x, label), _geometry_finite_float(p.y, label),
         _geometry_finite_float(p.z, label))

"""
    LineCurve(v1::Vec2, v2::Vec2)

Straight 2D segment from `v1` to `v2` (three.js `LineCurve`). Its parameter is
already arc length, so `get_point_at` equals `get_point`.
"""
struct LineCurve <: Curve{Vec2{Float64}}
    v1::Vec2{Float64}
    v2::Vec2{Float64}
    LineCurve(v1::Vec2, v2::Vec2) =
        new(_curve_vec2(v1, "LineCurve v1"), _curve_vec2(v2, "LineCurve v2"))
end

"""
    LineCurve3(v1::Vec3, v2::Vec3)

Straight 3D segment from `v1` to `v2` (three.js `LineCurve3`); see
[`LineCurve`](@ref).
"""
struct LineCurve3 <: Curve{Vec3{Float64}}
    v1::Vec3{Float64}
    v2::Vec3{Float64}
    LineCurve3(v1::Vec3, v2::Vec3) =
        new(_curve_vec3(v1, "LineCurve3 v1"), _curve_vec3(v2, "LineCurve3 v2"))
end

"""
    QuadraticBezierCurve(v0::Vec2, v1::Vec2, v2::Vec2)

2D quadratic Bézier curve with control point `v1` (three.js
`QuadraticBezierCurve`).
"""
struct QuadraticBezierCurve <: Curve{Vec2{Float64}}
    v0::Vec2{Float64}
    v1::Vec2{Float64}
    v2::Vec2{Float64}
    QuadraticBezierCurve(v0::Vec2, v1::Vec2, v2::Vec2) =
        new(_curve_vec2(v0, "QuadraticBezierCurve v0"), _curve_vec2(v1, "QuadraticBezierCurve v1"),
            _curve_vec2(v2, "QuadraticBezierCurve v2"))
end

"""
    QuadraticBezierCurve3(v0::Vec3, v1::Vec3, v2::Vec3)

3D quadratic Bézier curve (three.js `QuadraticBezierCurve3`).
"""
struct QuadraticBezierCurve3 <: Curve{Vec3{Float64}}
    v0::Vec3{Float64}
    v1::Vec3{Float64}
    v2::Vec3{Float64}
    QuadraticBezierCurve3(v0::Vec3, v1::Vec3, v2::Vec3) =
        new(_curve_vec3(v0, "QuadraticBezierCurve3 v0"), _curve_vec3(v1, "QuadraticBezierCurve3 v1"),
            _curve_vec3(v2, "QuadraticBezierCurve3 v2"))
end

"""
    CubicBezierCurve(v0::Vec2, v1::Vec2, v2::Vec2, v3::Vec2)

2D cubic Bézier curve with control points `v1`, `v2` (three.js
`CubicBezierCurve`).
"""
struct CubicBezierCurve <: Curve{Vec2{Float64}}
    v0::Vec2{Float64}
    v1::Vec2{Float64}
    v2::Vec2{Float64}
    v3::Vec2{Float64}
    CubicBezierCurve(v0::Vec2, v1::Vec2, v2::Vec2, v3::Vec2) =
        new(_curve_vec2(v0, "CubicBezierCurve v0"), _curve_vec2(v1, "CubicBezierCurve v1"),
            _curve_vec2(v2, "CubicBezierCurve v2"), _curve_vec2(v3, "CubicBezierCurve v3"))
end

"""
    CubicBezierCurve3(v0::Vec3, v1::Vec3, v2::Vec3, v3::Vec3)

3D cubic Bézier curve (three.js `CubicBezierCurve3`).
"""
struct CubicBezierCurve3 <: Curve{Vec3{Float64}}
    v0::Vec3{Float64}
    v1::Vec3{Float64}
    v2::Vec3{Float64}
    v3::Vec3{Float64}
    CubicBezierCurve3(v0::Vec3, v1::Vec3, v2::Vec3, v3::Vec3) =
        new(_curve_vec3(v0, "CubicBezierCurve3 v0"), _curve_vec3(v1, "CubicBezierCurve3 v1"),
            _curve_vec3(v2, "CubicBezierCurve3 v2"), _curve_vec3(v3, "CubicBezierCurve3 v3"))
end

"""
    EllipseCurve(ax=0, ay=0, x_radius=1, y_radius=1, start_angle=0, end_angle=2π,
                 clockwise=false, rotation=0)

2D ellipse arc centred at `(ax, ay)` from `start_angle` to `end_angle`
radians, counterclockwise unless `clockwise`, rotated by `rotation` about its
centre (three.js `EllipseCurve`, including its handling of the sweep: angles
equal within machine epsilon give a point, a sweep that is a multiple of 2π a
full turn). The angles and their difference must be finite.
"""
struct EllipseCurve <: Curve{Vec2{Float64}}
    ax::Float64
    ay::Float64
    x_radius::Float64
    y_radius::Float64
    start_angle::Float64
    end_angle::Float64
    clockwise::Bool
    rotation::Float64
    function EllipseCurve(ax::Real=0.0, ay::Real=0.0, x_radius::Real=1.0, y_radius::Real=1.0,
                          start_angle::Real=0.0, end_angle::Real=2π, clockwise::Bool=false,
                          rotation::Real=0.0)
        f(value, label) = _geometry_finite_float(value, "EllipseCurve $label")
        start_value = f(start_angle, "start_angle")
        end_value = f(end_angle, "end_angle")
        isfinite(end_value - start_value) ||
            throw(ArgumentError("EllipseCurve end_angle - start_angle must be finite"))
        return new(f(ax, "ax"), f(ay, "ay"), f(x_radius, "x_radius"), f(y_radius, "y_radius"),
                   start_value, end_value, clockwise, f(rotation, "rotation"))
    end
end

"""
    ArcCurve(ax, ay, radius, start_angle, end_angle, clockwise=false)

Circular arc (three.js `ArcCurve`): the [`EllipseCurve`](@ref) with both radii
equal to `radius`.
"""
ArcCurve(ax::Real, ay::Real, radius::Real, start_angle::Real, end_angle::Real,
         clockwise::Bool=false) =
    EllipseCurve(ax, ay, radius, radius, start_angle, end_angle, clockwise)

"""
    SplineCurve(points::AbstractVector{<:Vec2})

2D uniform Catmull–Rom spline through `points` (three.js `SplineCurve`); the
end segments repeat the end points as their outer neighbours. Needs at least
one point.
"""
struct SplineCurve <: Curve{Vec2{Float64}}
    points::Vector{Vec2{Float64}}
    function SplineCurve(points::AbstractVector{<:Vec2})
        isempty(points) && throw(ArgumentError("SplineCurve needs at least one point"))
        return new([_curve_vec2(p, "SplineCurve point") for p in points])
    end
end

"""
    CurvePath{P}(curves=Curve{P}[]; auto_close=false)
    CurvePath(curves::AbstractVector{<:Curve{P}}; auto_close=false)

A sequence of connected curves treated as one curve, parametrized by arc
length over its pieces (three.js `CurvePath`). Append pieces with
`add!(path, curve)` and close it with [`close_path!`](@ref). With
`auto_close`, `get_points` and `get_spaced_points` repeat the first point at
the end.
"""
mutable struct CurvePath{P} <: Curve{P}
    curves::Vector{Curve{P}}
    auto_close::Bool
end
CurvePath{P}(curves::AbstractVector=Curve{P}[]; auto_close::Bool=false) where {P} =
    CurvePath{P}(Vector{Curve{P}}(curves), auto_close)
CurvePath(curves::AbstractVector{<:Curve{P}}; auto_close::Bool=false) where {P} =
    CurvePath{P}(curves; auto_close=auto_close)

"""
    Path(points=nothing)

A 2D [`CurvePath`](@ref) built with pen commands (three.js `Path`):
[`move_to!`](@ref), [`line_to!`](@ref), [`quadratic_curve_to!`](@ref),
[`bezier_curve_to!`](@ref), [`spline_thru!`](@ref), [`arc!`](@ref),
[`absarc!`](@ref), [`ellipse!`](@ref) and [`absellipse!`](@ref), each of which
appends a curve from the current point and returns the path. `Path(points)`
starts at `points[1]` and adds a line to each further point.
"""
mutable struct Path <: Curve{Vec2{Float64}}
    curves::Vector{Curve{Vec2{Float64}}}
    auto_close::Bool
    current_point::Vec2{Float64}
    function Path(points::Union{Nothing,AbstractVector{<:Vec2}}=nothing)
        path = new(Curve{Vec2{Float64}}[], false, Vec2(0.0, 0.0))
        points === nothing || set_from_points!(path, points)
        return path
    end
end

"""
    Shape(points=nothing)

A closed 2D outline with optional holes (three.js `Shape`): a [`Path`](@ref)
plus `holes::Vector{Path}`. [`extract_points`](@ref) samples both, and
`ShapeGeometry(shape)` / `ExtrudeGeometry(shape)` build meshes from it.
"""
mutable struct Shape <: Curve{Vec2{Float64}}
    curves::Vector{Curve{Vec2{Float64}}}
    auto_close::Bool
    current_point::Vec2{Float64}
    holes::Vector{Path}
    function Shape(points::Union{Nothing,AbstractVector{<:Vec2}}=nothing)
        shape = new(Curve{Vec2{Float64}}[], false, Vec2(0.0, 0.0), Path[])
        points === nothing || set_from_points!(shape, points)
        return shape
    end
end

const _CompositeCurve = Union{CurvePath,Path,Shape}
const _PenPath = Union{Path,Shape}

_curve_point_type(::Curve{P}) where {P} = P

# ---- point evaluation (Interpolations.js) ----

@inline function _catmull_rom_scalar(t::Float64, p0::Float64, p1::Float64, p2::Float64, p3::Float64)
    v0 = (p2 - p0) * 0.5
    v1 = (p3 - p1) * 0.5
    t2 = t * t
    t3 = t * t2
    return (2 * p1 - 2 * p2 + v0 + v1) * t3 + (-3 * p1 + 3 * p2 - 2 * v0 - v1) * t2 + v0 * t + p1
end

@inline function _quadratic_bezier(t::Float64, p0::Float64, p1::Float64, p2::Float64)
    k = 1 - t
    return k * k * p0 + 2 * (1 - t) * t * p1 + t * t * p2
end

@inline function _cubic_bezier(t::Float64, p0::Float64, p1::Float64, p2::Float64, p3::Float64)
    k = 1 - t
    return k * k * k * p0 + 3 * k * k * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t * p3
end

_curve_t(t, label::String="curve parameter") = _geometry_finite_float(t, label)

"""
    get_point(curve, t)

Point of `curve` at parameter `t` (three.js `Curve.getPoint`). Most curves
accept any finite `t`, extrapolating beyond `[0, 1]` as three.js does; a
[`CurvePath`](@ref) needs `t ∈ [0, 1]`.
"""
function get_point end

function get_point(c::Union{LineCurve,LineCurve3}, t::Real)
    t = _curve_t(t)
    # LineCurve.js:49-61: t === 1 returns v2 exactly.
    t == 1 && return c.v2
    return (c.v2 - c.v1) * t + c.v1
end

get_point(c::QuadraticBezierCurve, t::Real) = (t = _curve_t(t);
    Vec2(_quadratic_bezier(t, c.v0.x, c.v1.x, c.v2.x), _quadratic_bezier(t, c.v0.y, c.v1.y, c.v2.y)))
get_point(c::QuadraticBezierCurve3, t::Real) = (t = _curve_t(t);
    Vec3(_quadratic_bezier(t, c.v0.x, c.v1.x, c.v2.x), _quadratic_bezier(t, c.v0.y, c.v1.y, c.v2.y),
         _quadratic_bezier(t, c.v0.z, c.v1.z, c.v2.z)))
get_point(c::CubicBezierCurve, t::Real) = (t = _curve_t(t);
    Vec2(_cubic_bezier(t, c.v0.x, c.v1.x, c.v2.x, c.v3.x),
         _cubic_bezier(t, c.v0.y, c.v1.y, c.v2.y, c.v3.y)))
get_point(c::CubicBezierCurve3, t::Real) = (t = _curve_t(t);
    Vec3(_cubic_bezier(t, c.v0.x, c.v1.x, c.v2.x, c.v3.x), _cubic_bezier(t, c.v0.y, c.v1.y, c.v2.y, c.v3.y),
         _cubic_bezier(t, c.v0.z, c.v1.z, c.v2.z, c.v3.z)))

function get_point(c::EllipseCurve, t::Real)
    t = _curve_t(t)
    # EllipseCurve.js:123-170.
    two_pi = π * 2
    delta = c.end_angle - c.start_angle
    same_points = abs(delta) < eps(Float64)
    # three.js reduces the sweep by repeated 2π steps, which takes |delta| / 2π
    # iterations and never ends once delta - 2π == delta (|delta| >= 2^55).
    # Long sweeps take the exact remainder first; shorter ones keep three.js's
    # steps and rounding.
    abs(delta) > 1024 * two_pi && (delta = rem(delta, two_pi))
    while delta < 0
        delta += two_pi
    end
    while delta > two_pi
        delta -= two_pi
    end
    if delta < eps(Float64)
        delta = same_points ? 0.0 : two_pi
    end
    if c.clockwise && !same_points
        delta = delta == two_pi ? -two_pi : delta - two_pi
    end
    angle = c.start_angle + t * delta
    x = c.ax + c.x_radius * cos(angle)
    y = c.ay + c.y_radius * sin(angle)
    if c.rotation != 0
        cr = cos(c.rotation)
        sr = sin(c.rotation)
        tx = x - c.ax
        ty = y - c.ay
        x = tx * cr - ty * sr + c.ax
        y = tx * sr + ty * cr + c.ay
    end
    return Vec2(x, y)
end

function get_point(c::SplineCurve, t::Real)
    t = _curve_t(t)
    points = c.points
    n = length(points)
    # SplineCurve.js:53-71 (0-based indices, clamped as there).
    p = (n - 1) * t
    int_point = floor(p)
    weight = p - int_point
    0 <= int_point <= n - 1 || throw(ArgumentError("SplineCurve parameter must lie in [0, 1]"))
    i = Int(int_point)
    p0 = points[(i == 0 ? i : i - 1) + 1]
    p1 = points[i + 1]
    p2 = points[(i > n - 2 ? n - 1 : i + 1) + 1]
    p3 = points[(i > n - 3 ? n - 1 : i + 2) + 1]
    return Vec2(_catmull_rom_scalar(weight, p0.x, p1.x, p2.x, p3.x),
                _catmull_rom_scalar(weight, p0.y, p1.y, p2.y, p3.y))
end


function _curve_lengths(c::_CompositeCurve)
    isempty(c.curves) && throw(ArgumentError("$(nameof(typeof(c))) has no curves"))
    lengths = Vector{Float64}(undef, length(c.curves))
    sum = 0.0
    for (i, curve) in enumerate(c.curves)
        sum += get_length(curve)
        lengths[i] = sum
    end
    return lengths
end

# Arc-length tables of a composite curve, computed once per call that samples
# it many times (three.js caches the same values on the curve objects, so this
# changes no result): the cumulative piece lengths (CurvePath.getCurveLengths),
# each piece's own length (Curve.getLength, or the sum of its pieces for a
# nested CurvePath) and each piece's get_lengths table for getPointAt.
struct _CompositeTables
    cumulative::Vector{Float64}
    piece_lengths::Vector{Float64}
    piece_tables::Vector{Vector{Float64}}
end

function _composite_tables(c::_CompositeCurve)
    isempty(c.curves) && throw(ArgumentError("$(nameof(typeof(c))) has no curves"))
    n = length(c.curves)
    cumulative = Vector{Float64}(undef, n)
    piece_lengths = Vector{Float64}(undef, n)
    piece_tables = Vector{Vector{Float64}}(undef, n)
    sum = 0.0
    for (i, curve) in enumerate(c.curves)
        table = get_lengths(curve)
        piece_tables[i] = table
        piece_lengths[i] = curve isa _CompositeCurve ? get_length(curve) : table[end]
        sum += piece_lengths[i]
        cumulative[i] = sum
    end
    return _CompositeTables(cumulative, piece_lengths, piece_tables)
end

# Curve.getPointAt with the piece's get_lengths table already computed.
_point_at_with_table(c::Curve, u::Float64, table::Vector{Float64}) =
    get_point(c, _u_to_t_mapping(table, u, nothing))
_point_at_with_table(c::Union{LineCurve,LineCurve3}, u::Float64, ::Vector{Float64}) =
    get_point(c, u)

# CurvePath.js:90-117: the first piece whose cumulative length reaches
# t * length, at the matching arc-length fraction of that piece.
function _composite_point(c::_CompositeCurve, t::Float64, tables::_CompositeTables)
    cumulative = tables.cumulative
    d = t * cumulative[end]
    for (i, total) in enumerate(cumulative)
        if total >= d
            segment_length = tables.piece_lengths[i]
            u = segment_length == 0 ? 0.0 : 1 - (total - d) / segment_length
            return _point_at_with_table(c.curves[i], u, tables.piece_tables[i])
        end
    end
    throw(ArgumentError("$(nameof(typeof(c))) parameter must lie in [0, 1]"))
end

get_point(c::_CompositeCurve, t::Real) = _composite_point(c, _curve_t(t), _composite_tables(c))

# ---- arc length (Curve.js:144-266) ----

"""
    get_lengths(curve, divisions=200) -> Vector{Float64}

Cumulative chord lengths of `curve` sampled at `t = 0:1/divisions:1`
(three.js `Curve.getLengths`); the first entry is 0 and the last the length.
"""
function get_lengths(c::Curve, divisions::Integer=_CURVE_ARC_LENGTH_DIVISIONS)
    n = _geometry_positive_int(divisions, "get_lengths divisions")
    return _curve_chord_lengths(t -> get_point(c, t), n)
end

function get_lengths(c::_CompositeCurve, divisions::Integer=_CURVE_ARC_LENGTH_DIVISIONS)
    n = _geometry_positive_int(divisions, "get_lengths divisions")
    tables = _composite_tables(c)
    return _curve_chord_lengths(t -> _composite_point(c, t, tables), n)
end

function _curve_chord_lengths(point::F, n::Int) where {F}
    lengths = Vector{Float64}(undef, n + 1)
    lengths[1] = 0.0
    last = point(0.0)
    sum = 0.0
    for p in 1:n
        current = point(p / n)
        sum += _curve_distance(current, last)
        lengths[p + 1] = sum
        last = current
    end
    return lengths
end

# Vector{2,3}.distanceTo: sqrt of the summed squared differences.
@inline _curve_distance(a::Vec2, b::Vec2) = (dx = a.x - b.x; dy = a.y - b.y; sqrt(dx * dx + dy * dy))
@inline _curve_distance(a::Vec3, b::Vec3) =
    (dx = a.x - b.x; dy = a.y - b.y; dz = a.z - b.z; sqrt(dx * dx + dy * dy + dz * dz))

"""
    get_length(curve)

Arc length of `curve` (three.js `Curve.getLength`): the last of
[`get_lengths`](@ref), or for a [`CurvePath`](@ref) the sum of its pieces'
lengths.
"""
get_length(c::Curve) = get_lengths(c)[end]
get_length(c::_CompositeCurve) = _curve_lengths(c)[end]

"""
    get_u_to_t_mapping(curve, u, distance=nothing)

Parameter `t` at which the arc length from the start is `u` times the length
of `curve`, or `distance` when given and non-zero (three.js
`Curve.getUtoTmapping`): a binary search in [`get_lengths`](@ref) and linear
interpolation within the chord. `u` must lie in `[0, 1]` (three.js returns
`NaN` outside), and a given distance in `[0, length]`.
"""
get_u_to_t_mapping(c::Curve, u::Real, distance::Union{Nothing,Real}=nothing) =
    _u_to_t_mapping(get_lengths(c), _curve_t(u, "get_u_to_t_mapping u"), distance)

function _u_to_t_mapping(lengths::Vector{Float64}, u::Float64, distance::Union{Nothing,Real})
    il = length(lengths)
    total = lengths[il]
    target = distance === nothing || iszero(distance) ? u * total :
             _geometry_finite_float(distance, "get_u_to_t_mapping distance")
    0 <= target <= total ||
        throw(ArgumentError("get_u_to_t_mapping needs u in [0, 1] and distance in [0, length]"))
    low, high = 0, il - 1
    while low <= high
        i = low + (high - low) ÷ 2
        comparison = lengths[i + 1] - target
        if comparison < 0
            low = i + 1
        elseif comparison > 0
            high = i - 1
        else
            high = i
            break
        end
    end
    i = high
    lengths[i + 1] == target && return i / (il - 1)
    before = lengths[i + 1]
    after = lengths[i + 2]
    return (i + (target - before) / (after - before)) / (il - 1)
end

"""
    get_point_at(curve, u)

Point at arc-length fraction `u ∈ [0, 1]` (three.js `Curve.getPointAt`).
"""
get_point_at(c::Curve, u::Real) = get_point(c, get_u_to_t_mapping(c, u))
get_point_at(c::Union{LineCurve,LineCurve3}, u::Real) = get_point(c, u)

"""
    get_points(curve, divisions=5)

`divisions + 1` points at evenly spaced parameters `t` (three.js
`Curve.getPoints`). For a [`CurvePath`](@ref), [`Path`](@ref) or
[`Shape`](@ref) the default is 12 and each piece is sampled at its own
resolution (`2divisions` for ellipses, one segment for lines,
`divisions * length(points)` for splines, else `divisions`), skipping a point
equal to the previous one; with `auto_close` the first point is appended when
the path is open.
"""
function get_points(c::Curve, divisions::Integer=5)
    n = _geometry_positive_int(divisions, "get_points divisions")
    return [get_point(c, d / n) for d in 0:n]
end

_curve_resolution(::EllipseCurve, divisions::Int) = 2divisions
_curve_resolution(::Union{LineCurve,LineCurve3}, divisions::Int) = 1
_curve_resolution(c::SplineCurve, divisions::Int) = divisions * length(c.points)
_curve_resolution(::Curve, divisions::Int) = divisions

function get_points(c::_CompositeCurve, divisions::Integer=12)
    P = _curve_point_type(c)
    n = _geometry_positive_int(divisions, "get_points divisions")
    points = P[]
    for curve in c.curves
        for point in get_points(curve, _curve_resolution(curve, n))
            # CurvePath.js:197-201 skips consecutive duplicates.
            !isempty(points) && points[end] == point && continue
            push!(points, point)
        end
    end
    if c.auto_close && length(points) > 1 && points[end] != points[1]
        push!(points, points[1])
    end
    return points
end

"""
    get_spaced_points(curve, divisions=5)

`divisions + 1` points at evenly spaced arc length (three.js
`Curve.getSpacedPoints`). A [`CurvePath`](@ref) uses 40 divisions by default,
samples its own parameter (already arc length over the pieces) and appends the
first point when `auto_close` is set.
"""
function get_spaced_points(c::Curve, divisions::Integer=5)
    n = _geometry_positive_int(divisions, "get_spaced_points divisions")
    return [get_point_at(c, d / n) for d in 0:n]
end

function get_spaced_points(c::_CompositeCurve, divisions::Integer=40)
    P = _curve_point_type(c)
    n = _geometry_positive_int(divisions, "get_spaced_points divisions")
    tables = _composite_tables(c)
    points = P[_composite_point(c, i / n, tables) for i in 0:n]
    c.auto_close && push!(points, points[1])
    return points
end

# Vector.normalize divides by `length() || 1`.
@inline function _curve_normalize(v::Vec2)
    len = sqrt(v.x * v.x + v.y * v.y)
    iszero(len) && return v
    inverse = 1 / len
    return Vec2(v.x * inverse, v.y * inverse)
end
@inline function _curve_normalize(v::Vec3)
    len = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    iszero(len) && return v
    inverse = 1 / len
    return Vec3(v.x * inverse, v.y * inverse, v.z * inverse)
end

"""
    get_tangent(curve, t)

Unit tangent at parameter `t` (three.js `Curve.getTangent`): the normalized
difference of the points at `t ± 1e-4`, clamped to `[0, 1]`. Lines return
their direction.
"""
function get_tangent(c::Curve, t::Real)
    t = _curve_t(t)
    delta = 0.0001
    t1 = max(t - delta, 0.0)
    t2 = min(t + delta, 1.0)
    return _curve_normalize(get_point(c, t2) - get_point(c, t1))
end
get_tangent(c::Union{LineCurve,LineCurve3}, t::Real) = _curve_normalize(c.v2 - c.v1)

"""
    get_tangent_at(curve, u)

Unit tangent at arc-length fraction `u` (three.js `Curve.getTangentAt`).
"""
get_tangent_at(c::Curve, u::Real) = get_tangent(c, get_u_to_t_mapping(c, u))
get_tangent_at(c::Union{LineCurve,LineCurve3}, u::Real) = get_tangent(c, u)

# Matrix4.makeRotationAxis applied to a point (Matrix4.js:1040-1067).
@inline function _rotate_about_axis(p::Vec3{Float64}, axis::Vec3{Float64}, angle::Float64)
    c = cos(angle)
    s = sin(angle)
    t = 1 - c
    x, y, z = axis.x, axis.y, axis.z
    tx, ty = t * x, t * y
    m11, m12, m13 = tx * x + c, tx * y - s * z, tx * z + s * y
    m21, m22, m23 = tx * y + s * z, ty * y + c, ty * z - s * x
    m31, m32, m33 = tx * z - s * y, ty * z + s * x, t * z * z + c
    return Vec3(m11 * p.x + m12 * p.y + m13 * p.z,
                m21 * p.x + m22 * p.y + m23 * p.z,
                m31 * p.x + m32 * p.y + m33 * p.z)
end

# Vector3.crossVectors.
@inline _curve_cross(a::Vec3{Float64}, b::Vec3{Float64}) =
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
@inline _curve_dot(a::Vec3{Float64}, b::Vec3{Float64}) = a.x * b.x + a.y * b.y + a.z * b.z

"""
    compute_frenet_frames(curve::Curve{Vec3{Float64}}, segments, closed=false)

Rotation-minimizing frames at `u = i / segments` for `i = 0:segments` (three.js
`Curve.computeFrenetFrames`): tangents from [`get_tangent_at`](@ref), an
initial normal perpendicular to the tangent's smallest component, normals
carried along by the rotation between consecutive tangents, and for a closed
curve a twist spread evenly so the last frame meets the first. Returns a named
tuple `(tangents, normals, binormals)` of `Vector{Vec3{Float64}}`.
"""
function compute_frenet_frames(c::Curve{Vec3{Float64}}, segments::Integer, closed::Bool=false)
    n = _geometry_positive_int(segments, "compute_frenet_frames segments")
    tangents = [get_tangent_at(c, i / n) for i in 0:n]
    normals = Vector{Vec3{Float64}}(undef, n + 1)
    binormals = Vector{Vec3{Float64}}(undef, n + 1)
    # Curve.js:330-356: start from the axis of the tangent's smallest component.
    minimum_component = floatmax(Float64)
    t0 = tangents[1]
    normal = Vec3(0.0, 0.0, 0.0)
    abs(t0.x) <= minimum_component && (minimum_component = abs(t0.x); normal = Vec3(1.0, 0.0, 0.0))
    abs(t0.y) <= minimum_component && (minimum_component = abs(t0.y); normal = Vec3(0.0, 1.0, 0.0))
    abs(t0.z) <= minimum_component && (normal = Vec3(0.0, 0.0, 1.0))
    vec = _curve_normalize(_curve_cross(t0, normal))
    normals[1] = _curve_cross(t0, vec)
    binormals[1] = _curve_cross(t0, normals[1])
    for i in 2:(n + 1)
        normals[i] = normals[i - 1]
        vec = _curve_cross(tangents[i - 1], tangents[i])
        if sqrt(_curve_dot(vec, vec)) > eps(Float64)
            vec = _curve_normalize(vec)
            theta = acos(clamp(_curve_dot(tangents[i - 1], tangents[i]), -1.0, 1.0))
            normals[i] = _rotate_about_axis(normals[i], vec, theta)
        end
        binormals[i] = _curve_cross(tangents[i], normals[i])
    end
    if closed
        theta = acos(clamp(_curve_dot(normals[1], normals[n + 1]), -1.0, 1.0)) / n
        _curve_dot(tangents[1], _curve_cross(normals[1], normals[n + 1])) > 0 && (theta = -theta)
        for i in 2:(n + 1)
            normals[i] = _rotate_about_axis(normals[i], tangents[i], theta * (i - 1))
            binormals[i] = _curve_cross(tangents[i], normals[i])
        end
    end
    return (tangents=tangents, normals=normals, binormals=binormals)
end

# ---- composite curves and pen commands ----

# CurvePath.add. No docstring here: `add!` is the scene-graph function, whose
# documentation comes from docs.jl only while the binding has none; the
# CurvePath docstring describes this method.
function add!(c::_CompositeCurve, curve::Curve)
    curve isa Curve{_curve_point_type(c)} ||
        throw(ArgumentError("add! needs a curve of the path's dimension"))
    push!(c.curves, curve)
    return c
end

"""
    close_path!(path) -> path

Append a line from the end of the last curve to the start of the first when
they differ (three.js `CurvePath.closePath`).
"""
function close_path!(c::_CompositeCurve)
    P = _curve_point_type(c)
    isempty(c.curves) && throw(ArgumentError("close_path! needs at least one curve"))
    start_point = get_point(c.curves[1], 0.0)
    end_point = get_point(c.curves[end], 1.0)
    if start_point != end_point
        push!(c.curves, P <: Vec2 ? LineCurve(end_point, start_point) :
                                    LineCurve3(end_point, start_point))
    end
    return c
end

"""
    set_from_points!(path::Union{Path,Shape}, points) -> path

Move to `points[1]` and draw lines through the remaining points (three.js
`Path.setFromPoints`).
"""
function set_from_points!(path::_PenPath, points::AbstractVector{<:Vec2})
    isempty(points) && throw(ArgumentError("set_from_points! needs at least one point"))
    move_to!(path, points[1].x, points[1].y)
    for i in 2:length(points)
        line_to!(path, points[i].x, points[i].y)
    end
    return path
end

"""
    move_to!(path, x, y) -> path

Set the current point without drawing (three.js `Path.moveTo`).
"""
function move_to!(path::_PenPath, x::Real, y::Real)
    path.current_point = _curve_vec2(Vec2(x, y), "move_to! point")
    return path
end

"""
    line_to!(path, x, y) -> path

Append a [`LineCurve`](@ref) from the current point to `(x, y)` (three.js
`Path.lineTo`).
"""
function line_to!(path::_PenPath, x::Real, y::Real)
    target = _curve_vec2(Vec2(x, y), "line_to! point")
    push!(path.curves, LineCurve(path.current_point, target))
    path.current_point = target
    return path
end

"""
    quadratic_curve_to!(path, cpx, cpy, x, y) -> path

Append a [`QuadraticBezierCurve`](@ref) with control point `(cpx, cpy)`
ending at `(x, y)` (three.js `Path.quadraticCurveTo`).
"""
function quadratic_curve_to!(path::_PenPath, cpx::Real, cpy::Real, x::Real, y::Real)
    target = _curve_vec2(Vec2(x, y), "quadratic_curve_to! point")
    push!(path.curves, QuadraticBezierCurve(path.current_point, Vec2(cpx, cpy), target))
    path.current_point = target
    return path
end

"""
    bezier_curve_to!(path, cp1x, cp1y, cp2x, cp2y, x, y) -> path

Append a [`CubicBezierCurve`](@ref) ending at `(x, y)` (three.js
`Path.bezierCurveTo`).
"""
function bezier_curve_to!(path::_PenPath, cp1x::Real, cp1y::Real, cp2x::Real, cp2y::Real,
                          x::Real, y::Real)
    target = _curve_vec2(Vec2(x, y), "bezier_curve_to! point")
    push!(path.curves, CubicBezierCurve(path.current_point, Vec2(cp1x, cp1y), Vec2(cp2x, cp2y), target))
    path.current_point = target
    return path
end

"""
    spline_thru!(path, points) -> path

Append a [`SplineCurve`](@ref) from the current point through `points`
(three.js `Path.splineThru`).
"""
function spline_thru!(path::_PenPath, points::AbstractVector{<:Vec2})
    isempty(points) && throw(ArgumentError("spline_thru! needs at least one point"))
    curve = SplineCurve(vcat([path.current_point], [Vec2{Float64}(p.x, p.y) for p in points]))
    push!(path.curves, curve)
    path.current_point = curve.points[end]
    return path
end

"""
    absellipse!(path, ax, ay, x_radius, y_radius, start_angle, end_angle,
                clockwise=false, rotation=0) -> path

Append an [`EllipseCurve`](@ref) centred at `(ax, ay)`, first drawing a line
to its start when the path already has curves and the start differs from the
current point (three.js `Path.absellipse`).
"""
function absellipse!(path::_PenPath, ax::Real, ay::Real, x_radius::Real, y_radius::Real,
                     start_angle::Real, end_angle::Real, clockwise::Bool=false,
                     rotation::Real=0.0)
    curve = EllipseCurve(ax, ay, x_radius, y_radius, start_angle, end_angle, clockwise, rotation)
    if !isempty(path.curves)
        first_point = get_point(curve, 0.0)
        first_point == path.current_point || line_to!(path, first_point.x, first_point.y)
    end
    push!(path.curves, curve)
    path.current_point = get_point(curve, 1.0)
    return path
end

"""
    ellipse!(path, ax, ay, x_radius, y_radius, start_angle, end_angle,
             clockwise=false, rotation=0) -> path

[`absellipse!`](@ref) with the centre relative to the current point (three.js
`Path.ellipse`).
"""
ellipse!(path::_PenPath, ax::Real, ay::Real, x_radius::Real, y_radius::Real,
         start_angle::Real, end_angle::Real, clockwise::Bool=false, rotation::Real=0.0) =
    absellipse!(path, ax + path.current_point.x, ay + path.current_point.y, x_radius,
                y_radius, start_angle, end_angle, clockwise, rotation)

"""
    absarc!(path, ax, ay, radius, start_angle, end_angle, clockwise=false) -> path

Circular [`absellipse!`](@ref) (three.js `Path.absarc`).
"""
absarc!(path::_PenPath, ax::Real, ay::Real, radius::Real, start_angle::Real,
        end_angle::Real, clockwise::Bool=false) =
    absellipse!(path, ax, ay, radius, radius, start_angle, end_angle, clockwise)

"""
    arc!(path, ax, ay, radius, start_angle, end_angle, clockwise=false) -> path

[`absarc!`](@ref) with the centre relative to the current point (three.js
`Path.arc`).
"""
arc!(path::_PenPath, ax::Real, ay::Real, radius::Real, start_angle::Real,
     end_angle::Real, clockwise::Bool=false) =
    absarc!(path, ax + path.current_point.x, ay + path.current_point.y, radius,
            start_angle, end_angle, clockwise)

"""
    get_points_holes(shape::Shape, divisions=12) -> Vector{Vector{Vec2{Float64}}}

`get_points(hole, divisions)` for each hole (three.js `Shape.getPointsHoles`).
"""
get_points_holes(shape::Shape, divisions::Integer=12) =
    [get_points(hole, divisions) for hole in shape.holes]

"""
    extract_points(shape::Shape, divisions=12)

Sampled outline and holes as `(shape=points, holes=hole_points)` (three.js
`Shape.extractPoints`).
"""
extract_points(shape::Shape, divisions::Integer=12) =
    (shape=get_points(shape, divisions), holes=get_points_holes(shape, divisions))

"""
    TubeGeometry(path::Curve{Vec3{Float64}}; tubular_segments=64, radius=1,
                 radial_segments=8, closed=false)

Tube of `radius` around a 3D curve, as three.js `TubeGeometry` builds it:
`tubular_segments + 1` rings at evenly spaced arc length
([`get_point_at`](@ref)), oriented by [`compute_frenet_frames`](@ref), each
with `radial_segments + 1` vertices at angle `v = 2πj / radial_segments` in
the direction `normalize(-cos(v) N + sin(v) B)`. A closed tube reuses the
first ring's position and frame for its last ring. UVs are
`(i / tubular_segments, j / radial_segments)`.
"""
function TubeGeometry(path::Curve{Vec3{Float64}}; tubular_segments::Integer=64,
                      radius::Real=1.0, radial_segments::Integer=8, closed::Bool=false)
    ts = _geometry_positive_int(tubular_segments, "TubeGeometry tubular_segments")
    rs = _geometry_positive_int(radial_segments, "TubeGeometry radial_segments")
    r = _geometry_finite_float(radius, "TubeGeometry radius")
    frames = compute_frenet_frames(path, ts, closed)
    row = _geometry_checked_add(rs, 1, "TubeGeometry radial_segments")
    n_vertices = _geometry_checked_mul(ts + 1, row, "TubeGeometry vertex count")
    n_faces = _geometry_checked_mul(2ts, rs, "TubeGeometry face count")
    position_len, uv_len, index_len = _geometry_mesh_buffer_lengths(n_vertices, n_faces, "TubeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    # TubeGeometry.js:100-160.
    for i in 0:ts
        k = closed && i == ts ? 0 : i
        center = get_point_at(path, k / ts)
        n_frame = frames.normals[k + 1]
        b_frame = frames.binormals[k + 1]
        for j in 0:rs
            v = j / rs * π * 2
            s = sin(v)
            c = -cos(v)
            normal = _curve_normalize(Vec3(c * n_frame.x + s * b_frame.x, c * n_frame.y + s * b_frame.y,
                                           c * n_frame.z + s * b_frame.z))
            vi = i * row + j + 1
            positions[3vi - 2] = center.x + r * normal.x
            positions[3vi - 1] = center.y + r * normal.y
            positions[3vi] = center.z + r * normal.z
            normals[3vi - 2] = normal.x
            normals[3vi - 1] = normal.y
            normals[3vi] = normal.z
            uvs[2vi - 1] = i / ts
            uvs[2vi] = j / rs
        end
    end
    indices = Vector{Int}(undef, index_len)
    out = 1
    for j in 1:ts, i in 1:rs
        a = row * (j - 1) + (i - 1) + 1
        b = row * j + (i - 1) + 1
        c = row * j + i + 1
        d = row * (j - 1) + i + 1
        indices[out:out + 5] .= (a, b, d, b, c, d)
        out += 6
    end
    return BufferGeometry(positions, normals, uvs, indices, n_vertices, n_faces)
end

"""
    ShapeGeometry(shape::Shape; curve_segments=12, triangulation=:ear_clip)

Flat triangulated [`Shape`](@ref) with its holes, sampled by
[`extract_points`](@ref) with `curve_segments` divisions per curve (three.js
`ShapeGeometry(shapes, curveSegments)`), then built as
`ShapeGeometry(points; holes)`.
"""
function ShapeGeometry(shape::Shape; curve_segments::Integer=12,
                       triangulation::Symbol=:ear_clip)
    points = extract_points(shape, _geometry_positive_int(curve_segments, "ShapeGeometry curve_segments"))
    return ShapeGeometry(points.shape; holes=points.holes, triangulation=triangulation)
end

"""
    ExtrudeGeometry(shape::Shape; curve_segments=12, kwargs...)

[`ExtrudeGeometry`](@ref) of a [`Shape`](@ref) sampled by
[`extract_points`](@ref) with `curve_segments` divisions per curve (three.js
option `curveSegments`); its holes become the `holes` keyword and the other
keywords are passed on.
"""
function ExtrudeGeometry(shape::Shape; curve_segments::Integer=12, kwargs...)
    haskey(kwargs, :holes) && throw(ArgumentError("ExtrudeGeometry(::Shape) takes its holes from shape.holes"))
    points = extract_points(shape, _geometry_positive_int(curve_segments, "ExtrudeGeometry curve_segments"))
    return ExtrudeGeometry(points.shape; holes=points.holes, kwargs...)
end

"""
    ShapePath(; fill_rule=:nonzero)

A set of 2D sub-paths drawn with pen commands, typically from SVG or font
outlines (three.js `ShapePath`). [`move_to!`](@ref) starts a new sub-path
([`Path`](@ref)); [`line_to!`](@ref), [`quadratic_curve_to!`](@ref),
[`bezier_curve_to!`](@ref) and [`spline_thru!`](@ref) extend the current one.
[`to_shapes`](@ref) sorts the sub-paths into outlines and holes by `fill_rule`
(`:nonzero` or `:evenodd`, three.js `userData.style.fillRule`).
"""
mutable struct ShapePath
    sub_paths::Vector{Path}
    current_path::Union{Nothing,Path}
    fill_rule::Symbol
    function ShapePath(; fill_rule::Symbol=:nonzero)
        fill_rule in (:nonzero, :evenodd) ||
            throw(ArgumentError("ShapePath fill_rule must be :nonzero or :evenodd"))
        return new(Path[], nothing, fill_rule)
    end
end

function move_to!(sp::ShapePath, x::Real, y::Real)
    path = Path()
    push!(sp.sub_paths, path)
    sp.current_path = path
    move_to!(path, x, y)
    return sp
end

function _shape_path_current(sp::ShapePath)
    sp.current_path === nothing && throw(ArgumentError("ShapePath needs move_to! before drawing"))
    return sp.current_path
end
line_to!(sp::ShapePath, x::Real, y::Real) = (line_to!(_shape_path_current(sp), x, y); sp)
quadratic_curve_to!(sp::ShapePath, cpx::Real, cpy::Real, x::Real, y::Real) =
    (quadratic_curve_to!(_shape_path_current(sp), cpx, cpy, x, y); sp)
bezier_curve_to!(sp::ShapePath, cp1x::Real, cp1y::Real, cp2x::Real, cp2y::Real, x::Real, y::Real) =
    (bezier_curve_to!(_shape_path_current(sp), cp1x, cp1y, cp2x, cp2y, x, y); sp)
spline_thru!(sp::ShapePath, points::AbstractVector{<:Vec2}) =
    (spline_thru!(_shape_path_current(sp), points); sp)

# ShapeUtils.area: half the signed shoelace sum, positive counterclockwise.
function _curve_polygon_area(points::Vector{Vec2{Float64}})
    n = length(points)
    a = 0.0
    p = n
    for q in 1:n
        a += points[p].x * points[q].y - points[q].x * points[p].y
        p = q
    end
    return a * 0.5
end

# ShapePath.js toShapes `pointInPolygon` (crossing test).
function _curve_point_in_polygon(p::Vec2{Float64}, polygon::Vector{Vec2{Float64}})
    inside = false
    n = length(polygon)
    j = n
    for i in 1:n
        a = polygon[i]
        b = polygon[j]
        if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            inside = !inside
        end
        j = i
    end
    return inside
end

# ShapePath.js toShapes `getInteriorPoint`: the box centre, or the midpoint of
# the first two crossings of its horizontal line.
function _curve_interior_point(polygon::Vector{Vec2{Float64}}, lo::Vec2{Float64}, hi::Vec2{Float64})
    point = Vec2((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5)
    _curve_point_in_polygon(point, polygon) && return point
    y = point.y
    intercepts = Float64[]
    n = length(polygon)
    for i in 1:n
        a = polygon[i]
        b = polygon[mod1(i + 1, n)]
        if (a.y > y) != (b.y > y)
            push!(intercepts, a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
        end
    end
    if length(intercepts) > 1
        sort!(intercepts)
        point = Vec2((intercepts[1] + intercepts[2]) / 2, y)
    end
    return point
end

mutable struct _ShapePathEntry
    path::Path
    points::Vector{Vec2{Float64}}
    lo::Vec2{Float64}
    hi::Vec2{Float64}
    interior::Vec2{Float64}
    abs_area::Float64
    winding::Int
    container::Union{Nothing,_ShapePathEntry}
    exclude::Bool
    role::Symbol
end

"""
    to_shapes(shape_path::ShapePath) -> Vector{Shape}

Sort the sub-paths into [`Shape`](@ref)s with holes (three.js
`ShapePath.toShapes`). Sub-paths with fewer than three points (at 12
divisions) or zero area are dropped. Working from the largest area down, each
sub-path is nested in the smallest larger sub-path whose bounding box contains
its box and whose outline contains its interior point; the winding numbers
then decide under `fill_rule` whether it is filled. A filled sub-path inside a
hole or at the top level becomes an outline, any other filled one a hole of
its container. The shapes share the sub-paths' curves.
"""
function to_shapes(sp::ShapePath)
    inside = sp.fill_rule === :nonzero ? (w -> w != 0) : (w -> isodd(w))
    entries = _ShapePathEntry[]
    for path in sp.sub_paths
        isempty(path.curves) && continue
        points = get_points(path)
        length(points) < 3 && continue
        area = _curve_polygon_area(points)
        area == 0 && continue
        lo = Vec2(minimum(p -> p.x, points), minimum(p -> p.y, points))
        hi = Vec2(maximum(p -> p.x, points), maximum(p -> p.y, points))
        push!(entries, _ShapePathEntry(path, points, lo, hi, _curve_interior_point(points, lo, hi),
                                       abs(area), area < 0 ? -1 : 1, nothing, false, :none))
    end
    # Array.prototype.sort is stable, like sort! with a stable algorithm.
    sort!(entries; by=e -> e.abs_area, rev=true, alg=Base.Sort.DEFAULT_STABLE)
    for (i, entry) in enumerate(entries)
        container_winding = 0
        for j in (i - 1):-1:1
            candidate = entries[j]
            (candidate.lo.x <= entry.lo.x && entry.hi.x <= candidate.hi.x &&
             candidate.lo.y <= entry.lo.y && entry.hi.y <= candidate.hi.y) || continue
            _curve_point_in_polygon(entry.interior, candidate.points) || continue
            entry.container = candidate.exclude ? candidate.container : candidate
            container_winding = candidate.winding
            entry.winding += container_winding
            break
        end
        inside(entry.winding) == inside(container_winding) && (entry.exclude = true)
    end
    for entry in entries
        entry.exclude && continue
        entry.role = entry.container === nothing || entry.container.role === :hole ? :outer : :hole
    end
    shapes = Shape[]
    shape_of = IdDict{_ShapePathEntry,Shape}()
    for entry in entries
        (entry.exclude || entry.role !== :outer) && continue
        shape = Shape()
        shape.curves = entry.path.curves
        push!(shapes, shape)
        shape_of[entry] = shape
    end
    for entry in entries
        (entry.exclude || entry.role !== :hole) && continue
        shape = get(shape_of, entry.container, nothing)
        shape === nothing && continue
        hole = Path()
        hole.curves = entry.path.curves
        push!(shape.holes, hole)
    end
    return shapes
end

# ========================== CatmullRomCurve ==========================

struct CatmullRomCurve <: Curve{Vec3{Float64}}
    points::Vector{Vec3{Float64}}
    curve_type::Symbol
    closed::Bool
    tension::Float64
end

const _CATMULL_ROM_CURVE_TYPES = (:catmullrom, :centripetal, :chordal)

@inline function _catmull_rom_stable_coordinate(a, b, c, d, weights)
    return _float_representation_value(
        _float_representation_sum4(
            _float_representation_multiply(
                _float_value_representation(a),
                _float_value_representation(weights[1])),
            _float_representation_multiply(
                _float_value_representation(b),
                _float_value_representation(weights[2])),
            _float_representation_multiply(
                _float_value_representation(c),
                _float_value_representation(weights[3])),
            _float_representation_multiply(
                _float_value_representation(d),
                _float_value_representation(weights[4])),
        ))
end

function _catmull_rom_control_point(point::Vec3)
    p = Vec3(_geometry_finite_float(point.x, "CatmullRomCurve control points"),
             _geometry_finite_float(point.y, "CatmullRomCurve control points"),
             _geometry_finite_float(point.z, "CatmullRomCurve control points"))
    return p
end

function CatmullRomCurve(points::AbstractVector{<:Vec3};
                         curve_type::Symbol=:centripetal,
                         closed::Bool=false,
                         tension::Real=0.5)
    length(points) >= 2 ||
        throw(ArgumentError("CatmullRomCurve needs at least two control points"))
    curve_type in _CATMULL_ROM_CURVE_TYPES ||
        throw(ArgumentError("unsupported CatmullRomCurve curve_type: $curve_type"))
    tf = _geometry_finite_float(tension, "CatmullRomCurve tension")
    return CatmullRomCurve([_catmull_rom_control_point(p) for p in points],
                           curve_type, Bool(closed), tf)
end

function _catmull_rom_uniform(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3,
                              t::Float64, tension::Float64)
    t2 = t * t
    t3 = t2 * t
    m1 = (p2 - p0) * tension
    m2 = (p3 - p1) * tension
    result = (p1 * (2t3 - 3t2 + 1.0) +
              m1 * (t3 - 2t2 + t) +
              p2 * (-2t3 + 3t2) +
              m2 * (t3 - t2))
    has_subnormal_input =
        issubnormal(p0.x) || issubnormal(p0.y) || issubnormal(p0.z) ||
        issubnormal(p1.x) || issubnormal(p1.y) || issubnormal(p1.z) ||
        issubnormal(p2.x) || issubnormal(p2.y) || issubnormal(p2.z) ||
        issubnormal(p3.x) || issubnormal(p3.y) || issubnormal(p3.z)
    lost_finite_coordinate =
        (iszero(result.x) && !all(iszero, (p0.x, p1.x, p2.x, p3.x))) ||
        (iszero(result.y) && !all(iszero, (p0.y, p1.y, p2.y, p3.y))) ||
        (iszero(result.z) && !all(iszero, (p0.z, p1.z, p2.z, p3.z))) ||
        has_subnormal_input
    all(isfinite, (result.x, result.y, result.z)) &&
        !lost_finite_coordinate && return result

    tangent1_weight = tension * (t3 - 2t2 + t)
    tangent2_weight = tension * (t3 - t2)
    weights = (-tangent1_weight,
               2t3 - 3t2 + 1.0 - tangent2_weight,
               -2t3 + 3t2 + tangent1_weight,
               tangent2_weight)
    return Vec3(
        _catmull_rom_stable_coordinate(p0.x, p1.x, p2.x, p3.x, weights),
        _catmull_rom_stable_coordinate(p0.y, p1.y, p2.y, p3.y, weights),
        _catmull_rom_stable_coordinate(p0.z, p1.z, p2.z, p3.z, weights))
end

function _catmull_rom_param_lerp(a::Vec3, b::Vec3, t0::Float64,
                                 t1::Float64, t::Float64)
    denom = t1 - t0
    denom > 0.0 || return a
    return lerp(a, b, (t - t0) / denom)
end

function _catmull_rom_interval(a::Vec3, b::Vec3, alpha::Float64)
    return norm(b - a)^alpha
end

function _catmull_rom_normalized_intervals(
        p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3, alpha::Float64)
    pairs = ((p0, p1), (p1, p2), (p2, p3))
    log_intervals = ntuple(3) do index
        direction, logscale, nonzero =
            _difference_direction_and_logscale(pairs[index]...)
        nonzero || return (-Inf, false)
        return (alpha * (log(norm(direction)) + logscale), true)
    end
    largest = maximum(first(interval) for interval in log_intervals)
    isfinite(largest) || return (eps(Float64), eps(Float64), eps(Float64))
    return ntuple(3) do index
        log_interval, nonzero = log_intervals[index]
        nonzero || return eps(Float64)
        max(exp(log_interval - largest), eps(Float64))
    end
end

function _catmull_rom_nonuniform(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3,
                                 u::Float64, alpha::Float64)
    t0 = 0.0
    interval1 = _catmull_rom_interval(p0, p1, alpha)
    interval2 = _catmull_rom_interval(p1, p2, alpha)
    interval3 = _catmull_rom_interval(p2, p3, alpha)
    resolution_limited =
        !(isfinite(interval1) && interval1 > eps(Float64)) ||
        !(isfinite(interval2) && interval2 > eps(Float64)) ||
        !(isfinite(interval3) && interval3 > eps(Float64))
    if !resolution_limited
        direct_t1 = interval1
        direct_t2 = direct_t1 + interval2
        direct_t3 = direct_t2 + interval3
        resolution_limited =
            !(isfinite(direct_t3) && direct_t1 > t0 &&
              direct_t2 > direct_t1 && direct_t3 > direct_t2)
    end
    if resolution_limited
        interval1, interval2, interval3 =
            _catmull_rom_normalized_intervals(p0, p1, p2, p3, alpha)
    end
    t1 = interval1
    t2 = t1 + interval2
    t3 = t2 + interval3
    t = t1 + u * (t2 - t1)

    a1 = _catmull_rom_param_lerp(p0, p1, t0, t1, t)
    a2 = _catmull_rom_param_lerp(p1, p2, t1, t2, t)
    a3 = _catmull_rom_param_lerp(p2, p3, t2, t3, t)
    b1 = _catmull_rom_param_lerp(a1, a2, t0, t2, t)
    b2 = _catmull_rom_param_lerp(a2, a3, t1, t3, t)
    return _catmull_rom_param_lerp(b1, b2, t1, t2, t)
end

function _catmull_rom_segment(curve::CatmullRomCurve, t::Real)
    # Keep finite out-of-range samples clamped to endpoints, but reject NaN/Inf
    # and Bool explicitly instead of silently mapping them to endpoint samples.
    tf = Float64(_geometry_finite_scalar(t, "catmull_rom_point t"))
    n = length(curve.points)
    segments = curve.closed ? n : n - 1
    tf = clamp(tf, 0.0, 1.0)
    scaled = tf * segments
    if scaled >= segments
        return segments, 1.0
    end
    index = floor(Int, scaled) + 1
    return index, scaled - (index - 1)
end

@inline function _catmull_rom_evaluate(curve::CatmullRomCurve, p0::Vec3, p1::Vec3,
                                       p2::Vec3, p3::Vec3, local_t::Float64)
    curve.curve_type === :catmullrom &&
        return _catmull_rom_uniform(p0, p1, p2, p3, local_t, curve.tension)
    alpha = curve.curve_type === :centripetal ? 0.5 : 1.0
    result = _catmull_rom_nonuniform(p0, p1, p2, p3, local_t, alpha)
    _catmull_rom_finite(result) && return result
    # Differences of control points near floatmax overflow although the curve
    # between them is finite. The centripetal and chordal parameterizations
    # are invariant under uniform scaling, and scaling by a power of two is
    # exact, so evaluate a quarter-size copy and scale the result back.
    q = 0.25
    return _catmull_rom_nonuniform(p0 * q, p1 * q, p2 * q, p3 * q, local_t, alpha) * 4.0
end

# three.js CatmullRomCurve3.getPoint extrapolates the missing neighbour of an
# open curve's first or last segment by reflecting the adjacent point:
# `tmp.subVectors(points[0], points[1]).add(points[0])`.
@inline _catmull_rom_phantom(endpoint::Vec3, neighbour::Vec3) =
    (endpoint - neighbour) + endpoint

@inline _catmull_rom_finite(p::Vec3) = isfinite(p.x) && isfinite(p.y) && isfinite(p.z)

# Compensated dot product (Ogita, Rump & Oishi "Dot2"): the result is as
# accurate as a twice-working-precision evaluation rounded once.
@inline function _catmull_rom_dot2(w::NTuple{4,Float64}, x::NTuple{4,Float64})
    p = w[1] * x[1]
    s = fma(w[1], x[1], -p)
    for k in 2:4
        h = w[k] * x[k]
        r = fma(w[k], x[k], -h)
        sum = p + h
        z = sum - p
        q = (p - (sum - z)) + (h - z)
        p = sum
        s += q + r
    end
    return p + s
end

# Reflected neighbours that overflow Float64. The uniform (three.js
# `initCatmullRom`) cubic is linear in its points, so substitute the
# reflections p0 = 2p1 - p2 and p3 = 2p2 - p1 into the point weights and sum
# the quarter-scaled points (power-of-two scaling is exact) with Dot2.
function _catmull_rom_reflected_uniform(before, p1::Vec3, p2::Vec3, after,
                                        t::Float64, tension::Float64)
    t2 = t * t
    t3 = t2 * t
    w0 = -tension * (t3 - 2t2 + t)
    w3 = tension * (t3 - t2)
    w1 = 2t3 - 3t2 + 1.0 - w3
    w2 = -2t3 + 3t2 - w0
    if before === nothing
        w1 += 2w0
        w2 -= w0
        w0 = 0.0
    end
    if after === nothing
        w1 -= w3
        w2 += 2w3
        w3 = 0.0
    end
    weights = (w0, w1, w2, w3)
    a = (before === nothing ? p1 : before) * 0.25
    b = p1 * 0.25
    c = p2 * 0.25
    d = (after === nothing ? p2 : after) * 0.25
    return Vec3(_catmull_rom_dot2(weights, (a.x, b.x, c.x, d.x)),
                _catmull_rom_dot2(weights, (a.y, b.y, c.y, d.y)),
                _catmull_rom_dot2(weights, (a.z, b.z, c.z, d.z))) * 4.0
end

function _catmull_rom_open_end_segment(curve::CatmullRomCurve, before, p1::Vec3,
                                       p2::Vec3, after, local_t::Float64)
    p0 = before === nothing ? _catmull_rom_phantom(p1, p2) : before
    p3 = after === nothing ? _catmull_rom_phantom(p2, p1) : after
    _catmull_rom_finite(p0) && _catmull_rom_finite(p3) &&
        return _catmull_rom_evaluate(curve, p0, p1, p2, p3, local_t)
    # A reflected point can overflow although the curve itself stays finite.
    curve.curve_type === :catmullrom &&
        return _catmull_rom_reflected_uniform(
            before, p1, p2, after, local_t, curve.tension)
    # The centripetal and chordal parameterizations are invariant under
    # uniform scaling, and scaling by a power of two is exact, so evaluate a
    # quarter-size copy (whose reflected points are bounded by 3/4 of
    # floatmax) and scale the result back.
    q = 0.25
    s1 = p1 * q
    s2 = p2 * q
    s0 = before === nothing ? _catmull_rom_phantom(s1, s2) : before * q
    s3 = after === nothing ? _catmull_rom_phantom(s2, s1) : after * q
    return _catmull_rom_evaluate(curve, s0, s1, s2, s3, local_t) * 4.0
end

function catmull_rom_point(curve::CatmullRomCurve, t::Real)
    points = curve.points
    n = length(points)
    segment, local_t = _catmull_rom_segment(curve, t)
    if curve.closed
        p0 = points[mod1(segment - 1, n)]
        p1 = points[mod1(segment, n)]
        p2 = points[mod1(segment + 1, n)]
        p3 = points[mod1(segment + 2, n)]
        return _catmull_rom_evaluate(curve, p0, p1, p2, p3, local_t)
    end
    p1 = points[segment]
    p2 = points[segment + 1]
    if segment > 1 && segment + 2 <= n
        return _catmull_rom_evaluate(curve, points[segment - 1], p1, p2,
                                     points[segment + 2], local_t)
    end
    before = segment > 1 ? points[segment - 1] : nothing
    after = segment + 2 <= n ? points[segment + 2] : nothing
    return _catmull_rom_open_end_segment(curve, before, p1, p2, after, local_t)
end

# Curve interface: CatmullRomCurve3.getPoint.
get_point(c::CatmullRomCurve, t::Real) = catmull_rom_point(c, t)

function catmull_rom_points(curve::CatmullRomCurve; segments::Integer=200)
    segs = _geometry_positive_int(segments, "catmull_rom_points segments")
    pts = Vector{Vec3{Float64}}(undef, segs + 1)
    for i in 0:segs
        pts[i + 1] = catmull_rom_point(curve, i / segs)
    end
    return pts
end

function CatmullRomCurveGeometry(curve::CatmullRomCurve; segments::Integer=200)
    segs = _geometry_positive_int(
        segments, "CatmullRomCurveGeometry segments")
    n_vertices = segs + 1
    position_len, _, _ =
        _geometry_mesh_buffer_lengths(n_vertices, 0, "CatmullRomCurveGeometry")
    positions = Vector{Float64}(undef, position_len)
    for i in 0:segs
        p = catmull_rom_point(curve, i / segs)
        base = 3i + 1
        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[], n_vertices, 0)
end

# ========================== NURBS / Parametric Geometry ==========================

struct NURBSCurve
    degree::Int
    knots::Vector{Float64}
    control_points::Vector{Vec4{Float64}}

    # Inner constructor so validation can't be bypassed: the auto-generated
    # field constructor would otherwise shadow the validating one for exact
    # (Int, Vector{Float64}, Vector{Vec4{Float64}}) arguments.
    function NURBSCurve(degree::Integer, knots, control_points::AbstractVector{<:Vec4})
        p = _nurbs_degree(degree)
        cps = [_nurbs_control_point(cp) for cp in control_points]
        return new(p, _nurbs_knots(knots, p, length(cps), "NURBSCurve"), cps)
    end
end

struct NURBSSurface
    degree_u::Int
    degree_v::Int
    knots_u::Vector{Float64}
    knots_v::Vector{Float64}
    control_points::Vector{Vector{Vec4{Float64}}}

    function NURBSSurface(degree_u::Integer, degree_v::Integer,
                          knots_u, knots_v, control_points)
        p = _nurbs_degree(degree_u)
        q = _nurbs_degree(degree_v)
        cps = _nurbs_surface_points(control_points)
        ku = _nurbs_knots(
            knots_u, p, length(cps), "NURBSSurface u")
        kv = _nurbs_knots(
            knots_v, q, length(cps[1]), "NURBSSurface v")
        return new(p, q, ku, kv, cps)
    end
end

struct NURBSVolume
    degree_u::Int
    degree_v::Int
    degree_w::Int
    knots_u::Vector{Float64}
    knots_v::Vector{Float64}
    knots_w::Vector{Float64}
    control_points::Vector{Vector{Vector{Vec4{Float64}}}}

    function NURBSVolume(degree_u::Integer, degree_v::Integer,
                         degree_w::Integer, knots_u, knots_v, knots_w,
                         control_points)
        p = _nurbs_degree(degree_u)
        q = _nurbs_degree(degree_v)
        r = _nurbs_degree(degree_w)
        cps = _nurbs_volume_points(control_points)
        ku = _nurbs_knots(
            knots_u, p, length(cps), "NURBSVolume u")
        kv = _nurbs_knots(
            knots_v, q, length(cps[1]), "NURBSVolume v")
        kw = _nurbs_knots(
            knots_w, r, length(cps[1][1]), "NURBSVolume w")
        return new(p, q, r, ku, kv, kw, cps)
    end
end

function _nurbs_degree(degree::Integer)
    return _geometry_positive_int(degree, "NURBS degree")
end
_nurbs_degree(degree) = throw(ArgumentError("NURBS degree must be an integer"))

function _nurbs_knots(knots, degree::Int, npoints::Int, label::String)
    npoints >= degree + 1 ||
        throw(ArgumentError("$label needs at least degree + 1 control points"))
    length(knots) == npoints + degree + 1 ||
        throw(ArgumentError("$label knot count must equal control point count + degree + 1"))
    out = Float64[Float64(k) for k in knots]
    all(isfinite, out) || throw(ArgumentError("$label knots must be finite"))
    for i in 2:length(out)
        out[i] >= out[i - 1] ||
            throw(ArgumentError("$label knots must be nondecreasing"))
    end
    out[degree + 1] < out[npoints + 1] ||
        throw(ArgumentError("$label knot domain has zero length"))
    return out
end

function _nurbs_control_point(point::Vec4)
    x = _geometry_finite_float(point.x, "NURBS control points")
    y = _geometry_finite_float(point.y, "NURBS control points")
    z = _geometry_finite_float(point.z, "NURBS control points")
    w = _geometry_finite_float(point.w, "NURBS control points")
    w > 0.0 || throw(ArgumentError("NURBS control point weights must be positive"))
    return Vec4(x, y, z, w)
end

function _nurbs_surface_points(control_points)
    rows = length(control_points)
    rows > 0 || throw(ArgumentError("NURBSSurface needs control points"))
    cols = length(control_points[1])
    cols > 0 || throw(ArgumentError("NURBSSurface needs control points"))
    out = Vector{Vec4{Float64}}[]
    for row in control_points
        length(row) == cols ||
            throw(ArgumentError("NURBSSurface control point rows must be rectangular"))
        push!(out, [_nurbs_control_point(cp) for cp in row])
    end
    return out
end

function _nurbs_volume_points(control_points)
    nu = length(control_points)
    nu > 0 || throw(ArgumentError("NURBSVolume needs control points"))
    nv = length(control_points[1])
    nv > 0 || throw(ArgumentError("NURBSVolume needs control points"))
    nw = length(control_points[1][1])
    nw > 0 || throw(ArgumentError("NURBSVolume needs control points"))
    out = Vector{Vector{Vec4{Float64}}}[]
    for slab in control_points
        length(slab) == nv ||
            throw(ArgumentError("NURBSVolume control point slabs must be rectangular"))
        out_slab = Vector{Vec4{Float64}}[]
        for row in slab
            length(row) == nw ||
                throw(ArgumentError("NURBSVolume control point rows must be rectangular"))
            push!(out_slab, [_nurbs_control_point(cp) for cp in row])
        end
        push!(out, out_slab)
    end
    return out
end

function _nurbs_span(degree::Int, knots::Vector{Float64}, npoints::Int, u::Float64)
    if u >= knots[npoints + 1]
        return npoints - 1
    elseif u <= knots[degree + 1]
        return degree
    end
    low = degree
    high = npoints
    mid = (low + high) ÷ 2
    while u < knots[mid + 1] || u >= knots[mid + 2]
        if u < knots[mid + 1]
            high = mid
        else
            low = mid
        end
        mid = (low + high) ÷ 2
    end
    return mid
end

function _nurbs_basis_scratch(degree::Int)
    degree >= 0 || throw(ArgumentError("NURBS degree must be non-negative"))
    n = _geometry_checked_add(degree, 1, "NURBS basis size")
    len = _geometry_checked_mul(3, n, "NURBS basis size")
    len <= _GEOMETRY_MAX_BUFFER_ELEMENTS ||
        throw(ArgumentError(
            "NURBS basis exceeds the " *
            "$_GEOMETRY_MAX_BUFFER_ELEMENTS-element safety limit"))
    return Vector{Float64}(undef, len)
end

function _nurbs_basis_fractions(left::Float64, right::Float64,
                                u::Float64, low::Float64,
                                high::Float64)
    denominator = left + right
    if isfinite(left) && isfinite(right) && isfinite(denominator) &&
       !iszero(denominator)
        return right / denominator, left / denominator
    end
    low == high && return (0.0, 0.0)
    return setprecision(BigFloat, 256) do
        ub = BigFloat(u)
        lowb = BigFloat(low)
        highb = BigFloat(high)
        denominator_b = highb - lowb
        (Float64((highb - ub) / denominator_b),
         Float64((ub - lowb) / denominator_b))
    end
end

function _nurbs_basis_with_status!(scratch::Vector{Float64}, span::Int,
                                   u::Float64, degree::Int,
                                   knots::Vector{Float64})
    n = degree + 1
    length(scratch) >= 3n || resize!(scratch, 3n)
    left0 = n
    right0 = 2n
    scratch[1] = 1.0
    needs_precise = false
    for j in 1:degree
        scratch[left0 + j + 1] = u - knots[span - j + 2]
        scratch[right0 + j + 1] = knots[span + j + 1] - u
        saved = 0.0
        for r in 0:(j - 1)
            left = scratch[left0 + j - r + 1]
            right = scratch[right0 + r + 2]
            low = knots[span - j + r + 2]
            high = knots[span + r + 2]
            right_fraction, left_fraction = _nurbs_basis_fractions(
                left, right, u, low, high)
            if low != high
                needs_precise |=
                    (!iszero(right) && iszero(right_fraction)) ||
                    (!iszero(left) && iszero(left_fraction))
            end
            basis = scratch[r + 1]
            right_product = basis * right_fraction
            left_product = basis * left_fraction
            needs_precise |=
                (!iszero(basis) && !iszero(right_fraction) &&
                 iszero(right_product)) ||
                (!iszero(basis) && !iszero(left_fraction) &&
                 iszero(left_product))
            scratch[r + 1] = saved + right_product
            saved = left_product
        end
        scratch[j + 1] = saved
    end
    return scratch, needs_precise
end

function _nurbs_basis!(scratch::Vector{Float64}, span::Int, u::Float64,
                       degree::Int, knots::Vector{Float64})
    basis, _ = _nurbs_basis_with_status!(
        scratch, span, u, degree, knots)
    return basis
end

function _nurbs_basis(span::Int, u::Float64, degree::Int, knots::Vector{Float64})
    scratch = _nurbs_basis_scratch(degree)
    _nurbs_basis!(scratch, span, u, degree, knots)
    return scratch[1:(degree + 1)]
end

function _nurbs_parameter(t, knots::Vector{Float64}, degree::Int, npoints::Int,
                          label::String)
    tf = _geometry_finite_scalar(t, label)
    tf = clamp(Float64(tf), 0.0, 1.0)
    u0 = knots[degree + 1]
    u1 = knots[npoints + 1]
    return _stable_lerp(u0, u1, tf)
end

function _nurbs_finish_point(x::Float64, y::Float64, z::Float64, w::Float64)
    !iszero(w) ||
        throw(ArgumentError("NURBS evaluation produced zero homogeneous weight"))
    return Vec3(x / w, y / w, z / w)
end

@inline function _nurbs_weighted_point(
        point::Vec3{Float64}, total_weight::Float64,
        control_point::Vec4{Float64}, weight::Float64)
    next_weight = total_weight + weight
    next_point = iszero(total_weight) ?
        Vec3(control_point.x, control_point.y, control_point.z) :
        lerp(
            point,
            Vec3(control_point.x, control_point.y, control_point.z),
            weight / next_weight,
        )
    return next_point, next_weight
end

@inline function _nurbs_finish_weighted_point(
        point::Vec3{Float64}, total_weight::Float64)
    !iszero(total_weight) ||
        throw(ArgumentError(
            "NURBS evaluation produced zero homogeneous weight"))
    return point
end

@inline _nurbs_product_underflow(a::Float64, b::Float64,
                                 product::Float64) =
    !iszero(a) && !iszero(b) && iszero(product)

@inline function _nurbs_finish_precise_point(x::BigFloat, y::BigFloat,
                                             z::BigFloat, weight::BigFloat)
    !iszero(weight) ||
        throw(ArgumentError(
            "NURBS evaluation produced zero homogeneous weight"))
    return Vec3(Float64(x / weight), Float64(y / weight),
                Float64(z / weight))
end

function _nurbs_precise_basis(span::Int, u::Float64, degree::Int,
                              knots::Vector{Float64})
    n = degree + 1
    basis = zeros(BigFloat, n)
    left = zeros(BigFloat, n)
    right = zeros(BigFloat, n)
    basis[1] = one(BigFloat)
    u_big = BigFloat(u)
    for j in 1:degree
        left[j + 1] = u_big - BigFloat(knots[span - j + 2])
        right[j + 1] = BigFloat(knots[span + j + 1]) - u_big
        saved = zero(BigFloat)
        for r in 0:(j - 1)
            denominator = right[r + 2] + left[j - r + 1]
            if iszero(denominator)
                basis[r + 1] = saved
                saved = zero(BigFloat)
                continue
            end
            temporary = basis[r + 1] / denominator
            basis[r + 1] = saved + right[r + 2] * temporary
            saved = left[j - r + 1] * temporary
        end
        basis[j + 1] = saved
    end
    return basis
end

@noinline function _nurbs_precise_point(
        curve::NURBSCurve, span::Int, u::Float64)
    return setprecision(BigFloat, 512) do
        basis = _nurbs_precise_basis(
            span, u, curve.degree, curve.knots)
        x = zero(BigFloat)
        y = zero(BigFloat)
        z = zero(BigFloat)
        weight = zero(BigFloat)
        for j in 0:curve.degree
            cp = curve.control_points[span - curve.degree + j + 1]
            coefficient = BigFloat(basis[j + 1]) * BigFloat(cp.w)
            x += BigFloat(cp.x) * coefficient
            y += BigFloat(cp.y) * coefficient
            z += BigFloat(cp.z) * coefficient
            weight += coefficient
        end
        _nurbs_finish_precise_point(x, y, z, weight)
    end
end

@noinline function _nurbs_precise_point(
        surface::NURBSSurface, span_u::Int, span_v::Int,
        u::Float64, v::Float64)
    return setprecision(BigFloat, 512) do
        basis_u = _nurbs_precise_basis(
            span_u, u, surface.degree_u, surface.knots_u)
        basis_v = _nurbs_precise_basis(
            span_v, v, surface.degree_v, surface.knots_v)
        x = zero(BigFloat)
        y = zero(BigFloat)
        z = zero(BigFloat)
        weight = zero(BigFloat)
        for i in 0:surface.degree_u, j in 0:surface.degree_v
            cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
            coefficient = BigFloat(basis_u[i + 1]) *
                          BigFloat(basis_v[j + 1]) * BigFloat(cp.w)
            x += BigFloat(cp.x) * coefficient
            y += BigFloat(cp.y) * coefficient
            z += BigFloat(cp.z) * coefficient
            weight += coefficient
        end
        _nurbs_finish_precise_point(x, y, z, weight)
    end
end

@noinline function _nurbs_precise_point(
        volume::NURBSVolume, span_u::Int, span_v::Int, span_w::Int,
        u::Float64, v::Float64, w::Float64)
    return setprecision(BigFloat, 512) do
        basis_u = _nurbs_precise_basis(
            span_u, u, volume.degree_u, volume.knots_u)
        basis_v = _nurbs_precise_basis(
            span_v, v, volume.degree_v, volume.knots_v)
        basis_w = _nurbs_precise_basis(
            span_w, w, volume.degree_w, volume.knots_w)
        x = zero(BigFloat)
        y = zero(BigFloat)
        z = zero(BigFloat)
        weight = zero(BigFloat)
        for i in 0:volume.degree_u, j in 0:volume.degree_v,
            k in 0:volume.degree_w
            cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
            coefficient = BigFloat(basis_u[i + 1]) *
                          BigFloat(basis_v[j + 1]) *
                          BigFloat(basis_w[k + 1]) * BigFloat(cp.w)
            x += BigFloat(cp.x) * coefficient
            y += BigFloat(cp.y) * coefficient
            z += BigFloat(cp.z) * coefficient
            weight += coefficient
        end
        _nurbs_finish_precise_point(x, y, z, weight)
    end
end

function _nurbs_point(curve::NURBSCurve, t::Real, basis::Vector{Float64})
    npoints = length(curve.control_points)
    u = _nurbs_parameter(t, curve.knots, curve.degree, npoints,
                         "NURBS curve parameter t")
    span = _nurbs_span(curve.degree, curve.knots, npoints, u)
    _, basis_needs_precise = _nurbs_basis_with_status!(
        basis, span, u, curve.degree, curve.knots)
    weight_scale = 0.0
    for j in 0:curve.degree
        cp = curve.control_points[span - curve.degree + j + 1]
        weight_scale = max(weight_scale, cp.w)
    end
    x = 0.0
    y = 0.0
    z = 0.0
    weight = 0.0
    needs_precise = basis_needs_precise
    for j in 0:curve.degree
        cp = curve.control_points[span - curve.degree + j + 1]
        basis_factor = basis[j + 1]
        scaled_weight = cp.w / weight_scale
        coeff = basis_factor * scaled_weight
        x_term = cp.x * coeff
        y_term = cp.y * coeff
        z_term = cp.z * coeff
        needs_precise |= !iszero(basis_factor) && iszero(scaled_weight)
        needs_precise |= _nurbs_product_underflow(
            basis_factor, scaled_weight, coeff)
        needs_precise |= _nurbs_product_underflow(cp.x, coeff, x_term) ||
                         _nurbs_product_underflow(cp.y, coeff, y_term) ||
                         _nurbs_product_underflow(cp.z, coeff, z_term)
        x += x_term
        y += y_term
        z += z_term
        weight += coeff
    end
    needs_precise && return _nurbs_precise_point(curve, span, u)
    if isfinite(x) && isfinite(y) && isfinite(z) &&
       isfinite(weight)
        return _nurbs_finish_point(x, y, z, weight)
    end

    point = Vec3(0.0, 0.0, 0.0)
    total_weight = 0.0
    for j in 0:curve.degree
        cp = curve.control_points[span - curve.degree + j + 1]
        coeff = basis[j + 1] * (cp.w / weight_scale)
        point, total_weight =
            _nurbs_weighted_point(
                point, total_weight, cp, coeff)
    end
    return _nurbs_finish_weighted_point(point, total_weight)
end

function nurbs_point(curve::NURBSCurve, t::Real)
    return _nurbs_point(curve, t, _nurbs_basis_scratch(curve.degree))
end

function _nurbs_point(surface::NURBSSurface, u::Real, v::Real,
                      basis_u::Vector{Float64}, basis_v::Vector{Float64})
    nu = length(surface.control_points)
    nv = length(surface.control_points[1])
    uu = _nurbs_parameter(u, surface.knots_u, surface.degree_u, nu,
                          "NURBS surface parameter u")
    vv = _nurbs_parameter(v, surface.knots_v, surface.degree_v, nv,
                          "NURBS surface parameter v")
    span_u = _nurbs_span(surface.degree_u, surface.knots_u, nu, uu)
    span_v = _nurbs_span(surface.degree_v, surface.knots_v, nv, vv)
    _, basis_u_needs_precise = _nurbs_basis_with_status!(
        basis_u, span_u, uu, surface.degree_u, surface.knots_u)
    _, basis_v_needs_precise = _nurbs_basis_with_status!(
        basis_v, span_v, vv, surface.degree_v, surface.knots_v)
    weight_scale = 0.0
    for i in 0:surface.degree_u, j in 0:surface.degree_v
        cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
        weight_scale = max(weight_scale, cp.w)
    end
    x = 0.0
    y = 0.0
    z = 0.0
    weight = 0.0
    needs_precise = basis_u_needs_precise || basis_v_needs_precise
    for i in 0:surface.degree_u, j in 0:surface.degree_v
        cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
        basis_u_value = basis_u[i + 1]
        basis_v_value = basis_v[j + 1]
        basis_factor = basis_u_value * basis_v_value
        basis_active = !iszero(basis_u_value) && !iszero(basis_v_value)
        scaled_weight = cp.w / weight_scale
        coeff = basis_factor * scaled_weight
        x_term = cp.x * coeff
        y_term = cp.y * coeff
        z_term = cp.z * coeff
        needs_precise |= basis_active &&
                         (iszero(basis_factor) || iszero(scaled_weight))
        needs_precise |= _nurbs_product_underflow(
            basis_factor, scaled_weight, coeff)
        needs_precise |= _nurbs_product_underflow(cp.x, coeff, x_term) ||
                         _nurbs_product_underflow(cp.y, coeff, y_term) ||
                         _nurbs_product_underflow(cp.z, coeff, z_term)
        x += x_term
        y += y_term
        z += z_term
        weight += coeff
    end
    needs_precise && return _nurbs_precise_point(
        surface, span_u, span_v, uu, vv)
    if isfinite(x) && isfinite(y) && isfinite(z) &&
       isfinite(weight)
        return _nurbs_finish_point(x, y, z, weight)
    end

    point = Vec3(0.0, 0.0, 0.0)
    total_weight = 0.0
    for i in 0:surface.degree_u, j in 0:surface.degree_v
        cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] *
                (cp.w / weight_scale)
        point, total_weight =
            _nurbs_weighted_point(
                point, total_weight, cp, coeff)
    end
    return _nurbs_finish_weighted_point(point, total_weight)
end

function nurbs_point(surface::NURBSSurface, u::Real, v::Real)
    return _nurbs_point(surface, u, v, _nurbs_basis_scratch(surface.degree_u),
                        _nurbs_basis_scratch(surface.degree_v))
end

function _nurbs_point(volume::NURBSVolume, u::Real, v::Real, wparam::Real,
                      basis_u::Vector{Float64}, basis_v::Vector{Float64},
                      basis_w::Vector{Float64})
    nu = length(volume.control_points)
    nv = length(volume.control_points[1])
    nw = length(volume.control_points[1][1])
    uu = _nurbs_parameter(u, volume.knots_u, volume.degree_u, nu,
                          "NURBS volume parameter u")
    vv = _nurbs_parameter(v, volume.knots_v, volume.degree_v, nv,
                          "NURBS volume parameter v")
    ww = _nurbs_parameter(wparam, volume.knots_w, volume.degree_w, nw,
                          "NURBS volume parameter w")
    span_u = _nurbs_span(volume.degree_u, volume.knots_u, nu, uu)
    span_v = _nurbs_span(volume.degree_v, volume.knots_v, nv, vv)
    span_w = _nurbs_span(volume.degree_w, volume.knots_w, nw, ww)
    _, basis_u_needs_precise = _nurbs_basis_with_status!(
        basis_u, span_u, uu, volume.degree_u, volume.knots_u)
    _, basis_v_needs_precise = _nurbs_basis_with_status!(
        basis_v, span_v, vv, volume.degree_v, volume.knots_v)
    _, basis_w_needs_precise = _nurbs_basis_with_status!(
        basis_w, span_w, ww, volume.degree_w, volume.knots_w)
    weight_scale = 0.0
    for i in 0:volume.degree_u, j in 0:volume.degree_v,
        k in 0:volume.degree_w
        cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
        weight_scale = max(weight_scale, cp.w)
    end
    x = 0.0
    y = 0.0
    z = 0.0
    weight = 0.0
    needs_precise = basis_u_needs_precise ||
                    basis_v_needs_precise ||
                    basis_w_needs_precise
    for i in 0:volume.degree_u, j in 0:volume.degree_v, k in 0:volume.degree_w
        cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
        basis_u_value = basis_u[i + 1]
        basis_v_value = basis_v[j + 1]
        basis_w_value = basis_w[k + 1]
        basis_uv = basis_u_value * basis_v_value
        basis_factor = basis_uv * basis_w_value
        basis_active = !iszero(basis_u_value) &&
                       !iszero(basis_v_value) &&
                       !iszero(basis_w_value)
        scaled_weight = cp.w / weight_scale
        coeff = basis_factor * scaled_weight
        x_term = cp.x * coeff
        y_term = cp.y * coeff
        z_term = cp.z * coeff
        needs_precise |= basis_active &&
                         (iszero(basis_uv) || iszero(basis_factor) ||
                          iszero(scaled_weight))
        needs_precise |= _nurbs_product_underflow(
            basis_factor, scaled_weight, coeff)
        needs_precise |= _nurbs_product_underflow(cp.x, coeff, x_term) ||
                         _nurbs_product_underflow(cp.y, coeff, y_term) ||
                         _nurbs_product_underflow(cp.z, coeff, z_term)
        x += x_term
        y += y_term
        z += z_term
        weight += coeff
    end
    needs_precise && return _nurbs_precise_point(
        volume, span_u, span_v, span_w, uu, vv, ww)
    if isfinite(x) && isfinite(y) && isfinite(z) &&
       isfinite(weight)
        return _nurbs_finish_point(x, y, z, weight)
    end

    point = Vec3(0.0, 0.0, 0.0)
    total_weight = 0.0
    for i in 0:volume.degree_u, j in 0:volume.degree_v, k in 0:volume.degree_w
        cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * basis_w[k + 1] *
                (cp.w / weight_scale)
        point, total_weight =
            _nurbs_weighted_point(
                point, total_weight, cp, coeff)
    end
    return _nurbs_finish_weighted_point(point, total_weight)
end

function nurbs_point(volume::NURBSVolume, u::Real, v::Real, wparam::Real)
    return _nurbs_point(volume, u, v, wparam, _nurbs_basis_scratch(volume.degree_u),
                        _nurbs_basis_scratch(volume.degree_v),
                        _nurbs_basis_scratch(volume.degree_w))
end

function NURBSCurveGeometry(curve::NURBSCurve; segments::Integer=200)
    segs = _geometry_positive_int(segments, "NURBSCurveGeometry segments")
    n_vertices = segs + 1
    position_len, _, _ =
        _geometry_mesh_buffer_lengths(n_vertices, 0, "NURBSCurveGeometry")
    positions = Vector{Float64}(undef, position_len)
    basis = _nurbs_basis_scratch(curve.degree)
    for i in 0:segs
        p = _nurbs_point(curve, i / segs, basis)
        base = 3i + 1
        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[], n_vertices, 0)
end

# `nonfinite` is the error label, built once per geometry so that sampling
# does not allocate; Bool, non-real and unrepresentable coordinates are
# rejected like non-finite ones.
function _parametric_point(fn::F, u::Float64, v::Float64, label::String,
                           nonfinite::String) where {F}
    p = fn(u, v)
    p isa Vec3 || throw(ArgumentError(string(label, " callback must return Vec3")))
    return Vec3(_geometry_finite_float(p.x, nonfinite), _geometry_finite_float(p.y, nonfinite),
                _geometry_finite_float(p.z, nonfinite))
end

# ParametricGeometry.js:64-118: positions, finite-difference normals and UVs
# on a (slices + 1) x (stacks + 1) grid, then the (a, b, d), (b, c, d) faces.
function _parametric_geometry(fn::F, slices, stacks, label::String) where {F}
    us = _geometry_positive_int(slices, string(label, " slices"))
    vs = _geometry_positive_int(stacks, string(label, " stacks"))
    row = us + 1
    nvertices = _geometry_checked_mul(row, vs + 1, string(label, " vertex count"))
    nfaces = _geometry_checked_mul(2 * us, vs, string(label, " face count"))
    position_len, uv_len, index_len = _geometry_mesh_buffer_lengths(nvertices, nfaces, label)
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    eps = 0.00001
    nonfinite = string(label, " callback returned a non-finite point")
    for i in 0:vs, j in 0:us
        v = i / vs
        u = j / us
        p0 = _parametric_point(fn, u, v, label, nonfinite)
        # ParametricGeometry.js:85-111: one-sided differences, backward where
        # u - EPS >= 0 and forward otherwise (likewise for v), then
        # cross(pu, pv).normalize().
        backward_u = u - eps >= 0
        backward_v = v - eps >= 0
        p1u = _parametric_point(fn, backward_u ? u - eps : u + eps, v, label, nonfinite)
        p1v = _parametric_point(fn, u, backward_v ? v - eps : v + eps, label, nonfinite)
        pu = backward_u ? p0 - p1u : p1u - p0
        pv = backward_v ? p0 - p1v : p1v - p0
        cx = pu.y * pv.z - pu.z * pv.y
        cy = pu.z * pv.x - pu.x * pv.z
        cz = pu.x * pv.y - pu.y * pv.x
        length_squared = cx * cx + cy * cy + cz * cz
        if isfinite(length_squared) && length_squared >= floatmin(Float64)
            inverse = 1 / sqrt(length_squared)
            n = Vec3(cx * inverse, cy * inverse, cz * inverse)
        else
            # The differences or their cross product overflow or underflow
            # (three.js would give NaN or a zero normal there): form the same
            # cross product of (p1u - p0, p1v - p0) with rescaling, flipping
            # it once for each backward difference.
            n = triangle_normal(Triangle(p0, p1u, p1v))
            backward_u == backward_v || (n = -n)
        end
        vi = i * row + j + 1
        pbase = 3vi - 2
        positions[pbase] = p0.x
        positions[pbase + 1] = p0.y
        positions[pbase + 2] = p0.z
        normals[pbase] = n.x
        normals[pbase + 1] = n.y
        normals[pbase + 2] = n.z
        uvs[2vi - 1] = u
        uvs[2vi] = v
    end
    indices = Vector{Int}(undef, index_len)
    out = 1
    for i in 0:(vs - 1), j in 0:(us - 1)
        a = i * row + j + 1
        b = a + 1
        c = (i + 1) * row + j + 2
        d = c - 1
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = d
        indices[out + 3] = b
        indices[out + 4] = c
        indices[out + 5] = d
        out += 6
    end
    return BufferGeometry(positions, normals, uvs, indices, nvertices, nfaces)
end

"""
    ParametricGeometry(fn, slices=8, stacks=8)

Triangle geometry sampled from `fn(u, v) -> Vec3` on a regular grid of
`u = j / slices`, `v = i / stacks` (three.js `ParametricGeometry`, including
its defaults). Rows of constant `v` are stored in order of `u`; the UV of each
vertex is `(u, v)`, and each grid cell is split into the triangles `(a, b, d)`
and `(b, c, d)` with `a = (u, v)`, `b = (u + du, v)`, `c = (u + du, v + dv)`,
`d = (u, v + dv)`. Normals are `cross(∂p/∂u, ∂p/∂v)` normalized, with the
tangents approximated by one-sided differences of step `1e-5` (backward where
`u - 1e-5 >= 0`, else forward; likewise for `v`), so they are continuous
across seams of closed surfaces. A zero cross product gives a zero normal;
where the differences overflow or underflow, the same direction is formed with
rescaling (three.js would produce `NaN` or zero there).

`fn` must return a `Vec3` with finite coordinates at every sample, including
the difference samples, or an `ArgumentError` is thrown. See
[`ParametricFunctions`](@ref) for three.js's example surfaces.
"""
ParametricGeometry(fn::Function, slices::Integer=8, stacks::Integer=8) =
    _parametric_geometry(fn, slices, stacks, "ParametricGeometry")

"""
    NURBSSurfaceGeometry(surface::NURBSSurface; slices=20, stacks=20)

Triangle geometry of a NURBS surface: [`ParametricGeometry`](@ref) over
`(u, v) -> nurbs_point(surface, u, v)`, which is how three.js's NURBS example
builds its surface (`new ParametricGeometry(getSurfacePoint, 20, 20)`).
"""
function NURBSSurfaceGeometry(surface::NURBSSurface; slices::Integer=20,
                              stacks::Integer=20)
    basis_u = _nurbs_basis_scratch(surface.degree_u)
    basis_v = _nurbs_basis_scratch(surface.degree_v)
    point(u, v) = _nurbs_point(surface, u, v, basis_u, basis_v)
    return _parametric_geometry(point, slices, stacks, "NURBSSurfaceGeometry")
end

"""
    ParametricFunctions

three.js's example parametric surfaces (`examples/jsm/geometries/ParametricFunctions.js`)
as `(u, v) -> Vec3` functions for [`ParametricGeometry`](@ref Diff3D.ParametricGeometry):
`ParametricFunctions.klein`, `ParametricFunctions.plane`,
`ParametricFunctions.mobius` and `ParametricFunctions.mobius3d`.
"""
module ParametricFunctions

using ..Diff3D: Vec3

"""
    ParametricFunctions.klein(v, u)

Klein bottle (three.js `ParametricFunctions.klein`; note its `(v, u)`
argument order, kept from three.js).
"""
function klein(v::Real, u::Real)
    u *= π
    v *= 2π
    u = u * 2
    if u < π
        x = 3 * cos(u) * (1 + sin(u)) + (2 * (1 - cos(u) / 2)) * cos(u) * cos(v)
        z = -8 * sin(u) - 2 * (1 - cos(u) / 2) * sin(u) * cos(v)
    else
        x = 3 * cos(u) * (1 + sin(u)) + (2 * (1 - cos(u) / 2)) * cos(v + π)
        z = -8 * sin(u)
    end
    y = -2 * (1 - cos(u) / 2) * sin(v)
    return Vec3(x, y, z)
end

"""
    ParametricFunctions.plane(u, v)

The unit square in the xz plane, `Vec3(u, 0, v)` (three.js
`ParametricFunctions.plane`).
"""
plane(u::Real, v::Real) = Vec3(u, zero(u), v)

"""
    ParametricFunctions.mobius(u, t)

Möbius strip of radius 2 and width 1 (three.js `ParametricFunctions.mobius`).
"""
function mobius(u::Real, t::Real)
    u = u - 0.5
    v = 2π * t
    a = 2
    x = cos(v) * (a + u * cos(v / 2))
    y = sin(v) * (a + u * cos(v / 2))
    z = u * sin(v / 2)
    return Vec3(x, y, z)
end

"""
    ParametricFunctions.mobius3d(u, t)

Möbius band with an elliptical cross-section (three.js
`ParametricFunctions.mobius3d`).
"""
function mobius3d(u::Real, t::Real)
    u *= π
    t *= 2π
    u = u * 2
    phi = u / 2
    major, a, b = 2.25, 0.125, 0.65
    x = a * cos(t) * cos(phi) - b * sin(t) * sin(phi)
    z = a * cos(t) * sin(phi) + b * sin(t) * cos(phi)
    y = (major + x) * sin(u)
    x = (major + x) * cos(u)
    return Vec3(x, y, z)
end

end # module ParametricFunctions

# ========================== Earcut ==========================
# Port of mapbox/earcut 3.0.2 as vendored by three.js r186
# (src/extras/lib/earcut.js). Nodes live in parallel arrays; node id 0 plays
# the role of JavaScript `null`. Every predicate keeps earcut's operation order
# and tie-breaking so the triangles are identical to three.js's for the same
# Float64 input. `i` is the 0-based vertex index, as in earcut.

mutable struct _Earcut
    i::Vector{Int}
    x::Vector{Float64}
    y::Vector{Float64}
    prev::Vector{Int}
    next::Vector{Int}
    z::Vector{Int32}
    prevz::Vector{Int}
    nextz::Vector{Int}
    steiner::Vector{Bool}
    triangles::Vector{Int}
end

function _Earcut(capacity::Int)
    e = _Earcut(Int[], Float64[], Float64[], Int[], Int[], Int32[], Int[], Int[],
                Bool[], Int[])
    for field in (e.i, e.x, e.y, e.prev, e.next, e.z, e.prevz, e.nextz, e.steiner)
        sizehint!(field, capacity)
    end
    return e
end

# createNode (earcut.js:653-664)
function _ec_create!(e::_Earcut, i::Int, x::Float64, y::Float64)
    push!(e.i, i); push!(e.x, x); push!(e.y, y)
    push!(e.prev, 0); push!(e.next, 0); push!(e.z, Int32(0))
    push!(e.prevz, 0); push!(e.nextz, 0); push!(e.steiner, false)
    return length(e.i)
end

# insertNode (earcut.js:628-642)
function _ec_insert!(e::_Earcut, i::Int, x::Float64, y::Float64, last::Int)
    p = _ec_create!(e, i, x, y)
    @inbounds if last == 0
        e.prev[p] = p
        e.next[p] = p
    else
        e.next[p] = e.next[last]
        e.prev[p] = last
        e.prev[e.next[last]] = p
        e.next[last] = p
    end
    return p
end

# removeNode (earcut.js:644-651). Like earcut, the removed node keeps its links.
@inline function _ec_remove!(e::_Earcut, p::Int)
    @inbounds begin
        e.prev[e.next[p]] = e.prev[p]
        e.next[e.prev[p]] = e.next[p]
        e.prevz[p] != 0 && (e.nextz[e.prevz[p]] = e.nextz[p])
        e.nextz[p] != 0 && (e.prevz[e.nextz[p]] = e.prevz[p])
    end
    return nothing
end

@inline _ec_equals(e::_Earcut, a::Int, b::Int) =
    @inbounds e.x[a] == e.x[b] && e.y[a] == e.y[b]

# area (earcut.js:521-524): signed area of a triangle, negative counterclockwise.
@inline function _ec_area(e::_Earcut, p::Int, q::Int, r::Int)
    @inbounds return (e.y[q] - e.y[p]) * (e.x[r] - e.x[q]) -
                     (e.x[q] - e.x[p]) * (e.y[r] - e.y[q])
end

# JavaScript truthiness of a number.
@inline _ec_truthy(v::Float64) = !(iszero(v) || isnan(v))

@inline _ec_sign(v::Float64) = v > 0 ? 1 : v < 0 ? -1 : 0

# pointInTriangle (earcut.js:500-505)
@inline function _ec_point_in_triangle(ax::Float64, ay::Float64, bx::Float64, by::Float64,
                                       cx::Float64, cy::Float64, px::Float64, py::Float64)
    return (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
           (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
           (bx - px) * (cy - py) >= (cx - px) * (by - py)
end

# pointInTriangleExceptFirst (earcut.js:507-510)
@inline _ec_point_in_triangle_except_first(ax, ay, bx, by, cx, cy, px, py) =
    !(ax == px && ay == py) && _ec_point_in_triangle(ax, ay, bx, by, cx, cy, px, py)

# signedArea (earcut.js:701-708) over the flat coordinates `data[start+1:end]`
# (0-based `start`/`stop` offsets as in earcut).
function _ec_signed_area(data::Vector{Float64}, start::Int, stop::Int, dim::Int)
    sum = 0.0
    j = stop - dim
    i = start
    @inbounds while i < stop
        sum += (data[j + 1] - data[i + 1]) * (data[i + 2] + data[j + 2])
        j = i
        i += dim
    end
    return sum
end

# linkedList (earcut.js:46-62)
function _ec_linked_list!(e::_Earcut, data::Vector{Float64}, start::Int, stop::Int,
                          dim::Int, clockwise::Bool)
    last = 0
    if clockwise == (_ec_signed_area(data, start, stop, dim) > 0)
        i = start
        @inbounds while i < stop
            last = _ec_insert!(e, i ÷ dim, data[i + 1], data[i + 2], last)
            i += dim
        end
    else
        i = stop - dim
        @inbounds while i >= start
            last = _ec_insert!(e, i ÷ dim, data[i + 1], data[i + 2], last)
            i -= dim
        end
    end
    if last != 0 && _ec_equals(e, last, e.next[last])
        _ec_remove!(e, last)
        last = e.next[last]
    end
    return last
end

# filterPoints (earcut.js:65-87)
function _ec_filter_points!(e::_Earcut, start::Int, stop::Int=0)
    start == 0 && return start
    stop == 0 && (stop = start)
    p = start
    while true
        again = false
        if !e.steiner[p] && (_ec_equals(e, p, e.next[p]) ||
                             _ec_area(e, e.prev[p], p, e.next[p]) == 0)
            _ec_remove!(e, p)
            p = stop = e.prev[p]
            p == e.next[p] && break
            again = true
        else
            p = e.next[p]
        end
        (again || p != stop) || break
    end
    return stop
end

struct _EcHash
    min_x::Float64
    min_y::Float64
    inv_size::Float64
end

# earcutLinked (earcut.js:90-136)
function _ec_earcut_linked!(e::_Earcut, ear::Int, h::_EcHash, pass::Int)
    ear == 0 && return nothing
    hashed = _ec_truthy(h.inv_size)
    pass == 0 && hashed && _ec_index_curve!(e, ear, h)
    stop = ear
    while e.prev[ear] != e.next[ear]
        prev = e.prev[ear]
        next = e.next[ear]
        if hashed ? _ec_is_ear_hashed(e, ear, h) : _ec_is_ear(e, ear)
            push!(e.triangles, e.i[prev], e.i[ear], e.i[next])
            _ec_remove!(e, ear)
            # Skipping the next vertex leads to fewer sliver triangles.
            ear = e.next[next]
            stop = e.next[next]
            continue
        end
        ear = next
        if ear == stop
            if pass == 0
                _ec_earcut_linked!(e, _ec_filter_points!(e, ear), h, 1)
            elseif pass == 1
                ear = _ec_cure_local_intersections!(e, _ec_filter_points!(e, ear))
                _ec_earcut_linked!(e, ear, h, 2)
            elseif pass == 2
                _ec_split_earcut!(e, ear, h)
            end
            break
        end
    end
    return nothing
end

# isEar (earcut.js:139-164)
function _ec_is_ear(e::_Earcut, ear::Int)
    a = e.prev[ear]; b = ear; c = e.next[ear]
    _ec_area(e, a, b, c) >= 0 && return false
    @inbounds begin
        ax = e.x[a]; bx = e.x[b]; cx = e.x[c]
        ay = e.y[a]; by = e.y[b]; cy = e.y[c]
    end
    x0 = min(ax, bx, cx); y0 = min(ay, by, cy)
    x1 = max(ax, bx, cx); y1 = max(ay, by, cy)
    p = e.next[c]
    @inbounds while p != a
        px = e.x[p]; py = e.y[p]
        if px >= x0 && px <= x1 && py >= y0 && py <= y1 &&
           _ec_point_in_triangle_except_first(ax, ay, bx, by, cx, cy, px, py) &&
           _ec_area(e, e.prev[p], p, e.next[p]) >= 0
            return false
        end
        p = e.next[p]
    end
    return true
end

@inline function _ec_blocks(e::_Earcut, p::Int, a::Int, c::Int, ax, ay, bx, by, cx, cy,
                            x0, y0, x1, y1)
    @inbounds begin
        px = e.x[p]; py = e.y[p]
        return px >= x0 && px <= x1 && py >= y0 && py <= y1 && p != a && p != c &&
               _ec_point_in_triangle_except_first(ax, ay, bx, by, cx, cy, px, py) &&
               _ec_area(e, e.prev[p], p, e.next[p]) >= 0
    end
end

# isEarHashed (earcut.js:166-213)
function _ec_is_ear_hashed(e::_Earcut, ear::Int, h::_EcHash)
    a = e.prev[ear]; b = ear; c = e.next[ear]
    _ec_area(e, a, b, c) >= 0 && return false
    @inbounds begin
        ax = e.x[a]; bx = e.x[b]; cx = e.x[c]
        ay = e.y[a]; by = e.y[b]; cy = e.y[c]
    end
    x0 = min(ax, bx, cx); y0 = min(ay, by, cy)
    x1 = max(ax, bx, cx); y1 = max(ay, by, cy)
    min_z = _ec_z_order(x0, y0, h)
    max_z = _ec_z_order(x1, y1, h)
    p = e.prevz[ear]
    n = e.nextz[ear]
    @inbounds while p != 0 && e.z[p] >= min_z && n != 0 && e.z[n] <= max_z
        _ec_blocks(e, p, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1) && return false
        p = e.prevz[p]
        _ec_blocks(e, n, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1) && return false
        n = e.nextz[n]
    end
    @inbounds while p != 0 && e.z[p] >= min_z
        _ec_blocks(e, p, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1) && return false
        p = e.prevz[p]
    end
    @inbounds while n != 0 && e.z[n] <= max_z
        _ec_blocks(e, n, a, c, ax, ay, bx, by, cx, cy, x0, y0, x1, y1) && return false
        n = e.nextz[n]
    end
    return true
end

# cureLocalIntersections (earcut.js:216-236)
function _ec_cure_local_intersections!(e::_Earcut, start::Int)
    p = start
    while true
        a = e.prev[p]
        b = e.next[e.next[p]]
        if !_ec_equals(e, a, b) && _ec_intersects(e, a, p, e.next[p], b) &&
           _ec_locally_inside(e, a, b) && _ec_locally_inside(e, b, a)
            push!(e.triangles, e.i[a], e.i[p], e.i[b])
            _ec_remove!(e, p)
            _ec_remove!(e, e.next[p])
            p = start = b
        end
        p = e.next[p]
        p != start || break
    end
    return _ec_filter_points!(e, p)
end

# splitEarcut (earcut.js:239-264)
function _ec_split_earcut!(e::_Earcut, start::Int, h::_EcHash)
    a = start
    while true
        b = e.next[e.next[a]]
        while b != e.prev[a]
            if e.i[a] != e.i[b] && _ec_is_valid_diagonal(e, a, b)
                c = _ec_split_polygon!(e, a, b)
                a = _ec_filter_points!(e, a, e.next[a])
                c = _ec_filter_points!(e, c, e.next[c])
                _ec_earcut_linked!(e, a, h, 0)
                _ec_earcut_linked!(e, c, h, 0)
                return nothing
            end
            b = e.next[b]
        end
        a = e.next[a]
        a != start || break
    end
    return nothing
end

# compareXYSlope (earcut.js:286-299). A NaN result counts as equal, as in
# Array.prototype.sort.
function _ec_compare_xy_slope(e::_Earcut, a::Int, b::Int)
    result = e.x[a] - e.x[b]
    if result == 0
        result = e.y[a] - e.y[b]
        if result == 0
            a_slope = (e.y[e.next[a]] - e.y[a]) / (e.x[e.next[a]] - e.x[a])
            b_slope = (e.y[e.next[b]] - e.y[b]) / (e.x[e.next[b]] - e.x[b])
            result = a_slope - b_slope
        end
    end
    return isnan(result) ? 0.0 : result
end

# eliminateHoles (earcut.js:267-284). `hole_starts` are 0-based vertex indices.
function _ec_eliminate_holes!(e::_Earcut, data::Vector{Float64}, hole_starts::Vector{Int},
                              outer::Int, dim::Int)
    queue = Vector{Int}(undef, length(hole_starts))
    len = length(hole_starts)
    for k in 1:len
        start = hole_starts[k] * dim
        stop = k < len ? hole_starts[k + 1] * dim : length(data)
        list = _ec_linked_list!(e, data, start, stop, dim, false)
        list == 0 && throw(ArgumentError("earcut hole $k has no vertices"))
        list == e.next[list] && (e.steiner[list] = true)
        queue[k] = _ec_get_leftmost(e, list)
    end
    # Array.prototype.sort is stable.
    sort!(queue; alg=MergeSort, lt=(a, b) -> _ec_compare_xy_slope(e, a, b) < 0)
    for hole in queue
        outer = _ec_eliminate_hole!(e, hole, outer)
    end
    return outer
end

# eliminateHole (earcut.js:302-313)
function _ec_eliminate_hole!(e::_Earcut, hole::Int, outer::Int)
    bridge = _ec_find_hole_bridge(e, hole, outer)
    bridge == 0 && return outer
    bridge_reverse = _ec_split_polygon!(e, bridge, hole)
    _ec_filter_points!(e, bridge_reverse, e.next[bridge_reverse])
    return _ec_filter_points!(e, bridge, e.next[bridge])
end

# findHoleBridge: David Eberly's bridge search (earcut.js:316-372).
function _ec_find_hole_bridge(e::_Earcut, hole::Int, outer::Int)
    p = outer
    hx = e.x[hole]
    hy = e.y[hole]
    qx = -Inf
    m = 0
    _ec_equals(e, hole, p) && return p
    while true
        pn = e.next[p]
        _ec_equals(e, hole, pn) && return pn
        if hy <= e.y[p] && hy >= e.y[pn] && e.y[pn] != e.y[p]
            x = e.x[p] + (hy - e.y[p]) * (e.x[pn] - e.x[p]) / (e.y[pn] - e.y[p])
            if x <= hx && x > qx
                qx = x
                m = e.x[p] < e.x[pn] ? p : pn
                x == hx && return m
            end
        end
        p = pn
        p != outer || break
    end
    m == 0 && return 0
    stop = m
    mx = e.x[m]
    my = e.y[m]
    tan_min = Inf
    p = m
    while true
        px = e.x[p]; py = e.y[p]
        if hx >= px && px >= mx && hx != px &&
           _ec_point_in_triangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, px, py)
            tan = abs(hy - py) / (hx - px)
            if _ec_locally_inside(e, p, hole) &&
               (tan < tan_min || (tan == tan_min &&
                                  (px > e.x[m] || (px == e.x[m] && _ec_sector_contains_sector(e, m, p)))))
                m = p
                tan_min = tan
            end
        end
        p = e.next[p]
        p != stop || break
    end
    return m
end

# sectorContainsSector (earcut.js:375-377)
_ec_sector_contains_sector(e::_Earcut, m::Int, p::Int) =
    _ec_area(e, e.prev[m], m, e.prev[p]) < 0 && _ec_area(e, e.next[p], m, e.next[m]) < 0

# indexCurve (earcut.js:380-394)
function _ec_index_curve!(e::_Earcut, start::Int, h::_EcHash)
    p = start
    @inbounds while true
        e.z[p] == 0 && (e.z[p] = _ec_z_order(e.x[p], e.y[p], h))
        e.prevz[p] = e.prev[p]
        e.nextz[p] = e.next[p]
        p = e.next[p]
        p != start || break
    end
    e.nextz[e.prevz[p]] = 0
    e.prevz[p] = 0
    _ec_sort_linked!(e, p)
    return nothing
end

# sortLinked: Simon Tatham's linked-list merge sort (earcut.js:397-448).
function _ec_sort_linked!(e::_Earcut, list::Int)
    in_size = 1
    @inbounds while true
        p = list
        list = 0
        tail = 0
        num_merges = 0
        while p != 0
            num_merges += 1
            q = p
            p_size = 0
            for _ in 1:in_size
                p_size += 1
                q = e.nextz[q]
                q == 0 && break
            end
            q_size = in_size
            while p_size > 0 || (q_size > 0 && q != 0)
                if p_size != 0 && (q_size == 0 || q == 0 || e.z[p] <= e.z[q])
                    node = p
                    p = e.nextz[p]
                    p_size -= 1
                else
                    node = q
                    q = e.nextz[q]
                    q_size -= 1
                end
                if tail != 0
                    e.nextz[tail] = node
                else
                    list = node
                end
                e.prevz[node] = tail
                tail = node
            end
            p = q
        end
        e.nextz[tail] = 0
        in_size *= 2
        num_merges > 1 || break
    end
    return list
end

# ECMAScript ToInt32, the `| 0` in zOrder.
@inline function _ec_to_int32(v::Float64)
    isfinite(v) || return Int32(0)
    m = rem(trunc(v), 4294967296.0)
    m < 0 && (m += 4294967296.0)
    return reinterpret(Int32, UInt32(m))
end

# zOrder (earcut.js:451-467): 32-bit integer arithmetic as in JavaScript.
@inline function _ec_z_order(x::Float64, y::Float64, h::_EcHash)
    xi = _ec_to_int32((x - h.min_x) * h.inv_size)
    yi = _ec_to_int32((y - h.min_y) * h.inv_size)
    xi = (xi | (xi << 8)) & Int32(0x00FF00FF)
    xi = (xi | (xi << 4)) & Int32(0x0F0F0F0F)
    xi = (xi | (xi << 2)) & Int32(0x33333333)
    xi = (xi | (xi << 1)) & Int32(0x55555555)
    yi = (yi | (yi << 8)) & Int32(0x00FF00FF)
    yi = (yi | (yi << 4)) & Int32(0x0F0F0F0F)
    yi = (yi | (yi << 2)) & Int32(0x33333333)
    yi = (yi | (yi << 1)) & Int32(0x55555555)
    return xi | (yi << 1)
end

# getLeftmost (earcut.js:470-479)
function _ec_get_leftmost(e::_Earcut, start::Int)
    p = start
    leftmost = start
    while true
        (e.x[p] < e.x[leftmost] || (e.x[p] == e.x[leftmost] && e.y[p] < e.y[leftmost])) &&
            (leftmost = p)
        p = e.next[p]
        p != start || break
    end
    return leftmost
end

# isValidDiagonal (earcut.js:513-518)
function _ec_is_valid_diagonal(e::_Earcut, a::Int, b::Int)
    return e.i[e.next[a]] != e.i[b] && e.i[e.prev[a]] != e.i[b] &&
           !_ec_intersects_polygon(e, a, b) &&
           ((_ec_locally_inside(e, a, b) && _ec_locally_inside(e, b, a) &&
             _ec_middle_inside(e, a, b) &&
             (_ec_truthy(_ec_area(e, e.prev[a], a, e.prev[b])) ||
              _ec_truthy(_ec_area(e, a, e.prev[b], b)))) ||
            (_ec_equals(e, a, b) && _ec_area(e, e.prev[a], a, e.next[a]) > 0 &&
             _ec_area(e, e.prev[b], b, e.next[b]) > 0))
end

# onSegment (earcut.js:546-549)
@inline _ec_on_segment(e::_Earcut, p::Int, q::Int, r::Int) =
    e.x[q] <= max(e.x[p], e.x[r]) && e.x[q] >= min(e.x[p], e.x[r]) &&
    e.y[q] <= max(e.y[p], e.y[r]) && e.y[q] >= min(e.y[p], e.y[r])

# intersects (earcut.js:532-544)
function _ec_intersects(e::_Earcut, p1::Int, q1::Int, p2::Int, q2::Int)
    o1 = _ec_sign(_ec_area(e, p1, q1, p2))
    o2 = _ec_sign(_ec_area(e, p1, q1, q2))
    o3 = _ec_sign(_ec_area(e, p2, q2, p1))
    o4 = _ec_sign(_ec_area(e, p2, q2, q1))
    o1 != o2 && o3 != o4 && return true
    o1 == 0 && _ec_on_segment(e, p1, p2, q1) && return true
    o2 == 0 && _ec_on_segment(e, p1, q2, q1) && return true
    o3 == 0 && _ec_on_segment(e, p2, p1, q2) && return true
    o4 == 0 && _ec_on_segment(e, p2, q1, q2) && return true
    return false
end

# intersectsPolygon (earcut.js:556-565)
function _ec_intersects_polygon(e::_Earcut, a::Int, b::Int)
    p = a
    ia = e.i[a]; ib = e.i[b]
    while true
        pn = e.next[p]
        if e.i[p] != ia && e.i[pn] != ia && e.i[p] != ib && e.i[pn] != ib &&
           _ec_intersects(e, p, pn, a, b)
            return true
        end
        p = pn
        p != a || break
    end
    return false
end

# locallyInside (earcut.js:568-572)
function _ec_locally_inside(e::_Earcut, a::Int, b::Int)
    return _ec_area(e, e.prev[a], a, e.next[a]) < 0 ?
           _ec_area(e, a, b, e.next[a]) >= 0 && _ec_area(e, a, e.prev[a], b) >= 0 :
           _ec_area(e, a, b, e.prev[a]) < 0 || _ec_area(e, a, e.next[a], b) < 0
end

# middleInside (earcut.js:575-588)
function _ec_middle_inside(e::_Earcut, a::Int, b::Int)
    p = a
    inside = false
    px = (e.x[a] + e.x[b]) / 2
    py = (e.y[a] + e.y[b]) / 2
    while true
        pn = e.next[p]
        if ((e.y[p] > py) != (e.y[pn] > py)) && e.y[pn] != e.y[p] &&
           (px < (e.x[pn] - e.x[p]) * (py - e.y[p]) / (e.y[pn] - e.y[p]) + e.x[p])
            inside = !inside
        end
        p = pn
        p != a || break
    end
    return inside
end

# splitPolygon (earcut.js:592-613)
function _ec_split_polygon!(e::_Earcut, a::Int, b::Int)
    a2 = _ec_create!(e, e.i[a], e.x[a], e.y[a])
    b2 = _ec_create!(e, e.i[b], e.x[b], e.y[b])
    an = e.next[a]
    bp = e.prev[b]
    e.next[a] = b
    e.prev[b] = a
    e.next[a2] = an
    e.prev[an] = a2
    e.next[b2] = a2
    e.prev[a2] = b2
    e.next[bp] = b2
    e.prev[b2] = bp
    return b2
end

# earcut (earcut.js:5-43) on flat coordinates with 0-based hole start vertices.
# Returns 0-based vertex indices, three per triangle.
function _earcut(data::Vector{Float64}, hole_starts::Vector{Int}, dim::Int)
    has_holes = !isempty(hole_starts)
    outer_len = has_holes ? hole_starts[1] * dim : length(data)
    e = _Earcut(length(data) ÷ dim + 4 * length(hole_starts) + 8)
    outer = _ec_linked_list!(e, data, 0, outer_len, dim, true)
    (outer == 0 || e.next[outer] == e.prev[outer]) && return e.triangles
    sizehint!(e.triangles, 3 * (length(data) ÷ dim + 2 * length(hole_starts)))
    has_holes && (outer = _ec_eliminate_holes!(e, data, hole_starts, outer, dim))
    min_x = 0.0
    min_y = 0.0
    inv_size = 0.0
    # Larger inputs use the z-order curve hash; its box covers the outer ring only.
    if length(data) > 80 * dim
        min_x = data[1]
        min_y = data[2]
        max_x = min_x
        max_y = min_y
        i = dim
        @inbounds while i < outer_len
            x = data[i + 1]; y = data[i + 2]
            x < min_x && (min_x = x)
            y < min_y && (min_y = y)
            x > max_x && (max_x = x)
            y > max_y && (max_y = y)
            i += dim
        end
        inv_size = max(max_x - min_x, max_y - min_y)
        inv_size = inv_size != 0 ? 32767 / inv_size : 0.0
    end
    _ec_earcut_linked!(e, outer, _EcHash(min_x, min_y, inv_size), 0)
    return e.triangles
end

"""
    earcut_triangulate(data, hole_indices=Int[]; dim=2) -> Vector{Int}

Triangulate a polygon with holes by the Earcut algorithm, as three.js
`Earcut.triangulate(data, holeIndices, dim)` (mapbox/earcut 3.0.2,
src/extras/lib/earcut.js) does. `data` holds the flat vertex coordinates
`[x1, y1, x2, y2, ...]` (`dim` numbers per vertex; only the first two are
used): the outer ring first, then each hole. `hole_indices` are the one-based
vertex indices at which the holes start. Returns one-based vertex indices,
three per triangle, identical to three.js's triangles (shifted by one) for the
same input. Rings may have either winding; degenerate, collinear and
self-touching input is triangulated as Earcut does, and input whose outer ring
has fewer than three distinct points returns no triangles.
"""
function earcut_triangulate(data::AbstractVector{<:Real}, hole_indices::AbstractVector{<:Integer}=Int[];
                            dim::Integer=2)
    d = _geometry_int(dim, "earcut_triangulate dim")
    d >= 2 || throw(ArgumentError("earcut_triangulate dim must be at least 2"))
    rem(length(data), d) == 0 ||
        throw(ArgumentError("earcut_triangulate data length must be a multiple of dim"))
    coords = Vector{Float64}(undef, length(data))
    for (k, value) in enumerate(data)
        coords[k] = _geometry_finite_float(value, "earcut_triangulate data")
    end
    nverts = length(coords) ÷ d
    starts = Vector{Int}(undef, length(hole_indices))
    previous = 0
    for (k, index) in enumerate(hole_indices)
        start = _geometry_int(index, "earcut_triangulate hole index") - 1
        previous < start <= nverts - 1 ||
            throw(ArgumentError("earcut_triangulate hole indices must increase within 2:$nverts"))
        starts[k] = start
        previous = start
    end
    triangles = _earcut(coords, starts, d)
    triangles .+= 1
    return triangles
end

# ========================== Shape / Extrude ==========================
# A Shape is a simple polygon in the xy-plane (Vector{Vec2}). ShapeGeometry
# fills it; ExtrudeGeometry sweeps it to depth along +z, or along a sampled 3D
# path.

function _shape_area2(shape::AbstractVector{<:Vec2})
    xmin = Inf
    xmax = -Inf
    ymin = Inf
    ymax = -Inf
    @inbounds for p in shape
        xmin = min(xmin, p.x)
        xmax = max(xmax, p.x)
        ymin = min(ymin, p.y)
        ymax = max(ymax, p.y)
    end
    cx = _geometry_midpoint(xmin, xmax)
    cy = _geometry_midpoint(ymin, ymax)
    xscale = max(abs(xmin - cx), abs(xmax - cx))
    yscale = max(abs(ymin - cy), abs(ymax - cy))
    (xscale > 0.0 && yscale > 0.0) || return 0.0

    area2 = 0.0
    @inbounds for i in eachindex(shape)
        p1 = shape[i]
        p2 = shape[i == lastindex(shape) ? firstindex(shape) : i + 1]
        x1 = (p1.x - cx) / xscale
        y1 = (p1.y - cy) / yscale
        x2 = (p2.x - cx) / xscale
        y2 = (p2.y - cy) / yscale
        area2 += x1 * y2 - x2 * y1
    end
    return area2
end

@inline function _shape_turn(a::Vec2, b::Vec2, c::Vec2)
    return _stable_float_product_difference(
        b.x - a.x, c.y - a.y, b.y - a.y, c.x - a.x)
end

function _shape_normalized_points(shape::Vector{Vec2{Float64}})
    xmin = minimum(point -> point.x, shape)
    xmax = maximum(point -> point.x, shape)
    ymin = minimum(point -> point.y, shape)
    ymax = maximum(point -> point.y, shape)
    cx = _geometry_midpoint(xmin, xmax)
    cy = _geometry_midpoint(ymin, ymax)
    xscale = max(abs(xmin - cx), abs(xmax - cx))
    yscale = max(abs(ymin - cy), abs(ymax - cy))
    (xscale > 0.0 && yscale > 0.0) ||
        throw(ArgumentError("ExtrudeGeometry shape area must be non-zero"))
    return [Vec2((point.x - cx) / xscale,
                 (point.y - cy) / yscale) for point in shape]
end

@inline function _shape_point_on_segment(point::Vec2, a::Vec2, b::Vec2,
                                         tolerance::Float64)
    abs(_shape_turn(a, b, point)) <= tolerance || return false
    return min(a.x, b.x) - tolerance <= point.x <= max(a.x, b.x) + tolerance &&
           min(a.y, b.y) - tolerance <= point.y <= max(a.y, b.y) + tolerance
end

@inline function _shape_segments_intersect(a::Vec2, b::Vec2,
                                           c::Vec2, d::Vec2,
                                           tolerance::Float64)
    ab_c = _shape_turn(a, b, c)
    ab_d = _shape_turn(a, b, d)
    cd_a = _shape_turn(c, d, a)
    cd_b = _shape_turn(c, d, b)
    ((ab_c > tolerance && ab_d < -tolerance) ||
     (ab_c < -tolerance && ab_d > tolerance)) &&
    ((cd_a > tolerance && cd_b < -tolerance) ||
     (cd_a < -tolerance && cd_b > tolerance)) && return true
    abs(ab_c) <= tolerance &&
        _shape_point_on_segment(c, a, b, tolerance) && return true
    abs(ab_d) <= tolerance &&
        _shape_point_on_segment(d, a, b, tolerance) && return true
    abs(cd_a) <= tolerance &&
        _shape_point_on_segment(a, c, d, tolerance) && return true
    return abs(cd_b) <= tolerance &&
           _shape_point_on_segment(b, c, d, tolerance)
end

function _shape_validate_simple(points::Vector{Vec2{Float64}},
                                tolerance::Float64)
    n = length(points)
    @inbounds for first_edge in 1:n
        first_next = mod1(first_edge + 1, n)
        for second_edge in (first_edge + 1):n
            second_next = mod1(second_edge + 1, n)
            (first_next == second_edge || second_next == first_edge) && continue
            _shape_segments_intersect(
                points[first_edge], points[first_next],
                points[second_edge], points[second_next], tolerance) &&
                throw(ArgumentError(
                    "ExtrudeGeometry shape must be a simple polygon"))
        end
    end
    return nothing
end

@inline function _shape_point_in_triangle(point::Vec2, a::Vec2,
                                          b::Vec2, c::Vec2,
                                          tolerance::Float64)
    return _shape_turn(a, b, point) >= -tolerance &&
           _shape_turn(b, c, point) >= -tolerance &&
           _shape_turn(c, a, point) >= -tolerance
end

function _shape_triangulate(shape::Vector{Vec2{Float64}})
    points = _shape_normalized_points(shape)
    tolerance = 64 * eps(Float64)
    _shape_validate_simple(points, tolerance)
    remaining = collect(eachindex(points))
    triangles = Vector{NTuple{3,Int}}()
    sizehint!(triangles, length(points) - 2)
    while length(remaining) > 3
        found_ear = false
        @inbounds for slot in eachindex(remaining)
            previous = remaining[mod1(slot - 1, length(remaining))]
            current = remaining[slot]
            following = remaining[mod1(slot + 1, length(remaining))]
            a, b, c = points[previous], points[current], points[following]
            _shape_turn(a, b, c) > tolerance || continue
            contains_vertex = false
            for other in remaining
                (other == previous || other == current || other == following) &&
                    continue
                if _shape_point_in_triangle(
                        points[other], a, b, c, tolerance)
                    contains_vertex = true
                    break
                end
            end
            contains_vertex && continue
            push!(triangles, (previous, current, following))
            deleteat!(remaining, slot)
            found_ear = true
            break
        end
        found_ear || throw(ArgumentError(
            "ExtrudeGeometry shape could not be triangulated"))
    end
    final_triangle = (remaining[1], remaining[2], remaining[3])
    _shape_turn(points[final_triangle[1]], points[final_triangle[2]],
                points[final_triangle[3]]) > tolerance ||
        throw(ArgumentError("ExtrudeGeometry shape could not be triangulated"))
    push!(triangles, final_triangle)
    return triangles
end

# ---- Shapes with holes (three.js ShapeUtils.triangulateShape) ----
# Loops are stored back to back in one point list: loop k is `ranges[k]`, the
# CCW outer contour first and the CW holes after it.

function _shape_point_in_loop(p::Vec2, points::Vector{Vec2{Float64}}, range::UnitRange{Int})
    inside = false
    j = last(range)
    @inbounds for i in range
        a = points[i]; b = points[j]
        if (a.y > p.y) != (b.y > p.y)
            x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
            x > p.x && (inside = !inside)
        end
        j = i
    end
    return inside
end

function _shape_validate_loops(points::Vector{Vec2{Float64}}, ranges::Vector{UnitRange{Int}},
                               tolerance::Float64)
    next_in(range, i) = i == last(range) ? first(range) : i + 1
    for la in eachindex(ranges), ea in ranges[la]
        na = next_in(ranges[la], ea)
        for lb in la:length(ranges)
            for eb in (lb == la ? (ea + 1:last(ranges[lb])) : ranges[lb])
                nb = next_in(ranges[lb], eb)
                (lb == la && (na == eb || nb == ea)) && continue
                _shape_segments_intersect(points[ea], points[na], points[eb], points[nb],
                                          tolerance) &&
                    throw(ArgumentError("ExtrudeGeometry shape and holes must be simple " *
                                        "and must not intersect"))
            end
        end
    end
    for k in 2:length(ranges)
        p = points[first(ranges[k])]
        _shape_point_in_loop(p, points, ranges[1]) ||
            throw(ArgumentError("ExtrudeGeometry holes must lie inside the shape"))
        for j in 2:length(ranges)
            j != k && _shape_point_in_loop(p, points, ranges[j]) &&
                throw(ArgumentError("ExtrudeGeometry holes must not be nested"))
        end
    end
    return nothing
end

# Is the direction from poly vertex `slot` towards `b` inside the polygon there?
function _shape_locally_inside(points::Vector{Vec2{Float64}}, poly::Vector{Int},
                               slot::Int, b::Vec2)
    n = length(poly)
    prev = points[poly[mod1(slot - 1, n)]]
    a = points[poly[slot]]
    next = points[poly[mod1(slot + 1, n)]]
    left_of_next = _shape_turn(a, next, b) >= 0
    left_of_prev = _shape_turn(prev, a, b) >= 0
    return _shape_turn(prev, a, next) >= 0 ? (left_of_next && left_of_prev) :
                                             (left_of_next || left_of_prev)
end

# Eberly/earcut hole elimination with a +x ray from the hole's rightmost vertex.
function _shape_bridge_hole!(poly::Vector{Int}, points::Vector{Vec2{Float64}},
                             hole::UnitRange{Int}, tolerance::Float64)
    hp = first(hole)
    for id in hole
        q = points[id]; h = points[hp]
        (q.x > h.x || (q.x == h.x && q.y < h.y)) && (hp = id)
    end
    H = points[hp]
    n = length(poly)
    best_x = Inf
    best_slot = 0
    for slot in 1:n
        a = points[poly[slot]]
        b = points[poly[mod1(slot + 1, n)]]
        a.y <= H.y <= b.y && a.y < b.y || continue
        x = a.x + (H.y - a.y) / (b.y - a.y) * (b.x - a.x)
        if x >= H.x && x < best_x
            best_x = x
            best_slot = slot
        end
    end
    best_slot == 0 &&
        throw(ArgumentError("ExtrudeGeometry shape could not be triangulated"))
    a_slot = best_slot
    b_slot = mod1(best_slot + 1, n)
    m_slot = points[poly[b_slot]].x > points[poly[a_slot]].x ? b_slot : a_slot
    if best_x > H.x
        I = Vec2(best_x, H.y)
        M = points[poly[m_slot]]
        tri = H.y < M.y ? (H, I, M) : (H, M, I)
        best_tan = abs(H.y - M.y) / (M.x - H.x)
        for slot in 1:n
            p = points[poly[slot]]
            H.x < p.x <= M.x || continue
            slot == m_slot && continue
            _shape_point_in_triangle(p, tri..., tolerance) || continue
            _shape_locally_inside(points, poly, slot, H) || continue
            tan = abs(H.y - p.y) / (p.x - H.x)
            if tan < best_tan || (tan == best_tan && p.x < points[poly[m_slot]].x)
                best_tan = tan
                m_slot = slot
            end
        end
    end
    m = poly[m_slot]
    ring = Int[]
    sizehint!(ring, length(hole) + 2)
    offset = hp - first(hole)
    for k in 0:length(hole)
        push!(ring, first(hole) + mod(offset + k, length(hole)))
    end
    push!(ring, m)
    for (k, id) in enumerate(ring)
        insert!(poly, m_slot + k, id)
    end
    return poly
end

function _shape_ear_clip(points::Vector{Vec2{Float64}}, poly::Vector{Int},
                         tolerance::Float64)
    remaining = poly
    triangles = Vector{NTuple{3,Int}}()
    sizehint!(triangles, length(remaining) - 2)
    while length(remaining) > 3
        m = length(remaining)
        found = false
        @inbounds for slot in 1:m
            ip = remaining[mod1(slot - 1, m)]
            ic = remaining[slot]
            inext = remaining[mod1(slot + 1, m)]
            a, b, c = points[ip], points[ic], points[inext]
            _shape_turn(a, b, c) > tolerance || continue
            blocked = false
            for other in remaining
                (other == ip || other == ic || other == inext) && continue
                q = points[other]
                (q == a || q == b || q == c) && continue
                if _shape_point_in_triangle(q, a, b, c, tolerance)
                    blocked = true
                    break
                end
            end
            blocked && continue
            push!(triangles, (ip, ic, inext))
            deleteat!(remaining, slot)
            found = true
            break
        end
        if !found
            # Drop a vertex that encloses no area (collinear run or bridge spike).
            @inbounds for slot in 1:m
                a = points[remaining[mod1(slot - 1, m)]]
                b = points[remaining[slot]]
                c = points[remaining[mod1(slot + 1, m)]]
                if abs(_shape_turn(a, b, c)) <= tolerance
                    deleteat!(remaining, slot)
                    found = true
                    break
                end
            end
        end
        found || throw(ArgumentError("ExtrudeGeometry shape could not be triangulated"))
    end
    if length(remaining) == 3
        a, b, c = remaining
        _shape_turn(points[a], points[b], points[c]) > tolerance &&
            push!(triangles, (a, b, c))
    end
    isempty(triangles) &&
        throw(ArgumentError("ExtrudeGeometry shape could not be triangulated"))
    return triangles
end

# Triangulate a CCW outer contour with CW holes. Triangle indices refer to the
# concatenation `[outer; holes...]`, like three.js ShapeUtils.triangulateShape.
function _shape_triangulate(outer::Vector{Vec2{Float64}},
                            holes::Vector{Vector{Vec2{Float64}}})
    isempty(holes) && return _shape_triangulate(outer)
    all_points = reduce(vcat, holes; init=copy(outer))
    points = _shape_normalized_points(all_points)
    tolerance = 64 * eps(Float64)
    ranges = UnitRange{Int}[1:length(outer)]
    start = length(outer)
    for hole in holes
        push!(ranges, (start + 1):(start + length(hole)))
        start += length(hole)
    end
    _shape_validate_loops(points, ranges, tolerance)
    poly = collect(ranges[1])
    order = sort(2:length(ranges); by=k -> -maximum(points[i].x for i in ranges[k]))
    for k in order
        _shape_bridge_hole!(poly, points, ranges[k], tolerance)
    end
    return _shape_ear_clip(points, poly, tolerance)
end

const _NO_SHAPE_HOLES = Vector{Vec2{Float64}}[]

function _shape_clean_holes(holes)
    isempty(holes) && return _NO_SHAPE_HOLES
    out = Vector{Vec2{Float64}}[]
    for hole in holes
        clean = _extrude_clean_shape(hole)
        push!(out, reverse!(clean))
    end
    return out
end

_shape_len(v::Vec2) = hypot(v.x, v.y)
_shape_normalize(v::Vec2) = v * (1 / _shape_len(v))

@inline function _extrude_component_close(a::Float64, b::Float64,
                                          scale::Float64,
                                          relative_tolerance::Float64)
    iszero(scale) && return a == b
    return abs((a - b) / scale) <= relative_tolerance
end

@inline function _extrude_shape_points_close(a::Vec2{Float64},
                                             b::Vec2{Float64},
                                             xscale::Float64,
                                             yscale::Float64)
    return _extrude_component_close(a.x, b.x, xscale, 1.0e-12) &&
           _extrude_component_close(a.y, b.y, yscale, 1.0e-12)
end

function _extrude_clean_shape(shape::AbstractVector{<:Vec2})
    length(shape) >= 3 || throw(ArgumentError("ExtrudeGeometry shape needs at least three points"))
    raw = Vector{Vec2{Float64}}(undef, length(shape))
    for (index, point) in pairs(shape)
        raw[index] = Vec2{Float64}(
            _geometry_finite_float(
                point.x, "ExtrudeGeometry shape points"),
            _geometry_finite_float(
                point.y, "ExtrudeGeometry shape points"))
    end
    xmin = minimum(point -> point.x, raw)
    xmax = maximum(point -> point.x, raw)
    ymin = minimum(point -> point.y, raw)
    ymax = maximum(point -> point.y, raw)
    cx = _geometry_midpoint(xmin, xmax)
    cy = _geometry_midpoint(ymin, ymax)
    xscale = max(abs(xmin - cx), abs(xmax - cx))
    yscale = max(abs(ymin - cy), abs(ymax - cy))
    clean = Vec2{Float64}[]
    sizehint!(clean, length(raw))
    for point in raw
        if isempty(clean) ||
           !_extrude_shape_points_close(
               point, clean[end], xscale, yscale)
            push!(clean, point)
        end
    end
    if length(clean) > 1 && _extrude_shape_points_close(
            clean[end], clean[1], xscale, yscale)
        pop!(clean)
    end
    length(clean) >= 3 || throw(ArgumentError("ExtrudeGeometry shape needs at least three points"))
    area2 = _shape_area2(clean)
    abs(area2) > 1.0e-12 ||
        throw(ArgumentError("ExtrudeGeometry shape area must be non-zero"))
    area2 > 0.0 || reverse!(clean)
    return clean
end

@inline function _extrude_path_points_close(a::Vec3{Float64},
                                            b::Vec3{Float64},
                                            scale::Vec3{Float64})
    return _extrude_component_close(a.x, b.x, scale.x, 1.0e-9) &&
           _extrude_component_close(a.y, b.y, scale.y, 1.0e-9) &&
           _extrude_component_close(a.z, b.z, scale.z, 1.0e-9)
end

function _extrude_clean_path(path::AbstractVector{<:Vec3})
    length(path) >= 2 || throw(ArgumentError("ExtrudeGeometry extrude_path needs at least two points"))
    raw = Vector{Vec3{Float64}}(undef, length(path))
    for (i, p) in enumerate(path)
        raw[i] = Vec3{Float64}(
            _geometry_finite_float(p.x, "ExtrudeGeometry extrude_path points"),
            _geometry_finite_float(p.y, "ExtrudeGeometry extrude_path points"),
            _geometry_finite_float(p.z, "ExtrudeGeometry extrude_path points"))
    end
    xmin = ymin = zmin = Inf
    xmax = ymax = zmax = -Inf
    @inbounds for q in raw
        xmin = min(xmin, q.x); xmax = max(xmax, q.x)
        ymin = min(ymin, q.y); ymax = max(ymax, q.y)
        zmin = min(zmin, q.z); zmax = max(zmax, q.z)
    end
    cx = _geometry_midpoint(xmin, xmax)
    cy = _geometry_midpoint(ymin, ymax)
    cz = _geometry_midpoint(zmin, zmax)
    scale = Vec3(max(abs(xmin - cx), abs(xmax - cx)),
                 max(abs(ymin - cy), abs(ymax - cy)),
                 max(abs(zmin - cz), abs(zmax - cz)))
    closed = _extrude_path_points_close(raw[end], raw[1], scale)
    clean_last = closed ? length(raw) - 1 : length(raw)
    filtered = sizehint!(Vec3{Float64}[], clean_last)
    for i in 1:clean_last
        p = raw[i]
        if isempty(filtered) ||
           !_extrude_path_points_close(p, filtered[end], scale)
            push!(filtered, p)
        end
    end
    length(filtered) >= 2 ||
        throw(ArgumentError("ExtrudeGeometry extrude_path needs at least two distinct points"))
    return filtered, closed, 1.0e-9
end

function _extrude_path_tangents(path::Vector{Vec3{Float64}}, closed::Bool, eps::Float64)
    n = length(path)
    tangents = Vector{Vec3{Float64}}(undef, n)
    @inbounds for i in 1:n
        prev = closed ? path[mod1(i - 1, n)] : path[max(i - 1, 1)]
        nxt = closed ? path[mod1(i + 1, n)] : path[min(i + 1, n)]
        t = _geometry_unit_delta3(
            prev.x, prev.y, prev.z, nxt.x, nxt.y, nxt.z)
        if norm(t) <= eps
            next_point = path[mod1(i + 1, n)]
            prev_point = path[mod1(i - 1, n)]
            forward = _geometry_unit_delta3(
                path[i].x, path[i].y, path[i].z,
                next_point.x, next_point.y, next_point.z)
            backward = _geometry_unit_delta3(
                prev_point.x, prev_point.y, prev_point.z,
                path[i].x, path[i].y, path[i].z)
            t = norm(forward) > eps ? forward : backward
        end
        norm(t) > eps ||
            throw(ArgumentError("ExtrudeGeometry extrude_path contains degenerate segment"))
        tangents[i] = t
    end
    return tangents
end

function _extrude_shape_vertex_normals(shape::Vector{Vec2{Float64}})
    np = length(shape)
    edge_normals = Vector{Vec2{Float64}}(undef, np)
    @inbounds for i in 1:np
        p1 = shape[i]
        p2 = shape[mod1(i + 1, np)]
        dx, dy = _geometry_unit_delta2(p1.x, p1.y, p2.x, p2.y)
        (dx != 0.0 || dy != 0.0) ||
            throw(ArgumentError("ExtrudeGeometry shape contains degenerate edge"))
        edge_normals[i] = Vec2(dy, -dx)
    end
    normals = Vector{Vec2{Float64}}(undef, np)
    @inbounds for i in 1:np
        n = edge_normals[mod1(i - 1, np)] + edge_normals[i]
        normals[i] = _shape_len(n) > 1e-12 ? _shape_normalize(n) : edge_normals[i]
    end
    return normals
end

function _extrude_loops(outer::Vector{Vec2{Float64}}, holes::Vector{Vector{Vec2{Float64}}})
    isempty(holes) && return outer, UnitRange{Int}[1:length(outer)]
    shape = reduce(vcat, holes; init=copy(outer))
    ranges = UnitRange{Int}[1:length(outer)]
    for hole in holes
        push!(ranges, (last(ranges[end]) + 1):(last(ranges[end]) + length(hole)))
    end
    return shape, ranges
end

@inline _extrude_next(ranges::Vector{UnitRange{Int}}, k::Int, j::Int) =
    j == last(ranges[k]) ? first(ranges[k]) : j + 1

# Top-level rather than a closure over `moves`/`offsets`/`base`: Julia ≤ 1.10
# cannot infer captured variables, so each closure call boxed its Vec2 result
# (~4 KiB per extrusion). The same is true of `_extrude_write_vertex!`.
@inline function _extrude_layer_point(moves::Union{Nothing,Vector{Vec2{Float64}}},
                                      base::Vector{Vec2{Float64}},
                                      offsets::Vector{Float64}, l::Int, j::Int)
    return moves === nothing ? base[j] : base[j] + moves[j] * offsets[l]
end

@inline function _extrude_write_vertex!(positions::Vector{Float64},
                                        normals::Vector{Float64},
                                        uvs::Vector{Float64}, vi::Int,
                                        p::Vec2{Float64}, z::Float64,
                                        n::Vec3{Float64}, u::Float64, v::Float64)
    pbase = 3vi - 2
    positions[pbase] = p.x
    positions[pbase + 1] = p.y
    positions[pbase + 2] = z
    normals[pbase] = n.x
    normals[pbase + 1] = n.y
    normals[pbase + 2] = n.z
    uvs[2vi - 1] = u
    uvs[2vi] = v
    return nothing
end

function _extrude_path_geometry(shape_in::AbstractVector{<:Vec2},
                                path_in::AbstractVector{<:Vec3}, holes_in)
    outer = _extrude_clean_shape(shape_in)
    holes = _shape_clean_holes(holes_in)
    shape, ranges = _extrude_loops(outer, holes)
    path, closed, eps = _extrude_clean_path(path_in)
    tangents = _extrude_path_tangents(path, closed, eps)
    shape_normals = isempty(holes) ? _extrude_shape_vertex_normals(shape) :
        reduce(vcat, (_extrude_shape_vertex_normals(shape[r]) for r in ranges))
    cap_triangles = closed ? NTuple{3,Int}[] : _shape_triangulate(outer, holes)
    np = length(shape)
    nr = length(path)
    segments = closed ? nr : nr - 1
    ring_vertices = _geometry_checked_mul(
        nr, np, "ExtrudeGeometry path vertex count")
    cap_vertices = closed ? 0 :
                   _geometry_checked_mul(2, np, "ExtrudeGeometry cap vertex count")
    n_verts = _geometry_checked_add(
        ring_vertices, cap_vertices, "ExtrudeGeometry vertex count")
    side_faces = _geometry_checked_mul(
        _geometry_checked_mul(2, segments, "ExtrudeGeometry side face count"),
        np, "ExtrudeGeometry side face count")
    cap_faces = closed ? 0 :
                _geometry_checked_mul(
                    2, length(cap_triangles), "ExtrudeGeometry cap face count")
    n_faces = _geometry_checked_add(
        side_faces, cap_faces, "ExtrudeGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "ExtrudeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    T = tangents[1]
    refv = abs(T.y) < 0.99 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    N = normalize(cross(refv, T))
    B = cross(T, N)
    first_N = N
    first_B = B
    last_N = N
    last_B = B
    twist = 0.0
    if closed
        # Like three.js computeFrenetFrames(…, closed=true), spread the
        # transport holonomy over the loop so the wrap-around ring matches.
        Nt, Bt = N, B
        for i in 2:nr
            Nt, Bt = _tube_transport(Nt, Bt, tangents[i])
        end
        N_end, _ = _tube_transport(Nt, Bt, tangents[1])
        twist = acos(clamp(dot(N, N_end), -1.0, 1.0)) / nr
        dot(tangents[1], cross(N, N_end)) > 0 && (twist = -twist)
    end
    @inbounds for i in 1:nr
        T = tangents[i]
        if i > 1
            projected = N - T * dot(N, T)
            N = norm(projected) > eps ? normalize(projected) : normalize(cross(B, T))
            B = cross(T, N)
        end
        i == 1 && (first_N = N; first_B = B)
        i == nr && (last_N = N; last_B = B)
        Nr, Br = N, B
        if twist != 0.0
            Nr = _tube_rotate(N, T, twist * (i - 1))
            Br = cross(T, Nr)
        end
        for j in 1:np
            pt = shape[j]
            normal2 = shape_normals[j]
            p = path[i] + Nr * pt.x + Br * pt.y
            n = normalize(Nr * normal2.x + Br * normal2.y)
            _geometry_check_position(p.x, p.y, p.z, "ExtrudeGeometry")
            vi = (i - 1) * np + j
            pbase = 3vi - 2
            positions[pbase] = p.x
            positions[pbase + 1] = p.y
            positions[pbase + 2] = p.z
            normals[pbase] = n.x
            normals[pbase + 1] = n.y
            normals[pbase + 2] = n.z
            ubase = 2vi - 1
            uvs[ubase] = (i - 1) / max(nr - 1, 1)
            uvs[ubase + 1] = (j - 1) / np
        end
    end

    out = 1
    @inbounds for i in 1:segments
        i2 = i == nr ? 1 : i + 1
        for k in eachindex(ranges), j in ranges[k]
            j2 = _extrude_next(ranges, k, j)
            a = (i - 1) * np + j
            b = (i - 1) * np + j2
            c = (i2 - 1) * np + j2
            d = (i2 - 1) * np + j
            indices[out] = a
            indices[out + 1] = b
            indices[out + 2] = c
            indices[out + 3] = a
            indices[out + 4] = c
            indices[out + 5] = d
            out += 6
        end
    end

    if !closed
        start = nr * np
        cap_normal = -tangents[1]
        @inbounds for j in 1:np
            pt = shape[j]
            p = path[1] + first_N * pt.x + first_B * pt.y
            _geometry_check_position(p.x, p.y, p.z, "ExtrudeGeometry")
            vi = start + j
            pbase = 3vi - 2
            positions[pbase] = p.x
            positions[pbase + 1] = p.y
            positions[pbase + 2] = p.z
            normals[pbase] = cap_normal.x
            normals[pbase + 1] = cap_normal.y
            normals[pbase + 2] = cap_normal.z
            ubase = 2vi - 1
            uvs[ubase] = pt.x
            uvs[ubase + 1] = pt.y
        end
        @inbounds for (a, b, c) in cap_triangles
            indices[out] = start + a
            indices[out + 1] = start + c
            indices[out + 2] = start + b
            out += 3
        end

        start += np
        cap_normal = tangents[end]
        @inbounds for j in 1:np
            pt = shape[j]
            p = path[nr] + last_N * pt.x + last_B * pt.y
            _geometry_check_position(p.x, p.y, p.z, "ExtrudeGeometry")
            vi = start + j
            pbase = 3vi - 2
            positions[pbase] = p.x
            positions[pbase + 1] = p.y
            positions[pbase + 2] = p.z
            normals[pbase] = cap_normal.x
            normals[pbase + 1] = cap_normal.y
            normals[pbase + 2] = cap_normal.z
            ubase = 2vi - 1
            uvs[ubase] = pt.x
            uvs[ubase + 1] = pt.y
        end
        @inbounds for (a, b, c) in cap_triangles
            indices[out] = start + a
            indices[out + 1] = start + b
            indices[out + 2] = start + c
            out += 3
        end
    end

    return BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

"""
    ShapeGeometry(shape; holes=Vector{Vec2{Float64}}[], triangulation=:ear_clip)

Filled planar polygon at z = 0 with +z normals and world-space `(x, y)` UVs
(three.js `ShapeGeometry`). `holes` are polygons cut out of `shape`; they must
lie inside it without touching it or each other. Either winding is accepted for
the outline and the holes.

`triangulation=:ear_clip` (the default) triangulates with Diff3D's ear clipper:
the outline is stored counterclockwise, near-duplicate points are merged and
self-intersecting input is an error. `triangulation=:earcut` builds the
geometry exactly as three.js r186 `ShapeGeometry` does, with its Earcut port
(see [`earcut_triangulate`](@ref)): the outline is stored clockwise and holes
counterclockwise, exactly repeated consecutive points and a closing point equal
to the first are dropped, and the vertices, UVs and triangles equal three.js's.
Degenerate, touching or self-intersecting input is then triangulated as Earcut
does, which may give no triangles at all.
"""
function ShapeGeometry(shape::Vector{<:Vec2}; holes=Vector{Vec2{Float64}}[],
                       triangulation::Symbol=:ear_clip)
    _shape_triangulation(triangulation, "ShapeGeometry") === :earcut &&
        return _shape_geometry_earcut(shape, holes)
    outer = _extrude_clean_shape(shape)   # normalize to CCW (+z normal)
    hole_loops = _shape_clean_holes(holes)
    points, _ = _extrude_loops(outer, hole_loops)
    np = length(points)
    triangles = _shape_triangulate(outer, hole_loops)
    n_faces = length(triangles)
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(np, n_faces, "ShapeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    @inbounds for i in 1:np
        pt = points[i]
        pbase = 3i - 2
        positions[pbase] = pt.x
        positions[pbase + 1] = pt.y
        positions[pbase + 2] = 0.0
        normals[pbase] = 0.0
        normals[pbase + 1] = 0.0
        normals[pbase + 2] = 1.0
        ubase = 2i - 1
        uvs[ubase] = pt.x
        uvs[ubase + 1] = pt.y
    end
    out = 1
    @inbounds for (a, b, c) in triangles
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = c
        out += 3
    end
    BufferGeometry(positions, normals, uvs, indices, np, n_faces)
end

# three.js ExtrudeGeometry `getBevelVec`: the unnormalized move of `pt` onto
# the contour shifted one unit to the left when walking prev -> pt -> next.
function _extrude_bevel_vec(pt::Vec2{Float64}, prev::Vec2{Float64}, next::Vec2{Float64})
    vpx = pt.x - prev.x; vpy = pt.y - prev.y
    vnx = next.x - pt.x; vny = next.y - pt.y
    vp_lensq = vpx * vpx + vpy * vpy
    if abs(vpx * vny - vpy * vnx) > eps(Float64)
        vp_len = sqrt(vp_lensq)
        vn_len = sqrt(vnx * vnx + vny * vny)
        psx = prev.x - vpy / vp_len; psy = prev.y + vpx / vp_len
        nsx = next.x - vny / vn_len; nsy = next.y + vnx / vn_len
        sf = ((nsx - psx) * vny - (nsy - psy) * vnx) / (vpx * vny - vpy * vnx)
        tx = psx + vpx * sf - pt.x
        ty = psy + vpy * sf - pt.y
        tl = tx * tx + ty * ty
        tl <= 2 && return Vec2(tx, ty)
        shrink = sqrt(tl / 2)
    else
        same_direction = vpx > eps(Float64) ? vnx > eps(Float64) :
                         vpx < -eps(Float64) ? vnx < -eps(Float64) :
                         sign(vpy) == sign(vny)
        if same_direction
            tx = -vpy; ty = vpx; shrink = sqrt(vp_lensq)
        else
            tx = vpx; ty = vpy; shrink = sqrt(vp_lensq / 2)
        end
    end
    return Vec2(tx / shrink, ty / shrink)
end

# Our loops are stored reversed relative to three.js (CCW outer, CW holes), so
# its `prev`/`next` swap; the moves still point out of the solid.
function _extrude_bevel_vectors(points::Vector{Vec2{Float64}}, ranges::Vector{UnitRange{Int}})
    moves = Vector{Vec2{Float64}}(undef, length(points))
    for k in eachindex(ranges), j in ranges[k]
        prev = j == first(ranges[k]) ? last(ranges[k]) : j - 1
        moves[j] = _extrude_bevel_vec(points[j], points[_extrude_next(ranges, k, j)],
                                      points[prev])
    end
    return moves
end

"""
    ExtrudeGeometry(shape; depth=1.0, holes=Vector{Vec2{Float64}}[], steps=1,
                    bevel_enabled=false, bevel_thickness=0.2,
                    bevel_size=bevel_thickness - 0.1, bevel_offset=0.0,
                    bevel_segments=3, extrude_path=nothing,
                    triangulation=:ear_clip)

Extrude the planar polygon `shape`, minus optional `holes`, along +z from
`z = 0` to `depth` in `steps` slices (three.js `ExtrudeGeometry`). With
`bevel_enabled=true` both caps are beveled: `bevel_segments` layers spread over
`bevel_thickness` beyond each cap grow the outline by up to `bevel_size`,
starting `bevel_offset` from it (three.js `getBevelVec` offsets). Caps use
world `(x, y)` UVs and side walls three.js `WorldUVGenerator` UVs. With
`extrude_path` the profile is swept along that polyline instead; as in three.js
path extrusion, bevels are not applied there and every path point is a step.

Unlike three.js, `bevel_enabled` defaults to `false`.

`triangulation=:earcut` builds the geometry exactly as three.js r186
`ExtrudeGeometry` does, triangulating the caps with its Earcut port
([`earcut_triangulate`](@ref)): an unindexed triangle list (`indices` is
`1:n`) in three.js's vertex order, `WorldUVGenerator` UVs and the flat normals
of `computeVertexNormals`, with three.js's handling of degenerate input (see
[`ShapeGeometry`](@ref)). three.js's two draw groups are not added. In that
mode `extrude_path` must be a 3D [`Curve`](@ref), sampled as three.js does by
`get_spaced_points(extrude_path, steps)` with [`compute_frenet_frames`](@ref)
(closed only for a closed [`CatmullRomCurve`](@ref)); both caps are kept and
bevels are disabled.
"""
function ExtrudeGeometry(shape::Vector{<:Vec2}; depth=1.0, extrude_path=nothing,
                         holes=Vector{Vec2{Float64}}[], steps=1,
                         bevel_enabled::Bool=false, bevel_thickness=0.2,
                         bevel_size=nothing, bevel_offset=0.0, bevel_segments=3,
                         triangulation::Symbol=:ear_clip)
    if _shape_triangulation(triangulation, "ExtrudeGeometry") === :earcut
        extrude_path === nothing || extrude_path isa Curve{Vec3{Float64}} ||
            throw(ArgumentError("ExtrudeGeometry with triangulation=:earcut needs " *
                                "extrude_path to be a 3D Curve, as in three.js"))
        opt = _extrude_threejs_options(depth, steps, bevel_enabled, bevel_thickness,
                                       bevel_size, bevel_offset, bevel_segments)
        outer = _earcut_path_points(shape, "ExtrudeGeometry shape points")
        hole_loops = Vector{Vec2{Float64}}[_earcut_path_points(h, "ExtrudeGeometry hole points")
                                           for h in holes]
        return _extrude_threejs_geometry(((outer, hole_loops),), opt, extrude_path)
    end
    extrude_path !== nothing && return _extrude_path_geometry(shape, extrude_path, holes)
    depth = _geometry_finite_float(depth, "ExtrudeGeometry depth")
    steps = _geometry_positive_int(steps, "ExtrudeGeometry steps")
    thickness = _geometry_finite_float(bevel_thickness, "ExtrudeGeometry bevel_thickness")
    size = bevel_size === nothing ? thickness - 0.1 :
           _geometry_finite_float(bevel_size, "ExtrudeGeometry bevel_size")
    offset = _geometry_finite_float(bevel_offset, "ExtrudeGeometry bevel_offset")
    nb = _geometry_nonnegative_int(bevel_segments, "ExtrudeGeometry bevel_segments")
    if !bevel_enabled
        nb = 0; thickness = 0.0; size = 0.0; offset = 0.0
    end
    # Normalize to CCW (like the extrude_path branch) so the hard-coded cap and
    # side-wall normals stay consistent with the winding for any input orientation.
    outer = _extrude_clean_shape(shape)
    hole_loops = _shape_clean_holes(holes)
    base, ranges = _extrude_loops(outer, hole_loops)
    np = length(base)
    moves = bevel_enabled ? _extrude_bevel_vectors(base, ranges) : nothing

    # Vertex layers bottom to top: bevel rings, `steps + 1` body rings, bevel rings.
    layers = steps + 2nb + 1
    zs = Vector{Float64}(undef, layers)
    offsets = Vector{Float64}(undef, layers)
    for b in 0:nb-1
        t = b / nb
        zs[b + 1] = -thickness * cos(t * π / 2)
        offsets[b + 1] = size * sin(t * π / 2) + offset
        zs[layers - b] = depth + thickness * cos(t * π / 2)
        offsets[layers - b] = offsets[b + 1]
    end
    for s in 0:steps
        zs[nb + s + 1] = depth / steps * s
        offsets[nb + s + 1] = size + offset
    end
    cap_triangles = if moves === nothing || iszero(offsets[1])
        _shape_triangulate(outer, hole_loops)
    else
        cap = [_extrude_layer_point(moves, base, offsets, 1, j) for j in 1:np]
        _shape_triangulate(cap[ranges[1]], [cap[r] for r in ranges[2:end]])
    end
    n_side_quads = _geometry_checked_mul(np, layers - 1, "ExtrudeGeometry face count")
    n_verts = _geometry_checked_add(
        _geometry_checked_mul(2, np, "ExtrudeGeometry vertex count"),
        _geometry_checked_mul(4, n_side_quads, "ExtrudeGeometry vertex count"),
        "ExtrudeGeometry vertex count")
    n_faces = _geometry_checked_add(
        _geometry_checked_mul(2, length(cap_triangles), "ExtrudeGeometry face count"),
        _geometry_checked_mul(2, n_side_quads, "ExtrudeGeometry face count"),
        "ExtrudeGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "ExtrudeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    @inbounds for j in 1:np
        front = _extrude_layer_point(moves, base, offsets, 1, j)
        back = _extrude_layer_point(moves, base, offsets, layers, j)
        _extrude_write_vertex!(positions, normals, uvs, j, front, zs[1],
                               Vec3(0.0, 0.0, -1.0), front.x, front.y)
        _extrude_write_vertex!(positions, normals, uvs, np + j, back, zs[layers],
                               Vec3(0.0, 0.0, 1.0), back.x, back.y)
    end

    out = 1
    @inbounds for (a, b, c) in cap_triangles
        indices[out] = a
        indices[out + 1] = c
        indices[out + 2] = b
        indices[out + 3] = np + a
        indices[out + 4] = np + b
        indices[out + 5] = np + c
        out += 6
    end
    vi = 2 * np
    @inbounds for k in eachindex(ranges), i in ranges[k]
        i2 = _extrude_next(ranges, k, i)
        for l in 1:layers-1
            p1 = _extrude_layer_point(moves, base, offsets, l, i)
            p2 = _extrude_layer_point(moves, base, offsets, l, i2)
            q1 = _extrude_layer_point(moves, base, offsets, l + 1, i)
            q2 = _extrude_layer_point(moves, base, offsets, l + 1, i2)
            z1 = zs[l]; z2 = zs[l + 1]
            n = if offsets[l] == offsets[l + 1]
                ex, ey = _geometry_unit_delta2(p1.x, p1.y, p2.x, p2.y)
                # Follow the quad winding like three.js computeVertexNormals: a
                # negative depth turns the wall inside out, normal included.
                z2 < z1 ? Vec3(-ey, ex, 0.0) : Vec3(ey, -ex, 0.0)
            else
                # Bevel quad: the normalized cross product of its diagonals. The
                # quad is planar only when both corner moves are parallel to the
                # edge (e.g. a rectangle); otherwise this is the quad's average
                # normal, a few degrees off each triangle's own. three.js gives
                # each triangle its flat normal (`triangulation=:earcut`).
                normalize(cross(Vec3(q2.x - p1.x, q2.y - p1.y, z2 - z1),
                                Vec3(q1.x - p2.x, q1.y - p2.y, z2 - z1)))
            end
            # three.js WorldUVGenerator.generateSideWallUV
            use_x = abs(p1.y - p2.y) < abs(p1.x - p2.x)
            _extrude_write_vertex!(positions, normals, uvs, vi + 1, p1, z1, n,
                                   use_x ? p1.x : p1.y, 1 - z1)
            _extrude_write_vertex!(positions, normals, uvs, vi + 2, p2, z1, n,
                                   use_x ? p2.x : p2.y, 1 - z1)
            _extrude_write_vertex!(positions, normals, uvs, vi + 3, q2, z2, n,
                                   use_x ? q2.x : q2.y, 1 - z2)
            _extrude_write_vertex!(positions, normals, uvs, vi + 4, q1, z2, n,
                                   use_x ? q1.x : q1.y, 1 - z2)
            indices[out] = vi + 1
            indices[out + 1] = vi + 2
            indices[out + 2] = vi + 3
            indices[out + 3] = vi + 1
            indices[out + 4] = vi + 3
            indices[out + 5] = vi + 4
            out += 6
            vi += 4
        end
    end
    BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

# ---- three.js r186 construction with Earcut (`triangulation=:earcut`) ----

const _SHAPE_TRIANGULATIONS = (:ear_clip, :earcut)

function _shape_triangulation(value::Symbol, label::String)
    value in _SHAPE_TRIANGULATIONS ||
        throw(ArgumentError("$label triangulation must be :ear_clip or :earcut"))
    return value
end

# The points three.js samples from `new Shape(points)` / `new Path(points)`:
# Path.setFromPoints builds line curves and CurvePath.getPoints drops exactly
# repeated consecutive points (CurvePath.js:197-201); one point makes no curve.
function _earcut_path_points(points::AbstractVector{<:Vec2}, label::String)
    out = Vec2{Float64}[]
    length(points) >= 2 || return out
    sizehint!(out, length(points))
    for p in points
        q = Vec2{Float64}(_geometry_finite_float(p.x, label), _geometry_finite_float(p.y, label))
        (!isempty(out) && out[end] == q) && continue
        push!(out, q)
    end
    return out
end

# ShapeUtils.area / isClockWise (ShapeUtils.js:16-43).
function _shape_utils_area(contour::Vector{Vec2{Float64}})
    n = length(contour)
    a = 0.0
    p = n
    @inbounds for q in 1:n
        a += contour[p].x * contour[q].y - contour[q].x * contour[p].y
        p = q
    end
    return a * 0.5
end
_shape_utils_is_clockwise(points::Vector{Vec2{Float64}}) = _shape_utils_area(points) < 0

# ShapeUtils.triangulateShape (ShapeUtils.js:52-93): drops a closing point
# equal to the first from `contour` and each hole IN PLACE, as three.js does,
# then returns Earcut's 0-based vertex indices, three per triangle.
function _shape_utils_triangulate!(contour::Vector{Vec2{Float64}},
                                   holes::Vector{Vector{Vec2{Float64}}})
    _shape_remove_dup_end!(contour)
    foreach(_shape_remove_dup_end!, holes)
    total = length(contour) + sum(length, holes; init=0)
    data = Vector{Float64}(undef, 2total)
    k = 0
    for loop in (contour, holes...)
        @inbounds for p in loop
            data[k + 1] = p.x
            data[k + 2] = p.y
            k += 2
        end
    end
    starts = Vector{Int}(undef, length(holes))
    hole_start = length(contour)
    for (h, hole) in enumerate(holes)
        isempty(hole) && throw(ArgumentError("shape hole $h has no points"))
        starts[h] = hole_start
        hole_start += length(hole)
    end
    return _earcut(data, starts, 2)
end

function _shape_remove_dup_end!(points::Vector{Vec2{Float64}})
    l = length(points)
    (l > 2 && points[l] == points[1]) && pop!(points)
    return points
end

# three.js ShapeGeometry addShape (ShapeGeometry.js:85-140) for one shape.
function _shape_geometry_earcut(shape::AbstractVector{<:Vec2}, holes_in)
    outer = _earcut_path_points(shape, "ShapeGeometry shape points")
    holes = Vector{Vec2{Float64}}[_earcut_path_points(h, "ShapeGeometry hole points")
                                  for h in holes_in]
    _shape_utils_is_clockwise(outer) || reverse!(outer)
    for hole in holes
        _shape_utils_is_clockwise(hole) && reverse!(hole)
    end
    faces = _shape_utils_triangulate!(outer, holes)
    np = length(outer) + sum(length, holes; init=0)
    n_faces = length(faces) ÷ 3
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(np, n_faces, "ShapeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    i = 0
    for loop in (outer, holes...)
        @inbounds for pt in loop
            i += 1
            positions[3i - 2] = pt.x
            positions[3i - 1] = pt.y
            positions[3i] = 0.0
            normals[3i - 2] = 0.0
            normals[3i - 1] = 0.0
            normals[3i] = 1.0
            uvs[2i - 1] = pt.x
            uvs[2i] = pt.y
        end
    end
    indices = faces
    indices .+= 1
    return BufferGeometry(positions, normals, uvs, indices, np, n_faces)
end

# ExtrudeGeometry.js mergeOverlappingPoints (lines 214-252), in place. The
# wrap-around step compares the first point with the last kept one.
function _extrude_merge_overlapping!(points::Vector{Vec2{Float64}})
    isempty(points) && return points
    threshold = 1e-10
    threshold_sq = threshold * threshold
    prev = points[1]
    i = 1
    while i <= length(points)
        current_index = i % length(points)
        current = points[current_index + 1]
        dx = current.x - prev.x
        dy = current.y - prev.y
        dist_sq = dx * dx + dy * dy
        scaling = max(abs(current.x), abs(current.y), abs(prev.x), abs(prev.y))
        if dist_sq <= threshold_sq * scaling * scaling
            deleteat!(points, current_index + 1)
            continue
        end
        prev = current
        i += 1
    end
    return points
end

# ExtrudeGeometry.js getBevelVec (lines 291-399) in three.js's own orientation
# (outer contour clockwise). Returns the translation for `pt`.
function _extrude_threejs_bevel_vec(pt::Vec2{Float64}, prev::Vec2{Float64}, next::Vec2{Float64})
    v_prev_x = pt.x - prev.x
    v_prev_y = pt.y - prev.y
    v_next_x = next.x - pt.x
    v_next_y = next.y - pt.y
    v_prev_lensq = v_prev_x * v_prev_x + v_prev_y * v_prev_y
    collinear0 = v_prev_x * v_next_y - v_prev_y * v_next_x
    if abs(collinear0) > eps(Float64)
        v_prev_len = sqrt(v_prev_lensq)
        v_next_len = sqrt(v_next_x * v_next_x + v_next_y * v_next_y)
        prev_shift_x = prev.x - v_prev_y / v_prev_len
        prev_shift_y = prev.y + v_prev_x / v_prev_len
        next_shift_x = next.x - v_next_y / v_next_len
        next_shift_y = next.y + v_next_x / v_next_len
        sf = ((next_shift_x - prev_shift_x) * v_next_y -
              (next_shift_y - prev_shift_y) * v_next_x) /
             (v_prev_x * v_next_y - v_prev_y * v_next_x)
        v_trans_x = prev_shift_x + v_prev_x * sf - pt.x
        v_trans_y = prev_shift_y + v_prev_y * sf - pt.y
        v_trans_lensq = v_trans_x * v_trans_x + v_trans_y * v_trans_y
        v_trans_lensq <= 2 && return Vec2(v_trans_x, v_trans_y)
        shrink_by = sqrt(v_trans_lensq / 2)
    else
        direction_eq = if v_prev_x > eps(Float64)
            v_next_x > eps(Float64)
        elseif v_prev_x < -eps(Float64)
            v_next_x < -eps(Float64)
        else
            sign(v_prev_y) == sign(v_next_y)
        end
        if direction_eq
            v_trans_x = -v_prev_y
            v_trans_y = v_prev_x
            shrink_by = sqrt(v_prev_lensq)
        else
            v_trans_x = v_prev_x
            v_trans_y = v_prev_y
            shrink_by = sqrt(v_prev_lensq / 2)
        end
    end
    return Vec2(v_trans_x / shrink_by, v_trans_y / shrink_by)
end

function _extrude_threejs_movements(loop::Vector{Vec2{Float64}})
    n = length(loop)
    moves = Vector{Vec2{Float64}}(undef, n)
    @inbounds for i in 1:n
        j = i == 1 ? n : i - 1
        k = i == n ? 1 : i + 1
        moves[i] = _extrude_threejs_bevel_vec(loop[i], loop[j], loop[k])
    end
    return moves
end

# scalePt2: pt.clone().addScaledVector(vec, size)
@inline _extrude_scale_pt(pt::Vec2{Float64}, vec::Vec2{Float64}, size::Float64) =
    Vec2(pt.x + vec.x * size, pt.y + vec.y * size)

# Non-indexed computeVertexNormals (BufferGeometry.js:780-817): each triangle's
# (C - B) x (A - B), normalized with `length() || 1`.
function _threejs_flat_normals!(normals::Vector{Float64}, positions::Vector{Float64})
    @inbounds for t in 0:(length(positions) ÷ 9 - 1)
        o = 9t
        ax = positions[o + 1]; ay = positions[o + 2]; az = positions[o + 3]
        bx = positions[o + 4]; by = positions[o + 5]; bz = positions[o + 6]
        cx = positions[o + 7]; cy = positions[o + 8]; cz = positions[o + 9]
        cbx = cx - bx; cby = cy - by; cbz = cz - bz
        abx = ax - bx; aby = ay - by; abz = az - bz
        nx = cby * abz - cbz * aby
        ny = cbz * abx - cbx * abz
        nz = cbx * aby - cby * abx
        len = sqrt(nx * nx + ny * ny + nz * nz)
        inv = 1 / (iszero(len) ? 1.0 : len)
        nx *= inv; ny *= inv; nz *= inv
        for v in 0:2
            normals[o + 3v + 1] = nx
            normals[o + 3v + 2] = ny
            normals[o + 3v + 3] = nz
        end
    end
    return normals
end

@inline function _extrude_add_vertex!(positions::Vector{Float64}, placeholder::Vector{Float64},
                                      index::Int)
    @inbounds push!(positions, placeholder[3index + 1], placeholder[3index + 2],
                    placeholder[3index + 3])
    return nothing
end

# ExtrudeGeometry.js f3 with WorldUVGenerator.generateTopUV: the vertices' (x, y).
function _extrude_f3!(positions::Vector{Float64}, uvs::Vector{Float64},
                      placeholder::Vector{Float64}, a::Int, b::Int, c::Int)
    start = length(positions)
    _extrude_add_vertex!(positions, placeholder, a)
    _extrude_add_vertex!(positions, placeholder, b)
    _extrude_add_vertex!(positions, placeholder, c)
    @inbounds for v in 0:2
        push!(uvs, positions[start + 3v + 1], positions[start + 3v + 2])
    end
    return nothing
end

# ExtrudeGeometry.js f4 (triangles a-b-d and b-c-d) with
# WorldUVGenerator.generateSideWallUV on A, the second B, C and D.
function _extrude_f4!(positions::Vector{Float64}, uvs::Vector{Float64},
                      placeholder::Vector{Float64}, a::Int, b::Int, c::Int, d::Int)
    start = length(positions)
    for index in (a, b, d, b, c, d)
        _extrude_add_vertex!(positions, placeholder, index)
    end
    @inbounds begin
        ia = start; ib = start + 9; ic = start + 12; id = start + 15
        use_x = abs(positions[ia + 2] - positions[ib + 2]) <
                abs(positions[ia + 1] - positions[ib + 1])
        o = use_x ? 1 : 2
        ua1 = positions[ia + o]; ua2 = 1 - positions[ia + 3]
        ub1 = positions[ib + o]; ub2 = 1 - positions[ib + 3]
        uc1 = positions[ic + o]; uc2 = 1 - positions[ic + 3]
        ud1 = positions[id + o]; ud2 = 1 - positions[id + 3]
        push!(uvs, ua1, ua2, ub1, ub2, ud1, ud2, ub1, ub2, uc1, uc2, ud1, ud2)
    end
    return nothing
end

struct _ExtrudeThreeOptions
    depth::Float64
    steps::Int
    bevel_enabled::Bool
    bevel_thickness::Float64
    bevel_size::Float64
    bevel_offset::Float64
    bevel_segments::Int
end

# three.js ExtrudeGeometry addShape (ExtrudeGeometry.js:117-760) for one shape
# given as the points of `shape.extractPoints(curveSegments)`. `path_points` and
# `frames` are `extrudePath.getSpacedPoints(steps)` and its Frenet frames, or
# `nothing`. Appends three.js's unindexed positions and UVs.
function _extrude_threejs_shape!(positions::Vector{Float64}, uvs::Vector{Float64},
                                 shape_points::Vector{Vec2{Float64}},
                                 hole_points::Vector{Vector{Vec2{Float64}}},
                                 opt::_ExtrudeThreeOptions, path_points, frames)
    steps = opt.steps
    depth = opt.depth
    by_path = path_points !== nothing
    bevel_enabled = opt.bevel_enabled && !by_path
    bevel_segments = bevel_enabled ? opt.bevel_segments : 0
    bevel_thickness = bevel_enabled ? opt.bevel_thickness : 0.0
    bevel_size = bevel_enabled ? opt.bevel_size : 0.0
    bevel_offset = bevel_enabled ? opt.bevel_offset : 0.0

    contour = copy(shape_points)
    holes = [copy(h) for h in hole_points]
    if !_shape_utils_is_clockwise(contour)
        reverse!(contour)
        for hole in holes
            _shape_utils_is_clockwise(hole) && reverse!(hole)
        end
    end
    _extrude_merge_overlapping!(contour)
    foreach(_extrude_merge_overlapping!, holes)
    vertices = reduce(vcat, holes; init=copy(contour))
    vlen = length(vertices)

    contour_moves = _extrude_threejs_movements(contour)
    hole_moves = [_extrude_threejs_movements(hole) for hole in holes]
    vertex_moves = reduce(vcat, hole_moves; init=copy(contour_moves))

    layers = steps + 1 + 2bevel_segments
    placeholder = Float64[]
    sizehint!(placeholder, 3 * _geometry_checked_mul(vlen, layers, "ExtrudeGeometry vertex count"))
    faces = if bevel_segments == 0
        _shape_utils_triangulate!(contour, holes)
    else
        contracted = Vec2{Float64}[]
        expanded = Vector{Vec2{Float64}}[]
        for b in 0:(bevel_segments - 1)
            t = b / bevel_segments
            z = bevel_thickness * cos(t * π / 2)
            bs = bevel_size * sin(t * π / 2) + bevel_offset
            for i in eachindex(contour)
                vert = _extrude_scale_pt(contour[i], contour_moves[i], bs)
                push!(placeholder, vert.x, vert.y, -z)
                t == 0 && push!(contracted, vert)
            end
            for h in eachindex(holes)
                one = Vec2{Float64}[]
                for i in eachindex(holes[h])
                    vert = _extrude_scale_pt(holes[h][i], hole_moves[h][i], bs)
                    push!(placeholder, vert.x, vert.y, -z)
                    t == 0 && push!(one, vert)
                end
                t == 0 && push!(expanded, one)
            end
        end
        _shape_utils_triangulate!(contracted, expanded)
    end
    bs = bevel_size + bevel_offset
    for s in 0:steps
        for i in 1:vlen
            vert = bevel_enabled ? _extrude_scale_pt(vertices[i], vertex_moves[i], bs) : vertices[i]
            if by_path
                n = frames.normals[s + 1]
                b = frames.binormals[s + 1]
                p = path_points[s + 1]
                push!(placeholder, p.x + n.x * vert.x + b.x * vert.y,
                        p.y + n.y * vert.x + b.y * vert.y,
                        p.z + n.z * vert.x + b.z * vert.y)
            else
                push!(placeholder, vert.x, vert.y, s == 0 ? 0.0 : depth / steps * s)
            end
        end
    end
    # Top bevel layers. three.js's path branch inside this loop is unreachable:
    # bevels are disabled for path extrusion, so `bevel_segments` is 0 there.
    for b in (bevel_segments - 1):-1:0
        t = b / bevel_segments
        z = bevel_thickness * cos(t * π / 2)
        bs_layer = bevel_size * sin(t * π / 2) + bevel_offset
        for i in eachindex(contour)
            vert = _extrude_scale_pt(contour[i], contour_moves[i], bs_layer)
            push!(placeholder, vert.x, vert.y, depth + z)
        end
        for h in eachindex(holes), i in eachindex(holes[h])
            vert = _extrude_scale_pt(holes[h][i], hole_moves[h][i], bs_layer)
            push!(placeholder, vert.x, vert.y, depth + z)
        end
    end

    flen = length(faces) ÷ 3
    if bevel_enabled
        offset = 0
        for f in 0:(flen - 1)
            _extrude_f3!(positions, uvs, placeholder, faces[3f + 3] + offset, faces[3f + 2] + offset, faces[3f + 1] + offset)
        end
        offset = vlen * (steps + 2bevel_segments)
        for f in 0:(flen - 1)
            _extrude_f3!(positions, uvs, placeholder, faces[3f + 1] + offset, faces[3f + 2] + offset, faces[3f + 3] + offset)
        end
    else
        for f in 0:(flen - 1)
            _extrude_f3!(positions, uvs, placeholder, faces[3f + 3], faces[3f + 2], faces[3f + 1])
        end
        offset = vlen * steps
        for f in 0:(flen - 1)
            _extrude_f3!(positions, uvs, placeholder, faces[3f + 1] + offset, faces[3f + 2] + offset, faces[3f + 3] + offset)
        end
    end
    sl = steps + 2bevel_segments
    layer_offset = 0
    for loop in (contour, holes...)
        len = length(loop)
        for i in (len - 1):-1:0
            j = i
            k = i - 1
            k < 0 && (k = len - 1)
            for s in 0:(sl - 1)
                slen1 = vlen * s
                slen2 = vlen * (s + 1)
                _extrude_f4!(positions, uvs, placeholder, layer_offset + j + slen1, layer_offset + k + slen1,
                    layer_offset + k + slen2, layer_offset + j + slen2)
            end
        end
        layer_offset += len
    end
    return nothing
end

function _extrude_threejs_options(depth, steps, bevel_enabled::Bool, bevel_thickness,
                                  bevel_size, bevel_offset, bevel_segments)
    thickness = _geometry_finite_float(bevel_thickness, "ExtrudeGeometry bevel_thickness")
    return _ExtrudeThreeOptions(
        _geometry_finite_float(depth, "ExtrudeGeometry depth"),
        _geometry_positive_int(steps, "ExtrudeGeometry steps"),
        bevel_enabled, thickness,
        bevel_size === nothing ? thickness - 0.1 :
            _geometry_finite_float(bevel_size, "ExtrudeGeometry bevel_size"),
        _geometry_finite_float(bevel_offset, "ExtrudeGeometry bevel_offset"),
        _geometry_nonnegative_int(bevel_segments, "ExtrudeGeometry bevel_segments"))
end

# `extrudePath.getSpacedPoints(steps)` and `computeFrenetFrames(steps, closed)`,
# closed only for a closed CatmullRomCurve (ExtrudeGeometry.js:148-160).
function _extrude_curve_samples(path::Curve{Vec3{Float64}}, steps::Int)
    closed = path isa CatmullRomCurve ? path.closed : false
    return get_spaced_points(path, steps), compute_frenet_frames(path, steps, closed)
end

function _extrude_threejs_geometry(shapes, opt::_ExtrudeThreeOptions, extrude_path)
    path_points, frames = extrude_path === nothing ? (nothing, nothing) :
                          _extrude_curve_samples(extrude_path, opt.steps)
    positions = Float64[]
    uvs = Float64[]
    for (shape_points, hole_points) in shapes
        _extrude_threejs_shape!(positions, uvs, shape_points, hole_points, opt,
                                path_points, frames)
    end
    all(isfinite, positions) || _geometry_position_range_error("ExtrudeGeometry")
    n = length(positions) ÷ 3
    normals = _threejs_flat_normals!(similar(positions), positions)
    return BufferGeometry(positions, normals, uvs, collect(1:n), n, n ÷ 3)
end

# ========================== CapsuleGeometry ==========================
# Cylinder of `length` capped by two hemispheres of `radius`, revolved about y.

function CapsuleGeometry(; radius=1.0, length=1.0, cap_segments=4, radial_segments=8,
                         height_segments=1)
    radius = _geometry_finite_float(radius, "CapsuleGeometry radius")
    length = max(0.0, _geometry_finite_float(length, "CapsuleGeometry length"))
    _geometry_check_abs_sum(length * 0.5, radius, "CapsuleGeometry")
    # clamp so 0 can't make i/cap_segments or s/radial_segments a 0/0 = NaN
    cap_segments = _clamp_seg(cap_segments, 1, "CapsuleGeometry cap_segments")
    radial_segments = _clamp_seg(radial_segments, 3, "CapsuleGeometry radial_segments")
    height_segments = _clamp_seg(height_segments, 1, "CapsuleGeometry height_segments")
    half = length / 2
    rows = _geometry_checked_add(
        _geometry_checked_mul(2, cap_segments, "CapsuleGeometry row count"),
        height_segments, "CapsuleGeometry row count")
    row = radial_segments + 1
    n_verts = _geometry_checked_mul(row, rows + 1, "CapsuleGeometry vertex count")
    n_faces = _geometry_checked_mul(
        2 * radial_segments, rows, "CapsuleGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "CapsuleGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    # three.js measures v by arc length; scale first so huge capsules stay finite.
    scale = max(abs(radius), length)
    cap_arc = scale > 0 ? (π / 2) * (radius / scale) : 0.0
    body_arc = scale > 0 ? length / scale : 0.0
    total_arc = 2cap_arc + body_arc
    @inbounds for iy in 0:rows
        if iy <= cap_segments
            t = iy / cap_segments
            angle = t * (π / 2)
            profile_y = -half - radius * cos(angle)
            profile_r = radius * sin(angle)
            normal_y = -radius * cos(angle)
            arc = t * cap_arc
        elseif iy <= cap_segments + height_segments
            t = (iy - cap_segments) / height_segments
            profile_y = -half + t * length
            profile_r = radius
            normal_y = 0.0
            arc = cap_arc + t * body_arc
        else
            t = (iy - cap_segments - height_segments) / cap_segments
            angle = t * (π / 2)
            profile_y = half + radius * sin(angle)
            profile_r = radius * cos(angle)
            normal_y = radius * sin(angle)
            arc = cap_arc + body_arc + t * cap_arc
        end
        v = total_arc != 0 ? clamp(arc / total_arc, 0.0, 1.0) : iy / rows
        u_offset = iy == 0 ? 0.5 / radial_segments :
                   iy == rows ? -0.5 / radial_segments : 0.0
        for ix in 0:radial_segments
            u = ix / radial_segments
            theta = u * 2π
            x = -profile_r * cos(theta)
            z = profile_r * sin(theta)
            nx = x; ny = normal_y; nz = z
            nl = hypot(nx, ny, nz); nl > 0 && (nx/=nl; ny/=nl; nz/=nl)
            vi = iy * row + ix + 1
            pbase = 3vi - 2
            positions[pbase] = x
            positions[pbase + 1] = profile_y
            positions[pbase + 2] = z
            normals[pbase] = nx
            normals[pbase + 1] = ny
            normals[pbase + 2] = nz
            ubase = 2vi - 1
            uvs[ubase] = u + u_offset
            uvs[ubase + 1] = v
        end
    end
    out = 1
    @inbounds for iy in 1:rows, ix in 0:radial_segments-1
        i1 = (iy - 1) * row + ix + 1
        i2 = i1 + 1
        i3 = iy * row + ix + 1
        i4 = i3 + 1
        indices[out] = i1
        indices[out + 1] = i2
        indices[out + 2] = i3
        indices[out + 3] = i2
        indices[out + 4] = i4
        indices[out + 5] = i3
        out += 6
    end
    BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

# ========================== Edges / Wireframe ==========================

const _EDGE_KEY32_MAX = Int64(typemax(UInt32))

@inline function _edge_key(::Type{UInt64}, a::Int, b::Int)::UInt64
    lo, hi = a < b ? (a, b) : (b, a)
    return (UInt64(lo) << 32) | UInt64(hi)
end

@inline function _edge_key(::Type{UInt128}, a::Int, b::Int)::UInt128
    lo, hi = a < b ? (a, b) : (b, a)
    return (UInt128(lo) << 64) | UInt128(hi)
end

@inline _edge_key_first(key::UInt64) = Int(key >> 32)
@inline _edge_key_second(key::UInt64) = Int(key & UInt64(0xffffffff))
@inline _edge_key_first(key::UInt128) = Int(key >> 64)
@inline _edge_key_second(key::UInt128) = Int(key & UInt128(typemax(UInt64)))

@inline function _edge_table_capacity(max_edges::Int)
    return max(16, nextpow(2, max_edges + max(16, max_edges >>> 2)))
end

@inline function _edge_record_hint(geo::BufferGeometry, max_edges::Int)
    return min(max_edges, max(16, geo.n_vertices + geo.n_faces))
end

@inline function _record_wireframe_edge!(
    seen::Vector{K}, ordered_edges::Vector{K}, a::Int, b::Int,
) where {K<:Union{UInt64,UInt128}}
    key = _edge_key(K, a, b)
    mask = length(seen) - 1
    idx = Int(hash(key) & UInt(mask)) + 1
    while true
        existing = seen[idx]
        if existing == zero(K)
            seen[idx] = key
            push!(ordered_edges, key)
            return nothing
        elseif existing == key
            return nothing
        end
        idx = idx == length(seen) ? 1 : idx + 1
    end
end

@inline _directed_edge_key(::Type{UInt64}, a::Int, b::Int)::UInt64 =
    (UInt64(a) << 32) | UInt64(b)
@inline _directed_edge_key(::Type{UInt128}, a::Int, b::Int)::UInt128 =
    (UInt128(a) << 64) | UInt128(b)

# Slot of `key` in an open-addressed power-of-two table whose empty slots hold
# zero, or the empty slot where `key` belongs. Keys are never zero because
# vertex ids start at one.
@inline function _edge_table_slot(keys::Vector{K}, key::K) where {K<:Union{UInt64,UInt128}}
    last_slot = length(keys)
    slot = Int(hash(key) & UInt(last_slot - 1)) + 1
    @inbounds while true
        existing = keys[slot]
        (existing == zero(K) || existing == key) && return slot
        slot = slot == last_slot ? 1 : slot + 1
    end
end

function _wireframe_edge_keys(geo::BufferGeometry, faces,
                               ::Type{K},
                               vertex_ids::Union{Nothing,Vector{Int}}=nothing,
                               ) where {K<:Union{UInt64,UInt128}}
    max_edges = 3 * length(faces)
    seen = zeros(K, _edge_table_capacity(max_edges))
    ordered_edges = Vector{K}()
    sizehint!(ordered_edges, _edge_record_hint(geo, max_edges))
    @inbounds for fi in faces
        i1, i2, i3 = get_face(geo, fi)
        if vertex_ids !== nothing
            i1 = vertex_ids[i1]
            i2 = vertex_ids[i2]
            i3 = vertex_ids[i3]
        end
        _record_wireframe_edge!(seen, ordered_edges, i1, i2)
        _record_wireframe_edge!(seen, ordered_edges, i2, i3)
        _record_wireframe_edge!(seen, ordered_edges, i3, i1)
    end
    return ordered_edges
end

# Exact position of a vertex as a hash key; `+ 0.0` folds -0.0 into 0.0, as
# three.js's `${x}` string hashes do.
@inline function _wireframe_position_key(geo::BufferGeometry, vi::Int)
    base = 3vi - 2
    @inbounds return (geo.positions[base] + 0.0, geo.positions[base + 1] + 0.0,
                      geo.positions[base + 2] + 0.0)
end

# Map every vertex to the first vertex with exactly the same position
# (three.js WireframeGeometry `isUniqueEdge` hashes edges by position).
function _wireframe_position_ids(geo::BufferGeometry)
    n = geo.n_vertices
    ids = Vector{Int}(undef, n)
    table = zeros(Int, _edge_table_capacity(n))
    last_slot = length(table)
    mask = last_slot - 1
    @inbounds for vi in 1:n
        key = _wireframe_position_key(geo, vi)
        slot = Int(hash(key) & UInt(mask)) + 1
        while true
            existing = table[slot]
            if existing == 0
                table[slot] = vi
                ids[vi] = vi
                break
            elseif isequal(_wireframe_position_key(geo, existing), key)
                ids[vi] = existing
                break
            end
            slot = slot == last_slot ? 1 : slot + 1
        end
    end
    return ids
end

# Face ranges visited by `wireframe_geometry`: the draw groups when present
# (WireframeGeometry.js:51-57), otherwise every face (as a tuple, so the
# common case allocates no range list).
function _wireframe_face_ranges(geo::BufferGeometry)
    isempty(geo.groups) && return (1:geo.n_faces,)
    return _group_face_ranges(geo, "wireframe_geometry")
end

# Writes the segment from vertex `a` to vertex `b` at positions[out+1:out+6].
@inline function _write_segment!(positions::Vector{Float64}, out::Int, geo::BufferGeometry,
                                 a::Int, b::Int)
    base_a = 3a - 3
    base_b = 3b - 3
    @inbounds for c in 1:3
        positions[out + c] = geo.positions[base_a + c]
        positions[out + 3 + c] = geo.positions[base_b + c]
    end
    return positions
end

"""
    wireframe_geometry(geo)

All unique triangle edges as line segments (three.js `WireframeGeometry`).
Faces are visited in index order, or group by group when `geo` has draw groups
(faces outside every group are skipped). Each triangle `(a, b, c)` contributes
its edges `a→b`, `b→c`, `c→a` in that direction, and an edge is emitted only the
first time its two end positions occur in either direction, so triangles that
share an edge through separate but coincident vertices contribute it once.

Returns an unindexed line geometry (`n_faces = 0`) whose consecutive vertex
pairs are the segments. Throws an `ArgumentError` when a draw group lies outside
the geometry's faces.
"""
function wireframe_geometry(geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "wireframe_geometry")
    geo.n_vertices <= _EDGE_KEY32_MAX ?
        _wireframe_geometry_keyed(geo, UInt64) :
        _wireframe_geometry_keyed(geo, UInt128)
end

function _wireframe_geometry_keyed(geo::BufferGeometry, ::Type{K}) where {K<:Union{UInt64,UInt128}}
    return _wireframe_geometry_ranges(geo, K, _wireframe_position_ids(geo),
                                      _wireframe_face_ranges(geo))
end

# Visits each triangle (a, b, c)'s edges a→b, b→c, c→a in face order and keeps
# the first occurrence of each pair of end positions in either direction
# (WireframeGeometry.js:186-202 isUniqueEdge hashes both directions). The kept
# directed edges are recorded first so that the positions buffer is allocated
# once at its exact size.
function _wireframe_geometry_ranges(geo::BufferGeometry, ::Type{K}, position_ids::Vector{Int},
                                    ranges) where {K<:Union{UInt64,UInt128}}
    max_edges = 0
    for faces in ranges
        max_edges = _geometry_checked_add(
            max_edges, _geometry_checked_mul(3, length(faces), "wireframe_geometry edge count"),
            "wireframe_geometry edge count")
    end
    seen = zeros(K, _edge_table_capacity(max_edges))
    kept = K[]
    sizehint!(kept, _edge_record_hint(geo, max_edges))
    @inbounds for faces in ranges, fi in faces
        corners = get_face(geo, fi)
        for j in 1:3
            a = corners[j]
            b = corners[j == 3 ? 1 : j + 1]
            key = _edge_key(K, position_ids[a], position_ids[b])
            slot = _edge_table_slot(seen, key)
            seen[slot] == key && continue
            seen[slot] = key
            push!(kept, _directed_edge_key(K, a, b))
        end
    end
    positions = Vector{Float64}(undef, 6 * length(kept))
    @inbounds for (k, key) in enumerate(kept)
        _write_segment!(positions, 6k - 6, geo, _edge_key_first(key), _edge_key_second(key))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], 2 * length(kept), 0)
end

# EdgesGeometry.js:33-34 and :79-81 hash each corner as
# `Math.round(x * 10 ** 4)`. JavaScript rounds halves towards +Inf, and the
# template string prints -0 as "0", so -0.0 folds into 0.0. Non-finite products
# keep their value ("NaN", "Infinity" and "-Infinity" are hash strings too).
@inline function _edges_hash_component(x::Float64)
    y = x * 10_000.0
    isfinite(y) || return y
    r = floor(y)
    # y - floor(y) is exact, so this matches Math.round without double rounding.
    return (y - r >= 0.5 ? r + 1.0 : r) + 0.0
end

# Triangle.js:66-81 getNormal, `cross(c - b, a - b) * (1 / length)`, evaluated
# with the same operations so normals at the threshold compare as in three.js.
# Products that overflow or leave the normal range use the scaled
# `triangle_normal`, where three.js would produce NaN or lose the direction.
@inline function _edges_face_normal(a::Vec3{Float64}, b::Vec3{Float64}, c::Vec3{Float64})
    ux, uy, uz = c.x - b.x, c.y - b.y, c.z - b.z
    vx, vy, vz = a.x - b.x, a.y - b.y, a.z - b.z
    nx = uy * vz - uz * vy
    ny = uz * vx - ux * vz
    nz = ux * vy - uy * vx
    length_sq = nx * nx + ny * ny + nz * nz
    if isfinite(length_sq) && length_sq >= floatmin(Float64)
        inverse = 1 / sqrt(length_sq)
        return Vec3(nx * inverse, ny * inverse, nz * inverse)
    end
    return triangle_normal(Triangle(a, b, c))
end

@inline function _edges_vertex_id!(vertex_ids::Vector{Int},
                                   canon::Dict{NTuple{3,Float64},Int},
                                   geo::BufferGeometry, vi::Int)
    @inbounds cached = vertex_ids[vi]
    cached != 0 && return cached
    base = 3vi - 3
    @inbounds key = (_edges_hash_component(geo.positions[base + 1]),
                     _edges_hash_component(geo.positions[base + 2]),
                     _edges_hash_component(geo.positions[base + 3]))
    id = get!(canon, key, length(canon) + 1)
    @inbounds vertex_ids[vi] = id
    return id
end

"""
    edges_geometry(geo; threshold_angle=deg2rad(1))

Boundary edges and the edges between faces whose normals differ by at least
`threshold_angle` radians, as an unindexed line geometry (three.js
`EdgesGeometry`, whose default threshold is 1 degree). This follows
EdgesGeometry.js exactly:

- corners are welded by position rounded to four decimal places
  (`Math.round(coordinate * 1e4)`), and triangles with two welded corners are
  skipped;
- each directed edge `a→b` is recorded once; when a later triangle supplies the
  reverse edge `b→a`, the pair is consumed and emitted, in that later
  triangle's direction, if the normals' dot product is at most
  `cos(threshold_angle)`;
- the edges left unpaired (boundaries, and the extra sides of non-manifold
  edges) follow, in the order they were first recorded.
"""
function edges_geometry(geo::BufferGeometry; threshold_angle=deg2rad(1.0))
    _validate_triangle_geometry_indices(geo, "edges_geometry")
    threshold_angle = _geometry_finite_float(
        threshold_angle, "edges_geometry threshold_angle")
    cosT = cos(threshold_angle)
    geo.n_vertices <= _EDGE_KEY32_MAX ?
        _edges_geometry_keyed(geo, cosT, UInt64) :
        _edges_geometry_keyed(geo, cosT, UInt128)
end

function _edges_geometry_keyed(geo::BufferGeometry, cosT::Float64,
                               ::Type{K}) where {K<:Union{UInt64,UInt128}}
    canon = Dict{NTuple{3,Float64},Int}()
    sizehint!(canon, geo.n_vertices)
    vertex_ids = zeros(Int, geo.n_vertices)
    max_edges = 3 * geo.n_faces
    slots = zeros(K, _edge_table_capacity(max_edges))
    slot_records = zeros(Int, length(slots))
    edge_hint = _edge_record_hint(geo, max_edges)
    record_index0 = Int[]
    record_index1 = Int[]
    record_normals = Vec3{Float64}[]
    record_active = Bool[]
    sizehint!(record_index0, edge_hint)
    sizehint!(record_index1, edge_hint)
    sizehint!(record_normals, edge_hint)
    sizehint!(record_active, edge_hint)
    # Matched sharp edges, in emission order, as ids of the consumed records
    # whose index fields then hold the later triangle's corners.
    matched = Int[]
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        c1 = _edges_vertex_id!(vertex_ids, canon, geo, i1)
        c2 = _edges_vertex_id!(vertex_ids, canon, geo, i2)
        c3 = _edges_vertex_id!(vertex_ids, canon, geo, i3)
        # EdgesGeometry.js:84-88 skips triangles with coincident corner hashes.
        (c1 == c2 || c2 == c3 || c3 == c1) && continue
        n = _edges_face_normal(get_vertex(geo, i1), get_vertex(geo, i2),
                               get_vertex(geo, i3))
        for (ia, ib, ca, cb) in ((i1, i2, c1, c2), (i2, i3, c2, c3), (i3, i1, c3, c1))
            # EdgesGeometry.js:103-117: a live reverse edge pairs with this one.
            reverse = slot_records[_edge_table_slot(slots, _directed_edge_key(K, cb, ca))]
            if reverse != 0 && record_active[reverse]
                if dot(n, record_normals[reverse]) <= cosT
                    record_index0[reverse] = ia
                    record_index1[reverse] = ib
                    push!(matched, reverse)
                end
                record_active[reverse] = false
            else
                # EdgesGeometry.js:119-130: record the directed edge once.
                key = _directed_edge_key(K, ca, cb)
                slot = _edge_table_slot(slots, key)
                slots[slot] == key && continue
                slots[slot] = key
                push!(record_index0, ia)
                push!(record_index1, ib)
                push!(record_normals, n)
                push!(record_active, true)
                slot_records[slot] = length(record_active)
            end
        end
    end
    # The matched sharp edges, then (EdgesGeometry.js:138-152) the unmatched
    # edges in insertion order, written into an exactly sized buffer.
    n_segments = length(matched) + count(record_active)
    positions = Vector{Float64}(undef, 6 * n_segments)
    out = 0
    @inbounds for r in matched
        _write_segment!(positions, out, geo, record_index0[r], record_index1[r])
        out += 6
    end
    @inbounds for r in eachindex(record_active)
        record_active[r] || continue
        _write_segment!(positions, out, geo, record_index0[r], record_index1[r])
        out += 6
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], 2 * n_segments, 0)
end

# ========================== Geometry addons ==========================
# three.js examples/jsm/geometries: RoundedBoxGeometry, BoxLineGeometry,
# DecalGeometry.

# Vector3.angleTo: acos of the clamped normalized dot product, or pi / 2 when
# either vector is zero.
@inline function _angle_between(a::Vec3{Float64}, b::Vec3{Float64})
    denominator = sqrt((a.x * a.x + a.y * a.y + a.z * a.z) * (b.x * b.x + b.y * b.y + b.z * b.z))
    iszero(denominator) && return π / 2
    return acos(clamp((a.x * b.x + a.y * b.y + a.z * b.z) / denominator, -1.0, 1.0))
end

@inline _axis_component(v::Vec3, axis::Int) = axis == 1 ? v.x : axis == 2 ? v.y : v.z

# RoundedBoxGeometry.js:6-43 `getUv`.
function _rounded_box_uv(face_dir::Vec3{Float64}, normal::Vec3{Float64}, uv_axis::Int,
                         projection_axis::Int, radius::Float64, side_length::Float64)
    total_arc_length = 2π * radius / 4
    center_length = max(side_length - 2 * radius, 0.0)
    half_arc = π / 4
    projected = Vec3(projection_axis == 1 ? 0.0 : normal.x, projection_axis == 2 ? 0.0 : normal.y,
                     projection_axis == 3 ? 0.0 : normal.z)
    projected = Vec3(_normalize_components(projected.x, projected.y, projected.z)...)
    arc_uv_ratio = 0.5 * total_arc_length / (total_arc_length + center_length)
    arc_angle_ratio = 1.0 - (_angle_between(projected, face_dir) / half_arc)
    if sign(_axis_component(projected, uv_axis)) == 1
        return arc_angle_ratio * arc_uv_ratio
    end
    length_uv = center_length / (total_arc_length + center_length)
    return length_uv + arc_uv_ratio + arc_uv_ratio * (1.0 - arc_angle_ratio)
end

"""
    RoundedBoxGeometry(; width=1, height=1, depth=1, segments=2, radius=0.1)

Box with rounded edges and corners (three.js addon `RoundedBoxGeometry`). The
radius is limited to half the shortest side, and each rounded edge has
`segments` subdivisions. As in three.js the result is built from a unit
`BoxGeometry` with `2segments + 1` subdivisions per side, made unindexed
(indices `1:n_vertices`), each vertex is pushed onto the rounded surface with
the surface normal, and the UVs run around each side's arcs. With
`segments = 0` three.js returns that unit box unchanged (ignoring `width`,
`height`, `depth` and `radius`), and so does this constructor.

The dimensions must be finite and positive and the radius finite and
non-negative (a zero side would make three.js's UVs `NaN`).
"""
function RoundedBoxGeometry(; width=1.0, height=1.0, depth=1.0, segments=2, radius=0.1)
    width = _geometry_finite_float(width, "RoundedBoxGeometry width")
    height = _geometry_finite_float(height, "RoundedBoxGeometry height")
    depth = _geometry_finite_float(depth, "RoundedBoxGeometry depth")
    radius = _geometry_finite_float(radius, "RoundedBoxGeometry radius")
    (width > 0 && height > 0 && depth > 0) ||
        throw(ArgumentError("RoundedBoxGeometry width, height and depth must be positive"))
    radius >= 0 || throw(ArgumentError("RoundedBoxGeometry radius must be non-negative"))
    segments = _geometry_nonnegative_int(segments, "RoundedBoxGeometry segments")
    total = _geometry_checked_add(
        _geometry_checked_mul(2, segments, "RoundedBoxGeometry segments"), 1,
        "RoundedBoxGeometry segments")
    radius = min(width / 2, height / 2, depth / 2, radius)
    box = BoxGeometry(width=1.0, height=1.0, depth=1.0, width_segments=total,
                      height_segments=total, depth_segments=total)
    total == 1 && return box
    geo = to_non_indexed(box)
    positions, normals, uvs = geo.positions, geo.normals, geo.uvs
    bx, by, bz = width / 2 - radius, height / 2 - radius, depth / 2 - radius
    face_tris = length(positions) ÷ 6
    half_segment = 0.5 / total
    for i in 0:3:(length(positions) - 1)
        j = 2 * (i ÷ 3)
        x, y, z = positions[i + 1], positions[i + 2], positions[i + 3]
        n = Vec3(_normalize_components(x - sign(x) * half_segment, y - sign(y) * half_segment,
                                       z - sign(z) * half_segment)...)
        positions[i + 1] = bx * sign(x) + n.x * radius
        positions[i + 2] = by * sign(y) + n.y * radius
        positions[i + 3] = bz * sign(z) + n.z * radius
        normals[i + 1] = n.x
        normals[i + 2] = n.y
        normals[i + 3] = n.z
        # RoundedBoxGeometry.js:118-176; axes are 1 = x, 2 = y, 3 = z.
        side = i ÷ face_tris
        if side == 0
            dir = Vec3(1.0, 0.0, 0.0)
            u = _rounded_box_uv(dir, n, 3, 2, radius, depth)
            v = 1.0 - _rounded_box_uv(dir, n, 2, 3, radius, height)
        elseif side == 1
            dir = Vec3(-1.0, 0.0, 0.0)
            u = 1.0 - _rounded_box_uv(dir, n, 3, 2, radius, depth)
            v = 1.0 - _rounded_box_uv(dir, n, 2, 3, radius, height)
        elseif side == 2
            dir = Vec3(0.0, 1.0, 0.0)
            u = 1.0 - _rounded_box_uv(dir, n, 1, 3, radius, width)
            v = _rounded_box_uv(dir, n, 3, 1, radius, depth)
        elseif side == 3
            dir = Vec3(0.0, -1.0, 0.0)
            u = 1.0 - _rounded_box_uv(dir, n, 1, 3, radius, width)
            v = 1.0 - _rounded_box_uv(dir, n, 3, 1, radius, depth)
        elseif side == 4
            dir = Vec3(0.0, 0.0, 1.0)
            u = 1.0 - _rounded_box_uv(dir, n, 1, 2, radius, width)
            v = 1.0 - _rounded_box_uv(dir, n, 2, 1, radius, height)
        else
            dir = Vec3(0.0, 0.0, -1.0)
            u = _rounded_box_uv(dir, n, 1, 2, radius, width)
            v = 1.0 - _rounded_box_uv(dir, n, 2, 1, radius, height)
        end
        uvs[j + 1] = u
        uvs[j + 2] = v
    end
    return geo
end

"""
    BoxLineGeometry(; width=1, height=1, depth=1, width_segments=1,
                    height_segments=1, depth_segments=1)

Line segments outlining the grid lines on the six sides of a box (three.js
addon `BoxLineGeometry`): for each of the `width_segments + 1` x positions a
rectangle around the box, then likewise along y and z. Returns an unindexed
line geometry (`n_faces = 0`) whose consecutive vertex pairs are the segments;
draw it with [`LineSegments`](@ref).
"""
function BoxLineGeometry(; width=1.0, height=1.0, depth=1.0, width_segments=1,
                         height_segments=1, depth_segments=1)
    width = _geometry_finite_float(width, "BoxLineGeometry width")
    height = _geometry_finite_float(height, "BoxLineGeometry height")
    depth = _geometry_finite_float(depth, "BoxLineGeometry depth")
    ws = _geometry_segment_count("width_segments", width_segments)
    hs = _geometry_segment_count("height_segments", height_segments)
    ds = _geometry_segment_count("depth_segments", depth_segments)
    wh, hh, dh = width / 2, height / 2, depth / 2
    segment_width, segment_height, segment_depth = width / ws, height / hs, depth / ds
    n_lines = _geometry_checked_add(_geometry_checked_add(ws, hs, "BoxLineGeometry segments"),
                                    ds + 3, "BoxLineGeometry segments")
    n_vertices = _geometry_checked_mul(8, n_lines, "BoxLineGeometry vertex count")
    position_len, _, _ = _geometry_mesh_buffer_lengths(n_vertices, 0, "BoxLineGeometry")
    positions = Float64[]
    sizehint!(positions, position_len)
    # BoxLineGeometry.js:43-71 accumulates each coordinate by its step.
    x = -wh
    for _ in 0:ws
        append!(positions, (x, -hh, -dh, x, hh, -dh, x, hh, -dh, x, hh, dh,
                            x, hh, dh, x, -hh, dh, x, -hh, dh, x, -hh, -dh))
        x += segment_width
    end
    y = -hh
    for _ in 0:hs
        append!(positions, (-wh, y, -dh, wh, y, -dh, wh, y, -dh, wh, y, dh,
                            wh, y, dh, -wh, y, dh, -wh, y, dh, -wh, y, -dh))
        y += segment_height
    end
    z = -dh
    for _ in 0:ds
        append!(positions, (-wh, -hh, z, -wh, hh, z, -wh, hh, z, wh, hh, z,
                            wh, hh, z, wh, -hh, z, wh, -hh, z, -wh, -hh, z))
        z += segment_depth
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[], n_vertices, 0)
end

# DecalGeometry.js:183-311 `clipGeometry` for the plane with unit normal
# `sign` along `axis`, keeping the side within `s` of the origin.
@inline _decal_distance(p::Vec3{Float64}, axis::Int, sgn::Float64, s::Float64) =
    sgn * _axis_component(p, axis) - s

@inline function _decal_clip(p0::Vec3{Float64}, n0::Vec3{Float64}, p1::Vec3{Float64},
                             n1::Vec3{Float64}, axis::Int, sgn::Float64, s::Float64)
    d0 = _decal_distance(p0, axis, sgn, s)
    d1 = _decal_distance(p1, axis, sgn, s)
    s0 = d0 / (d0 - d1)
    return (Vec3(p0.x + s0 * (p1.x - p0.x), p0.y + s0 * (p1.y - p0.y), p0.z + s0 * (p1.z - p0.z)),
            Vec3(n0.x + s0 * (n1.x - n0.x), n0.y + s0 * (n1.y - n0.y), n0.z + s0 * (n1.z - n0.z)))
end

function _decal_clip_plane(points::Vector{Vec3{Float64}}, normals::Vector{Vec3{Float64}},
                           axis::Int, sgn::Float64, s::Float64)
    out_points = Vec3{Float64}[]
    out_normals = Vec3{Float64}[]
    sizehint!(out_points, length(points))
    sizehint!(out_normals, length(points))
    keep(p, n) = (push!(out_points, p); push!(out_normals, n))
    for i in 1:3:length(points)
        q = (points[i], points[i + 1], points[i + 2])
        m = (normals[i], normals[i + 1], normals[i + 2])
        out = (_decal_distance(q[1], axis, sgn, s) > 0, _decal_distance(q[2], axis, sgn, s) > 0,
               _decal_distance(q[3], axis, sgn, s) > 0)
        total = count(out)
        if total == 0
            for k in 1:3
                keep(q[k], m[k])
            end
        elseif total == 1
            # One corner outside: two triangles (DecalGeometry.js:218-270).
            o = out[1] ? 1 : out[2] ? 2 : 3
            a, b = o == 1 ? (2, 3) : o == 2 ? (1, 3) : (1, 2)
            c3 = _decal_clip(q[o], m[o], q[a], m[a], axis, sgn, s)
            c4 = _decal_clip(q[o], m[o], q[b], m[b], axis, sgn, s)
            if o == 2
                keep(c3...); keep(q[b], m[b]); keep(q[a], m[a])
                keep(q[b], m[b]); keep(c3...); keep(c4...)
            else
                keep(q[a], m[a]); keep(q[b], m[b]); keep(c3...)
                keep(c4...); keep(c3...); keep(q[b], m[b])
            end
        elseif total == 2
            # One corner inside: one triangle (DecalGeometry.js:272-306).
            k = !out[1] ? 1 : !out[2] ? 2 : 3
            next, prev = k == 1 ? (2, 3) : k == 2 ? (3, 1) : (1, 2)
            keep(q[k], m[k])
            keep(_decal_clip(q[k], m[k], q[next], m[next], axis, sgn, s)...)
            keep(_decal_clip(q[k], m[k], q[prev], m[prev], axis, sgn, s)...)
        end
    end
    return out_points, out_normals
end

"""
    DecalGeometry(mesh::Mesh, position::Vec3, orientation::Euler, size::Vec3)

Decal geometry projected onto `mesh` (three.js addon `DecalGeometry`). A box
projector of extent `size`, centred at the world-space `position` and rotated
by `orientation`, cuts the mesh's triangles (in world space, through the
mesh's world matrix) to the box. The result is an unindexed world-space
triangle geometry with UVs `0.5 .+ (x, y) ./ (size.x, size.y)` in projector
space; it carries the mesh's normals, transformed by its normal matrix and
linearly interpolated at the cut (not renormalized, as in three.js), when the
mesh geometry has normals. Use it with a mesh at the origin, e.g.
`Mesh(DecalGeometry(target, position, orientation, size), decal_material)`.

The geometry's base positions are used (morph targets and skinning are not
applied, as in three.js). `size` must have finite non-zero components.
"""
function DecalGeometry(mesh::Mesh, position::Vec3, orientation::Euler, size::Vec3)
    geo = mesh.geometry
    geo isa BufferGeometry || throw(ArgumentError("DecalGeometry mesh must have a BufferGeometry"))
    _validate_triangle_geometry_indices(geo, "DecalGeometry")
    sx = _geometry_nonzero_finite_scalar(Float64(size.x), "DecalGeometry size.x")
    sy = _geometry_nonzero_finite_scalar(Float64(size.y), "DecalGeometry size.y")
    sz = _geometry_nonzero_finite_scalar(Float64(size.z), "DecalGeometry size.z")
    center = Vec3(_geometry_finite_float(position.x, "DecalGeometry position"),
                  _geometry_finite_float(position.y, "DecalGeometry position"),
                  _geometry_finite_float(position.z, "DecalGeometry position"))
    has_normals = !isempty(geo.normals)
    has_normals && length(geo.normals) < 3geo.n_vertices &&
        throw(ArgumentError("DecalGeometry mesh normals must cover n_vertices"))
    entries = isempty(geo.indices) ? (1:geo.n_vertices) : view(geo.indices, 1:3geo.n_faces)
    rem(length(entries), 3) == 0 ||
        throw(ArgumentError("DecalGeometry mesh must consist of whole triangles"))
    world = compute_world_matrix(mesh)
    normal_matrix = _geometry_normal_matrix(world)
    # Matrix4.makeRotationFromEuler(orientation).setPosition(position).
    rotation = quat_to_mat4(quat_from_euler(Float64(orientation.x), Float64(orientation.y),
                                            Float64(orientation.z); order=orientation.order))
    e = rotation.e
    projector = Mat4((e[1], e[2], e[3], 0.0, e[5], e[6], e[7], 0.0, e[9], e[10], e[11], 0.0,
                      center.x, center.y, center.z, 1.0))
    projector_inverse = mat4_inverse(projector)
    points = Vector{Vec3{Float64}}(undef, length(entries))
    normals = Vector{Vec3{Float64}}(undef, length(entries))
    for (k, vi) in enumerate(entries)
        points[k] = mat4_transform_point(projector_inverse, mat4_transform_point(world, get_vertex(geo, vi)))
        normals[k] = has_normals ?
            first(_transform_geometry_direction_pair(normal_matrix, get_normal(geo, vi), Vec3(), 1.0)) :
            Vec3(0.0, 0.0, 0.0)
    end
    # DecalGeometry.js:100-105: +x, -x, +y, -y, +z, -z.
    for (axis, sgn) in ((1, 1.0), (1, -1.0), (2, 1.0), (2, -1.0), (3, 1.0), (3, -1.0))
        half = 0.5 * abs(axis == 1 ? sx : axis == 2 ? sy : sz)
        points, normals = _decal_clip_plane(points, normals, axis, sgn, half)
    end
    n = length(points)
    out_positions = Vector{Float64}(undef, 3n)
    out_normals = has_normals ? Vector{Float64}(undef, 3n) : Float64[]
    out_uvs = Vector{Float64}(undef, 2n)
    for k in 1:n
        p = points[k]
        out_uvs[2k - 1] = 0.5 + (p.x / sx)
        out_uvs[2k] = 0.5 + (p.y / sy)
        w = mat4_transform_point(projector, p)
        out_positions[3k - 2] = w.x
        out_positions[3k - 1] = w.y
        out_positions[3k] = w.z
        if has_normals
            out_normals[3k - 2] = normals[k].x
            out_normals[3k - 1] = normals[k].y
            out_normals[3k] = normals[k].z
        end
    end
    return BufferGeometry(out_positions, out_normals, out_uvs, collect(1:n), n, n ÷ 3)
end
