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
end

function InstancedMesh(geometry, material, count::Int; name="InstancedMesh",
                       cast_shadow::Bool=false, receive_shadow::Bool=false)
    mats = [Mat4{Float64}() for _ in 1:count]
    InstancedMesh(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                  true, name, _next_id(), geometry, material,
                  cast_shadow, receive_shadow, mats)
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
end

function LineSegments(geometry, material; name="LineSegments")
    LineSegments(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                 true, name, _next_id(), geometry, material)
end

get_position(o::LineSegments) = o.position
get_rotation(o::LineSegments) = o.rotation
get_scale(o::LineSegments) = o.scale
get_children(o::LineSegments) = o.children
get_parent(o::LineSegments) = o.parent
is_visible(o::LineSegments) = o.visible
set_parent!(o::LineSegments, p) = (o.parent = p)

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
end

function LineLoop(geometry, material; name="LineLoop")
    LineLoop(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
             true, name, _next_id(), geometry, material)
end

get_position(o::LineLoop) = o.position
get_rotation(o::LineLoop) = o.rotation
get_scale(o::LineLoop) = o.scale
get_children(o::LineLoop) = o.children
get_parent(o::LineLoop) = o.parent
is_visible(o::LineLoop) = o.visible
set_parent!(o::LineLoop, p) = (o.parent = p)

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
    p = get_position(sprite); s = get_scale(sprite)
    Mat4((right.x*s.x, right.y*s.x, right.z*s.x, 0.0,
          up.x*s.y,    up.y*s.y,    up.z*s.y,    0.0,
          fwd.x*s.z,   fwd.y*s.z,   fwd.z*s.z,   0.0,
          p.x,         p.y,         p.z,         1.0))
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

"""Build a skeleton, capturing the current bone world matrices as the bind pose."""
function Skeleton(bones::Vector{Bone})
    binv = [mat4_inverse(compute_world_matrix(b)) for b in bones]
    Skeleton(bones, binv)
end

"""Per-bone skinning matrix = current world × inverse bind (identity in bind pose)."""
skeleton_matrices(s::Skeleton) =
    [compute_world_matrix(s.bones[i]) * s.bind_inverses[i] for i in eachindex(s.bones)]

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
end

function SkinnedMesh(geometry, material, skeleton::Skeleton,
                     skin_indices, skin_weights; name="SkinnedMesh",
                     cast_shadow::Bool=false, receive_shadow::Bool=false)
    SkinnedMesh(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
                true, name, _next_id(), geometry, material,
                cast_shadow, receive_shadow, skeleton,
                skin_indices, skin_weights)
end

get_position(o::SkinnedMesh) = o.position
get_rotation(o::SkinnedMesh) = o.rotation
get_scale(o::SkinnedMesh) = o.scale
get_children(o::SkinnedMesh) = o.children
get_parent(o::SkinnedMesh) = o.parent
is_visible(o::SkinnedMesh) = o.visible
set_parent!(o::SkinnedMesh, p) = (o.parent = p)

"""
Linear blend skinning: deform each geometry vertex by the weighted sum of its
bones' skinning matrices. Returns `Vector{Vec3}` of deformed positions.
"""
function apply_skinning(sm::SkinnedMesh)
    mats = skeleton_matrices(sm.skeleton)
    geo = sm.geometry
    out = Vector{Vec3{Float64}}(undef, geo.n_vertices)
    @inbounds for vi in 1:geo.n_vertices
        p = get_vertex(geo, vi)
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
