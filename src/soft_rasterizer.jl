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

"""
    SoftRasterizerConfig(; sigma=1.0, gamma=1.0, bg_color=Color3(0.0, 0.0, 0.0), eps=1e-8)

Configuration for [`soft_render`](@ref). `sigma` is the edge softness in
pixels (coverage `sigmoid_approx(d / sigma)` of the signed distance `d`),
`gamma` the depth-softmax temperature in NDC depth units, and `bg_color` the
colour of the virtual background surface at the far plane. `eps` (positive)
is the floor added to the background weight, the relative near/far clipping
margin, and the doubled screen area (in pixel²) below which a triangle's
coverage fades smoothly to zero as it degenerates.
"""
struct SoftRasterizerConfig{T<:Real}
    sigma::T       # Edge softness in pixel units (larger = softer)
    gamma::T       # Depth aggregation temperature in NDC units
    bg_color::Color3{T}
    eps::T
end

function _soft_positive_finite(value, label::String)
    value isa Real && !(value isa Bool) ||
        throw(ArgumentError("$label must be finite and positive"))
    scalar = _primal_value(value)
    (isfinite(scalar) && scalar > zero(scalar)) ||
        throw(ArgumentError("$label must be finite and positive"))
    return value
end

function _soft_finite_color(color, label::String)
    color isa Color3 ||
        throw(ArgumentError("$label must be a Color3 with finite components"))
    (isfinite(color.r) && isfinite(color.g) && isfinite(color.b)) ||
        throw(ArgumentError("$label must be finite"))
    return color
end

# When `1/gamma` is not representable, absolute depth logits overflow before
# max subtraction. A minimum-depth reference keeps every exponent non-positive.
# Farther deltas that still overflow are beyond the representable softmax tail;
# return a typed zero so ForwardDiff does not encounter `0 * Inf` partials.
# Ties and underflowed weights are decided on primal values: a Dual delta with
# a zero value but nonzero partials, or a weight whose value underflowed while
# its partials hold `0 * Inf`, would otherwise poison the image with NaN.
@inline function _soft_relative_depth_weight(nearest_depth, depth, gamma)
    delta = depth - nearest_depth
    iszero(_primal_value(delta)) && return one(delta)
    scaled_delta = delta / gamma
    isfinite(scaled_delta) || return zero(scaled_delta)
    weight = exp(-scaled_delta)
    return iszero(_primal_value(weight)) ? zero(weight) : weight
end

@inline _soft_pixel_center(::Type{T}, index::Int) where {T} = T(index) - T(0.5)

function SoftRasterizerConfig(; sigma=1.0, gamma=1.0,
                               bg_color=Color3(0.0, 0.0, 0.0),
                               eps=1e-8)
    _soft_positive_finite(sigma, "SoftRasterizerConfig sigma")
    _soft_positive_finite(gamma, "SoftRasterizerConfig gamma")
    _soft_positive_finite(eps, "SoftRasterizerConfig eps")
    _soft_finite_color(bg_color, "SoftRasterizerConfig bg_color")
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
    depth::T       # mean NDC depth of the three vertices
    logit::T       # depth softmax logit -depth/γ (depth when 1/γ overflows)
    min_x::Int
    max_x::Int
    min_y::Int
    max_y::Int
    area::T
    valid::Bool
end

"""Reusable scratch/output buffers for repeated `soft_render` calls with element type `T`.

When passed as `workspace`, the returned image array is owned by the workspace
and is overwritten by the next render that reuses the same dimensions.
"""
mutable struct SoftRenderWorkspace{T<:Real}
    screen_tris::Vector{_SoftScreenTriangle{T}}
    tile_counts::Vector{Int}
    tile_offsets::Vector{Int}
    tile_faces::Vector{Int}
    tile_cursor::Vector{Int}
    image::Array{T,3}
end

SoftRenderWorkspace{T}() where {T<:Real} =
    SoftRenderWorkspace{T}(_SoftScreenTriangle{T}[], Int[], Int[], Int[], Int[],
                           Array{T,3}(undef, 0, 0, 0))
SoftRenderWorkspace{T}(screen_tris::Vector{_SoftScreenTriangle{T}},
                       tile_counts::Vector{Int}, tile_offsets::Vector{Int},
                       tile_faces::Vector{Int}, tile_cursor::Vector{Int}) where {T<:Real} =
    SoftRenderWorkspace{T}(screen_tris, tile_counts, tile_offsets, tile_faces,
                           tile_cursor, Array{T,3}(undef, 0, 0, 0))
SoftRenderWorkspace() = SoftRenderWorkspace{Float64}()

"""Reusable scene-extraction and soft-rasterizer buffers for `soft_render_scene`.

The returned image follows the same reuse rules as `SoftRenderWorkspace`.
"""
mutable struct SoftRenderSceneWorkspace
    vertices::Vector{Vec3{Float64}}
    faces::Vector{NTuple{3,Int}}
    colors::Vector{Color3{Float64}}
    face_colors::Vector{Color3{Float64}}
    soft::SoftRenderWorkspace{Float64}
    meshes::Vector{Mesh}
    lights::Vector{SceneLight}
    morph_meshes::Vector{Mesh}
    morph_positions::Vector{Vec3{Float64}}
    skinned::Vector{SkinnedMesh}
    skinned_meshes::Vector{Mesh}
    skinning_matrices::Vector{Mat4{Float64}}
    instanced::Vector{InstancedMesh}
    instanced_materials::Vector{_InstancedMaterialState}
end

SoftRenderSceneWorkspace(vertices, faces, colors, face_colors, soft, meshes, lights) =
    SoftRenderSceneWorkspace(vertices, faces, colors, face_colors, soft, meshes, lights,
                             Mesh[], Vec3{Float64}[], SkinnedMesh[], Mesh[],
                             Mat4{Float64}[], InstancedMesh[], _InstancedMaterialState[])

SoftRenderSceneWorkspace(vertices, faces, colors, face_colors, soft) =
    SoftRenderSceneWorkspace(vertices, faces, colors, face_colors, soft,
                             Mesh[], SceneLight[])

SoftRenderSceneWorkspace() =
    SoftRenderSceneWorkspace(Vec3{Float64}[], NTuple{3,Int}[],
                             Color3{Float64}[], Color3{Float64}[],
                             SoftRenderWorkspace{Float64}())

function _soft_checked_workspace(workspace, ::Type{T}) where {T}
    workspace === nothing && return nothing
    workspace isa SoftRenderWorkspace{T} ||
        throw(ArgumentError("soft_render workspace element type must be $T; got $(typeof(workspace))"))
    return workspace
end

function _soft_screen_triangle_buffer!(workspace::SoftRenderWorkspace{T},
                                       n::Int) where {T}
    length(workspace.screen_tris) < n && resize!(workspace.screen_tris, n)
    return workspace.screen_tris
end

