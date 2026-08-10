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

@noinline function _throw_instanced_matrix(context::String, index::Int)
    throw(ArgumentError("$context instance matrix $index must be finite"))
end

@inline function _validate_instance_matrix(matrix::Mat4, context::String,
                                           index::Int)
    @inbounds for value in matrix.e
        isfinite(value) || _throw_instanced_matrix(context, index)
    end
    return nothing
end

@noinline function _throw_instanced_color(context::String, index::Int)
    throw(ArgumentError("$context instance color $index must be finite"))
end

@inline function _validate_instance_color(color::Color3, context::String,
                                          index::Int)
    isfinite(color.r) && isfinite(color.g) && isfinite(color.b) ||
        _throw_instanced_color(context, index)
    return nothing
end

function _validate_instanced_data(instance_matrices::Vector{Mat4{Float64}},
                                  instance_colors::Vector{Color3{Float64}},
                                  context::String)
    length(instance_colors) == length(instance_matrices) ||
        throw(ArgumentError(
            "$context instance_colors length must match instance_matrices length"))
    @inbounds for index in eachindex(instance_matrices)
        _validate_instance_matrix(instance_matrices[index], context, index)
        _validate_instance_color(instance_colors[index], context, index)
    end
    return nothing
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
        _validate_instanced_data(instance_matrices, instance_colors,
                                 "InstancedMesh")
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

function InstancedMesh(geometry, material,
                       instance_matrices::Vector{Mat4{Float64}};
                       name="InstancedMesh",
                       cast_shadow::Bool=false, receive_shadow::Bool=false,
                       draw_mode::Symbol=:triangles)
    colors = [Color3(1.0, 1.0, 1.0) for _ in eachindex(instance_matrices)]
    InstancedMesh(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0), nothing,
                  AbstractObject3D[], true, name, _next_id(), geometry,
                  material, cast_shadow, receive_shadow, instance_matrices,
                  colors, draw_mode)
end

function InstancedMesh(geometry, material,
                       instance_matrices::AbstractVector{<:Mat4}; kwargs...)
    matrices = Mat4{Float64}[
        convert(Mat4{Float64}, matrix) for matrix in instance_matrices
    ]
    return InstancedMesh(geometry, material, matrices; kwargs...)
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
function set_instance_matrix!(o::InstancedMesh, i::Int, m::Mat4)
    matrix = convert(Mat4{Float64}, m)
    _validate_instance_matrix(matrix, "InstancedMesh", i)
    o.instance_matrices[i] = matrix
    return matrix
end
get_instance_matrix(o::InstancedMesh, i::Int) = o.instance_matrices[i]
function set_instance_color!(o::InstancedMesh, i::Int, color::Color3)
    converted = convert(Color3{Float64}, color)
    _validate_instance_color(converted, "InstancedMesh", i)
    o.instance_colors[i] = converted
    return converted
end
get_instance_color(o::InstancedMesh, i::Int) = o.instance_colors[i]
_instanced_triangle_drawable(o::InstancedMesh) = o.draw_mode === :triangles
_instanced_point_drawable(o::InstancedMesh) = o.draw_mode === :points
_instanced_line_drawable(o::InstancedMesh) =
    o.draw_mode === :lines || o.draw_mode === :line_loop || o.draw_mode === :line_strip

function _validate_instanced_mesh(o::InstancedMesh, context::String)
    _validate_instanced_draw_mode(o.draw_mode)
    _validate_instanced_data(o.instance_matrices, o.instance_colors, context)
    return nothing
end

"""Collect every `InstancedMesh` under `root` (used by the rasterizer)."""
function _count_instanced(root::AbstractObject3D)
    n = root isa InstancedMesh ? 1 : 0
    @inbounds for child in get_children(root)
        n += _count_instanced(child)
    end
    return n
end

function _fill_instanced!(out::Vector{InstancedMesh}, root::AbstractObject3D, i::Int)
    if root isa InstancedMesh
        out[i] = root
        i += 1
    end
    @inbounds for child in get_children(root)
        i = _fill_instanced!(out, child, i)
    end
    return i
end

