# --------------------------------------------------------------------------
# CPU software rasterizer with z-buffer.
# Produces an H×W×3 Float64 image array (RGB, values in [0,1]).
# --------------------------------------------------------------------------

struct RenderTarget{T<:Real}
    width::Int
    height::Int
    color::Array{T, 3}    # H × W × 3 (RGB)
    depth::Matrix{T}      # H × W
end

function RenderTarget(width::Int, height::Int; T=Float64)
    (width > 0 && height > 0) || throw(ArgumentError("RenderTarget dimensions must be positive"))
    color = zeros(T, height, width, 3)
    depth = fill(T(Inf), height, width)
    RenderTarget{T}(width, height, color, depth)
end

function clear!(rt::RenderTarget, bg::Color3)
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
    @inbounds for px in xlo:xhi, py in ylo:yhi
        rt.color[py, px, 1] = bg.r
        rt.color[py, px, 2] = bg.g
        rt.color[py, px, 3] = bg.b
        rt.depth[py, px] = eltype(rt.depth)(Inf)
    end
    return rt
end

function _scissor_bounds(rt::RenderTarget, scissor::NTuple{4,Int})
    sxr, syr, swr, shr = scissor
    xlo = max(1, sxr + 1); xhi = min(rt.width, sxr + swr)
    ylo = max(1, syr + 1); yhi = min(rt.height, syr + shr)
    return xlo, xhi, ylo, yhi
end

function _intersect_scissor(a::NTuple{4,Int}, b::NTuple{4,Int})
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    x0 = max(ax, bx); y0 = max(ay, by)
    x1 = min(ax + aw, bx + bw); y1 = min(ay + ah, by + bh)
    (x1 <= x0 || y1 <= y0) && return nothing
    return (x0, y0, x1 - x0, y1 - y0)
end

@inline _camera_near(c::AbstractCamera) = c.near
@inline _camera_far(c::AbstractCamera) = c.far

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
    @inbounds for py in min_y:max_y
        for px in min_x:max_x
            cx = px - 0.5
            cy = py - 0.5
            w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if w0 >= 0 && w1 >= 0 && w2 >= 0
                z = w0 * z1 + w1 * z2 + w2 * z3
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