function _soft_int_buffer!(buf::Vector{Int}, n::Int)
    length(buf) < n && resize!(buf, n)
    return buf
end

function _soft_image_buffer!(workspace::SoftRenderWorkspace{T},
                             H::Int, W::Int) where {T}
    size(workspace.image) == (H, W, 3) ||
        (workspace.image = Array{T,3}(undef, H, W, 3))
    return workspace.image
end

function _soft_resize_buffer!(buf::Vector{T}, n::Int) where {T}
    length(buf) == n || resize!(buf, n)
    return buf
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

Degenerate triangles: a triangle whose doubled screen area `|A|` is below
`config.eps` (pixel²) has its coverage multiplied by `s(|A| / eps)` with
`s(t) = t^2 (3 - 2t)`, so a collapsing triangle fades out continuously and a
zero-area triangle covers nothing; triangles with `|A| >= eps` are unaffected.
"""
function soft_render(vertices::AbstractVector{Vec3{Tv}},
                     faces::Vector{NTuple{3,Int}},
                     face_colors::AbstractVector{Color3{Tc}},
                     view_proj::Mat4,
                     width::Int, height::Int,
                     config::SoftRasterizerConfig = SoftRasterizerConfig()
                     ; workspace=nothing
                     ) where {Tv, Tc}

    # Promote to a common element type so the renderer is differentiable with
    # respect to any subset of {vertices, colors, camera}: e.g. Dual vertices
    # with fixed Float64 colors. The common path (all the same type) hits the
    # `=== T` short-circuits and performs no extra work or allocation.
    T = promote_type(Tv, Tc, eltype(view_proj.e), typeof(config.sigma),
                     typeof(config.gamma), typeof(config.bg_color.r), typeof(config.eps))
    # Inline scalar values can be promoted on access without allocating input
    # copies. Heap-backed scalars retain eager conversion so shared vertices do
    # not repeatedly create BigFloat values or reverse-mode tape nodes.
    verts = if Tv === T
        vertices
    elseif isbitstype(T)
        _promote_vec3_source(vertices, T)
    else
        Vec3{T}[Vec3(T(v.x), T(v.y), T(v.z)) for v in vertices]
    end
    cols = if Tc === T
        face_colors
    elseif isbitstype(T)
        _promote_color_source(face_colors, T)
    else
        Color3{T}[Color3(T(c.r), T(c.g), T(c.b)) for c in face_colors]
    end
    vp = _promote_mat4(view_proj, T)

    # Dividing by a promoted constant Dual forms 0 * Inf partials once its
    # square underflows; keep the configured scalars as the divisors.
    σ = config.sigma
    γ = config.gamma
    bg = Color3(T(config.bg_color.r), T(config.bg_color.g), T(config.bg_color.b))
    eps = T(config.eps)
    workspace = _soft_checked_workspace(workspace, T)

    n_faces = length(faces)
    W, H = width, height
    (W > 0 && H > 0) || throw(ArgumentError("soft_render dimensions must be positive"))
    pixels = _render_checked_mul(W, H, "soft_render pixel count")
    _render_checked_mul(pixels, 3, "soft_render image element count")
    length(face_colors) == n_faces ||
        throw(ArgumentError("soft_render face_colors length must match faces length"))
    _soft_positive_finite(σ, "SoftRasterizerConfig sigma")
    _soft_positive_finite(γ, "SoftRasterizerConfig gamma")
    _soft_positive_finite(eps, "SoftRasterizerConfig eps")
    _soft_finite_color(bg, "SoftRasterizerConfig bg_color")
    γ_value = _primal_value(γ)
    use_relative_depth = !isfinite(one(γ_value) / γ_value)
    n_faces == 0 && return _soft_background_image(T, H, W, bg, workspace)
    n_vertices = length(verts)
    for face in faces
        i1, i2, i3 = face
        (1 <= i1 <= n_vertices && 1 <= i2 <= n_vertices && 1 <= i3 <= n_vertices) ||
            throw(ArgumentError("soft_render face indices must reference vertices"))
    end

    # Precompute screen-space triangles. Allocate for the common unclipped case
    # and grow only when near/far clipping splits a triangle.
    screen_tris = workspace === nothing ?
        Vector{_SoftScreenTriangle{T}}(undef, n_faces) :
        _soft_screen_triangle_buffer!(workspace, n_faces)
    n_screen_tris = 0
    max_screen_tris = _render_checked_mul(
        3, n_faces, "soft_render clipped triangle count")

    TW = T(W)
    TH = T(H)
    # Heap-backed AD scalars record every operation, so their vertices are
    # transformed and projected once instead of once per incident face.
    cache = isbitstype(T) ? nothing : _SoftVertexCache{T}(n_vertices)
    for fi in 1:n_faces
        i1, i2, i3 = faces[fi]
        a = _soft_vertex_clip(cache, verts, vp, i1)
        b = _soft_vertex_clip(cache, verts, vp, i2)
        c = _soft_vertex_clip(cache, verts, vp, i3)
        n_clipped, c1, c2, c3, c4 = _soft_clip_near_triangle(a, b, c, eps)
        n_clipped < 3 && continue
        n_clipped, c1, c2, c3, c4, c5 = _soft_clip_far_polygon(
            n_clipped, c1, c2, c3, c4, eps)
        n_clipped < 3 && continue
        s1 = _soft_vertex_screen(cache, c1, a, i1, b, i2, c, i3, TW, TH)
        s2 = _soft_vertex_screen(cache, c2, a, i1, b, i2, c, i3, TW, TH)
        s3 = _soft_vertex_screen(cache, c3, a, i1, b, i2, c, i3, TW, TH)
        n_screen_tris = _soft_store_screen_triangle!(
            screen_tris, n_screen_tris, max_screen_tris,
            s1, s2, s3, cols[fi], σ, γ, eps, use_relative_depth, W, H)
        if n_clipped >= 4
            s4 = _soft_vertex_screen(cache, c4, a, i1, b, i2, c, i3, TW, TH)
            n_screen_tris = _soft_store_screen_triangle!(
                screen_tris, n_screen_tris, max_screen_tris,
                s1, s3, s4, cols[fi], σ, γ, eps, use_relative_depth, W, H)
        end
        if n_clipped == 5
            s5 = _soft_project_clip_to_screen(c5, TW, TH)
            n_screen_tris = _soft_store_screen_triangle!(
                screen_tris, n_screen_tris, max_screen_tris,
                s1, s4, s5, cols[fi], σ, γ, eps, use_relative_depth, W, H)
        end
    end
    # Heap-backed scalar slots can retain an earlier differentiation graph.
    if workspace !== nothing && !isbitstype(T)
        resize!(screen_tris, n_screen_tris)
    end
    n_screen_tris == 0 && return _soft_background_image(T, H, W, bg, workspace)
    return _soft_render_screen(T, screen_tris, n_screen_tris, W, H,
                               σ, γ, bg, eps, use_relative_depth, workspace)
end

# --------------------------------------------------------------------------
# Spatial acceleration: uniform tile grid.
#
# A face contributes to pixel (px, py) iff
#   tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y.
# Each valid face is binned into every tile its bbox overlaps, so the per-pixel
# loop only visits the faces registered to that pixel's tile. A pixel in tile
# (tx, ty) lies inside the tile's pixel span, so any face whose bbox covers
# that pixel also overlaps the tile and is registered to it. The tile list is
# thus a superset of the covering faces in ascending face order; the unchanged
# per-pixel bbox test rejects the extras, so the retained faces and their order
# equal those of an all-faces scan and the floating-point result is unchanged.
# Bounds come from the integer bbox stored with each triangle, so binning adds
# no differentiable path.
# --------------------------------------------------------------------------
const _SOFT_TILE = 16
const _SOFT_DIRECT_SCAN_MAX = 8

@inline _soft_tile_of(p::Int) = (p - 1) ÷ _SOFT_TILE + 1

# Two-pass CSR build: allocation is O(faces + tile-overlap entries) and every
# per-tile list is contiguous and index-ordered. Returns `(offsets, faces,
# tiles_x)`; tile (tx, ty) owns `faces[offsets[t]:offsets[t+1]-1]` with
# t = (ty - 1) * tiles_x + tx.
function _soft_build_tiles(screen_tris::AbstractVector, n_screen_tris::Int,
                           W::Int, H::Int, workspace)
    n_tx = cld(W, _SOFT_TILE)
    n_ty = cld(H, _SOFT_TILE)
    n_tiles = _render_checked_mul(n_tx, n_ty, "soft_render tile count")
    tile_counts = workspace === nothing ? zeros(Int, n_tiles) :
        _soft_int_buffer!(workspace.tile_counts, n_tiles)
    fill!(tile_counts, 0)
    for fi in 1:n_screen_tris
        tri = screen_tris[fi]
        tri.valid || continue
        tx0 = _soft_tile_of(tri.min_x); tx1 = _soft_tile_of(tri.max_x)
        ty0 = _soft_tile_of(tri.min_y); ty1 = _soft_tile_of(tri.max_y)
        for ty in ty0:ty1, tx in tx0:tx1
            tile_counts[(ty - 1) * n_tx + tx] += 1
        end
    end
    tile_offsets = workspace === nothing ? Vector{Int}(undef, n_tiles + 1) :
        _soft_int_buffer!(workspace.tile_offsets, n_tiles + 1)
    tile_offsets[1] = 1
    for t in 1:n_tiles
        tile_offsets[t + 1] = tile_offsets[t] + tile_counts[t]
    end
    n_tile_faces = tile_offsets[n_tiles + 1] - 1
    tile_faces = workspace === nothing ? Vector{Int}(undef, n_tile_faces) :
        _soft_int_buffer!(workspace.tile_faces, n_tile_faces)
    tile_cursor = workspace === nothing ? copy(tile_offsets) :
        _soft_int_buffer!(workspace.tile_cursor, n_tiles + 1)
    copyto!(tile_cursor, 1, tile_offsets, 1, n_tiles + 1)
    for fi in 1:n_screen_tris
        tri = screen_tris[fi]
        tri.valid || continue
        tx0 = _soft_tile_of(tri.min_x); tx1 = _soft_tile_of(tri.max_x)
        ty0 = _soft_tile_of(tri.min_y); ty1 = _soft_tile_of(tri.max_y)
        for ty in ty0:ty1, tx in tx0:tx1
            t = (ty - 1) * n_tx + tx
            tile_faces[tile_cursor[t]] = fi
            tile_cursor[t] += 1
        end
    end
    return tile_offsets, tile_faces, n_tx
end

# Candidate faces of pixel (px, py): the tile list, or every face for tiny
# face sets that skip the spatial index.
@inline function _soft_pixel_face_range(tiles, n_screen_tris::Int, px::Int, py::Int)
    tiles === nothing && return 1, n_screen_tris
    tile_offsets, _, n_tx = tiles
    t = (_soft_tile_of(py) - 1) * n_tx + _soft_tile_of(px)
    return tile_offsets[t], tile_offsets[t + 1] - 1
end

@inline _soft_pixel_face(tiles, k::Int) = tiles === nothing ? k : tiles[2][k]

@inline _soft_covers(tri, px::Int, py::Int) =
    tri.valid && tri.min_x <= px <= tri.max_x && tri.min_y <= py <= tri.max_y

# SoftRas aggregation for one pixel. The foreground face weights and a
# background weight (a virtual surface at the far plane z=+1, hence exponent
# -1/γ) form a softmax over {faces, background}, stabilized by the maximum
# logit `m`. A covered pixel approaches the nearest face colour as σ,γ -> 0
# (recovering the hard rasterizer); an uncovered pixel reduces exactly to the
# background. The eps floor keeps the denominator strictly positive.
#
# When 1/γ is not representable, pass 1 tracks the minimum depth instead and
# pass 2 exponentiates only non-positive relative depth deltas. Both forms
# include the z=+1 background and are mathematically equivalent; the relative
# form avoids Inf-Inf.
@inline function _soft_pixel_color(screen_tris, tiles, n_screen_tris::Int,
                                   px::Int, py::Int, cx, cy, σ, γ, bg, eps,
                                   use_relative_depth::Bool, background_logit,
                                   zero_weight, zero_color)
    face_lo, face_hi = _soft_pixel_face_range(tiles, n_screen_tris, px, py)
    m = background_logit
    any_face = false
    for k in face_lo:face_hi
        tri = screen_tris[_soft_pixel_face(tiles, k)]
        _soft_covers(tri, px, py) || continue
        if use_relative_depth
            tri.depth < m && (m = tri.depth)
        else
            tri.logit > m && (m = tri.logit)
        end
        any_face = true
    end

    total_weight = zero_weight
    average_color = zero_color
    if any_face
        for k in face_lo:face_hi
            tri = screen_tris[_soft_pixel_face(tiles, k)]
            _soft_covers(tri, px, py) || continue
            d = _signed_distance_to_triangle_area(cx, cy,
                tri.s1.x, tri.s1.y, tri.s2.x, tri.s2.y, tri.s3.x, tri.s3.y,
                tri.area)
            coverage = sigmoid_approx(d / σ)
            if _soft_is_faded(tri.area, eps)
                coverage *= _soft_degenerate_fade(tri.area, eps)
            end
            depth_weight = use_relative_depth ?
                _soft_relative_depth_weight(m, tri.depth, γ) :
                exp(tri.logit - m)
            w = coverage * depth_weight
            next_weight = total_weight + w
            average_color = iszero(_primal_value(total_weight)) ? tri.color :
                _stable_color_lerp(average_color, tri.color, w / next_weight)
            total_weight = next_weight
        end
    end

    w_bg = (use_relative_depth ?
        _soft_relative_depth_weight(m, one(m), γ) :
        exp(background_logit - m)) + eps
    denom = total_weight + w_bg
    return iszero(_primal_value(total_weight)) ? bg :
        _stable_color_lerp(average_color, bg, w_bg / denom)
end

# Image model at degeneracy. A triangle whose doubled screen area |A| is below
# the configured `eps` (pixel^2) has its coverage multiplied by the smoothstep
# s(t) = t^2 (3 - 2t), t = |A| / eps, which is 1 with zero slope at |A| = eps
# and 0 with zero slope at A = 0. A collapsing triangle therefore fades out
# continuously (C1) instead of switching from a half-covered sliver to
# nothing; triangles with |A| >= eps are unchanged. The test uses primal values
# so AD scalars take the same branch.
@inline _soft_is_faded(area, eps) =
    abs(_primal_value(area)) < _primal_value(eps)

@inline function _soft_degenerate_fade(area, eps)
    t = abs(area) / eps
    return t * t * (3 - 2t)
end

# Per-vertex clip and screen positions, filled on first use.
struct _SoftVertexCache{T}
    clip::Vector{Vec4{T}}
    screen::Vector{Vec3{T}}
    has_clip::Vector{Bool}
    has_screen::Vector{Bool}
end

_SoftVertexCache{T}(n::Int) where {T} =
    _SoftVertexCache{T}(Vector{Vec4{T}}(undef, n), Vector{Vec3{T}}(undef, n),
                        fill(false, n), fill(false, n))

@inline function _soft_vertex_clip(::Nothing, verts, vp, index::Int)
    v = verts[index]
    return mat4_transform_vec4(vp, Vec4(v.x, v.y, v.z, one(v.x)))
end

@inline function _soft_vertex_clip(cache::_SoftVertexCache, verts, vp, index::Int)
    if !cache.has_clip[index]
        cache.clip[index] = _soft_vertex_clip(nothing, verts, vp, index)
        cache.has_clip[index] = true
    end
    return cache.clip[index]
end

@inline _soft_vertex_screen(::Nothing, clip, a, ia, b, ib, c, ic, W, H) =
    _soft_project_clip_to_screen(clip, W, H)

# A clipped polygon vertex that is one of the face's own vertices (`===`
# identity, so interpolated vertices never match) reuses its cached projection.
@inline function _soft_vertex_screen(cache::_SoftVertexCache, clip,
                                     a, ia::Int, b, ib::Int, c, ic::Int, W, H)
    index = clip === a ? ia : clip === b ? ib : clip === c ? ic : 0
    index == 0 && return _soft_project_clip_to_screen(clip, W, H)
    if !cache.has_screen[index]
        cache.screen[index] = _soft_project_clip_to_screen(clip, W, H)
        cache.has_screen[index] = true
    end
    return cache.screen[index]
end

function _soft_render_screen(::Type{T}, screen_tris, n_screen_tris::Int,
                             W::Int, H::Int, σ, γ, bg::Color3{T}, eps::T,
                             use_relative_depth::Bool, workspace) where {T}
    # Tiny face sets need no spatial index: scanning directly avoids the CSR
    # tile buffers that dominate small inverse-rendering problems.
    tiles = n_screen_tris <= _SOFT_DIRECT_SCAN_MAX ? nothing :
        _soft_build_tiles(screen_tris, n_screen_tris, W, H, workspace)
    # Pixel-independent scalars are formed once, so heap-backed AD types do not
    # record or allocate them per pixel.
    background_logit = use_relative_depth ? one(T) : -one(T) / γ
    zero_weight = zero(T)
    zero_color = Color3(zero_weight, zero_weight, zero_weight)
    image = workspace === nothing ? Array{T}(undef, H, W, 3) :
        _soft_image_buffer!(workspace, H, W)
    for py in 1:H
        for px in 1:W
            color = _soft_pixel_color(screen_tris, tiles, n_screen_tris, px, py,
                _soft_pixel_center(T, px), _soft_pixel_center(T, py),
                σ, γ, bg, eps, use_relative_depth, background_logit,
                zero_weight, zero_color)
            image[py, px, 1] = color.r
            image[py, px, 2] = color.g
            image[py, px, 3] = color.b
        end
    end
    return image
end

function _soft_background_image(::Type{T}, H::Int, W::Int, bg::Color3{T},
                                workspace=nothing) where {T}
    if workspace !== nothing && !isbitstype(T)
        empty!(workspace.screen_tris)
    end
    image = workspace === nothing ? Array{T}(undef, H, W, 3) :
        _soft_image_buffer!(workspace, H, W)
    @inbounds for j in 1:W, i in 1:H
        image[i, j, 1] = bg.r
        image[i, j, 2] = bg.g
        image[i, j, 3] = bg.b
    end
    return image
end

# `face_flip === nothing` derives the front-face flip from `world_mat` (a mesh);
# an InstancedMesh passes the flip of its object matrix, because three.js
# flips front faces for a mirrored matrixWorld only (WebGLRenderer.js
# `frontFaceCW`), never for an instance matrix.
@inline function _soft_shade_mesh_faces!(colors::Vector{Color3{Float64}},
                                         geo::BufferGeometry, world_mat::Mat4,
                                         material::AbstractMaterial,
                                         lights::Vector{<:AbstractLight},
                                         cam_pos::Vec3, camera_view::Mat4,
                                         ortho_dir, face_flip::Union{Nothing,Bool})
    face_flip === nothing && return shade_mesh_faces!(
        colors, geo, world_mat, material, lights, cam_pos;
        camera_view=camera_view, ortho_dir=ortho_dir)
    return _shade_mesh_faces_flip!(
        colors, geo, world_mat, material, lights, cam_pos, face_flip;
        camera_view=camera_view, ortho_dir=ortho_dir)
end

@inline function _soft_shade_mesh_faces_from_material!(colors::Vector{Color3{Float64}},
                                          geo::BufferGeometry, world_mat::Mat4,
                                          @nospecialize(mat),
                                          lights::Vector{<:AbstractLight},
                                          cam_pos::Vec3,
                                          camera_view::Mat4,
                                          ortho_dir,
                                          face_flip::Union{Nothing,Bool})
    if mat isa MeshBasicMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshLambertMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshPhongMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshStandardMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshPhysicalMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshToonMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshNormalMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshMatcapMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa MeshDepthMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    elseif mat isa AbstractMaterial
        return _soft_shade_mesh_faces!(colors, geo, world_mat, mat, lights, cam_pos, camera_view, ortho_dir, face_flip)
    else
        throw(ArgumentError("soft_render_scene mesh material must be an AbstractMaterial"))
    end
end

@inline _soft_near_value(v::Vec4, eps) =
    v.z + v.w - eps * abs(v.w)
@inline _soft_far_value(v::Vec4, eps) =
    v.w - v.z + eps * abs(v.w)

# Inside tests evaluate the same expressions on primal values: the decisions
# are identical, and heap-backed AD scalars record no nodes for vertices that
# need no interpolation.
@inline _soft_primal_vec4(v::Vec4) = Vec4(_primal_value(v.x), _primal_value(v.y),
                                          _primal_value(v.z), _primal_value(v.w))
@inline _soft_near_inside(v::Vec4, eps) =
    _soft_near_value(_soft_primal_vec4(v), _primal_value(eps)) >= 0
@inline _soft_far_inside(v::Vec4, eps) =
    _soft_far_value(_soft_primal_vec4(v), _primal_value(eps)) >= 0

@inline function _soft_lerp_clip(a::Vec4, b::Vec4, t)
    Vec4(a.x + t * (b.x - a.x),
         a.y + t * (b.y - a.y),
         a.z + t * (b.z - a.z),
         a.w + t * (b.w - a.w))
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
    prev_in = _soft_near_inside(prev, eps)
    @inbounds for curr in (a, b, c)
        curr_in = _soft_near_inside(curr, eps)
        if curr_in != prev_in
            prev_d = _soft_near_value(prev, eps)
            curr_d = _soft_near_value(curr, eps)
            t = prev_d / (prev_d - curr_d)
            out_n, c1, c2, c3, c4 =
                _soft_clip_push(out_n, _soft_lerp_clip(prev, curr, t), c1, c2, c3, c4)
        end
        if curr_in
            out_n, c1, c2, c3, c4 = _soft_clip_push(out_n, curr, c1, c2, c3, c4)
        end
        prev = curr
        prev_in = curr_in
    end
    return out_n, c1, c2, c3, c4
end

@inline function _soft_clip_vertex(index::Int, c1, c2, c3, c4)
    index == 1 && return c1
    index == 2 && return c2
    index == 3 && return c3
    return c4
end

@inline function _soft_clip_push5(n::Int, v::Vec4{T},
                                  c1::Vec4{T}, c2::Vec4{T},
                                  c3::Vec4{T}, c4::Vec4{T},
                                  c5::Vec4{T}) where {T}
    n += 1
    if n == 1
        c1 = v
    elseif n == 2
        c2 = v
    elseif n == 3
        c3 = v
    elseif n == 4
        c4 = v
    else
        c5 = v
    end
    return n, c1, c2, c3, c4, c5
end

function _soft_clip_far_polygon(n::Int, a::Vec4{T}, b::Vec4{T},
                                c::Vec4{T}, d::Vec4{T}, eps) where {T}
    out_n = 0
    c1 = a
    c2 = a
    c3 = a
    c4 = a
    c5 = a
    prev = _soft_clip_vertex(n, a, b, c, d)
    prev_in = _soft_far_inside(prev, eps)
    @inbounds for index in 1:n
        current = _soft_clip_vertex(index, a, b, c, d)
        current_in = _soft_far_inside(current, eps)
        if current_in != prev_in
            prev_distance = _soft_far_value(prev, eps)
            current_distance = _soft_far_value(current, eps)
            t = prev_distance / (prev_distance - current_distance)
            out_n, c1, c2, c3, c4, c5 = _soft_clip_push5(
                out_n, _soft_lerp_clip(prev, current, t),
                c1, c2, c3, c4, c5)
        end
        if current_in
            out_n, c1, c2, c3, c4, c5 = _soft_clip_push5(
                out_n, current, c1, c2, c3, c4, c5)
        end
        prev = current
        prev_in = current_in
    end
    return out_n, c1, c2, c3, c4, c5
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

@inline _soft_coverage_margin(::Type{P}, sigma) where {P} =
    max(P(3.0) * sigma, one(P))

function _soft_screen_triangle(s1::Vec3{T}, s2::Vec3{T}, s3::Vec3{T},
                               color::Color3{T}, σ, γ, eps,
                               use_relative_depth::Bool, W::Int, H::Int) where {T}
    area = edge_function(s1.x, s1.y, s2.x, s2.y, s3.x, s3.y)
    # Pixel-independent depth terms are formed once per triangle.
    depth = _mean3_scaled(s1.z, s2.z, s3.z)
    logit = use_relative_depth ? depth : -depth / γ

    # The sigmoid tail extends with sigma. Do not impose a fixed pixel cap here:
    # very soft silhouettes are expected to influence distant pixels.
    # The integer bounds are discrete, so they use primal values: AD scalars
    # select the same bounds and record nothing.
    x1 = _primal_value(s1.x); y1 = _primal_value(s1.y)
    x2 = _primal_value(s2.x); y2 = _primal_value(s2.y)
    x3 = _primal_value(s3.x); y3 = _primal_value(s3.y)
    P = typeof(x1)
    margin = _soft_coverage_margin(P, _primal_value(σ))
    finite = isfinite(x1) && isfinite(y1) &&
             isfinite(x2) && isfinite(y2) &&
             isfinite(x3) && isfinite(y3)
    fW = Float64(W)
    fH = Float64(H)
    if finite
        bmin_x = max(floor(Int, clamp(min(x1, x2, x3) - margin, 1.0, fW)), 1)
        bmax_x = min(ceil(Int,  clamp(max(x1, x2, x3) + margin, 1.0, fW)), W)
        bmin_y = max(floor(Int, clamp(min(y1, y2, y3) - margin, 1.0, fH)), 1)
        bmax_y = min(ceil(Int,  clamp(max(y1, y2, y3) + margin, 1.0, fH)), H)
    else
        bmin_x = 1
        bmax_x = 0
        bmin_y = 1
        bmax_y = 0
    end
    # Zero-area (and non-finite NaN-area) triangles cover nothing. Triangles
    # with doubled area below `eps` stay, with coverage faded to zero as the
    # area vanishes (`_soft_degenerate_fade`), so coverage is continuous.
    valid = finite && abs(_primal_value(area)) > zero(P) &&
            bmax_x >= bmin_x && bmax_y >= bmin_y
    return _SoftScreenTriangle(s1, s2, s3, color, depth, logit,
                               bmin_x, bmax_x, bmin_y, bmax_y,
                               area, valid)
end

@inline function _soft_store_screen_triangle!(
        screen_tris::Vector{_SoftScreenTriangle{T}}, n::Int, max_n::Int,
        s1::Vec3{T}, s2::Vec3{T}, s3::Vec3{T}, color::Color3{T},
        σ, γ, eps, use_relative_depth::Bool, W::Int, H::Int) where {T}
    if n == length(screen_tris)
        resize!(screen_tris, min(max_n, max(n + 1, 2n)))
    end
    n += 1
    @inbounds screen_tris[n] = _soft_screen_triangle(
        s1, s2, s3, color, σ, γ, eps, use_relative_depth, W, H)
    return n
end

"""
    sigmoid_approx(x)

