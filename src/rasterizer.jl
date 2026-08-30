# --------------------------------------------------------------------------
# CPU software rasterizer with z-buffer.
# Produces an H×W×3 Float64 image array (RGB, values in [0,1]).
# --------------------------------------------------------------------------

struct RenderTarget{T<:Real}
    width::Int
    height::Int
    color::Array{T, 3}    # H × W × 3 (RGB)
    depth::Matrix{T}      # H × W

    function RenderTarget{T}(width::Int, height::Int, color::Array{T,3},
                             depth::Matrix{T}) where {T<:Real}
        (width > 0 && height > 0) ||
            throw(ArgumentError("RenderTarget dimensions must be positive"))
        size(color) == (height, width, 3) ||
            throw(ArgumentError(
                "RenderTarget color dimensions must be height×width×3"))
        size(depth) == (height, width) ||
            throw(ArgumentError(
                "RenderTarget depth dimensions must be height×width"))
        _render_target_type(T)
        return new{T}(width, height, color, depth)
    end
end

RenderTarget(width::Int, height::Int, color::Array{T,3},
             depth::Matrix{T}) where {T<:Real} =
    RenderTarget{T}(width, height, color, depth)

@inline function _render_checked_mul(a::Int, b::Int, label::AbstractString)
    (a >= 0 && b >= 0) || throw(ArgumentError("$label must be non-negative"))
    try
        return Base.checked_mul(a, b)
    catch err
        err isa OverflowError || rethrow()
        throw(ArgumentError("$label is too large"))
    end
end

function _render_target_type(::Type{T}) where {T}
    (T <: Real && isconcretetype(T)) ||
        throw(ArgumentError("RenderTarget element type must be a concrete Real type"))
    infinity = try
        T(Inf)
    catch
        throw(ArgumentError(
            "RenderTarget element type must represent positive infinity"))
    end
    valid_infinity = try
        infinity isa T && isinf(infinity) && infinity > zero(infinity)
    catch
        false
    end
    valid_infinity ||
        throw(ArgumentError(
            "RenderTarget element type must represent positive infinity"))
    return infinity
end

function RenderTarget(width::Int, height::Int; T=Float64)
    (width > 0 && height > 0) || throw(ArgumentError("RenderTarget dimensions must be positive"))
    T isa Type ||
        throw(ArgumentError("RenderTarget element type must be a concrete Real type"))
    infinity = _render_target_type(T)
    pixels = _render_checked_mul(width, height, "RenderTarget pixel count")
    _render_checked_mul(pixels, 3, "RenderTarget color element count")
    color = zeros(T, height, width, 3)
    depth = fill(infinity, height, width)
    RenderTarget{T}(width, height, color, depth)
end

function clear!(rt::RenderTarget, bg::Color3)
    isfinite(bg.r) && isfinite(bg.g) && isfinite(bg.b) ||
        throw(ArgumentError("render background must have finite components"))
    rt.color[:, :, 1] .= bg.r
    rt.color[:, :, 2] .= bg.g
    rt.color[:, :, 3] .= bg.b
    rt.depth .= eltype(rt.depth)(Inf)
end

# Scissor-limited clear: only the pixel rectangle [xlo:xhi, ylo:yhi] (inclusive,
# 1-based, already clamped to the buffer) is cleared. Pixels outside the scissor
# rectangle are left untouched, matching three.js `setScissor` + `setScissorTest`
# behaviour where clears are restricted to the scissor box. The full-frame
# `clear!` above is unchanged and is used when scissor testing is off.
function clear_rect!(rt::RenderTarget, bg::Color3, xlo::Int, xhi::Int, ylo::Int, yhi::Int)
    (xhi < xlo || yhi < ylo) && return rt
    isfinite(bg.r) && isfinite(bg.g) && isfinite(bg.b) ||
        throw(ArgumentError("render background must have finite components"))
    @inbounds for px in xlo:xhi, py in ylo:yhi
        rt.color[py, px, 1] = bg.r
        rt.color[py, px, 2] = bg.g
        rt.color[py, px, 3] = bg.b
        rt.depth[py, px] = eltype(rt.depth)(Inf)
    end
    return rt
end

@inline function _saturating_add_int(a::Int, b::Int)
    if b > 0 && a > typemax(Int) - b
        return typemax(Int)
    elseif b < 0 && a < typemin(Int) - b
        return typemin(Int)
    end
    return a + b
end

function _scissor_bounds(rt::RenderTarget, scissor::NTuple{4,Int})
    sxr, syr, swr, shr = scissor
    xlo = max(1, _saturating_add_int(sxr, 1))
    xhi = min(rt.width, _saturating_add_int(sxr, swr))
    ylo = max(1, _saturating_add_int(syr, 1))
    yhi = min(rt.height, _saturating_add_int(syr, shr))
    return xlo, xhi, ylo, yhi
end

function _intersect_scissor(a::NTuple{4,Int}, b::NTuple{4,Int})
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    x0 = max(ax, bx); y0 = max(ay, by)
    x1 = min(_saturating_add_int(ax, aw), _saturating_add_int(bx, bw))
    y1 = min(_saturating_add_int(ay, ah), _saturating_add_int(by, bh))
    (x1 <= x0 || y1 <= y0) && return nothing
    return (x0, y0, x1 - x0, y1 - y0)
end

@inline _camera_near(c::AbstractCamera) = c.near
@inline _camera_far(c::AbstractCamera) = c.far
@inline _mesh_geometry(mesh::Mesh)::BufferGeometry = mesh.geometry
@inline _mesh_material(mesh::Mesh)::AbstractMaterial = mesh.material

# Logarithmic depth encoding (three.js `logarithmicDepthBuffer`, interpolated-
# varying fallback). Given the clip-space `w` of a vertex (for a perspective
# camera, `w` is the positive view-space distance to the camera plane), encode
#
#     z_log = log2(max(1e-6, w + 1)) / log2(far + 1)
#
# `inv_log_far = 1 / log2(far + 1)` is precomputed once per frame. The encoding is
# monotonically increasing in distance and lands in roughly [0, 1] for w in
# [0, far], so the existing "smaller depth wins" z-test (`z < depth`) keeps the
# nearer fragment exactly as with NDC z. Spreading precision logarithmically keeps
# usable resolution across very large far/near ratios where linear NDC z collapses
# almost entirely onto the far plane. Three.js without `EXT_frag_depth`
# interpolates this value as a vertex varying; this rasterizer matches that by
# encoding per clipped vertex and letting the barycentric depth interpolation
# carry the encoded value, so no per-fragment log is required.
@inline _encode_log_depth(w, inv_log_far) = log2(max(1.0e-6, w + 1.0)) * inv_log_far

# An infinite far plane has no finite normalization distance. Use the largest
# representable view distance so finite clip-space w values retain a monotone
# encoded depth in [0, 1] instead of all collapsing to zero.
@inline function _inverse_log_depth_far(far::Float64)
    normalization_far = isinf(far) ? floatmax(Float64) : far
    return 1.0 / log2(normalization_far + 1.0)
end

# Intersect view-space edge a→b with the near plane (view-space z = -near).
@inline function _clip_intersect_near(a::Vec4, b::Vec4, near)
    t = (-near - a.z) / (b.z - a.z)
    Vec4(a.x + t*(b.x - a.x), a.y + t*(b.y - a.y),
         a.z + t*(b.z - a.z), a.w + t*(b.w - a.w))
end

# Sutherland–Hodgman clip of a convex view-space polygon against the near plane,
# keeping the half-space z ≤ -near (in front of the camera's near plane). Writes
# the clipped vertices into `out` (reused buffer) and returns its length.
function _clip_near!(out::Vector{Vec4{T}}, verts::Vector{Vec4{T}}, n::Int, near) where T
    empty!(out)
    @inbounds for i in 1:n
        cur = verts[i]
        prv = verts[i == 1 ? n : i - 1]
        cur_in = cur.z <= -near
        prv_in = prv.z <= -near
        if cur_in
            prv_in || push!(out, _clip_intersect_near(prv, cur, near))
            push!(out, cur)
        elseif prv_in
            push!(out, _clip_intersect_near(prv, cur, near))
        end
    end
    return length(out)
end

# Shared empty/zero constants so the no-clip path threads typed defaults without
# allocating per call.
const _NO_PLANES = Plane{Float64}[]
const _ZERO_V3 = Vec3(0.0, 0.0, 0.0)
const _ZERO_V2 = Vec2(0.0, 0.0)
const _EMPTY_INT_STAMP = zeros(Int, 0, 0)

@inline _inside_far_clip(z) = isfinite(z) && z <= one(z)
@inline _inside_near_clip(z) = isfinite(z) && z >= -one(z)

struct _CombinedClippingPlanes{G,M}
    global_planes::G
    material_planes::M
end

Base.isempty(planes::_CombinedClippingPlanes) =
    isempty(planes.global_planes) && isempty(planes.material_planes)

# A fragment lies on the "kept" side of every clipping plane when its signed
# distance is non-negative for all of them (three.js `clippingPlanes`: a plane
# clips away the half-space on the negative side of its normal). With no planes
# this is a no-op. `wp` is the fragment's interpolated world position.
@inline function _clip_keep(planes, wp::Vec3)
    @inbounds for pl in planes
        plane_distance_to_point(pl, wp) < 0 && return false
    end
    return true
end

@inline function _clip_keep(planes::_CombinedClippingPlanes, wp::Vec3)
    return _clip_keep(planes.global_planes, wp) &&
           _clip_keep(planes.material_planes, wp)
end

# Rasterize one screen-space triangle (flat color) with z-buffer. `ylo`/`yhi`
# and `xlo`/`xhi` clamp the scanline/column range so a tiled renderer can restrict
# output to a band and so scissor testing can restrict output to a pixel box.
# When `clipping_planes` is non-empty, each fragment's world position is
# barycentrically interpolated from the triangle's world vertices `wp1/wp2/wp3`
# and the fragment is discarded if it falls on the negative side of any plane.
@inline function _rasterize_tri!(rt::RenderTarget, s1x, s1y, z1, s2x, s2y, z2,
                                 s3x, s3y, z3, fc::Color3, ylo::Int=1, yhi::Int=typemax(Int);
                                 xlo::Int=1, xhi::Int=typemax(Int),
                                 clipping_planes=_NO_PLANES,
                                 wp1::Vec3=_ZERO_V3, wp2::Vec3=_ZERO_V3, wp3::Vec3=_ZERO_V3,
                                 iw1::Float64=1.0, iw2::Float64=1.0, iw3::Float64=1.0,
                                 depth_test::Bool=true, depth_write::Bool=true,
                                 alpha_test::Float64=0.0, alpha_base::Float64=1.0,
                                 albedo_map=nothing, alpha_map=nothing,
                                 uv1::Vec2=_ZERO_V2, uv2::Vec2=_ZERO_V2, uv3::Vec2=_ZERO_V2,
                                 uv2_1::Vec2=_ZERO_V2, uv2_2::Vec2=_ZERO_V2, uv2_3::Vec2=_ZERO_V2)
    W, H = rt.width, rt.height
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-10 && return nothing
    # Skip triangles with non-finite screen coords, and clamp extreme-but-finite
    # extents into the buffer (in float) before the Int conversion, so an
    # off-screen/degenerate vertex contributes nothing instead of an InexactError.
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    fW, fH = Float64(W), Float64(H)
    inv_area = 1.0 / area
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int, clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int, clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, alpha_base, albedo_map, alpha_map)
    @inbounds for px in min_x:max_x
        for py in min_y:max_y
            cx = px - 0.5
            cy = py - 0.5
            w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if w0 >= 0 && w1 >= 0 && w2 >= 0
                z = w0 * z1 + w1 * z2 + w2 * z3
                _inside_far_clip(z) || continue
                if !depth_test || z < rt.depth[py, px]
                    if has_clip || has_alpha
                        # Perspective-correct world position (weight by 1/w).
                        iw = w0*iw1 + w1*iw2 + w2*iw3
                        a0 = w0*iw1/iw; a1 = w1*iw2/iw; a2 = w2*iw3/iw
                        if has_clip
                            wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                                      a0*wp1.y + a1*wp2.y + a2*wp3.y,
                                      a0*wp1.z + a1*wp2.z + a2*wp3.z)
                            _clip_keep(clipping_planes, wp) || continue
                        end
                        if has_alpha
                            u = a0*uv1.x + a1*uv2.x + a2*uv3.x
                            v = a0*uv1.y + a1*uv2.y + a2*uv3.y
                            u2 = a0*uv2_1.x + a1*uv2_2.x + a2*uv2_3.x
                            v2 = a0*uv2_1.y + a1*uv2_2.y + a2*uv2_3.y
                            _fragment_alpha(alpha_base, albedo_map, alpha_map, u, v, u2, v2) >= alpha_test ||
                                continue
                        end
                    end
                    depth_write && (rt.depth[py, px] = z)
                    rt.color[py, px, 1] = fc.r
                    rt.color[py, px, 2] = fc.g
                    rt.color[py, px, 3] = fc.b
                end
            end
        end
    end
    return nothing
end

@inline function _rasterize_tri_alpha!(rt::RenderTarget,
        s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3, fc::Color3,
        ylo::Int, yhi::Int, xlo::Int, xhi::Int, clipping_planes,
        wp1::Vec3, wp2::Vec3, wp3::Vec3,
        iw1::Float64, iw2::Float64, iw3::Float64,
        depth_test::Bool, depth_write::Bool,
        alpha_test::Float64, alpha_base::Float64, albedo_map, alpha_map,
        uv1::Vec2, uv2::Vec2, uv3::Vec2,
        uv2_1::Vec2, uv2_2::Vec2, uv2_3::Vec2)
    W, H = rt.width, rt.height
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-10 && return nothing
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    fW, fH = Float64(W), Float64(H)
    inv_area = 1.0 / area
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int, clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int, clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    has_clip = !isempty(clipping_planes)
    @inbounds for px in min_x:max_x
        for py in min_y:max_y
            cx = px - 0.5
            cy = py - 0.5
            w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if w0 >= 0 && w1 >= 0 && w2 >= 0
                z = w0 * z1 + w1 * z2 + w2 * z3
                _inside_far_clip(z) || continue
                if !depth_test || z < rt.depth[py, px]
                    iw = w0*iw1 + w1*iw2 + w2*iw3
                    a0 = w0*iw1/iw; a1 = w1*iw2/iw; a2 = w2*iw3/iw
                    if has_clip
                        wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                                  a0*wp1.y + a1*wp2.y + a2*wp3.y,
                                  a0*wp1.z + a1*wp2.z + a2*wp3.z)
                        _clip_keep(clipping_planes, wp) || continue
                    end
                    u = a0*uv1.x + a1*uv2.x + a2*uv3.x
                    v = a0*uv1.y + a1*uv2.y + a2*uv3.y
                    u2 = a0*uv2_1.x + a1*uv2_2.x + a2*uv2_3.x
                    v2 = a0*uv2_1.y + a1*uv2_2.y + a2*uv2_3.y
                    _fragment_alpha(alpha_base, albedo_map, alpha_map, u, v, u2, v2) >= alpha_test ||
                        continue
                    depth_write && (rt.depth[py, px] = z)
                    rt.color[py, px, 1] = fc.r
                    rt.color[py, px, 2] = fc.g
                    rt.color[py, px, 3] = fc.b
                end
            end
        end
    end
    return nothing
end

# ==========================================================================
# Smooth (per-pixel) shading path.
# Per-vertex world position and normal are interpolated perspective-correctly
# and the shading model is evaluated at every covered pixel, matching three.js
# smooth shading. Faces whose vertices share a normal (sphere, cylinder, …)
# render smoothly; faces with per-face normals (box) stay flat-faceted.
# ==========================================================================

