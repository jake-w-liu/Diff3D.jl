# --------------------------------------------------------------------------
# Differentiable soft rasterizer (Liu et al., ICCV 2019 inspired).
#
# Key idea: replace hard z-buffer with soft aggregation.
#   - Soft coverage: sigmoid of signed distance to triangle edge
#   - Soft depth: softmax over face depths
#   - Result: fully differentiable image w.r.t. vertex positions,
#     material parameters, light parameters, and camera parameters.
#
# All operations are pure Julia scalar math — ForwardDiff compatible.
# --------------------------------------------------------------------------

"""Configuration for the soft rasterizer."""
struct SoftRasterizerConfig{T<:Real}
    sigma::T       # Edge softness in pixel units (larger = softer)
    gamma::T       # Depth aggregation temperature in NDC units
    bg_color::Color3{T}
    eps::T
end

function _soft_positive_finite(value, label::String)
    value isa Bool && throw(ArgumentError("$label must be finite and positive"))
    (isfinite(value) && value > zero(value)) ||
        throw(ArgumentError("$label must be finite and positive"))
    return value
end

function _soft_finite_color(color::Color3, label::String)
    (isfinite(color.r) && isfinite(color.g) && isfinite(color.b)) ||
        throw(ArgumentError("$label must be finite"))
    return color
end

function SoftRasterizerConfig(; sigma=1.0, gamma=1.0,
                               bg_color=Color3(0.0, 0.0, 0.0),
                               eps=1e-8)
    T = promote_type(typeof(sigma), typeof(gamma), typeof(bg_color.r), typeof(eps))
    sigma_t = _soft_positive_finite(T(sigma), "SoftRasterizerConfig sigma")
    gamma_t = _soft_positive_finite(T(gamma), "SoftRasterizerConfig gamma")
    eps_t = _soft_positive_finite(T(eps), "SoftRasterizerConfig eps")
    bg_t = _soft_finite_color(
        Color3(T(bg_color.r), T(bg_color.g), T(bg_color.b)),
        "SoftRasterizerConfig bg_color")
    SoftRasterizerConfig{T}(sigma_t, gamma_t, bg_t, eps_t)
end

