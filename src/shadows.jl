# --------------------------------------------------------------------------
# Shadow mapping: render scene depth from a light's viewpoint, then test shaded
# points against that depth map. Directional lights use an orthographic light
# camera sized to the scene; spot/point lights use a perspective light camera.
# --------------------------------------------------------------------------

struct ShadowMap
    depth::Matrix{Float64}      # NDC depth from the light (smaller = nearer light); Inf = empty
    light_vp::Mat4{Float64}     # light view-projection
    bias::Float64
    pcf_radius::Int             # percentage-closer-filtering radius r; 0 = hard shadow

    function ShadowMap(depth::Matrix{Float64}, light_vp::Mat4{Float64}, bias, pcf_radius)
        !isempty(depth) || throw(ArgumentError("ShadowMap depth must be non-empty"))
        all(isfinite, light_vp.e) || throw(ArgumentError("ShadowMap light_vp must be finite"))
        b = _validated_shadow_bias(bias)
        b === nothing && throw(ArgumentError("ShadowMap bias must be finite"))
        pcf = _validated_shadow_pcf_radius(pcf_radius)
        pcf === nothing && throw(ArgumentError("ShadowMap pcf_radius must be an integer"))
        return new(depth, light_vp, b, pcf)
    end
end

ShadowMap(depth::Matrix{Float64}, light_vp::Mat4, bias, pcf_radius) =
    ShadowMap(depth, convert(Mat4{Float64}, light_vp), bias, pcf_radius)

# Backward-compatible constructor: existing 3-arg callers get a hard shadow (r=0),
# matching the original single-sample depth comparison byte-for-byte.
ShadowMap(depth::Matrix{Float64}, light_vp::Mat4{Float64}, bias::Float64) =
    ShadowMap(depth, light_vp, bias, 0)
ShadowMap(depth::Matrix{Float64}, light_vp::Mat4, bias) =
    ShadowMap(depth, light_vp, bias, 0)

struct _ShadowQuery{M}
    maps::M
end

@inline function (query::_ShadowQuery)(light, p::Vec3)
    maps = query.maps
    return haskey(maps, light) ? shadow_visibility(maps[light], p) : 1.0
end

function _validated_shadow_resolution(resolution::Int)
    resolution > 0 || throw(ArgumentError("shadow resolution must be positive"))
    return resolution
end

function _expand_shadow_bounds!(box::Box3, geo, world::Mat4)
    for face_index in _draw_face_range(geo)
        first_entry = 3face_index - 2
        for entry in first_entry:(first_entry + 2)
            vi = _draw_vertex_index(geo, entry)
            p = mat4_transform_point(world, get_vertex(geo, vi))
            isfinite(p.x) && isfinite(p.y) && isfinite(p.z) || continue
            box = box3_expand_by_point(box, p)
        end
    end
    return box
end

_valid_shadow_box(box::Box3) =
    isfinite(box.min.x) && isfinite(box.min.y) && isfinite(box.min.z) &&
    isfinite(box.max.x) && isfinite(box.max.y) && isfinite(box.max.z) &&
    box.min.x <= box.max.x && box.min.y <= box.max.y && box.min.z <= box.max.z

# World-space bounding sphere of visible drawables. The public visibility query
# may be evaluated at any visible surface, regardless of its receive flag.
function _scene_bounds(meshes, instanced)
    box = Box3()
    for mesh in meshes
        is_visible(mesh) || continue
        box = _expand_shadow_bounds!(box, mesh.geometry, compute_world_matrix(mesh))
    end
    for im in instanced
        # collect_instanced traverses without pruning invisible subtrees.
        _visible_in_tree(im) || continue
        _instanced_triangle_drawable(im) || continue
        base = compute_world_matrix(im)
        for M in im.instance_matrices
            box = _expand_shadow_bounds!(box, im.geometry, base * M)
        end
    end
    _valid_shadow_box(box) || return (Vec3(), 1e-3)
    center = Vec3(
        _geometry_midpoint(box.min.x, box.max.x),
        _geometry_midpoint(box.min.y, box.max.y),
        _geometry_midpoint(box.min.z, box.max.z),
    )
    radius = norm(box.max - center)
    return (center, max(radius, 1e-3))
