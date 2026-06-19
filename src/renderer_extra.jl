# --------------------------------------------------------------------------
# Renderer extras: tone mapping + sRGB output encoding, supersample anti-
# aliasing, line/point rasterization, a small post-processing EffectComposer,
# and a tiled (optionally threaded) rasterizer.
# --------------------------------------------------------------------------

# ========================== Tone mapping / sRGB ==========================

"""Reinhard tone map `c/(1+c)`, mapping HDR radiance into [0,1)."""
function tone_map_reinhard(img::AbstractArray)
    out = Array{Float64}(undef, size(img))
    @inbounds for i in eachindex(img)
        c = Float64(img[i]); out[i] = c / (1 + c)
    end
    return out
end

"""ACES filmic tone map (Narkowicz approximation)."""
function tone_map_aces(img::AbstractArray)
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    out = Array{Float64}(undef, size(img))
    @inbounds for i in eachindex(img)
        x = Float64(img[i])
        out[i] = clamp((x * (a*x + b)) / (x * (c*x + d) + e), 0.0, 1.0)
    end
    return out
end

linear_to_srgb(c) = c <= 0.0031308 ? 12.92*c : 1.055*c^(1/2.4) - 0.055
srgb_to_linear(c) = c <= 0.04045 ? c/12.92 : ((c + 0.055)/1.055)^2.4

"""Encode a linear-light image to sRGB for display/output."""
function srgb_encode(img::AbstractArray)
    out = Array{Float64}(undef, size(img))
    @inbounds for i in eachindex(img)
        out[i] = clamp(linear_to_srgb(clamp(Float64(img[i]), 0.0, 1.0)), 0.0, 1.0)
    end
    return out
end

# ========================== Supersample (MSAA) ==========================

"""Box-average downsample an H·ss × W·ss image to H × W."""
function downsample(img::AbstractArray, ss::Int)
    Hb, Wb, _ = size(img)
    H, W = Hb ÷ ss, Wb ÷ ss
    out = zeros(Float64, H, W, 3)
    inv = 1.0 / (ss * ss)
    @inbounds for c in 1:3, i in 1:H, j in 1:W
        s = 0.0
        for di in 0:ss-1, dj in 0:ss-1
            s += img[(i-1)*ss + di + 1, (j-1)*ss + dj + 1, c]
        end
        out[i, j, c] = s * inv
    end
    return out
end

"""Render at `ss`× resolution and box-downsample — supersampled anti-aliasing."""
function render_aa(scene::Scene, camera::AbstractCamera, width::Int, height::Int;
                   ss::Int=2, shading::Symbol=:flat, shadows::Bool=false)
    rt = RenderTarget(width*ss, height*ss)
    render!(rt, scene, camera; shading=shading, shadows=shadows)
    return downsample(rt.color, ss)
end

"""
    render_msaa!(rt, scene, camera; samples=4, shading=:flat, shadows=false)

In-renderer multisample anti-aliasing: render an internal ⌈√samples⌉× target and
box-downsample into `rt.color`. Unlike `render_aa` (which returns an array), this
fills the supplied `RenderTarget`, so the renderer itself yields an AA frame.
"""
function render_msaa!(rt::RenderTarget, scene::Scene, camera::AbstractCamera;
                      samples::Int=4, shading::Symbol=:flat, shadows::Bool=false)
    ss = max(ceil(Int, sqrt(samples)), 1)
    big = RenderTarget(rt.width*ss, rt.height*ss)
    render!(big, scene, camera; shading=shading, shadows=shadows)
    rt.color .= downsample(big.color, ss)
    return rt
end

# ========================== Pooled rendering (bounded allocation) ==========================

"""
Reusable scratch buffers for the flat opaque path, so repeated frames allocate a
bounded amount (independent of frame count). Mesh/light lists and the per-face
colour buffer are reused via [`render_pooled!`].
"""
mutable struct RenderCache
    meshes::Vector{Mesh}
    lights::Vector{AbstractLight}
    instanced::Vector{InstancedMesh}
    transparent::Vector{Mesh}
    opaque_flat::Vector{Mesh}
    smooth_meshes::Vector{Mesh}
    tri::Vector{Vec4{Float64}}
    clipped::Vector{Vec4{Float64}}
    sx::Vector{Float64}
    sy::Vector{Float64}
    sz::Vector{Float64}
    colors::Vector{Color3{Float64}}
    stamp::Matrix{Int}
end
function RenderCache()
    cl = Vector{Vec4{Float64}}(undef, 0); sizehint!(cl, 6)
    RenderCache(Mesh[], AbstractLight[], InstancedMesh[],
                Mesh[], Mesh[], Mesh[],
                Vector{Vec4{Float64}}(undef, 3), cl,
                Vector{Float64}(undef, 8), Vector{Float64}(undef, 8), Vector{Float64}(undef, 8),
                Color3{Float64}[], zeros(Int, 0, 0))
end

function _render_cache_stamp!(cache::RenderCache, H::Int, W::Int)
    if size(cache.stamp) != (H, W)
        cache.stamp = zeros(Int, H, W)
    else
        fill!(cache.stamp, 0)
    end
    return cache.stamp
end

# Collect into a reused vector (clears then refills), avoiding per-frame allocation.
function _collect_into!(out::Vector, root, pred)
    empty!(out)
    traverse(root, o -> pred(o) && push!(out, o))
    return out
end

