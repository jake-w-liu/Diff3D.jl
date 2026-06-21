# --------------------------------------------------------------------------
# Additional scene-graph objects mirroring three.js: InstancedMesh,
# LineSegments, LineLoop, Sprite, LOD, Bone/Skeleton/SkinnedMesh, plus the Layers
# bitmask and a one-pass world-matrix cache (matrixWorldAutoUpdate analogue).
# --------------------------------------------------------------------------

# ========================== Layers ==========================
# three.js channel bitmask. Default: channel 0 enabled (mask = 1).

mutable struct Layers
    mask::UInt32
end
Layers() = Layers(UInt32(1))

layers_set!(l::Layers, channel::Int)    = (l.mask = UInt32(1) << (channel & 31); l)
layers_enable!(l::Layers, channel::Int) = (l.mask |= (UInt32(1) << (channel & 31)); l)
layers_disable!(l::Layers, channel::Int)= (l.mask &= ~(UInt32(1) << (channel & 31)); l)
layers_toggle!(l::Layers, channel::Int) = (l.mask ⊻= (UInt32(1) << (channel & 31)); l)
layers_enable_all!(l::Layers)  = (l.mask = 0xffffffff; l)
layers_disable_all!(l::Layers) = (l.mask = UInt32(0); l)
"""True if two layer masks share any enabled channel (three.js `Layers.test`)."""
layers_test(a::Layers, b::Layers) = (a.mask & b.mask) != 0

# ========================== InstancedMesh ==========================
# One geometry/material drawn at many transforms with bounded extra memory.

const _INSTANCED_DRAW_MODES = (:triangles, :points, :lines, :line_loop, :line_strip)

function _validate_instanced_draw_mode(draw_mode::Symbol)
    draw_mode in _INSTANCED_DRAW_MODES ||
        throw(ArgumentError("unsupported InstancedMesh draw_mode: $draw_mode"))
    return draw_mode
end

mutable struct InstancedMesh <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    geometry::Any
    material::Any
    cast_shadow::Bool
    receive_shadow::Bool
    instance_matrices::Vector{Mat4{Float64}}
    instance_colors::Vector{Color3{Float64}}
    draw_mode::Symbol

    function InstancedMesh(position::Vec3{Float64}, rotation::Euler{Float64},
                           scale::Vec3{Float64},
                           parent::Union{Nothing, AbstractObject3D},
                           children::Vector{AbstractObject3D},
                           visible::Bool, name::String, id::Int,
                           geometry, material, cast_shadow::Bool,
                           receive_shadow::Bool,
                           instance_matrices::Vector{Mat4{Float64}},
                           instance_colors::Vector{Color3{Float64}},
                           draw_mode::Symbol)
        length(instance_colors) == length(instance_matrices) ||
            throw(ArgumentError("instance_colors length must match instance_matrices length"))
        new(position, rotation, scale, parent, children, visible, name, id,
            geometry, material, cast_shadow, receive_shadow, instance_matrices,
            instance_colors, _validate_instanced_draw_mode(draw_mode))
    end
end

function InstancedMesh(geometry, material, count::Int; name="InstancedMesh",
                       cast_shadow::Bool=false, receive_shadow::Bool=false,
                       draw_mode::Symbol=:triangles)
    count >= 0 || throw(ArgumentError("InstancedMesh count must be non-negative"))
    mats = [Mat4{Float64}() for _ in 1:count]
    colors = [Color3(1.0, 1.0, 1.0) for _ in 1:count]
    InstancedMesh(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                  true, name, _next_id(), geometry, material,
                  cast_shadow, receive_shadow, mats, colors, draw_mode)
end

function InstancedMesh(position::Vec3{Float64}, rotation::Euler{Float64},
                       scale::Vec3{Float64},
                       parent::Union{Nothing, AbstractObject3D},
                       children::Vector{AbstractObject3D},
                       visible::Bool, name::String, id::Int,
                       geometry, material, cast_shadow::Bool,
                       receive_shadow::Bool,
                       instance_matrices::Vector{Mat4{Float64}})
    InstancedMesh(position, rotation, scale, parent, children, visible, name, id,
                  geometry, material, cast_shadow, receive_shadow,
                  instance_matrices,
                  [Color3(1.0, 1.0, 1.0) for _ in instance_matrices],
                  :triangles)
