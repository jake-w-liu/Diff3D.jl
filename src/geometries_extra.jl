# --------------------------------------------------------------------------
# Additional geometry generators mirroring three.js: the platonic-solid family
# via a subdividing PolyhedronGeometry, convex hulls, surfaces of revolution /
# sweeps (Lathe, Tube), profile extrusion (Shape/Extrude), Capsule, and the
# Edges/Wireframe line geometries.
# --------------------------------------------------------------------------

# ========================== PolyhedronGeometry ==========================
# Subdivide each base triangle into (detail+1)² faces and project to a sphere
# of the given radius. Vertices are non-indexed (3 per face).

function PolyhedronGeometry(base_verts::Vector{<:Vec3}, base_faces::Vector{NTuple{3,Int}};
                            radius=1.0, detail=0)
    radius = _geometry_finite_scalar(radius, "PolyhedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "PolyhedronGeometry detail")
    verts = Vec3{Float64}[]
    for (i, v) in enumerate(base_verts)
        push!(verts, Vec3(_geometry_finite_float(v.x, "PolyhedronGeometry base vertex $i"),
                          _geometry_finite_float(v.y, "PolyhedronGeometry base vertex $i"),
                          _geometry_finite_float(v.z, "PolyhedronGeometry base vertex $i")))
    end
    nbase = length(verts)
    for face in base_faces
        i1, i2, i3 = face
        (1 <= i1 <= nbase && 1 <= i2 <= nbase && 1 <= i3 <= nbase) ||
            throw(ArgumentError("PolyhedronGeometry face indices must reference base vertices"))
    end
    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    vi = 0
    function emit!(a::Vec3, b::Vec3, c::Vec3)
        for v in (a, b, c)
            d = normalize(v)                  # unit direction, independent of radius
            p = d * radius
            push!(positions, p.x, p.y, p.z)
            push!(normals, d.x, d.y, d.z)
            # Derive the spherical UV from the unit direction, not p.y/radius:
            # at radius=0 the latter is 0/0 = NaN, while asin(d.y) stays finite.
            push!(uvs, atan(d.z, d.x)/(2π) + 0.5, asin(clamp(d.y, -1.0, 1.0))/π + 0.5)
        end
        push!(indices, vi+1, vi+2, vi+3); vi += 3
    end
    cols = detail + 1
    for (i1, i2, i3) in base_faces
        A = verts[i1]; B = verts[i2]; C = verts[i3]
        bary(p, q) = A*((cols - p - q)/cols) + B*(p/cols) + C*(q/cols)
        for i in 0:cols-1, j in 0:(cols-1-i)
            emit!(bary(i, j), bary(i+1, j), bary(i, j+1))
            if j < cols - 1 - i
                emit!(bary(i+1, j), bary(i+1, j+1), bary(i, j+1))
            end
        end
    end
    BufferGeometry(positions, normals, uvs, indices, vi, length(indices) ÷ 3)
end

function OctahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_scalar(radius, "OctahedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "OctahedronGeometry detail")
    v = [Vec3(1.0,0,0), Vec3(-1.0,0,0), Vec3(0.0,1.0,0), Vec3(0.0,-1.0,0),
         Vec3(0.0,0,1.0), Vec3(0.0,0,-1.0)]
    f = NTuple{3,Int}[(1,3,5),(1,5,4),(1,4,6),(1,6,3),(2,3,6),(2,6,4),(2,4,5),(2,5,3)]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

function TetrahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_scalar(radius, "TetrahedronGeometry radius")
    detail = _geometry_nonnegative_int(detail, "TetrahedronGeometry detail")
    v = [Vec3(1.0,1,1), Vec3(-1.0,-1,1), Vec3(-1.0,1,-1), Vec3(1.0,-1,-1)]
    f = NTuple{3,Int}[(3,2,1),(1,4,3),(2,4,1),(3,4,2)]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

function DodecahedronGeometry(; radius=1.0, detail=0)
    radius = _geometry_finite_scalar(radius, "DodecahedronGeometry radius")
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
    raw = Vec3{Float64}[]
    for p in points
        q = Vec3(_geometry_finite_float(p.x, "ConvexGeometry points"),
                 _geometry_finite_float(p.y, "ConvexGeometry points"),
                 _geometry_finite_float(p.z, "ConvexGeometry points"))
        push!(raw, q)
    end
    isempty(raw) && throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    scale = max(1.0, maximum(max(abs(p.x), abs(p.y), abs(p.z)) for p in raw))
    eps = 1e-9 * scale
    deduped = Vec3{Float64}[]
    for p in raw
        any(q -> norm(p - q) <= eps, deduped) || push!(deduped, p)
    end
    length(deduped) >= 4 ||
        throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    return deduped, eps
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
    seen = Set{Tuple{Vararg{Int}}}()
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
    for idx in face_indices
        d = points[idx] - center
        push!(projected, (dot(d, u), dot(d, v), idx))
    end
    sort!(projected, by=t -> (t[1], t[2], t[3]))

    filtered = Tuple{Float64,Float64,Int}[]
    for p in projected
        if isempty(filtered) ||
           hypot(p[1] - filtered[end][1], p[2] - filtered[end][2]) > eps
            push!(filtered, p)
        end
    end

    cross2(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) -
                      (a[2] - o[2]) * (b[1] - o[1])
    lower = Tuple{Float64,Float64,Int}[]
    for p in filtered
        while length(lower) >= 2 &&
              cross2(lower[end - 1], lower[end], p) <= eps
            pop!(lower)
        end
        push!(lower, p)
    end
    upper = Tuple{Float64,Float64,Int}[]
    for p in Iterators.reverse(filtered)
        while length(upper) >= 2 &&
              cross2(upper[end - 1], upper[end], p) <= eps
            pop!(upper)
        end
        push!(upper, p)
    end
    hull = [p[3] for p in vcat(lower[1:end - 1], upper[1:end - 1])]
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
    clean, eps = _convex_clean_points(points)
    _convex_has_volume(clean, eps) ||
        throw(ArgumentError("ConvexGeometry needs at least four non-coplanar points"))
    support_faces = _convex_support_faces(clean, eps)
    isempty(support_faces) &&
        throw(ArgumentError("ConvexGeometry could not find hull support faces"))

    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    vi = 0
    for (face_indices, normal) in support_faces
        hull = _convex_face_hull(clean, face_indices, normal, eps)
        length(hull) >= 3 || continue
        origin = clean[hull[1]]
        for k in 2:(length(hull) - 1)
            tri = (origin, clean[hull[k]], clean[hull[k + 1]])
            face_normal = normalize(cross(tri[2] - tri[1], tri[3] - tri[1]))
            dot(face_normal, normal) < 0.0 &&
                (tri = (tri[1], tri[3], tri[2]); face_normal = -face_normal)
            for p in tri
                push!(positions, p.x, p.y, p.z)
                push!(normals, face_normal.x, face_normal.y, face_normal.z)
                push!(uvs, p.x, p.y)
                vi += 1
                push!(indices, vi)
            end
        end
    end
    length(indices) >= 12 ||
        throw(ArgumentError("ConvexGeometry produced no non-degenerate hull volume"))
    return BufferGeometry(positions, normals, uvs, indices, vi, length(indices) ÷ 3)
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

    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    for i in 0:segments
        phi = phi_start + i/segments * phi_length
        c = cos(phi); s = sin(phi)
        for j in 1:np
            pt = points[j]
            push!(positions, pt.x*c, pt.y, -pt.x*s)
            jm = max(j-1, 1); jp = min(j+1, np)
            dx = points[jp].x - points[jm].x; dy = points[jp].y - points[jm].y
            nr = dy; nh = -dx                      # outward profile normal
            nx = nr*c; ny = nh; nz = -nr*s
            nl = sqrt(nx^2 + ny^2 + nz^2); nl > 0 && (nx/=nl; ny/=nl; nz/=nl)
            push!(normals, nx, ny, nz)
            push!(uvs, i/segments, (j-1)/(np-1))
        end
    end
    for i in 0:segments-1, j in 0:np-2
        a = i*np + j + 1; b = (i+1)*np + j + 1
        c = (i+1)*np + j + 2; d = i*np + j + 2
        push!(indices, a, b, d, b, c, d)
    end
    BufferGeometry(positions, normals, uvs, indices, (segments+1)*np, length(indices) ÷ 3)
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

function TubeGeometry(path::Vector{<:Vec3}; radius=1.0, radial_segments=8)
    n = length(path)
    _validate_tube_path(path)
    radius = _geometry_finite_scalar(radius, "TubeGeometry radius")
    radial_segments = _clamp_seg(radial_segments, 3, "TubeGeometry radial_segments")   # clamp so 0 can't make j/radial_segments NaN

    tangents = [normalize(path[min(i+1,n)] - path[max(i-1,1)]) for i in 1:n]
    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    # Initial frame from the first tangent, parallel-transported along the path
    # (as in three.js computeFrenetFrames) so the frame never flips between rings.
    T1 = tangents[1]
    refv = abs(T1.y) < 0.99 ? Vec3(0.0,1.0,0.0) : Vec3(1.0,0.0,0.0)
    N = normalize(cross(refv, T1)); B = cross(T1, N)
    for i in 1:n
        T = tangents[i]
        if i > 1
            Np = N - T*dot(N, T)               # project previous N off the new tangent
            N = norm(Np) > 1e-9 ? normalize(Np) : normalize(cross(B, T))
            B = cross(T, N)
        end
        for j in 0:radial_segments
            v = j/radial_segments * 2π
            normal = N*cos(v) + B*sin(v)
            p = path[i] + normal*radius
            push!(positions, p.x, p.y, p.z)
            push!(normals, normal.x, normal.y, normal.z)
            push!(uvs, (i-1)/(n-1), j/radial_segments)
        end
    end
    rs1 = radial_segments + 1
    for i in 0:n-2, j in 0:radial_segments-1
        a = i*rs1 + j + 1; b = (i+1)*rs1 + j + 1
        c = (i+1)*rs1 + j + 2; d = i*rs1 + j + 2
        push!(indices, a, d, b, b, d, c)
    end
    BufferGeometry(positions, normals, uvs, indices, n*rs1, length(indices) ÷ 3)
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
    tf = Float64(_geometry_finite_scalar(tension, "CatmullRomCurve tension"))
    return CatmullRomCurve([_catmull_rom_control_point(p) for p in points],
                           curve_type, Bool(closed), tf)
end

function _catmull_rom_uniform(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3,
                              t::Float64, tension::Float64)
    t2 = t * t
    t3 = t2 * t
    m1 = (p2 - p0) * tension
    m2 = (p3 - p1) * tension
    return (p1 * (2t3 - 3t2 + 1.0) +
            m1 * (t3 - 2t2 + t) +
            p2 * (-2t3 + 3t2) +
            m2 * (t3 - t2))
end

function _catmull_rom_param_lerp(a::Vec3, b::Vec3, t0::Float64,
                                 t1::Float64, t::Float64)
    denom = t1 - t0
    denom > 0.0 || return a
    return a * ((t1 - t) / denom) + b * ((t - t0) / denom)
end

function _catmull_rom_interval(a::Vec3, b::Vec3, alpha::Float64)
    return max(norm(b - a)^alpha, eps(Float64))
end

function _catmull_rom_nonuniform(p0::Vec3, p1::Vec3, p2::Vec3, p3::Vec3,
                                 u::Float64, alpha::Float64)
    t0 = 0.0
    t1 = t0 + _catmull_rom_interval(p0, p1, alpha)
    t2 = t1 + _catmull_rom_interval(p1, p2, alpha)
    t3 = t2 + _catmull_rom_interval(p2, p3, alpha)
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
    segs = _geometry_positive_int(segments, "catmull_rom_points segments")
    positions = Vector{Float64}(undef, 3 * (segs + 1))
    for i in 0:segs
        p = catmull_rom_point(curve, i / segs)
        base = 3i + 1
        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[], segs + 1, 0)
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
end

struct NURBSVolume
    degree_u::Int
    degree_v::Int
    degree_w::Int
    knots_u::Vector{Float64}
    knots_v::Vector{Float64}
    knots_w::Vector{Float64}
    control_points::Vector{Vector{Vector{Vec4{Float64}}}}
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

function NURBSSurface(degree_u::Integer, degree_v::Integer,
                      knots_u, knots_v, control_points)
    p = _nurbs_degree(degree_u)
    q = _nurbs_degree(degree_v)
    cps = _nurbs_surface_points(control_points)
    ku = _nurbs_knots(knots_u, p, length(cps), "NURBSSurface u")
    kv = _nurbs_knots(knots_v, q, length(cps[1]), "NURBSSurface v")
    return NURBSSurface(p, q, ku, kv, cps)
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

function NURBSVolume(degree_u::Integer, degree_v::Integer, degree_w::Integer,
                     knots_u, knots_v, knots_w, control_points)
    p = _nurbs_degree(degree_u)
    q = _nurbs_degree(degree_v)
    r = _nurbs_degree(degree_w)
    cps = _nurbs_volume_points(control_points)
    ku = _nurbs_knots(knots_u, p, length(cps), "NURBSVolume u")
    kv = _nurbs_knots(knots_v, q, length(cps[1]), "NURBSVolume v")
    kw = _nurbs_knots(knots_w, r, length(cps[1][1]), "NURBSVolume w")
    return NURBSVolume(p, q, r, ku, kv, kw, cps)
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

_nurbs_basis_scratch(degree::Int) = Vector{Float64}(undef, 3 * (degree + 1))

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
            denom = scratch[right0 + r + 2] + scratch[left0 + j - r + 1]
            temp = abs(denom) > eps(Float64) ? scratch[r + 1] / denom : 0.0
            scratch[r + 1] = saved + scratch[right0 + r + 2] * temp
            saved = scratch[left0 + j - r + 1] * temp
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
    return u0 + tf * (u1 - u0)
end

function _nurbs_finish_point(x::Float64, y::Float64, z::Float64, w::Float64)
    abs(w) > eps(Float64) ||
        throw(ArgumentError("NURBS evaluation produced zero homogeneous weight"))
    return Vec3(x / w, y / w, z / w)
end

function _nurbs_point(curve::NURBSCurve, t::Real, basis::Vector{Float64})
    npoints = length(curve.control_points)
    u = _nurbs_parameter(t, curve.knots, curve.degree, npoints,
                         "NURBS curve parameter t")
    span = _nurbs_span(curve.degree, curve.knots, npoints, u)
    _nurbs_basis!(basis, span, u, curve.degree, curve.knots)
    x = 0.0; y = 0.0; z = 0.0; w = 0.0
    for j in 0:curve.degree
        cp = curve.control_points[span - curve.degree + j + 1]
        coeff = basis[j + 1] * cp.w
        x += cp.x * coeff
        y += cp.y * coeff
        z += cp.z * coeff
        w += coeff
    end
    return _nurbs_finish_point(x, y, z, w)
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
    x = 0.0; y = 0.0; z = 0.0; w = 0.0
    for i in 0:surface.degree_u, j in 0:surface.degree_v
        cp = surface.control_points[span_u - surface.degree_u + i + 1][span_v - surface.degree_v + j + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * cp.w
        x += cp.x * coeff
        y += cp.y * coeff
        z += cp.z * coeff
        w += coeff
    end
    return _nurbs_finish_point(x, y, z, w)
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
    x = 0.0; y = 0.0; z = 0.0; weight = 0.0
    for i in 0:volume.degree_u, j in 0:volume.degree_v, k in 0:volume.degree_w
        cp = volume.control_points[span_u - volume.degree_u + i + 1][span_v - volume.degree_v + j + 1][span_w - volume.degree_w + k + 1]
        coeff = basis_u[i + 1] * basis_v[j + 1] * basis_w[k + 1] * cp.w
        x += cp.x * coeff
        y += cp.y * coeff
        z += cp.z * coeff
        weight += coeff
    end
    return _nurbs_finish_point(x, y, z, weight)
end

function nurbs_point(volume::NURBSVolume, u::Real, v::Real, wparam::Real)
    return _nurbs_point(volume, u, v, wparam, _nurbs_basis_scratch(volume.degree_u),
                        _nurbs_basis_scratch(volume.degree_v),
                        _nurbs_basis_scratch(volume.degree_w))
end

function NURBSCurveGeometry(curve::NURBSCurve; segments::Integer=200)
    segs = _geometry_positive_int(segments, "NURBSCurveGeometry segments")
    positions = Vector{Float64}(undef, 3 * (segs + 1))
    basis = _nurbs_basis_scratch(curve.degree)
    for i in 0:segs
        p = _nurbs_point(curve, i / segs, basis)
        base = 3i + 1
        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[], segs + 1, 0)
end

function _parametric_normals(positions::Vector{Float64}, indices::Vector{Int}, nvertices::Int)
    normals = zeros(Float64, 3 * nvertices)
    for fi in 1:(length(indices) ÷ 3)
        i1 = indices[3fi - 2]
        i2 = indices[3fi - 1]
        i3 = indices[3fi]
        p1 = Vec3(positions[3i1 - 2], positions[3i1 - 1], positions[3i1])
        p2 = Vec3(positions[3i2 - 2], positions[3i2 - 1], positions[3i2])
        p3 = Vec3(positions[3i3 - 2], positions[3i3 - 1], positions[3i3])
        fn = cross(p2 - p1, p3 - p1)
        for idx in (i1, i2, i3)
            base = 3idx - 2
            normals[base] += fn.x
            normals[base + 1] += fn.y
            normals[base + 2] += fn.z
        end
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
    nvertices = row * (vs + 1)
    positions = Vector{Float64}(undef, 3 * nvertices)
    uvs = Vector{Float64}(undef, 2 * nvertices)
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
    indices = Vector{Int}(undef, 6 * us * vs)
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
    return BufferGeometry(positions, normals, uvs, indices, nvertices, 2 * us * vs)
end

function NURBSSurfaceGeometry(surface::NURBSSurface; slices::Integer=20,
                              stacks::Integer=20)
    us = _geometry_positive_int(slices, "ParametricGeometry slices")
    vs = _geometry_positive_int(stacks, "ParametricGeometry stacks")
    row = us + 1
    nvertices = row * (vs + 1)
    positions = Vector{Float64}(undef, 3 * nvertices)
    uvs = Vector{Float64}(undef, 2 * nvertices)
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
    indices = Vector{Int}(undef, 6 * us * vs)
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
    return BufferGeometry(positions, normals, uvs, indices, nvertices, 2 * us * vs)
end

# ========================== Shape / Extrude ==========================
# A Shape is a simple polygon in the xy-plane (Vector{Vec2}). ShapeGeometry
# fills it; ExtrudeGeometry sweeps it to depth along +z, or along a sampled 3D
# path. Caps are fan-triangulated (correct for convex shapes).

function _shape_area2(shape::AbstractVector{<:Vec2})
    area2 = 0.0
    for i in eachindex(shape)
        p1 = shape[i]
        p2 = shape[i == lastindex(shape) ? firstindex(shape) : i + 1]
        area2 += p1.x * p2.y - p2.x * p1.y
    end
    return area2
end

_shape_len(v::Vec2) = hypot(v.x, v.y)
_shape_normalize(v::Vec2) = v * (1 / _shape_len(v))

function _extrude_clean_shape(shape::AbstractVector{<:Vec2})
    length(shape) >= 3 || throw(ArgumentError("ExtrudeGeometry shape needs at least three points"))
    clean = Vec2{Float64}[]
    scale = 1.0
    for p in shape
        q = Vec2(_geometry_finite_float(p.x, "ExtrudeGeometry shape points"),
                 _geometry_finite_float(p.y, "ExtrudeGeometry shape points"))
        scale = max(scale, abs(q.x), abs(q.y))
        if isempty(clean) || _shape_len(q - clean[end]) > 1e-12 * scale
            push!(clean, q)
        end
    end
    if length(clean) > 1 && _shape_len(clean[end] - clean[1]) <= 1e-12 * scale
        pop!(clean)
    end
    length(clean) >= 3 || throw(ArgumentError("ExtrudeGeometry shape needs at least three points"))
    _shape_area2(clean) > 0.0 || reverse!(clean)
    abs(_shape_area2(clean)) > 1e-12 * scale^2 ||
        throw(ArgumentError("ExtrudeGeometry shape area must be non-zero"))
    return clean
end

function _extrude_clean_path(path::AbstractVector{<:Vec3})
    length(path) >= 2 || throw(ArgumentError("ExtrudeGeometry extrude_path needs at least two points"))
    raw = Vec3{Float64}[]
    scale = 1.0
    for p in path
        q = Vec3(_geometry_finite_float(p.x, "ExtrudeGeometry extrude_path points"),
                 _geometry_finite_float(p.y, "ExtrudeGeometry extrude_path points"),
                 _geometry_finite_float(p.z, "ExtrudeGeometry extrude_path points"))
        scale = max(scale, abs(q.x), abs(q.y), abs(q.z))
        push!(raw, q)
    end
    eps = 1e-9 * scale
    closed = norm(raw[end] - raw[1]) <= eps
    clean = closed ? raw[1:end - 1] : raw
    filtered = Vec3{Float64}[]
    for p in clean
        if isempty(filtered) || norm(p - filtered[end]) > eps
            push!(filtered, p)
        end
    end
    length(filtered) >= 2 ||
        throw(ArgumentError("ExtrudeGeometry extrude_path needs at least two distinct points"))
    return filtered, closed, eps
end

function _extrude_path_tangents(path::Vector{Vec3{Float64}}, closed::Bool, eps::Float64)
    n = length(path)
    tangents = Vec3{Float64}[]
    for i in 1:n
        prev = closed ? path[mod1(i - 1, n)] : path[max(i - 1, 1)]
        nxt = closed ? path[mod1(i + 1, n)] : path[min(i + 1, n)]
        t = nxt - prev
        if norm(t) <= eps
            forward = path[mod1(i + 1, n)] - path[i]
            backward = path[i] - path[mod1(i - 1, n)]
            t = norm(forward) > eps ? forward : backward
        end
        norm(t) > eps ||
            throw(ArgumentError("ExtrudeGeometry extrude_path contains degenerate segment"))
        push!(tangents, normalize(t))
    end
    return tangents
end

function _extrude_shape_vertex_normals(shape::Vector{Vec2{Float64}})
    np = length(shape)
    edge_normals = Vec2{Float64}[]
    for i in 1:np
        p1 = shape[i]
        p2 = shape[mod1(i + 1, np)]
        edge = p2 - p1
        len = _shape_len(edge)
        len > 0.0 || throw(ArgumentError("ExtrudeGeometry shape contains degenerate edge"))
        push!(edge_normals, Vec2(edge.y / len, -edge.x / len))
    end
    normals = Vec2{Float64}[]
    for i in 1:np
        n = edge_normals[mod1(i - 1, np)] + edge_normals[i]
        push!(normals, _shape_len(n) > 1e-12 ? _shape_normalize(n) : edge_normals[i])
    end
    return normals
end

function _extrude_path_geometry(shape_in::AbstractVector{<:Vec2},
                                path_in::AbstractVector{<:Vec3})
    shape = _extrude_clean_shape(shape_in)
    path, closed, eps = _extrude_clean_path(path_in)
    tangents = _extrude_path_tangents(path, closed, eps)
    shape_normals = _extrude_shape_vertex_normals(shape)
    np = length(shape)
    nr = length(path)
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    frames = Tuple{Vec3{Float64},Vec3{Float64}}[]

    T = tangents[1]
    refv = abs(T.y) < 0.99 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    N = normalize(cross(refv, T))
    B = cross(T, N)
    for i in 1:nr
        T = tangents[i]
        if i > 1
            projected = N - T * dot(N, T)
            N = norm(projected) > eps ? normalize(projected) : normalize(cross(B, T))
            B = cross(T, N)
        end
        push!(frames, (N, B))
        for j in 1:np
            pt = shape[j]
            normal2 = shape_normals[j]
            p = path[i] + N * pt.x + B * pt.y
            n = normalize(N * normal2.x + B * normal2.y)
            push!(positions, p.x, p.y, p.z)
            push!(normals, n.x, n.y, n.z)
            push!(uvs, (i - 1) / max(nr - 1, 1), (j - 1) / np)
        end
    end

    segments = closed ? nr : nr - 1
    for i in 1:segments
        i2 = i == nr ? 1 : i + 1
        for j in 1:np
            j2 = mod1(j + 1, np)
            a = (i - 1) * np + j
            b = (i - 1) * np + j2
            c = (i2 - 1) * np + j2
            d = (i2 - 1) * np + j
            push!(indices, a, b, c, a, c, d)
        end
    end

    if !closed
        for (ring, cap_normal, reverse_cap) in ((1, -tangents[1], true),
                                                (nr, tangents[end], false))
            start = length(positions) ÷ 3
            N, B = frames[ring]
            cap_indices = Int[]
            for pt in shape
                p = path[ring] + N * pt.x + B * pt.y
                push!(positions, p.x, p.y, p.z)
                push!(normals, cap_normal.x, cap_normal.y, cap_normal.z)
                push!(uvs, pt.x, pt.y)
                push!(cap_indices, start + length(cap_indices) + 1)
            end
            for k in 2:(np - 1)
                if reverse_cap
                    push!(indices, cap_indices[1], cap_indices[k + 1], cap_indices[k])
                else
                    push!(indices, cap_indices[1], cap_indices[k], cap_indices[k + 1])
                end
            end
        end
    end

    return BufferGeometry(positions, normals, uvs, indices,
                          length(positions) ÷ 3, length(indices) ÷ 3)
end

"""Filled planar polygon (z = 0), normal +z."""
function ShapeGeometry(shape::Vector{<:Vec2})
    shape = _extrude_clean_shape(shape)   # normalize to CCW (+z normal)
    np = length(shape)
    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    for pt in shape
        push!(positions, pt.x, pt.y, 0.0); push!(normals, 0.0, 0.0, 1.0)
        push!(uvs, pt.x, pt.y)
    end
    for k in 2:np-1
        push!(indices, 1, k, k+1)
    end
    BufferGeometry(positions, normals, uvs, indices, np, length(indices) ÷ 3)
end

"""Extrude a planar polygon `shape` to `depth` along +z, or along `extrude_path`."""
function ExtrudeGeometry(shape::Vector{<:Vec2}; depth=1.0, extrude_path=nothing)
    extrude_path !== nothing && return _extrude_path_geometry(shape, extrude_path)
    depth = _geometry_finite_scalar(depth, "ExtrudeGeometry depth")
    # Normalize to CCW (like the extrude_path branch) so the hard-coded cap and
    # side-wall normals stay consistent with the winding for any input orientation.
    shape = _extrude_clean_shape(shape)
    np = length(shape)
    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    vi = 0
    pushv(x,y,z,nx,ny,nz,u,v) = (push!(positions,x,y,z); push!(normals,nx,ny,nz);
                                  push!(uvs,u,v); vi += 1; vi)
    front = [pushv(pt.x, pt.y, 0.0,   0.0,0.0,-1.0, 0.0,0.0) for pt in shape]
    back  = [pushv(pt.x, pt.y, depth, 0.0,0.0, 1.0, 1.0,1.0) for pt in shape]
    for k in 2:np-1
        push!(indices, front[1], front[k+1], front[k])   # -z face
        push!(indices, back[1],  back[k],    back[k+1])   # +z face
    end
    for i in 1:np
        i2 = i % np + 1
        p1 = shape[i]; p2 = shape[i2]
        ex = p2.x - p1.x; ey = p2.y - p1.y
        nx = ey; ny = -ex; nl = sqrt(nx^2 + ny^2); nl > 0 && (nx/=nl; ny/=nl)
        a = pushv(p1.x,p1.y,0.0,   nx,ny,0.0, 0.0,0.0)
        b = pushv(p2.x,p2.y,0.0,   nx,ny,0.0, 1.0,0.0)
        c = pushv(p2.x,p2.y,depth, nx,ny,0.0, 1.0,1.0)
        d = pushv(p1.x,p1.y,depth, nx,ny,0.0, 0.0,1.0)
        push!(indices, a, b, c, a, c, d)
    end
    BufferGeometry(positions, normals, uvs, indices, vi, length(indices) ÷ 3)
end

# ========================== CapsuleGeometry ==========================
# Cylinder of `length` capped by two hemispheres of `radius`, revolved about y.

function CapsuleGeometry(; radius=1.0, length=1.0, cap_segments=8, radial_segments=16)
    radius = _geometry_finite_scalar(radius, "CapsuleGeometry radius")
    length = _geometry_finite_scalar(length, "CapsuleGeometry length")
    # clamp so 0 can't make i/cap_segments or s/radial_segments a 0/0 = NaN
    cap_segments = _clamp_seg(cap_segments, 1, "CapsuleGeometry cap_segments")
    radial_segments = _clamp_seg(radial_segments, 3, "CapsuleGeometry radial_segments")
    half = length / 2
    profile = Tuple{Float64,Float64}[]
    for i in 0:cap_segments                          # top hemisphere: pole → equator
        a = i/cap_segments * (π/2)
        push!(profile, (radius*sin(a), half + radius*cos(a)))
    end
    for i in 0:cap_segments                          # bottom hemisphere: equator → pole
        a = i/cap_segments * (π/2)
        push!(profile, (radius*cos(a), -half - radius*sin(a)))
    end
    np = Base.length(profile)
    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    for s in 0:radial_segments
        phi = s/radial_segments * 2π
        c = cos(phi); sn = sin(phi)
        for (j, (r, y)) in enumerate(profile)
            x = r*c; z = -r*sn
            cy = clamp(y, -half, half)               # nearest point on the spine
            nx = x; ny = y - cy; nz = z
            nl = sqrt(nx^2 + ny^2 + nz^2); nl > 0 && (nx/=nl; ny/=nl; nz/=nl)
            push!(positions, x, y, z); push!(normals, nx, ny, nz)
            push!(uvs, s/radial_segments, (j-1)/(np-1))
        end
    end
    for s in 0:radial_segments-1, j in 0:np-2
        a = s*np + j + 1; b = (s+1)*np + j + 1
        c = (s+1)*np + j + 2; d = s*np + j + 2
        push!(indices, a, d, b, b, d, c)
    end
    BufferGeometry(positions, normals, uvs, indices, (radial_segments+1)*np, Base.length(indices) ÷ 3)
end

# ========================== Edges / Wireframe ==========================

"""All unique triangle edges as line segments (three.js `WireframeGeometry`).
Returned as a line BufferGeometry (`n_faces = 0`; vertices are segment pairs)."""
function wireframe_geometry(geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "wireframe_geometry")
    seen = Set{Tuple{Int,Int}}()
    positions = Float64[]; indices = Int[]; vi = 0
    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        for (a, b) in ((i1,i2), (i2,i3), (i3,i1))
            key = a < b ? (a, b) : (b, a)
            key in seen && continue
            push!(seen, key)
            va = get_vertex(geo, a); vb = get_vertex(geo, b)
            push!(positions, va.x, va.y, va.z, vb.x, vb.y, vb.z)
            push!(indices, vi+1, vi+2); vi += 2
        end
    end
    BufferGeometry(positions, Float64[], Float64[], indices, vi, 0)
end

# Round a position to merge coincident (duplicated) vertices for adjacency.
@inline _pkey(v::Vec3; nd=6) = (round(v.x, digits=nd), round(v.y, digits=nd), round(v.z, digits=nd))

"""Feature edges whose adjacent faces differ in orientation by more than
`threshold_angle`, plus boundary edges (three.js `EdgesGeometry`). Returned as a
line BufferGeometry. Coincident vertices are merged by position first."""
function edges_geometry(geo::BufferGeometry; threshold_angle=0.349)   # ≈20°
    _validate_triangle_geometry_indices(geo, "edges_geometry")
    threshold_angle = _geometry_finite_scalar(threshold_angle, "edges_geometry threshold_angle")
    cosT = cos(threshold_angle)
    # Canonicalize vertices by position.
    canon = Dict{Tuple{Float64,Float64,Float64}, Int}()
    cpos = Vec3{Float64}[]
    cidx(v) = get!(canon, _pkey(v)) do
        push!(cpos, v); length(cpos)
    end
    # edge (lo,hi) -> list of face normals
    edge_faces = Dict{Tuple{Int,Int}, Vector{Vec3{Float64}}}()
    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        n = cross(v2 - v1, v3 - v1); nl = norm(n); nl > 0 && (n = n / nl)
        c1 = cidx(v1); c2 = cidx(v2); c3 = cidx(v3)
        for (a, b) in ((c1,c2), (c2,c3), (c3,c1))
            key = a < b ? (a, b) : (b, a)
            push!(get!(edge_faces, key, Vec3{Float64}[]), n)
        end
    end
    positions = Float64[]; indices = Int[]; vi = 0
    for (key, nlist) in edge_faces
        feature = length(nlist) == 1 || dot(nlist[1], nlist[2]) < cosT
        feature || continue
        a = cpos[key[1]]; b = cpos[key[2]]
        push!(positions, a.x, a.y, a.z, b.x, b.y, b.z)
        push!(indices, vi+1, vi+2); vi += 2
    end
    BufferGeometry(positions, Float64[], Float64[], indices, vi, 0)
end