"""
    render_pooled!(rt, scene, camera, cache; shading=:flat)

Flat opaque meshes/instances are rasterized reusing `cache`'s buffers — the same
image as `render!` for opaque flat scenes, but with bounded per-frame allocation
across repeated calls. Transparent meshes, lines and points are skipped here.
"""
function render_pooled!(rt::RenderTarget, scene::Scene, camera::AbstractCamera,
                        cache::RenderCache; shading::Symbol=:flat)
    shading === :flat || throw(ArgumentError("render_pooled! supports only :flat shading"))
    clear!(rt, scene.background)
    proj = projection_matrix(camera); view = view_matrix(camera); near = _camera_near(camera)
    # Same orthographic back-face-culling direction as `render!`.
    ortho_dir = camera isa OrthographicCamera ?
        normalize(camera.position - camera.target) : nothing
    # `_collect_into!` traverses without pruning invisible subtrees, so apply
    # the hierarchical visibility test (three.js semantics) per object here.
    _collect_into!(cache.meshes, scene, m -> m isa Mesh)
    _append_skinned_render_meshes!(cache.meshes, scene)
    _collect_into!(cache.lights, scene, l -> l isa AbstractLight && _visible_in_tree(l))
    _collect_into!(cache.instanced, scene, o -> o isa InstancedMesh)
    for mesh in cache.meshes
        (_visible_in_tree(mesh) && !is_transparent_material(mesh.material) &&
         !material_wireframe(mesh.material)) || continue
        _rasterize_geo_flat!(rt, mesh.geometry, compute_world_matrix(mesh), mesh.material,
                             cache.lights, proj, view, near, camera.position,
                             cache.tri, cache.clipped, cache.sx, cache.sy, cache.sz;
                             colorbuf=cache.colors, ortho_dir=ortho_dir)
    end
    for im in cache.instanced
        (_visible_in_tree(im) && !material_wireframe(im.material)) || continue
        base = compute_world_matrix(im)
        for M in im.instance_matrices
            _rasterize_geo_flat!(rt, im.geometry, base * M, im.material,
                                 cache.lights, proj, view, near, camera.position,
                                 cache.tri, cache.clipped, cache.sx, cache.sy, cache.sz;
                                 colorbuf=cache.colors, ortho_dir=ortho_dir)
        end
    end
    return rt
end

# ========================== Line / point rasterization ==========================

@inline function _put_pixel!(rt::RenderTarget, x::Int, y::Int, z, col::Color3,
                             xlo::Int=1, xhi::Int=rt.width,
                             ylo::Int=1, yhi::Int=rt.height,
                             depth_test::Bool=true, depth_write::Bool=true,
                             alpha::Float64=1.0)
    (1 <= x <= rt.width && 1 <= y <= rt.height && xlo <= x <= xhi && ylo <= y <= yhi) || return false
    @inbounds if !depth_test || z < rt.depth[y, x]
        depth_write && (rt.depth[y, x] = z)
        if alpha >= 1.0
            rt.color[y, x, 1] = col.r; rt.color[y, x, 2] = col.g; rt.color[y, x, 3] = col.b
        elseif alpha > 0.0
            ia = 1.0 - alpha
            rt.color[y, x, 1] = col.r * alpha + rt.color[y, x, 1] * ia
            rt.color[y, x, 2] = col.g * alpha + rt.color[y, x, 2] * ia
            rt.color[y, x, 3] = col.b * alpha + rt.color[y, x, 3] * ia
        end
        return true
    end
    return false
end

@inline function _put_stamped_pixel!(rt::RenderTarget, x::Int, y::Int, z, col::Color3,
                                     xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                     depth_test::Bool, depth_write::Bool,
                                     alpha::Float64, stamp, stamp_id::Int)
    if stamp !== nothing &&
       1 <= x <= rt.width && 1 <= y <= rt.height && xlo <= x <= xhi && ylo <= y <= yhi &&
       stamp[y, x] == stamp_id
        return false
    end
    wrote = _put_pixel!(rt, x, y, z, col, xlo, xhi, ylo, yhi, depth_test, depth_write, alpha)
    wrote && stamp !== nothing && (stamp[y, x] = stamp_id)
    return wrote
end

@inline function _put_line_pixel!(rt::RenderTarget, x::Int, y::Int, z, col::Color3,
                                  radius::Float64,
                                  xlo::Int=1, xhi::Int=rt.width,
                                  ylo::Int=1, yhi::Int=rt.height,
                                  depth_test::Bool=true, depth_write::Bool=true,
                                  alpha::Float64=1.0,
                                  stamp=nothing, stamp_id::Int=0)
    if radius <= 0.5
        _put_stamped_pixel!(rt, x, y, z, col, xlo, xhi, ylo, yhi,
                            depth_test, depth_write, alpha, stamp, stamp_id)
        return nothing
    end
    r = ceil(Int, radius)
    r2 = radius * radius
    @inbounds for oy in -r:r, ox in -r:r
        ox * ox + oy * oy <= r2 &&
            _put_stamped_pixel!(rt, x + ox, y + oy, z, col, xlo, xhi, ylo, yhi,
                                depth_test, depth_write, alpha, stamp, stamp_id)
    end
    return nothing
end

# DDA line with depth interpolation and z-test.
function _draw_line!(rt::RenderTarget, x0, y0, z0, x1, y1, z1, col::Color3,
                     linewidth::Real=1.0,
                     xlo::Int=1, xhi::Int=rt.width,
                     ylo::Int=1, yhi::Int=rt.height,
                     depth_test::Bool=true, depth_write::Bool=true,
                     alpha::Float64=1.0,
                     stamp=nothing, stamp_id::Int=0)
    dx = x1 - x0; dy = y1 - y0
    n = max(ceil(Int, max(abs(dx), abs(dy))), 1)
    radius = max(0.5, Float64(linewidth) / 2)
    @inbounds for s in 0:n
        t = s / n
        _put_line_pixel!(rt, round(Int, x0 + dx*t), round(Int, y0 + dy*t),
                         z0 + (z1 - z0)*t, col, radius, xlo, xhi, ylo, yhi,
                         depth_test, depth_write, alpha, stamp, stamp_id)
    end
    return nothing
end

# Project a world point; returns (sx, sy, ndcz, ok) — ok=false if behind the camera.
@inline function _project(vp::Mat4, p::Vec3, W, H)
    c = mat4_transform_vec4(vp, Vec4(p.x, p.y, p.z, 1.0))
    c.w <= 1e-6 && return (0.0, 0.0, 0.0, false)
    iw = 1.0 / c.w
    ((c.x*iw + 1)*0.5*W, (1 - c.y*iw)*0.5*H, c.z*iw, true)
end