struct ShadeVtx
    vp::Vec4{Float64}   # view-space position (for near-plane clipping)
    wp::Vec3{Float64}   # world-space position
    wn::Vec3{Float64}   # world-space normal (unnormalised; normalised per pixel)
    uv::Vec2{Float64}   # texture coordinate (for per-pixel material maps)
    uv2::Vec2{Float64}  # secondary texture coordinate (AO/light maps)
    vc::Color3{Float64} # vertex color factor (for material vertex_colors)
end

@inline function _lerp_shadevtx(a::ShadeVtx, b::ShadeVtx, t)
    ShadeVtx(Vec4(a.vp.x + t*(b.vp.x - a.vp.x), a.vp.y + t*(b.vp.y - a.vp.y),
                  a.vp.z + t*(b.vp.z - a.vp.z), a.vp.w + t*(b.vp.w - a.vp.w)),
             Vec3(a.wp.x + t*(b.wp.x - a.wp.x), a.wp.y + t*(b.wp.y - a.wp.y), a.wp.z + t*(b.wp.z - a.wp.z)),
             Vec3(a.wn.x + t*(b.wn.x - a.wn.x), a.wn.y + t*(b.wn.y - a.wn.y), a.wn.z + t*(b.wn.z - a.wn.z)),
             Vec2(a.uv.x + t*(b.uv.x - a.uv.x), a.uv.y + t*(b.uv.y - a.uv.y)),
             Vec2(a.uv2.x + t*(b.uv2.x - a.uv2.x), a.uv2.y + t*(b.uv2.y - a.uv2.y)),
             Color3(a.vc.r + t*(b.vc.r - a.vc.r),
                    a.vc.g + t*(b.vc.g - a.vc.g),
                    a.vc.b + t*(b.vc.b - a.vc.b)))
end

@inline function _vertex_color(attr::BufferAttribute, vi)
    s = attr.item_size
    b = (vi - 1) * s
    d = attr.data
    Color3(d[b + 1], d[b + 2], d[b + 3])
end

@inline function _shade_vertex(geo, vi::Int, world_mat::Mat4, normal_mat::Mat4,
                               modelview::Mat4, has_normals::Bool, fallback_n::Vec3,
                               has_uvs::Bool, uv2_attr, use_vertex_colors::Bool,
                               color_attr)
    v = get_vertex(geo, vi)
    nrm = has_normals ? get_normal(geo, vi) : fallback_n
    wp = mat4_transform_point(world_mat, v)
    wn = mat4_transform_direction(normal_mat, nrm)
    vp = mat4_transform_vec4(modelview, Vec4(v.x, v.y, v.z, 1.0))
    uv = has_uvs ? Vec2(geo.uvs[(vi - 1) * 2 + 1], geo.uvs[(vi - 1) * 2 + 2]) : Vec2(0.0, 0.0)
    uv2 = uv2_attr === nothing ? uv : Vec2(_vertex_uv_attr(uv2_attr, vi)...)
    vc = use_vertex_colors ? _vertex_color(color_attr, vi) : Color3(1.0, 1.0, 1.0)
    ShadeVtx(vp, wp, wn, uv, uv2, vc)
end

function _clip_near_attr!(out::Vector{ShadeVtx}, verts::Vector{ShadeVtx}, n::Int, near)
    empty!(out)
    @inbounds for i in 1:n
        cur = verts[i]
        prv = verts[i == 1 ? n : i - 1]
        cur_in = cur.vp.z <= -near
        prv_in = prv.vp.z <= -near
        if cur_in
            if !prv_in
                t = (-near - prv.vp.z) / (cur.vp.z - prv.vp.z)
                push!(out, _lerp_shadevtx(prv, cur, t))
            end
            push!(out, cur)
        elseif prv_in
            t = (-near - prv.vp.z) / (cur.vp.z - prv.vp.z)
            push!(out, _lerp_shadevtx(prv, cur, t))
        end
    end
    return length(out)
end

# Transparent triangles use a half-open top-left fill rule. Screen y increases
# downward, so a canonically oriented edge owns its boundary when it points down,
# or points left when horizontal. Reorienting by the triangle-area sign makes the
# result independent of winding. Adjacent triangles (including a fan introduced
# by near clipping) therefore divide a shared boundary between them, while
# overlapping triangle interiors remain independent source-over layers.
@inline function _raster_edge_owns_boundary(ax, ay, bx, by,
                                             positive_area::Bool)
    dx = bx - ax
    dy = by - ay
    if !positive_area
        dx = -dx
        dy = -dy
    end
    return dy > 0 || (iszero(dy) && dx < 0)
end

@inline function _half_open_triangle_contains(
        b0, b1, b2,
        s1x, s1y, s2x, s2y, s3x, s3y,
        positive_area::Bool)
    edge0 = b0 > 0 || (iszero(b0) &&
        _raster_edge_owns_boundary(s2x, s2y, s3x, s3y, positive_area))
    edge0 || return false
    edge1 = b1 > 0 || (iszero(b1) &&
        _raster_edge_owns_boundary(s3x, s3y, s1x, s1y, positive_area))
    edge1 || return false
    return b2 > 0 || (iszero(b2) &&
        _raster_edge_owns_boundary(s1x, s1y, s2x, s2y, positive_area))
end

# Per-pixel (smooth) triangle. World position and normal are interpolated
# perspective-correctly, then the shading model is evaluated per pixel. When the
# material carries UV-indexed material maps, the texture coordinate is also
# interpolated perspective-correctly and the maps are applied per pixel using the
# same helpers (`sample_texture_linear`, `_apply_normal_map`) as the flat path — so a
# textured surface looks identical under flat and smooth shading. `clipping_planes`
# discards fragments on the negative side of any plane (interpolated world pos).
@inline function _rasterize_tri_smooth!(rt::RenderTarget,
        s1x, s1y, z1, iw1, view_depth1, wp1::Vec3, wn1::Vec3, uv1::Vec2, uv2_1::Vec2, vc1::Color3,
        s2x, s2y, z2, iw2, view_depth2, wp2::Vec3, wn2::Vec3, uv2::Vec2, uv2_2::Vec2, vc2::Color3,
        s3x, s3y, z3, iw3, view_depth3, wp3::Vec3, wn3::Vec3, uv3::Vec2, uv2_3::Vec2, vc3::Color3,
        material::M, lights, cam_pos::Vec3, shadow_fn,
        albedo_map, alpha_map, normal_map, roughness_map, metalness_map,
        specular_map, glossiness_map, physical_pbr_map, ao_map, emissive_map, light_map,
        normal_scale, clipping_planes;
        xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
        depth_test::Bool=true, depth_write::Bool=true,
        stamp=nothing, stamp_id::Int=0, use_vertex_colors::Bool=true,
        blend::Bool=false, normal_sign::Float64=1.0) where {M<:AbstractMaterial}
    if use_vertex_colors
        return _rasterize_tri_smooth_impl!(Val(true), rt,
            s1x, s1y, z1, iw1, view_depth1, wp1, wn1, uv1, uv2_1, vc1,
            s2x, s2y, z2, iw2, view_depth2, wp2, wn2, uv2, uv2_2, vc2,
            s3x, s3y, z3, iw3, view_depth3, wp3, wn3, uv3, uv2_3, vc3,
            material, lights, cam_pos, shadow_fn, albedo_map, alpha_map,
            normal_map, roughness_map, metalness_map, specular_map,
            glossiness_map, physical_pbr_map, ao_map, emissive_map,
            light_map, normal_scale, clipping_planes;
            xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
            depth_test=depth_test, depth_write=depth_write,
            stamp=stamp, stamp_id=stamp_id, blend=blend,
            normal_sign=normal_sign)
    end
    return _rasterize_tri_smooth_impl!(Val(false), rt,
        s1x, s1y, z1, iw1, view_depth1, wp1, wn1, uv1, uv2_1, vc1,
        s2x, s2y, z2, iw2, view_depth2, wp2, wn2, uv2, uv2_2, vc2,
        s3x, s3y, z3, iw3, view_depth3, wp3, wn3, uv3, uv2_3, vc3,
        material, lights, cam_pos, shadow_fn, albedo_map, alpha_map,
        normal_map, roughness_map, metalness_map, specular_map,
        glossiness_map, physical_pbr_map, ao_map, emissive_map,
        light_map, normal_scale, clipping_planes;
        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
        depth_test=depth_test, depth_write=depth_write,
        stamp=stamp, stamp_id=stamp_id, blend=blend,
        normal_sign=normal_sign)
end