"""
Differentiable soft rendering.
Takes explicit arrays rather than scene-graph objects for AD compatibility.

Arguments:
- vertices: Vector{Vec3{T}} — world-space vertex positions
- faces: Vector{NTuple{3,Int}} — triangle face indices (1-based)
- face_colors: Vector{Color3{T}} — one color per face
- view_proj: Mat4{T} — combined view-projection matrix
- width, height: image dimensions
- config: SoftRasterizerConfig

Returns: Array{T, 3} of size (height, width, 3) — RGB image.
"""
function soft_render(vertices::Vector{Vec3{Tv}},
                     faces::Vector{NTuple{3,Int}},
                     face_colors::Vector{Color3{Tc}},
                     view_proj::Mat4,
                     width::Int, height::Int,
                     config::SoftRasterizerConfig = SoftRasterizerConfig()
                     ) where {Tv, Tc}

    # Promote to a common element type so the renderer is differentiable with
    # respect to any subset of {vertices, colors, camera}: e.g. Dual vertices
    # with fixed Float64 colors. The common path (all the same type) hits the
    # `=== T` short-circuits and performs no extra work or allocation.
    T = promote_type(Tv, Tc, eltype(view_proj.e), typeof(config.sigma),
                     typeof(config.gamma), typeof(config.bg_color.r), typeof(config.eps))
    verts = Tv === T ? vertices : Vec3{T}[Vec3(T(v.x), T(v.y), T(v.z)) for v in vertices]
    cols  = Tc === T ? face_colors : Color3{T}[Color3(T(c.r), T(c.g), T(c.b)) for c in face_colors]
    vp    = eltype(view_proj.e) === T ? view_proj : Mat4{T}(ntuple(k -> T(view_proj.e[k]), 16))

    σ = T(config.sigma)
    γ = T(config.gamma)
    bg = Color3(T(config.bg_color.r), T(config.bg_color.g), T(config.bg_color.b))
    eps = T(config.eps)

    n_faces = length(faces)
    W, H = width, height
    (W > 0 && H > 0) || throw(ArgumentError("soft_render dimensions must be positive"))
    length(face_colors) == n_faces ||
        throw(ArgumentError("soft_render face_colors length must match faces length"))
    _soft_positive_finite(σ, "SoftRasterizerConfig sigma")
    _soft_positive_finite(γ, "SoftRasterizerConfig gamma")
    _soft_positive_finite(eps, "SoftRasterizerConfig eps")
    _soft_finite_color(bg, "SoftRasterizerConfig bg_color")
    n_vertices = length(verts)
    for face in faces
        i1, i2, i3 = face
        (1 <= i1 <= n_vertices && 1 <= i2 <= n_vertices && 1 <= i3 <= n_vertices) ||
            throw(ArgumentError("soft_render face indices must reference vertices"))
    end

    # Project all vertices to screen space
    screen_verts = Vector{Vec3{T}}(undef, length(verts))
    ndc_verts = Vector{Vec3{T}}(undef, length(verts))
    for (vi, v) in enumerate(verts)
        clip = mat4_transform_vec4(vp, Vec4(v.x, v.y, v.z, one(T)))
        if clip.w > eps
            ndc = Vec3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
            ndc_verts[vi] = ndc
            sx = (ndc.x + 1) * T(0.5) * W
            sy = (1 - ndc.y) * T(0.5) * H
            screen_verts[vi] = Vec3(sx, sy, ndc.z)
        else
            ndc_verts[vi] = Vec3(zero(T), zero(T), T(1000))
            screen_verts[vi] = Vec3(-T(1000), -T(1000), T(1000))
        end
    end

    # Precompute screen-space triangles as NamedTuples
    screen_tris = Vector{NamedTuple{(:s1,:s2,:s3,:color,:min_x,:max_x,:min_y,:max_y,:area,:valid),
                                     Tuple{Vec3{T},Vec3{T},Vec3{T},Color3{T},Int,Int,Int,Int,T,Bool}}}(undef, n_faces)

    for fi in 1:n_faces
        i1, i2, i3 = faces[fi]
        s1 = screen_verts[i1]
        s2 = screen_verts[i2]
        s3 = screen_verts[i3]
        area = edge_function(s1.x, s1.y, s2.x, s2.y, s3.x, s3.y)

        # Extended bounding box for soft edges. The soft-coverage sigmoid
        # sigmoid(d/σ) extends ~3σ pixels OUTSIDE the triangle, so the
        # influence band GROWS with σ. Grow the margin with σ (floor ~1px,
        # cap 50px) so larger σ is not truncated at the bbox edge.
        margin = clamp(3.0 * σ, 1.0, 50.0)
        # Clamp the float extent into [1,W]/[1,H] before the Int conversion (and
        # reject non-finite projected coords) so a near-camera vertex with a huge
        # finite screen coordinate cannot overflow floor/ceil(Int, …) — matching
        # the hard rasterizer. Reachable in inverse rendering when an optimized
        # vertex transiently slides through the camera.
        # isfinite works directly on Float64, ForwardDiff.Dual, and ADVar; do NOT
        # wrap in Float64() — Float64(::ForwardDiff.Dual) is undefined and would
        # crash the differentiable/inverse-rendering gradient path (its core use).
        finite = isfinite(s1.x) && isfinite(s1.y) &&
                 isfinite(s2.x) && isfinite(s2.y) &&
                 isfinite(s3.x) && isfinite(s3.y)
        fW = Float64(W); fH = Float64(H)
        if finite
            bmin_x = max(floor(Int, clamp(min(s1.x, s2.x, s3.x) - margin, 1.0, fW)), 1)
            bmax_x = min(ceil(Int,  clamp(max(s1.x, s2.x, s3.x) + margin, 1.0, fW)), W)
            bmin_y = max(floor(Int, clamp(min(s1.y, s2.y, s3.y) - margin, 1.0, fH)), 1)
            bmax_y = min(ceil(Int,  clamp(max(s1.y, s2.y, s3.y) + margin, 1.0, fH)), H)
        else
            bmin_x = 1; bmax_x = 0; bmin_y = 1; bmax_y = 0   # empty box -> valid=false
        end

        valid = finite && abs(area) > eps && bmax_x >= bmin_x && bmax_y >= bmin_y
        screen_tris[fi] = (s1=s1, s2=s2, s3=s3, color=cols[fi],
                           min_x=bmin_x, max_x=bmax_x, min_y=bmin_y, max_y=bmax_y,
                           area=area, valid=valid)
    end

    # --------------------------------------------------------------------
    # Spatial acceleration: uniform tile grid.
    #
    # The original per-pixel cost is O(pixels x faces) because every pixel
    # scans all faces and rejects those whose margin-expanded bbox does not
    # cover it. We bin each face into every tile its bbox overlaps, then the
    # per-pixel loop only visits the faces registered to that pixel's tile.
    #
    # Numerical equivalence: a face contributes to pixel (px, py) iff
    #   tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y.
    # A pixel in tile (tx, ty) lies inside the tile's pixel span, so any face
    # whose bbox covers that pixel also overlaps the tile and is therefore
    # registered to it. The tile list is thus a SUPERSET of the covering
    # faces; the unchanged inner bbox test rejects the extras. The retained
    # faces, their order (ascending face index per tile), coverage, and depth
    # weights are identical to the all-faces scan, so the floating-point
    # result and the gradients that flow through it are unchanged. Tile bounds
    # are taken from the Float64-precision (or Dual-value) screen bbox already
    # stored in screen_tris, so binning introduces no new differentiable path.
    # --------------------------------------------------------------------
    TILE = 16
    n_tx = cld(W, TILE)
    n_ty = cld(H, TILE)
    n_tiles = n_tx * n_ty
    @inline tile_index(tx, ty) = (ty - 1) * n_tx + tx
    @inline tile_x_of(px) = (px - 1) ÷ TILE + 1
    @inline tile_y_of(py) = (py - 1) ÷ TILE + 1

    # Bucket faces into tiles. Two-pass CSR build keeps allocation O(faces +
    # tile-overlap entries) and gives contiguous, index-ordered per-tile lists.
    tile_counts = zeros(Int, n_tiles)
    for fi in 1:n_faces
        tri = screen_tris[fi]
        tri.valid || continue
        tx0 = tile_x_of(tri.min_x); tx1 = tile_x_of(tri.max_x)
        ty0 = tile_y_of(tri.min_y); ty1 = tile_y_of(tri.max_y)
        for ty in ty0:ty1, tx in tx0:tx1
            tile_counts[tile_index(tx, ty)] += 1
        end
    end
    tile_offsets = Vector{Int}(undef, n_tiles + 1)
    tile_offsets[1] = 1
    for t in 1:n_tiles
        tile_offsets[t + 1] = tile_offsets[t] + tile_counts[t]
    end
    tile_faces = Vector{Int}(undef, tile_offsets[n_tiles + 1] - 1)
    tile_cursor = copy(tile_offsets)
    for fi in 1:n_faces
        tri = screen_tris[fi]
        tri.valid || continue
        tx0 = tile_x_of(tri.min_x); tx1 = tile_x_of(tri.max_x)
        ty0 = tile_y_of(tri.min_y); ty1 = tile_y_of(tri.max_y)
        for ty in ty0:ty1, tx in tx0:tx1
            t = tile_index(tx, ty)
            tile_faces[tile_cursor[t]] = fi
            tile_cursor[t] += 1
        end
    end

    # Render each pixel
    image = Array{T}(undef, H, W, 3)
    for py in 1:H
        ty = tile_y_of(py)
        for px in 1:W
            cx = T(px) - T(0.5)
            cy = T(py) - T(0.5)

            t = tile_index(tile_x_of(px), ty)
            face_lo = tile_offsets[t]
            face_hi = tile_offsets[t + 1] - 1

            # Soft aggregation over faces using a numerically stabilized
            # softmax over face depth. The depth weight is exp(-z_face/γ);
            # without max-subtraction the exponent overflows to Inf/NaN for
            # large +arg or underflows so total_weight < eps for small γ.
            #
            # Pass 1: compute each covered face's coverage and exponent arg
            #   e_f = -z_face/γ, tracking the per-pixel max arg m. The
            #   max-subtraction cancels in the normalized blend, so this is
            #   mathematically equivalent for moderate γ. (γ is in NDC-depth
            #   units.) Only the faces binned to this pixel's tile are visited.
            m = -one(T) / γ          # background exponent (virtual far-plane surface
            any_face = false          # z=+1); folding it into the softmax max keeps the
                                      # background weight stable and <= 1.
            for k in face_lo:face_hi
                fi = tile_faces[k]
                tri = screen_tris[fi]
                !(tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y) && continue
                z_face = (tri.s1.z + tri.s2.z + tri.s3.z) / 3
                e_f = -z_face / γ
                if e_f > m
                    m = e_f
                end
                any_face = true
            end

            # Pass 2: stabilized weights weight_f = coverage_f * exp(e_f - m).
            total_weight = zero(T)
            color_r = zero(T)
            color_g = zero(T)
            color_b = zero(T)
            if any_face
                for k in face_lo:face_hi
                    fi = tile_faces[k]
                    tri = screen_tris[fi]
                    !(tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y) && continue

                    # Signed distance to triangle (minimum distance to any edge)
                    d = signed_distance_to_triangle(cx, cy,
                        tri.s1.x, tri.s1.y, tri.s2.x, tri.s2.y, tri.s3.x, tri.s3.y)

                    # Soft coverage via sigmoid
                    coverage = sigmoid_approx(d / σ)

                    # Stabilized depth-based weighting
                    z_face = (tri.s1.z + tri.s2.z + tri.s3.z) / 3
                    e_f = -z_face / γ
                    depth_weight = exp(e_f - m)

                    w = coverage * depth_weight
                    total_weight += w
                    color_r += w * tri.color.r
                    color_g += w * tri.color.g
                    color_b += w * tri.color.b
                end
            end

            # SoftRas partition-of-unity blend: the foreground face weights and a
            # background weight (a virtual surface at the far plane z=+1, hence
            # exponent -1/γ, stabilized by the same max m) form a softmax over
            # {faces, background}. A covered pixel approaches the nearest face
            # colour as σ,γ -> 0 (recovering the hard rasterizer); an uncovered
            # pixel (total_weight -> 0) reduces exactly to the background. The eps
            # floor keeps the denominator strictly positive without a discrete branch.
            w_bg = exp(-one(T) / γ - m) + eps
            denom = total_weight + w_bg
            image[py, px, 1] = (color_r + w_bg * bg.r) / denom
            image[py, px, 2] = (color_g + w_bg * bg.g) / denom
            image[py, px, 3] = (color_b + w_bg * bg.b) / denom
        end
    end

    return image