# Per-pixel (smooth) triangle. World position and normal are interpolated
# perspective-correctly, then the shading model is evaluated per pixel. When the
# material carries UV-indexed material maps, the texture coordinate is also
# interpolated perspective-correctly and the maps are applied per pixel using the
# same helpers (`sample_texture_linear`, `_apply_normal_map`) as the flat path — so a
# textured surface looks identical under flat and smooth shading. `clipping_planes`
# discards fragments on the negative side of any plane (interpolated world pos).
@inline function _rasterize_tri_smooth!(rt::RenderTarget,
        s1x, s1y, z1, iw1, wp1::Vec3, wn1::Vec3, uv1::Vec2, uv2_1::Vec2, vc1::Color3,
        s2x, s2y, z2, iw2, wp2::Vec3, wn2::Vec3, uv2::Vec2, uv2_2::Vec2, vc2::Color3,
        s3x, s3y, z3, iw3, wp3::Vec3, wn3::Vec3, uv3::Vec2, uv2_3::Vec2, vc3::Color3,
        material::AbstractMaterial, lights, cam_pos::Vec3, shadow_fn,
        albedo_map, alpha_map, normal_map, roughness_map, metalness_map,
        specular_map, glossiness_map, physical_pbr_map, ao_map, emissive_map, light_map,
        normal_scale, clipping_planes;
        xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
        depth_test::Bool=true, depth_write::Bool=true,
        stamp=nothing, stamp_id::Int=0)
    W, H = rt.width, rt.height
    use_stamp = stamp !== nothing   # transparent pass: alpha-blend once per mesh per pixel
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
    has_uv_maps = has_albedo || has_alpha_map || has_normalmap || has_roughness ||
                  has_metalness || has_specular || has_glossiness ||
                  has_physical_pbr || has_ao || has_emissive || has_lightmap
    has_clip = !isempty(clipping_planes)
    alpha_test = material_alpha_test(material)
    alpha_base = Float64(material_opacity(material))
    @inbounds for py in min_y:max_y
        for px in min_x:max_x
            cx = px - 0.5
            cy = py - 0.5
            b0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            b1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            b2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            (b0 >= 0 && b1 >= 0 && b2 >= 0) || continue
            z = b0 * z1 + b1 * z2 + b2 * z3
            (!depth_test || z < rt.depth[py, px]) || continue
            use_stamp && stamp[py, px] == stamp_id && continue   # already blended by this mesh
            frag_alpha = alpha_base
            # Perspective-correct interpolation: weight by 1/w.
            iw = b0 * iw1 + b1 * iw2 + b2 * iw3
            a0 = b0 * iw1 / iw; a1 = b1 * iw2 / iw; a2 = b2 * iw3 / iw
            wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                        a0*wp1.y + a1*wp2.y + a2*wp3.y,
                        a0*wp1.z + a1*wp2.z + a2*wp3.z)
            has_clip && (_clip_keep(clipping_planes, wp) || continue)
            (!has_uv_maps && alpha_base < alpha_test) && continue
            wn = normalize(Vec3(a0*wn1.x + a1*wn2.x + a2*wn3.x,
                                a0*wn1.y + a1*wn2.y + a2*wn3.y,
                                a0*wn1.z + a1*wn2.z + a2*wn3.z))
            vc = Color3(a0*vc1.r + a1*vc2.r + a2*vc3.r,
                        a0*vc1.g + a1*vc2.g + a2*vc3.g,
                        a0*vc1.b + a1*vc2.b + a2*vc3.b)
            # Perspective-correct UV, computed only when a map is active so the
            # no-map path keeps its original per-pixel cost.
            if has_uv_maps
                u = a0*uv1.x + a1*uv2.x + a2*uv3.x
                v = a0*uv1.y + a1*uv2.y + a2*uv3.y
                u2 = a0*uv2_1.x + a1*uv2_2.x + a2*uv2_3.x
                v2 = a0*uv2_1.y + a1*uv2_2.y + a2*uv2_3.y
                frag_alpha = _fragment_alpha(alpha_base, albedo_map, alpha_map, u, v, u2, v2)
                frag_alpha >= alpha_test || continue
                # normalMap perturbs the shading normal before lighting (same
                # helper as the flat path); the tangent frame uses the UV set
                # selected by the texture metadata.
                if has_normalmap
                    nu, nv = _map_uv(normal_map, u, v, u2, v2)
                    normal_uvs = _texture_uv_set(normal_map) == 1 ?
                        ((uv2_1.x, uv2_1.y), (uv2_2.x, uv2_2.y), (uv2_3.x, uv2_3.y)) :
                        ((uv1.x, uv1.y), (uv2.x, uv2.y), (uv3.x, uv3.y))
                    wn = _apply_normal_map(wn, normal_map, nu, nv, wp1, wp2, wp3,
                                           normal_uvs[1], normal_uvs[2], normal_uvs[3],
                                           normal_scale)
                end
                if has_specular || has_glossiness
                    eff_mat = _apply_phong_maps(material, specular_map, glossiness_map,
                                                u, v, u2, v2)
                elseif has_roughness || has_metalness || has_physical_pbr
                    eff_mat = _apply_pbr_maps(material, roughness_map, metalness_map, u, v, u2, v2)
                else
                    eff_mat = material
                end
                vd = normalize(cam_pos - wp)
                col = shade_face(wn, vd, wp, _with_vertex_color(eff_mat, vc), lights; shadow_fn=shadow_fn)
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
                if has_albedo
                    tu, tv = _map_uv(albedo_map, u, v, u2, v2)
                    col = col * sample_texture_linear(albedo_map, tu, tv)
                end
                if has_ao
                    tu, tv = _map_uv(ao_map, u, v, u2, v2; default_uv2=true)
                    ao = sample_texture(ao_map, tu, tv)
                    aoi = _material_scalar(material, :ao_map_intensity)
                    aor = 1.0 + (ao.r - 1.0) * aoi
                    aog = 1.0 + (ao.g - 1.0) * aoi
                    aob = 1.0 + (ao.b - 1.0) * aoi
                    col = Color3(col.r * aor, col.g * aog, col.b * aob)
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
            else
                vd = normalize(cam_pos - wp)
                col = shade_face(wn, vd, wp, _with_vertex_color(material, vc), lights; shadow_fn=shadow_fn)
            end
            col = clamp_color(col)
            if use_stamp
                # Transparent smooth pass: source-over blend, gated once per mesh.
                ia = 1.0 - frag_alpha
                rt.color[py, px, 1] = col.r * frag_alpha + rt.color[py, px, 1] * ia
                rt.color[py, px, 2] = col.g * frag_alpha + rt.color[py, px, 2] * ia
                rt.color[py, px, 3] = col.b * frag_alpha + rt.color[py, px, 3] * ia
                depth_write && (rt.depth[py, px] = z)
                stamp[py, px] = stamp_id
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

