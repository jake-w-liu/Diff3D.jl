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
end

# Backward-compatible constructor: existing 3-arg callers get a hard shadow (r=0),
# matching the original single-sample depth comparison byte-for-byte.
ShadowMap(depth::Matrix{Float64}, light_vp::Mat4{Float64}, bias::Float64) =
    ShadowMap(depth, light_vp, bias, 0)

function _expand_shadow_bounds!(box::Box3, geo, world::Mat4)
    for vi in 1:geo.n_vertices
        box = box3_expand_by_point(box, mat4_transform_point(world, get_vertex(geo, vi)))
    end
    return box
end

# World-space bounding sphere of all shadow-casting drawables under the scene.
function _scene_bounds(meshes, instanced)
    box = Box3()
    for mesh in meshes
        is_visible(mesh) || continue
        (object_casts_shadow(mesh) || object_receives_shadow(mesh)) || continue
        box = _expand_shadow_bounds!(box, mesh.geometry, compute_world_matrix(mesh))
    end
    for im in instanced
        # collect_instanced traverses without pruning invisible subtrees.
        _visible_in_tree(im) || continue
        (object_casts_shadow(im) || object_receives_shadow(im)) || continue
        base = compute_world_matrix(im)
        for M in im.instance_matrices
            box = _expand_shadow_bounds!(box, im.geometry, base * M)
        end
    end
    center = (box.min + box.max) * 0.5
    radius = norm(box.max - center)
    return (center, max(radius, 1e-3))
end

_safe_up(dir::Vec3) = abs(dir.y) > 0.99 ? Vec3(1.0, 0.0, 0.0) : Vec3(0.0, 1.0, 0.0)

function _light_view_proj(light::DirectionalLight, center::Vec3, radius)
    dir = normalize(light.position - light.target)        # toward the light
    eye = center + dir * (radius * 2.0)
    lv = mat4_look_at(eye, center, _safe_up(dir))
    s = radius * 1.1
    lp = mat4_orthographic(-s, s, -s, s, 0.01, radius * 4.0)
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
    lv = mat4_look_at(light.position, light.target, _safe_up(normalize(light.target - light.position)))
    near, far = _perspective_shadow_planes(light.position, center, radius)
    lp = mat4_perspective(min(light.angle * 2.0, π * 0.9), 1.0, near, far)
    return lp * lv
end

function _light_view_proj(light::PointLight, center::Vec3, radius)
    dir = normalize(center - light.position)
    lv = mat4_look_at(light.position, center, _safe_up(dir))
    near, far = _perspective_shadow_planes(light.position, center, radius)
    lp = mat4_perspective(π/2, 1.0, near, far)
    return lp * lv
end

# Depth-only triangle rasterization into the shadow buffer.
@inline function _raster_depth!(depth::Matrix{Float64}, W, H,
                                s1x, s1y, z1, s2x, s2y, z2, s3x, s3y, z3)
    area = edge_function(s1x, s1y, s2x, s2y, s3x, s3y)
    abs(area) < 1e-12 && return nothing
    inv_area = 1.0 / area
    min_x = max(floor(Int, min(s1x, s2x, s3x)), 1)
    max_x = min(ceil(Int, max(s1x, s2x, s3x)), W)
    min_y = max(floor(Int, min(s1y, s2y, s3y)), 1)
    max_y = min(ceil(Int, max(s1y, s2y, s3y)), H)
    @inbounds for py in min_y:max_y, px in min_x:max_x
        cx = px - 0.5; cy = py - 0.5
        w0 = edge_function(s2x, s2y, s3x, s3y, cx, cy) * inv_area
        w1 = edge_function(s3x, s3y, s1x, s1y, cx, cy) * inv_area
        w2 = edge_function(s1x, s1y, s2x, s2y, cx, cy) * inv_area
        if w0 >= 0 && w1 >= 0 && w2 >= 0
            z = w0 * z1 + w1 * z2 + w2 * z3
            z < depth[py, px] && (depth[py, px] = z)
        end
    end
    return nothing
end

