# --------------------------------------------------------------------------
# Additional geometry generators mirroring three.js: the platonic-solid family
# via a subdividing PolyhedronGeometry, convex hulls, surfaces of revolution /
# sweeps (Lathe, Tube), profile extrusion (Shape/Extrude), Capsule, and the
# Edges/Wireframe line geometries.
# --------------------------------------------------------------------------

# ========================== PolyhedronGeometry ==========================
# Subdivide each base triangle into (detail+1)² faces and project to a sphere
# of the given radius. Vertices are non-indexed (3 per face).

_polyhedron_bary(A::Vec3, B::Vec3, C::Vec3, cols::Int, p::Int, q::Int) =
    A * ((cols - p - q) / cols) + B * (p / cols) + C * (q / cols)

function _polyhedron_emit_vertex!(positions::Vector{Float64}, normals::Vector{Float64},
                                  uvs::Vector{Float64}, vi::Int, v::Vec3,
                                  radius)
    d = normalize(v)                  # unit direction, independent of radius
    p = d * radius
    next_vi = vi + 1
    pbase = 3next_vi - 2
    ubase = 2next_vi - 1
    positions[pbase] = p.x
    positions[pbase + 1] = p.y
    positions[pbase + 2] = p.z
    normals[pbase] = d.x
    normals[pbase + 1] = d.y
    normals[pbase + 2] = d.z
    # Derive the spherical UV from the unit direction, not p.y/radius:
    # at radius=0 the latter is 0/0 = NaN, while asin(d.y) stays finite.
    uvs[ubase] = atan(d.z, d.x) / (2π) + 0.5
    uvs[ubase + 1] = asin(clamp(d.y, -1.0, 1.0)) / π + 0.5
    return next_vi
end

function _polyhedron_emit_triangle!(positions::Vector{Float64}, normals::Vector{Float64},
                                    uvs::Vector{Float64}, indices::Vector{Int},
                                    vi::Int, out::Int, a::Vec3, b::Vec3,
                                    c::Vec3, radius)
    start = vi + 1
    vi = _polyhedron_emit_vertex!(positions, normals, uvs, vi, a, radius)
    vi = _polyhedron_emit_vertex!(positions, normals, uvs, vi, b, radius)
    vi = _polyhedron_emit_vertex!(positions, normals, uvs, vi, c, radius)
    indices[out] = start
    indices[out + 1] = start + 1
    indices[out + 2] = start + 2
    return vi, out + 3
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
    for (i1, i2, i3) in base_faces
        A = verts[i1]; B = verts[i2]; C = verts[i3]
        for i in 0:cols-1, j in 0:(cols-1-i)
            vi, out = _polyhedron_emit_triangle!(
                positions, normals, uvs, indices, vi, out,
                _polyhedron_bary(A, B, C, cols, i, j),
                _polyhedron_bary(A, B, C, cols, i + 1, j),
                _polyhedron_bary(A, B, C, cols, i, j + 1),
                radius)
            if j < cols - 1 - i
                vi, out = _polyhedron_emit_triangle!(
                    positions, normals, uvs, indices, vi, out,
                    _polyhedron_bary(A, B, C, cols, i + 1, j),
                    _polyhedron_bary(A, B, C, cols, i + 1, j + 1),
                    _polyhedron_bary(A, B, C, cols, i, j + 1),
                    radius)
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

function _convex_support_faces(points::Vector{Vec3{Float64}}, eps::Float64)
    n = length(points)
    faces = Tuple{Vector{Int},Vec3{Float64}}[]
    sizehint!(faces, n)
    seen = Set{Tuple{Vararg{Int}}}()
    sizehint!(seen, n)
    plane_eps = 64 * eps
    for i in 1:(n - 2), j in (i + 1):(n - 1), k in (j + 1):n
        normal = cross(points[j] - points[i], points[k] - points[i])
        len = norm(normal)
        len > plane_eps || continue
        normal = normal * (1 / len)
        pos = false
        neg = false
        for p in points
            side = dot(normal, p - points[i])
            pos |= side > plane_eps
            neg |= side < -plane_eps
            pos && neg && break
        end
        pos && neg && continue
        pos && (normal = -normal)
        coplanar = Int[]
        sizehint!(coplanar, n)
        for idx in eachindex(points)
            abs(dot(normal, points[idx] - points[i])) <= plane_eps &&
                push!(coplanar, idx)
        end
        key = Tuple(coplanar)
        if !(key in seen)
            push!(seen, key)
            push!(faces, (coplanar, normal))
        end
    end
    return faces
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