end

_safe_up(dir::Vec3) = abs(dir.y) > 0.99 ? Vec3(1.0, 0.0, 0.0) : Vec3(0.0, 1.0, 0.0)

function _shadow_direction(from::Vec3, to::Vec3)
    direction = to - from
    if isfinite(direction.x) && isfinite(direction.y) &&
       isfinite(direction.z)
        return normalize(direction)
    end
    scaled, _, nonzero =
        _difference_direction_and_logscale(from, to)
    return nonzero ? normalize(scaled) : normalize(direction)
end

function _light_view_proj(light::DirectionalLight, center::Vec3, radius)
    light_position = _light_world_position(light)
    dir = _shadow_direction(light.target, light_position) # toward the light
    eye = center + dir * (radius * 2.0)
    lv = mat4_look_at(eye, center, _safe_up(dir))
    s = radius * 1.1
    # Scale near with the scene radius: the eye sits at distance 2·radius, so the
    # casters span [radius, 3·radius] from it. A hardcoded near=0.01 exceeds
    # far (radius*4) and clips the whole scene once radius < 0.0025; radius*1e-2
    # keeps near < closest caster < farthest caster < far at every scene scale
    # (and equals the old 0.01 at the common radius≈1).
    lp = mat4_orthographic(-s, s, -s, s, radius * 1e-2, radius * 4.0)
    return lp * lv
end

# Fit the perspective near/far planes to the slab [d-radius, d+radius] actually
# containing casters/receivers, so NDC depth precision (and the fixed bias)
# stays meaningful at any light distance. The floor keeps `near` positive (and
# the near/far ratio bounded) when the light sits inside the bounding sphere.
function _perspective_shadow_planes(light_pos::Vec3, center::Vec3, radius)
    d = norm(light_pos - center)
    near = max(d - radius, max(radius, d) * 1e-2)
    far = max(d + radius, near * (1 + 1e-6))
    return (near, far)
end

function _light_view_proj(light::SpotLight, center::Vec3, radius)
    light_position = _light_world_position(light)
    lv = mat4_look_at(
        light_position, light.target,
        _safe_up(_shadow_direction(light_position, light.target)))
    near, far = _perspective_shadow_planes(light_position, center, radius)
    lp = mat4_perspective(min(light.angle * 2.0, π * 0.9), 1.0, near, far)
    return lp * lv
end

function _light_view_proj(light::PointLight, center::Vec3, radius)
    light_position = _light_world_position(light)
    dir = _shadow_direction(light_position, center)
    lv = mat4_look_at(light_position, center, _safe_up(dir))
    near, far = _perspective_shadow_planes(light_position, center, radius)
    lp = mat4_perspective(π/2, 1.0, near, far)
    return lp * lv
end

# Depth-only triangle rasterization into the shadow buffer. The optional material
# inputs mirror the color rasterizer's alpha-test and clipping discard paths.
@inline _shadow_depth_in_range(z) =
    isfinite(z) && -one(z) <= z <= one(z)