function collect_instanced(root::AbstractObject3D)
    out = Vector{InstancedMesh}(undef, _count_instanced(root))
    _fill_instanced!(out, root, 1)
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
function sprite_world_matrix(sprite::Sprite, camera::AbstractCamera,
                             wm::Mat4=compute_world_matrix(sprite))
    world = convert(Mat4{Float64}, wm)
    V = view_matrix(camera)
    # Rows 1..3 of the view matrix are the camera right/up/forward axes in world space.
    right = Vec3(mat4_get(V,1,1), mat4_get(V,1,2), mat4_get(V,1,3))
    up    = Vec3(mat4_get(V,2,1), mat4_get(V,2,2), mat4_get(V,2,3))
    fwd   = Vec3(mat4_get(V,3,1), mat4_get(V,3,2), mat4_get(V,3,3))
    p = Vec3(mat4_get(world,1,4), mat4_get(world,2,4), mat4_get(world,3,4))
    # World scale = column norms of the world matrix (as in the WebGL sprite shader).
    sx = _mat4_linear_column_norm(world, 1)
    sy = _mat4_linear_column_norm(world, 2)
    sz = _mat4_linear_column_norm(world, 3)
    Mat4((right.x*sx, right.y*sx, right.z*sx, 0.0,
          up.x*sy,    up.y*sy,    up.z*sy,    0.0,
          fwd.x*sz,   fwd.y*sz,   fwd.z*sz,   0.0,
          p.x,        p.y,        p.z,        1.0))
end

# ========================== LOD ==========================
# Level-of-detail container: child objects keyed by minimum camera distance.

struct LODLevel
    distance::Float64
    hysteresis::Float64
    object::AbstractObject3D
end

# Preserve the tuple-like surface used by existing code while keeping each
# level's scalar fields in a concrete layout. A vector of abstract-field tuples
# boxes every scalar field access on Julia 1.10 and 1.12.
Base.length(::LODLevel) = 3
Base.firstindex(::LODLevel) = 1
Base.lastindex(::LODLevel) = 3
Base.first(level::LODLevel) = level.distance

@inline function Base.getindex(level::LODLevel, index::Int)
    index == 1 && return level.distance
    index == 2 && return level.hysteresis
    index == 3 && return level.object
    throw(BoundsError(level, index))
end

@inline function Base.iterate(level::LODLevel, index::Int=1)
    index > 3 && return nothing
    return (level[index], index + 1)
end

mutable struct LOD <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    levels::Vector{LODLevel}   # ascending by minimum distance
end

function LOD(; name="LOD")
    LOD(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
        true, name, _next_id(), LODLevel[])
end

get_position(o::LOD) = o.position
get_rotation(o::LOD) = o.rotation
get_scale(o::LOD) = o.scale
get_children(o::LOD) = o.children
get_parent(o::LOD) = o.parent
is_visible(o::LOD) = o.visible
set_parent!(o::LOD, p) = (o.parent = p)

@noinline function _throw_lod_distance(label::String)
    throw(ArgumentError("$label must be finite and non-negative"))
end

@inline function _validated_lod_distance(value, label::String)
    value isa Real && !(value isa Bool) || _throw_lod_distance(label)
    result = Float64(value)
    isfinite(result) && result >= 0.0 || _throw_lod_distance(label)
    return result
end

@noinline function _throw_lod_hysteresis()
    throw(ArgumentError("LOD hysteresis must be finite and between 0 and 1"))
end

@inline function _validated_lod_hysteresis(value)
    value isa Real && !(value isa Bool) || _throw_lod_hysteresis()
    result = Float64(value)
    isfinite(result) && 0.0 <= result <= 1.0 || _throw_lod_hysteresis()
    return result
end

function _validate_lod_levels(lod::LOD, context::String)
    previous_distance = -Inf
    @inbounds for index in eachindex(lod.levels)
        level = lod.levels[index]
        distance = level.distance
        _validated_lod_distance(distance, "LOD level distance")
        _validated_lod_hysteresis(level.hysteresis)
        distance >= previous_distance ||
            throw(ArgumentError("$context levels must be sorted by distance"))
        get_parent(level.object) === lod ||
            throw(ArgumentError(
                "$context level $index object must be a child of the LOD"))
        previous_distance = distance
    end
    return nothing
end

function add_lod_level!(lod::LOD, distance, obj::AbstractObject3D;
                        hysteresis=0.0)
    dist = _validated_lod_distance(distance, "LOD distance")
    hyst = _validated_lod_hysteresis(hysteresis)
    # add! first: it can throw (cycle/self guards). Pushing the level entry only
    # after it succeeds avoids leaving a phantom level whose object is not a child.
    add!(lod, obj)
    push!(lod.levels, LODLevel(dist, hyst, obj))
    sort!(lod.levels, by = first)
    return lod