@inline function _rasterize_tri_smooth_impl!(::Val{UseVertexColors}, rt::RenderTarget,
        s1x, s1y, z1, iw1, view_depth1, wp1::Vec3, wn1::Vec3, uv1::Vec2, uv2_1::Vec2, vc1::Color3,
        s2x, s2y, z2, iw2, view_depth2, wp2::Vec3, wn2::Vec3, uv2::Vec2, uv2_2::Vec2, vc2::Color3,
        s3x, s3y, z3, iw3, view_depth3, wp3::Vec3, wn3::Vec3, uv3::Vec2, uv2_3::Vec2, vc3::Color3,
        material::M, lights, cam_pos::Vec3, shadow_fn,
        albedo_map, alpha_map, normal_map, roughness_map, metalness_map,
        specular_map, glossiness_map, physical_pbr_map, ao_map, emissive_map, light_map,
        normal_scale, clipping_planes;
        xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
        depth_test::Bool=true, depth_write::Bool=true,
        stamp=nothing, stamp_id::Int=0,
        blend::Bool=false,
        normal_sign::Float64=1.0) where {M<:AbstractMaterial, UseVertexColors}
    W, H = rt.width, rt.height
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-10 && return nothing
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    fW, fH = Float64(W), Float64(H)
    inv_area = 1.0 / area
    positive_area = area > 0
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int, clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int, clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    has_albedo = albedo_map !== nothing
    has_alpha_map = alpha_map !== nothing
    has_normalmap = normal_map !== nothing
    has_roughness = roughness_map !== nothing
    has_metalness = metalness_map !== nothing
    has_specular = specular_map !== nothing
    has_glossiness = glossiness_map !== nothing
    has_physical_pbr = physical_pbr_map !== nothing
    has_ao = ao_map !== nothing
    has_emissive = emissive_map !== nothing
    has_lightmap = light_map !== nothing
    env_map = _envmap_field(material)
    has_env = env_map !== nothing
    has_uv_maps = has_albedo || has_alpha_map || has_normalmap || has_roughness ||
                  has_metalness || has_specular || has_glossiness ||
                  has_physical_pbr || has_ao || has_emissive || has_lightmap ||
                  has_env
    has_clip = !isempty(clipping_planes)
    alpha_test = material_alpha_test(material)
    alpha_base = Float64(material_opacity(material))
    normal_seed_valid = false
    normal_tangent = Vec3(0.0, 0.0, 0.0)
    normal_handedness = 0.0
    if has_normalmap
        normal_uvs = _texture_uv_set(normal_map) == 1 ?
            ((uv2_1.x, uv2_1.y), (uv2_2.x, uv2_2.y), (uv2_3.x, uv2_3.y)) :
            ((uv1.x, uv1.y), (uv2.x, uv2.y), (uv3.x, uv3.y))
        normal_seed_valid, normal_tangent, normal_handedness =
            _normal_map_tangent_seed(wp1, wp2, wp3, normal_uvs[1], normal_uvs[2],
                                     normal_uvs[3])
    end
    @inbounds for px in min_x:max_x
        for py in min_y:max_y
            cx = px - 0.5
            cy = py - 0.5
            b0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            b1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            b2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if blend
                _half_open_triangle_contains(
                    b0, b1, b2, s1x, s1y, s2x, s2y, s3x, s3y,
                    positive_area) || continue
            else
                (b0 >= 0 && b1 >= 0 && b2 >= 0) || continue
            end
            z = b0 * z1 + b1 * z2 + b2 * z3
            _inside_far_clip(z) || continue
            (!depth_test || z < rt.depth[py, px]) || continue
            frag_alpha = alpha_base
            # Perspective-correct interpolation: weight by 1/w.
            iw = b0 * iw1 + b1 * iw2 + b2 * iw3
            a0 = b0 * iw1 / iw; a1 = b1 * iw2 / iw; a2 = b2 * iw3 / iw
            fragment_view_depth = a0 * view_depth1 +
                                  a1 * view_depth2 +
                                  a2 * view_depth3
            wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                        a0*wp1.y + a1*wp2.y + a2*wp3.y,
                        a0*wp1.z + a1*wp2.z + a2*wp3.z)
            has_clip && (_clip_keep(clipping_planes, wp) || continue)
            (!has_uv_maps && alpha_base < alpha_test) && continue
            wn = normalize(Vec3(a0*wn1.x + a1*wn2.x + a2*wn3.x,
                                a0*wn1.y + a1*wn2.y + a2*wn3.y,
                                a0*wn1.z + a1*wn2.z + a2*wn3.z)) *
                 normal_sign
            vc = Color3(a0*vc1.r + a1*vc2.r + a2*vc3.r,
                        a0*vc1.g + a1*vc2.g + a2*vc3.g,
                        a0*vc1.b + a1*vc2.b + a2*vc3.b)
            ao_factor = 1.0
            # Perspective-correct UV, computed only when a map is active so the
            # no-map path keeps its original per-pixel cost.
            if has_uv_maps
                u = a0*uv1.x + a1*uv2.x + a2*uv3.x
                v = a0*uv1.y + a1*uv2.y + a2*uv3.y
                u2 = a0*uv2_1.x + a1*uv2_2.x + a2*uv2_3.x
                v2 = a0*uv2_1.y + a1*uv2_2.y + a2*uv2_3.y
                frag_alpha = _fragment_alpha(alpha_base, albedo_map, alpha_map, u, v, u2, v2)
                frag_alpha >= alpha_test || continue
                base_albedo_map = has_albedo &&
                                  _albedo_map_before_lighting(material)
                surface_color = vc
                if base_albedo_map
                    au, av = _map_uv(albedo_map, u, v, u2, v2)
                    surface_color = _modulate(
                        surface_color,
                        sample_texture_linear(albedo_map, au, av))
                end
                use_surface_color = UseVertexColors || base_albedo_map
                # normalMap perturbs the shading normal before lighting (same
                # helper as the flat path); the tangent frame uses the UV set
                # selected by the texture metadata.
                if normal_seed_valid
                    nu, nv = _map_uv(normal_map, u, v, u2, v2)
                    wn = _apply_normal_map_tangent_seed(wn, normal_map, nu, nv,
                                                        normal_tangent,
                                                        normal_handedness,
                                                        normal_scale)
                end
                if material isa MeshDepthMaterial
                    depth = clamp(
                        (fragment_view_depth - material.near) /
                        (material.far - material.near), 0.0, 1.0)
                    col = _depth_material_color(material, depth)
                elseif has_specular || has_glossiness
                    specular, shininess = _phong_mapped_terms(
                        material, specular_map, glossiness_map, u, v, u2, v2)
                    vd = _direction_between(wp, cam_pos)
                    col = use_surface_color ?
                          _shade_phong_mapped_vertex_color(
                              wn, vd, wp, material, lights, shadow_fn, specular,
                              Float64(shininess), surface_color) :
                          _shade_phong_mapped(wn, vd, wp, material, lights,
                                              shadow_fn, specular,
                                              Float64(shininess))
                elseif material isa MeshStandardMaterial &&
                       (has_roughness || has_metalness) && !has_physical_pbr
                    ru, rv = roughness_map === nothing ? (u, v) :
                             _map_uv(roughness_map, u, v, u2, v2)
                    mu, mv = metalness_map === nothing ? (u, v) :
                             _map_uv(metalness_map, u, v, u2, v2)
                    roughness = roughness_map === nothing ? material.roughness :
                                material.roughness * sample_texture(roughness_map, ru, rv).g
                    metalness = metalness_map === nothing ? material.metalness :
                               material.metalness * sample_texture(metalness_map, mu, mv).b
                    vd = _direction_between(wp, cam_pos)
                    col = use_surface_color ?
                          _shade_standard_mapped_vertex_color(wn, vd, wp, material,
                                                              lights, shadow_fn,
                                                              Float64(metalness),
                                                              Float64(roughness),
                                                              surface_color) :
                          _shade_standard_mapped(wn, vd, wp, material, lights, shadow_fn,
                                                 Float64(metalness), Float64(roughness))
                elseif material isa MeshPhysicalMaterial &&
                       (has_roughness || has_metalness || has_physical_pbr)
                    terms = _physical_mapped_terms(material, roughness_map,
                                                   metalness_map, u, v, u2, v2)
                    vd = _direction_between(wp, cam_pos)
                    col = use_surface_color ?
                          _shade_physical_mapped_vertex_color(
                              wn, vd, wp, material, lights, shadow_fn, terms,
                              surface_color) :
                          _shade_physical_mapped(wn, vd, wp, material, lights,
                                                 shadow_fn, terms)
                elseif has_roughness || has_metalness || has_physical_pbr
                    eff_mat = _apply_pbr_maps(material, roughness_map, metalness_map,
                                              u, v, u2, v2)
                    vd = _direction_between(wp, cam_pos)
                    col = use_surface_color ?
                          _shade_face_vertex_color(
                              wn, vd, wp, eff_mat, lights, surface_color;
                                                   shadow_fn=shadow_fn) :
                          shade_face(wn, vd, wp, eff_mat, lights;
                                     shadow_fn=shadow_fn)
                else
                    eff_mat = material
                    vd = _direction_between(wp, cam_pos)
                    col = use_surface_color ?
                          _shade_face_vertex_color(
                              wn, vd, wp, eff_mat, lights, surface_color;
                                                   shadow_fn=shadow_fn) :
                          shade_face(wn, vd, wp, eff_mat, lights;
                                     shadow_fn=shadow_fn)
                end
                # three.js keeps emission OUT of the diffuse map chain: remove the
                # base `emissive · intensity` added by `shade_face` before the
                # multiplicative maps below, and add the modulated form
                # `emissive · emissiveMap texel · intensity` back afterwards.
                em = _material_field(material, :emissive)
                emi = em === nothing ? 0.0 : _material_scalar(material, :emissive_intensity)
                if em !== nothing
                    col = Color3(col.r - em.r * emi, col.g - em.g * emi,
                                 col.b - em.b * emi)
                end
                if has_albedo && !base_albedo_map &&
                   !(material isa MeshDepthMaterial)
                    tu, tv = _map_uv(albedo_map, u, v, u2, v2)
                    col = col * sample_texture_linear(albedo_map, tu, tv)
                end
                if has_ao
                    tu, tv = _map_uv(ao_map, u, v, u2, v2; default_uv2=true)
                    aoi = _material_scalar(material, :ao_map_intensity)
                    ao = _ambient_occlusion_factor(ao_map, tu, tv, aoi)
                    ao_factor = ao
                    direct_col = Color3(0.0, 0.0, 0.0)
                    if material isa LitMaterial
                        direct_lights = _DirectLightView(lights)
                        direct_view = _direction_between(wp, cam_pos)
                        direct_col = if has_specular || has_glossiness
                            specular, shininess = _phong_mapped_terms(
                                material, specular_map, glossiness_map,
                                u, v, u2, v2)
                            use_surface_color ?
                                _shade_phong_mapped_vertex_color(
                                    wn, direct_view, wp, material,
                                    direct_lights, shadow_fn, specular,
                                    Float64(shininess), surface_color) :
                                _shade_phong_mapped(
                                    wn, direct_view, wp, material,
                                    direct_lights, shadow_fn, specular,
                                    Float64(shininess))
                        elseif material isa MeshStandardMaterial &&
                               (has_roughness || has_metalness) &&
                               !has_physical_pbr
                            metalness, roughness = _standard_mapped_terms(
                                material, roughness_map, metalness_map,
                                u, v, u2, v2)
                            use_surface_color ?
                                _shade_standard_mapped_vertex_color(
                                    wn, direct_view, wp, material,
                                    direct_lights, shadow_fn, metalness,
                                    roughness, surface_color) :
                                _shade_standard_mapped(
                                    wn, direct_view, wp, material,
                                    direct_lights, shadow_fn, metalness,
                                    roughness)
                        elseif material isa MeshPhysicalMaterial &&
                               (has_roughness || has_metalness ||
                                has_physical_pbr)
                            terms = _physical_mapped_terms(
                                material, roughness_map, metalness_map,
                                u, v, u2, v2)
                            use_surface_color ?
                                _shade_physical_mapped_vertex_color(
                                    wn, direct_view, wp, material,
                                    direct_lights, shadow_fn, terms,
                                    surface_color) :
                                _shade_physical_mapped(
                                    wn, direct_view, wp, material,
                                    direct_lights, shadow_fn, terms)
                        elseif has_roughness || has_metalness ||
                               has_physical_pbr
                            direct_material = _apply_pbr_maps(
                                material, roughness_map, metalness_map,
                                u, v, u2, v2)
                            use_surface_color ?
                                _shade_face_vertex_color(
                                    wn, direct_view, wp, direct_material,
                                    direct_lights, surface_color;
                                    shadow_fn=shadow_fn) :
                                shade_face(
                                    wn, direct_view, wp, direct_material,
                                    direct_lights; shadow_fn=shadow_fn)
                        elseif use_surface_color
                            _shade_face_vertex_color(
                                wn, direct_view, wp, material,
                                direct_lights, surface_color;
                                shadow_fn=shadow_fn)
                        else
                            shade_face(
                                wn, direct_view, wp, material,
                                direct_lights; shadow_fn=shadow_fn)
                        end
                        if em !== nothing
                            direct_col = Color3(
                                direct_col.r - em.r * emi,
                                direct_col.g - em.g * emi,
                                direct_col.b - em.b * emi)
                        end
                        if has_albedo && !base_albedo_map
                            au, av = _map_uv(
                                albedo_map, u, v, u2, v2)
                            direct_col = direct_col *
                                sample_texture_linear(albedo_map, au, av)
                        end
                    end
                    col = _apply_indirect_ao(col, direct_col, ao)
                end
                if has_lightmap
                    tu, tv = _map_uv(light_map, u, v, u2, v2; default_uv2=true)
                    lm = sample_texture(light_map, tu, tv)
                    lmi = _material_scalar(material, :light_map_intensity)
                    col = Color3(col.r * lm.r * lmi, col.g * lm.g * lmi, col.b * lm.b * lmi)
                end
                if em !== nothing
                    t = Color3(1.0, 1.0, 1.0)
                    if has_emissive
                        tu, tv = _map_uv(emissive_map, u, v, u2, v2)
                        t = sample_texture_linear(emissive_map, tu, tv)
                    end
                    col = col + Color3(em.r * t.r * emi, em.g * t.g * emi,
                                       em.b * t.b * emi)
                end
                if has_env
                    mapped_kind = 0
                    env_material = material
                    standard_metalness = 0.0
                    standard_roughness = 0.0
                    physical_terms = _PHYSICAL_MAPPED_TERMS_ZERO
                    if material isa MeshStandardMaterial &&
                       (has_roughness || has_metalness)
                        standard_metalness, standard_roughness =
                            _standard_mapped_terms(
                                material, roughness_map, metalness_map,
                                u, v, u2, v2)
                        mapped_kind = 2
                    elseif material isa MeshPhysicalMaterial &&
                           (has_roughness || has_metalness ||
                            has_physical_pbr)
                        physical_terms = _physical_mapped_terms(
                            material, roughness_map, metalness_map,
                            u, v, u2, v2)
                        mapped_kind = 3
                    elseif has_roughness || has_metalness ||
                           has_physical_pbr
                        env_material = _apply_pbr_maps(
                            material, roughness_map, metalness_map,
                            u, v, u2, v2)
                    end
                    col = col + _mapped_environment_contribution(
                        env_map, wn, _direction_between(wp, cam_pos),
                        material, env_material, mapped_kind,
                        use_surface_color, surface_color,
                        standard_metalness, standard_roughness,
                        physical_terms) * ao_factor
                end
            else
                vd = _direction_between(wp, cam_pos)
                shade_mat = UseVertexColors ? _with_vertex_color(material, vc) : material
                col = shade_face(wn, vd, wp, shade_mat, lights; shadow_fn=shadow_fn)
            end
            col = clamp_color(col)
            if blend
                # Transparent smooth pass: source-over after half-open fill
                # ownership has assigned this sample to exactly one shared edge.
                ia = 1.0 - frag_alpha
                rt.color[py, px, 1] = col.r * frag_alpha + rt.color[py, px, 1] * ia
                rt.color[py, px, 2] = col.g * frag_alpha + rt.color[py, px, 2] * ia
                rt.color[py, px, 3] = col.b * frag_alpha + rt.color[py, px, 3] * ia
                depth_write && (rt.depth[py, px] = z)
            else
                depth_write && (rt.depth[py, px] = z)
                rt.color[py, px, 1] = col.r
                rt.color[py, px, 2] = col.g
                rt.color[py, px, 3] = col.b
            end
        end
    end
    return nothing
end

@inline function _rasterize_tri_smooth_nomaps!(rt::RenderTarget,
        s1x, s1y, z1, iw1, view_depth1, wp1::Vec3, wn1::Vec3, vc1::Color3,
        s2x, s2y, z2, iw2, view_depth2, wp2::Vec3, wn2::Vec3, vc2::Color3,
        s3x, s3y, z3, iw3, view_depth3, wp3::Vec3, wn3::Vec3, vc3::Color3,
        material::M, lights, cam_pos::Vec3, shadow_fn,
        clipping_planes;
        xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
        depth_test::Bool=true, depth_write::Bool=true,
        stamp=nothing, stamp_id::Int=0, use_vertex_colors::Bool=true,
        blend::Bool=false, normal_sign::Float64=1.0) where {M<:AbstractMaterial}
    if use_vertex_colors
        return _rasterize_tri_smooth_nomaps_impl!(Val(true), rt,
            s1x, s1y, z1, iw1, view_depth1, wp1, wn1, vc1,
            s2x, s2y, z2, iw2, view_depth2, wp2, wn2, vc2,
            s3x, s3y, z3, iw3, view_depth3, wp3, wn3, vc3,
            material, lights, cam_pos, shadow_fn, clipping_planes;
            xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
            depth_test=depth_test, depth_write=depth_write,
            stamp=stamp, stamp_id=stamp_id, blend=blend,
            normal_sign=normal_sign)
    end
    return _rasterize_tri_smooth_nomaps_impl!(Val(false), rt,
        s1x, s1y, z1, iw1, view_depth1, wp1, wn1, vc1,
        s2x, s2y, z2, iw2, view_depth2, wp2, wn2, vc2,
        s3x, s3y, z3, iw3, view_depth3, wp3, wn3, vc3,
        material, lights, cam_pos, shadow_fn, clipping_planes;
        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
        depth_test=depth_test, depth_write=depth_write,
        stamp=stamp, stamp_id=stamp_id, blend=blend,
        normal_sign=normal_sign)
end

@inline function _rasterize_tri_smooth_nomaps_impl!(::Val{UseVertexColors}, rt::RenderTarget,
        s1x, s1y, z1, iw1, view_depth1, wp1::Vec3, wn1::Vec3, vc1::Color3,
        s2x, s2y, z2, iw2, view_depth2, wp2::Vec3, wn2::Vec3, vc2::Color3,
        s3x, s3y, z3, iw3, view_depth3, wp3::Vec3, wn3::Vec3, vc3::Color3,
        material::M, lights, cam_pos::Vec3, shadow_fn,
        clipping_planes;
        xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
        depth_test::Bool=true, depth_write::Bool=true,
        stamp=nothing, stamp_id::Int=0,
        blend::Bool=false,
        normal_sign::Float64=1.0) where {M<:AbstractMaterial, UseVertexColors}
    W, H = rt.width, rt.height
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-10 && return nothing
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    fW, fH = Float64(W), Float64(H)
    inv_area = 1.0 / area
    positive_area = area > 0
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int, clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int, clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    has_clip = !isempty(clipping_planes)
    alpha_test = material_alpha_test(material)
    alpha_base = Float64(material_opacity(material))
    @inbounds for px in min_x:max_x
        for py in min_y:max_y
            cx = px - 0.5
            cy = py - 0.5
            b0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            b1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            b2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if blend
                _half_open_triangle_contains(
                    b0, b1, b2, s1x, s1y, s2x, s2y, s3x, s3y,
                    positive_area) || continue
            else
                (b0 >= 0 && b1 >= 0 && b2 >= 0) || continue
            end
            z = b0 * z1 + b1 * z2 + b2 * z3
            _inside_far_clip(z) || continue
            (!depth_test || z < rt.depth[py, px]) || continue
            alpha_base < alpha_test && continue
            iw = b0 * iw1 + b1 * iw2 + b2 * iw3
            a0 = b0 * iw1 / iw; a1 = b1 * iw2 / iw; a2 = b2 * iw3 / iw
            fragment_view_depth = a0 * view_depth1 +
                                  a1 * view_depth2 +
                                  a2 * view_depth3
            wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                      a0*wp1.y + a1*wp2.y + a2*wp3.y,
                      a0*wp1.z + a1*wp2.z + a2*wp3.z)
            has_clip && (_clip_keep(clipping_planes, wp) || continue)
            wn = normalize(Vec3(a0*wn1.x + a1*wn2.x + a2*wn3.x,
                                a0*wn1.y + a1*wn2.y + a2*wn3.y,
                                a0*wn1.z + a1*wn2.z + a2*wn3.z)) *
                 normal_sign
            vd = _direction_between(wp, cam_pos)
            if material isa MeshDepthMaterial
                depth = clamp(
                    (fragment_view_depth - material.near) /
                    (material.far - material.near), 0.0, 1.0)
                col = _depth_material_color(material, depth)
            elseif UseVertexColors
                vc = Color3(a0*vc1.r + a1*vc2.r + a2*vc3.r,
                            a0*vc1.g + a1*vc2.g + a2*vc3.g,
                            a0*vc1.b + a1*vc2.b + a2*vc3.b)
                col = _shade_face_vertex_color(wn, vd, wp, material, lights, vc;
                                               shadow_fn=shadow_fn)
            else
                col = shade_face(wn, vd, wp, material, lights; shadow_fn=shadow_fn)
            end
            col = clamp_color(col)
            if blend
                ia = 1.0 - alpha_base
                rt.color[py, px, 1] = col.r * alpha_base + rt.color[py, px, 1] * ia
                rt.color[py, px, 2] = col.g * alpha_base + rt.color[py, px, 2] * ia
                rt.color[py, px, 3] = col.b * alpha_base + rt.color[py, px, 3] * ia
                depth_write && (rt.depth[py, px] = z)
            else
                depth_write && (rt.depth[py, px] = z)
                rt.color[py, px, 1] = col.r
                rt.color[py, px, 2] = col.g
                rt.color[py, px, 3] = col.b
            end
        end
    end
    return nothing
end