"""
    ConvexGeometry(points)

Build a flat-shaded triangle `BufferGeometry` for the convex hull of a
non-coplanar 3D point set.
"""
function ConvexGeometry(points::AbstractVector{<:Vec3})
    clean, normalized, eps = _convex_clean_points(points)
    _convex_has_volume(normalized, eps) ||
        throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    support_faces = _convex_support_faces(normalized, eps)
    isempty(support_faces) &&
        throw(ArgumentError("ConvexGeometry could not find hull support faces"))

    hulls = Tuple{Vector{Int},Vec3{Float64}}[]
    sizehint!(hulls, length(support_faces))
    n_faces = 0
    for (face_indices, normal) in support_faces
        hull = _convex_face_hull(
            normalized, face_indices, normal, eps)
        length(hull) >= 3 || continue
        push!(hulls, (hull, normal))
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
    segments = _clamp_seg(segments, 3, "LatheGeometry segments")   # clamp so 0 can't make i/segments NaN

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
            positions[pbase] = pt.x * c
            positions[pbase + 1] = pt.y
            positions[pbase + 2] = -pt.x * s
            jm = max(j-1, 1); jp = min(j+1, np)
            dx, dy = _geometry_unit_delta2(
                Float64(points[jm].x), Float64(points[jm].y),
                Float64(points[jp].x), Float64(points[jp].y))
            nr = dy; nh = -dx                      # outward profile normal
            nx = nr*c; ny = nh; nz = -nr*s
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
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = d
        indices[out + 3] = b
        indices[out + 4] = c
        indices[out + 5] = d
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

@inline function _tube_tangent(path::Vector{<:Vec3}, i::Int, n::Int)
    prev = path[max(i - 1, 1)]
    next = path[min(i + 1, n)]
    tangent = _tube_unit_delta(prev, next)
    norm(tangent) > 0.0 && return tangent
    # A 180-degree reversal can make the centered difference zero despite both
    # adjacent segments being valid. Prefer the forward segment at the cusp.
    i < n && return _tube_unit_delta(path[i], path[i + 1])
    return _tube_unit_delta(path[i - 1], path[i])
end