function _render_smooth!(rt::RenderTarget, meshes, lights, proj, view, near, cam_pos, shadow_fn=nothing;
                         clipping_planes=_NO_PLANES,
                         xlo::Int=1, xhi::Int=typemax(Int), ylo::Int=1, yhi::Int=typemax(Int),
                         log_depth::Bool=false, inv_log_far::Float64=1.0, ortho_dir=nothing,
                         stamp=nothing, stamp_id::Int=0)
    W, H = rt.width, rt.height
    tri = Vector{ShadeVtx}(undef, 3)
    clipped = ShadeVtx[]; sizehint!(clipped, 6)
    sx = Vector{Float64}(undef, 8); sy = Vector{Float64}(undef, 8)
    sz = Vector{Float64}(undef, 8); iw = Vector{Float64}(undef, 8)
    for mesh in meshes
        !is_visible(mesh) && continue
        mesh_shadow_fn = object_receives_shadow(mesh) ? shadow_fn : nothing
        world_mat = compute_world_matrix(mesh)
        modelview = view * world_mat
        normal_mat = mat4_transpose(mat4_inverse(world_mat))
        geo = mesh.geometry
        mat = mesh.material
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
        uv2_attr = _uv2_attribute(geo)
        color_attr = (_wants_vertex_colors(mat) && has_attribute(geo, :color)) ?
                     get_attribute(geo, :color) : nothing
        use_vertex_colors = color_attr !== nothing && color_attr.item_size >= 3 &&
                            length(color_attr.data) >= geo.n_vertices * color_attr.item_size
        for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            if side !== :double
                w1 = mat4_transform_point(world_mat, get_vertex(geo, i1))
                w2 = mat4_transform_point(world_mat, get_vertex(geo, i2))
                w3 = mat4_transform_point(world_mat, get_vertex(geo, i3))
                wc = Vec3((w1.x+w2.x+w3.x)/3, (w1.y+w2.y+w3.y)/3, (w1.z+w2.z+w3.z)/3)
                fn = _flat_face_normal(geo, i1, i2, i3, w1, w2, w3, normal_mat, has_normals)
                # Orthographic rays are parallel, so facing is judged against the
                # constant view direction; the eye-point vector is perspective-only.
                facing = ortho_dir === nothing ? dot(fn, cam_pos - wc) : dot(fn, ortho_dir)
                (side === :front ? facing <= 0 : facing > 0) && continue
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
            @inbounds for (slot, vi) in ((1, i1), (2, i2), (3, i3))
                v = get_vertex(geo, vi)
                nrm = has_normals ? get_normal(geo, vi) : fallback_n
                wp = mat4_transform_point(world_mat, v)
                wn = mat4_transform_direction(normal_mat, nrm)
                vp = mat4_transform_vec4(modelview, Vec4(v.x, v.y, v.z, 1.0))
                uv = has_uvs ? Vec2(geo.uvs[(vi-1)*2+1], geo.uvs[(vi-1)*2+2]) : Vec2(0.0, 0.0)
                uv2 = uv2_attr === nothing ? uv : Vec2(_vertex_uv_attr(uv2_attr, vi)...)
                vc = use_vertex_colors ? _vertex_color(color_attr, vi) : Color3(1.0, 1.0, 1.0)
                tri[slot] = ShadeVtx(vp, wp, wn, uv, uv2, vc)
            end
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
                _rasterize_tri_smooth!(rt,
                    sx[1], sy[1], sz[1], iw[1], clipped[1].wp, clipped[1].wn, clipped[1].uv, clipped[1].uv2, clipped[1].vc,
                    sx[k], sy[k], sz[k], iw[k], clipped[k].wp, clipped[k].wn, clipped[k].uv, clipped[k].uv2, clipped[k].vc,
                    sx[k+1], sy[k+1], sz[k+1], iw[k+1], clipped[k+1].wp, clipped[k+1].wn, clipped[k+1].uv, clipped[k+1].uv2, clipped[k+1].vc,
                    mat, lights, cam_pos, mesh_shadow_fn, albedo_map, alpha_map,
                    normal_map, roughness_map, metalness_map, specular_map,
                    glossiness_map, physical_pbr_map,
                    ao_map, emissive_map, light_map, normal_scale, mesh_clipping_planes;
                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                    depth_test=depth_test, depth_write=depth_write,
                    stamp=stamp, stamp_id=stamp_id)
            end
        end
    end
    return rt
