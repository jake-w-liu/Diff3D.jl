# --------------------------------------------------------------------------
# High-dimensional differentiable rendering: gradients of the soft rasterizer
# with respect to vertex positions and per-face colors ("differentiable
# textures"), plus optimization helpers. The render functions preserve scalar
# types for ForwardDiff and the package's ADVar reverse engine. The optimization
# convenience functions use inverse_render_adam's default gradient method.
# --------------------------------------------------------------------------

# Promote a Mat4 to element type T so AD duals flow through projection.
@inline _promote_mat4(vp::Mat4{T}, ::Type{T}) where {T} = vp
@inline _promote_mat4(vp::Mat4{S}, ::Type{T}) where {S,T} =
    convert(Mat4{T}, vp)

struct _FlatVec3Params{T,P<:AbstractVector{T}} <: AbstractVector{Vec3{T}}
    p::P
    n::Int
end

Base.IndexStyle(::Type{<:_FlatVec3Params}) = IndexLinear()
Base.size(v::_FlatVec3Params) = (v.n,)
@inline function Base.getindex(v::_FlatVec3Params{T}, i::Int) where {T}
    @boundscheck 1 <= i <= v.n || throw(BoundsError(v, i))
    @inbounds return Vec3{T}(v.p[3i - 2], v.p[3i - 1], v.p[3i])
end

struct _FlatColorParams{T,P<:AbstractVector{T}} <: AbstractVector{Color3{T}}
    p::P
    n::Int
end

Base.IndexStyle(::Type{<:_FlatColorParams}) = IndexLinear()
Base.size(v::_FlatColorParams) = (v.n,)
@inline function Base.getindex(v::_FlatColorParams{T}, i::Int) where {T}
    @boundscheck 1 <= i <= v.n || throw(BoundsError(v, i))
    @inbounds return Color3{T}(v.p[3i - 2], v.p[3i - 1], v.p[3i])
end

struct _PromotedVec3Vector{T,V<:AbstractVector} <: AbstractVector{Vec3{T}}
    data::V
end

Base.IndexStyle(::Type{<:_PromotedVec3Vector}) = IndexLinear()
Base.size(v::_PromotedVec3Vector) = size(v.data)
@inline function Base.getindex(v::_PromotedVec3Vector{T}, i::Int) where {T}
    x = v.data[i]
    return Vec3{T}(T(x.x), T(x.y), T(x.z))
end

struct _PromotedColorVector{T,V<:AbstractVector} <: AbstractVector{Color3{T}}
    data::V
end

Base.IndexStyle(::Type{<:_PromotedColorVector}) = IndexLinear()
Base.size(v::_PromotedColorVector) = size(v.data)
@inline function Base.getindex(v::_PromotedColorVector{T}, i::Int) where {T}
    x = v.data[i]
    return Color3{T}(T(x.r), T(x.g), T(x.b))
end

@inline _promote_vec3_source(vertices::AbstractVector{Vec3{T}}, ::Type{T}) where {T} =
    vertices
@inline _promote_vec3_source(vertices::AbstractVector, ::Type{T}) where {T} =
    _PromotedVec3Vector{T,typeof(vertices)}(vertices)

@inline _promote_color_source(colors::AbstractVector{Color3{T}}, ::Type{T}) where {T} =
    colors
@inline _promote_color_source(colors::AbstractVector, ::Type{T}) where {T} =
    _PromotedColorVector{T,typeof(colors)}(colors)

function _render_workspace_for_type(workspace, cache::Base.RefValue{Any},
                                    ::Type{T}) where {T}
    workspace === nothing && return nothing
    if workspace === :auto
        cached = cache[]
        cached isa SoftRenderWorkspace{T} && return cached
        cached = SoftRenderWorkspace{T}()
        cache[] = cached
        return cached
    end
    return workspace
end

function _max_face_vertex_index(faces)
    max_index = 0
    for face in faces
        i1, i2, i3 = face
        (i1 >= 1 && i2 >= 1 && i3 >= 1) ||
            throw(ArgumentError("faces must use positive 1-based vertex indices"))
        max_index = max(max_index, i1, i2, i3)
    end
    return max_index
end

