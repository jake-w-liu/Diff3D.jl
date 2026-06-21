# --------------------------------------------------------------------------
# Raycaster: ray-mesh intersection for picking and queries (three.js Raycaster).
# Uses the Möller–Trumbore algorithm against world-space triangles.
# --------------------------------------------------------------------------

struct Intersection
    distance::Float64
    point::Vec3{Float64}
    object::AbstractObject3D
    face_index::Int
end

"""
Möller–Trumbore ray/triangle test. Returns the ray parameter `t > 0` at the
hit, or `nothing` if the ray misses. `dir` need not be normalised; `t` is then
in units of `dir`. `side` culls by winding like three.js `Ray.intersectTriangle`:
`:front` rejects backfaces, `:back` rejects frontfaces, `:double` accepts both.
"""
function ray_triangle_intersect(origin::Vec3, dir::Vec3, a::Vec3, b::Vec3, c::Vec3;
                                eps=1e-9, side::Symbol=:double)
    e1 = b - a; e2 = c - a
    p = cross(dir, e2)
    det = dot(e1, p)                             # det = -dot(dir, cross(e1, e2))
    if side === :front
        det <= eps && return nothing             # backfacing or parallel
    elseif side === :back
        det >= -eps && return nothing            # frontfacing or parallel
    else
        abs(det) < eps && return nothing         # ray parallel to triangle
    end
    inv_det = 1 / det
    tvec = origin - a
    u = dot(tvec, p) * inv_det
    (u < 0 || u > 1) && return nothing
    q = cross(tvec, e1)
    v = dot(dir, q) * inv_det
    (v < 0 || u + v > 1) && return nothing
    t = dot(e2, q) * inv_det
    return t > eps ? t : nothing
end

mutable struct Raycaster
    ray::Ray{Float64}
    near::Float64
    far::Float64
    layers::Layers           # only objects sharing a channel are tested (three.js Raycaster.layers)
    point_threshold::Float64 # world-space pick radius for PointsObject vertices (three.js params.Points.threshold)
    line_threshold::Float64  # world-space pick radius for Line/LineSegments segments (three.js params.Line.threshold)
end
Raycaster(origin::Vec3, dir::Vec3; near=0.0, far=Inf,
          layers::Layers=layers_enable_all!(Layers()),
          point_threshold=1.0, line_threshold=1.0) =
    Raycaster(Ray(Vec3(Float64(origin.x), Float64(origin.y), Float64(origin.z)),
                  normalize(Vec3(Float64(dir.x), Float64(dir.y), Float64(dir.z)))),
              Float64(near), Float64(far), layers,
              Float64(point_threshold), Float64(line_threshold))

const _OBJECT_LAYER_STORE = WeakKeyDict{AbstractObject3D, Layers}()
const _OBJECT_LAYER_LOCK = ReentrantLock()

"""
Layers mask attached to `obj`. Scene-graph objects need not carry a `layers`
field; absent one, `object_layers` initializes persistent channel-0 state.
"""
function object_layers(obj::AbstractObject3D)
    hasproperty(obj, :layers) && return getfield(obj, :layers)
    lock(_OBJECT_LAYER_LOCK)
    try
        return get!(_OBJECT_LAYER_STORE, obj) do
            Layers()
        end
    finally
        unlock(_OBJECT_LAYER_LOCK)
    end
end

# Distance from point `p` to the ray, and the ray parameter `t` (in units of the
# ray direction `d`, which `Raycaster` keeps normalised) at the closest approach.
# Returns `(t, dist)`; the projection is clamped to `t >= 0` so points behind the
# origin report their straight-line distance to the origin (three.js behaviour).
function _ray_point_distance(o::Vec3, d::Vec3, p::Vec3)
    w = p - o
    t = dot(w, d)
    if t < 0
        return (zero(t), norm(w))
    end
    closest = o + d * t
    return (t, norm(p - closest))
end

# Shortest distance between the ray (origin `o`, unit dir `d`) and the segment
# `[a, b]`, plus the ray parameter `t_ray >= 0` at the closest approach on the
# ray and the point `seg_pt` on the segment. Closed-form minimisation of
# |o + t*d - (a + s*seg)|^2 over t >= 0, s in [0,1] (cf. three.js
# `Ray.distanceSqToSegment`), returning the unsquared distance.
function _ray_segment_distance(o::Vec3, d::Vec3, a::Vec3, b::Vec3)
    seg = b - a
    B = dot(d, seg)            # d·seg
    C = dot(seg, seg)          # seg·seg = |seg|^2 (A = d·d = 1, d is unit)
    w0 = o - a
    D = dot(d, w0)             # d·(o-a)
    E = dot(seg, w0)           # seg·(o-a)
    denom = C - B * B          # A*C - B^2 with A = 1; >= 0 (Cauchy–Schwarz)
    if denom > eps(Float64) * (C + one(C))
        s_seg = (E - B * D) / denom        # = (A*E - B*D)/denom with A = 1
    else
        # Ray parallel to the segment: project the origin onto the segment line.
        s_seg = C > 0 ? E / C : zero(C)
    end
    s_seg = clamp(s_seg, zero(s_seg), one(s_seg))
    # Closest ray parameter for the clamped segment point. If it falls behind
    # the origin, clamp t to 0 and re-solve s on that face: project the ray
    # ORIGIN onto the segment (three.js `Ray.distanceSqToSegment` region case).
    seg_pt = a + seg * s_seg
    raw_t = dot(seg_pt - o, d)
    if raw_t < 0
        t_ray = zero(raw_t)
        s_seg = clamp(C > 0 ? E / C : zero(C), zero(C), one(C))
        seg_pt = a + seg * s_seg
    else
        t_ray = raw_t
    end
    ray_pt = o + d * t_ray
    return (t_ray, norm(ray_pt - seg_pt), seg_pt)