@inline function _raster_depth!(depth::Matrix{Float64}, W, H,
                                s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3;
                                clipping_planes=_NO_PLANES,
                                wp1::Vec3=_ZERO_V3, wp2::Vec3=_ZERO_V3, wp3::Vec3=_ZERO_V3,
                                iw1::Float64=1.0, iw2::Float64=1.0, iw3::Float64=1.0,
                                alpha_test::Float64=0.0, alpha_base::Float64=1.0,
                                albedo_map=nothing, alpha_map=nothing,
                                uv1::Vec2=_ZERO_V2, uv2::Vec2=_ZERO_V2, uv3::Vec2=_ZERO_V2,
                                uv2_1::Vec2=_ZERO_V2, uv2_2::Vec2=_ZERO_V2, uv2_3::Vec2=_ZERO_V2)
    # Skip triangles with a non-finite projected vertex (no raster footprint).
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    (isfinite(area) && abs(area) >= 1e-12) || return nothing
    inv_area = 1.0 / area
    # Clamp the float extent into [1, W]/[1, H] before the Int conversion so an
    # extreme-but-finite projected vertex cannot overflow floor/ceil(Int, …),
    # matching the color rasterizer's hardened bbox.
    fW = Float64(W); fH = Float64(H)
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1)
    max_x = min(ceil(Int,  clamp(max(s1x, s2x, s3x), 1.0, fW)), W)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1)
    max_y = min(ceil(Int,  clamp(max(s1y, s2y, s3y), 1.0, fH)), H)
    has_clip = !isempty(clipping_planes)
    has_alpha = _needs_fragment_alpha(alpha_test, alpha_base, albedo_map, alpha_map)
    @inbounds for py in min_y:max_y, px in min_x:max_x
        cx = px - 0.5; cy = py - 0.5
        w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
        w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
        w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
        if w0 >= 0 && w1 >= 0 && w2 >= 0
            if has_clip || has_alpha
                iw = w0 * iw1 + w1 * iw2 + w2 * iw3
                iw <= 0 && continue
                a0 = w0 * iw1 / iw; a1 = w1 * iw2 / iw; a2 = w2 * iw3 / iw
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
            z = w0 * z1 + w1 * z2 + w2 * z3
            _shadow_depth_in_range(z) || continue
            z < depth[py, px] && (depth[py, px] = z)
        end
    end
    return nothing
end

@inline function _raster_depth_plain!(depth::Matrix{Float64}, W, H,
                                      s1x, s1y, z1, s2x, s2y, z2,
                                      s3x, s3y, z3)
    (isfinite(s1x) && isfinite(s1y) && isfinite(s2x) && isfinite(s2y) &&
     isfinite(s3x) && isfinite(s3y)) || return nothing
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    (isfinite(area) && abs(area) >= 1e-12) || return nothing
    inv_area = 1.0 / area
    fW = Float64(W); fH = Float64(H)
    min_x = max(floor(Int, clamp(min(s1x, s2x, s3x), 1.0, fW)), 1)
    max_x = min(ceil(Int,  clamp(max(s1x, s2x, s3x), 1.0, fW)), W)
    min_y = max(floor(Int, clamp(min(s1y, s2y, s3y), 1.0, fH)), 1)
    max_y = min(ceil(Int,  clamp(max(s1y, s2y, s3y), 1.0, fH)), H)
    @inbounds for py in min_y:max_y, px in min_x:max_x
        cx = px - 0.5; cy = py - 0.5
        w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
        w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
        w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
        if w0 >= 0 && w1 >= 0 && w2 >= 0
            z = w0 * z1 + w1 * z2 + w2 * z3
            _shadow_depth_in_range(z) || continue
            z < depth[py, px] && (depth[py, px] = z)
        end
    end
    return nothing
end