end

function remove!(lod::LOD, child::AbstractObject3D)
    children = get_children(lod)
    index = findfirst(candidate -> candidate === child, children)
    if index !== nothing
        deleteat!(children, index)
        set_parent!(child, nothing)
    end
    filter!(level -> level.object !== child, lod.levels)
    return lod
end

"""Highest-distance LOD level whose threshold ≤ `distance` (three.js `getObjectForDistance`)."""
function lod_select(lod::LOD, distance)
    query_distance = _validated_lod_distance(distance, "LOD query distance")
    _validate_lod_levels(lod, "LOD")
    isempty(lod.levels) && return nothing
    chosen = lod.levels[1].object
    for level in lod.levels
        query_distance >= level.distance ? (chosen = level.object) : break
    end
    return chosen
end

"""
Update child visibility using three.js-style LOD thresholds and hysteresis.
Returns the selected level object, or `nothing` when the LOD has no levels.
"""
function lod_update!(lod::LOD, distance)
    d = _validated_lod_distance(distance, "LOD update distance")
    _validate_lod_levels(lod, "LOD")
    isempty(lod.levels) && return nothing

    chosen_index = 1
    for i in 2:length(lod.levels)
        level = lod.levels[i]
        threshold = level.distance
        level_distance = is_visible(level.object) ?
            threshold * (1 - level.hysteresis) : threshold
        if d >= level_distance
            chosen_index = i
        else
            break
        end
    end

    # Compare by object identity, not index: if the same object is registered at
    # several levels, it must stay visible whenever any of its entries is chosen
    # (an index test would let a later non-chosen entry hide the chosen object).
    chosen_obj = lod.levels[chosen_index].object
    for level in lod.levels
        obj = level.object
        hasproperty(obj, :visible) && setproperty!(obj, :visible, obj === chosen_obj)
    end
    return chosen_obj
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
    _validate_skeleton(s, "Skeleton", "bind_inverses")
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
                     bind_mode::Symbol=:attached, bind_matrix::Mat4=Mat4())
    bind_mode in (:attached, :detached) ||
        throw(ArgumentError("SkinnedMesh bind_mode must be :attached or :detached"))
    geometry isa BufferGeometry ||
        throw(ArgumentError("SkinnedMesh geometry must be a BufferGeometry"))
    converted_indices = convert(Vector{NTuple{4,Int}}, skin_indices)
    converted_weights = convert(Vector{NTuple{4,Float64}}, skin_weights)
    _validate_skin_data(geometry, skeleton, converted_indices, converted_weights,
                        "SkinnedMesh")
    matrix = convert(Mat4{Float64}, bind_matrix)
    _validate_object_matrix(matrix, "SkinnedMesh", "bind_matrix")
    matrix_inverse = mat4_inverse(matrix)
    sm = SkinnedMesh(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing,
                     AbstractObject3D[], true, name, _next_id(), geometry,
                     material, cast_shadow, receive_shadow, skeleton,
                     converted_indices, converted_weights,
                     collect(Float64, morph_target_influences),
                     collect(String, morph_target_names),
                     bind_mode, matrix, matrix_inverse)
    return sm
end

get_position(o::SkinnedMesh) = o.position
get_rotation(o::SkinnedMesh) = o.rotation
get_scale(o::SkinnedMesh) = o.scale
get_children(o::SkinnedMesh) = o.children
get_parent(o::SkinnedMesh) = o.parent
is_visible(o::SkinnedMesh) = o.visible
set_parent!(o::SkinnedMesh, p) = (o.parent = p)

@_compute_world_matrix_method(InstancedMesh,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)
@_compute_world_matrix_method(LineSegments,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)
@_compute_world_matrix_method(LineLoop,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)
@_compute_world_matrix_method(Sprite,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)
@_compute_world_matrix_method(LOD,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)
@_compute_world_matrix_method(Bone,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)
@_compute_world_matrix_method(SkinnedMesh,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera,
    AmbientLight, DirectionalLight, PointLight, SpotLight, HemisphereLight, RectAreaLight, LightProbe,
    InstancedMesh, LineSegments, LineLoop, Sprite, LOD, Bone, SkinnedMesh)