end

"""
    render!(rt, scene, camera; shading=:flat)

Render a scene with a camera into a RenderTarget using CPU rasterization.

Triangles are transformed to view space, clipped against the camera near plane
(so geometry straddling the camera renders its visible portion instead of
vanishing), then projected and rasterized with a z-buffer. Scratch buffers are
reused across faces to keep per-frame allocation bounded.

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
the clip-space w, i.e. the positive view distance) instead of NDC z. The encoding
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
function render!(rt::RenderTarget, scene::Scene, camera::AbstractCamera;
                 shading::Symbol=:flat, shadows::Bool=false, shadow_resolution::Int=512,
                 frustum_cull::Bool=true, clipping_planes::AbstractVector{<:Plane}=_NO_PLANES,
                 scissor::Union{Nothing,NTuple{4,Int}}=nothing, scissor_test::Bool=false,
                 sort_objects::Bool=true, logarithmic_depth::Bool=false,
                 cache=nothing)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
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
    # Precompute 1/log2(far+1) once per frame for the logarithmic depth encoding.
    inv_log_far = log_depth ? 1.0 / log2(far + 1.0) : 1.0

    # Orthographic cameras project along a constant direction, so back-face
    # culling must test against that direction (the camera's backward axis)
    # rather than the eye-point vector `cam_pos - wc`, which is exact only for
    # perspective projection. `nothing` selects the perspective test.
    ortho_dir = camera isa OrthographicCamera ?
        normalize(camera.position - camera.target) : nothing

    if cache === nothing
        meshes = collect_meshes(scene)
        lights = collect_lights(scene)
    else
        # `collect_lights` prunes invisible subtrees; the cached traversal does
        # not, so apply the same hierarchical visibility filter here (meshes are
        # filtered per object in the classify loop below).
        meshes = _collect_into!(cache.meshes, scene, m -> m isa Mesh)
        lights = _collect_into!(cache.lights, scene, l -> l isa AbstractLight && _visible_in_tree(l))
    end
    _append_skinned_render_meshes!(meshes, scene)
    shadow_fn = shadows ? _build_shadow_query(scene, lights; resolution=shadow_resolution,
                                              clipping_planes=clipping_planes) : nothing

    # View-projection frustum for culling whole meshes that fall offscreen.
    frustum = frustum_cull ? frustum_from_matrix(proj * view) : nothing

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
    colorbuf = cache === nothing ? nothing : cache.colors

    # Opaque pass first (writes the depth buffer). Per-mesh shading mode honours
    # the mesh's `flat_shading` override, else the renderer default. Opaque meshes
    # are collected (not drawn inline) so they can optionally be drawn front-to-
    # back; the z-buffer keeps opaque output order-independent, so this affects
    # only overdraw work, never the final pixels.
    if cache === nothing
        transparent = Mesh[]
        opaque_flat = Mesh[]
        smooth_meshes = Mesh[]
    else
        transparent = cache.transparent
        opaque_flat = cache.opaque_flat
        smooth_meshes = cache.smooth_meshes
        empty!(transparent)
        empty!(opaque_flat)
        empty!(smooth_meshes)
    end
    wireframe_meshes = Mesh[]
    for mesh in meshes
        !_visible_in_tree(mesh) && continue
        wm = compute_world_matrix(mesh)
        (frustum === nothing || _mesh_in_frustum(frustum, mesh.geometry, wm)) || continue
        if material_wireframe(mesh.material)
            push!(wireframe_meshes, mesh)
        elseif is_transparent_material(mesh.material)
            push!(transparent, mesh)
        elseif _mesh_is_flat(mesh, shading)
            push!(opaque_flat, mesh)
        else
            push!(smooth_meshes, mesh)
        end
    end

    # Front-to-back draw order for opaque meshes (nearest first = largest, least-
    # negative view-space z). Pure draw-order optimisation; pixels are unchanged.
    if sort_objects
        _sort_meshes_by_depth!(opaque_flat, view, true)
        _sort_meshes_by_depth!(smooth_meshes, view, true)
    end

    for mesh in opaque_flat
        mesh_shadow_fn = object_receives_shadow(mesh) ? shadow_fn : nothing
        mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                         material_clipping_planes(mesh.material))
        _rasterize_geo_flat!(rt, mesh.geometry, compute_world_matrix(mesh), mesh.material,
                             lights, proj, view, near, camera.position, tri, clipped, sx, sy, sz;
                             shadow_fn=mesh_shadow_fn, clipping_planes=mesh_clipping_planes,
                             colorbuf=colorbuf,
                             xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                             log_depth=log_depth, inv_log_far=inv_log_far, ortho_dir=ortho_dir)
    end

    # InstancedMesh: same geometry/material drawn at each instance transform (flat).
    instanced = cache === nothing ? collect_instanced(scene) :
                _collect_into!(cache.instanced, scene, o -> o isa InstancedMesh)
    for im in instanced
        !_visible_in_tree(im) && continue
        _instanced_triangle_drawable(im) || continue
        base = compute_world_matrix(im)
        for (instance_index, M) in enumerate(im.instance_matrices)
            world = base * M
            instance_material = _with_vertex_color(im.material, im.instance_colors[instance_index])
            if material_wireframe(im.material)
                _render_wireframe_mesh!(rt, im.geometry, instance_material, world, proj, view, near;
                                        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi)
            else
                mesh_shadow_fn = object_receives_shadow(im) ? shadow_fn : nothing
                mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                                 material_clipping_planes(instance_material))
                _rasterize_geo_flat!(rt, im.geometry, world, instance_material,
                                     lights, proj, view, near, camera.position, tri, clipped, sx, sy, sz;
                                     shadow_fn=mesh_shadow_fn, clipping_planes=mesh_clipping_planes,
                                     colorbuf=colorbuf,
                                     xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                     log_depth=log_depth, inv_log_far=inv_log_far, ortho_dir=ortho_dir)
            end
        end
    end

    # Smooth (per-pixel) opaque meshes share the same depth buffer.
    isempty(smooth_meshes) ||
        _render_smooth!(rt, smooth_meshes, lights, proj, view, near, camera.position, shadow_fn;
                        clipping_planes=clipping_planes,
                        xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                        log_depth=log_depth, inv_log_far=inv_log_far, ortho_dir=ortho_dir)

    # Transparent pass: back-to-front, z-tested against the current depth buffer
    # and alpha-blended over the existing colour. Depth writes follow the
    # material's `depth_write` field. The back-to-front order is required for
    # correct blending and is kept regardless of `sort_objects`.
    if !isempty(transparent)
        _sort_meshes_by_depth!(transparent, view, false)
        stamp = cache === nothing ? zeros(Int, H, W) : _render_cache_stamp!(cache, H, W)
        # `stamp` ensures each pixel blends at most once per mesh.
        sid = 0
        for mesh in transparent
            mesh_shadow_fn = object_receives_shadow(mesh) ? shadow_fn : nothing
            mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                             material_clipping_planes(mesh.material))
            sid += 1
            α = material_opacity(mesh.material)
            if _mesh_is_flat(mesh, shading)
                _rasterize_geo_flat!(rt, mesh.geometry, compute_world_matrix(mesh), mesh.material,
                                     lights, proj, view, near, camera.position, tri, clipped, sx, sy, sz;
                                     alpha=α, stamp=stamp, stamp_id=sid, shadow_fn=mesh_shadow_fn,
                                     clipping_planes=mesh_clipping_planes,
                                     colorbuf=colorbuf,
                                     xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                     log_depth=log_depth, inv_log_far=inv_log_far, ortho_dir=ortho_dir)
            else
                # Smooth-shaded transparent mesh: per-pixel interpolated normals with
                # source-over blending (the same stamp guards against double-blend),
                # instead of being silently flattened.
                _render_smooth!(rt, (mesh,), lights, proj, view, near, camera.position, shadow_fn;
                                clipping_planes=clipping_planes,
                                xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                log_depth=log_depth, inv_log_far=inv_log_far, ortho_dir=ortho_dir,
                                stamp=stamp, stamp_id=sid)
            end
        end
    end

    # Camera-facing sprites (billboards), depth-tested against the mesh passes.
    render_sprites!(rt, scene, camera; clipping_planes=clipping_planes,
                    xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi)

    for mesh in wireframe_meshes
        _render_wireframe_mesh!(rt, mesh.geometry, mesh.material, compute_world_matrix(mesh),
                                proj, view, near; xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi)
    end

    # Line and point primitives (depth-tested against the mesh passes).
    render_lines!(rt, scene, camera; xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi)
    render_points!(rt, scene, camera; xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi)

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
        sx < rt.width && sy < rt.height && sx + sw > 0 && sy + sh > 0 || continue
        render!(rt, scene, subcamera; kwargs..., scissor=view_scissor, scissor_test=true)
    end
    return rt
end

# World-space bounding sphere of a geometry placed by `world_mat`, then tested
# against the frustum. The sphere centre is the geometry centre transformed to
# world; the radius scales by the largest axis scale extracted from `world_mat`
# (a conservative bound for non-uniform scale that never culls a visible mesh).
@inline function _mesh_in_frustum(frustum::Frustum, geo, world_mat::Mat4)
    bs = compute_bounding_sphere(geo)
    bs.radius == 0 && geo.n_vertices == 0 && return false
    center = mat4_transform_point(world_mat, bs.center)
    # Column lengths of the upper-left 3×3 give the per-axis scale factors.
    cx = sqrt(mat4_get(world_mat,1,1)^2 + mat4_get(world_mat,2,1)^2 + mat4_get(world_mat,3,1)^2)
    cy = sqrt(mat4_get(world_mat,1,2)^2 + mat4_get(world_mat,2,2)^2 + mat4_get(world_mat,3,2)^2)
    cz = sqrt(mat4_get(world_mat,1,3)^2 + mat4_get(world_mat,2,3)^2 + mat4_get(world_mat,3,3)^2)
    r = bs.radius * max(cx, cy, cz)
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
material_side(m::AbstractMaterial) = hasfield(typeof(m), :side) ? getfield(m, :side) : :front

# View-space z of a mesh's world origin (more negative = farther from camera).
function _mesh_view_depth(mesh, view::Mat4)
    w = compute_world_matrix(mesh)
    o = mat4_transform_point(w, Vec3(0.0, 0.0, 0.0))
    v = mat4_transform_vec4(view, Vec4(o.x, o.y, o.z, 1.0))
    return v.z
end

struct _MeshDepthOrder{T<:Real}
    view::Mat4{T}
    nearest_first::Bool
end

function (order::_MeshDepthOrder)(a, b)
    da = _mesh_view_depth(a, order.view)
    db = _mesh_view_depth(b, order.view)
    return order.nearest_first ? da > db : da < db
end

function _sort_meshes_by_depth!(meshes::Vector{Mesh}, view::Mat4, nearest_first::Bool)
    n = length(meshes)
    n <= 1 && return meshes
    if n <= 32
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
    else
        sort!(meshes, lt=_MeshDepthOrder(view, nearest_first))
    end
    return meshes
end

# Material transparency helpers (some materials lack these fields).
material_opacity(m::AbstractMaterial) = hasfield(typeof(m), :opacity) ? getfield(m, :opacity) : 1.0
material_transparent(m::AbstractMaterial) = hasfield(typeof(m), :transparent) ? getfield(m, :transparent) : false
is_transparent_material(m::AbstractMaterial) = material_transparent(m)
material_depth_test(m::AbstractMaterial) = hasfield(typeof(m), :depth_test) ? getfield(m, :depth_test) : true
material_depth_write(m::AbstractMaterial) = hasfield(typeof(m), :depth_write) ? getfield(m, :depth_write) : true
material_alpha_test(m::AbstractMaterial) = hasfield(typeof(m), :alpha_test) ? Float64(getfield(m, :alpha_test)) : 0.0
material_wireframe(m::AbstractMaterial) = hasfield(typeof(m), :wireframe) ? getfield(m, :wireframe) : false
material_clipping_planes(m::AbstractMaterial) =
    hasfield(typeof(m), :clipping_planes) ? getfield(m, :clipping_planes) : _NO_PLANES

function _combined_clipping_planes(global_planes, material_planes)
    isempty(material_planes) && return global_planes
    isempty(global_planes) && return material_planes
    return Plane{Float64}[global_planes...; material_planes...]
end

@inline _has_texture_alpha(tex) = tex isa Texture && size(tex.data, 3) >= 4
@inline _has_alpha_map(tex) = tex isa Texture
@inline _needs_fragment_alpha(alpha_test::Float64, alpha_base::Float64, albedo_map, alpha_map) =
    alpha_test > 0.0 || alpha_base < 1.0 || _has_texture_alpha(albedo_map) || _has_alpha_map(alpha_map)

@inline function _fragment_alpha(alpha_base::Float64, albedo_map, alpha_map, u, v, u2, v2)
    a = alpha_base
    if _has_texture_alpha(albedo_map)
        tu, tv = _map_uv(albedo_map, u, v, u2, v2)
        a *= sample_texture_channel(albedo_map, tu, tv, 4; default=1.0)
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
                              ortho_dir=nothing)
    W, H = rt.width, rt.height
    modelview = view * world_mat
    face_colors = colorbuf === nothing ?
        shade_mesh_faces(geo, world_mat, mat, lights, cam_pos; shadow_fn=shadow_fn) :
        shade_mesh_faces!(colorbuf, geo, world_mat, mat, lights, cam_pos; shadow_fn=shadow_fn)
    blend = material_transparent(mat) || alpha < 1.0
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    side = material_side(mat)
    normal_mat = side === :double ? world_mat : mat4_transpose(mat4_inverse(world_mat))
    has_normals = length(geo.normals) >= geo.n_vertices * 3
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    albedo_map = has_uvs ? _material_field(mat, :map) : nothing
    alpha_map = has_uvs ? _material_field(mat, :alpha_map) : nothing
    alpha_test = material_alpha_test(mat)
    alpha_base = Float64(alpha)
    use_fragment_alpha = _needs_fragment_alpha(alpha_test, alpha_base, albedo_map, alpha_map)
    uv2_attr = use_fragment_alpha ? _uv2_attribute(geo) : nothing
    attr_tri = use_fragment_alpha ? Vector{ShadeVtx}(undef, 3) : ShadeVtx[]
    attr_clipped = use_fragment_alpha ? ShadeVtx[] : ShadeVtx[]
    use_fragment_alpha && sizehint!(attr_clipped, 6)
    siw = use_fragment_alpha ? Vector{Float64}(undef, 8) : Float64[]
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
            wc = mat4_transform_point(world_mat, Vec3((v1.x+v2.x+v3.x)/3, (v1.y+v2.y+v3.y)/3, (v1.z+v2.z+v3.z)/3))
            fn = _flat_face_normal(geo, i1, i2, i3,
                                   mat4_transform_point(world_mat, v1),
                                   mat4_transform_point(world_mat, v2),
                                   mat4_transform_point(world_mat, v3), normal_mat, has_normals)
            # Orthographic rays are parallel, so facing is judged against the
            # constant view direction; the eye-point vector is perspective-only.
            facing = ortho_dir === nothing ? dot(fn, cam_pos - wc) : dot(fn, ortho_dir)
            (side === :front ? facing <= 0 : facing > 0) && continue
        end
        tri[1] = mat4_transform_vec4(modelview, Vec4(v1.x, v1.y, v1.z, 1.0))
        tri[2] = mat4_transform_vec4(modelview, Vec4(v2.x, v2.y, v2.z, 1.0))
        tri[3] = mat4_transform_vec4(modelview, Vec4(v3.x, v3.y, v3.z, 1.0))

        if use_fragment_alpha
            @inbounds for (slot, vi, vtx) in ((1, i1, v1), (2, i2, v2), (3, i3, v3))
                uv = has_uvs ? Vec2(geo.uvs[(vi-1)*2+1], geo.uvs[(vi-1)*2+2]) : _ZERO_V2
                uv2v = uv2_attr === nothing ? uv : Vec2(_vertex_uv_attr(uv2_attr, vi)...)
                attr_tri[slot] = ShadeVtx(
                    tri[slot],
                    mat4_transform_point(world_mat, vtx),
                    _ZERO_V3,
                    uv,
                    uv2v,
                    Color3(1.0, 1.0, 1.0),
                )
            end

            m = _clip_near_attr!(attr_clipped, attr_tri, 3, near)
            m < 3 && continue

            @inbounds for k in 1:m
                cv = mat4_transform_vec4(proj, attr_clipped[k].vp)
                invw = 1.0 / cv.w
                ndcx = cv.x * invw; ndcy = cv.y * invw; ndcz = cv.z * invw
                sx[k] = (ndcx + 1) * 0.5 * W
                sy[k] = (1 - ndcy) * 0.5 * H
                sz[k] = log_depth ? _encode_log_depth(cv.w, inv_log_far) : ndcz
                siw[k] = invw
            end

            fc = face_colors[fi]
            @inbounds for k in 2:(m - 1)
                if blend
                    _rasterize_tri_blend!(rt, sx[1], sy[1], sz[1],
                                          sx[k], sy[k], sz[k],
                                          sx[k+1], sy[k+1], sz[k+1], fc, alpha, stamp, stamp_id;
                                          xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                          clipping_planes=clipping_planes,
                                          wp1=attr_clipped[1].wp,
                                          wp2=attr_clipped[k].wp,
                                          wp3=attr_clipped[k+1].wp,
                                          iw1=siw[1], iw2=siw[k], iw3=siw[k+1],
                                          depth_test=depth_test, depth_write=depth_write,
                                          alpha_test=alpha_test, albedo_map=albedo_map, alpha_map=alpha_map,
                                          uv1=attr_clipped[1].uv,
                                          uv2=attr_clipped[k].uv,
                                          uv3=attr_clipped[k+1].uv,
                                          uv2_1=attr_clipped[1].uv2,
                                          uv2_2=attr_clipped[k].uv2,
                                          uv2_3=attr_clipped[k+1].uv2)
                else
                    _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                    sx[k], sy[k], sz[k],
                                    sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                    xlo=xlo, xhi=xhi,
                                    clipping_planes=clipping_planes,
                                    wp1=attr_clipped[1].wp,
                                    wp2=attr_clipped[k].wp,
                                    wp3=attr_clipped[k+1].wp,
                                    iw1=siw[1], iw2=siw[k], iw3=siw[k+1],
                                    depth_test=depth_test, depth_write=depth_write,
                                    alpha_test=alpha_test, alpha_base=alpha_base,
                                    albedo_map=albedo_map, alpha_map=alpha_map,
                                    uv1=attr_clipped[1].uv,
                                    uv2=attr_clipped[k].uv,
                                    uv3=attr_clipped[k+1].uv,
                                    uv2_1=attr_clipped[1].uv2,
                                    uv2_2=attr_clipped[k].uv2,
                                    uv2_3=attr_clipped[k+1].uv2)
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

        fc = face_colors[fi]
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
                                      sx[k+1], sy[k+1], sz[k+1], fc, alpha, stamp, stamp_id;
                                      xlo=xlo, xhi=xhi, ylo=ylo, yhi=yhi,
                                      clipping_planes=clipping_planes, wp1=wp1, wp2=wp2, wp3=wp3,
                                      iw1=iw1, iw2=iw2, iw3=iw3,
                                      depth_test=depth_test, depth_write=depth_write)
            elseif has_clip
                _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                sx[k], sy[k], sz[k],
                                sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                xlo=xlo, xhi=xhi,
                                clipping_planes=clipping_planes, wp1=wp1, wp2=wp2, wp3=wp3,
                                iw1=iw1, iw2=iw2, iw3=iw3,
                                depth_test=depth_test, depth_write=depth_write)
            else
                _rasterize_tri!(rt, sx[1], sy[1], sz[1],
                                sx[k], sy[k], sz[k],
                                sx[k+1], sy[k+1], sz[k+1], fc, ylo, yhi;
                                xlo=xlo, xhi=xhi,
                                depth_test=depth_test, depth_write=depth_write)
            end
        end
    end
    return nothing
end

# Alpha-blend a triangle over the existing colour, optionally z-tested and
# optionally writing depth according to the material flags. `xlo`/`xhi`/`ylo`/
# `yhi` clamp the covered pixel box so scissor testing restricts the blend.
# When `clipping_planes` is non-empty, fragments on the negative side of any
# plane are discarded (same `_clip_keep` test as `_rasterize_tri!`) before the
# stamp is consulted or written, so clipped fragments neither blend nor stamp.
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
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1, xlo)
    max_x = min(ceil(Int, clamp(max(s1x, s2x, s3x), 1.0, fW)), W, xhi)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1, ylo)
    max_y = min(ceil(Int, clamp(max(s1y, s2y, s3y), 1.0, fH)), H, yhi)
    use_stamp = stamp !== nothing
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, Float64(alpha), albedo_map, alpha_map)
    @inbounds for py in min_y:max_y
        for px in min_x:max_x
            cx = px - 0.5; cy = py - 0.5
            w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            if w0 >= 0 && w1 >= 0 && w2 >= 0
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
                # Skip pixels already blended by this same mesh (shared edges).
                use_stamp && stamp[py, px] == stamp_id && continue
                z = w0 * z1 + w1 * z2 + w2 * z3
                if !depth_test || z < rt.depth[py, px]
                    ia_frag = 1.0 - frag_alpha
                    rt.color[py, px, 1] = fc.r * frag_alpha + rt.color[py, px, 1] * ia_frag
                    rt.color[py, px, 2] = fc.g * frag_alpha + rt.color[py, px, 2] * ia_frag
                    rt.color[py, px, 3] = fc.b * frag_alpha + rt.color[py, px, 3] * ia_frag
                    depth_write && (rt.depth[py, px] = z)
                    use_stamp && (stamp[py, px] = stamp_id)
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