function _raster_shadow_geometry!(depth::Matrix{Float64}, W::Int, H::Int,
                                  geo, world_mat::Mat4, mvp::Mat4, mat;
                                  clipping_planes=_NO_PLANES)
    has_uvs = length(geo.uvs) >= geo.n_vertices * 2
    albedo_map = has_uvs ? _material_field(mat, :map) : nothing
    alpha_map = has_uvs ? _material_field(mat, :alpha_map) : nothing
    alpha_test = material_alpha_test(mat)
    alpha_base = Float64(material_opacity(mat))
    use_fragment_alpha = _needs_fragment_alpha(alpha_test, alpha_base, albedo_map, alpha_map)
    uv2_attr = use_fragment_alpha ? _uv2_attribute(geo) : nothing
    has_clip = !isempty(clipping_planes)
    for fi in _draw_face_range(geo)
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        c1 = mat4_transform_vec4(mvp, _vh(v1))
        c2 = mat4_transform_vec4(mvp, _vh(v2))
        c3 = mat4_transform_vec4(mvp, _vh(v3))
        (c1.w <= 1e-6 || c2.w <= 1e-6 || c3.w <= 1e-6) && continue
        uv1 = _ZERO_V2; uv2v = _ZERO_V2; uv3 = _ZERO_V2
        uv2_1 = _ZERO_V2; uv2_2 = _ZERO_V2; uv2_3 = _ZERO_V2
        if use_fragment_alpha
            uv1 = has_uvs ? Vec2(geo.uvs[(i1-1)*2+1], geo.uvs[(i1-1)*2+2]) : _ZERO_V2
            uv2v = has_uvs ? Vec2(geo.uvs[(i2-1)*2+1], geo.uvs[(i2-1)*2+2]) : _ZERO_V2
            uv3 = has_uvs ? Vec2(geo.uvs[(i3-1)*2+1], geo.uvs[(i3-1)*2+2]) : _ZERO_V2
            uv2_1 = uv2_attr === nothing ? uv1 : Vec2(_vertex_uv_attr(uv2_attr, i1)...)
            uv2_2 = uv2_attr === nothing ? uv2v : Vec2(_vertex_uv_attr(uv2_attr, i2)...)
            uv2_3 = uv2_attr === nothing ? uv3 : Vec2(_vertex_uv_attr(uv2_attr, i3)...)
        end
        wp1 = has_clip ? mat4_transform_point(world_mat, v1) : _ZERO_V3
        wp2 = has_clip ? mat4_transform_point(world_mat, v2) : _ZERO_V3
        wp3 = has_clip ? mat4_transform_point(world_mat, v3) : _ZERO_V3
        s1x = (c1.x/c1.w+1)*0.5*W; s1y = (1-c1.y/c1.w)*0.5*H; z1 = c1.z/c1.w
        s2x = (c2.x/c2.w+1)*0.5*W; s2y = (1-c2.y/c2.w)*0.5*H; z2 = c2.z/c2.w
        s3x = (c3.x/c3.w+1)*0.5*W; s3y = (1-c3.y/c3.w)*0.5*H; z3 = c3.z/c3.w
        if has_clip || use_fragment_alpha
            _raster_depth!(depth, W, H, s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3;
                clipping_planes=clipping_planes,
                wp1=wp1, wp2=wp2, wp3=wp3,
                iw1=1.0/c1.w, iw2=1.0/c2.w, iw3=1.0/c3.w,
                alpha_test=alpha_test, alpha_base=alpha_base,
                albedo_map=albedo_map, alpha_map=alpha_map,
                uv1=uv1, uv2=uv2v, uv3=uv3,
                uv2_1=uv2_1, uv2_2=uv2_2, uv2_3=uv2_3)
        else
            _raster_depth_plain!(depth, W, H, s1x, s1y, z1, s2x, s2y, z2,
                                 s3x, s3y, z3)
        end
    end
    return depth
end