end

"""
Sigmoid approximation — smooth and AD-friendly.
"""
@inline function sigmoid_approx(x::T) where T
    one(T) / (one(T) + exp(-x))
end

"""
Signed distance from point (px,py) to triangle defined by (ax,ay), (bx,by), (cx,cy).
Positive inside, negative outside.
"""
function signed_distance_to_triangle(px, py, ax, ay, bx, by, cx, cy)
    # Barycentric test
    area = edge_function(ax, ay, bx, by, cx, cy)
    if abs(area) < 1e-20
        return typeof(px)(-1e10)
    end

    w0 = edge_function(bx, by, cx, cy, px, py) / area
    w1 = edge_function(cx, cy, ax, ay, px, py) / area
    w2 = edge_function(ax, ay, bx, by, px, py) / area

    if w0 >= 0 && w1 >= 0 && w2 >= 0
        # Inside — distance is min distance to any edge
        d1 = point_line_distance(px, py, ax, ay, bx, by)
        d2 = point_line_distance(px, py, bx, by, cx, cy)
        d3 = point_line_distance(px, py, cx, cy, ax, ay)
        return min(d1, d2, d3)
    else
        # Outside — negative of min distance to edges/vertices
        d1 = point_segment_distance(px, py, ax, ay, bx, by)
        d2 = point_segment_distance(px, py, bx, by, cx, cy)
        d3 = point_segment_distance(px, py, cx, cy, ax, ay)
        return -min(d1, d2, d3)
    end