"""
    vertex_render_fn(faces, face_colors, vp, W, H; sigma, gamma)

Return a closure `p -> image` where `p` is a flat vector of vertex positions
`[x1,y1,z1, x2,...]`. Differentiable w.r.t. `p` (vertex-position gradients).
Pass `workspace=SoftRenderWorkspace{T}()` or `workspace=:auto` only when the
returned image may be overwritten by the next closure call.
"""
function vertex_render_fn(faces, face_colors, vp::Mat4, W::Int, H::Int;
                          sigma=1.0, gamma=1.0, bg=Color3(0.0,0.0,0.0),
                          workspace=nothing)
    expected_vertices = _max_face_vertex_index(faces)
    length(face_colors) == length(faces) ||
        throw(ArgumentError("vertex_render_fn face_colors length must match faces length"))
    expected_params = 3 * expected_vertices
    workspace_cache = Ref{Any}(nothing)
    return function (p)
        length(p) == expected_params ||
            throw(ArgumentError("vertex_render_fn parameter length must be 3 * maximum face index ($expected_params); got $(length(p))"))
        T = eltype(p)
        verts = _FlatVec3Params{T,typeof(p)}(p, expected_vertices)
        cols = _promote_color_source(face_colors, T)
        cfg = SoftRasterizerConfig(sigma=sigma, gamma=gamma, bg_color=bg)
        soft_render(verts, faces, cols, _promote_mat4(vp, T), W, H, cfg;
                    workspace=_render_workspace_for_type(workspace, workspace_cache, T))
    end
end

"""
    color_render_fn(vertices, faces, vp, W, H; sigma, gamma)

Return a closure `p -> image` where `p` is a flat vector of per-face RGB colors
`[r1,g1,b1, r2,...]`. Differentiable w.r.t. `p` (a differentiable texture/colour
field over the surface).
Pass `workspace=SoftRenderWorkspace{T}()` or `workspace=:auto` only when the
returned image may be overwritten by the next closure call.
"""
function color_render_fn(vertices, faces, vp::Mat4, W::Int, H::Int;
                         sigma=1.0, gamma=1.0, bg=Color3(0.0,0.0,0.0),
                         workspace=nothing)
    _max_face_vertex_index(faces) <= length(vertices) ||
        throw(ArgumentError("color_render_fn faces must reference vertices"))
    expected_params = 3 * length(faces)
    workspace_cache = Ref{Any}(nothing)
    return function (p)
        length(p) == expected_params ||
            throw(ArgumentError("color_render_fn parameter length must be 3 * number of faces ($expected_params); got $(length(p))"))
        T = eltype(p)
        cols = _FlatColorParams{T,typeof(p)}(p, length(faces))
        verts = _promote_vec3_source(vertices, T)
        cfg = SoftRasterizerConfig(sigma=sigma, gamma=gamma, bg_color=bg)
        soft_render(verts, faces, cols, _promote_mat4(vp, T), W, H, cfg;
                    workspace=_render_workspace_for_type(workspace, workspace_cache, T))
    end
end

"""
    optimize_vertices(initial, faces, face_colors, vp, target; ...)

Adam optimization of a flat vertex-position vector to match `target`. Returns
`(optimized_params, loss_history)`.
Uses an internal workspace by default because intermediate renders are consumed
immediately by the loss function.
"""
function optimize_vertices(initial::Vector{Float64}, faces, face_colors, vp::Mat4,
                           target::Array{Float64,3}; W::Int, H::Int,
                           sigma=1.0, gamma=1.0, lr=0.05, n_iters=50,
                           verbose=false, workspace=:auto)
    rf = vertex_render_fn(faces, face_colors, vp, W, H; sigma=sigma, gamma=gamma,
                          workspace=workspace)
    inverse_render_adam(initial, target, rf, loss_mse; lr=lr, n_iters=n_iters, verbose=verbose)
end

"""
    optimize_face_colors(initial, vertices, faces, vp, target; ...)

Adam optimization of a flat per-face colour vector to match `target` — a
differentiable-texture demo. Returns `(optimized_params, loss_history)`.
Uses an internal workspace by default because intermediate renders are consumed
immediately by the loss function.
"""
function optimize_face_colors(initial::Vector{Float64}, vertices, faces, vp::Mat4,
                              target::Array{Float64,3}; W::Int, H::Int,
                              sigma=1.0, gamma=1.0, lr=0.05, n_iters=50,
                              verbose=false, workspace=:auto)
    rf = color_render_fn(vertices, faces, vp, W, H; sigma=sigma, gamma=gamma,
                         workspace=workspace)
    inverse_render_adam(initial, target, rf, loss_mse; lr=lr, n_iters=n_iters, verbose=verbose)
end