# Clip a world-space segment against the view-space near plane (z ≤ -near,
# matching the mesh path's `_clip_near!`), then project and rasterize it.
# Segments straddling the plane are shortened instead of dropped, and clipped
# endpoints keep NDC z ≥ -1, bounding the DDA step count.
function _draw_segment_near_clipped!(rt::RenderTarget, proj::Mat4, view::Mat4, near,
                                     a::Vec3, b::Vec3, col::Color3, linewidth::Real,
                                     xlo::Int, xhi::Int, ylo::Int, yhi::Int,
                                     depth_test::Bool=true, depth_write::Bool=true,
                                     alpha::Float64=1.0,
                                     stamp=nothing, stamp_id::Int=0)
    av = mat4_transform_point(view, a)
    bv = mat4_transform_point(view, b)
    a_in = av.z <= -near; b_in = bv.z <= -near
    (a_in || b_in) || return nothing
    if a_in != b_in
        t = (-near - av.z) / (bv.z - av.z)
        c = Vec3(av.x + t*(bv.x - av.x), av.y + t*(bv.y - av.y), av.z + t*(bv.z - av.z))
        a_in ? (bv = c) : (av = c)
    end
    W, H = rt.width, rt.height
    (ax, ay, az, oka) = _project(proj, av, W, H)
    (bx, by, bz, okb) = _project(proj, bv, W, H)
    (oka && okb) && _draw_line!(rt, ax, ay, az, bx, by, bz, col, linewidth,
                                xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                stamp, stamp_id)
    return nothing
end

"""Rasterize `LineObject` strips, `LineLoop` closed strips, and `LineSegments` pairs."""
function render_lines!(rt::RenderTarget, scene::AbstractObject3D, camera::AbstractCamera;
                       xlo::Int=1, xhi::Int=rt.width,
                       ylo::Int=1, yhi::Int=rt.height)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
    near = _camera_near(camera)
    stamp = zeros(Int, rt.height, rt.width)
    stamp_id = 0

    function draw_line_geometry!(geo, material, wm::Mat4, line_mode::Symbol,
                                 morphed_positions=nothing)
        col = hasfield(typeof(material), :color) ? material.color : Color3(1.0,1.0,1.0)
        linewidth = hasfield(typeof(material), :linewidth) ? material.linewidth : 1.0
        alpha = clamp(Float64(material_opacity(material)), 0.0, 1.0)
        depth_test = material_depth_test(material)
        depth_write = material_depth_write(material)
        stride = line_mode === :lines ? 2 : 1
        nv = geo.n_vertices
        i = 1
        while i + 1 <= nv
            a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, i))
            b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, i+1))
            stamp_id += 1
            _draw_segment_near_clipped!(rt, proj, view, near, a, b, col, linewidth,
                                        xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                        stamp, stamp_id)
            i += stride
        end
        if line_mode === :line_loop && nv > 2
            a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, nv))
            b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, 1))
            stamp_id += 1
            _draw_segment_near_clipped!(rt, proj, view, near, a, b, col, linewidth,
                                        xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                        stamp, stamp_id)
        end
        return nothing
    end

    traverse(scene, function(obj)
        _visible_in_tree(obj) || return
        if obj isa LineObject || obj isa LineSegments || obj isa LineLoop
            line_mode = obj isa LineSegments ? :lines :
                        obj isa LineLoop ? :line_loop : :line_strip
            geo = obj.geometry
            morphed_positions = _object_morph_positions(obj, geo)
            draw_line_geometry!(geo, obj.material, compute_world_matrix(obj), line_mode,
                                morphed_positions)
        elseif obj isa InstancedMesh && _instanced_line_drawable(obj)
            base = compute_world_matrix(obj)
            for M in obj.instance_matrices
                draw_line_geometry!(obj.geometry, obj.material, base * M, obj.draw_mode)
            end
        end
    end)
    return rt
end

function _render_wireframe_mesh!(rt::RenderTarget, geo::BufferGeometry, mat::AbstractMaterial,
                                 world::Mat4, proj::Mat4, view::Mat4, near;
                                 xlo::Int=1, xhi::Int=rt.width,
                                 ylo::Int=1, yhi::Int=rt.height)
    line_geo = wireframe_geometry(geo)
    col = hasfield(typeof(mat), :color) ? mat.color : Color3(1.0, 1.0, 1.0)
    alpha = clamp(Float64(material_opacity(mat)), 0.0, 1.0)
    depth_test = material_depth_test(mat)
    depth_write = material_depth_write(mat)
    stamp = zeros(Int, rt.height, rt.width)
    stamp_id = 0
    i = 1
    while i + 1 <= line_geo.n_vertices
        a = mat4_transform_point(world, get_vertex(line_geo, i))
        b = mat4_transform_point(world, get_vertex(line_geo, i + 1))
        stamp_id += 1
        _draw_segment_near_clipped!(rt, proj, view, near, a, b, col, 1.0,
                                    xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
                                    stamp, stamp_id)
        i += 2
    end
    return nothing
end

# ========================== Sprite rasterization ==========================

# Camera-facing quad corner: project local (lx,ly) on the sprite plane through
# the sprite's screen-aligned world matrix, returning screen x/y, ndc z, 1/w and
# the world position (for clipping). `ok=false` if behind the near plane.
@inline function _sprite_corner(M::Mat4, vp::Mat4, lx, ly, W, H)
    wp = mat4_transform_point(M, Vec3(lx, ly, 0.0))
    c = mat4_transform_vec4(vp, Vec4(wp.x, wp.y, wp.z, 1.0))
    c.w <= 1e-6 && return (0.0, 0.0, 0.0, 0.0, wp, false)
    iw = 1.0 / c.w
    ((c.x*iw + 1)*0.5*W, (1 - c.y*iw)*0.5*H, c.z*iw, iw, wp, true)
end