end

function InstancedMesh(position::Vec3{Float64}, rotation::Euler{Float64},
                       scale::Vec3{Float64},
                       parent::Union{Nothing, AbstractObject3D},
                       children::Vector{AbstractObject3D},
                       visible::Bool, name::String, id::Int,
                       geometry, material, cast_shadow::Bool,
                       receive_shadow::Bool,
                       instance_matrices::Vector{Mat4{Float64}},
                       draw_mode::Symbol)
    InstancedMesh(position, rotation, scale, parent, children, visible, name, id,
                  geometry, material, cast_shadow, receive_shadow,
                  instance_matrices,
                  [Color3(1.0, 1.0, 1.0) for _ in instance_matrices],
                  draw_mode)
end

get_position(o::InstancedMesh) = o.position
get_rotation(o::InstancedMesh) = o.rotation
get_scale(o::InstancedMesh) = o.scale
get_children(o::InstancedMesh) = o.children
get_parent(o::InstancedMesh) = o.parent
is_visible(o::InstancedMesh) = o.visible
set_parent!(o::InstancedMesh, p) = (o.parent = p)

instanced_count(o::InstancedMesh) = length(o.instance_matrices)
set_instance_matrix!(o::InstancedMesh, i::Int, m::Mat4) = (o.instance_matrices[i] = m)
get_instance_matrix(o::InstancedMesh, i::Int) = o.instance_matrices[i]
set_instance_color!(o::InstancedMesh, i::Int, color::Color3) =
    (o.instance_colors[i] = convert(Color3{Float64}, color))
get_instance_color(o::InstancedMesh, i::Int) = o.instance_colors[i]
_instanced_triangle_drawable(o::InstancedMesh) = o.draw_mode === :triangles
_instanced_point_drawable(o::InstancedMesh) = o.draw_mode === :points
_instanced_line_drawable(o::InstancedMesh) =
    o.draw_mode === :lines || o.draw_mode === :line_loop || o.draw_mode === :line_strip

"""Collect every `InstancedMesh` under `root` (used by the rasterizer)."""
function collect_instanced(root::AbstractObject3D)
    out = InstancedMesh[]
    traverse(root, o -> o isa InstancedMesh && push!(out, o))
    return out
end

# ========================== LineSegments ==========================
# Geometry vertices interpreted as disjoint segment pairs (v1-v2, v3-v4, ...).

mutable struct LineSegments <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    geometry::Any
    material::Any
    morph_target_influences::Vector{Float64}
    morph_target_names::Vector{String}
end

function LineSegments(geometry, material; name="LineSegments",
                      morph_target_influences=Float64[], morph_target_names=String[])
    LineSegments(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                 true, name, _next_id(), geometry, material,
                 collect(Float64, morph_target_influences),
                 collect(String, morph_target_names))
end

function LineSegments(position::Vec3{Float64}, rotation::Euler{Float64},
                      scale::Vec3{Float64},
                      parent::Union{Nothing, AbstractObject3D},
                      children::Vector{AbstractObject3D},
                      visible::Bool, name::String, id::Int, geometry, material)
    LineSegments(position, rotation, scale, parent, children, visible, name, id,
                 geometry, material, Float64[], String[])
end

get_position(o::LineSegments) = o.position
get_rotation(o::LineSegments) = o.rotation
get_scale(o::LineSegments) = o.scale
get_children(o::LineSegments) = o.children
get_parent(o::LineSegments) = o.parent
is_visible(o::LineSegments) = o.visible
set_parent!(o::LineSegments, p) = (o.parent = p)
apply_morph_targets(line::LineSegments) =
    apply_morph_targets(line.geometry, line.morph_target_influences)

# ========================== LineLoop ==========================
# Geometry vertices interpreted as a closed polyline; the final vertex reconnects to the first.

mutable struct LineLoop <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    geometry::Any
    material::Any
    morph_target_influences::Vector{Float64}
    morph_target_names::Vector{String}
end