function _render_smooth_geometry!(rt::RenderTarget, geo::BufferGeometry,
                                  mat::M, world_mat::Mat4, lights,
                                  proj::Mat4, view::Mat4, near,
                                  cam_pos::Vec3, mesh_shadow_fn,
                                  tri::Vector{ShadeVtx},
                                  clipped::Vector{ShadeVtx},
                                  sx::Vector{Float64}, sy::Vector{Float64},
                                  sz::Vector{Float64}, iw::Vector{Float64},
                                  clipping_planes,
                                  xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                  log_depth::Bool, inv_log_far::Float64,
                                  ortho_dir, stamp,
                                  stamp_id::Int) where {M<:AbstractMaterial}
    _validate_material_parameters(mat)
    _validate_depth_material(mat)
    W, H = rt.width, rt.height
    modelview = view * world_mat
    normal_mat = mat4_transpose(mat4_inverse(world_mat))
    mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                     material_clipping_planes(mat))
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    # Back-face culling, matching the flat path (`_rasterize_geo_flat!`): the
    # per-pixel path must agree with the per-face path on which faces survive.
    side = material_side(mat)
    has_normals = length(geo.normals) >= geo.n_vertices * 3
    # Per-pixel material maps, applied only when the
    # geometry carries UVs and the material exposes the map. Matches the flat
    # path's material-map handling so textured surfaces agree.
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    albedo_map = has_uvs ? _material_field(mat, :map) : nothing
    normal_map = has_uvs ? _material_field(mat, :normal_map) : nothing
    normal_scale = _material_scalar(mat, :normal_scale, 1.0)
    roughness_map = has_uvs ? _material_field(mat, :roughness_map) : nothing
    metalness_map = has_uvs ? _material_field(mat, :metalness_map) : nothing
    specular_map = has_uvs ? _material_field(mat, :specular_map) : nothing
    glossiness_map = has_uvs ? _material_field(mat, :glossiness_map) : nothing
    physical_pbr_map = has_uvs ? _physical_pbr_map(mat) : nothing
    alpha_map = has_uvs ? _material_field(mat, :alpha_map) : nothing
    ao_map = has_uvs ? _material_field(mat, :ao_map) : nothing
    emissive_map = has_uvs ? _material_field(mat, :emissive_map) : nothing
    light_map = has_uvs ? _material_field(mat, :light_map) : nothing
    has_uv_maps = albedo_map !== nothing || alpha_map !== nothing ||
                  normal_map !== nothing || roughness_map !== nothing ||
                  metalness_map !== nothing || specular_map !== nothing ||
                  glossiness_map !== nothing || physical_pbr_map !== nothing ||
                  ao_map !== nothing || emissive_map !== nothing ||
                  light_map !== nothing
    has_env = _envmap_field(mat) !== nothing
    has_mapped_inputs = has_uv_maps || has_env
    uv2_attr = _uv2_attribute(geo)
    color_attr = (_wants_vertex_colors(mat) && has_attribute(geo, :color)) ?
                 get_attribute(geo, :color) : nothing
    use_vertex_colors = color_attr !== nothing && color_attr.item_size >= 3 &&
                        length(color_attr.data) >= geo.n_vertices * color_attr.item_size
    if !has_mapped_inputs && !use_vertex_colors
        return _render_smooth_mesh_loop!(rt, geo, mat, lights, proj, near, cam_pos,
                                         mesh_shadow_fn, tri, clipped, sx, sy, sz, iw,
                                         xlo, xhi, ylo, yhi, log_depth, inv_log_far,
                                         ortho_dir, stamp, stamp_id, W, H, world_mat,
                                         modelview, normal_mat, mesh_clipping_planes,
                                         depth_test, depth_write, side, has_normals,
                                         has_uvs, nothing, nothing, nothing, nothing,
                                         nothing, nothing, nothing, nothing, nothing,
                                         nothing, nothing, normal_scale, false,
                                         nothing, nothing, false)
    end
    if has_uv_maps && albedo_map isa Texture && alpha_map === nothing &&
       normal_map === nothing && roughness_map === nothing &&
       metalness_map === nothing && specular_map === nothing &&
       glossiness_map === nothing && physical_pbr_map === nothing &&
       ao_map === nothing && emissive_map === nothing && light_map === nothing &&
       !use_vertex_colors
        return _render_smooth_mesh_loop!(rt, geo, mat, lights, proj, near, cam_pos,
                                         mesh_shadow_fn, tri, clipped, sx, sy, sz, iw,
                                         xlo, xhi, ylo, yhi, log_depth, inv_log_far,
                                         ortho_dir, stamp, stamp_id, W, H, world_mat,
                                         modelview, normal_mat, mesh_clipping_planes,
                                         depth_test, depth_write, side, has_normals,
                                         has_uvs, albedo_map, nothing, nothing,
                                         nothing, nothing, nothing, nothing, nothing,
                                         nothing, nothing, nothing, normal_scale,
                                         true, uv2_attr, nothing, false)
    end
    if has_uv_maps && albedo_map === nothing && alpha_map === nothing &&
       normal_map isa Texture && roughness_map === nothing &&
       metalness_map === nothing && specular_map === nothing &&
       glossiness_map === nothing && physical_pbr_map === nothing &&
       ao_map === nothing && emissive_map === nothing && light_map === nothing &&
       !use_vertex_colors
        return _render_smooth_mesh_loop!(rt, geo, mat, lights, proj, near, cam_pos,
                                         mesh_shadow_fn, tri, clipped, sx, sy, sz, iw,
                                         xlo, xhi, ylo, yhi, log_depth, inv_log_far,
                                         ortho_dir, stamp, stamp_id, W, H, world_mat,
                                         modelview, normal_mat, mesh_clipping_planes,
                                         depth_test, depth_write, side, has_normals,
                                         has_uvs, nothing, nothing, normal_map,
                                         nothing, nothing, nothing, nothing, nothing,
                                         nothing, nothing, nothing, normal_scale,
                                         true, uv2_attr, nothing, false)
    end
    if mat isa MeshStandardMaterial && has_uv_maps &&
       albedo_map === nothing && alpha_map === nothing && normal_map === nothing &&
       roughness_map isa Texture && metalness_map isa Texture &&
       specular_map === nothing && glossiness_map === nothing &&
       physical_pbr_map === nothing && ao_map isa Texture &&
       emissive_map === nothing && light_map === nothing && !use_vertex_colors
        return _render_smooth_mesh_loop!(rt, geo, mat, lights, proj, near, cam_pos,
                                         mesh_shadow_fn, tri, clipped, sx, sy, sz, iw,
                                         xlo, xhi, ylo, yhi, log_depth, inv_log_far,
                                         ortho_dir, stamp, stamp_id, W, H, world_mat,
                                         modelview, normal_mat, mesh_clipping_planes,
                                         depth_test, depth_write, side, has_normals,
                                         has_uvs, nothing, nothing, nothing,
                                         roughness_map, metalness_map, nothing,
                                         nothing, nothing, ao_map, nothing, nothing,
                                         normal_scale, true, uv2_attr, nothing, false)
    end
    return _render_smooth_mesh_loop!(rt, geo, mat, lights, proj, near, cam_pos,
                                     mesh_shadow_fn, tri, clipped, sx, sy, sz, iw,
                                     xlo, xhi, ylo, yhi, log_depth, inv_log_far,
                                     ortho_dir, stamp, stamp_id, W, H, world_mat,
                                     modelview, normal_mat, mesh_clipping_planes,
                                     depth_test, depth_write, side, has_normals,
                                     has_uvs, albedo_map, alpha_map, normal_map,
                                     roughness_map, metalness_map, specular_map,
                                     glossiness_map, physical_pbr_map, ao_map,
                                     emissive_map, light_map, normal_scale,
                                     has_mapped_inputs, uv2_attr, color_attr,
                                     use_vertex_colors)
end

function _render_smooth_mesh!(rt::RenderTarget, mesh::Mesh,
                              geo::BufferGeometry, mat::M,
                              world_mat::Mat4, lights,
                              proj::Mat4, view::Mat4, near,
                              cam_pos::Vec3, shadow_fn,
                              tri::Vector{ShadeVtx},
                              clipped::Vector{ShadeVtx},
                              sx::Vector{Float64}, sy::Vector{Float64},
                              sz::Vector{Float64}, iw::Vector{Float64},
                              clipping_planes,
                              xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                              log_depth::Bool, inv_log_far::Float64,
                              ortho_dir, stamp,
                              stamp_id::Int) where {M<:AbstractMaterial}
    mesh_shadow_fn = object_receives_shadow(mesh) ? shadow_fn : nothing
    return _render_smooth_geometry!(
        rt, geo, mat, world_mat, lights, proj, view, near, cam_pos,
        mesh_shadow_fn, tri, clipped, sx, sy, sz, iw,
        clipping_planes, xlo, xhi, ylo, yhi, log_depth,
        inv_log_far, ortho_dir, stamp, stamp_id)
end

function _render_smooth_mesh_loop!(rt::RenderTarget, geo::BufferGeometry,
                                   mat::M, lights, proj::Mat4, near,
                                   cam_pos::Vec3, mesh_shadow_fn,
                                   tri::Vector{ShadeVtx},
                                   clipped::Vector{ShadeVtx},
                                   sx::Vector{Float64}, sy::Vector{Float64},
                                   sz::Vector{Float64}, iw::Vector{Float64},
                                   xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                   log_depth::Bool, inv_log_far::Float64,
                                   ortho_dir, stamp, stamp_id::Int, W::Int, H::Int,
                                   world_mat::Mat4, modelview::Mat4,
                                   normal_mat::Mat4, mesh_clipping_planes,
                                   depth_test::Bool, depth_write::Bool,
                                   side::Symbol, has_normals::Bool,
                                   has_uvs::Bool, albedo_map, alpha_map,
                                   normal_map, roughness_map, metalness_map,
                                   specular_map, glossiness_map, physical_pbr_map,
                                   ao_map, emissive_map, light_map,
                                   normal_scale::Float64, has_uv_maps::Bool,
                                   uv2_attr, color_attr,
                                   use_vertex_colors::Bool) where {M<:AbstractMaterial}
    blend = material_transparent(mat)
    for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        front_facing = true
        if side !== :double
            w1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
            w2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
            w3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
            wc = _mean3_vec3(w1, w2, w3)
            front_facing = _face_front_facing(
                w1, w2, w3, wc, cam_pos, ortho_dir)
            (side === :front ? !front_facing : front_facing) && continue
        end
        # Geometry without authored normals: fall back to the local-space
        # winding normal once per face (matching `_flat_face_normal`'s
        # fallback in the flat path) instead of indexing the empty buffer.
        fallback_n = _ZERO_V3
        if !has_normals
            p1 = get_vertex(geo, i1); p2 = get_vertex(geo, i2); p3 = get_vertex(geo, i3)
            gn = cross(p2 - p1, p3 - p1)
            gl = norm(gn)
            fallback_n = gl > 1e-12 ? gn / gl : Vec3(0.0, 0.0, 1.0)
        end
        @inbounds begin
            tri[1] = _shade_vertex(geo, i1, world_mat, normal_mat, modelview,
                                   has_normals, fallback_n, has_uvs, uv2_attr,
                                   use_vertex_colors, color_attr)
            tri[2] = _shade_vertex(geo, i2, world_mat, normal_mat, modelview,
                                   has_normals, fallback_n, has_uvs, uv2_attr,
                                   use_vertex_colors, color_attr)
            tri[3] = _shade_vertex(geo, i3, world_mat, normal_mat, modelview,
                                   has_normals, fallback_n, has_uvs, uv2_attr,
                                   use_vertex_colors, color_attr)
        end
        if side === :double
            wc = _mean3_vec3(tri[1].wp, tri[2].wp, tri[3].wp)
            front_facing = _face_front_facing(
                tri[1].wp, tri[2].wp, tri[3].wp,
                wc, cam_pos, ortho_dir)
        end
        normal_sign = front_facing ? 1.0 : -1.0
        m = _clip_near_attr!(clipped, tri, 3, near)
        m < 3 && continue
        @inbounds for k in 1:m
            cv = mat4_transform_vec4(proj, clipped[k].vp)
            invw = 1.0 / cv.w
            sx[k] = (cv.x * invw + 1) * 0.5 * W
            sy[k] = (1 - cv.y * invw) * 0.5 * H
            # Depth stored in the z-buffer: NDC z by default, or the
            # logarithmic encoding of the clip-space w (= view distance) when
            # `log_depth` is set. Both are monotone in distance so the z-test
            # is unchanged; the encoded value is interpolated as a varying.
            sz[k] = log_depth ? _encode_log_depth(cv.w, inv_log_far) : cv.z * invw
            iw[k] = invw
        end
        @inbounds for k in 2:(m - 1)
            if has_uv_maps
                _rasterize_tri_smooth!(rt,
                    sx[1], sy[1], sz[1], iw[1], -clipped[1].vp.z, clipped[1].wp, clipped[1].wn, clipped[1].uv, clipped[1].uv2, clipped[1].vc,
                    sx[k], sy[k], sz[k], iw[k], -clipped[k].vp.z, clipped[k].wp, clipped[k].wn, clipped[k].uv, clipped[k].uv2, clipped[k].vc,
                    sx[k+1], sy[k+1], sz[k+1], iw[k+1], -clipped[k+1].vp.z, clipped[k+1].wp, clipped[k+1].wn, clipped[k+1].uv, clipped[k+1].uv2, clipped[k+1].vc,
                    mat, lights, cam_pos, mesh_shadow_fn, albedo_map, alpha_map,
                    normal_map, roughness_map, metalness_map, specular_map,
                    glossiness_map, physical_pbr_map,
                    ao_map, emissive_map, light_map, normal_scale, mesh_clipping_planes;
                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                    depth_test=depth_test, depth_write=depth_write,
                    stamp=nothing, stamp_id=0,
                    use_vertex_colors=use_vertex_colors, blend=blend,
                    normal_sign=normal_sign)
            else
                _rasterize_tri_smooth_nomaps!(rt,
                    sx[1], sy[1], sz[1], iw[1], -clipped[1].vp.z, clipped[1].wp, clipped[1].wn, clipped[1].vc,
                    sx[k], sy[k], sz[k], iw[k], -clipped[k].vp.z, clipped[k].wp, clipped[k].wn, clipped[k].vc,
                    sx[k+1], sy[k+1], sz[k+1], iw[k+1], -clipped[k+1].vp.z, clipped[k+1].wp, clipped[k+1].wn, clipped[k+1].vc,
                    mat, lights, cam_pos, mesh_shadow_fn, mesh_clipping_planes;
                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                    depth_test=depth_test, depth_write=depth_write,
                    stamp=nothing, stamp_id=0,
                    use_vertex_colors=use_vertex_colors, blend=blend,
                    normal_sign=normal_sign)
            end
        end
    end
    return nothing
end