# Rasterize one sprite quad triangle with z-test, optional albedo/alpha textures
# (perspective-correct UV), tint colour, and world-space clipping planes.
@inline function _rasterize_sprite_tri!(rt::RenderTarget,
        s1x, s1y, z1, iw1, u1, v1, wp1::Vec3,
        s2x, s2y, z2, iw2, u2, v2, wp2::Vec3,
        s3x, s3y, z3, iw3, u3, v3, wp3::Vec3,
        tint::Color3, tex, clipping_planes,
        xlo::Int, xhi::Int, ylo::Int, yhi::Int,
        depth_test::Bool=true, depth_write::Bool=true,
        alpha::Float64=1.0,
        alpha_test::Float64=0.0,
        alpha_map=nothing,
        stamp=nothing, stamp_id::Int=0)
    W, H = rt.width, rt.height
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-10 && return nothing
    inv_area = 1.0 / area
    min_x = max(floor(Int, min(s1x, s2x, s3x)), 1, xlo)
    max_x = min(ceil(Int, max(s1x, s2x, s3x)), W, xhi)
    min_y = max(floor(Int, min(s1y, s2y, s3y)), 1, ylo)
    max_y = min(ceil(Int, max(s1y, s2y, s3y)), H, yhi)
    (min_x <= max_x && min_y <= max_y) || return nothing
    has_tex = tex !== nothing
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, Float64(alpha), tex, alpha_map)
    needs_uv = has_tex || has_alpha
    @inbounds for py in min_y:max_y
        for px in min_x:max_x
            cx = px - 0.5; cy = py - 0.5
            b0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
            b1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
            b2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
            (b0 >= 0 && b1 >= 0 && b2 >= 0) || continue
            stamp !== nothing && stamp[py, px] == stamp_id && continue
            z = b0 * z1 + b1 * z2 + b2 * z3
            (!depth_test || z < rt.depth[py, px]) || continue
            a0 = b0; a1 = b1; a2 = b2
            if has_clip || needs_uv
                iw = b0*iw1 + b1*iw2 + b2*iw3
                a0 = b0*iw1/iw; a1 = b1*iw2/iw; a2 = b2*iw3/iw
                if has_clip
                    wp = Vec3(a0*wp1.x + a1*wp2.x + a2*wp3.x,
                              a0*wp1.y + a1*wp2.y + a2*wp3.y,
                              a0*wp1.z + a1*wp2.z + a2*wp3.z)
                    _clip_keep(clipping_planes, wp) || continue
                end
            end
            u = a0*u1 + a1*u2 + a2*u3
            v = a0*v1 + a1*v2 + a2*v3
            frag_alpha = alpha
            col = tint
            if has_tex
                col = col * sample_texture(tex, u, v)
            end
            if has_alpha
                frag_alpha = _fragment_alpha(Float64(alpha), tex, alpha_map, u, v, u, v)
                frag_alpha >= alpha_test || continue
            end
            col = clamp_color(col)
            depth_write && (rt.depth[py, px] = z)
            if frag_alpha >= 1.0
                rt.color[py, px, 1] = col.r; rt.color[py, px, 2] = col.g; rt.color[py, px, 3] = col.b
            elseif frag_alpha > 0.0
                ia = 1.0 - frag_alpha
                rt.color[py, px, 1] = col.r * frag_alpha + rt.color[py, px, 1] * ia
                rt.color[py, px, 2] = col.g * frag_alpha + rt.color[py, px, 2] * ia
                rt.color[py, px, 3] = col.b * frag_alpha + rt.color[py, px, 3] * ia
            end
            stamp !== nothing && (stamp[py, px] = stamp_id)
        end
    end
    return nothing
end

"""
    render_sprites!(rt, scene, camera; clipping_planes=Plane[])

Rasterize every visible [`Sprite`](@ref) under `scene` as a camera-facing
billboard. Each sprite is a unit quad oriented by [`sprite_world_matrix`](@ref)
so it squarely faces the camera, shifted by `Sprite.center`, scaled by the
sprite's scale, projected, and drawn depth-tested. `SpriteMaterial.rotation` is
applied in the billboard plane, and `SpriteMaterial.size_attenuation=false`
keeps approximate screen size under perspective projection. The sprite
material's `map` texture (if any) is sampled per pixel and modulated by its
`color` tint; `alpha_map`, map alpha, and `alpha_test` mask the same fragments
as other CPU-rasterized materials. Without a map the flat tint colour is used.
"""
function render_sprites!(rt::RenderTarget, scene::AbstractObject3D, camera::AbstractCamera;
                         clipping_planes=_NO_PLANES,
                         xlo::Int=1, xhi::Int=rt.width,
                         ylo::Int=1, yhi::Int=rt.height)
    view = view_matrix(camera)
    vp = projection_matrix(camera) * view
    W, H = rt.width, rt.height
    stamp = zeros(Int, H, W)
    stamp_id = 0
    traverse(scene, function(obj)
        (obj isa Sprite && _visible_in_tree(obj)) || return
        stamp_id += 1
        M = sprite_world_matrix(obj, camera)
        mat = obj.material
        tint = _material_field(mat, :color)
        tint === nothing && (tint = Color3(1.0, 1.0, 1.0))
        alpha = clamp(Float64(material_opacity(mat)), 0.0, 1.0)
        tex = _material_field(mat, :map)
        alpha_test = material_alpha_test(mat)
        alpha_map = _material_field(mat, :alpha_map)
        rot = _material_field(mat, :rotation)
        rot === nothing && (rot = 0.0)
        depth_test = material_depth_test(mat)
        depth_write = material_depth_write(mat)
        size_attenuation = _material_field(mat, :size_attenuation)
        size_attenuation === nothing && (size_attenuation = true)
        center_world = Vec3(mat4_get(M, 1, 4), mat4_get(M, 2, 4), mat4_get(M, 3, 4))
        center_view = mat4_transform_vec4(view, Vec4(center_world.x, center_world.y, center_world.z, 1.0))
        attenuation = size_attenuation ? 1.0 : max(0.0001, -center_view.z)
        c = cos(rot); s = sin(rot)
        function xy(x, y)
            px = x - obj.center.x
            py = y - obj.center.y
            return ((c * px - s * py) * attenuation, (s * px + c * py) * attenuation)
        end
        # Quad corners (local sprite plane) and their UVs (v=0 at the bottom).
        x0, y0 = xy(0.0, 0.0)
        x1, y1 = xy(1.0, 0.0)
        x2, y2 = xy(1.0, 1.0)
        x3, y3 = xy(0.0, 1.0)
        (s0x, s0y, z0, iw0, wp0, ok0) = _sprite_corner(M, vp, x0, y0, W, H)
        (s1x, s1y, z1, iw1, wp1, ok1) = _sprite_corner(M, vp, x1, y1, W, H)
        (s2x, s2y, z2, iw2, wp2, ok2) = _sprite_corner(M, vp, x2, y2, W, H)
        (s3x, s3y, z3, iw3, wp3, ok3) = _sprite_corner(M, vp, x3, y3, W, H)
        (ok0 && ok1 && ok2 && ok3) || return
        # Triangle (0,1,2): UVs (0,0),(1,0),(1,1).
        _rasterize_sprite_tri!(rt,
            s0x, s0y, z0, iw0, 0.0, 0.0, wp0,
            s1x, s1y, z1, iw1, 1.0, 0.0, wp1,
            s2x, s2y, z2, iw2, 1.0, 1.0, wp2,
            tint, tex, clipping_planes, xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
            alpha_test, alpha_map, stamp, stamp_id)
        # Triangle (0,2,3): UVs (0,0),(1,1),(0,1).
        _rasterize_sprite_tri!(rt,
            s0x, s0y, z0, iw0, 0.0, 0.0, wp0,
            s2x, s2y, z2, iw2, 1.0, 1.0, wp2,
            s3x, s3y, z3, iw3, 0.0, 1.0, wp3,
            tint, tex, clipping_planes, xlo, xhi, ylo, yhi, depth_test, depth_write, alpha,
            alpha_test, alpha_map, stamp, stamp_id)
    end)
    return rt