apply_morph_targets(mesh::SkinnedMesh) =
    apply_morph_targets(mesh.geometry, mesh.morph_target_influences)
apply_morph_normals(mesh::SkinnedMesh) =
    apply_morph_normals(mesh.geometry, mesh.morph_target_influences)
apply_morph_tangents(mesh::SkinnedMesh) =
    apply_morph_tangents(mesh.geometry, mesh.morph_target_influences)

function bind_skeleton!(sm::SkinnedMesh, skeleton::Skeleton,
                        bind_matrix::Union{Nothing,Mat4}=nothing;
                        bind_mode::Symbol=sm.bind_mode,
                        calculate_inverses::Bool=bind_matrix === nothing)
    bind_mode in (:attached, :detached) ||
        throw(ArgumentError("SkinnedMesh bind_mode must be :attached or :detached"))
    calculate_inverses && calculate_inverses!(skeleton)
    geo = _skinned_buffer_geometry(sm)
    _validate_skin_data(geo, skeleton, sm.skin_indices, sm.skin_weights,
                        "SkinnedMesh")
    matrix = bind_matrix === nothing ? compute_world_matrix(sm) :
             convert(Mat4{Float64}, bind_matrix)
    _validate_object_matrix(matrix, "SkinnedMesh", "bind_matrix")
    matrix_inverse = mat4_inverse(matrix)
    sm.skeleton = skeleton
    sm.bind_mode = bind_mode
    sm.bind_matrix = matrix
    sm.bind_matrix_inverse = matrix_inverse
    return sm
end

_skinned_bind_matrix_inverse(sm::SkinnedMesh) =
    sm.bind_mode === :attached ? mat4_inverse(compute_world_matrix(sm)) :
    sm.bind_matrix_inverse

@inline function _skinned_buffer_geometry(sm::SkinnedMesh)
    geo = sm.geometry
    geo isa BufferGeometry ||
        throw(ArgumentError("SkinnedMesh geometry must be a BufferGeometry"))
    return geo
end

function _validate_skeleton(skeleton::Skeleton, context::String, label::String)
    n_bones = length(skeleton.bones)
    length(skeleton.bind_inverses) == n_bones ||
        throw(ArgumentError(
            "$context $label length must match bones length"))
    @inbounds for index in eachindex(skeleton.bind_inverses)
        _validate_object_matrix(
            skeleton.bind_inverses[index], context, label, index)
    end
    return n_bones
end

@noinline function _throw_object_matrix(context::String, label::String,
                                        index::Int)
    suffix = index == 0 ? "" : " $index"
    throw(ArgumentError("$context $label$suffix must be finite"))
end

@inline function _validate_object_matrix(matrix::Mat4, context::String,
                                         label::String, index::Int=0)
    @inbounds for value in matrix.e
        isfinite(value) || _throw_object_matrix(context, label, index)
    end
    return nothing
end

function _validate_skin_data(geo::BufferGeometry, skeleton::Skeleton,
                             skin_indices::Vector{NTuple{4,Int}},
                             skin_weights::Vector{NTuple{4,Float64}},
                             context::String)
    _validate_geometry_vertices(geo, context)
    n_vertices = geo.n_vertices
    length(skin_indices) == n_vertices ||
        throw(ArgumentError(
            "$context skin_indices length must match geometry n_vertices"))
    length(skin_weights) == n_vertices ||
        throw(ArgumentError(
            "$context skin_weights length must match geometry n_vertices"))
    n_bones = _validate_skeleton(
        skeleton, context, "skeleton bind_inverses")
    @inbounds for vi in 1:n_vertices
        indices = skin_indices[vi]
        weights = skin_weights[vi]
        total_weight = 0.0
        for k in 1:4
            1 <= indices[k] <= n_bones ||
                throw(ArgumentError(
                    "$context skin_indices must reference skeleton bones"))
            weight = weights[k]
            isfinite(weight) && weight >= 0.0 ||
                throw(ArgumentError(
                    "$context skin_weights must be finite and non-negative"))
            total_weight += weight
        end
        isfinite(total_weight) &&
            isapprox(total_weight, 1.0; atol=1.0e-6, rtol=1.0e-6) ||
            throw(ArgumentError(
                "$context skin_weights must sum to one per vertex"))
    end
    return nothing
end