@inline function _render_smooth_mesh_from_mesh!(rt::RenderTarget, mesh::Mesh,
                                                world_mat::Mat4,
                                                lights, proj::Mat4, view::Mat4, near,
                                                cam_pos::Vec3, shadow_fn,
                                                tri::Vector{ShadeVtx},
                                                clipped::Vector{ShadeVtx},
                                                sx::Vector{Float64},
                                                sy::Vector{Float64},
                                                sz::Vector{Float64},
                                                iw::Vector{Float64},
                                                clipping_planes,
                                                xlo::Int, xhi::Int,
                                                ylo::Int, yhi::Int,
                                                log_depth::Bool,
                                                inv_log_far::Float64,
                                                ortho_dir, stamp, stamp_id::Int)
    geo = _mesh_geometry(mesh)
    mat = _mesh_material(mesh)
    if mat isa MeshBasicMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshBasicMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshLambertMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshLambertMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshPhongMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshPhongMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshStandardMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshStandardMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshPhysicalMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshPhysicalMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshToonMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshToonMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshNormalMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshNormalMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshMatcapMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshMatcapMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa MeshDepthMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::MeshDepthMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa ShaderMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::ShaderMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa SpriteMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::SpriteMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa LineBasicMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::LineBasicMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa LineDashedMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::LineDashedMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    elseif mat isa PointsMaterial
        _render_smooth_mesh!(rt, mesh, geo, mat::PointsMaterial, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    else
        _render_smooth_mesh!(rt, mesh, geo, mat, world_mat, lights, proj, view, near, cam_pos, shadow_fn, tri, clipped, sx, sy, sz, iw, clipping_planes, xlo, xhi, ylo, yhi, log_depth, inv_log_far, ortho_dir, stamp, stamp_id)
    end
    return nothing
end

function _render_smooth!(rt::RenderTarget, meshes, lights, proj, view, near, cam_pos, shadow_fn=nothing;
                         clipping_planes=_NO_PLANES,
                         xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
                         log_depth::Bool=false, inv_log_far::Float64=1.0, ortho_dir=nothing,
                         stamp=nothing, stamp_id::Int=0,
                         smooth_tri=nothing, smooth_clipped=nothing,
                         smooth_sx=nothing, smooth_sy=nothing,
                         smooth_sz=nothing, smooth_iw=nothing,
                         worlds=nothing)
    tri = smooth_tri === nothing ? Vector{ShadeVtx}(undef, 3) :
          smooth_tri::Vector{ShadeVtx}
    clipped = if smooth_clipped === nothing
        buf = ShadeVtx[]
        sizehint!(buf, 6)
        buf
    else
        buf = smooth_clipped::Vector{ShadeVtx}
        empty!(buf)
        buf
    end
    sx = smooth_sx === nothing ? Vector{Float64}(undef, 8) :
         smooth_sx::Vector{Float64}
    sy = smooth_sy === nothing ? Vector{Float64}(undef, 8) :
         smooth_sy::Vector{Float64}
    sz = smooth_sz === nothing ? Vector{Float64}(undef, 8) :
         smooth_sz::Vector{Float64}
    iw = smooth_iw === nothing ? Vector{Float64}(undef, 8) :
         smooth_iw::Vector{Float64}
    for i in eachindex(meshes)
        mesh = meshes[i]
        !is_visible(mesh) && continue
        world_mat = worlds === nothing ? compute_world_matrix(mesh) : worlds[i]
        _render_smooth_mesh_from_mesh!(rt, mesh, world_mat, lights, proj, view, near,
                                       cam_pos, shadow_fn, tri, clipped,
                                       sx, sy, sz, iw, clipping_planes,
                                       xlo, xhi, ylo, yhi, log_depth,
                                       inv_log_far, ortho_dir, stamp, stamp_id)
    end
    return rt
end

"""
    render!(rt, scene, camera; shading=:flat)

Render a scene with a camera into a RenderTarget using CPU rasterization.

Triangles are transformed to view space, clipped against the camera near plane,
then projected and rasterized with a z-buffer; fragments beyond a finite far
plane are discarded. Geometry straddling either depth boundary keeps its visible
portion. Scratch buffers are reused across faces to keep per-frame allocation
bounded.

`shading=:flat` (default) evaluates one colour per face (fast). `shading=:smooth`
interpolates per-vertex world position and normal perspective-correctly and
shades each pixel, matching three.js smooth shading.

`frustum_cull=true` (default) skips any mesh whose world-space bounding sphere
lies entirely outside the camera view-projection frustum (three.js
`frustumCulled`). It never changes the image for in-view meshes; set it `false`
to draw every mesh unconditionally.

`clipping_planes` (default empty) is a set of world-space [`Plane`](@ref)s. Each
fragment on the negative side of any plane is discarded (three.js
`renderer.clippingPlanes`), applied per pixel in both the flat and smooth paths.

`scissor_test=false` and `scissor=nothing` mirror the WebGLRenderer scissor state
(`setScissorTest`, `setScissor`). When `scissor_test` is set and a rectangle
`scissor = (x, y, w, h)` is supplied, both the background clear and every
rasterized fragment are clamped to that pixel box, leaving the rest of the target
untouched. The rectangle uses the same top-left origin as the render target's
pixel array: `x` is the 0-based left column, `y` is the 0-based top row, and
`w`/`h` are the box width/height in pixels (this differs from WebGL's bottom-left
origin and is the natural convention for this row-major top-left image buffer).
The box is clamped to the buffer, so partially off-screen rectangles are safe.

`sort_objects=true` mirrors `WebGLRenderer.sortObjects`: opaque meshes are drawn
front-to-back by view-space depth to reduce overdraw work. Because the z-buffer
makes opaque rendering order-independent, this changes only the draw order, not
the final pixels. Transparent meshes keep their back-to-front order, which is
required for correct alpha blending.

`logarithmic_depth=false` mirrors `WebGLRenderer.logarithmicDepthBuffer`. When
enabled, the z-buffer stores `log2(max(1e-6, w + 1)) / log2(far + 1)` (with `w`
the clip-space w, i.e. the positive view distance) instead of NDC z. An infinite
far plane uses `floatmax(Float64)` as the finite normalization limit. The encoding
is monotone in distance, so the "nearer fragment wins" depth test is unchanged,
while precision is spread logarithmically to stay usable across very large
far/near ratios where linear NDC z collapses onto the far plane. The encoding is
interpolated as a vertex varying across each triangle, matching three.js without
`EXT_frag_depth`. It is applied to the opaque and transparent mesh passes; sprite,
line, and point primitives continue to write NDC z, so enable it for scenes whose
occlusion is dominated by mesh geometry.

Pass `cache=RenderCache()` when rendering repeated frames with the same target
shape to reuse traversal lists, pass buckets, triangle scratch buffers, and the
transparent-pass stamp buffer. Leaving `cache=nothing` preserves the historical
allocation behavior.
"""
function _render_instanced_mesh_flat!(rt::RenderTarget, geo, mat,
                                      instance_colors::Vector{Color3{Float64}},
                                      instance_matrices::Vector{Mat4{Float64}},
                                      base::Mat4, lights, proj::Mat4, view::Mat4,
                                      near, cam_pos::Vec3, tri, clipped, sx, sy, sz;
                                      shadow_fn=nothing,
                                      clipping_planes::AbstractVector{<:Plane}=_NO_PLANES,
                                      colorbuf=nothing,
                                      xlo::Int=1, xhi::Int=rt.width,
                                      ylo::Int=1, yhi::Int=rt.height,
                                      log_depth::Bool=false,
                                      inv_log_far=1.0,
                                      ortho_dir=nothing,
                                      stamp_cache=nothing,
                                      instance_materials=nothing)
    wireframe = material_wireframe(mat)
    mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                     material_clipping_planes(mat))
    use_pooled_flat_path = colorbuf isa Vector{Color3{Float64}} &&
                           !wireframe && shadow_fn === nothing &&
                           isempty(mesh_clipping_planes) && !log_depth &&
                           !material_transparent(mat) &&
                           !_render_pooled_uses_fragment_alpha(geo, mat)
    flat_attr_tri = stamp_cache === nothing ? nothing : stamp_cache.smooth_tri
    flat_attr_clipped = stamp_cache === nothing ? nothing : stamp_cache.smooth_clipped
    flat_iw = stamp_cache === nothing ? nothing : stamp_cache.smooth_iw
    @inbounds for instance_index in eachindex(instance_matrices)
        world = base * instance_matrices[instance_index]
        instance_material = instance_materials === nothing ?
                            _with_vertex_color(mat, instance_colors[instance_index]) :
                            instance_materials[instance_index]
        if wireframe
            _render_wireframe_mesh_cached!(rt, geo, instance_material, world, proj, view, near,
                                           xlo, xhi, ylo, yhi, stamp_cache)
        elseif use_pooled_flat_path
            _rasterize_geo_flat_pooled!(rt, geo, world, instance_material,
                                        lights, proj, view, near, cam_pos,
                                        tri, clipped, sx, sy, sz, colorbuf;
                                        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                        ortho_dir=ortho_dir,
                                        flat_attr_tri=flat_attr_tri,
                                        flat_attr_clipped=flat_attr_clipped,
                                        flat_iw=flat_iw)
        else
            _rasterize_geo_flat!(rt, geo, world, instance_material,
                                 lights, proj, view, near, cam_pos, tri, clipped, sx, sy, sz;
                                 shadow_fn=shadow_fn, clipping_planes=mesh_clipping_planes,
                                 colorbuf=colorbuf,
                                 xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                 log_depth=log_depth, inv_log_far=inv_log_far,
                                 ortho_dir=ortho_dir,
                                 flat_attr_tri=flat_attr_tri,
                                 flat_attr_clipped=flat_attr_clipped,
                                 flat_iw=flat_iw)
        end
    end
    return nothing
end

