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

struct _SoftScreenTriangle{T}
    s1::Vec3{T}
    s2::Vec3{T}
    s3::Vec3{T}
    color::Color3{T}
    min_x::Int
    max_x::Int
    min_y::Int
    max_y::Int
    area::T
    valid::Bool
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
    n_faces == 0 && return _soft_background_image(T, H, W, bg)
    n_vertices = length(verts)
    for face in faces
        i1, i2, i3 = face
        (1 <= i1 <= n_vertices && 1 <= i2 <= n_vertices && 1 <= i3 <= n_vertices) ||
            throw(ArgumentError("soft_render face indices must reference vertices"))
    end

    # Precompute screen-space triangles. Allocate for the common no-near-clip
    # case (one emitted triangle per face) and grow only for split triangles.
    screen_tris = Vector{_SoftScreenTriangle{T}}(undef, n_faces)
    n_screen_tris = 0
    max_screen_tris = 2n_faces

    for fi in 1:n_faces
        i1, i2, i3 = faces[fi]
        v1 = verts[i1]; v2 = verts[i2]; v3 = verts[i3]
        c1 = mat4_transform_vec4(vp, Vec4(v1.x, v1.y, v1.z, one(T)))
        c2 = mat4_transform_vec4(vp, Vec4(v2.x, v2.y, v2.z, one(T)))
        c3 = mat4_transform_vec4(vp, Vec4(v3.x, v3.y, v3.z, one(T)))
        n_clipped, c1, c2, c3, c4 = _soft_clip_near_triangle(c1, c2, c3, eps)
        n_clipped < 3 && continue
        s1 = _soft_project_clip_to_screen(c1, T(W), T(H))
        s2 = _soft_project_clip_to_screen(c2, T(W), T(H))
        s3 = _soft_project_clip_to_screen(c3, T(W), T(H))
        n_screen_tris = _soft_store_screen_triangle!(
            screen_tris, n_screen_tris, max_screen_tris,
            s1, s2, s3, cols[fi], σ, eps, W, H)
        if n_clipped == 4
            s4 = _soft_project_clip_to_screen(c4, T(W), T(H))
            n_screen_tris = _soft_store_screen_triangle!(
                screen_tris, n_screen_tris, max_screen_tris,
                s1, s3, s4, cols[fi], σ, eps, W, H)
        end
    end
    n_screen_tris == 0 && return _soft_background_image(T, H, W, bg)

    if n_screen_tris <= 8
        # Tiny face sets need no spatial index: scanning directly avoids the CSR
        # tile buffers that dominate small inverse-rendering problems.
        image = Array{T}(undef, H, W, 3)
        for py in 1:H
            for px in 1:W
                cx = T(px) - T(0.5)
                cy = T(py) - T(0.5)

                m = -one(T) / γ
                any_face = false
                for fi in 1:n_screen_tris
                    tri = screen_tris[fi]
                    tri.valid || continue
                    !(tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y) && continue
                    z_face = (tri.s1.z + tri.s2.z + tri.s3.z) / 3
                    e_f = -z_face / γ
                    if e_f > m
                        m = e_f
                    end
                    any_face = true
                end

                total_weight = zero(T)
                color_r = zero(T)
                color_g = zero(T)
                color_b = zero(T)
                if any_face
                    for fi in 1:n_screen_tris
                        tri = screen_tris[fi]
                        tri.valid || continue
                        !(tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y) && continue

                        d = _signed_distance_to_triangle_area(cx, cy,
                            tri.s1.x, tri.s1.y, tri.s2.x, tri.s2.y, tri.s3.x, tri.s3.y,
                            tri.area)
                        coverage = sigmoid_approx(d / σ)
                        z_face = (tri.s1.z + tri.s2.z + tri.s3.z) / 3
                        depth_weight = exp(-z_face / γ - m)

                        w = coverage * depth_weight
                        total_weight += w
                        color_r += w * tri.color.r
                        color_g += w * tri.color.g
                        color_b += w * tri.color.b
                    end
                end

                w_bg = exp(-one(T) / γ - m) + eps
                denom = total_weight + w_bg
                image[py, px, 1] = (color_r + w_bg * bg.r) / denom
                image[py, px, 2] = (color_g + w_bg * bg.g) / denom
                image[py, px, 3] = (color_b + w_bg * bg.b) / denom
            end
        end
        return image
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
    for fi in 1:n_screen_tris
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
    for fi in 1:n_screen_tris
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
                    d = _signed_distance_to_triangle_area(cx, cy,
                        tri.s1.x, tri.s1.y, tri.s2.x, tri.s2.y, tri.s3.x, tri.s3.y,
                        tri.area)

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