"""
    compute_shadow_map(scene, light; resolution=512, bias=nothing, pcf_radius=nothing, clipping_planes=_NO_PLANES)

Render the scene's depth from `light`'s viewpoint into a [`ShadowMap`].

`pcf_radius` selects percentage-closer filtering (PCF) soft shadows when querying
the map with [`shadow_visibility`](@ref): a value `r` samples a `(2r+1)x(2r+1)`
neighbourhood of the depth map and returns the lit fraction in `[0,1]`. When
`pcf_radius` or `bias` is `nothing`, three.js-style per-light `shadow_pcf_radius`
or `shadow_bias` settings are used when present; otherwise the historical hard
shadow (`pcf_radius=0`) and `bias=3e-3` defaults are preserved.
"""
function _compute_shadow_map_from_drawables(meshes, instanced, light,
                                            depth::Matrix{Float64};
                                            resolution::Int=512, bias=nothing,
                                            pcf_radius=nothing,
                                            clipping_planes=_NO_PLANES)
    _validate_light_object(light)
    res = _validated_shadow_resolution(resolution)
    size(depth) == (res, res) ||
        throw(ArgumentError("shadow depth scratch must match resolution"))
    for mesh in meshes
        _validate_triangle_geometry_indices(_mesh_geometry(mesh), "compute_shadow_map")
    end
    for im in instanced
        _validate_instanced_mesh(im, "compute_shadow_map")
        _instanced_triangle_drawable(im) || continue
        _validate_triangle_geometry_indices(_instanced_geometry(im), "compute_shadow_map")
    end
    fill!(depth, Inf)
    shadow_bias = bias === nothing ? _light_shadow_bias(light, 3e-3) :
                  _validated_shadow_bias(bias)
    pcf = pcf_radius === nothing ? _light_shadow_pcf_radius(light, 0) :
          _validated_shadow_pcf_radius(pcf_radius)
    pcf === nothing && (pcf = 0)
    has_caster = any(m -> is_visible(m) && object_casts_shadow(m), meshes) ||
                 any(im -> _visible_in_tree(im) && _instanced_triangle_drawable(im) &&
                           object_casts_shadow(im), instanced)
    has_caster ||
        return ShadowMap(depth, Mat4{Float64}(), shadow_bias, pcf)
    center, radius = _scene_bounds(meshes, instanced)
    vp = _light_view_proj(light, center, radius)
    W = H = res
    for mesh in meshes
        is_visible(mesh) || continue
        object_casts_shadow(mesh) || continue
        wm = compute_world_matrix(mesh); geo = mesh.geometry
        mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                         material_clipping_planes(mesh.material))
        _raster_shadow_geometry!(depth, W, H, geo, wm, vp * wm, mesh.material;
                                 clipping_planes=mesh_clipping_planes)
    end
    for im in instanced
        _visible_in_tree(im) || continue
        _instanced_triangle_drawable(im) || continue
        object_casts_shadow(im) || continue
        base = compute_world_matrix(im)
        mesh_clipping_planes = _combined_clipping_planes(clipping_planes,
                                                         material_clipping_planes(im.material))
        for M in im.instance_matrices
            world = base * M
            _raster_shadow_geometry!(depth, W, H, im.geometry, world, vp * world, im.material;
                                     clipping_planes=mesh_clipping_planes)
        end
    end
    return ShadowMap(depth, vp, shadow_bias, pcf)
end

function compute_shadow_map(scene, light; resolution::Int=512, bias=nothing, pcf_radius=nothing,
                            clipping_planes=_NO_PLANES)
    _validate_light_object(light)
    res = _validated_shadow_resolution(resolution)
    meshes = collect_meshes(scene)
    _append_skinned_render_meshes!(meshes, scene)
    instanced = collect_instanced(scene)
    depth = Matrix{Float64}(undef, res, res)
    return _compute_shadow_map_from_drawables(meshes, instanced, light, depth;
        resolution=res, bias=bias, pcf_radius=pcf_radius, clipping_planes=clipping_planes)
end

@inline _vh(v::Vec3) = Vec4(v.x, v.y, v.z, 1.0)