function _validate_skinned_mesh(sm::SkinnedMesh, context::String)
    sm.bind_mode in (:attached, :detached) ||
        throw(ArgumentError(
            "$context bind_mode must be :attached or :detached"))
    _validate_object_matrix(sm.bind_matrix, context, "bind_matrix")
    _validate_object_matrix(
        sm.bind_matrix_inverse, context, "bind_matrix_inverse")
    geo = _skinned_buffer_geometry(sm)
    _validate_skin_data(geo, sm.skeleton, sm.skin_indices, sm.skin_weights,
                        context)
    return geo
end

function _skinning_matrices(sm::SkinnedMesh)
    skel = sm.skeleton
    _validate_skeleton(skel, "SkinnedMesh", "skeleton bind_inverses")
    bind = sm.bind_matrix
    bind_inv = _skinned_bind_matrix_inverse(sm)
    [bind_inv * compute_world_matrix(skel.bones[i]) * skel.bind_inverses[i] * bind
     for i in eachindex(skel.bones)]
end

function _skinning_matrices!(out::Vector{Mat4{Float64}}, sm::SkinnedMesh)
    skel = sm.skeleton
    _validate_skeleton(skel, "SkinnedMesh", "skeleton bind_inverses")
    resize!(out, length(skel.bones))
    bind = sm.bind_matrix
    bind_inv = _skinned_bind_matrix_inverse(sm)
    @inbounds for i in eachindex(skel.bones)
        out[i] = bind_inv * compute_world_matrix(skel.bones[i]) *
                 skel.bind_inverses[i] * bind
    end
    return out
end

@inline function _skin_position(mats, idx::NTuple{4,Int},
                               w::NTuple{4,Float64}, p::Vec3)
    acc = Vec3(0.0, 0.0, 0.0)
    @inbounds for k in 1:4
        wk = w[k]
        wk == 0 && continue
        acc = acc + mat4_transform_point(mats[idx[k]], p) * wk
    end
    return acc
end

"""
Linear blend skinning: deform each geometry vertex by the weighted sum of its
bones' skinning matrices. Returns `Vector{Vec3}` of deformed positions.
"""
function apply_skinning(sm::SkinnedMesh)
    geo = _validate_skinned_mesh(sm, "SkinnedMesh")
    mats = _skinning_matrices(sm)
    morphed = _has_active_morph_influences(sm.morph_target_influences) ? apply_morph_targets(sm) : nothing
    out = Vector{Vec3{Float64}}(undef, geo.n_vertices)
    @inbounds for vi in 1:geo.n_vertices
        p = morphed === nothing ? get_vertex(geo, vi) : morphed[vi]
        out[vi] = _skin_position(mats, sm.skin_indices[vi], sm.skin_weights[vi], p)
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
    geo = _skinned_buffer_geometry(sm)
    out = Vector{Float64}(undef, _skinned_normal_output_length(geo))
    return _skin_normal_buffer!(out, sm, mats)
end

function _skin_positions!(out::Vector{Float64}, sm::SkinnedMesh, mats, morphed)
    geo = _skinned_buffer_geometry(sm)
    @inbounds for vi in 1:geo.n_vertices
        base = 3vi - 2
        p0 = morphed === nothing ? get_vertex(geo, vi) : morphed[vi]
        p = _skin_position(mats, sm.skin_indices[vi], sm.skin_weights[vi], p0)
        out[base] = p.x
        out[base + 1] = p.y
        out[base + 2] = p.z
    end
    return out
end

function _skin_morph_normals!(out::Vector{Float64}, geo::BufferGeometry,
                              influences::AbstractVector{<:Real})
    if length(geo.normals) < geo.n_vertices * 3
        length(geo.normals) > 0 && copyto!(out, 1, geo.normals, 1, length(geo.normals))
        return out
    end
    copyto!(out, 1, geo.normals, 1, geo.n_vertices * 3)
    for (ti, weight) in enumerate(influences)
        weight isa Bool && _throw_morph_influence(ti)
        iszero(weight) && continue
        w = _morph_influence(weight, ti)
        w == 0.0 && continue
        name = _morph_normal_symbol(ti)
        has_attribute(geo, name) || continue
        attr = get_attribute(geo, name)
        _apply_morph_attribute3_attr_dispatch!(out, attr, w, name,
                                               geo.n_vertices, 3)
    end
    return _normalize_attribute3!(out, geo.n_vertices, 3)