end

"""Rasterize `PointsObject` vertices as small point sprites sized by the material."""
function render_points!(rt::RenderTarget, scene::AbstractObject3D, camera::AbstractCamera;
                        xlo::Int=1, xhi::Int=rt.width,
                        ylo::Int=1, yhi::Int=rt.height)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
    near = _camera_near(camera)
    W, H = rt.width, rt.height

    function draw_points_geometry!(geo, material, wm::Mat4, morphed_positions=nothing)
        col = hasfield(typeof(material), :color) ? material.color : Color3(1.0,1.0,1.0)
        alpha = clamp(Float64(material_opacity(material)), 0.0, 1.0)
        depth_test = material_depth_test(material)
        depth_write = material_depth_write(material)
        alpha_test = material_alpha_test(material)
        albedo_map = _material_field(material, :map)
        alpha_map = _material_field(material, :alpha_map)
        use_color_map = albedo_map isa Texture
        use_fragment_alpha = _needs_fragment_alpha(alpha_test, alpha, albedo_map, alpha_map)
        base_size = hasfield(typeof(material), :size) ? Float64(material.size) : 1.0
        size_attenuation = _material_field(material, :size_attenuation)
        size_attenuation === nothing && (size_attenuation = true)
        reference_depth = camera isa PerspectiveCamera ?
            max(norm(camera.position - camera.target), near) : 1.0
        for vi in 1:geo.n_vertices
            pv = mat4_transform_point(view, mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi)))
            pv.z <= -near || continue      # near-plane cull, matching the mesh path
            (px, py, pz, ok) = _project(proj, pv, W, H)
            ok || continue
            effective_size = base_size
            if size_attenuation && camera isa PerspectiveCamera
                effective_size *= reference_depth / max(1e-6, -pv.z)
            end
            r = max(Int(round(effective_size)) ÷ 2, 0)
            diameter = max(2r + 1, 1)
            cx = round(Int, px); cy = round(Int, py)
            min_px = max(cx - r, xlo)
            max_px = min(cx + r, xhi)
            min_py = max(cy - r, ylo)
            max_py = min(cy + r, yhi)
            for py in min_py:max_py, px in min_px:max_px
                u = clamp((px - (cx - r) + 0.5) / diameter, 0.0, 1.0)
                v = clamp(1.0 - (py - (cy - r) + 0.5) / diameter, 0.0, 1.0)
                frag_alpha = use_fragment_alpha ?
                    _fragment_alpha(alpha, albedo_map, alpha_map, u, v, u, v) : alpha
                frag_alpha >= alpha_test || continue
                point_col = col
                if use_color_map
                    tex_col = sample_texture_linear(albedo_map, u, v)
                    point_col = Color3(col.r * tex_col.r, col.g * tex_col.g, col.b * tex_col.b)
                end
                _put_pixel!(rt, px, py, pz, point_col, xlo, xhi, ylo, yhi,
                            depth_test, depth_write, frag_alpha)
            end
        end
        return nothing
    end

    traverse(scene, function(obj)
        _visible_in_tree(obj) || return
        if obj isa PointsObject
            geo = obj.geometry
            draw_points_geometry!(geo, obj.material, compute_world_matrix(obj),
                                  _object_morph_positions(obj, geo))
        elseif obj isa InstancedMesh && _instanced_point_drawable(obj)
            base = compute_world_matrix(obj)
            for M in obj.instance_matrices
                draw_points_geometry!(obj.geometry, obj.material, base * M)
            end
        end
    end)
    return rt
end

# ========================== EffectComposer (post-processing) ==========================

mutable struct EffectComposer
    passes::Vector{Function}     # each maps an H×W×3 image to an H×W×3 image
end
EffectComposer() = EffectComposer(Function[])
add_pass!(c::EffectComposer, f::Function) = (push!(c.passes, f); c)

"""Run the image through every pass in order."""
function compose(c::EffectComposer, img::AbstractArray)
    out = img
    for p in c.passes
        out = p(out)
    end
    return out
end

# Built-in passes.
function grayscale_pass(img::AbstractArray)
    H, W, _ = size(img)
    out = Array{Float64}(undef, H, W, 3)
    @inbounds for i in 1:H, j in 1:W
        g = 0.299*img[i,j,1] + 0.587*img[i,j,2] + 0.114*img[i,j,3]
        out[i,j,1] = g; out[i,j,2] = g; out[i,j,3] = g
    end
    return out
end
reinhard_pass(img) = tone_map_reinhard(img)
aces_pass(img) = tone_map_aces(img)
srgb_pass(img) = srgb_encode(img)