"""
    shadow_visibility(sm, p; pcf_radius=sm.pcf_radius)

Visibility of a world-space point from the shadow map's light: `1` lit, `0`
fully occluded. With `pcf_radius = r > 0`, a `(2r+1)x(2r+1)` neighbourhood of the
projected texel is sampled and the lit fraction in `[0,1]` is returned, giving a
soft penumbra (percentage-closer filtering, matching three.js `PCFShadowMap`).
The neighbourhood is clamped to the map bounds. `pcf_radius=0` reproduces the
single-sample hard shadow exactly.
"""
function shadow_visibility(sm::ShadowMap, p::Vec3; pcf_radius::Int=sm.pcf_radius)
    r = _validated_shadow_pcf_radius(pcf_radius)::Int
    isfinite(p.x) && isfinite(p.y) && isfinite(p.z) ||
        throw(ArgumentError("shadow_visibility point must be finite"))
    c = mat4_transform_vec4(sm.light_vp, _vh(p))
    isfinite(c.w) || return 1.0
    c.w <= 1e-6 && return 1.0
    ndcx = c.x / c.w; ndcy = c.y / c.w; ndcz = c.z / c.w
    isfinite(ndcx) && isfinite(ndcy) && isfinite(ndcz) || return 1.0
    (abs(ndcx) > 1 || abs(ndcy) > 1 || ndcz < -1 || ndcz > 1) &&
        return 1.0                                          # outside the light frustum
    H, W = size(sm.depth)
    px = clamp(floor(Int, (ndcx + 1) * 0.5 * W) + 1, 1, W)
    py = clamp(floor(Int, (1 - ndcy) * 0.5 * H) + 1, 1, H)

    if r <= 0                                               # hard shadow: single sample
        d = sm.depth[py, px]
        isinf(d) && return 1.0
        return ndcz - sm.bias > d ? 0.0 : 1.0               # something nearer the light occludes
    end

    # Soft shadow: average the unoccluded fraction over the texel neighbourhood,
    # clamped to the map bounds. Empty (Inf) texels count as lit, matching the
    # single-sample early-out above.
    x0 = r >= px - 1 ? 1 : px - r
    x1 = r >= W - px ? W : px + r
    y0 = r >= py - 1 ? 1 : py - r
    y1 = r >= H - py ? H : py + r
    lit = 0
    total = 0
    thresh = ndcz - sm.bias
    @inbounds for sy in y0:y1, sx in x0:x1
        total += 1
        d = sm.depth[sy, sx]
        if isinf(d) || thresh <= d
            lit += 1
        end
    end
    total == 0 && return 1.0
    return lit / total
end

# Build shadow maps for all shadow-casting lights and a closure to query them.
# `pcf_radius=0` keeps the original hard-shadow behaviour; a positive radius bakes
# percentage-closer soft shadows into every map, so the query closure returns the
# lit fraction in [0,1] via the radius stored on each `ShadowMap`.
@inline function _light_casts_shadow(light)
    return !_is_fill_light(light) && hasfield(typeof(light), :cast_shadow) &&
           getfield(light, :cast_shadow)
end

function _shadow_depth!(depths::Vector{Matrix{Float64}}, slot::Int, res::Int)
    while length(depths) < slot
        push!(depths, Matrix{Float64}(undef, 0, 0))
    end
    depth = depths[slot]
    if size(depth) != (res, res)
        depth = Matrix{Float64}(undef, res, res)
        depths[slot] = depth
    end
    return depth
end

function _build_shadow_query_from_drawables!(maps::IdDict{AbstractLight,ShadowMap},
                                             depths::Union{Nothing,Vector{Matrix{Float64}}},
                                             lights, meshes, instanced;
                                             resolution::Int=512, bias=nothing,
                                             pcf_radius=nothing,
                                             clipping_planes=_NO_PLANES)
    res = _validated_shadow_resolution(resolution)
    empty!(maps)
    shadow_slot = 0
    for light in lights
        if _light_casts_shadow(light)
            shadow_slot += 1
            depth = depths === nothing ? Matrix{Float64}(undef, res, res) :
                    _shadow_depth!(depths, shadow_slot, res)
            maps[light] = _compute_shadow_map_from_drawables(meshes, instanced, light, depth;
                resolution=res, bias=bias, pcf_radius=pcf_radius,
                clipping_planes=clipping_planes)
        end
    end
    isempty(maps) && return nothing
    return _ShadowQuery(maps)
end

function _build_shadow_query(scene, lights; resolution::Int=512, bias=nothing, pcf_radius=nothing,
                             clipping_planes=_NO_PLANES)
    meshes = collect_meshes(scene)
    _append_skinned_render_meshes!(meshes, scene)
    instanced = collect_instanced(scene)
    maps = IdDict{AbstractLight, ShadowMap}()
    return _build_shadow_query_from_drawables!(maps, nothing, lights, meshes, instanced;
        resolution=resolution, bias=bias, pcf_radius=pcf_radius,
        clipping_planes=clipping_planes)
end