end

"""
Distance from point to infinite line through (ax,ay)-(bx,by).
"""
@inline function point_line_distance(px, py, ax, ay, bx, by)
    dx = bx - ax
    dy = by - ay
    len = sqrt(dx^2 + dy^2)
    abs((px - ax) * dy - (py - ay) * dx) / max(len, 1e-20)
end

"""
Distance from point to line segment (ax,ay)-(bx,by).
AD-friendly: uses smooth min/max via clamping.
"""
function point_segment_distance(px, py, ax, ay, bx, by)
    dx = bx - ax
    dy = by - ay
    len_sq = dx^2 + dy^2
    # Smoothing epsilon under the square roots: sqrt has an infinite derivative
    # at 0, so a sample point landing exactly on the segment (distance 0) would
    # make ForwardDiff return Inf*0 = NaN and poison the whole gradient. The added
    # 1e-12 (≈1e-6 px) makes the distance smooth everywhere with a finite (zero)
    # derivative at 0; the bias is negligible relative to the sigmoid softness sigma.
    if len_sq < 1e-20
        return sqrt((px - ax)^2 + (py - ay)^2 + 1e-12)
    end
    t = clamp(((px - ax)*dx + (py - ay)*dy) / len_sq, zero(px), one(px))
    proj_x = ax + t * dx
    proj_y = ay + t * dy
    sqrt((px - proj_x)^2 + (py - proj_y)^2 + 1e-12)