function _raster_shadow_geometry!(depth::Matrix{Float64}, W::Int, H::Int, geo, mvp::Mat4)
    for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        c1 = mat4_transform_vec4(mvp, _vh(get_vertex(geo, i1)))
        c2 = mat4_transform_vec4(mvp, _vh(get_vertex(geo, i2)))
        c3 = mat4_transform_vec4(mvp, _vh(get_vertex(geo, i3)))
        (c1.w <= 1e-6 || c2.w <= 1e-6 || c3.w <= 1e-6) && continue
        _raster_depth!(depth, W, H,
            (c1.x/c1.w+1)*0.5*W, (1-c1.y/c1.w)*0.5*H, c1.z/c1.w,
            (c2.x/c2.w+1)*0.5*W, (1-c2.y/c2.w)*0.5*H, c2.z/c2.w,
            (c3.x/c3.w+1)*0.5*W, (1-c3.y/c3.w)*0.5*H, c3.z/c3.w)
    end
    return depth
end

"""
    compute_shadow_map(scene, light; resolution=512, bias=3e-3, pcf_radius=0)

Render the scene's depth from `light`'s viewpoint into a [`ShadowMap`].

`pcf_radius` selects percentage-closer filtering (PCF) soft shadows when querying
the map with [`shadow_visibility`](@ref): a value `r` samples a `(2r+1)x(2r+1)`
neighbourhood of the depth map and returns the lit fraction in `[0,1]`. The
default `pcf_radius=0` reproduces the original single-sample hard shadow exactly.
"""
function compute_shadow_map(scene, light; resolution::Int=512, bias=3e-3, pcf_radius::Int=0)
    pcf_radius >= 0 || throw(ArgumentError("pcf_radius must be >= 0, got $pcf_radius"))
    meshes = collect_meshes(scene)
    _append_skinned_render_meshes!(meshes, scene)
    instanced = collect_instanced(scene)
    has_caster = any(m -> is_visible(m) && object_casts_shadow(m), meshes) ||
                 any(im -> _visible_in_tree(im) && object_casts_shadow(im), instanced)
    has_caster ||
        return ShadowMap(fill(Inf, resolution, resolution), Mat4{Float64}(), bias, pcf_radius)
    center, radius = _scene_bounds(meshes, instanced)
    vp = _light_view_proj(light, center, radius)
    W = H = resolution
    depth = fill(Inf, H, W)
    for mesh in meshes
        is_visible(mesh) || continue
        object_casts_shadow(mesh) || continue
        wm = compute_world_matrix(mesh); geo = mesh.geometry
        _raster_shadow_geometry!(depth, W, H, geo, vp * wm)
    end
    for im in instanced
        _visible_in_tree(im) || continue
        object_casts_shadow(im) || continue
        base = compute_world_matrix(im)
        for M in im.instance_matrices
            _raster_shadow_geometry!(depth, W, H, im.geometry, vp * base * M)
        end
    end
    return ShadowMap(depth, vp, bias, pcf_radius)
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
    c = mat4_transform_vec4(sm.light_vp, _vh(p))
    c.w <= 1e-6 && return 1.0
    ndcx = c.x / c.w; ndcy = c.y / c.w; ndcz = c.z / c.w
    (abs(ndcx) > 1 || abs(ndcy) > 1) && return 1.0          # outside the light frustum
    H, W = size(sm.depth)
    px = clamp(floor(Int, (ndcx + 1) * 0.5 * W) + 1, 1, W)
    py = clamp(floor(Int, (1 - ndcy) * 0.5 * H) + 1, 1, H)

    r = pcf_radius
    if r <= 0                                               # hard shadow: single sample
        d = sm.depth[py, px]
        isinf(d) && return 1.0
        return ndcz - sm.bias > d ? 0.0 : 1.0               # something nearer the light occludes
    end

    # Soft shadow: average the unoccluded fraction over the texel neighbourhood,
    # clamped to the map bounds. Empty (Inf) texels count as lit, matching the
    # single-sample early-out above.
    x0 = max(px - r, 1); x1 = min(px + r, W)
    y0 = max(py - r, 1); y1 = min(py + r, H)
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
function _build_shadow_query(scene, lights; resolution::Int=512, pcf_radius::Int=0)
    maps = IdDict{AbstractLight, ShadowMap}()
    for light in lights
        if !_is_fill_light(light) && hasfield(typeof(light), :cast_shadow) && getfield(light, :cast_shadow)
            maps[light] = compute_shadow_map(scene, light; resolution=resolution, pcf_radius=pcf_radius)
        end
    end
    isempty(maps) && return nothing
    return (light, p) -> haskey(maps, light) ? shadow_visibility(maps[light], p) : 1.0
end