function LineLoop(geometry, material; name="LineLoop",
                  morph_target_influences=Float64[], morph_target_names=String[])
    LineLoop(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
             true, name, _next_id(), geometry, material,
             collect(Float64, morph_target_influences),
             collect(String, morph_target_names))
end

function LineLoop(position::Vec3{Float64}, rotation::Euler{Float64},
                  scale::Vec3{Float64},
                  parent::Union{Nothing, AbstractObject3D},
                  children::Vector{AbstractObject3D},
                  visible::Bool, name::String, id::Int, geometry, material)
    LineLoop(position, rotation, scale, parent, children, visible, name, id,
             geometry, material, Float64[], String[])
end

get_position(o::LineLoop) = o.position
get_rotation(o::LineLoop) = o.rotation
get_scale(o::LineLoop) = o.scale
get_children(o::LineLoop) = o.children
get_parent(o::LineLoop) = o.parent
is_visible(o::LineLoop) = o.visible
set_parent!(o::LineLoop, p) = (o.parent = p)
apply_morph_targets(line::LineLoop) =
    apply_morph_targets(line.geometry, line.morph_target_influences)

# ========================== Sprite ==========================
# A camera-facing billboard.

mutable struct Sprite <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    material::Any
    center::Vec2{Float64}
end

function Sprite(material; name="Sprite", center=Vec2(0.5, 0.5))
    Sprite(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
           true, name, _next_id(), material, center)
end

get_position(o::Sprite) = o.position
get_rotation(o::Sprite) = o.rotation
get_scale(o::Sprite) = o.scale
get_children(o::Sprite) = o.children
get_parent(o::Sprite) = o.parent
is_visible(o::Sprite) = o.visible
set_parent!(o::Sprite, p) = (o.parent = p)

"""
World matrix for a sprite: positioned at its world location, oriented so its
local axes coincide with the camera's right/up/forward axes (screen-facing).
"""
function sprite_world_matrix(sprite::Sprite, camera::AbstractCamera)
    V = view_matrix(camera)
    # Rows 1..3 of the view matrix are the camera right/up/forward axes in world space.
    right = Vec3(mat4_get(V,1,1), mat4_get(V,1,2), mat4_get(V,1,3))
    up    = Vec3(mat4_get(V,2,1), mat4_get(V,2,2), mat4_get(V,2,3))
    fwd   = Vec3(mat4_get(V,3,1), mat4_get(V,3,2), mat4_get(V,3,3))
    wm = compute_world_matrix(sprite)
    p = Vec3(mat4_get(wm,1,4), mat4_get(wm,2,4), mat4_get(wm,3,4))
    # World scale = column norms of the world matrix (as in the WebGL sprite shader).
    sx = sqrt(mat4_get(wm,1,1)^2 + mat4_get(wm,2,1)^2 + mat4_get(wm,3,1)^2)
    sy = sqrt(mat4_get(wm,1,2)^2 + mat4_get(wm,2,2)^2 + mat4_get(wm,3,2)^2)
    sz = sqrt(mat4_get(wm,1,3)^2 + mat4_get(wm,2,3)^2 + mat4_get(wm,3,3)^2)
    Mat4((right.x*sx, right.y*sx, right.z*sx, 0.0,
          up.x*sy,    up.y*sy,    up.z*sy,    0.0,
          fwd.x*sz,   fwd.y*sz,   fwd.z*sz,   0.0,
          p.x,        p.y,        p.z,        1.0))
end

# ========================== LOD ==========================
# Level-of-detail container: child objects keyed by minimum camera distance.

mutable struct LOD <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    levels::Vector{Tuple{Float64, Float64, AbstractObject3D}}   # (min distance, hysteresis, object), ascending
end

function LOD(; name="LOD")
    LOD(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
        true, name, _next_id(), Tuple{Float64, Float64, AbstractObject3D}[])
end

get_position(o::LOD) = o.position
get_rotation(o::LOD) = o.rotation
get_scale(o::LOD) = o.scale
get_children(o::LOD) = o.children
get_parent(o::LOD) = o.parent
is_visible(o::LOD) = o.visible
set_parent!(o::LOD, p) = (o.parent = p)