The logistic function `1 / (1 + exp(-x))`, evaluated in the form that cannot
overflow for either sign of `x`. It is exact (not an approximation) and
preserves the scalar type, so ForwardDiff and `ADVar` inputs differentiate it.
"""
@inline function sigmoid_approx(x::T) where T
    if x >= zero(T)
        return one(T) / (one(T) + exp(-x))
    else
        ex = exp(x)
        return ex / (one(T) + ex)
    end
end

# Exact sign of the edge function, for coordinates whose Float64 product overflows.
@noinline function _soft_edge_sign_bigfloat(ax::Float64, ay::Float64,
                                            bx::Float64, by::Float64,
                                            px::Float64, py::Float64)
    return setprecision(BigFloat, 256) do
        bax = BigFloat(bx) - BigFloat(ax)
        bay = BigFloat(by) - BigFloat(ay)
        pax = BigFloat(px) - BigFloat(ax)
        pay = BigFloat(py) - BigFloat(ay)
        value = pax * bay - pay * bax
        value > 0 ? 1 : value < 0 ? -1 : 0
    end
end

@inline function _soft_edge_sign_float(ax::Float64, ay::Float64,
                                       bx::Float64, by::Float64,
                                       px::Float64, py::Float64)
    value = edge_function(ax, ay, bx, by, px, py)
    if isfinite(value)
        return value > 0.0 ? 1 : value < 0.0 ? -1 : 0
    end
    return _soft_edge_sign_bigfloat(ax, ay, bx, by, px, py)
end

function _soft_extreme_signed_distance_float(
        px::Float64, py::Float64,
        ax::Float64, ay::Float64, bx::Float64, by::Float64,
        cx::Float64, cy::Float64)
    area_sign = _soft_edge_sign_float(ax, ay, bx, by, cx, cy)
    area_sign == 0 && return -1.0e10
    s0 = _soft_edge_sign_float(bx, by, cx, cy, px, py)
    s1 = _soft_edge_sign_float(cx, cy, ax, ay, px, py)
    s2 = _soft_edge_sign_float(ax, ay, bx, by, px, py)
    inside = area_sign > 0 ?
             (s0 >= 0 && s1 >= 0 && s2 >= 0) :
             (s0 <= 0 && s1 <= 0 && s2 <= 0)
    if inside
        return min(
            point_line_distance(px, py, ax, ay, bx, by),
            point_line_distance(px, py, bx, by, cx, cy),
            point_line_distance(px, py, cx, cy, ax, ay),
        )
    end
    return -min(
        point_segment_distance(px, py, ax, ay, bx, by),
        point_segment_distance(px, py, bx, by, cx, cy),
        point_segment_distance(px, py, cx, cy, ax, ay),
    )
end

function _signed_distance_to_triangle_area(px, py, ax, ay, bx, by, cx, cy, area)
    if area isa Float64 && !isfinite(area) &&
       px isa Float64 && py isa Float64 &&
       ax isa Float64 && ay isa Float64 &&
       bx isa Float64 && by isa Float64 &&
       cx isa Float64 && cy isa Float64
        return _soft_extreme_signed_distance_float(
            px, py, ax, ay, bx, by, cx, cy)
    end

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

"""
    signed_distance_to_triangle(px, py, ax, ay, bx, by, cx, cy)