function TubeGeometry(path::Vector{<:Vec3}; radius=1.0, radial_segments=8)
    n = length(path)
    _validate_tube_path(path)
    @inbounds for i in 2:n
        _geometry_delta_norm3(
            Float64(path[i - 1].x), Float64(path[i - 1].y),
            Float64(path[i - 1].z), Float64(path[i].x),
            Float64(path[i].y), Float64(path[i].z)) > 0.0 ||
            throw(ArgumentError(
                "TubeGeometry path needs consecutive distinct points"))
    end
    radius = _geometry_finite_float(radius, "TubeGeometry radius")
    radial_segments = _clamp_seg(radial_segments, 3, "TubeGeometry radial_segments")   # clamp so 0 can't make j/radial_segments NaN

    rs1 = radial_segments + 1
    n_verts = _geometry_checked_mul(n, rs1, "TubeGeometry vertex count")
    n_faces = _geometry_checked_mul(
        2 * (n - 1), radial_segments, "TubeGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "TubeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    # Initial frame from the first tangent, parallel-transported along the path
    # (as in three.js computeFrenetFrames) so the frame never flips between rings.
    T1 = _tube_tangent(path, 1, n)
    refv = abs(T1.y) < 0.99 ? Vec3(0.0,1.0,0.0) : Vec3(1.0,0.0,0.0)
    N = normalize(cross(refv, T1)); B = cross(T1, N)
    for i in 1:n
        T = i == 1 ? T1 : _tube_tangent(path, i, n)
        if i > 1
            Np = N - T*dot(N, T)               # project previous N off the new tangent
            N = norm(Np) > 1e-9 ? normalize(Np) : normalize(cross(B, T))
            B = cross(T, N)
        end
        for j in 0:radial_segments
            vj = j / radial_segments
            v = vj * 2π
            normal = N * cos(v) + B * sin(v)
            p = path[i] + normal * radius
            _geometry_check_position(
                Float64(p.x), Float64(p.y), Float64(p.z), "TubeGeometry")
            vi = (i - 1) * rs1 + j + 1
            pbase = 3vi - 2
            ubase = 2vi - 1
            positions[pbase] = p.x
            positions[pbase + 1] = p.y
            positions[pbase + 2] = p.z
            normals[pbase] = normal.x
            normals[pbase + 1] = normal.y
            normals[pbase + 2] = normal.z
            uvs[ubase] = (i - 1) / (n - 1)
            uvs[ubase + 1] = vj
        end
    end

    out = 1
    for i in 0:n-2, j in 0:radial_segments-1
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

# ========================== CatmullRomCurve ==========================

struct CatmullRomCurve
    points::Vector{Vec3{Float64}}
    curve_type::Symbol
    closed::Bool
    tension::Float64
end

const _CATMULL_ROM_CURVE_TYPES = (:catmullrom, :centripetal, :chordal)

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
    all(isfinite, (result.x, result.y, result.z)) && return result

    tangent1_weight = tension * (t3 - 2t2 + t)
    tangent2_weight = tension * (t3 - t2)
    weights = (-tangent1_weight,
               2t3 - 3t2 + 1.0 - tangent2_weight,
               -2t3 + 3t2 + tangent1_weight,
               tangent2_weight)
    stable_coordinate(a, b, c, d) = _float_representation_value(
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
    return Vec3(stable_coordinate(p0.x, p1.x, p2.x, p3.x),
                stable_coordinate(p0.y, p1.y, p2.y, p3.y),
                stable_coordinate(p0.z, p1.z, p2.z, p3.z))
end

function _catmull_rom_param_lerp(a::Vec3, b::Vec3, t0::Float64,
                                 t1::Float64, t::Float64)
    denom = t1 - t0
    denom > 0.0 || return a
    return lerp(a, b, (t - t0) / denom)
end

function _catmull_rom_interval(a::Vec3, b::Vec3, alpha::Float64)
    return max(norm(b - a)^alpha, eps(Float64))
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
    t1 = t0 + _catmull_rom_interval(p0, p1, alpha)
    t2 = t1 + _catmull_rom_interval(p1, p2, alpha)
    t3 = t2 + _catmull_rom_interval(p2, p3, alpha)
    if !(isfinite(t3) && t1 > t0 && t2 > t1 && t3 > t2)
        interval1, interval2, interval3 =
            _catmull_rom_normalized_intervals(p0, p1, p2, p3, alpha)
        t1 = interval1
        t2 = t1 + interval2
        t3 = t2 + interval3
    end
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

function catmull_rom_point(curve::CatmullRomCurve, t::Real)
    points = curve.points
    n = length(points)
    segment, local_t = _catmull_rom_segment(curve, t)
    if curve.closed
        p0 = points[mod1(segment - 1, n)]
        p1 = points[mod1(segment, n)]
        p2 = points[mod1(segment + 1, n)]
        p3 = points[mod1(segment + 2, n)]
    else
        p0 = points[max(segment - 1, 1)]
        p1 = points[segment]
        p2 = points[segment + 1]
        p3 = points[min(segment + 2, n)]
    end
    curve.curve_type === :catmullrom &&
        return _catmull_rom_uniform(p0, p1, p2, p3, local_t, curve.tension)
    alpha = curve.curve_type === :centripetal ? 0.5 : 1.0
    return _catmull_rom_nonuniform(p0, p1, p2, p3, local_t, alpha)
end

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

function _nurbs_basis!(scratch::Vector{Float64}, span::Int, u::Float64,
                       degree::Int, knots::Vector{Float64})
    n = degree + 1
    length(scratch) >= 3n || resize!(scratch, 3n)
    left0 = n
    right0 = 2n
    scratch[1] = 1.0
    for j in 1:degree
        scratch[left0 + j + 1] = u - knots[span - j + 2]
        scratch[right0 + j + 1] = knots[span + j + 1] - u
        saved = 0.0
        for r in 0:(j - 1)
            left = scratch[left0 + j - r + 1]
            right = scratch[right0 + r + 2]
            right_fraction, left_fraction = _nurbs_basis_fractions(
                left, right, u,
                knots[span - j + r + 2], knots[span + r + 2])
            basis = scratch[r + 1]
            scratch[r + 1] = saved + basis * right_fraction
            saved = basis * left_fraction
        end
        scratch[j + 1] = saved
    end
    return scratch
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

function _nurbs_point(curve::NURBSCurve, t::Real, basis::Vector{Float64})
    npoints = length(curve.control_points)
    u = _nurbs_parameter(t, curve.knots, curve.degree, npoints,
                         "NURBS curve parameter t")
    span = _nurbs_span(curve.degree, curve.knots, npoints, u)
    _nurbs_basis!(basis, span, u, curve.degree, curve.knots)
    x = 0.0
    y = 0.0
    z = 0.0
    weight = 0.0
    for j in 0:curve.degree
        cp = curve.control_points[span - curve.degree + j + 1]
        coeff = basis[j + 1] * cp.w
        x += cp.x * coeff
        y += cp.y * coeff
        z += cp.z * coeff
        weight += coeff
    end
    if isfinite(x) && isfinite(y) && isfinite(z) &&
       isfinite(weight)
        return _nurbs_finish_point(x, y, z, weight)
    end

    point = Vec3(0.0, 0.0, 0.0)
    total_weight = 0.0
    for j in 0:curve.degree
        cp = curve.control_points[span - curve.degree + j + 1]
        coeff = basis[j + 1] * cp.w
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
    _nurbs_basis!(basis_u, span_u, uu, surface.degree_u, surface.knots_u)
    _nurbs_basis!(basis_v, span_v, vv, surface.degree_v, surface.knots_v)
    x = 0.0
    y = 0.0
    z = 0.0
    weight = 0.0
    for i in 0:surface.degree_u, j in 0:surface.degree_v
        cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * cp.w
        x += cp.x * coeff
        y += cp.y * coeff
        z += cp.z * coeff
        weight += coeff
    end
    if isfinite(x) && isfinite(y) && isfinite(z) &&
       isfinite(weight)
        return _nurbs_finish_point(x, y, z, weight)
    end

    point = Vec3(0.0, 0.0, 0.0)
    total_weight = 0.0
    for i in 0:surface.degree_u, j in 0:surface.degree_v
        cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * cp.w
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
    _nurbs_basis!(basis_u, span_u, uu, volume.degree_u, volume.knots_u)
    _nurbs_basis!(basis_v, span_v, vv, volume.degree_v, volume.knots_v)
    _nurbs_basis!(basis_w, span_w, ww, volume.degree_w, volume.knots_w)
    x = 0.0
    y = 0.0
    z = 0.0
    weight = 0.0
    for i in 0:volume.degree_u, j in 0:volume.degree_v, k in 0:volume.degree_w
        cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * basis_w[k + 1] * cp.w
        x += cp.x * coeff
        y += cp.y * coeff
        z += cp.z * coeff
        weight += coeff
    end
    if isfinite(x) && isfinite(y) && isfinite(z) &&
       isfinite(weight)
        return _nurbs_finish_point(x, y, z, weight)
    end

    point = Vec3(0.0, 0.0, 0.0)
    total_weight = 0.0
    for i in 0:volume.degree_u, j in 0:volume.degree_v, k in 0:volume.degree_w
        cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * basis_w[k + 1] * cp.w
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

function _parametric_normals(positions::Vector{Float64}, indices::Vector{Int}, nvertices::Int)
    normals = zeros(Float64, 3 * nvertices)
    needs_scaled_fallback = false
    for fi in 1:(length(indices) ÷ 3)
        i1 = indices[3fi - 2]
        i2 = indices[3fi - 1]
        i3 = indices[3fi]
        p1 = Vec3(positions[3i1 - 2], positions[3i1 - 1], positions[3i1])
        p2 = Vec3(positions[3i2 - 2], positions[3i2 - 1], positions[3i2])
        p3 = Vec3(positions[3i3 - 2], positions[3i3 - 1], positions[3i3])
        fn = cross(p2 - p1, p3 - p1)
        needs_scaled_fallback |=
            !(isfinite(fn.x) && isfinite(fn.y) && isfinite(fn.z))
        for idx in (i1, i2, i3)
            base = 3idx - 2
            nx = normals[base] + fn.x
            ny = normals[base + 1] + fn.y
            nz = normals[base + 2] + fn.z
            needs_scaled_fallback |=
                !(isfinite(nx) && isfinite(ny) && isfinite(nz))
            normals[base] = nx
            normals[base + 1] = ny
            normals[base + 2] = nz
        end
    end
    if needs_scaled_fallback
        nfaces = length(indices) ÷ 3
        geometry = BufferGeometry(
            positions, normals, Float64[], indices,
            nvertices, nfaces)
        _compute_vertex_normals_scaled!(normals, geometry)
        return normals
    end
    for vi in 1:nvertices
        base = 3vi - 2
        n = normalize(Vec3(normals[base], normals[base + 1], normals[base + 2]))
        normals[base] = n.x
        normals[base + 1] = n.y
        normals[base + 2] = n.z
    end
    return normals
end

function ParametricGeometry(fn::Function, slices::Integer=20, stacks::Integer=20)
    us = _geometry_positive_int(slices, "ParametricGeometry slices")
    vs = _geometry_positive_int(stacks, "ParametricGeometry stacks")
    row = us + 1
    nvertices = _geometry_checked_mul(
        row, vs + 1, "ParametricGeometry vertex count")
    nfaces = _geometry_checked_mul(2 * us, vs, "ParametricGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(nvertices, nfaces, "ParametricGeometry")
    positions = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    for j in 0:vs, i in 0:us
        u = i / us
        v = j / vs
        p = fn(u, v)
        p isa Vec3 || throw(ArgumentError("ParametricGeometry callback must return Vec3"))
        x = _geometry_finite_float(p.x, "ParametricGeometry callback returned a non-finite point")
        y = _geometry_finite_float(p.y, "ParametricGeometry callback returned a non-finite point")
        z = _geometry_finite_float(p.z, "ParametricGeometry callback returned a non-finite point")
        vi = j * row + i + 1
        pbase = 3vi - 2
        ubase = 2vi - 1
        positions[pbase] = x
        positions[pbase + 1] = y
        positions[pbase + 2] = z
        uvs[ubase] = u
        uvs[ubase + 1] = 1.0 - v
    end
    indices = Vector{Int}(undef, index_len)
    out = 1
    for j in 0:(vs - 1), i in 0:(us - 1)
        a = j * row + i + 1
        b = a + 1
        c = a + row
        d = c + 1
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = d
        indices[out + 3] = a
        indices[out + 4] = d
        indices[out + 5] = c
        out += 6
    end
    normals = _parametric_normals(positions, indices, nvertices)
    return BufferGeometry(positions, normals, uvs, indices, nvertices, nfaces)
end

function NURBSSurfaceGeometry(surface::NURBSSurface; slices::Integer=20,
                              stacks::Integer=20)
    us = _geometry_positive_int(slices, "NURBSSurfaceGeometry slices")
    vs = _geometry_positive_int(stacks, "NURBSSurfaceGeometry stacks")
    row = us + 1
    nvertices = _geometry_checked_mul(
        row, vs + 1, "NURBSSurfaceGeometry vertex count")
    nfaces = _geometry_checked_mul(
        2 * us, vs, "NURBSSurfaceGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(
            nvertices, nfaces, "NURBSSurfaceGeometry")
    positions = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    basis_u = _nurbs_basis_scratch(surface.degree_u)
    basis_v = _nurbs_basis_scratch(surface.degree_v)
    for j in 0:vs, i in 0:us
        u = i / us
        v = j / vs
        p = _nurbs_point(surface, u, v, basis_u, basis_v)
        vi = j * row + i + 1
        pbase = 3vi - 2
        ubase = 2vi - 1
        positions[pbase] = p.x
        positions[pbase + 1] = p.y
        positions[pbase + 2] = p.z
        uvs[ubase] = u
        uvs[ubase + 1] = 1.0 - v
    end
    indices = Vector{Int}(undef, index_len)
    out = 1
    for j in 0:(vs - 1), i in 0:(us - 1)
        a = j * row + i + 1
        b = a + 1
        c = a + row
        d = c + 1
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = d
        indices[out + 3] = a
        indices[out + 4] = d
        indices[out + 5] = c
        out += 6
    end
    normals = _parametric_normals(positions, indices, nvertices)
    return BufferGeometry(positions, normals, uvs, indices, nvertices, nfaces)
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
        raw[index] = Vec2(
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
    raw = Vec3{Float64}[]
    for p in path
        q = Vec3(_geometry_finite_float(p.x, "ExtrudeGeometry extrude_path points"),
                 _geometry_finite_float(p.y, "ExtrudeGeometry extrude_path points"),
                 _geometry_finite_float(p.z, "ExtrudeGeometry extrude_path points"))
        push!(raw, q)
    end
    xmin = minimum(point -> point.x, raw)
    xmax = maximum(point -> point.x, raw)
    ymin = minimum(point -> point.y, raw)
    ymax = maximum(point -> point.y, raw)
    zmin = minimum(point -> point.z, raw)
    zmax = maximum(point -> point.z, raw)
    cx = _geometry_midpoint(xmin, xmax)
    cy = _geometry_midpoint(ymin, ymax)
    cz = _geometry_midpoint(zmin, zmax)
    scale = Vec3(max(abs(xmin - cx), abs(xmax - cx)),
                 max(abs(ymin - cy), abs(ymax - cy)),
                 max(abs(zmin - cz), abs(zmax - cz)))
    closed = _extrude_path_points_close(raw[end], raw[1], scale)
    clean_last = closed ? length(raw) - 1 : length(raw)
    filtered = Vec3{Float64}[]
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

function _extrude_path_geometry(shape_in::AbstractVector{<:Vec2},
                                path_in::AbstractVector{<:Vec3})
    shape = _extrude_clean_shape(shape_in)
    path, closed, eps = _extrude_clean_path(path_in)
    tangents = _extrude_path_tangents(path, closed, eps)
    shape_normals = _extrude_shape_vertex_normals(shape)
    cap_triangles = closed ? NTuple{3,Int}[] : _shape_triangulate(shape)
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
    @inbounds for i in 1:nr
        T = tangents[i]
        if i > 1
            projected = N - T * dot(N, T)
            N = norm(projected) > eps ? normalize(projected) : normalize(cross(B, T))
            B = cross(T, N)
        end
        i == 1 && (first_N = N; first_B = B)
        i == nr && (last_N = N; last_B = B)
        for j in 1:np
            pt = shape[j]
            normal2 = shape_normals[j]
            p = path[i] + N * pt.x + B * pt.y
            n = normalize(N * normal2.x + B * normal2.y)
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
        for j in 1:np
            j2 = mod1(j + 1, np)
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

"""Filled planar polygon (z = 0), normal +z."""
function ShapeGeometry(shape::Vector{<:Vec2})
    shape = _extrude_clean_shape(shape)   # normalize to CCW (+z normal)
    np = length(shape)
    triangles = _shape_triangulate(shape)
    n_faces = length(triangles)
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(np, n_faces, "ShapeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    @inbounds for i in 1:np
        pt = shape[i]
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

"""Extrude a planar polygon `shape` to `depth` along +z, or along `extrude_path`."""
function ExtrudeGeometry(shape::Vector{<:Vec2}; depth=1.0, extrude_path=nothing)
    extrude_path !== nothing && return _extrude_path_geometry(shape, extrude_path)
    depth = _geometry_finite_float(depth, "ExtrudeGeometry depth")
    # Normalize to CCW (like the extrude_path branch) so the hard-coded cap and
    # side-wall normals stay consistent with the winding for any input orientation.
    shape = _extrude_clean_shape(shape)
    np = length(shape)
    cap_triangles = _shape_triangulate(shape)
    n_verts = _geometry_checked_mul(6, np, "ExtrudeGeometry vertex count")
    n_faces = _geometry_checked_add(
        _geometry_checked_mul(4, np, "ExtrudeGeometry face count"),
        -4, "ExtrudeGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "ExtrudeGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)

    @inbounds for i in 1:np
        pt = shape[i]
        front_base = 3i - 2
        back = np + i
        back_base = 3back - 2
        positions[front_base] = pt.x
        positions[front_base + 1] = pt.y
        positions[front_base + 2] = 0.0
        normals[front_base] = 0.0
        normals[front_base + 1] = 0.0
        normals[front_base + 2] = -1.0
        uvs[2i - 1] = 0.0
        uvs[2i] = 0.0

        positions[back_base] = pt.x
        positions[back_base + 1] = pt.y
        positions[back_base + 2] = depth
        normals[back_base] = 0.0
        normals[back_base + 1] = 0.0
        normals[back_base + 2] = 1.0
        uvs[2back - 1] = 1.0
        uvs[2back] = 1.0
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
    @inbounds for i in 1:np
        i2 = i % np + 1
        p1 = shape[i]; p2 = shape[i2]
        ex, ey = _geometry_unit_delta2(p1.x, p1.y, p2.x, p2.y)
        nx = ey; ny = -ex
        a = vi + 1
        b = vi + 2
        c = vi + 3
        d = vi + 4
        vals = ((p1.x, p1.y, 0.0,   0.0, 0.0),
                (p2.x, p2.y, 0.0,   1.0, 0.0),
                (p2.x, p2.y, depth, 1.0, 1.0),
                (p1.x, p1.y, depth, 0.0, 1.0))
        for (offset, val) in enumerate(vals)
            x, y, z, u, v = val
            dst = vi + offset
            pbase = 3dst - 2
            positions[pbase] = x
            positions[pbase + 1] = y
            positions[pbase + 2] = z
            normals[pbase] = nx
            normals[pbase + 1] = ny
            normals[pbase + 2] = 0.0
            ubase = 2dst - 1
            uvs[ubase] = u
            uvs[ubase + 1] = v
        end
        vi += 4
        indices[out] = a
        indices[out + 1] = b
        indices[out + 2] = c
        indices[out + 3] = a
        indices[out + 4] = c
        indices[out + 5] = d
        out += 6
    end
    BufferGeometry(positions, normals, uvs, indices, n_verts, n_faces)
end

# ========================== CapsuleGeometry ==========================
# Cylinder of `length` capped by two hemispheres of `radius`, revolved about y.

function CapsuleGeometry(; radius=1.0, length=1.0, cap_segments=8, radial_segments=16)
    radius = _geometry_finite_float(radius, "CapsuleGeometry radius")
    length = _geometry_finite_float(length, "CapsuleGeometry length")
    _geometry_check_abs_sum(length * 0.5, radius, "CapsuleGeometry")
    # clamp so 0 can't make i/cap_segments or s/radial_segments a 0/0 = NaN
    cap_segments = _clamp_seg(cap_segments, 1, "CapsuleGeometry cap_segments")
    radial_segments = _clamp_seg(radial_segments, 3, "CapsuleGeometry radial_segments")
    half = length / 2
    np = _geometry_checked_mul(
        2, cap_segments + 1, "CapsuleGeometry profile point count")
    n_verts = _geometry_checked_mul(
        radial_segments + 1, np, "CapsuleGeometry vertex count")
    n_faces = _geometry_checked_mul(
        2 * radial_segments, np - 1, "CapsuleGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(n_verts, n_faces, "CapsuleGeometry")
    profile_r = Vector{Float64}(undef, np)
    profile_y = Vector{Float64}(undef, np)
    for i in 0:cap_segments                          # top hemisphere: pole → equator
        a = i/cap_segments * (π/2)
        idx = i + 1
        profile_r[idx] = radius * sin(a)
        profile_y[idx] = half + radius * cos(a)
    end
    for i in 0:cap_segments                          # bottom hemisphere: equator → pole
        a = i/cap_segments * (π/2)
        idx = cap_segments + i + 2
        profile_r[idx] = radius * cos(a)
        profile_y[idx] = -half - radius * sin(a)
    end
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    @inbounds for s in 0:radial_segments
        u = s / radial_segments
        phi = u * 2π
        c = cos(phi); sn = sin(phi)
        for j in 1:np
            r = profile_r[j]
            y = profile_y[j]
            x = r*c; z = -r*sn
            cy = clamp(y, -half, half)               # nearest point on the spine
            nx = x; ny = y - cy; nz = z
            nl = hypot(nx, ny, nz); nl > 0 && (nx/=nl; ny/=nl; nz/=nl)
            vi = s * np + j
            pbase = 3vi - 2
            positions[pbase] = x
            positions[pbase + 1] = y
            positions[pbase + 2] = z
            normals[pbase] = nx
            normals[pbase + 1] = ny
            normals[pbase + 2] = nz
            ubase = 2vi - 1
            uvs[ubase] = u
            uvs[ubase + 1] = (j - 1) / (np - 1)
        end
    end
    out = 1
    @inbounds for s in 0:radial_segments-1, j in 0:np-2
        a = s*np + j + 1; b = (s+1)*np + j + 1
        c = (s+1)*np + j + 2; d = s*np + j + 2
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

@inline _edge_key(a::Int, b::Int)::UInt128 = _edge_key(UInt128, a, b)
@inline _edge_key_first(key::UInt64) = Int(key >> 32)
@inline _edge_key_second(key::UInt64) = Int(key & UInt64(0xffffffff))
@inline _edge_key_first(key::UInt128) = Int(key >> 64)
@inline _edge_key_second(key::UInt128) = Int(key & UInt128(typemax(UInt64)))

@inline function _record_edge_face!(
    edge_keys::Vector{K},
    edge_record_ids::Vector{Int},
    ordered_edges::Vector{K},
    edge_normals::Vector{Vec3{Float64}},
    edge_counts::Vector{UInt8},
    edge_features::Vector{Bool},
    a::Int, b::Int, n::Vec3{Float64}, cosT::Float64,
) where {K<:Union{UInt64,UInt128}}
    key = _edge_key(K, a, b)
    mask = length(edge_keys) - 1
    idx = Int(hash(key) & UInt(mask)) + 1
    while true
        existing = edge_keys[idx]
        if existing == zero(K)
            edge_keys[idx] = key
            record_id = length(ordered_edges) + 1
            edge_record_ids[idx] = record_id
            push!(ordered_edges, key)
            push!(edge_normals, n)
            push!(edge_counts, UInt8(1))
            push!(edge_features, false)
            return nothing
        elseif existing == key
            record_id = edge_record_ids[idx]
            count = edge_counts[record_id]
            if count == UInt8(1)
                edge_features[record_id] = dot(edge_normals[record_id], n) < cosT
                edge_counts[record_id] = UInt8(2)
            else
                # More than two incident faces make this a non-manifold edge.
                # Expose it regardless of face order or normal similarity.
                edge_features[record_id] = true
                edge_counts[record_id] = count == typemax(UInt8) ? count :
                                         count + UInt8(1)
            end
            return nothing
        end
        idx = idx == length(edge_keys) ? 1 : idx + 1
    end
end

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

@inline function _write_wireframe_key!(
    positions::Vector{Float64}, geo::BufferGeometry, key::K,
    vi::Int, pout::Int,
) where {K<:Union{UInt64,UInt128}}
    va = get_vertex(geo, _edge_key_first(key))
    vb = get_vertex(geo, _edge_key_second(key))
    positions[pout] = va.x
    positions[pout + 1] = va.y
    positions[pout + 2] = va.z
    positions[pout + 3] = vb.x
    positions[pout + 4] = vb.y
    positions[pout + 5] = vb.z
    return vi + 2, pout + 6
end

"""All unique triangle edges as line segments (three.js `WireframeGeometry`).
Returned as a line BufferGeometry (`n_faces = 0`; vertices are segment pairs)."""
function wireframe_geometry(geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "wireframe_geometry")
    geo.n_vertices <= _EDGE_KEY32_MAX ?
        _wireframe_geometry_keyed(geo, UInt64) :
        _wireframe_geometry_keyed(geo, UInt128)
end

function _wireframe_geometry_keyed(geo::BufferGeometry, ::Type{K}) where {K<:Union{UInt64,UInt128}}
    max_edges = 3 * geo.n_faces
    seen = zeros(K, _edge_table_capacity(max_edges))
    ordered_edges = Vector{K}()
    sizehint!(ordered_edges, _edge_record_hint(geo, max_edges))
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        _record_wireframe_edge!(seen, ordered_edges, i1, i2)
        _record_wireframe_edge!(seen, ordered_edges, i2, i3)
        _record_wireframe_edge!(seen, ordered_edges, i3, i1)
    end
    positions = Vector{Float64}(undef, 6 * length(ordered_edges))
    vi = 0
    pout = 1
    @inbounds for key in ordered_edges
        vi, pout = _write_wireframe_key!(positions, geo, key, vi, pout)
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], vi, 0)
end

# Round relative positions to merge coincident (duplicated) vertices for
# adjacency without making the result depend on a uniform translation.
@inline function _edge_relative_key_component(value::Float64,
                                              anchor::Float64; nd::Int=6)
    relative = value - anchor
    isfinite(relative) || (relative = value)
    rounded = round(relative, digits=nd)
    return iszero(rounded) ? 0.0 : rounded
end

@inline _pkey(v::Vec3, anchor::Vec3; nd=6) = (
    _edge_relative_key_component(v.x, anchor.x; nd=nd),
    _edge_relative_key_component(v.y, anchor.y; nd=nd),
    _edge_relative_key_component(v.z, anchor.z; nd=nd),
)

@inline function _canonical_edge_vertex!(
    canonical_ids::Vector{Int},
    canon::Dict{Tuple{Float64,Float64,Float64},Int},
    csrc::Vector{Int},
    cpos_len::Int,
    geo::BufferGeometry,
    anchor::Vec3,
    vi::Int,
)
    cached = canonical_ids[vi]
    cached != 0 && return cached, cpos_len
    v = get_vertex(geo, vi)
    key = _pkey(v, anchor)
    c = get(canon, key, 0)
    if c == 0
        cpos_len += 1
        csrc[cpos_len] = vi
        canon[key] = cpos_len
        c = cpos_len
    end
    canonical_ids[vi] = c
    return c, cpos_len
end

"""Feature edges whose adjacent faces differ in orientation by more than
`threshold_angle`, plus boundary edges (three.js `EdgesGeometry`). Returned as a
line BufferGeometry. Coincident vertices are merged by position first."""
function edges_geometry(geo::BufferGeometry; threshold_angle=0.349)   # ≈20°
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
    # Canonicalize vertices by position.
    canon = Dict{Tuple{Float64,Float64,Float64}, Int}()
    sizehint!(canon, geo.n_vertices)
    canonical_ids = zeros(Int, geo.n_vertices)
    csrc = Vector{Int}(undef, geo.n_vertices)
    cpos_len = 0
    # edge (lo,hi) -> first normal, adjacent face count, sharp-on-second-face
    max_edges = 3 * geo.n_faces
    edge_keys = zeros(K, _edge_table_capacity(max_edges))
    edge_record_ids = zeros(Int, length(edge_keys))
    ordered_edges = Vector{K}()
    edge_normals = Vector{Vec3{Float64}}()
    edge_counts = Vector{UInt8}()
    edge_features = Bool[]
    edge_hint = _edge_record_hint(geo, max_edges)
    sizehint!(ordered_edges, edge_hint)
    sizehint!(edge_normals, edge_hint)
    sizehint!(edge_counts, edge_hint)
    sizehint!(edge_features, edge_hint)
    anchor = geo.n_vertices == 0 ? Vec3() : get_vertex(geo, 1)
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        n = triangle_normal(Triangle(v1, v2, v3))
        c1, cpos_len = _canonical_edge_vertex!(canonical_ids, canon, csrc,
                                               cpos_len, geo, anchor, i1)
        c2, cpos_len = _canonical_edge_vertex!(canonical_ids, canon, csrc,
                                               cpos_len, geo, anchor, i2)
        c3, cpos_len = _canonical_edge_vertex!(canonical_ids, canon, csrc,
                                               cpos_len, geo, anchor, i3)
        _record_edge_face!(edge_keys, edge_record_ids, ordered_edges, edge_normals,
                           edge_counts, edge_features, c1, c2, n, cosT)
        _record_edge_face!(edge_keys, edge_record_ids, ordered_edges, edge_normals,
                           edge_counts, edge_features, c2, c3, n, cosT)
        _record_edge_face!(edge_keys, edge_record_ids, ordered_edges, edge_normals,
                           edge_counts, edge_features, c3, c1, n, cosT)
    end
    feature_edges = 0
    @inbounds for i in eachindex(ordered_edges)
        (edge_counts[i] == UInt8(1) || edge_features[i]) && (feature_edges += 1)
    end
    positions = Vector{Float64}(undef, 6 * feature_edges)
    vi = 0
    pout = 1
    @inbounds for i in eachindex(ordered_edges)
        (edge_counts[i] == UInt8(1) || edge_features[i]) || continue
        key = ordered_edges[i]
        a = get_vertex(geo, csrc[_edge_key_first(key)])
        b = get_vertex(geo, csrc[_edge_key_second(key)])
        positions[pout] = a.x
        positions[pout + 1] = a.y
        positions[pout + 2] = a.z
        positions[pout + 3] = b.x
        positions[pout + 4] = b.y
        positions[pout + 5] = b.z
        vi += 2
        pout += 6
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], vi, 0)
end