# --------------------------------------------------------------------------
# Additional post-processing passes.
#
# Convention: every pass consumed by [`EffectComposer`] is a `Function` that maps
# an H×W×3 colour image to an H×W×3 image (see `compose`). The colour-only passes
# below (`bloom_pass`, `fxaa_pass`) match the built-ins exactly; they are factory
# functions that read keyword parameters and return such a mapping. The passes
# that need scene depth (`outline_pass`, `ssao_pass`, `bokeh_pass`) capture a
# depth buffer (the `H×W` `RenderTarget.depth`, smaller = nearer, `Inf` =
# background) and likewise return an `img -> img` mapping, so they slot into the
# composer identically. No G-buffer normal channel exists, so the SSAO pass
# reconstructs view-space normals from the depth gradient (documented below).
# --------------------------------------------------------------------------

# Rec.601 luma of an RGB pixel at (i,j) — shared by several passes.
@inline _luma(img, i, j) = @inbounds 0.299*img[i,j,1] + 0.587*img[i,j,2] + 0.114*img[i,j,3]

# Build a 1-D Gaussian kernel of the given integer radius (σ = radius/2, clamped),
# normalized to sum 1. Returned as an OffsetVector-free plain Vector indexed 1..2r+1
# (centre at r+1).
function _gaussian_kernel(radius::Int)
    r = max(radius, 0)
    σ = max(r / 2, 1e-3)
    k = Vector{Float64}(undef, 2r + 1)
    s = 0.0
    @inbounds for t in -r:r
        w = exp(-(t*t) / (2σ*σ)); k[t + r + 1] = w; s += w
    end
    inv = 1.0 / s
    @inbounds for t in eachindex(k); k[t] *= inv; end
    return k
end

# Separable Gaussian blur of an H×W×3 image with the given radius. Edges are
# handled by clamping the sample index (replicate border). Uses one scratch
# buffer for the horizontal pass, then writes the vertical pass into `out`.
function _blur_separable(img::AbstractArray, radius::Int)
    H, W, _ = size(img)
    r = max(radius, 0)
    r == 0 && return Float64.(img)
    k = _gaussian_kernel(r)
    tmp = Array{Float64}(undef, H, W, 3)
    out = Array{Float64}(undef, H, W, 3)
    @inbounds for c in 1:3, i in 1:H, j in 1:W           # horizontal
        acc = 0.0
        for t in -r:r
            jj = clamp(j + t, 1, W)
            acc += k[t + r + 1] * img[i, jj, c]
        end
        tmp[i, j, c] = acc
    end
    @inbounds for c in 1:3, i in 1:H, j in 1:W           # vertical
        acc = 0.0
        for t in -r:r
            ii = clamp(i + t, 1, H)
            acc += k[t + r + 1] * tmp[ii, j, c]
        end
        out[i, j, c] = acc
    end
    return out
end

"""
    bloom_pass(; threshold=0.8, intensity=0.6, radius=2)

Bloom post-process. Extracts a bright-pass image (pixels whose Rec.601 luma
exceeds `threshold`, keeping their colour), blurs it with a separable Gaussian of
the given pixel `radius`, and adds the blurred glow back to the original image
scaled by `intensity`. Returns a new H×W×3 image; the input is not mutated. The
returned closure matches the [`EffectComposer`] pass convention (`img -> img`).
"""
function bloom_pass(; threshold::Real=0.8, intensity::Real=0.6, radius::Int=2)
    thr = Float64(threshold); inten = Float64(intensity); rad = max(Int(radius), 0)
    return function (img::AbstractArray)
        H, W, _ = size(img)
        bright = Array{Float64}(undef, H, W, 3)        # bright-pass extraction
        @inbounds for i in 1:H, j in 1:W
            if _luma(img, i, j) > thr
                bright[i,j,1] = img[i,j,1]; bright[i,j,2] = img[i,j,2]; bright[i,j,3] = img[i,j,3]
            else
                bright[i,j,1] = 0.0; bright[i,j,2] = 0.0; bright[i,j,3] = 0.0
            end
        end
        glow = _blur_separable(bright, rad)
        out = Array{Float64}(undef, H, W, 3)
        @inbounds for idx in eachindex(out)
            out[idx] = img[idx] + inten * glow[idx]
        end
        return out
    end
end

"""
    fxaa_pass()

Compact luma-based anti-aliasing (FXAA-style). For each pixel the Rec.601 luma of
the 4-neighbourhood is measured; where the local luma contrast (max − min)
exceeds an internal threshold, the pixel is blended toward its neighbours along
the dominant edge direction (horizontal or vertical, whichever has the larger
gradient). Colour-only: the depth buffer is not used. Returns a new H×W×3 image.
The returned closure matches the [`EffectComposer`] pass convention.
"""
function fxaa_pass()
    # Edge thresholds follow the original FXAA quality presets (relative + absolute).
    EDGE_MIN = 0.0312     # absolute luma floor below which no AA is applied
    EDGE_REL = 0.125      # contrast must exceed this fraction of the local max luma
    return function (img::AbstractArray)
        H, W, _ = size(img)
        out = Float64.(img)
        @inbounds for i in 2:H-1, j in 2:W-1
            lC = _luma(img, i, j)
            lN = _luma(img, i-1, j); lS = _luma(img, i+1, j)
            lW = _luma(img, i, j-1); lE = _luma(img, i, j+1)
            lmax = max(lC, lN, lS, lW, lE)
            lmin = min(lC, lN, lS, lW, lE)
            contrast = lmax - lmin
            (contrast < max(EDGE_MIN, EDGE_REL*lmax)) && continue
            # Dominant edge direction: vertical gradient vs horizontal gradient.
            gv = abs(lN - lS); gh = abs(lW - lE)
            if gv >= gh
                # Edge is horizontal-ish → blend vertically (with N and S).
                for c in 1:3
                    out[i,j,c] = 0.5*img[i,j,c] + 0.25*img[i-1,j,c] + 0.25*img[i+1,j,c]
                end
            else
                # Edge is vertical-ish → blend horizontally (with W and E).
                for c in 1:3
                    out[i,j,c] = 0.5*img[i,j,c] + 0.25*img[i,j-1,c] + 0.25*img[i,j+1,c]
                end
            end
        end
        return out
    end