function render!(rt::RenderTarget, scene::Scene, camera::AbstractCamera;
                 shading::Symbol=:flat, shadows::Bool=false, shadow_resolution::Int=512,
                 frustum_cull::Bool=true, clipping_planes::AbstractVector{<:Plane}=_NO_PLANES,
                 scissor::Union{Nothing,NTuple{4,Int}}=nothing, scissor_test::Bool=false,
                 sort_objects::Bool=true, logarithmic_depth::Bool=false,
                 cache=nothing)
    proj = projection_matrix(camera)
    camera_position, camera_target, camera_up = _camera_world_pose(camera)
    view = mat4_look_at(camera_position, camera_target, camera_up)
    near = _camera_near(camera)
    far = _camera_far(camera)
    W, H = rt.width, rt.height

    (shading === :flat || shading === :smooth) ||
        throw(ArgumentError("shading must be :flat or :smooth, got :$shading"))

    # Scissor rectangle → inclusive 1-based pixel bounds, clamped to the buffer.
    # Active only when scissor testing is on and a rectangle is supplied; otherwise
    # the full target is used (xlo=ylo=1, xhi=W, yhi=H).
    use_scissor = scissor_test && scissor !== nothing
    xlo = 1; xhi = W; ylo = 1; yhi = H
    if use_scissor
        xlo, xhi, ylo, yhi = _scissor_bounds(rt, scissor)
    end

    # Clear: full frame normally, or only the scissor box under scissor testing.
    if use_scissor
        clear_rect!(rt, scene.background, xlo, xhi, ylo, yhi)
    else
        clear!(rt, scene.background)
    end

    # Logarithmic depth uses the clip-space w as the view distance, which only
    # carries distance under a perspective projection. Orthographic clip w is
    # constant, so the encoding would flatten all depths; fall back to NDC z there.
    log_depth = logarithmic_depth && (camera isa PerspectiveCamera)
    # Precompute the normalization once per frame for logarithmic depth.
    inv_log_far = log_depth ? _inverse_log_depth_far(far) : 1.0

    # Orthographic cameras project along a constant direction, so back-face
    # culling must test against that direction (the camera's backward axis)
    # rather than the eye-point vector `cam_pos - wc`, which is exact only for
    # perspective projection. `nothing` selects the perspective test.
    ortho_dir = camera isa OrthographicCamera ?
        _direction_between(camera_target, camera_position) : nothing

    if cache === nothing
        meshes = Mesh[]
        mesh_worlds = Mat4{Float64}[]
        instanced = InstancedMesh[]
        instanced_worlds = Mat4{Float64}[]
        primitive_flags = _RenderPrimitiveFlags()
        _collect_render_drawables_worlds_into!(meshes, mesh_worlds, instanced,
                                               instanced_worlds, scene,
                                               primitive_flags)
        primitives = AbstractObject3D[]
        primitive_worlds = Mat4{Float64}[]
        _collect_render_primitives_worlds_into!(
            primitives, primitive_worlds, scene)
        lights = collect_lights(scene)
    else
        primitive_flags = cache.primitive_flags
        meshes = _collect_render_drawables_worlds_into!(cache.meshes, cache.mesh_worlds,
                                                        cache.instanced,
                                                        cache.instanced_worlds,
                                                        scene, primitive_flags)
        mesh_worlds = cache.mesh_worlds
        instanced = cache.instanced
        instanced_worlds = cache.instanced_worlds
        primitives = cache.primitives
        primitive_worlds = cache.primitive_worlds
        _collect_render_primitives_worlds_into!(
            primitives, primitive_worlds, scene)
        lights = _collect_lights_into!(cache.lights, scene)
    end
    if cache === nothing
        _append_skinned_render_meshes_worlds!(meshes, mesh_worlds, scene)
    else
        _append_skinned_render_meshes_worlds!(meshes, mesh_worlds, scene,
                                              cache.skinned, cache.skinned_meshes,
                                              cache.skinned_matrices,
                                              cache.morph_positions)
    end
    # Validate every triangle drawable before frustum, shadow, shader, or
    # rasterization code can index its buffers. The checks are allocation-free.
    for mesh in meshes
        _validate_triangle_geometry_indices(_mesh_geometry(mesh), "render!")
    end
    for im in instanced
        _validate_instanced_mesh(im, "render!")
        _instanced_triangle_drawable(im) || continue
        _validate_triangle_geometry_indices(_instanced_geometry(im), "render!")
    end
    shadow_fn = if shadows
        if cache === nothing
            _build_shadow_query_from_drawables!(IdDict{AbstractLight,ShadowMap}(), nothing,
                lights, meshes, instanced; resolution=shadow_resolution,
                clipping_planes=clipping_planes)
        else
            _build_shadow_query_from_drawables!(cache.shadow_maps, cache.shadow_depths,
                lights, meshes, instanced; resolution=shadow_resolution,
                clipping_planes=clipping_planes)
        end
    else
        nothing
    end

    # View-projection frustum for culling whole meshes that fall offscreen.
    frustum = frustum_cull ? frustum_from_matrix(proj * view) : nothing
    bounds_cache = if frustum === nothing
        nothing
    elseif cache === nothing
        (BufferGeometry[], BoundingSphere{Float64}[])
    else
        empty!(cache.bound_geometries)
        empty!(cache.bounds)
        (cache.bound_geometries, cache.bounds)
    end

    # Reused scratch buffers (bounded allocation per frame).
    if cache === nothing
        tri = Vector{Vec4{Float64}}(undef, 3)
        clipped = Vector{Vec4{Float64}}(undef, 0)
        sizehint!(clipped, 6)
        sx = Vector{Float64}(undef, 8)
        sy = Vector{Float64}(undef, 8)
        sz = Vector{Float64}(undef, 8)
    else
        tri = cache.tri
        clipped = cache.clipped
        empty!(clipped)
        sx = cache.sx
        sy = cache.sy
        sz = cache.sz
    end
    colorbuf = cache === nothing ? Color3{Float64}[] : cache.colors

    # Opaque pass first (writes the depth buffer). Per-mesh shading mode honours
    # the mesh's `flat_shading` override, else the renderer default. Opaque meshes
    # are collected (not drawn inline) so they can optionally be drawn front-to-
    # back; the z-buffer keeps opaque output order-independent, so this affects
    # only overdraw work, never the final pixels.
    if cache === nothing
        transparent = Mesh[]
        transparent_worlds = Mat4{Float64}[]
        opaque_flat = Mesh[]
        opaque_flat_worlds = Mat4{Float64}[]
        smooth_meshes = Mesh[]
        smooth_worlds = Mat4{Float64}[]
    else
        transparent = cache.transparent
        transparent_worlds = cache.transparent_worlds
        opaque_flat = cache.opaque_flat
        opaque_flat_worlds = cache.opaque_flat_worlds
        smooth_meshes = cache.smooth_meshes
        smooth_worlds = cache.smooth_worlds
        empty!(transparent)
        empty!(transparent_worlds)
        empty!(opaque_flat)
        empty!(opaque_flat_worlds)
        empty!(smooth_meshes)
        empty!(smooth_worlds)
    end
    wireframe_meshes = cache === nothing ? Mesh[] : cache.wireframe_meshes
    wireframe_worlds = cache === nothing ? Mat4{Float64}[] : cache.wireframe_worlds
    empty!(wireframe_meshes)
    empty!(wireframe_worlds)
    for i in eachindex(meshes)
        mesh = meshes[i]
        world = mesh_worlds[i]
        geo = _mesh_geometry(mesh)
        mat = _mesh_material(mesh)
        if frustum !== nothing
            _mesh_in_frustum(frustum, geo, world, bounds_cache) || continue
        end
        if material_wireframe(mat)
            push!(wireframe_meshes, mesh)
            push!(wireframe_worlds, world)
        elseif is_transparent_material(mat)
            push!(transparent, mesh)
            push!(transparent_worlds, world)
        elseif _mesh_is_flat(mesh, shading)
            push!(opaque_flat, mesh)
            push!(opaque_flat_worlds, world)
        else
            push!(smooth_meshes, mesh)
            push!(smooth_worlds, world)
        end
    end

    # Front-to-back draw order for opaque meshes (nearest first = largest, least-
    # negative view-space z). Pure draw-order optimisation; pixels are unchanged.
    if sort_objects
        depth_scratch = cache === nothing ? nothing : cache.mesh_depths
        _sort_meshes_by_depth!(opaque_flat, opaque_flat_worlds, view, true, depth_scratch)
        _sort_meshes_by_depth!(smooth_meshes, smooth_worlds, view, true, depth_scratch)
    end

    for i in eachindex(opaque_flat)
        mesh = opaque_flat[i]
        _rasterize_flat_mesh_from_mesh!(rt, mesh, opaque_flat_worlds[i], lights,
                                        proj, view, near, camera_position, tri, clipped,
                                        sx, sy, sz, colorbuf, 1.0, nothing, 0,
                                        shadow_fn, xlo, xhi, ylo, yhi,
                                        clipping_planes, log_depth, inv_log_far,
                                        ortho_dir,
                                        cache === nothing ? nothing : cache.smooth_tri,
                                        cache === nothing ? nothing : cache.smooth_clipped,
                                        cache === nothing ? nothing : cache.smooth_iw)
    end

    smooth_instance_tri = if shading === :smooth
        cache === nothing ? Vector{ShadeVtx}(undef, 3) : cache.smooth_tri
    else
        nothing
    end
    smooth_instance_clipped = if shading === :smooth
        if cache === nothing
            buffer = ShadeVtx[]
            sizehint!(buffer, 6)
            buffer
        else
            cache.smooth_clipped
        end
    else
        nothing
    end
    smooth_instance_iw = if shading === :smooth
        cache === nothing ? Vector{Float64}(undef, 8) : cache.smooth_iw
    else
        nothing
    end

    # InstancedMesh: same geometry/material drawn at each instance transform.
    for (instanced_slot, im) in pairs(instanced)
        _instanced_triangle_drawable(im) || continue
        base = instanced_worlds[instanced_slot]
        geo = _instanced_geometry(im)
        mat = _instanced_material(im)
        (material_wireframe(mat) ? _primitive_blends(mat) :
         is_transparent_material(mat)) && continue
        mesh_shadow_fn = object_receives_shadow(im) ? shadow_fn : nothing
        instance_materials = cache === nothing ? nothing :
                             _instanced_materials!(cache.instanced_materials,
                                                   instanced_slot, im, mat,
                                                   im.instance_colors)
        if shading === :smooth && !material_wireframe(mat)
            @inbounds for instance_index in eachindex(im.instance_matrices)
                instance_material = cache === nothing ?
                    _with_vertex_color(
                        mat, im.instance_colors[instance_index]) :
                    _cached_instanced_material_at(
                        cache.instanced_materials, instanced_slot,
                        instance_index, mat)
                world = base * im.instance_matrices[instance_index]
                _render_smooth_geometry!(
                    rt, geo, instance_material, world, lights,
                    proj, view, near, camera_position, mesh_shadow_fn,
                    smooth_instance_tri::Vector{ShadeVtx},
                    smooth_instance_clipped::Vector{ShadeVtx},
                    sx, sy, sz,
                    smooth_instance_iw::Vector{Float64},
                    clipping_planes, xlo, xhi, ylo, yhi,
                    log_depth, inv_log_far, ortho_dir, nothing, 0)
            end
            continue
        end
        _render_instanced_mesh_flat!(rt, geo, mat, im.instance_colors,
                                     im.instance_matrices, base, lights, proj, view, near,
                                     camera_position, tri, clipped, sx, sy, sz;
                                     shadow_fn=mesh_shadow_fn, clipping_planes=clipping_planes,
                                     colorbuf=colorbuf,
                                     xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                     log_depth=log_depth, inv_log_far=inv_log_far,
                                     ortho_dir=ortho_dir, stamp_cache=cache,
                                     instance_materials=instance_materials)
    end

    # Smooth (per-pixel) opaque meshes share the same depth buffer.
    isempty(smooth_meshes) ||
        _render_smooth!(rt, smooth_meshes, lights, proj, view, near, camera_position, shadow_fn;
                        clipping_planes=clipping_planes,
                        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                        log_depth=log_depth, inv_log_far=inv_log_far, ortho_dir=ortho_dir,
                        smooth_tri=cache === nothing ? nothing : cache.smooth_tri,
                        smooth_clipped=cache === nothing ? nothing : cache.smooth_clipped,
                        smooth_sx=cache === nothing ? nothing : sx,
                        smooth_sy=cache === nothing ? nothing : sy,
                        smooth_sz=cache === nothing ? nothing : sz,
                        smooth_iw=cache === nothing ? nothing : cache.smooth_iw,
                        worlds=smooth_worlds)

    # Opaque wireframes and primitive objects participate in the depth pass
    # before any transparent object is blended.
    for i in eachindex(wireframe_meshes)
        mesh = wireframe_meshes[i]
        _primitive_blends(_mesh_material(mesh)) && continue
        _render_wireframe_mesh_from_mesh!(
            rt, mesh, wireframe_worlds[i], proj, view, near,
            xlo, xhi, ylo, yhi, cache)
    end

    primitive_stamp = if primitive_flags.sprites || primitive_flags.lines
        cache === nothing ? zeros(Int, H, W) :
        _render_cache_primitive_stamp!(cache, H, W)
    else
        _EMPTY_INT_STAMP
    end
    sprite_state = cache === nothing ?
        _SpriteRenderState(primitive_stamp, 0) : cache.sprite_state
    vp = proj * view
    for primitive_index in eachindex(primitives)
        object = primitives[primitive_index]
        _render_primitive_blends(object) && continue
        world = primitive_worlds[primitive_index]
        if object isa Sprite
            fill!(primitive_stamp, 0)
            sprite_state.stamp = primitive_stamp
            sprite_state.stamp_id = 0
            _draw_sprite_object!(
                rt, object, world, camera, view, vp, W, H,
                clipping_planes, xlo, xhi, ylo, yhi, cache,
                sprite_state)
        elseif object isa LineObject || object isa LineSegments ||
               object isa LineLoop
            fill!(primitive_stamp, 0)
            _draw_line_object!(
                rt, object, world, proj, view, near,
                xlo, xhi, ylo, yhi, primitive_stamp, 0,
                cache === nothing ? nothing : cache.morph_positions)
        elseif object isa PointsObject
            _draw_points_object!(
                rt, object, world, camera, proj, view, near,
                W, H, xlo, xhi, ylo, yhi,
                cache === nothing ? nothing : cache.morph_positions)
        elseif object isa InstancedMesh && _instanced_line_drawable(object)
            fill!(primitive_stamp, 0)
            _draw_instanced_lines!(
                rt, object, world, proj, view, near,
                xlo, xhi, ylo, yhi, primitive_stamp, 0)
        else
            _draw_instanced_points!(
                rt, object::InstancedMesh, world, camera, proj, view,
                near, W, H, xlo, xhi, ylo, yhi)
        end
    end

    # Transparent pass: merge ordinary meshes and individual instance
    # transforms into one back-to-front draw list. Depth writes follow each
    # material's `depth_write` field. The order is required for blending and is
    # kept regardless of `sort_objects`.
    transparent_items = cache === nothing ? _TransparentRenderItem[] :
                        cache.transparent_items
    empty!(transparent_items)
    sizehint!(transparent_items, length(transparent))
    @inbounds for index in eachindex(transparent)
        push!(transparent_items, _TransparentRenderItem(
            _mesh_view_depth_world(transparent_worlds[index], view),
            _TRANSPARENT_MESH_ITEM, index, 0))
    end
    @inbounds for (instanced_slot, im) in pairs(instanced)
        _instanced_triangle_drawable(im) || continue
        mat = _instanced_material(im)
        (material_wireframe(mat) ? _primitive_blends(mat) :
         is_transparent_material(mat)) || continue
        cache === nothing || _instanced_materials!(
            cache.instanced_materials, instanced_slot, im, mat,
            im.instance_colors)
        base = instanced_worlds[instanced_slot]
        for instance_index in eachindex(im.instance_matrices)
            world = base * im.instance_matrices[instance_index]
            kind = material_wireframe(mat) ?
                   _TRANSPARENT_INSTANCED_WIREFRAME_ITEM :
                   _TRANSPARENT_INSTANCE_ITEM
            push!(transparent_items, _TransparentRenderItem(
                _mesh_view_depth_world(world, view),
                kind, instanced_slot,
                instance_index))
        end
    end
    @inbounds for index in eachindex(wireframe_meshes)
        _primitive_blends(
            _mesh_material(wireframe_meshes[index])) || continue
        push!(transparent_items, _TransparentRenderItem(
            _mesh_view_depth_world(wireframe_worlds[index], view),
            _TRANSPARENT_WIREFRAME_ITEM, index, 0))
    end
    @inbounds for primitive_index in eachindex(primitives)
        object = primitives[primitive_index]
        _render_primitive_blends(object) || continue
        base = primitive_worlds[primitive_index]
        if object isa InstancedMesh
            for instance_index in eachindex(object.instance_matrices)
                world = base * object.instance_matrices[instance_index]
                kind = _instanced_line_drawable(object) ?
                       _TRANSPARENT_INSTANCED_LINE_ITEM :
                       _TRANSPARENT_INSTANCED_POINT_ITEM
                push!(transparent_items, _TransparentRenderItem(
                    _mesh_view_depth_world(world, view), kind,
                    primitive_index, instance_index))
            end
        else
            push!(transparent_items, _TransparentRenderItem(
                _mesh_view_depth_world(base, view),
                _render_primitive_item_kind(object), primitive_index, 0))
        end
    end
    if !isempty(transparent_items)
        _sort_transparent_items!(transparent_items)
        # Half-open triangle fill owns shared boundaries, so mesh draw items do
        # not need a whole-item stamp that would suppress deeper surfaces.
        stamp = nothing
        sid = 0
        for item in transparent_items
            sid += 1
            if item.kind == _TRANSPARENT_MESH_ITEM
                mesh = transparent[item.object_index]
                world = transparent_worlds[item.object_index]
                if _mesh_is_flat(mesh, shading)
                    _rasterize_flat_mesh_material_opacity_from_mesh!(
                        rt, mesh, world, lights, proj, view, near,
                        camera_position, tri, clipped, sx, sy, sz, colorbuf,
                        stamp, sid, shadow_fn, xlo, xhi, ylo, yhi,
                        clipping_planes, log_depth, inv_log_far, ortho_dir,
                        cache === nothing ? nothing : cache.smooth_tri,
                        cache === nothing ? nothing : cache.smooth_clipped,
                        cache === nothing ? nothing : cache.smooth_iw)
                else
                    # Smooth-shaded transparent mesh: per-pixel interpolated
                    # normals with source-over blending.
                    _render_smooth!(
                        rt, (mesh,), lights, proj, view, near,
                        camera_position, shadow_fn;
                        clipping_planes=clipping_planes,
                        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                        log_depth=log_depth, inv_log_far=inv_log_far,
                        ortho_dir=ortho_dir, stamp=stamp, stamp_id=sid,
                        smooth_tri=cache === nothing ? nothing : cache.smooth_tri,
                        smooth_clipped=cache === nothing ? nothing :
                                        cache.smooth_clipped,
                        smooth_sx=cache === nothing ? nothing : sx,
                        smooth_sy=cache === nothing ? nothing : sy,
                        smooth_sz=cache === nothing ? nothing : sz,
                        smooth_iw=cache === nothing ? nothing : cache.smooth_iw,
                        worlds=(world,))
                end
            elseif item.kind == _TRANSPARENT_INSTANCE_ITEM
                instanced_slot = item.object_index
                instance_index = item.instance_index
                im = instanced[instanced_slot]
                geo = _instanced_geometry(im)
                base_material = _instanced_material(im)
                instance_material = cache === nothing ?
                    _with_vertex_color(
                        base_material, im.instance_colors[instance_index]) :
                    _cached_instanced_material_at(
                        cache.instanced_materials, instanced_slot,
                        instance_index, base_material)
                world = instanced_worlds[instanced_slot] *
                        im.instance_matrices[instance_index]
                mesh_shadow_fn = object_receives_shadow(im) ? shadow_fn : nothing
                mesh_clipping_planes = _combined_clipping_planes(
                    clipping_planes,
                    material_clipping_planes(instance_material))
                if shading === :smooth
                    _render_smooth_geometry!(
                        rt, geo, instance_material, world, lights,
                        proj, view, near, camera_position, mesh_shadow_fn,
                        smooth_instance_tri::Vector{ShadeVtx},
                        smooth_instance_clipped::Vector{ShadeVtx},
                        sx, sy, sz,
                        smooth_instance_iw::Vector{Float64},
                        clipping_planes, xlo, xhi, ylo, yhi,
                        log_depth, inv_log_far, ortho_dir, stamp, sid)
                else
                    _rasterize_geo_flat!(
                        rt, geo, world, instance_material, lights, proj, view,
                        near, camera_position, tri, clipped, sx, sy, sz;
                        alpha=Float64(material_opacity(instance_material)),
                        stamp=stamp, stamp_id=sid,
                        shadow_fn=mesh_shadow_fn,
                        clipping_planes=mesh_clipping_planes,
                        colorbuf=colorbuf,
                        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                        log_depth=log_depth, inv_log_far=inv_log_far,
                        ortho_dir=ortho_dir,
                        flat_attr_tri=cache === nothing ? nothing :
                                      cache.smooth_tri,
                        flat_attr_clipped=cache === nothing ? nothing :
                                         cache.smooth_clipped,
                        flat_iw=cache === nothing ? nothing : cache.smooth_iw)
                end
            elseif item.kind == _TRANSPARENT_WIREFRAME_ITEM
                mesh = wireframe_meshes[item.object_index]
                _render_wireframe_mesh_from_mesh!(
                    rt, mesh, wireframe_worlds[item.object_index],
                    proj, view, near, xlo, xhi, ylo, yhi, cache)
            elseif item.kind == _TRANSPARENT_INSTANCED_WIREFRAME_ITEM
                instanced_slot = item.object_index
                instance_index = item.instance_index
                object = instanced[instanced_slot]
                base_material = _instanced_material(object)
                instance_material = cache === nothing ?
                    _with_vertex_color(
                        base_material,
                        object.instance_colors[instance_index]) :
                    _cached_instanced_material_at(
                        cache.instanced_materials, instanced_slot,
                        instance_index, base_material)
                world = instanced_worlds[instanced_slot] *
                        object.instance_matrices[instance_index]
                _render_wireframe_mesh_cached!(
                    rt, _instanced_geometry(object), instance_material,
                    world, proj, view, near, xlo, xhi, ylo, yhi, cache)
            elseif item.kind == _TRANSPARENT_SPRITE_ITEM
                fill!(primitive_stamp, 0)
                sprite_state.stamp = primitive_stamp
                sprite_state.stamp_id = 0
                primitive_index = item.object_index
                _draw_sprite_object!(
                    rt, primitives[primitive_index]::Sprite,
                    primitive_worlds[primitive_index], camera, view, vp,
                    W, H, clipping_planes, xlo, xhi, ylo, yhi,
                    cache, sprite_state)
            elseif item.kind == _TRANSPARENT_LINE_ITEM
                fill!(primitive_stamp, 0)
                primitive_index = item.object_index
                _draw_line_object!(
                    rt, primitives[primitive_index],
                    primitive_worlds[primitive_index], proj, view, near,
                    xlo, xhi, ylo, yhi, primitive_stamp, 0,
                    cache === nothing ? nothing : cache.morph_positions)
            elseif item.kind == _TRANSPARENT_POINT_ITEM
                primitive_index = item.object_index
                _draw_points_object!(
                    rt, primitives[primitive_index]::PointsObject,
                    primitive_worlds[primitive_index], camera, proj, view,
                    near, W, H, xlo, xhi, ylo, yhi,
                    cache === nothing ? nothing : cache.morph_positions)
            elseif item.kind == _TRANSPARENT_INSTANCED_LINE_ITEM
                fill!(primitive_stamp, 0)
                primitive_index = item.object_index
                object = primitives[primitive_index]::InstancedMesh
                instance_index = item.instance_index
                geo = _instanced_geometry(object)
                _validate_indexed_geometry(geo, "render_lines!")
                _draw_line_geometry_from_material!(
                    rt, geo, _instanced_material(object),
                    primitive_worlds[primitive_index] *
                    object.instance_matrices[instance_index],
                    object.draw_mode, proj, view, near,
                    xlo, xhi, ylo, yhi, primitive_stamp, 0, nothing,
                    object.instance_colors[instance_index])
            else
                primitive_index = item.object_index
                object = primitives[primitive_index]::InstancedMesh
                instance_index = item.instance_index
                geo = _instanced_geometry(object)
                _validate_indexed_geometry(geo, "render_points!")
                _draw_points_geometry_from_material!(
                    rt, geo, _instanced_material(object),
                    primitive_worlds[primitive_index] *
                    object.instance_matrices[instance_index],
                    camera, proj, view, near, W, H,
                    xlo, xhi, ylo, yhi, nothing,
                    object.instance_colors[instance_index])
            end
        end
    end

    return rt