end

function _skin_normal_buffer!(out::Vector{Float64}, sm::SkinnedMesh, mats)
    geo = _skinned_buffer_geometry(sm)
    active_morph = _has_active_morph_influences(sm.morph_target_influences)
    normals = active_morph ? _skin_morph_normals!(out, geo, sm.morph_target_influences) :
              geo.normals
    if length(normals) < geo.n_vertices * 3
        copyto!(out, 1, normals, 1, length(normals))
        return out
    end
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
    geo = _skinned_buffer_geometry(sm)
    attr.item_size >= 3 && length(tangent_data) >= geo.n_vertices * attr.item_size ||
        return copy(tangent_data)
    out = _float64_copy(tangent_data)
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

function _skin_tangent_attribute!(out::Vector{Float64}, sm::SkinnedMesh,
                                  attr::BufferAttribute, mats,
                                  tangent_data=attr.data)
    geo = _skinned_buffer_geometry(sm)
    copyto!(out, 1, tangent_data, 1, length(tangent_data))
    attr.item_size >= 3 && length(tangent_data) >= geo.n_vertices * attr.item_size ||
        return out
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
    geo = _skinned_buffer_geometry(sm)
    for (name, attr) in geo.attributes
        data = if name === :tangent
            tangent_data = _has_active_morph_influences(sm.morph_target_influences) ? apply_morph_tangents(sm) : attr.data
            _skin_tangent_attribute(sm, attr, mats, tangent_data)
        else
            copy(attr.data)
        end
        attrs[name] = BufferAttribute(data, attr.item_size)
    end
    return attrs
end

function _skinned_render_geometry(sm::SkinnedMesh)
    geo = _validate_skinned_mesh(sm, "SkinnedMesh")
    mats = _skinning_matrices(sm)
    positions = Vector{Float64}(undef, geo.n_vertices * 3)
    morphed = _has_active_morph_influences(sm.morph_target_influences) ? apply_morph_targets(sm) : nothing
    _skin_positions!(positions, sm, mats, morphed)
    BufferGeometry(positions, _skin_normal_buffer(sm, mats), copy(geo.uvs),
                   copy(geo.indices), geo.n_vertices, geo.n_faces,
                   _copy_skinned_attributes(sm, mats), copy(geo.groups),
                   geo.draw_range)
end

function _skinned_render_mesh(sm::SkinnedMesh)
    Mesh(sm.position, sm.rotation, sm.scale, sm.parent, AbstractObject3D[],
         sm.visible, sm.name, sm.id, _skinned_render_geometry(sm), sm.material,
         nothing, sm.cast_shadow, sm.receive_shadow, Float64[], String[])
end

function _skinned_normal_output_length(geo::BufferGeometry)
    return length(geo.normals) >= geo.n_vertices * 3 ? geo.n_vertices * 3 :
           length(geo.normals)
end

@inline _skinned_attr_storage_matches(name::Symbol, proxy::BufferAttribute,
                                      source::BufferAttribute) =
    name === :tangent ? (proxy.data isa Vector{Float64}) :
    (typeof(proxy.data) === typeof(source.data))

function _skinned_proxy_geometry_matches(proxy::BufferGeometry, geo::BufferGeometry)
    proxy.n_vertices == geo.n_vertices || return false
    proxy.n_faces == geo.n_faces || return false
    length(proxy.positions) == 3 * geo.n_vertices || return false
    length(proxy.normals) == _skinned_normal_output_length(geo) || return false
    length(proxy.uvs) == length(geo.uvs) || return false
    length(proxy.indices) == length(geo.indices) || return false
    length(proxy.attributes) == length(geo.attributes) || return false
    for (name, attr) in geo.attributes
        haskey(proxy.attributes, name) || return false
        pattr = proxy.attributes[name]
        pattr.item_size == attr.item_size || return false
        length(pattr.data) == length(attr.data) || return false
        _skinned_attr_storage_matches(name, pattr, attr) || return false
    end
    return true
end