end

"""
    outline_pass(depth; threshold=0.1, color=Color3(0,0,0))

Edge outlining from the depth buffer. A Sobel gradient magnitude is computed on
the supplied `depth` matrix (the `H×W` `RenderTarget.depth`; smaller = nearer,
`Inf` = background). Wherever the normalized depth-gradient magnitude exceeds
`threshold`, the output pixel is set to `color`; elsewhere the original colour is
kept. Background/foreground silhouettes (finite↔`Inf` transitions) always count
as edges. Returns a new H×W×3 image. The returned closure matches the
[`EffectComposer`] pass convention; the depth buffer is captured here because the
composer only forwards the colour image.

The depth matrix is captured at construction time, so the returned pass can be
applied to any colour image of the matching size.
"""
function outline_pass(depth::AbstractMatrix; threshold::Real=0.1, color::Color3=Color3(0.0,0.0,0.0))
    thr = Float64(threshold)
    oc = (Float64(color.r), Float64(color.g), Float64(color.b))
    # Map a raw depth to a bounded finite value so Sobel differences are well
    # defined at silhouettes: Inf (background) → a large sentinel beyond any face.
    @inline function dval(d)
        isfinite(d) ? Float64(d) : 1.0e9
    end
    return function (img::AbstractArray)
        H, W, _ = size(img)
        out = Float64.(img)
        (H >= 3 && W >= 3) || return out
        # Normalize the gradient by the finite depth range so `threshold` is scale-free.
        dmin = Inf; dmax = -Inf
        @inbounds for i in 1:H, j in 1:W
            d = depth[i,j]
            if isfinite(d)
                d < dmin && (dmin = d); d > dmax && (dmax = d)
            end
        end
        span = (isfinite(dmin) && dmax > dmin) ? (dmax - dmin) : 1.0
        invspan = 1.0 / span
        @inbounds for i in 2:H-1, j in 2:W-1
            d11 = dval(depth[i-1,j-1]); d12 = dval(depth[i-1,j]); d13 = dval(depth[i-1,j+1])
            d21 = dval(depth[i  ,j-1]);                            d23 = dval(depth[i  ,j+1])
            d31 = dval(depth[i+1,j-1]); d32 = dval(depth[i+1,j]); d33 = dval(depth[i+1,j+1])
            gx = (d13 + 2*d23 + d33) - (d11 + 2*d21 + d31)
            gy = (d31 + 2*d32 + d33) - (d11 + 2*d12 + d13)
            mag = sqrt(gx*gx + gy*gy) * 0.25 * invspan
            if mag > thr
                out[i,j,1] = oc[1]; out[i,j,2] = oc[2]; out[i,j,3] = oc[3]
            end
        end
        return out
    end
end

"""
    ssao_pass(depth; radius=1.0, intensity=1.0, samples=8)

Screen-space ambient occlusion derived from the depth buffer alone (no G-buffer
normal channel exists in this rasterizer). For each foreground pixel the
view-space normal is reconstructed from the local depth gradient (finite
differences of `depth`, treated as a height field), then `samples` neighbours are
probed on the image-plane circle of the given pixel `radius`. A neighbour
contributes occlusion when it is nearer than the centre by more than a small bias
and lies in front of the reconstructed surface plane (its depth delta projects
onto the normal). The accumulated occlusion darkens the pixel by up to
`intensity`. Background pixels (`Inf` depth) are left unchanged. Returns a new
H×W×3 image. The returned closure matches the [`EffectComposer`] pass convention;
the depth buffer is captured here because the composer only forwards colour.
"""
function ssao_pass(depth::AbstractMatrix; radius::Real=1.0, intensity::Real=1.0, samples::Int=8)
    rad = max(Float64(radius), 1e-3)
    inten = clamp(Float64(intensity), 0.0, 1.0)
    ns = max(Int(samples), 1)
    bias = 1e-4
    # Precompute fixed hemisphere sample offsets on the image-plane circle (in
    # pixels), distributed by angle with mild radial jitter for coverage. Fixed
    # (deterministic) so the pass is reproducible.
    offs = Vector{NTuple{2,Float64}}(undef, ns)
    @inbounds for s in 1:ns
        θ = 2π * (s - 1) / ns
        rr = rad * (0.4 + 0.6 * (s / ns))      # spread samples over the radius
        offs[s] = (rr*cos(θ), rr*sin(θ))
    end
    return function (img::AbstractArray)
        H, W, _ = size(img)
        out = Float64.(img)
        (H >= 3 && W >= 3) || return out
        @inline df(i, j) = (d = depth[clamp(i,1,H), clamp(j,1,W)]; isfinite(d) ? Float64(d) : NaN)
        @inbounds for i in 2:H-1, j in 2:W-1
            dC = depth[i,j]
            isfinite(dC) || continue
            dc = Float64(dC)
            # Reconstruct a view-space normal from the depth height field. The
            # surface (x=col, y=row, z=depth) has tangents (1,0,dz/dx),(0,1,dz/dy);
            # their cross product gives (-dz/dx, -dz/dy, 1) (smaller depth = nearer).
            dzx = df(i, j+1); isnan(dzx) && (dzx = dc); dzx -= dc
            dzy = df(i+1, j); isnan(dzy) && (dzy = dc); dzy -= dc
            nx = -dzx; ny = -dzy; nz = 1.0
            ninv = 1.0 / sqrt(nx*nx + ny*ny + nz*nz)
            nx *= ninv; ny *= ninv; nz *= ninv
            occ = 0.0
            cnt = 0
            for s in 1:ns
                (ox, oy) = offs[s]
                si = i + round(Int, oy); sj = j + round(Int, ox)
                dN = df(si, sj)
                isnan(dN) && continue          # background neighbour: no occlusion
                cnt += 1
                Δ = dc - dN                    # >0 when neighbour is nearer (occluder)
                if Δ > bias
                    # Project the (image-plane offset, depth delta) onto the normal:
                    # only count occluders sitting above the surface plane. Uses the
                    # rounded offsets actually sampled so flat tilted surfaces
                    # (dN = dc + dzx*oxr + dzy*oyr) contribute exactly zero.
                    oxr = sj - j; oyr = si - i
                    proj = nz*Δ - (nx*oxr + ny*oyr)
                    if proj > bias
                        # Range check: distant depth gaps shouldn't over-darken.
                        rcheck = rad / (rad + Δ)
                        occ += rcheck
                    end
                end
            end
            cnt == 0 && continue
            ao = 1.0 - inten * (occ / cnt)
            ao = clamp(ao, 0.0, 1.0)
            out[i,j,1] = img[i,j,1]*ao; out[i,j,2] = img[i,j,2]*ao; out[i,j,3] = img[i,j,3]*ao
        end
        return out
    end