end

"""
    render!(rt, scene, camera::ArrayCamera; kwargs...)

Render each sub-camera into its `ArrayCamera.viewports` rectangle, compositing
the results into one `RenderTarget`. Viewports use Diff3D's CPU scissor
convention: `(x, y, width, height)` with a top-left origin and 0-based `x`/`y`.
Empty or fully off-target viewports are skipped.
"""
function render!(rt::RenderTarget, scene::Scene, camera::ArrayCamera;
                 scissor::Union{Nothing,NTuple{4,Int}}=nothing,
                 scissor_test::Bool=false, kwargs...)
    length(camera.cameras) == length(camera.viewports) ||
        throw(ArgumentError("ArrayCamera cameras and viewports lengths must match"))
    outer_scissor = scissor_test && scissor !== nothing
    if outer_scissor
        clear_rect!(rt, scene.background, _scissor_bounds(rt, scissor)...)
    else
        clear!(rt, scene.background)
    end
    for (subcamera, viewport) in zip(camera.cameras, camera.viewports)
        sx, sy, sw, sh = viewport
        sw > 0 && sh > 0 || continue
        view_scissor = outer_scissor ? _intersect_scissor(viewport, scissor) : viewport
        view_scissor === nothing && continue
        sx, sy, sw, sh = view_scissor
        (sx < rt.width && sy < rt.height &&
         _saturating_add_int(sx, sw) > 0 &&
         _saturating_add_int(sy, sh) > 0) || continue
        render!(rt, scene, subcamera; kwargs..., scissor=view_scissor, scissor_test=true)
    end
    return rt
end

# World-space bounding sphere of a geometry placed by `world_mat`, then tested
# against the frustum. The sphere centre is the geometry centre transformed to
# world; the radius scales by the largest axis scale extracted from `world_mat`
# (a conservative bound for non-uniform scale that never culls a visible mesh).
@inline function _mesh_local_bounding_sphere(geo::BufferGeometry, ::Nothing)
    return compute_bounding_sphere(geo)
end

@inline function _mesh_local_bounding_sphere(geo::BufferGeometry,
                                             bounds_cache::Tuple{Vector{BufferGeometry},
                                                                 Vector{BoundingSphere{Float64}}})
    bound_geometries, bounds = bounds_cache
    @inbounds for i in eachindex(bound_geometries)
        bound_geometries[i] === geo && return bounds[i]
    end
    bs = compute_bounding_sphere(geo)
    push!(bound_geometries, geo)
    push!(bounds, bs)
    return bs
end

@inline function _mesh_in_frustum(frustum::Frustum, geo::BufferGeometry,
                                  world_mat::Mat4, bounds_cache=nothing)
    bs = _mesh_local_bounding_sphere(geo, bounds_cache)
    bs.radius == 0 && geo.n_vertices == 0 && return false
    center = mat4_transform_point(world_mat, bs.center)
    # Column lengths of the upper-left 3×3 give the per-axis scale factors.
    r = bs.radius * _mat4_linear_max_scale(world_mat)
    return frustum_intersects_sphere(frustum, BoundingSphere(center, r))
end

# Hierarchical visibility (three.js `projectObject`): an object renders only
# when it and every ancestor are visible. `collect_meshes` already prunes
# invisible subtrees; this guard covers the cached and instanced collection
# paths, which traverse the graph without that pruning.
@inline function _visible_in_tree(obj)
    o = obj
    while o !== nothing
        is_visible(o) || return false
        o = get_parent(o)
    end
    return true
end

# Effective shading for a mesh: its override if set, else the renderer default.
_mesh_is_flat(mesh::Mesh, default_shading::Symbol) =
    mesh.flat_shading === nothing ? (default_shading === :flat) : mesh.flat_shading

# Material face side (defaults to front-facing/back-culled, matching three.js).
material_side(m::AbstractMaterial) =
    hasfield(typeof(m), :side) ? _validated_material_side(getfield(m, :side)) : :front

# View-space z of a mesh's world origin (more negative = farther from camera).
function _mesh_view_depth(mesh, view::Mat4)
    w = compute_world_matrix(mesh)
    o = mat4_transform_point(w, Vec3(0.0, 0.0, 0.0))
    v = mat4_transform_vec4(view, Vec4(o.x, o.y, o.z, 1.0))
    return v.z
end

function _mesh_view_depth_world(world::Mat4, view::Mat4)
    o = mat4_transform_point(world, Vec3(0.0, 0.0, 0.0))
    v = mat4_transform_vec4(view, Vec4(o.x, o.y, o.z, 1.0))
    return v.z
end

const _TRANSPARENT_MESH_ITEM = UInt8(0)
const _TRANSPARENT_INSTANCE_ITEM = UInt8(1)
const _TRANSPARENT_WIREFRAME_ITEM = UInt8(2)
const _TRANSPARENT_SPRITE_ITEM = UInt8(3)
const _TRANSPARENT_LINE_ITEM = UInt8(4)
const _TRANSPARENT_POINT_ITEM = UInt8(5)
const _TRANSPARENT_INSTANCED_LINE_ITEM = UInt8(6)
const _TRANSPARENT_INSTANCED_POINT_ITEM = UInt8(7)
const _TRANSPARENT_INSTANCED_WIREFRAME_ITEM = UInt8(8)

struct _TransparentRenderItem
    depth::Float64
    kind::UInt8
    object_index::Int
    instance_index::Int
end

function _sort_transparent_items!(items::Vector{_TransparentRenderItem})
    gap = length(items) >>> 1
    @inbounds while gap > 0
        for index in (gap + 1):length(items)
            item = items[index]
            position = index
            while position > gap && items[position - gap].depth > item.depth
                items[position] = items[position - gap]
                position -= gap
            end
            items[position] = item
        end
        gap >>>= 1
    end
    return items
end

function _sort_meshes_by_cached_depth!(meshes::Vector{Mesh}, depths::Vector{Float64},
                                       view::Mat4, nearest_first::Bool)
    n = length(meshes)
    n <= 1 && return meshes
    resize!(depths, n)
    @inbounds for i in 1:n
        depths[i] = _mesh_view_depth(meshes[i], view)
    end
    gap = n >>> 1
    @inbounds while gap > 0
        for i in (gap + 1):n
            mesh = meshes[i]
            depth = depths[i]
            j = i
            while j > gap
                prev_depth = depths[j - gap]
                should_shift = nearest_first ? prev_depth < depth : prev_depth > depth
                should_shift || break
                meshes[j] = meshes[j - gap]
                depths[j] = prev_depth
                j -= gap
            end
            meshes[j] = mesh
            depths[j] = depth
        end
        gap >>>= 1
    end
    return meshes
end

function _sort_meshes_by_cached_depth!(meshes::Vector{Mesh},
                                       worlds::Vector{Mat4{Float64}},
                                       depths::Vector{Float64},
                                       view::Mat4, nearest_first::Bool)
    n = length(meshes)
    n <= 1 && return meshes
    resize!(depths, n)
    @inbounds for i in 1:n
        depths[i] = _mesh_view_depth_world(worlds[i], view)
    end
    gap = n >>> 1
    @inbounds while gap > 0
        for i in (gap + 1):n
            mesh = meshes[i]
            world = worlds[i]
            depth = depths[i]
            j = i
            while j > gap
                prev_depth = depths[j - gap]
                should_shift = nearest_first ? prev_depth < depth : prev_depth > depth
                should_shift || break
                meshes[j] = meshes[j - gap]
                worlds[j] = worlds[j - gap]
                depths[j] = prev_depth
                j -= gap
            end
            meshes[j] = mesh
            worlds[j] = world
            depths[j] = depth
        end
        gap >>>= 1
    end
    return meshes
end

function _sort_meshes_by_depth!(meshes::Vector{Mesh}, view::Mat4,
                                nearest_first::Bool,
                                depths::Union{Nothing,Vector{Float64}}=nothing)
    n = length(meshes)
    n <= 1 && return meshes
    if depths !== nothing
        return _sort_meshes_by_cached_depth!(meshes, depths, view, nearest_first)
    elseif n <= 32
        @inbounds for i in 2:n
            mesh = meshes[i]
            depth = _mesh_view_depth(mesh, view)
            j = i - 1
            while j >= 1
                prev_depth = _mesh_view_depth(meshes[j], view)
                should_shift = nearest_first ? prev_depth < depth : prev_depth > depth
                should_shift || break
                meshes[j + 1] = meshes[j]
                j -= 1
            end
            meshes[j + 1] = mesh
        end
    elseif n > 32
        local_depths = Vector{Float64}(undef, n)
        return _sort_meshes_by_cached_depth!(meshes, local_depths, view, nearest_first)
    end
    return meshes
end

function _sort_meshes_by_depth!(meshes::Vector{Mesh},
                                worlds::Vector{Mat4{Float64}},
                                view::Mat4, nearest_first::Bool,
                                depths::Union{Nothing,Vector{Float64}}=nothing)
    n = length(meshes)
    n <= 1 && return meshes
    if depths !== nothing
        return _sort_meshes_by_cached_depth!(meshes, worlds, depths, view, nearest_first)
    elseif n <= 32
        @inbounds for i in 2:n
            mesh = meshes[i]
            world = worlds[i]
            depth = _mesh_view_depth_world(world, view)
            j = i - 1
            while j >= 1
                prev_depth = _mesh_view_depth_world(worlds[j], view)
                should_shift = nearest_first ? prev_depth < depth : prev_depth > depth
                should_shift || break
                meshes[j + 1] = meshes[j]
                worlds[j + 1] = worlds[j]
                j -= 1
            end
            meshes[j + 1] = mesh
            worlds[j + 1] = world
        end
    else
        local_depths = Vector{Float64}(undef, n)
        return _sort_meshes_by_cached_depth!(meshes, worlds, local_depths, view, nearest_first)
    end
    return meshes
end

# Material transparency helpers (some materials lack these fields).
material_opacity(m::AbstractMaterial) = hasfield(typeof(m), :opacity) ?
    _validated_material_opacity(getfield(m, :opacity)) : 1.0
material_transparent(m::AbstractMaterial) = hasfield(typeof(m), :transparent) ? getfield(m, :transparent) : false
function is_transparent_material(m::AbstractMaterial)
    _validate_material_parameters(m)
    material_opacity(m)
    return material_transparent(m)
end
function _primitive_blends(m::AbstractMaterial)
    _validate_material_parameters(m)
    return material_transparent(m) || material_opacity(m) < 1.0
end
@inline function _render_primitive_blends(object::AbstractObject3D)
    material = _render_primitive_material(object)
    _primitive_blends(material) && return true
    point_or_sprite = object isa Sprite || object isa PointsObject ||
                      (object isa InstancedMesh &&
                       _instanced_point_drawable(object))
    point_or_sprite || return false
    return _has_texture_alpha(_material_field(material, :map)) ||
           _has_alpha_map(_material_field(material, :alpha_map))
end
material_depth_test(m::AbstractMaterial) = hasfield(typeof(m), :depth_test) ? getfield(m, :depth_test) : true
material_depth_write(m::AbstractMaterial) = hasfield(typeof(m), :depth_write) ? getfield(m, :depth_write) : true
material_alpha_test(m::AbstractMaterial) = hasfield(typeof(m), :alpha_test) ?
    _validated_material_alpha_test(getfield(m, :alpha_test)) : 0.0
material_wireframe(m::AbstractMaterial) = hasfield(typeof(m), :wireframe) ? getfield(m, :wireframe) : false
function material_clipping_planes(m::AbstractMaterial)
    hasfield(typeof(m), :clipping_planes) || return _NO_PLANES
    planes = getfield(m, :clipping_planes)
    _validate_material_clipping_planes(planes)
    return planes
end

@inline function _shade_flat_shader_face(geo, fi::Int, world_mat::Mat4,
                                         mat::ShaderMaterial, lights,
                                         cam_pos::Vec3, normal_mat::Mat4,
                                         has_normals::Bool; shadow_fn=nothing,
                                         ortho_dir=nothing)
    i1, i2, i3 = get_face(geo, fi)
    v1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
    v2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
    v3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
    center = _mean3_vec3(v1, v2, v3)
    side = material_side(mat)
    face_n = _flat_face_normal(
        geo, i1, i2, i3, v1, v2, v3, normal_mat, has_normals)
    if side !== :front
        front_facing = _face_front_facing(
            v1, v2, v3, center, cam_pos, ortho_dir)
        face_n = _side_oriented_normal(face_n, side, front_facing)
    end
    return clamp_color(shade_face(
        face_n, _direction_between(center, cam_pos), center,
        mat, lights; shadow_fn=shadow_fn))
end

function _combined_clipping_planes(global_planes, material_planes)
    isempty(material_planes) && return global_planes
    isempty(global_planes) && return material_planes
    return _CombinedClippingPlanes(global_planes, material_planes)
end

@inline function _texture_alpha_channel(tex)
    tex isa Texture || return 0
    channels = size(tex.data, 3)
    return channels == 2 ? 2 : channels >= 4 ? 4 : 0
end
@inline _has_texture_alpha(tex) = _texture_alpha_channel(tex) != 0
@inline _has_alpha_map(tex) = tex isa Texture
@inline _needs_fragment_alpha(alpha_test::Float64, alpha_base::Float64, albedo_map, alpha_map) =
    alpha_test > 0.0 || alpha_base < 1.0 || _has_texture_alpha(albedo_map) || _has_alpha_map(alpha_map)

@inline function _fragment_alpha(alpha_base::Float64, albedo_map, alpha_map, u, v, u2, v2)
    a = alpha_base
    alpha_channel = _texture_alpha_channel(albedo_map)
    if alpha_channel != 0
        tu, tv = _map_uv(albedo_map, u, v, u2, v2)
        a *= sample_texture_channel(
            albedo_map, tu, tv, alpha_channel; default=1.0)
    end
    if _has_alpha_map(alpha_map)
        tu, tv = _map_uv(alpha_map, u, v, u2, v2)
        a *= sample_texture_channel(alpha_map, tu, tv, 2; default=1.0)
    end
    return a
end