# ==========================================================================
# Fused reverse-mode rule for the soft rasterizer's pixel stage.
#
# Recording every per-pixel, per-face scalar operation on the ADVar tape costs
# on the order of a hundred tape nodes per face-pixel pair. Instead, the
# screen-space triangles (projection, clipping, depth logits) stay on the tape,
# the pixel stage is evaluated once in Float64, and each image channel becomes
# a leaf node. A fused pullback then propagates the image adjoint to the
# triangle coordinates, colours, depth logits, sigma, gamma, eps and background.
#
# The pullback differentiates the formulas the generic ADVar path records
# (`_soft_pixel_color` with the generic `point_line_distance` and
# `point_segment_distance` methods), including its branch choices: the first
# argument wins ties of `min`, clamped segment parameters are constant, the
# `max(len, 1e-20)` floor is constant below the floor, and relative depth
# weights that are exactly one (ties) or underflowed are constant. Image values
# are those of the Float64 renderer.
# ==========================================================================

@inline _soft_ad_add!(target::ADVar, value::Float64) =
    (iszero(value) || (target.adj += value); nothing)
@inline _soft_ad_add!(::Real, ::Float64) = nothing

@inline _soft_primal_triangle(t::_SoftScreenTriangle{ADVar}) =
    _SoftScreenTriangle{Float64}(
        Vec3(t.s1.x.val, t.s1.y.val, t.s1.z.val),
        Vec3(t.s2.x.val, t.s2.y.val, t.s2.z.val),
        Vec3(t.s3.x.val, t.s3.y.val, t.s3.z.val),
        Color3(t.color.r.val, t.color.g.val, t.color.b.val),
        t.depth.val, t.logit.val,
        t.min_x, t.max_x, t.min_y, t.max_y, t.area.val, t.valid)

# Generic `point_line_distance` value and its gradient w.r.t. (ax, ay, bx, by).
@inline function _soft_line_distance_gradient(px::Float64, py::Float64,
                                              ax::Float64, ay::Float64,
                                              bx::Float64, by::Float64,
                                              interior_negative::Bool)
    dx = bx - ax
    dy = by - ay
    len = hypot(dx, dy)
    qx = px - ax
    qy = py - ay
    numerator = qx * dy - qy * dx
    floor_len = max(len, 1e-20)
    d = abs(numerator) / floor_len
    # A point exactly on the line counts as inside the triangle, so it takes
    # the derivative of the interior side (`_soft_inside_line_distance`).
    negative = numerator < 0 || (numerator == 0 && interior_negative)
    numerator_bar = (negative ? -1.0 : 1.0) / floor_len
    len_bar = len >= 1e-20 ? -d / floor_len : 0.0
    hx, hy = _scaled_hypot_partials(dx, dy)
    dx_bar = -numerator_bar * qy + len_bar * hx
    dy_bar = numerator_bar * qx + len_bar * hy
    qx_bar = numerator_bar * dy
    qy_bar = -numerator_bar * dx
    return d, -qx_bar - dx_bar, -qy_bar - dy_bar, dx_bar, dy_bar
end

# Generic `point_segment_distance` value and its gradient w.r.t. (ax, ay, bx, by).
@inline function _soft_segment_distance_gradient(px::Float64, py::Float64,
                                                 ax::Float64, ay::Float64,
                                                 bx::Float64, by::Float64)
    dx = bx - ax
    dy = by - ay
    len_sq = dx^2 + dy^2
    if len_sq < 1e-20
        rx = px - ax
        ry = py - ay
        dist = sqrt(rx^2 + ry^2 + 1e-12)
        return dist, -rx / dist, -ry / dist, 0.0, 0.0
    end
    qx = px - ax
    qy = py - ay
    t_raw = (qx * dx + qy * dy) / len_sq
    clamped = t_raw > 1.0 || t_raw < 0.0
    t = clamp(t_raw, 0.0, 1.0)
    rx = px - (ax + t * dx)
    ry = py - (ay + t * dy)
    dist = sqrt(rx^2 + ry^2 + 1e-12)
    proj_x_bar = -rx / dist
    proj_y_bar = -ry / dist
    ax_bar = proj_x_bar
    ay_bar = proj_y_bar
    dx_bar = proj_x_bar * t
    dy_bar = proj_y_bar * t
    if !clamped
        t_bar = proj_x_bar * dx + proj_y_bar * dy
        numerator_bar = t_bar / len_sq
        len_sq_bar = -t_bar * t_raw / len_sq
        ax_bar -= numerator_bar * dx
        ay_bar -= numerator_bar * dy
        dx_bar += numerator_bar * qx + len_sq_bar * 2dx
        dy_bar += numerator_bar * qy + len_sq_bar * 2dy
    end
    return dist, ax_bar - dx_bar, ay_bar - dy_bar, dx_bar, dy_bar