function _soft_background_image(::Type{T}, H::Int, W::Int, bg::Color3{T}) where {T}
    image = Array{T}(undef, H, W, 3)
    @inbounds for j in 1:W, i in 1:H
        image[i, j, 1] = bg.r
        image[i, j, 2] = bg.g
        image[i, j, 3] = bg.b
    end
    return image
end

@inline _soft_near_value(v::Vec4, eps) = v.z + v.w - eps

@inline function _soft_lerp_clip(a::Vec4, b::Vec4, t)
    Vec4(a.x + t * (b.x - a.x),
         a.y + t * (b.y - a.y),
         a.z + t * (b.z - a.z),
         a.w + t * (b.w - a.w))
end

function _soft_clip_near!(out::Vector{Vec4{T}}, poly::Vector{Vec4{T}},
                          n::Int, eps) where {T}
    out_n = 0
    prev = poly[n]
    prev_d = _soft_near_value(prev, eps)
    prev_in = prev_d >= zero(prev_d)
    @inbounds for i in 1:n
        curr = poly[i]
        curr_d = _soft_near_value(curr, eps)
        curr_in = curr_d >= zero(curr_d)
        if curr_in != prev_in
            t = prev_d / (prev_d - curr_d)
            out_n += 1
            out[out_n] = _soft_lerp_clip(prev, curr, t)
        end
        if curr_in
            out_n += 1
            out[out_n] = curr
        end
        prev = curr
        prev_d = curr_d
        prev_in = curr_in
    end
    return out_n
end

@inline function _soft_clip_push(n::Int, v::Vec4{T},
                                c1::Vec4{T}, c2::Vec4{T},
                                c3::Vec4{T}, c4::Vec4{T}) where {T}
    n += 1
    if n == 1
        c1 = v
    elseif n == 2
        c2 = v
    elseif n == 3
        c3 = v
    else
        c4 = v
    end
    return n, c1, c2, c3, c4
end

function _soft_clip_near_triangle(a::Vec4{T}, b::Vec4{T}, c::Vec4{T}, eps) where {T}
    out_n = 0
    c1 = a
    c2 = a
    c3 = a
    c4 = a
    prev = c
    prev_d = _soft_near_value(prev, eps)
    prev_in = prev_d >= zero(prev_d)
    @inbounds for curr in (a, b, c)
        curr_d = _soft_near_value(curr, eps)
        curr_in = curr_d >= zero(curr_d)
        if curr_in != prev_in
            t = prev_d / (prev_d - curr_d)
            out_n, c1, c2, c3, c4 =
                _soft_clip_push(out_n, _soft_lerp_clip(prev, curr, t), c1, c2, c3, c4)
        end
        if curr_in
            out_n, c1, c2, c3, c4 = _soft_clip_push(out_n, curr, c1, c2, c3, c4)
        end
        prev = curr
        prev_d = curr_d
        prev_in = curr_in
    end
    return out_n, c1, c2, c3, c4
end

@inline function _soft_project_clip_to_screen(clip::Vec4{T}, W::T, H::T) where {T}
    invw = one(T) / clip.w
    ndcx = clip.x * invw
    ndcy = clip.y * invw
    ndcz = clip.z * invw
    Vec3((ndcx + one(T)) * T(0.5) * W,
         (one(T) - ndcy) * T(0.5) * H,
         ndcz)
end