end

"""
    bokeh_pass(depth; focus_depth, aperture=0.02)
    bokeh_pass(; focus_depth, aperture=0.02, depth)

Depth-of-field (bokeh) blur driven by the depth buffer. Each pixel's circle of
confusion radius is `|depth - focus_depth| * aperture` (in pixels, rounded and
capped), so geometry near `focus_depth` stays sharp while out-of-focus regions
are box-blurred over their circle of confusion. Background pixels (`Inf` depth)
are treated as maximally defocused at the cap. Returns a new H×W×3 image. The
returned closure matches the [`EffectComposer`] pass convention; the depth buffer
is captured here because the composer only forwards the colour image.

`focus_depth` is required (the in-focus depth plane, in the same units as the
depth buffer). This is a scatter-as-gather approximation: each output pixel
averages a disc sized by its own circle of confusion. It does not model true lens
occlusion or partial-occlusion bleeding, which a CPU gather DoF cannot represent
exactly.
"""
function bokeh_pass(; focus_depth::Real, aperture::Real=0.02, depth::AbstractMatrix)
    fd = Float64(focus_depth); ap = max(Float64(aperture), 0.0)
    maxr = 16                                  # cap CoC radius to bound work
    return function (img::AbstractArray)
        H, W, _ = size(img)
        out = Array{Float64}(undef, H, W, 3)
        @inbounds for i in 1:H, j in 1:W
            dC = depth[i,j]
            coc = isfinite(dC) ? abs(Float64(dC) - fd) * ap : Float64(maxr)
            r = min(round(Int, coc), maxr)
            if r <= 0
                out[i,j,1] = img[i,j,1]; out[i,j,2] = img[i,j,2]; out[i,j,3] = img[i,j,3]
                continue
            end
            r2 = r * r
            sr = 0.0; sg = 0.0; sb = 0.0; wsum = 0.0
            for dy in -r:r, dx in -r:r
                (dx*dx + dy*dy) <= r2 || continue   # disc-shaped circle of confusion
                ii = clamp(i + dy, 1, H); jj = clamp(j + dx, 1, W)
                sr += img[ii,jj,1]; sg += img[ii,jj,2]; sb += img[ii,jj,3]; wsum += 1.0
            end
            iw = 1.0 / wsum
            out[i,j,1] = sr*iw; out[i,j,2] = sg*iw; out[i,j,3] = sb*iw
        end
        return out
    end
end
# Positional-depth convenience form, matching `outline_pass`/`ssao_pass`.
bokeh_pass(depth::AbstractMatrix; focus_depth::Real, aperture::Real=0.02) =
    bokeh_pass(; focus_depth=focus_depth, aperture=aperture, depth=depth)

# ========================== Tiled / parallel rasterization ==========================

"""
    render_tiled!(rt, scene, camera; tiles=Threads.nthreads(), shading=:flat)

Flat-rasterize the scene in horizontal row bands. Bands write disjoint rows, so
they can run on separate threads (used when Julia is started with > 1 thread).
Produces the same image as [`render!`] for opaque flat scenes.
"""
function render_tiled!(rt::RenderTarget, scene::Scene, camera::AbstractCamera;
                       tiles::Int=max(Threads.nthreads(), 1), shading::Symbol=:flat)
    shading === :flat || throw(ArgumentError("render_tiled! supports only :flat shading"))
    clear!(rt, scene.background)
    proj = projection_matrix(camera)
    view = view_matrix(camera)
    near = _camera_near(camera)
    # Same orthographic back-face-culling direction as `render!`.
    ortho_dir = camera isa OrthographicCamera ?
        normalize(camera.position - camera.target) : nothing
    H = rt.height
    meshes = collect_meshes(scene)
    _append_skinned_render_meshes!(meshes, scene)
    lights = collect_lights(scene)
    instanced = collect_instanced(scene)
    band = cld(H, tiles)
    Threads.@threads for t in 1:tiles
        ylo = (t-1)*band + 1
        yhi = min(t*band, H)
        ylo > yhi && continue
        tri = Vector{Vec4{Float64}}(undef, 3)
        clipped = Vector{Vec4{Float64}}(undef, 0); sizehint!(clipped, 6)
        sx = Vector{Float64}(undef, 8); sy = Vector{Float64}(undef, 8); sz = Vector{Float64}(undef, 8)
        for mesh in meshes
            is_visible(mesh) || continue
            is_transparent_material(mesh.material) && continue
            _rasterize_geo_flat!(rt, mesh.geometry, compute_world_matrix(mesh), mesh.material,
                                 lights, proj, view, near, camera.position, tri, clipped, sx, sy, sz;
                                 ylo=ylo, yhi=yhi, ortho_dir=ortho_dir)
        end
        for im in instanced
            # collect_instanced traverses without pruning invisible subtrees.
            _visible_in_tree(im) || continue
            _instanced_triangle_drawable(im) || continue
            base = compute_world_matrix(im)
            for M in im.instance_matrices
                _rasterize_geo_flat!(rt, im.geometry, base * M, im.material,
                                     lights, proj, view, near, camera.position, tri, clipped, sx, sy, sz;
                                     ylo=ylo, yhi=yhi, ortho_dir=ortho_dir)
            end
        end
    end
    return rt
end