end

# Index chosen by the generic three-argument `min` (ties keep the earlier
# argument; NaN propagates from the earlier argument).
@inline function _soft_min3_index(d1::Float64, d2::Float64, d3::Float64)
    first = d1 <= d2 || isnan(d1)
    m12 = first ? d1 : d2
    (m12 <= d3 || isnan(m12)) && return first ? 1 : 2
    return 3
end

# Value of the generic `_signed_distance_to_triangle_area` and its gradient
# w.r.t. (ax, ay, bx, by, cx, cy).
@inline function _soft_signed_distance_gradient(px::Float64, py::Float64,
                                                ax::Float64, ay::Float64,
                                                bx::Float64, by::Float64,
                                                cx::Float64, cy::Float64,
                                                area::Float64)
    abs(area) < 1e-20 && return -1e10, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
    w0 = edge_function(bx, by, cx, cy, px, py) / area
    w1 = edge_function(cx, cy, ax, ay, px, py) / area
    w2 = edge_function(ax, ay, bx, by, px, py) / area
    inside = w0 >= 0 && w1 >= 0 && w2 >= 0
    if inside
        interior_negative = area < 0
        d1, a1x, a1y, b1x, b1y = _soft_line_distance_gradient(px, py, ax, ay, bx, by, interior_negative)
        d2, a2x, a2y, b2x, b2y = _soft_line_distance_gradient(px, py, bx, by, cx, cy, interior_negative)
        d3, a3x, a3y, b3x, b3y = _soft_line_distance_gradient(px, py, cx, cy, ax, ay, interior_negative)
    else
        d1, a1x, a1y, b1x, b1y = _soft_segment_distance_gradient(px, py, ax, ay, bx, by)
        d2, a2x, a2y, b2x, b2y = _soft_segment_distance_gradient(px, py, bx, by, cx, cy)
        d3, a3x, a3y, b3x, b3y = _soft_segment_distance_gradient(px, py, cx, cy, ax, ay)
    end
    sign = inside ? 1.0 : -1.0
    value = sign * min(d1, d2, d3)
    selected = _soft_min3_index(d1, d2, d3)
    if selected == 1      # edge a -> b
        return value, sign * a1x, sign * a1y, sign * b1x, sign * b1y, 0.0, 0.0
    elseif selected == 2  # edge b -> c
        return value, 0.0, 0.0, sign * a2x, sign * a2y, sign * b2x, sign * b2y
    end
    return value, sign * b3x, sign * b3y, 0.0, 0.0, sign * a3x, sign * a3y  # c -> a
end

# Adjoint of the degeneracy fade s(t) = t^2 (3 - 2t), t = |A| / ε, where
# A = edge_function(s1, s2, s3) = (x3 - x1)(y2 - y1) - (y3 - y1)(x2 - x1).
@inline function _soft_ad_fade_pullback!(acc, scalars, fi::Int,
                                         tri::_SoftScreenTriangle{Float64},
                                         ε::Float64, fade_bar::Float64)
    area = tri.area
    t = abs(area) / ε
    t_bar = fade_bar * (6.0 * t * (1.0 - t))
    iszero(t_bar) && return nothing
    area_bar = (area < 0 ? -t_bar : t_bar) / ε
    scalars.eps -= t_bar * (t / ε)
    x1 = tri.s1.x; y1 = tri.s1.y
    x2 = tri.s2.x; y2 = tri.s2.y
    x3 = tri.s3.x; y3 = tri.s3.y
    @inbounds begin
        acc[1, fi] += area_bar * (y3 - y2)
        acc[2, fi] += area_bar * (x2 - x3)
        acc[3, fi] -= area_bar * (y3 - y1)
        acc[4, fi] += area_bar * (x3 - x1)
        acc[5, fi] += area_bar * (y2 - y1)
        acc[6, fi] -= area_bar * (x2 - x1)
    end
    return nothing
end

# Relative depth weight (see `_soft_relative_depth_weight`), its scaled delta,
# and whether it depends on its inputs; constant results carry no derivative.
@inline function _soft_relative_weight_state(nearest::Float64, depth::Float64,
                                             gamma::Float64)
    delta = depth - nearest
    iszero(delta) && return 1.0, 0.0, false
    scaled = delta / gamma
    isfinite(scaled) || return 0.0, scaled, false
    weight = exp(-scaled)
    iszero(weight) && return 0.0, scaled, false
    return weight, scaled, true