function _soft_screen_triangle(s1::Vec3{T}, s2::Vec3{T}, s3::Vec3{T},
                               color::Color3{T}, σ, eps, W::Int, H::Int) where {T}
    area = edge_function(s1.x, s1.y, s2.x, s2.y, s3.x, s3.y)

    # The sigmoid tail extends with sigma. Do not impose a fixed pixel cap here:
    # very soft silhouettes are expected to influence distant pixels.
    margin = max(T(3.0) * σ, one(T))
    finite = isfinite(s1.x) && isfinite(s1.y) &&
             isfinite(s2.x) && isfinite(s2.y) &&
             isfinite(s3.x) && isfinite(s3.y)
    fW = Float64(W)
    fH = Float64(H)
    if finite
        bmin_x = max(floor(Int, clamp(min(s1.x, s2.x, s3.x) - margin, 1.0, fW)), 1)
        bmax_x = min(ceil(Int,  clamp(max(s1.x, s2.x, s3.x) + margin, 1.0, fW)), W)
        bmin_y = max(floor(Int, clamp(min(s1.y, s2.y, s3.y) - margin, 1.0, fH)), 1)
        bmax_y = min(ceil(Int,  clamp(max(s1.y, s2.y, s3.y) + margin, 1.0, fH)), H)
    else
        bmin_x = 1
        bmax_x = 0
        bmin_y = 1
        bmax_y = 0
    end
    valid = finite && abs(area) > eps && bmax_x >= bmin_x && bmax_y >= bmin_y
    return _SoftScreenTriangle(s1, s2, s3, color,
                               bmin_x, bmax_x, bmin_y, bmax_y,
                               area, valid)
end

@inline function _soft_store_screen_triangle!(
        screen_tris::Vector{_SoftScreenTriangle{T}}, n::Int, max_n::Int,
        s1::Vec3{T}, s2::Vec3{T}, s3::Vec3{T}, color::Color3{T},
        σ, eps, W::Int, H::Int) where {T}
    if n == length(screen_tris)
        resize!(screen_tris, min(max_n, max(n + 1, 2n)))
    end
    n += 1
    @inbounds screen_tris[n] = _soft_screen_triangle(s1, s2, s3, color, σ, eps, W, H)
    return n
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
function _signed_distance_to_triangle_area(px, py, ax, ay, bx, by, cx, cy, area)
    # Barycentric test
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

function signed_distance_to_triangle(px, py, ax, ay, bx, by, cx, cy)
    area = edge_function(ax, ay, bx, by, cx, cy)
    return _signed_distance_to_triangle_area(px, py, ax, ay, bx, by, cx, cy, area)
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

    total_vertices = 0
    total_faces = 0
    max_mesh_faces = 0
    for mesh in meshes
        geo = _mesh_geometry(mesh)
        total_vertices += geo.n_vertices
        total_faces += geo.n_faces
        max_mesh_faces = max(max_mesh_faces, geo.n_faces)
    end

    all_verts = Vector{Vec3{Float64}}(undef, total_vertices)
    all_faces = Vector{NTuple{3,Int}}(undef, total_faces)
    all_colors = Vector{Color3{Float64}}(undef, total_faces)
    face_colors = Vector{Color3{Float64}}(undef, max_mesh_faces)
    vert_offset = 0
    face_offset = 0

    for mesh in meshes
        world_mat = compute_world_matrix(mesh)
        geo = _mesh_geometry(mesh)

        # Transform vertices to world space
        for vi in 1:geo.n_vertices
            v = get_vertex(geo, vi)
            wv = mat4_transform_point(world_mat, v)
            all_verts[vert_offset + vi] = wv
        end

        # Compute face colors
        shade_mesh_faces!(face_colors, geo, world_mat, _mesh_material(mesh),
                          lights, camera.position)

        for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            out_fi = face_offset + fi
            all_faces[out_fi] = (i1 + vert_offset, i2 + vert_offset, i3 + vert_offset)
            all_colors[out_fi] = face_colors[fi]
        end
        vert_offset += geo.n_vertices
        face_offset += geo.n_faces
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