function _copy_skinned_attributes!(out::Dict{Symbol,BufferAttribute}, sm::SkinnedMesh, mats)
    geo = _skinned_buffer_geometry(sm)
    active_morph = _has_active_morph_influences(sm.morph_target_influences)
    for (name, attr) in geo.attributes
        pattr = out[name]
        if name === :tangent
            tangent_data = active_morph ?
                           apply_morph_tangents!(pattr.data, geo,
                                                 sm.morph_target_influences) :
                           attr.data
            _skin_tangent_attribute!(pattr.data, sm, attr, mats, tangent_data)
        else
            copyto!(pattr.data, 1, attr.data, 1, length(attr.data))
        end
    end
    return out
end

function _copy_groups!(out::Vector{NTuple{3,Int}}, groups::Vector{NTuple{3,Int}})
    resize!(out, length(groups))
    length(groups) > 0 && copyto!(out, 1, groups, 1, length(groups))
    return out
end

function _update_skinned_render_geometry!(proxy::BufferGeometry, sm::SkinnedMesh,
                                          mats_scratch::Union{Nothing,Vector{Mat4{Float64}}}=nothing,
                                          morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    geo = _validate_skinned_mesh(sm, "SkinnedMesh")
    _skinned_proxy_geometry_matches(proxy, geo) || return _skinned_render_geometry(sm)
    mats = mats_scratch === nothing ? _skinning_matrices(sm) :
           _skinning_matrices!(mats_scratch, sm)
    morphed = _has_active_morph_influences(sm.morph_target_influences) ?
              _object_morph_positions(sm, geo, morph_scratch) : nothing
    _skin_positions!(proxy.positions, sm, mats, morphed)
    _skin_normal_buffer!(proxy.normals, sm, mats)
    copyto!(proxy.uvs, 1, geo.uvs, 1, length(geo.uvs))
    copyto!(proxy.indices, 1, geo.indices, 1, length(geo.indices))
    proxy.n_vertices = geo.n_vertices
    proxy.n_faces = geo.n_faces
    _copy_skinned_attributes!(proxy.attributes, sm, mats)
    _copy_groups!(proxy.groups, geo.groups)
    proxy.draw_range = geo.draw_range
    return proxy
end

function _update_skinned_render_mesh!(proxy::Mesh, sm::SkinnedMesh,
                                      mats_scratch::Union{Nothing,Vector{Mat4{Float64}}}=nothing,
                                      morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    proxy.position = sm.position
    proxy.rotation = sm.rotation
    proxy.scale = sm.scale
    proxy.parent = sm.parent
    proxy.visible = sm.visible
    proxy.name = sm.name
    proxy.id = sm.id
    proxy.geometry = _update_skinned_render_geometry!(proxy.geometry, sm,
                                                      mats_scratch, morph_scratch)
    proxy.material = sm.material
    proxy.flat_shading = nothing
    proxy.cast_shadow = sm.cast_shadow
    proxy.receive_shadow = sm.receive_shadow
    empty!(proxy.morph_target_influences)
    empty!(proxy.morph_target_names)
    return proxy
end

function _collect_skinned_meshes!(out::Vector{SkinnedMesh}, obj::AbstractObject3D)
    is_visible(obj) || return nothing
    obj isa SkinnedMesh && push!(out, obj)
    for child in get_children(obj)
        _collect_skinned_meshes!(out, child)
    end
    return nothing
end

function _append_skinned_render_meshes!(meshes::Vector{Mesh}, scene::AbstractObject3D,
                                        skinned::Vector{SkinnedMesh})
    empty!(skinned)
    _collect_skinned_meshes!(skinned, scene)
    for sm in skinned
        push!(meshes, _skinned_render_mesh(sm))
    end
    return meshes
end

function _append_skinned_render_meshes!(meshes::Vector{Mesh}, scene::AbstractObject3D,
                                        skinned::Vector{SkinnedMesh},
                                        proxies::Vector{Mesh},
                                        mats_scratch::Union{Nothing,Vector{Mat4{Float64}}}=nothing,
                                        morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    empty!(skinned)
    _collect_skinned_meshes!(skinned, scene)
    for i in eachindex(skinned)
        sm = skinned[i]
        if i > length(proxies)
            push!(proxies, _skinned_render_mesh(sm))
        else
            _update_skinned_render_mesh!(proxies[i], sm, mats_scratch, morph_scratch)
        end
        push!(meshes, proxies[i])
    end
    return meshes
end

function _append_skinned_render_meshes!(meshes::Vector{Mesh}, scene::AbstractObject3D)
    skinned = SkinnedMesh[]
    return _append_skinned_render_meshes!(meshes, scene, skinned)
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