# Rasterize one geometry (flat shading) at a given world transform, reusing the
# caller's scratch buffers. Shared by the mesh loop and the InstancedMesh loop.
function _rasterize_geo_flat!(rt::RenderTarget, geo, world_mat::Mat4, mat,
                              lights, proj::Mat4, view::Mat4, near, cam_pos::Vec3,
                              tri, clipped, sx, sy, sz;
                              alpha::Real=1.0, stamp=nothing, stamp_id::Int=0, shadow_fn=nothing,
                              xlo::Int=1, xhi::Int=typemax(Int),
                              ylo::Int=1, yhi::Int=typemax(Int), colorbuf=nothing,
                              clipping_planes=_NO_PLANES,
                              log_depth::Bool=false, inv_log_far::Float64=1.0,
                              ortho_dir=nothing,
                              flat_attr_tri=nothing,
                              flat_attr_clipped=nothing,
                              flat_iw=nothing)
    W, H = rt.width, rt.height
    modelview = view * world_mat
    blend = material_transparent(mat) || alpha < 1.0
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    side = material_side(mat)
    normal_mat = mat4_transpose(mat4_inverse(world_mat))
    has_normals = length(geo.normals) >= geo.n_vertices * 3
    lazy_shader_faces = mat isa ShaderMaterial
    face_colors = if lazy_shader_faces
        nothing
    elseif mat isa MeshDepthMaterial
        depth_colors = colorbuf === nothing ? Color3{Float64}[] : colorbuf
        _shade_depth_faces!(depth_colors, geo, modelview, mat)
    else
        colorbuf === nothing ?
            shade_mesh_faces(
                geo, world_mat, mat, lights, cam_pos;
                shadow_fn=shadow_fn, ortho_dir=ortho_dir) :
            shade_mesh_faces!(
                colorbuf, geo, world_mat, mat, lights, cam_pos;
                shadow_fn=shadow_fn, ortho_dir=ortho_dir)
    end
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    albedo_map = has_uvs ? _material_field(mat, :map) : nothing
    alpha_map = has_uvs ? _material_field(mat, :alpha_map) : nothing
    alpha_test = material_alpha_test(mat)
    alpha_base = Float64(alpha)
    use_fragment_alpha = _has_texture_alpha(albedo_map) || _has_alpha_map(alpha_map)
    uv2_attr = use_fragment_alpha ? _uv2_attribute(geo) : nothing
    attr_tri = use_fragment_alpha ?
        (flat_attr_tri === nothing ? Vector{ShadeVtx}(undef, 3) :
         flat_attr_tri::Vector{ShadeVtx}) : nothing
    attr_clipped = if use_fragment_alpha
        if flat_attr_clipped === nothing
            buf = ShadeVtx[]
            sizehint!(buf, 6)
            buf
        else
            buf = flat_attr_clipped::Vector{ShadeVtx}
            empty!(buf)
            buf
        end
    else
        nothing
    end
    siw = use_fragment_alpha ?
        (flat_iw === nothing ? Vector{Float64}(undef, 8) :
         flat_iw::Vector{Float64}) : nothing
    # Per-fragment clipping needs each clipped vertex's world position. The
    # near-clipped polygon is in view space with w=1 (affine), so mapping it back
    # by the inverse view matrix recovers the world position. Computed once per
    # mesh and only when clipping is active.
    has_clip = !isempty(clipping_planes)
    view_inv = has_clip ? mat4_inverse(view) : view
    wp1 = _ZERO_V3; wp2 = _ZERO_V3; wp3 = _ZERO_V3
    iw1 = 1.0; iw2 = 1.0; iw3 = 1.0
    for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        # Back-face culling (skipped for double-sided materials).
        if side !== :double
            w1 = mat4_transform_point(world_mat, v1)
            w2 = mat4_transform_point(world_mat, v2)
            w3 = mat4_transform_point(world_mat, v3)
            wc = _mean3_vec3(w1, w2, w3)
            front_facing = _face_front_facing(
                w1, w2, w3, wc, cam_pos, ortho_dir)
            (side === :front ? !front_facing : front_facing) && continue
        end
        tri[1] = mat4_transform_vec4(modelview, Vec4(v1.x, v1.y, v1.z, 1.0))
        tri[2] = mat4_transform_vec4(modelview, Vec4(v2.x, v2.y, v2.z, 1.0))
        tri[3] = mat4_transform_vec4(modelview, Vec4(v3.x, v3.y, v3.z, 1.0))

        if use_fragment_alpha
            tri_attr = attr_tri::Vector{ShadeVtx}
            clipped_attr = attr_clipped::Vector{ShadeVtx}
            invw_scratch = siw::Vector{Float64}
            alpha_albedo_map = albedo_map isa Texture ? albedo_map::Texture : nothing
            alpha_alpha_map = alpha_map isa Texture ? alpha_map::Texture : nothing
            if uv2_attr === nothing
                @inbounds for (slot, vi, vtx) in ((1, i1, v1), (2, i2, v2), (3, i3, v3))
                    uv = Vec2(geo.uvs[(vi-1)*2+1], geo.uvs[(vi-1)*2+2])
                    tri_attr[slot] = ShadeVtx(
                        tri[slot],
                        mat4_transform_point(world_mat, vtx),
                        _ZERO_V3,
                        uv,
                        uv,
                        Color3(1.0, 1.0, 1.0),
                    )
                end
            else
                uv2_data = uv2_attr::BufferAttribute
                @inbounds for (slot, vi, vtx) in ((1, i1, v1), (2, i2, v2), (3, i3, v3))
                    uv = Vec2(geo.uvs[(vi-1)*2+1], geo.uvs[(vi-1)*2+2])
                    uv2_tuple = _vertex_uv_attr(uv2_data, vi)
                    uv2v = Vec2(uv2_tuple[1], uv2_tuple[2])
                    tri_attr[slot] = ShadeVtx(
                        tri[slot],
                        mat4_transform_point(world_mat, vtx),
                        _ZERO_V3,
                        uv,
                        uv2v,
                        Color3(1.0, 1.0, 1.0),
                    )
                end
            end

            m = _clip_near_attr!(clipped_attr, tri_attr, 3, near)
            m < 3 && continue

            @inbounds for k in 1:m
                cv = mat4_transform_vec4(proj, clipped_attr[k].vp)
                invw = 1.0 / cv.w
                ndcx = cv.x * invw; ndcy = cv.y * invw; ndcz = cv.z * invw
                sx[k] = (ndcx + 1) * 0.5 * W
                sy[k] = (1 - ndcy) * 0.5 * H
                sz[k] = log_depth ? _encode_log_depth(cv.w, inv_log_far) : ndcz
                invw_scratch[k] = invw
            end

            fc = lazy_shader_faces ?
                 _shade_flat_shader_face(geo, fi, world_mat, mat, lights, cam_pos,
                                         normal_mat, has_normals;
                                         shadow_fn=shadow_fn,
                                         ortho_dir=ortho_dir) :
                 face_colors[fi]
            @inbounds for k in 2:(m - 1)
                if blend
                    _rasterize_tri_blend!(rt, sx[1], sy[1], sz[1],
                                          sx[k], sy[k], sz[k],
                                          sx[k+1], sy[k+1], sz[k+1], fc, alpha, nothing, 0;
                                          xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                          clipping_planes=clipping_planes,
                                          wp1=clipped_attr[1].wp,
                                          wp2=clipped_attr[k].wp,
                                          wp3=clipped_attr[k+1].wp,
                                          iw1=invw_scratch[1], iw2=invw_scratch[k], iw3=invw_scratch[k+1],
                                          depth_test=depth_test, depth_write=depth_write,
                                          alpha_test=alpha_test, albedo_map=albedo_map, alpha_map=alpha_map,
                                          uv1=clipped_attr[1].uv,
                                          uv2=clipped_attr[k].uv,
                                          uv3=clipped_attr[k+1].uv,
                                          uv2_1=clipped_attr[1].uv2,
                                          uv2_2=clipped_attr[k].uv2,
                                          uv2_3=clipped_attr[k+1].uv2)
                else
                    _rasterize_tri_alpha!(rt, sx[1], sy[1], sz[1],
                                           sx[k], sy[k], sz[k],
                                           sx[k+1], sy[k+1], sz[k+1], fc,
                                           ylo, yhi, xlo, xhi, clipping_planes,
                                           clipped_attr[1].wp,
                                           clipped_attr[k].wp,
                                           clipped_attr[k+1].wp,
                                           invw_scratch[1],
                                           invw_scratch[k],
                                           invw_scratch[k+1],
                                           depth_test, depth_write,
                                           alpha_test, alpha_base,
                                           alpha_albedo_map, alpha_alpha_map,
                                           clipped_attr[1].uv,
                                           clipped_attr[k].uv,
                                           clipped_attr[k+1].uv,
                                           clipped_attr[1].uv2,
                                           clipped_attr[k].uv2,
                                           clipped_attr[k+1].uv2)
                end
            end
            continue
        end

        m = _clip_near!(clipped, tri, 3, near)
        m < 3 && continue

        @inbounds for k in 1:m
            cv = mat4_transform_vec4(proj, clipped[k])
            invw = 1.0 / cv.w
            ndcx = cv.x * invw; ndcy = cv.y * invw; ndcz = cv.z * invw
            sx[k] = (ndcx + 1) * 0.5 * W
            sy[k] = (1 - ndcy) * 0.5 * H
            # Default depth is NDC z; with `log_depth` the clip-space w (view
            # distance) is encoded logarithmically. Both are monotone in distance,
            # so the z-test direction is unchanged.
            sz[k] = log_depth ? _encode_log_depth(cv.w, inv_log_far) : ndcz
        end

        fc = lazy_shader_faces ?
             _shade_flat_shader_face(geo, fi, world_mat, mat, lights, cam_pos,
                                     normal_mat, has_normals;
                                     shadow_fn=shadow_fn,
                                     ortho_dir=ortho_dir) :
             face_colors[fi]
        @inbounds for k in 2:(m - 1)        # fan-triangulate the clipped polygon
            if has_clip
                # World position and 1/w of each clip vertex for the per-fragment
                # plane test (perspective-correct world interpolation). Needed by
                # both the opaque and alpha-blended rasterizers.
                cp1 = clipped[1]; cpk = clipped[k]; cpk1 = clipped[k+1]
                wp1 = mat4_transform_point(view_inv, Vec3(cp1.x, cp1.y, cp1.z))
                wp2 = mat4_transform_point(view_inv, Vec3(cpk.x, cpk.y, cpk.z))
                wp3 = mat4_transform_point(view_inv, Vec3(cpk1.x, cpk1.y, cpk1.z))
                iw1 = 1.0 / mat4_transform_vec4(proj, cp1).w
                iw2 = 1.0 / mat4_transform_vec4(proj, cpk).w
                iw3 = 1.0 / mat4_transform_vec4(proj, cpk1).w
            end
            if blend
                _rasterize_tri_blend!(rt, sx[1], sy[1], sz[1],
                                      sx[k], sy[k], sz[k],
                                      sx[k+1], sy[k+1], sz[k+1], fc, alpha, nothing, 0;
                                      xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                      clipping_planes=clipping_planes, wp1=wp1, wp2=wp2, wp3=wp3,
                                      iw1=iw1, iw2=iw2, iw3=iw3,
                                      depth_test=depth_test, depth_write=depth_write,
                                      alpha_test=alpha_test)
            elseif has_clip
                _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                sx[k], sy[k], sz[k],
                                sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                xlo=xlo, xhi=xhi,
                                clipping_planes=clipping_planes, wp1=wp1, wp2=wp2, wp3=wp3,
                                iw1=iw1, iw2=iw2, iw3=iw3,
                                depth_test=depth_test, depth_write=depth_write,
                                alpha_test=alpha_test, alpha_base=alpha_base)
            else
                _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                sx[k], sy[k], sz[k],
                                sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                xlo=xlo, xhi=xhi,
                                depth_test=depth_test, depth_write=depth_write,
                                alpha_test=alpha_test, alpha_base=alpha_base)
            end
        end
    end
    return nothing
end

# Alpha-blend a triangle over the existing colour, optionally z-tested and
# optionally writing depth according to the material flags. `xlo`/`xhi`/`ylo`/
# `yhi` clamp the covered pixel box so scissor testing restricts the blend.
# When `clipping_planes` is non-empty, fragments on the negative side of any
# plane are discarded by the same `_clip_keep` test as `_rasterize_tri!`.
@inline function _rasterize_tri_blend!(rt::RenderTarget, s1x, s1y, z1, s2x, s2y, z2,
                                       s3x, s3y, z3, fc::Color3, alpha, stamp, stamp_id::Int;
                                       xlo::Int=1, xhi::Int=typemax(Int),
                                       ylo::Int=1, yhi::Int=typemax(Int),
                                       clipping_planes=_NO_PLANES,
                                       wp1::Vec3=_ZERO_V3, wp2::Vec3=_ZERO_V3, wp3::Vec3=_ZERO_V3,
                                       iw1::Float64=1.0, iw2::Float64=1.0, iw3::Float64=1.0,
                                       depth_test::Bool=true, depth_write::Bool=false,
                                       alpha_test::Float64=0.0,
                                       albedo_map=nothing, alpha_map=nothing,
                                       uv1::Vec2=_ZERO_V2, uv2::Vec2=_ZERO_V2, uv3::Vec2=_ZERO_V2,
                                       uv2_1::Vec2=_ZERO_V2, uv2_2::Vec2=_ZERO_V2, uv2_3::Vec2=_ZERO_V2)
    W, H = rt.width, rt.height
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-10 && return nothing
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    fW, fH = Float64(W), Float64(H)
    inv_area = 1.0 / area
    positive_area = area > 0
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int, clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int, clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, Float64(alpha), albedo_map, alpha_map)
    @inbounds for px in min_x:max_x
        for py in min_y:max_y
            cx = px - 0.5; cy = py - 0.5
            w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if _half_open_triangle_contains(
                    w0, w1, w2, s1x, s1y, s2x, s2y, s3x, s3y,
                    positive_area)
                frag_alpha = alpha
                if has_clip || has_alpha
                    # Perspective-correct world position (weight by 1/w).
                    iw = w0*iw1 + w1*iw2 + w2*iw3
                    a0 = w0*iw1/iw; a1 = w1*iw2/iw; a2 = w2*iw3/iw
                    if has_clip
                        wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                                  a0*wp1.y + a1*wp2.y + a2*wp3.y,
                                  a0*wp1.z + a1*wp2.z + a2*wp3.z)
                        _clip_keep(clipping_planes, wp) || continue
                    end
                    if has_alpha
                        u = a0*uv1.x + a1*uv2.x + a2*uv3.x
                        v = a0*uv1.y + a1*uv2.y + a2*uv3.y
                        u2 = a0*uv2_1.x + a1*uv2_2.x + a2*uv2_3.x
                        v2 = a0*uv2_1.y + a1*uv2_2.y + a2*uv2_3.y
                        frag_alpha = _fragment_alpha(Float64(alpha), albedo_map, alpha_map, u, v, u2, v2)
                        frag_alpha >= alpha_test || continue
                    end
                end
                z = w0 * z1 + w1 * z2 + w2 * z3
                _inside_far_clip(z) || continue
                if !depth_test || z < rt.depth[py, px]
                    ia_frag = 1.0 - frag_alpha
                    rt.color[py, px, 1] = fc.r * frag_alpha + rt.color[py, px, 1] * ia_frag
                    rt.color[py, px, 2] = fc.g * frag_alpha + rt.color[py, px, 2] * ia_frag
                    rt.color[py, px, 3] = fc.b * frag_alpha + rt.color[py, px, 3] * ia_frag
                    depth_write && (rt.depth[py, px] = z)
                end
            end
        end
    end
    return nothing
end

"""
Edge function for barycentric coordinate computation.
Positive if (px,py) is on the left of line from (ax,ay) to (bx,by).
"""
@inline function edge_function(ax, ay, bx, by, px, py)
    (px - ax) * (by - ay) - (py - ay) * (bx - ax)
end

"""
Convert RenderTarget color buffer to a flat RGB array suitable for image export.
Returns Matrix{UInt8} of size (H, W*3) or Array{UInt8, 3} of size (H, W, 3).
"""
function render_to_rgb8(rt::RenderTarget)
    H, W = rt.height, rt.width
    img = Array{UInt8}(undef, H, W, 3)
    # NaN must map to a defined byte (0), not InexactError: clamp(NaN,...) is NaN.
    c8(v) = round(UInt8, (isnan(v) ? 0.0 : clamp(Float64(v), 0.0, 1.0)) * 255)
    for j in 1:W
        for i in 1:H
            img[i, j, 1] = c8(rt.color[i, j, 1])
            img[i, j, 2] = c8(rt.color[i, j, 2])
            img[i, j, 3] = c8(rt.color[i, j, 3])
        end
    end
    return img
end
