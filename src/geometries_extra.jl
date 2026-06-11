# --------------------------------------------------------------------------
# Additional geometry generators mirroring three.js: the platonic-solid family
# via a subdividing PolyhedronGeometry, surfaces of revolution / sweeps
# (Lathe, Tube), profile extrusion (Shape/Extrude), Capsule, and the
# Edges/Wireframe line geometries.
# --------------------------------------------------------------------------

# ========================== PolyhedronGeometry ==========================
# Subdivide each base triangle into (detail+1)² faces and project to a sphere
# of the given radius. Vertices are non-indexed (3 per face).

function PolyhedronGeometry(base_verts::Vector{<:Vec3}, base_faces::Vector{NTuple{3,Int}};
                            radius=1.0, detail::Int=0)
    positions = Float64[]; normals = Float64[]; uvs = Float64[]; indices = Int[]
    vi = 0
    projr(v) = normalize(v) * radius
    function emit!(a::Vec3, b::Vec3, c::Vec3)
        for p in (projr(a), projr(b), projr(c))
            push!(positions, p.x, p.y, p.z)
            n = normalize(p); push!(normals, n.x, n.y, n.z)
            push!(uvs, atan(p.z, p.x)/(2π) + 0.5, asin(clamp(p.y/radius, -1.0, 1.0))/π + 0.5)
        end
        push!(indices, vi+1, vi+2, vi+3); vi += 3
    end
    cols = detail + 1
    for (i1, i2, i3) in base_faces
        A = base_verts[i1]; B = base_verts[i2]; C = base_verts[i3]
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
    v = [Vec3(1.0,0,0), Vec3(-1.0,0,0), Vec3(0.0,1.0,0), Vec3(0.0,-1.0,0),
         Vec3(0.0,0,1.0), Vec3(0.0,0,-1.0)]
    f = NTuple{3,Int}[(1,3,5),(1,5,4),(1,4,6),(1,6,3),(2,3,6),(2,6,4),(2,4,5),(2,5,3)]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

function TetrahedronGeometry(; radius=1.0, detail=0)
    v = [Vec3(1.0,1,1), Vec3(-1.0,-1,1), Vec3(-1.0,1,-1), Vec3(1.0,-1,-1)]
    f = NTuple{3,Int}[(3,2,1),(1,4,3),(2,4,1),(3,4,2)]
    PolyhedronGeometry(v, f; radius=radius, detail=detail)
end

function DodecahedronGeometry(; radius=1.0, detail=0)
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

# ========================== LatheGeometry ==========================
# Revolve a 2D profile (x = radius, y = height) about the y-axis.

function LatheGeometry(points::Vector{<:Vec2}; segments=12, phi_start=0.0, phi_length=2π)
    np = length(points)
    @assert np >= 2 "Lathe needs at least two profile points"
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

function TubeGeometry(path::Vector{<:Vec3}; radius=1.0, radial_segments=8)
    n = length(path)
    @assert n >= 2 "Tube needs at least two path points"
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

# ========================== Shape / Extrude ==========================
# A Shape is a simple polygon in the xy-plane (Vector{Vec2}). ShapeGeometry
# fills it; ExtrudeGeometry sweeps it to depth along +z. Caps are fan-
# triangulated (correct for convex shapes).

"""Filled planar polygon (z = 0), normal +z."""
function ShapeGeometry(shape::Vector{<:Vec2})
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

"""Extrude a planar polygon `shape` to `depth` along +z (front cap, back cap, walls)."""
function ExtrudeGeometry(shape::Vector{<:Vec2}; depth=1.0)
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