Signed screen-space distance from point `(px, py)` to the triangle with
vertices `(ax, ay)`, `(bx, by)`, `(cx, cy)` in either winding: inside (or on
the boundary) it is the distance to the nearest edge line
([`point_line_distance`](@ref)); outside it is minus the distance to the nearest
edge segment ([`point_segment_distance`](@ref)). A triangle whose doubled area
is below `1e-20` returns `-1e10`. This is the coverage argument of
[`soft_render`](@ref), which evaluates `sigmoid_approx(d / sigma)`.
"""
function signed_distance_to_triangle(px, py, ax, ay, bx, by, cx, cy)
    area = edge_function(ax, ay, bx, by, cx, cy)
    return _signed_distance_to_triangle_area(px, py, ax, ay, bx, by, cx, cy, area)
end

# `a * b`, with an exact zero when either factor is zero (avoids 0 * Inf).
@inline _soft_zero_product(a::Float64, b::Float64) =
    (iszero(a) || iszero(b)) ? 0.0 : a * b

@inline function _soft_max_abs_coordinate(px::Float64, py::Float64,
                                          ax::Float64, ay::Float64,
                                          bx::Float64, by::Float64)
    pscale = max(abs(px), abs(py))
    ascale = max(abs(ax), abs(ay))
    bscale = max(abs(bx), abs(by))
    return max(max(pscale, ascale), bscale)
end

@inline function _soft_line_unit_float(ax::Float64, ay::Float64,
                                       bx::Float64, by::Float64)
    dx, dy = bx - ax, by - ay
    len = hypot(dx, dy)
    if len > 0.0 && isfinite(len)
        return dx / len, dy / len, len
    end

    endpoint_scale = max(max(abs(ax), abs(ay)), max(abs(bx), abs(by)))
    endpoint_scale > 0.0 || return 0.0, 0.0, 0.0
    sdx = bx / endpoint_scale - ax / endpoint_scale
    sdy = by / endpoint_scale - ay / endpoint_scale
    scaled_len = hypot(sdx, sdy)
    scaled_len > 0.0 || return 0.0, 0.0, 0.0
    return sdx / scaled_len, sdy / scaled_len, Inf
end

"""
    point_line_distance(px, py, ax, ay, bx, by)