end

@inline function _soft_sigmoid_derivative(x::Float64)
    tail = exp(-abs(x))
    one_plus = 1.0 + tail
    return tail / (one_plus * one_plus)
end

mutable struct _SoftADScalarAdjoints
    sigma::Float64
    gamma::Float64
    eps::Float64
    background_logit::Float64
    bg_r::Float64
    bg_g::Float64
    bg_b::Float64
end

struct _SoftADPixelPullback{S,G,L}
    primal::Vector{_SoftScreenTriangle{Float64}}
    triangles::Vector{_SoftScreenTriangle{ADVar}}
    tiles::L                       # `nothing` or `_soft_build_tiles` output
    width::Int
    height::Int
    sigma::S
    gamma::G
    eps::ADVar
    bg::Color3{ADVar}
    background_logit::ADVar
    use_relative_depth::Bool
    first_output::Int
end

function _soft_max_candidates(tiles, n_screen_tris::Int)
    tiles === nothing && return n_screen_tris
    offsets = tiles[1]
    longest = 0
    @inbounds for t in 1:(length(offsets) - 1)
        longest = max(longest, offsets[t + 1] - offsets[t])
    end
    return longest
end

function (pullback::_SoftADPixelPullback)(tape::Vector{ADVar})
    primal = pullback.primal
    n = length(primal)
    tiles = pullback.tiles
    use_relative = pullback.use_relative_depth
    σ = Float64(_primal_value(pullback.sigma))
    γ = Float64(_primal_value(pullback.gamma))
    inv_γ = 1.0 / γ
    ε = pullback.eps.val
    bg = Color3(pullback.bg.r.val, pullback.bg.g.val, pullback.bg.b.val)
    background_logit = pullback.background_logit.val
    # Per triangle: d/d(s1x, s1y, s2x, s2y, s3x, s3y, r, g, b, logit or depth).
    acc = zeros(Float64, 10, n)
    scalars = _SoftADScalarAdjoints(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    capacity = _soft_max_candidates(tiles, n)
    faces = Vector{Int}(undef, capacity)
    xs = Vector{Float64}(undef, capacity)
    coverages = Vector{Float64}(undef, capacity)
    faded = Vector{Bool}(undef, capacity)
    depth_weights = Vector{Float64}(undef, capacity)
    weights = Vector{Float64}(undef, capacity)
    distance_grads = Matrix{Float64}(undef, 6, capacity)
    gamma_is_ad = pullback.gamma isa ADVar
    position = pullback.first_output
    @inbounds for py in 1:pullback.height, px in 1:pullback.width
        g_r = tape[position].adj
        g_g = tape[position + 1].adj
        g_b = tape[position + 2].adj
        position += 3
        (iszero(g_r) && iszero(g_g) && iszero(g_b)) && continue
        _soft_ad_pixel_pullback!(acc, scalars, faces, xs, coverages, faded,
            depth_weights, weights, distance_grads, primal, tiles, n,
            px, py, g_r, g_g, g_b, σ, γ, inv_γ, ε, bg, background_logit,
            use_relative, gamma_is_ad)
    end
    triangles = pullback.triangles
    @inbounds for fi in 1:n
        t = triangles[fi]
        _soft_ad_add!(t.s1.x, acc[1, fi]); _soft_ad_add!(t.s1.y, acc[2, fi])
        _soft_ad_add!(t.s2.x, acc[3, fi]); _soft_ad_add!(t.s2.y, acc[4, fi])
        _soft_ad_add!(t.s3.x, acc[5, fi]); _soft_ad_add!(t.s3.y, acc[6, fi])
        _soft_ad_add!(t.color.r, acc[7, fi])
        _soft_ad_add!(t.color.g, acc[8, fi])
        _soft_ad_add!(t.color.b, acc[9, fi])
        _soft_ad_add!(use_relative ? t.depth : t.logit, acc[10, fi])
    end
    _soft_ad_add!(pullback.sigma, scalars.sigma)
    _soft_ad_add!(pullback.gamma, scalars.gamma)
    _soft_ad_add!(pullback.eps, scalars.eps)
    _soft_ad_add!(pullback.background_logit, scalars.background_logit)
    _soft_ad_add!(pullback.bg.r, scalars.bg_r)
    _soft_ad_add!(pullback.bg.g, scalars.bg_g)
    _soft_ad_add!(pullback.bg.b, scalars.bg_b)
    return nothing
end

function _soft_ad_pixel_pullback!(acc, scalars, faces, xs, coverages, faded,
        depth_weights, weights, distance_grads, primal, tiles, n::Int,
        px::Int, py::Int, g_r::Float64, g_g::Float64, g_b::Float64,
        σ::Float64, γ::Float64, inv_γ::Float64, ε::Float64,
        bg::Color3{Float64}, background_logit::Float64,
        use_relative::Bool, gamma_is_ad::Bool)
    cx = _soft_pixel_center(Float64, px)
    cy = _soft_pixel_center(Float64, py)
    face_lo, face_hi = _soft_pixel_face_range(tiles, n, px, py)
    # Pass 1: stabilizing maximum logit (or minimum depth) and its owner.
    m = background_logit
    owner = 0
    @inbounds for k in face_lo:face_hi
        fi = _soft_pixel_face(tiles, k)
        tri = primal[fi]
        _soft_covers(tri, px, py) || continue
        if use_relative
            tri.depth < m && (m = tri.depth; owner = fi)
        else
            tri.logit > m && (m = tri.logit; owner = fi)
        end
    end
    count = 0
    total = 0.0
    average = Color3(0.0, 0.0, 0.0)
    # Pass 2: the forward weights, recorded per covering face.
    @inbounds for k in face_lo:face_hi
        fi = _soft_pixel_face(tiles, k)
        tri = primal[fi]
        _soft_covers(tri, px, py) || continue
        d, gax, gay, gbx, gby, gcx, gcy = _soft_signed_distance_gradient(
            cx, cy, tri.s1.x, tri.s1.y, tri.s2.x, tri.s2.y,
            tri.s3.x, tri.s3.y, tri.area)
        x = d / σ
        coverage = sigmoid_approx(x)
        is_faded = _soft_is_faded(tri.area, ε)
        is_faded && (coverage *= _soft_degenerate_fade(tri.area, ε))
        depth_weight = use_relative ?
            _soft_relative_weight_state(m, tri.depth, γ)[1] :
            exp(tri.logit - m)
        w = coverage * depth_weight
        next_total = total + w
        average = iszero(total) ? tri.color :
            _stable_color_lerp(average, tri.color, w / next_total)
        total = next_total
        count += 1
        faces[count] = fi
        xs[count] = x
        coverages[count] = coverage
        faded[count] = is_faded
        depth_weights[count] = depth_weight
        weights[count] = w
        distance_grads[1, count] = gax; distance_grads[2, count] = gay
        distance_grads[3, count] = gbx; distance_grads[4, count] = gby
        distance_grads[5, count] = gcx; distance_grads[6, count] = gcy
    end
    if iszero(total)
        # The pixel is exactly the background colour.
        scalars.bg_r += g_r; scalars.bg_g += g_g; scalars.bg_b += g_b
        return nothing
    end
    bg_weight, bg_scaled, bg_varies = use_relative ?
        _soft_relative_weight_state(m, 1.0, γ) :
        (exp(background_logit - m), 0.0, true)
    w_bg = bg_weight + ε
    denom = total + w_bg
    color = _stable_color_lerp(average, bg, w_bg / denom)
    # C = (Σ w_f c_f + w_bg bg) / S:  dC/dc_f = w_f/S, dC/dw_f = (c_f - C)/S,
    # dC/dbg = w_bg/S, dC/dw_bg = (bg - C)/S.
    bg_share = w_bg / denom
    scalars.bg_r += g_r * bg_share
    scalars.bg_g += g_g * bg_share
    scalars.bg_b += g_b * bg_share
    w_bg_bar = (g_r * (bg.r - color.r) + g_g * (bg.g - color.g) +
                g_b * (bg.b - color.b)) / denom
    scalars.eps += w_bg_bar
    m_bar = 0.0
    if use_relative
        if bg_varies && !iszero(w_bg_bar)
            scaled_bar = -(w_bg_bar * bg_weight)
            m_bar -= scaled_bar * inv_γ
            gamma_is_ad && (scalars.gamma += scaled_bar * (-bg_scaled / γ))
        end
    else
        # Mathematically the stabilizer's adjoint is eps * w̄_bg (the image is
        # invariant to m except through eps). Accumulate the individual terms
        # instead, as the recorded graph does: their rounding then cancels
        # against the per-logit adjoints, which matters when 1/γ² amplifies
        # the logit adjoints into the γ derivative.
        background_bar = w_bg_bar * bg_weight
        scalars.background_logit += background_bar
        m_bar -= background_bar
    end
    @inbounds for j in 1:count
        fi = faces[j]
        tri = primal[fi]
        share = weights[j] / denom
        acc[7, fi] += g_r * share
        acc[8, fi] += g_g * share
        acc[9, fi] += g_b * share
        w_bar = (g_r * (tri.color.r - color.r) + g_g * (tri.color.g - color.g) +
                 g_b * (tri.color.b - color.b)) / denom
        iszero(w_bar) && continue
        coverage_bar = w_bar * depth_weights[j]
        depth_weight_bar = w_bar * coverages[j]
        if use_relative
            weight, scaled, varies = _soft_relative_weight_state(m, tri.depth, γ)
            if varies && !iszero(depth_weight_bar)
                scaled_bar = -(depth_weight_bar * weight)
                delta_bar = scaled_bar * inv_γ
                acc[10, fi] += delta_bar
                m_bar -= delta_bar
                gamma_is_ad && (scalars.gamma += scaled_bar * (-scaled / γ))
            end
        else
            logit_bar = depth_weight_bar * depth_weights[j]
            acc[10, fi] += logit_bar
            m_bar -= logit_bar
        end
        iszero(coverage_bar) && continue
        x = xs[j]
        if faded[j]
            # coverage = sigmoid(x) * s(t), t = |A| / ε (`_soft_degenerate_fade`).
            fade_bar = coverage_bar * sigmoid_approx(x)
            coverage_bar *= _soft_degenerate_fade(tri.area, ε)
            _soft_ad_fade_pullback!(acc, scalars, fi, tri, ε, fade_bar)
        end
        x_bar = coverage_bar * _soft_sigmoid_derivative(x)
        iszero(x_bar) && continue
        d_bar = x_bar / σ
        scalars.sigma -= x_bar * (x / σ)
        acc[1, fi] += d_bar * distance_grads[1, j]
        acc[2, fi] += d_bar * distance_grads[2, j]
        acc[3, fi] += d_bar * distance_grads[3, j]
        acc[4, fi] += d_bar * distance_grads[4, j]
        acc[5, fi] += d_bar * distance_grads[5, j]
        acc[6, fi] += d_bar * distance_grads[6, j]
    end
    if !iszero(m_bar)
        if owner == 0
            use_relative || (scalars.background_logit += m_bar)
        else
            @inbounds acc[10, owner] += m_bar
        end
    end
    return nothing
end

function _soft_render_screen(::Type{ADVar}, screen_tris, n_screen_tris::Int,
                             W::Int, H::Int, σ, γ, bg::Color3{ADVar}, eps::ADVar,
                             use_relative_depth::Bool, workspace)
    recording = _ad_recording()
    primal = Vector{_SoftScreenTriangle{Float64}}(undef, n_screen_tris)
    @inbounds for fi in 1:n_screen_tris
        primal[fi] = _soft_primal_triangle(screen_tris[fi])
    end
    tiles = n_screen_tris <= _SOFT_DIRECT_SCAN_MAX ? nothing :
        _soft_build_tiles(primal, n_screen_tris, W, H, nothing)
    # Recorded before the image leaves so the sweep reaches it after the pullback.
    background_logit = use_relative_depth ? one(ADVar) : -one(ADVar) / γ
    σ_value = Float64(_primal_value(σ))
    γ_value = Float64(_primal_value(γ))
    eps_value = eps.val
    bg_value = Color3(bg.r.val, bg.g.val, bg.b.val)
    background_value = background_logit.val
    image = workspace === nothing ? Array{ADVar}(undef, H, W, 3) :
        _soft_image_buffer!(workspace, H, W)
    first_output = recording ? length(_ad_tape_stack()[end]) + 1 : 0
    zero_color = Color3(0.0, 0.0, 0.0)
    chunks = _soft_column_chunks(Float64, W, H)
    if chunks > 1
        # The Float64 pixel stage is evaluated by parallel tasks (see the
        # threading contract in soft_rasterizer.jl); the tape stays task-local,
        # so the image leaves are recorded afterwards in the serial order the
        # pullback reads.
        values = Array{Float64}(undef, H, W, 3)
        _soft_render_columns_parallel!(values, chunks, primal, tiles,
            n_screen_tris, W, H, σ_value, γ_value, bg_value, eps_value,
            use_relative_depth, background_value, 0.0, zero_color)
        @inbounds for py in 1:H, px in 1:W
            image[py, px, 1] = _ad_dependent_leaf(values[py, px, 1])
            image[py, px, 2] = _ad_dependent_leaf(values[py, px, 2])
            image[py, px, 3] = _ad_dependent_leaf(values[py, px, 3])
        end
    else
        for py in 1:H
            for px in 1:W
                color = _soft_pixel_color(primal, tiles, n_screen_tris, px, py,
                    _soft_pixel_center(Float64, px), _soft_pixel_center(Float64, py),
                    σ_value, γ_value, bg_value, eps_value, use_relative_depth,
                    background_value, 0.0, zero_color)
                image[py, px, 1] = _ad_dependent_leaf(color.r)
                image[py, px, 2] = _ad_dependent_leaf(color.g)
                image[py, px, 3] = _ad_dependent_leaf(color.b)
            end
        end
    end
    if recording
        _ad_record_pullback!(_SoftADPixelPullback(
            primal, screen_tris[1:n_screen_tris], tiles, W, H, σ, γ, eps, bg,
            background_logit, use_relative_depth, first_output))
    end
    return image
end

# ==========================================================================
# Fused reverse-mode rules for the pixelwise image losses.
#
# Recorded operation by operation, the compensated sums in `loss_mse` and
# `loss_l1` add about seven tape nodes per image element. These rules evaluate
# the Float64 loss on primal values and record a single output whose pullback
# applies d/dx_i = 2 (x_i - y_i) / n (MSE) or sign(x_i - y_i) / n (L1), with
# the sign of a zero difference taken as +1 like the recorded `abs`. The
# exact compensated summation has unit derivative with respect to each term.
# ==========================================================================

const _ADPlainScalar = Union{Base.IEEEFloat,Integer}

struct _ADImageLossPullback{I,T}
    image::I          # Vector{ADVar} of the image elements, or `nothing`
    target::T         # Vector{ADVar} of the target elements, or `nothing`
    differences::Vector{Float64}
    squared::Bool
    inv_count::Float64
    output::Int
end

function (pullback::_ADImageLossPullback)(tape::Vector{ADVar})
    adjoint = @inbounds tape[pullback.output].adj
    iszero(adjoint) && return nothing
    scale = adjoint * pullback.inv_count
    differences = pullback.differences
    image = pullback.image
    target = pullback.target
    @inbounds for i in eachindex(differences)
        difference = differences[i]
        element_bar = pullback.squared ? 2 * (scale * difference) :
            (difference < 0 ? -scale : scale)
        image === nothing || (image[i].adj += element_bar)
        target === nothing || (target[i].adj -= element_bar)
    end
    return nothing
end

@inline _ad_loss_primal(values::Array{ADVar,3}) = map(x -> x.val, values)
@inline _ad_loss_primal(values::Array) = values
@inline _ad_loss_nodes(values::Array{ADVar,3}) = vec(copy(values))
@inline _ad_loss_nodes(::Array) = nothing

function _ad_image_loss(image::Array, target::Array, squared::Bool)
    image_values = _ad_loss_primal(image)
    target_values = _ad_loss_primal(target)
    value = squared ? loss_mse(image_values, target_values) :
        loss_l1(image_values, target_values)
    output = _ad_dependent_leaf(Float64(value))
    if _ad_recording()
        differences = Vector{Float64}(undef, length(image))
        @inbounds for i in eachindex(differences, image_values, target_values)
            differences[i] = Float64(image_values[i]) - Float64(target_values[i])
        end
        _ad_record_pullback!(_ADImageLossPullback(
            _ad_loss_nodes(image), _ad_loss_nodes(target), differences, squared,
            1.0 / Float64(length(image)), length(_ad_tape_stack()[end])))
    end
    return output
end

loss_mse(image::Array{ADVar,3}, target::Array{S,3}) where {S<:_ADPlainScalar} =
    _ad_image_loss(image, target, true)
loss_mse(image::Array{S,3}, target::Array{ADVar,3}) where {S<:_ADPlainScalar} =
    _ad_image_loss(image, target, true)
loss_mse(image::Array{ADVar,3}, target::Array{ADVar,3}) =
    _ad_image_loss(image, target, true)
loss_l1(image::Array{ADVar,3}, target::Array{S,3}) where {S<:_ADPlainScalar} =
    _ad_image_loss(image, target, false)
loss_l1(image::Array{S,3}, target::Array{ADVar,3}) where {S<:_ADPlainScalar} =
    _ad_image_loss(image, target, false)
loss_l1(image::Array{ADVar,3}, target::Array{ADVar,3}) =
    _ad_image_loss(image, target, false)