end

# ========================== High-level differentiable render ==========================

"""
Differentiable render of a scene — extracts geometry data and calls soft_render.
Suitable for wrapping in ForwardDiff.
"""
function soft_render_scene(scene::Scene, camera::AbstractCamera,
                           width::Int, height::Int;
                           sigma=1.0, gamma=1.0)
    config = SoftRasterizerConfig(sigma=sigma, gamma=gamma, bg_color=scene.background)

    proj = projection_matrix(camera)
    view = view_matrix(camera)
    vp = proj * view

    meshes = collect_meshes(scene)
    lights = collect_lights(scene)

    all_verts = Vec3{Float64}[]
    all_faces = NTuple{3,Int}[]
    all_colors = Color3{Float64}[]
    vert_offset = 0

    for mesh in meshes
        !is_visible(mesh) && continue
        world_mat = compute_world_matrix(mesh)
        geo = mesh.geometry

        # Transform vertices to world space
        for vi in 1:geo.n_vertices
            v = get_vertex(geo, vi)
            wv = mat4_transform_point(world_mat, v)
            push!(all_verts, wv)
        end

        # Compute face colors
        face_colors = shade_mesh_faces(geo, world_mat, mesh.material, lights, camera.position)

        for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            push!(all_faces, (i1 + vert_offset, i2 + vert_offset, i3 + vert_offset))
            push!(all_colors, face_colors[fi])
        end
        vert_offset += geo.n_vertices
    end

    soft_render(all_verts, all_faces, all_colors, vp, width, height, config)
end

"""
Differentiable render with explicit parameters for AD.
`params` is a flat vector of parameters being optimized.
`param_injector!` is a function that injects params into the scene/camera before rendering.
"""
function differentiable_render(params::AbstractVector{T},
                               setup_fn::Function,
                               width::Int, height::Int;
                               sigma=1.0, gamma=1.0) where T
    # setup_fn returns (vertices, faces, face_colors, view_proj, bg_color)
    vertices, faces, face_colors, vp, bg = setup_fn(params)
    config = SoftRasterizerConfig(sigma=sigma, gamma=gamma, bg_color=bg)
    soft_render(vertices, faces, face_colors, vp, width, height, config)
end