Unsigned distance from point `(px, py)` to the infinite line through
`(ax, ay)` and `(bx, by)`. The line length is floored at `1e-20`, so coincident
endpoints give distance zero instead of dividing by zero. `Float64` inputs
use a rescaled evaluation that stays finite for coordinates near `floatmax`.
"""
@inline function point_line_distance(px::Float64, py::Float64,
                                     ax::Float64, ay::Float64,
                                     bx::Float64, by::Float64)
    ux, uy, len = _soft_line_unit_float(ax, ay, bx, by)
    if len > 0.0
        # Measuring from the midpoint keeps both extreme endpoints close enough
        # to subtract. Exact zero products avoid the indeterminate Inf*0 form
        # for an axis-aligned line and a far-away point.
        mx = _geometry_midpoint(ax, bx)
        my = _geometry_midpoint(ay, by)
        ox, oy = px - mx, py - my
        signed_distance =
            _soft_zero_product(ox, uy) - _soft_zero_product(oy, ux)
        if isfinite(signed_distance)
            length_floor = isfinite(len) ? len / max(len, 1.0e-20) : 1.0
            return abs(signed_distance) * length_floor
        end
    end

    # Fully scale all coordinates only when the direct calculation cannot
    # represent an intermediate. Line distance is homogeneous under this scale.
    scale = _soft_max_abs_coordinate(px, py, ax, ay, bx, by)
    scale > 0.0 || return 0.0
    spx, spy = px / scale, py / scale
    sax, say = ax / scale, ay / scale
    sbx, sby = bx / scale, by / scale
    dx, dy = sbx - sax, sby - say
    scaled_len = hypot(dx, dy)
    numerator = abs((spx - sax) * dy - (spy - say) * dx)
    return numerator * scale / max(scaled_len, 1.0e-20 / scale)
end

# Numerical floors in the scalar type of a hardware or BigFloat computation, so
# Float32 inputs stay Float32. AD scalars keep the Float64 literal (unchanged
# promotion, no tape node for a constant).
@inline _soft_constant(::Type{T}, value::Float64) where {T<:AbstractFloat} = T(value)
@inline _soft_constant(::Type, value::Float64) = value

@inline function point_line_distance(px, py, ax, ay, bx, by)
    dx = bx - ax
    dy = by - ay
    len = hypot(dx, dy)
    abs((px - ax) * dy - (py - ay) * dx) / max(len, _soft_constant(typeof(len), 1e-20))
end

# Clamped projection parameter of (px, py) onto segment (ax, ay)-(bx, by) of
# length `len`, rescaling when an intermediate is not representable.
@inline function _soft_segment_parameter_float(px::Float64, py::Float64,
                                               ax::Float64, ay::Float64,
                                               bx::Float64, by::Float64,
                                               len::Float64)
    dx, dy = bx - ax, by - ay
    if isfinite(len) && isfinite(dx) && isfinite(dy)
        ox, oy = px - ax, py - ay
        qx, qy = ox / len, oy / len
        t = _soft_zero_product(qx, dx / len) +
            _soft_zero_product(qy, dy / len)
        isnan(t) || return clamp(t, 0.0, 1.0)
    end

    # The projection parameter is invariant under a common coordinate scale.
    scale = _soft_max_abs_coordinate(px, py, ax, ay, bx, by)
    scale > 0.0 || return 0.0
    spx, spy = px / scale, py / scale
    sax, say = ax / scale, ay / scale
    sbx, sby = bx / scale, by / scale
    sdx, sdy = sbx - sax, sby - say
    denominator = sdx * sdx + sdy * sdy
    if denominator > 0.0
        t = ((spx - sax) * sdx + (spy - say) * sdy) / denominator
        isnan(t) || return clamp(t, 0.0, 1.0)
    end

    # If scaling erased an exceptionally short segment, either endpoint is an
    # adequate projection reference; choose the nearer one deterministically.
    da = hypot(spx - sax, spy - say)
    db = hypot(spx - sbx, spy - sby)
    return da <= db ? 0.0 : 1.0
end

"""
    point_segment_distance(px, py, ax, ay, bx, by)