function add_lod_level!(lod::LOD, distance::Real, obj::AbstractObject3D; hysteresis::Real=0.0)
    dist = Float64(distance)
    hyst = Float64(hysteresis)
    isfinite(dist) && dist >= 0 || throw(ArgumentError("LOD distance must be finite and non-negative"))
    isfinite(hyst) && hyst >= 0 || throw(ArgumentError("LOD hysteresis must be finite and non-negative"))
    push!(lod.levels, (dist, hyst, obj))
    add!(lod, obj)
    sort!(lod.levels, by = first)
    return lod
end

"""Highest-distance LOD level whose threshold ≤ `distance` (three.js `getObjectForDistance`)."""
function lod_select(lod::LOD, distance::Real)
    isempty(lod.levels) && return nothing
    chosen = lod.levels[1][3]
    for (d, _, obj) in lod.levels
        distance >= d ? (chosen = obj) : break
    end
    return chosen
end

"""
Update child visibility using three.js-style LOD thresholds and hysteresis.
Returns the selected level object, or `nothing` when the LOD has no levels.
"""
function lod_update!(lod::LOD, distance::Real)
    isempty(lod.levels) && return nothing
    d = Float64(distance)
    isfinite(d) || throw(ArgumentError("LOD update distance must be finite"))

    chosen_index = 1
    for i in 2:length(lod.levels)
        threshold, hysteresis, obj = lod.levels[i]
        level_distance = is_visible(obj) ? threshold * (1 - hysteresis) : threshold
        if d >= level_distance
            chosen_index = i
        else
            break
        end
    end

    for (i, (_, _, obj)) in enumerate(lod.levels)
        hasproperty(obj, :visible) && setproperty!(obj, :visible, i == chosen_index)
    end
    return lod.levels[chosen_index][3]
end

# ========================== Bone / Skeleton / SkinnedMesh ==========================

mutable struct Bone <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
end

function Bone(; name="Bone")
    Bone(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
         true, name, _next_id())
end

get_position(o::Bone) = o.position
get_rotation(o::Bone) = o.rotation
get_scale(o::Bone) = o.scale
get_children(o::Bone) = o.children
get_parent(o::Bone) = o.parent
is_visible(o::Bone) = o.visible
set_parent!(o::Bone, p) = (o.parent = p)

mutable struct Skeleton
    bones::Vector{Bone}
    bind_inverses::Vector{Mat4{Float64}}   # inverse of each bone's bind-pose world matrix
end

function calculate_inverses!(s::Skeleton)
    s.bind_inverses = [mat4_inverse(compute_world_matrix(b)) for b in s.bones]
    return s
end

"""Build a skeleton, capturing the current bone world matrices as the bind pose."""
function Skeleton(bones::Vector{Bone})
    Skeleton(bones, [mat4_inverse(compute_world_matrix(b)) for b in bones])
end

"""Per-bone skinning matrix = current world × inverse bind (identity in bind pose)."""
function skeleton_matrices(s::Skeleton)
    length(s.bind_inverses) == length(s.bones) ||
        error("skeleton bind_inverses length must match bones length")
    [compute_world_matrix(s.bones[i]) * s.bind_inverses[i] for i in eachindex(s.bones)]
end

mutable struct SkinnedMesh <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    geometry::Any
    material::Any
    cast_shadow::Bool
    receive_shadow::Bool
    skeleton::Skeleton
    skin_indices::Vector{NTuple{4,Int}}     # bone indices per vertex (1-based)
    skin_weights::Vector{NTuple{4,Float64}} # blend weights per vertex
    morph_target_influences::Vector{Float64}
    morph_target_names::Vector{String}
    bind_mode::Symbol                       # :attached or :detached
    bind_matrix::Mat4{Float64}
    bind_matrix_inverse::Mat4{Float64}
end

function SkinnedMesh(geometry, material, skeleton::Skeleton,
                     skin_indices, skin_weights; name="SkinnedMesh",
                     cast_shadow::Bool=false, receive_shadow::Bool=false,
                     morph_target_influences=Float64[], morph_target_names=String[],
                     bind_mode::Symbol=:attached, bind_matrix::Mat4{Float64}=Mat4())
    bind_mode in (:attached, :detached) ||
        throw(ArgumentError("SkinnedMesh bind_mode must be :attached or :detached"))
    SkinnedMesh(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                true, name, _next_id(), geometry, material,
                cast_shadow, receive_shadow, skeleton,
                skin_indices, skin_weights,
                collect(Float64, morph_target_influences),
                collect(String, morph_target_names),
                bind_mode, bind_matrix, mat4_inverse(bind_matrix))