end

# Build the world-space ray through normalized device coords (x,y ∈ [-1,1]).
function _camera_ray(camera::AbstractCamera, ndc_x, ndc_y)
    inv_vp = mat4_inverse(projection_matrix(camera) * view_matrix(camera))
    p_near = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, -1.0))
    p_far  = mat4_transform_point(inv_vp, Vec3(ndc_x, ndc_y, 1.0))
    # Perspective rays originate at the camera apex; orthographic rays originate
    # at the unprojected near-plane point because they do not share an apex.
    origin = camera isa PerspectiveCamera ? camera.position : p_near
    Ray(origin, normalize(p_far - p_near))
end

"""Aim the raycaster through screen NDC `(x,y)` from a camera (three.js `setFromCamera`)."""
function set_from_camera!(rc::Raycaster, camera::AbstractCamera, ndc_x, ndc_y)
    rc.ray = _camera_ray(camera, ndc_x, ndc_y)
    return rc
end

# Test a single object's own geometry against the ray, appending any hits to
# `hits`. Layers and visibility are already checked by the caller. Mesh uses the
# Möller–Trumbore triangle path; PointsObject uses per-vertex pick radius;
# LineObject/LineSegments use per-segment pick radius. Other object types (Group,
# Scene, Bone, Sprite, ...) carry no testable geometry and add nothing.
function _raycast_object!(hits::Vector{Intersection}, rc::Raycaster, obj::AbstractObject3D)
    o = rc.ray.origin; d = rc.ray.direction
    if obj isa Mesh
        wm = compute_world_matrix(obj)
        geo = obj.geometry
        # Cull by material side like three.js Mesh.raycast (default :front).
        side = material_side(obj.material)
        @inbounds for fi in _draw_face_range(geo)
            i1, i2, i3 = get_face(geo, fi)
            a = mat4_transform_point(wm, get_vertex(geo, i1))
            b = mat4_transform_point(wm, get_vertex(geo, i2))
            c = mat4_transform_point(wm, get_vertex(geo, i3))
            t = ray_triangle_intersect(o, d, a, b, c; side=side)
            if t !== nothing && rc.near <= t <= rc.far
                push!(hits, Intersection(t, o + d * t, obj, fi))
            end
        end
    elseif obj isa PointsObject
        wm = compute_world_matrix(obj)
        geo = obj.geometry
        morphed_positions = _object_morph_positions(obj, geo)
        thr = rc.point_threshold
        @inbounds for entry in _draw_entry_range(geo)
            vi = _draw_vertex_index(geo, entry)
            p = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi))
            t, dist = _ray_point_distance(o, d, p)
            if dist < thr && rc.near <= t <= rc.far
                # Report the point itself as the hit location; face_index = vertex index.
                push!(hits, Intersection(t, p, obj, vi))
            end
        end
    elseif obj isa LineObject || obj isa LineSegments || obj isa LineLoop
        wm = compute_world_matrix(obj)
        geo = obj.geometry
        morphed_positions = _object_morph_positions(obj, geo)
        thr = rc.line_threshold
        # LineSegments: disjoint pairs. LineObject: consecutive vertices.
        # LineLoop closes the final vertex back to the first, matching three.js.
        step = obj isa LineSegments ? 2 : 1
        entries = _draw_entry_range(geo)
        isempty(entries) && return hits
        first_entry = first(entries)
        last_entry = last(entries)
        @inbounds for entry in first_entry:step:(last_entry - 1)
            vi1 = _draw_vertex_index(geo, entry)
            vi2 = _draw_vertex_index(geo, entry + 1)
            a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi1))
            b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi2))
            t, dist, seg_pt = _ray_segment_distance(o, d, a, b)
            if dist < thr && rc.near <= t <= rc.far
                # face_index = the segment's start vertex index (three.js index).
                push!(hits, Intersection(t, seg_pt, obj, vi1))
            end
        end
        if obj isa LineLoop && last_entry - first_entry + 1 > 2
            vi1 = _draw_vertex_index(geo, last_entry)
            vi2 = _draw_vertex_index(geo, first_entry)
            a = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi1))
            b = mat4_transform_point(wm, _geometry_vertex(geo, morphed_positions, vi2))
            t, dist, seg_pt = _ray_segment_distance(o, d, a, b)
            if dist < thr && rc.near <= t <= rc.far
                push!(hits, Intersection(t, seg_pt, obj, vi1))
            end
        end
    end
    return hits
end

"""
    raycast(rc, root; recursive=true)

Intersect the ray with `root` and (when `recursive`) every descendant, returning
`Intersection`s sorted by distance (nearest first) and filtered to `[near, far]`.

Meshes are tested with the Möller–Trumbore triangle path; `PointsObject`
vertices and `LineObject`/`LineSegments` segments use the raycaster's
`point_threshold`/`line_threshold` pick radii (three.js `params.Points`/`Line`).
Objects whose layer mask shares no channel with `rc.layers` are skipped (their
children are still traversed when `recursive`). Invisible objects are skipped
hierarchically, matching the renderer: an object inside a `visible = false`
ancestor is not pickable.
"""
function raycast(rc::Raycaster, root::AbstractObject3D; recursive::Bool=true)
    hits = Intersection[]
    if recursive
        traverse(root, obj -> begin
            (_visible_in_tree(obj) && layers_test(object_layers(obj), rc.layers)) &&
                _raycast_object!(hits, rc, obj)
        end)
    else
        if _visible_in_tree(root) && layers_test(object_layers(root), rc.layers)
            _raycast_object!(hits, rc, root)
        end
    end
    sort!(hits, by = h -> h.distance)
    return hits
end