Distance from point `(px, py)` to the closed segment `(ax, ay)`-`(bx, by)`,
smoothed as `sqrt(d^2 + 1e-12)` so the derivative stays finite (zero) when the
point lies on the segment. The projection parameter is clamped to `[0, 1]`; a
segment shorter than `1e-10` is treated as its first endpoint.
"""
function point_segment_distance(px::Float64, py::Float64,
                                ax::Float64, ay::Float64,
                                bx::Float64, by::Float64)
    dx, dy = bx - ax, by - ay
    len = hypot(dx, dy)
    smoothing = 1.0e-6
    if len < 1.0e-10
        return hypot(px - ax, py - ay, smoothing)
    end
    t = _soft_segment_parameter_float(px, py, ax, ay, bx, by, len)
    proj_x = (1.0 - t) * ax + t * bx
    proj_y = (1.0 - t) * ay + t * by
    return hypot(px - proj_x, py - proj_y, smoothing)
end

function point_segment_distance(px, py, ax, ay, bx, by)
    dx = bx - ax
    dy = by - ay
    len_sq = dx^2 + dy^2
    # Smoothing epsilon under the square roots: sqrt has an infinite derivative
    # at 0, so a sample point landing exactly on the segment (distance 0) would
    # make ForwardDiff return Inf*0 = NaN and poison the whole gradient. The added
    # 1e-12 (≈1e-6 px) makes the distance smooth everywhere with a finite (zero)
    # derivative at 0; the bias is negligible relative to the sigmoid softness sigma.
    smoothing = _soft_constant(typeof(len_sq), 1e-12)
    if len_sq < 1e-20
        return sqrt((px - ax)^2 + (py - ay)^2 + smoothing)
    end
    t = clamp(((px - ax)*dx + (py - ay)*dy) / len_sq, zero(px), one(px))
    proj_x = ax + t * dx
    proj_y = ay + t * dy
    sqrt((px - proj_x)^2 + (py - proj_y)^2 + smoothing)
end

# ========================== High-level differentiable render ==========================

@inline function _soft_append_geometry!(vertices, faces, colors, face_colors,
                                 geo::BufferGeometry, world::Mat4, @nospecialize(material),
                                 lights, camera_position, view, ortho_dir,
                                 vertex_offset::Int, face_offset::Int,
                                 face_flip::Union{Nothing,Bool}=nothing)
    selected = _draw_face_range(geo)
    isempty(selected) && return vertex_offset, face_offset
    for vertex in 1:geo.n_vertices
        vertices[vertex_offset+vertex] = mat4_transform_point(world,get_vertex(geo,vertex))
    end
    _soft_shade_mesh_faces_from_material!(face_colors,geo,world,material,
                                         lights,camera_position,view,ortho_dir,face_flip)
    for face in selected
        i1,i2,i3 = get_face(geo,face)
        face_offset += 1
        faces[face_offset] = (i1+vertex_offset,i2+vertex_offset,i3+vertex_offset)
        colors[face_offset] = face_colors[face]
    end
    return vertex_offset+geo.n_vertices, face_offset
end

function _soft_append_instances!(vertices, faces, colors, face_colors,
                                  object::InstancedMesh, materials::Vector{M},
                                  lights, camera_position, view, ortho_dir,
                                  vertex_offset::Int, face_offset::Int) where {M<:AbstractMaterial}
    geo = _instanced_geometry(object)
    base = compute_world_matrix(object)
    mirrored = _world_mirrors_faces(base)
    for index in eachindex(object.instance_matrices)
        world = base*object.instance_matrices[index]
        vertex_offset,face_offset = _soft_append_geometry!(vertices,faces,colors,face_colors,
            geo,world,materials[index],lights,camera_position,view,ortho_dir,vertex_offset,face_offset,
            mirrored)
    end
    return vertex_offset,face_offset
end

"""
    soft_render_scene(scene, camera, width, height;
                      sigma=1.0, gamma=1.0, workspace=nothing)