end

get_position(o::SkinnedMesh) = o.position
get_rotation(o::SkinnedMesh) = o.rotation
get_scale(o::SkinnedMesh) = o.scale
get_children(o::SkinnedMesh) = o.children
get_parent(o::SkinnedMesh) = o.parent
is_visible(o::SkinnedMesh) = o.visible
set_parent!(o::SkinnedMesh, p) = (o.parent = p)
apply_morph_targets(mesh::SkinnedMesh) =
    apply_morph_targets(mesh.geometry, mesh.morph_target_influences)
apply_morph_normals(mesh::SkinnedMesh) =
    apply_morph_normals(mesh.geometry, mesh.morph_target_influences)
apply_morph_tangents(mesh::SkinnedMesh) =
    apply_morph_tangents(mesh.geometry, mesh.morph_target_influences)

function bind_skeleton!(sm::SkinnedMesh, skeleton::Skeleton,
                        bind_matrix::Union{Nothing,Mat4{Float64}}=nothing;
                        bind_mode::Symbol=sm.bind_mode,
                        calculate_inverses::Bool=bind_matrix === nothing)
    bind_mode in (:attached, :detached) ||
        throw(ArgumentError("SkinnedMesh bind_mode must be :attached or :detached"))
    sm.skeleton = skeleton
    calculate_inverses && calculate_inverses!(skeleton)
    matrix = bind_matrix === nothing ? compute_world_matrix(sm) : bind_matrix
    sm.bind_mode = bind_mode
    sm.bind_matrix = matrix
    sm.bind_matrix_inverse = mat4_inverse(matrix)
    return sm
end

_skinned_bind_matrix_inverse(sm::SkinnedMesh) =
    sm.bind_mode === :attached ? mat4_inverse(compute_world_matrix(sm)) :
    sm.bind_matrix_inverse

function _skinning_matrices(sm::SkinnedMesh)
    bind = sm.bind_matrix
    bind_inv = _skinned_bind_matrix_inverse(sm)
    [bind_inv * m * bind for m in skeleton_matrices(sm.skeleton)]
end

"""
Linear blend skinning: deform each geometry vertex by the weighted sum of its
bones' skinning matrices. Returns `Vector{Vec3}` of deformed positions.
"""
function apply_skinning(sm::SkinnedMesh)
    mats = _skinning_matrices(sm)
    geo = sm.geometry
    morphed = !isempty(sm.morph_target_influences) ? apply_morph_targets(sm) : nothing
    out = Vector{Vec3{Float64}}(undef, geo.n_vertices)
    @inbounds for vi in 1:geo.n_vertices
        p = morphed === nothing ? get_vertex(geo, vi) : morphed[vi]
        idx = sm.skin_indices[vi]; w = sm.skin_weights[vi]
        acc = Vec3(0.0, 0.0, 0.0)
        for k in 1:4
            wk = w[k]
            wk == 0 && continue
            acc = acc + mat4_transform_point(mats[idx[k]], p) * wk
        end
        out[vi] = acc
    end
    return out
end

function _skin_direction(mats, idx::NTuple{4,Int}, w::NTuple{4,Float64}, d::Vec3)
    acc = Vec3(0.0, 0.0, 0.0)
    @inbounds for k in 1:4
        wk = w[k]
        wk == 0 && continue
        acc = acc + mat4_transform_direction(mats[idx[k]], d) * wk
    end
    return normalize(acc)
end

function _skin_normal_buffer(sm::SkinnedMesh, mats)
    geo = sm.geometry
    normals = isempty(sm.morph_target_influences) ? geo.normals : apply_morph_normals(sm)
    length(normals) >= geo.n_vertices * 3 || return copy(normals)
    out = Vector{Float64}(undef, geo.n_vertices * 3)
    @inbounds for vi in 1:geo.n_vertices
        base = 3vi - 2
        n = Vec3(normals[base], normals[base + 1], normals[base + 2])
        sn = _skin_direction(mats, sm.skin_indices[vi], sm.skin_weights[vi], n)
        out[base] = sn.x
        out[base + 1] = sn.y
        out[base + 2] = sn.z
    end
    return out
end

function _skin_tangent_attribute(sm::SkinnedMesh, attr::BufferAttribute, mats,
                                 tangent_data=attr.data)
    geo = sm.geometry
    attr.item_size >= 3 && length(tangent_data) >= geo.n_vertices * attr.item_size ||
        return copy(tangent_data)
    out = Float64.(copy(tangent_data))
    @inbounds for vi in 1:geo.n_vertices
        base = (vi - 1) * attr.item_size + 1
        t = Vec3(Float64(tangent_data[base]), Float64(tangent_data[base + 1]), Float64(tangent_data[base + 2]))
        st = _skin_direction(mats, sm.skin_indices[vi], sm.skin_weights[vi], t)
        out[base] = st.x
        out[base + 1] = st.y
        out[base + 2] = st.z
    end
    return out
end

function _copy_skinned_attributes(sm::SkinnedMesh, mats)
    attrs = Dict{Symbol, BufferAttribute}()
    for (name, attr) in sm.geometry.attributes
        data = if name === :tangent
            tangent_data = isempty(sm.morph_target_influences) ? attr.data : apply_morph_tangents(sm)
            _skin_tangent_attribute(sm, attr, mats, tangent_data)
        else
            copy(attr.data)
        end
        attrs[name] = BufferAttribute(data, attr.item_size)
    end
    return attrs
end

function _skinned_render_geometry(sm::SkinnedMesh)
    geo = sm.geometry
    mats = _skinning_matrices(sm)
    positions = Vector{Float64}(undef, geo.n_vertices * 3)
    skinned = apply_skinning(sm)
    @inbounds for vi in 1:geo.n_vertices
        base = 3vi - 2
        p = skinned[vi]
        positions[base] = p.x
        positions[base + 1] = p.y
        positions[base + 2] = p.z
    end
    BufferGeometry(positions, _skin_normal_buffer(sm, mats), copy(geo.uvs),
                   copy(geo.indices), geo.n_vertices, geo.n_faces,
                   _copy_skinned_attributes(sm, mats), copy(geo.groups))
end

function _skinned_render_mesh(sm::SkinnedMesh)
    Mesh(sm.position, sm.rotation, sm.scale, sm.parent, AbstractObject3D[],
         sm.visible, sm.name, sm.id, _skinned_render_geometry(sm), sm.material,
         nothing, sm.cast_shadow, sm.receive_shadow, Float64[], String[])
end

function _collect_skinned_meshes!(out::Vector{SkinnedMesh}, obj::AbstractObject3D)
    is_visible(obj) || return nothing
    obj isa SkinnedMesh && push!(out, obj)
    for child in get_children(obj)
        _collect_skinned_meshes!(out, child)
    end
    return nothing
end

function _append_skinned_render_meshes!(meshes::Vector{Mesh}, scene::AbstractObject3D)
    skinned = SkinnedMesh[]
    _collect_skinned_meshes!(skinned, scene)
    for sm in skinned
        push!(meshes, _skinned_render_mesh(sm))
    end
    return meshes
end

# ========================== World-matrix cache ==========================
# One traversal pass computing every object's world matrix (each child reuses
# its parent's already-computed matrix), instead of walking to the root per
# object. Mirrors three.js `updateMatrixWorld` done once per frame.

function compute_world_matrices(root::AbstractObject3D,
                                parent_world::Mat4,
                                cache::IdDict{AbstractObject3D, Mat4})
    world = parent_world * compute_local_matrix(root)
    cache[root] = world
    for child in get_children(root)
        compute_world_matrices(child, world, cache)
    end
    return cache
end

function compute_world_matrices(root::AbstractObject3D)
    cache = IdDict{AbstractObject3D, Mat4}()
    compute_world_matrices(root, Mat4{Float64}(), cache)
    return cache
end