Render visible triangle meshes, posed skins, and triangle instances with soft
coverage. Honors camera layers, LOD selection, and geometry draw ranges.
Scene extraction uses `Float64` geometry and colors. For derivatives with
respect to geometry or cameras, use [`soft_render`](@ref) or
[`differentiable_render`](@ref) with explicit parametric inputs.

Pass a [`SoftRenderSceneWorkspace`](@ref) to reuse scene-extraction and render
buffers. Its returned image is overwritten by the next render that reuses the
same workspace and dimensions; copy the image to retain it.
"""
function soft_render_scene(scene::Scene, camera::AbstractCamera,
                           width::Int, height::Int;
                           sigma=1.0, gamma=1.0, workspace=nothing)
    config = SoftRasterizerConfig(sigma=sigma, gamma=gamma, bg_color=scene.background)

    proj = projection_matrix(camera)
    camera_position, camera_target, camera_up = _camera_world_pose(camera)
    view = view_matrix(camera)
    vp = proj * view
    ortho_dir = camera isa OrthographicCamera ?
        _camera_backward_from_view(view) : nothing

    scene_workspace = workspace isa SoftRenderSceneWorkspace ? workspace : nothing
    _update_scene_lods!(scene, camera)
    meshes = scene_workspace === nothing ? collect_meshes(scene) :
        _collect_meshes_into!(scene_workspace.meshes, scene)
    layer_mask = _object_layer_mask(camera)
    _filter_object_layers!(meshes, nothing, layer_mask)
    if scene_workspace === nothing
        _prepare_morph_render_meshes!(meshes)
        _append_skinned_render_meshes!(meshes,scene,SkinnedMesh[]; layer_mask=layer_mask)
    else
        _prepare_morph_render_meshes!(meshes, scene_workspace.morph_meshes,
                                      scene_workspace.morph_positions)
        _append_skinned_render_meshes!(meshes,scene,scene_workspace.skinned,
            scene_workspace.skinned_meshes,scene_workspace.skinning_matrices,
            scene_workspace.morph_positions; layer_mask=layer_mask)
    end
    instanced = scene_workspace === nothing ? _collect_instanced_into!(InstancedMesh[],scene) :
        _collect_instanced_into!(scene_workspace.instanced,scene)
    _filter_object_layers!(instanced,nothing,layer_mask)
    for object in instanced
        _validate_instanced_mesh(object,"soft_render_scene")
    end
    filter!(_instanced_triangle_drawable,instanced)
    instance_materials = scene_workspace === nothing ? _InstancedMaterialState[] : scene_workspace.instanced_materials
    _prepare_instanced_material_states!(instance_materials, instanced)
    lights = scene_workspace === nothing ? _collect_lights_into!(SceneLight[], scene, layer_mask) :
        _collect_lights_into!(scene_workspace.lights, scene, layer_mask)

    total_vertices = 0
    total_faces = 0
    max_mesh_faces = 0
    for mesh in meshes
        geo = _mesh_geometry(mesh)
        _validate_triangle_geometry_indices(geo, "soft_render_scene")
        mesh.material isa AbstractMaterial ||
            throw(ArgumentError("soft_render_scene mesh material must be an AbstractMaterial"))
        selected = _draw_face_range(geo)
        isempty(selected) && continue
        total_vertices = _geometry_checked_add(
            total_vertices, geo.n_vertices, "soft_render_scene vertex count")
        total_faces = _geometry_checked_add(
            total_faces, length(selected), "soft_render_scene face count")
        max_mesh_faces = max(max_mesh_faces, geo.n_faces)
    end
    for object in instanced
        geo = _instanced_geometry(object)
        _validate_triangle_geometry_indices(geo,"soft_render_scene")
        selected = _draw_face_range(geo)
        count = length(object.instance_matrices)
        (isempty(selected) || iszero(count)) && continue
        vertices = _geometry_checked_mul(geo.n_vertices,count,"soft_render_scene instance vertex count")
        faces = _geometry_checked_mul(length(selected),count,"soft_render_scene instance face count")
        total_vertices = _geometry_checked_add(total_vertices,vertices,"soft_render_scene vertex count")
        total_faces = _geometry_checked_add(total_faces,faces,"soft_render_scene face count")
        max_mesh_faces = max(max_mesh_faces,geo.n_faces)
    end

    soft_workspace = scene_workspace === nothing ? workspace : scene_workspace.soft
    all_verts = scene_workspace === nothing ? Vector{Vec3{Float64}}(undef, total_vertices) :
        _soft_resize_buffer!(scene_workspace.vertices, total_vertices)
    all_faces = scene_workspace === nothing ? Vector{NTuple{3,Int}}(undef, total_faces) :
        _soft_resize_buffer!(scene_workspace.faces, total_faces)
    all_colors = scene_workspace === nothing ? Vector{Color3{Float64}}(undef, total_faces) :
        _soft_resize_buffer!(scene_workspace.colors, total_faces)
    face_colors = scene_workspace === nothing ? Vector{Color3{Float64}}(undef, max_mesh_faces) :
        _soft_resize_buffer!(scene_workspace.face_colors, max_mesh_faces)
    vert_offset = 0
    face_offset = 0

    for mesh in meshes
        world_mat = compute_world_matrix(mesh)
        geo = _mesh_geometry(mesh)
        vert_offset,face_offset = _soft_append_geometry!(all_verts,all_faces,all_colors,face_colors,
            geo,world_mat,mesh.material,lights,camera_position,view,ortho_dir,vert_offset,face_offset)
    end
    for (slot,object) in pairs(instanced)
        geo = _instanced_geometry(object)
        isempty(_draw_face_range(geo)) && continue
        materials = _instanced_materials!(instance_materials,slot,object,
            _instanced_material(object),object.instance_colors)
        vert_offset,face_offset = _soft_append_instances!(all_verts,all_faces,all_colors,face_colors,
            object,materials,lights,camera_position,view,ortho_dir,vert_offset,face_offset)
    end

    soft_render(all_verts, all_faces, all_colors, vp, width, height, config;
                workspace=soft_workspace)
end

"""
    differentiable_render(params, setup_fn, width, height;
                          sigma=1.0, gamma=1.0, workspace=nothing)

Render an image from explicit parameters. `setup_fn(params)` returns
`(vertices, faces, face_colors, view_proj, bg_color)`. Preserve the parameter
scalar type in these values when differentiating with ForwardDiff or `ADVar`;
converting a differentiated value to `Float64` discards its derivative.

This function delegates to [`soft_render`](@ref). `workspace` follows the
[`SoftRenderWorkspace`](@ref) ownership and scalar-type rules. The function does
not mutate a scene or camera on the caller's behalf.
"""
function differentiable_render(params::AbstractVector{T},
                               setup_fn::Function,
                               width::Int, height::Int;
                               sigma=1.0, gamma=1.0,
                               workspace=nothing) where T
    # setup_fn returns (vertices, faces, face_colors, view_proj, bg_color)
    vertices, faces, face_colors, vp, bg = setup_fn(params)
    config = SoftRasterizerConfig(sigma=sigma, gamma=gamma, bg_color=bg)
    soft_render(vertices, faces, face_colors, vp, width, height, config;
                workspace=workspace)
end
