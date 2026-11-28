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
    render_order::Float64  # three.js Object3D.renderOrder

    function InstancedMesh(position::Vec3{Float64}, rotation::Euler{Float64},
                           scale::Vec3{Float64},
                           parent::Union{Nothing, AbstractObject3D},
                           children::Vector{AbstractObject3D},
                           visible::Bool, name::String, id::Int,
                           geometry, material, cast_shadow::Bool,
                           receive_shadow::Bool,
                           instance_matrices::Vector{Mat4{Float64}},
                           instance_colors::Vector{Color3{Float64}},
                           draw_mode::Symbol, render_order::Real=0.0)
        _validate_instanced_data(instance_matrices, instance_colors,
                                 "InstancedMesh")
        new(position, rotation, scale, parent, children, visible, name, id,
            geometry, material, cast_shadow, receive_shadow, instance_matrices,
            instance_colors, _validate_instanced_draw_mode(draw_mode),
            Float64(render_order))
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
    render_order::Float64  # three.js Object3D.renderOrder
end

# Field layout before `render_order` was added (three.js default 0).
LineSegments(args::Vararg{Any,12}) = LineSegments(args..., 0.0)

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
    render_order::Float64  # three.js Object3D.renderOrder
end

# Field layout before `render_order` was added (three.js default 0).
LineLoop(args::Vararg{Any,12}) = LineLoop(args..., 0.0)

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

@noinline function _throw_sprite_center(context::String)
    throw(ArgumentError("$context center must be finite"))
end

@inline function _validated_sprite_center(center::Vec2, context::String)
    result = convert(Vec2{Float64}, center)
    isfinite(result.x) && isfinite(result.y) || _throw_sprite_center(context)
    return result
end

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
    render_order::Float64  # three.js Object3D.renderOrder
end

# Field layout before `render_order` was added (three.js default 0).
Sprite(args::Vararg{Any,10}) = Sprite(args..., 0.0)

@inline function _validate_sprite_center(sprite::Sprite, context::String)
    center = sprite.center
    isfinite(center.x) && isfinite(center.y) || _throw_sprite_center(context)
    return nothing
end

function Sprite(material; name="Sprite", center=Vec2(0.5, 0.5))
    validated_center = _validated_sprite_center(center, "Sprite")
    Sprite(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
           true, name, _next_id(), material, validated_center)
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

# Quad corners in world space, ordered (0,0), (1,0), (1,1), (0,1) in sprite UV.
# Like three.js Sprite.raycast (transformVertex) and the sprite vertex shader,
# each centered corner is scaled by the world scale first and then rotated in
# the view plane, so non-uniform scale stays aligned with the screen axes.
@inline function _sprite_quad_corners(sprite::Sprite, material,
                                       camera::AbstractCamera, world::Mat4, view::Mat4)
    world64 = convert(Mat4{Float64}, world)
    # Rows 1 and 2 of the view matrix are the camera right/up axes in world space.
    right = Vec3(mat4_get(view,1,1), mat4_get(view,1,2), mat4_get(view,1,3))
    up    = Vec3(mat4_get(view,2,1), mat4_get(view,2,2), mat4_get(view,2,3))
    rotation = _material_field(material, :rotation)
    rotation === nothing && (rotation = 0.0)
    size_attenuation = _material_field(material, :size_attenuation)
    center = Vec3(mat4_get(world64,1,4),mat4_get(world64,2,4),mat4_get(world64,3,4))
    center_view = mat4_transform_vec4(view,Vec4(center.x,center.y,center.z,1.0))
    attenuation = size_attenuation === false && camera isa PerspectiveCamera ?
                  max(0.0001,-center_view.z) : 1.0
    scale_x = _mat4_linear_column_norm(world64, 1) * attenuation
    scale_y = _mat4_linear_column_norm(world64, 2) * attenuation
    cosine, sine = cos(rotation), sin(rotation)
    return ntuple(4) do index
        x = ((index in (2,3) ? 1.0 : 0.0)-sprite.center.x)*scale_x
        y = ((index in (3,4) ? 1.0 : 0.0)-sprite.center.y)*scale_y
        center + right*(cosine*x-sine*y) + up*(sine*x+cosine*y)
    end
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
    auto_update::Bool
    _camera_levels::WeakKeyDict{AbstractCamera,Int}
    _manual_level::Int
    render_order::Float64  # three.js Object3D.renderOrder
end

# Field layout before `render_order` was added (three.js default 0).
LOD(args::Vararg{Any,12}) = LOD(args..., 0.0)

LOD(position, rotation, scale, parent, children, visible, name, id, levels) =
    LOD(position, rotation, scale, parent, children, visible, name, id, levels, true)
LOD(position, rotation, scale, parent, children, visible, name, id, levels, auto_update::Bool) =
    LOD(position, rotation, scale, parent, children, visible, name, id, levels,
        auto_update, WeakKeyDict{AbstractCamera,Int}(), 0)

"""
    LOD(; name="LOD", auto_update=true)

Group levels by minimum camera distance. Rendering selects a whole level using
world distance divided by camera zoom, with independent hysteresis per camera.
Set `auto_update=false` to manage visibility with `lod_update!` yourself.
"""
function LOD(; name="LOD", auto_update::Bool=true)
    LOD(Vec3(), Euler(), Vec3(1.0,1.0,1.0), nothing, AbstractObject3D[],
        true, name, _next_id(), LODLevel[], auto_update)
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
    empty!(lod._camera_levels)
    lod._manual_level = 0
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
    empty!(lod._camera_levels)
    lod._manual_level = 0
    return lod
end

# Removing every child drops every level, as `remove!` does one at a time.
function clear_children!(lod::LOD)
    invoke(clear_children!, Tuple{AbstractObject3D}, lod)
    empty!(lod.levels)
    empty!(lod._camera_levels)
    lod._manual_level = 0
    return lod
end

"""
Highest-distance LOD level whose threshold ≤ `distance` (three.js
`getObjectForDistance`). A currently visible level's threshold is reduced by its
hysteresis fraction.
"""
function lod_select(lod::LOD, distance)
    query_distance = _validated_lod_distance(distance, "LOD query distance")
    _validate_lod_levels(lod, "LOD")
    isempty(lod.levels) && return nothing
    return lod.levels[_lod_level_index(lod, query_distance, nothing)].object
end

function _lod_level_index(lod::LOD, d::Float64, current::Union{Nothing,Int})
    isempty(lod.levels) && return 0
    chosen_index = 1
    for i in 2:length(lod.levels)
        level = lod.levels[i]
        threshold = level.distance
        was_visible = current === nothing ? is_visible(level.object) : current == level.object.id
        level_distance = was_visible ?
            threshold * (1 - level.hysteresis) : threshold
        if d >= level_distance
            chosen_index = i
        else
            break
        end
    end
    return chosen_index
end

function _set_lod_level!(lod::LOD, chosen_index::Int)
    chosen_index == 0 && return nothing
    # three.js LOD.update leaves a single level's visibility untouched.
    length(lod.levels) == 1 && return lod.levels[1].object
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

function _set_lod_manual_level!(lod::LOD, chosen)
    # Specialize the property access on the selected object's concrete type.
    lod._manual_level = chosen === nothing ? 0 : chosen.id
    return nothing
end

"""
Update child visibility using distance thresholds and hysteresis, returning the
selected object or `nothing`. A manual selection resets automatic camera state.
"""
function lod_update!(lod::LOD, distance)
    d = _validated_lod_distance(distance, "LOD update distance")
    _validate_lod_levels(lod, "LOD")
    chosen = _set_lod_level!(lod, _lod_level_index(lod, d, nothing))
    # A manual selection is the seed for newly observed cameras. Automatic
    # selections are kept separately so views cannot change each other's hysteresis.
    empty!(lod._camera_levels)
    _set_lod_manual_level!(lod, chosen)
    return chosen
end

"""Update an LOD from the camera's world position and zoom."""
function lod_update!(lod::LOD, camera::AbstractCamera)
    position = _camera_world_position(camera)
    zoom = _validated_camera_zoom(camera.zoom)
    world = compute_world_matrix(lod)
    origin = Vec3(world.e[13], world.e[14], world.e[15])
    all(isfinite, (origin.x, origin.y, origin.z)) ||
        throw(ArgumentError("LOD world position must be finite"))
    difference = _float_vector_difference(origin, position)
    divisor = _float_value_representation(zoom)
    components = map(value -> _float_representation_ratio(value, divisor), difference)
    distance = hypot(components...)
    # All stored thresholds are finite; saturation preserves the selected level
    # when the camera distance exceeds Float64 after accounting for zoom.
    _validate_lod_levels(lod, "LOD")
    previous = get(lod._camera_levels, camera, lod._manual_level)
    chosen = _set_lod_level!(lod, _lod_level_index(lod, min(distance, floatmax(Float64)), previous))
    chosen !== nothing && previous != chosen.id && (lod._camera_levels[camera] = chosen.id)
    return chosen
end

function _update_scene_lods!(root::AbstractObject3D, camera::AbstractCamera)
    is_visible(root) || return nothing
    if root isa LOD && root.auto_update
        lod_update!(root, camera)
    end
    for child in get_children(root)
        _update_scene_lods!(child, camera)
    end
    return nothing
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
    render_order::Float64  # three.js Object3D.renderOrder
end

# Field layout before `render_order` was added (three.js default 0).
Bone(args::Vararg{Any,8}) = Bone(args..., 0.0)

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
    render_order::Float64  # three.js Object3D.renderOrder
end

# Field layout before `render_order` was added (three.js default 0).
SkinnedMesh(args::Vararg{Any,20}) = SkinnedMesh(args..., 0.0)

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

function _skinning_prefix(sm::SkinnedMesh, space)
    space === :local && return _skinned_bind_matrix_inverse(sm)
    if space === :world
        # Cancel meshWorld * inverse(meshWorld) before forming the palette.
        # An attached skin is therefore independent of even singular mesh nodes.
        return sm.bind_mode === :attached ? Mat4() :
               compute_world_matrix(sm) * sm.bind_matrix_inverse
    end
    throw(ArgumentError("skinning space must be :local or :world"))
end

function _skinning_matrices(sm::SkinnedMesh, space=:local)
    skel = sm.skeleton
    _validate_skeleton(skel, "SkinnedMesh", "skeleton bind_inverses")
    bind = sm.bind_matrix
    bind_inv = _skinning_prefix(sm,space)
    [bind_inv * compute_world_matrix(skel.bones[i]) * skel.bind_inverses[i] * bind
     for i in eachindex(skel.bones)]
end

function _skinning_matrices!(out::Vector{Mat4{Float64}}, sm::SkinnedMesh, space=:local)
    skel = sm.skeleton
    _validate_skeleton(skel, "SkinnedMesh", "skeleton bind_inverses")
    resize!(out, length(skel.bones))
    bind = sm.bind_matrix
    bind_inv = _skinning_prefix(sm,space)
    @inbounds for i in eachindex(skel.bones)
        out[i] = bind_inv * compute_world_matrix(skel.bones[i]) *
                 skel.bind_inverses[i] * bind
    end
    return out
end

@inline function _skin_position(mats, idx::NTuple{4,Int},
                               w::NTuple{4,Float64}, p::Vec3)
    acc = Vec3(0.0, 0.0, 0.0)
    total = 0.0
    @inbounds for k in 1:4
        wk = w[k]
        wk == 0 && continue
        acc = acc + mat4_transform_point(mats[idx[k]], p) * wk
        total += wk
    end
    return total == 1.0 ? acc : acc / total
end

"""
    apply_skinning(mesh; space=:local)

Deform each vertex by the normalized weighted sum of its bone transforms.
Returns `Vector{Vec3}` in mesh-local coordinates by default. Use `space=:world`
for world coordinates, including attached skins with singular mesh transforms.
"""
function apply_skinning(sm::SkinnedMesh; space=:local)
    geo = _validate_skinned_mesh(sm, "SkinnedMesh")
    mats = _skinning_matrices(sm,space)
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

function _skin_linear_matrix(mats, idx::NTuple{4,Int}, weights::NTuple{4,Float64})
    values = ntuple(Val(16)) do component
        component == 16 && return 1.0
        (component % 4 == 0 || component > 12) && return 0.0
        value = 0.0
        @inbounds for slot in 1:4
            weight = weights[slot]
            iszero(weight) && continue
            value += weight * mats[idx[slot]].e[component]
        end
        value
    end
    return Mat4(values)
end

@noinline function _skin_normal_precise(matrix::Mat4, normal::Vec3)
    all(isfinite, matrix.e) || throw(ArgumentError("SkinnedMesh linear transform must be finite"))
    return setprecision(BigFloat, 8192) do
        normal_matrix = mat4_normal_matrix(convert(Mat4{BigFloat}, matrix))
        transformed = normalize(mat4_transform_direction(normal_matrix,convert(Vec3{BigFloat},normal)))
        result = convert(Vec3{Float64},transformed)
        all(isfinite,(result.x,result.y,result.z)) ||
            throw(ArgumentError("SkinnedMesh transformed normal must be finite"))
        result
    end
end

function _skin_normal(matrix::Mat4, normal_matrix::Mat4, normal::Vec3)
    all(isfinite,(normal.x,normal.y,normal.z)) ||
        throw(ArgumentError("SkinnedMesh normals must be finite"))
    unit_normal = normalize(normal)
    transformed = mat4_transform_direction(normal_matrix,unit_normal)
    # A unit direction can remain representable when an inverse coefficient
    # exceeds Float64. Normalize in higher precision before converting it.
    all(isfinite,(transformed.x,transformed.y,transformed.z)) ||
        return _skin_normal_precise(matrix,unit_normal)
    return normalize(transformed)
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
    previous_indices = nothing
    previous_weights = nothing
    linear = Mat4()
    normal_matrix = Mat4()
    @inbounds for vi in 1:geo.n_vertices
        base = 3vi - 2
        n = Vec3(normals[base], normals[base + 1], normals[base + 2])
        indices = sm.skin_indices[vi]
        weights = sm.skin_weights[vi]
        if indices != previous_indices || weights != previous_weights
            linear = _skin_linear_matrix(mats,indices,weights)
            normal_matrix = mat4_normal_matrix(linear)
            previous_indices = indices
            previous_weights = weights
        end
        sn = _skin_normal(linear,normal_matrix,n)
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
    out = Vector{Float64}(undef,length(tangent_data))
    return _skin_tangent_attribute!(out,sm,attr,mats,tangent_data)
end

function _skin_tangent_attribute!(out::Vector{Float64}, sm::SkinnedMesh,
                                  attr::BufferAttribute, mats,
                                  tangent_data=attr.data)
    geo = _skinned_buffer_geometry(sm)
    copyto!(out, 1, tangent_data, 1, length(tangent_data))
    attr.item_size >= 3 && length(tangent_data) >= geo.n_vertices * attr.item_size ||
        return out
    previous_indices = nothing
    previous_weights = nothing
    reverse_orientation = false
    @inbounds for vi in 1:geo.n_vertices
        base = (vi - 1) * attr.item_size + 1
        t = Vec3(Float64(tangent_data[base]), Float64(tangent_data[base + 1]), Float64(tangent_data[base + 2]))
        st = _skin_direction(mats, sm.skin_indices[vi], sm.skin_weights[vi], t)
        out[base] = st.x
        out[base + 1] = st.y
        out[base + 2] = st.z
        if attr.item_size >= 4
            indices = sm.skin_indices[vi]
            weights = sm.skin_weights[vi]
            if indices != previous_indices || weights != previous_weights
                linear = _skin_linear_matrix(mats,indices,weights)
                reverse_orientation = _mat4_linear_orientation_sign(linear) < 0
                previous_indices = indices
                previous_weights = weights
            end
            reverse_orientation && (out[base+3] = -out[base+3])
        end
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
    mats = _skinning_matrices(sm,:world)
    positions = Vector{Float64}(undef, geo.n_vertices * 3)
    morphed = _has_active_morph_influences(sm.morph_target_influences) ? apply_morph_targets(sm) : nothing
    _skin_positions!(positions, sm, mats, morphed)
    BufferGeometry(positions, _skin_normal_buffer(sm, mats), copy(geo.uvs),
                   copy(geo.indices), geo.n_vertices, geo.n_faces,
                   _copy_skinned_attributes(sm, mats), copy(geo.groups),
                   geo.draw_range)
end

# The render proxy of a posed skin holds world-space vertices, so its own world
# matrix is the identity and would hide a mirroring SkinnedMesh world matrix,
# which three.js draws with clockwise front faces (WebGLRenderer.js `frontFaceCW`
# from `object.matrixWorld.determinant() < 0`). A mirrored skin's proxy instead
# stores the vertices reflected through x = 0 under the world matrix
# diag(-1, 1, 1): the renderers see the mirror flag, and negating a coordinate
# twice is exact, so every transformed vertex and normal is bit-identical.
@inline _skinned_proxy_scale(sm::SkinnedMesh) =
    _world_mirrors_faces(compute_world_matrix(sm)) ? Vec3(-1.0, 1.0, 1.0) :
                                                     Vec3(1.0, 1.0, 1.0)

function _mirror_skinned_proxy_geometry!(geo::BufferGeometry)
    positions = geo.positions
    @inbounds for i in 1:geo.n_vertices
        positions[3i - 2] = -positions[3i - 2]
    end
    normals = geo.normals
    @inbounds for i in 1:(length(normals) ÷ 3)
        normals[3i - 2] = -normals[3i - 2]
    end
    tangent = get(geo.attributes, :tangent, nothing)
    if tangent !== nothing
        data = tangent.data
        stride = tangent.item_size
        @inbounds for i in 1:(length(data) ÷ stride)
            data[stride * (i - 1) + 1] = -data[stride * (i - 1) + 1]
        end
    end
    return geo
end

function _skinned_render_mesh(sm::SkinnedMesh)
    scale = _skinned_proxy_scale(sm)
    geo = _skinned_render_geometry(sm)
    scale.x < 0.0 && _mirror_skinned_proxy_geometry!(geo)
    Mesh(Vec3(), Euler(), scale, nothing, AbstractObject3D[],
         sm.visible, sm.name, sm.id, geo, sm.material,
         nothing, sm.cast_shadow, sm.receive_shadow, Float64[], String[],
         sm.render_order, _ancestor_group_order(sm))
end

function _skinned_normal_output_length(geo::BufferGeometry)
    return length(geo.normals) >= geo.n_vertices * 3 ? geo.n_vertices * 3 :
           length(geo.normals)
end

@inline _deformed_attr_storage_matches(name::Symbol, proxy::BufferAttribute,
                                      source::BufferAttribute) =
    name === :tangent ? (proxy.data isa Vector{Float64}) :
    (typeof(proxy.data) === typeof(source.data))

function _deformed_proxy_geometry_matches(proxy::BufferGeometry, geo::BufferGeometry,
                                          normal_length::Int)
    proxy.n_vertices == geo.n_vertices || return false
    proxy.n_faces == geo.n_faces || return false
    length(proxy.positions) == 3 * geo.n_vertices || return false
    length(proxy.normals) == normal_length || return false
    length(proxy.uvs) == length(geo.uvs) || return false
    length(proxy.indices) == length(geo.indices) || return false
    length(proxy.attributes) == length(geo.attributes) || return false
    for (name, attr) in geo.attributes
        haskey(proxy.attributes, name) || return false
        pattr = proxy.attributes[name]
        pattr.item_size == attr.item_size || return false
        length(pattr.data) == length(attr.data) || return false
        _deformed_attr_storage_matches(name, pattr, attr) || return false
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
    _deformed_proxy_geometry_matches(proxy, geo, _skinned_normal_output_length(geo)) ||
        return _skinned_render_geometry(sm)
    mats = mats_scratch === nothing ? _skinning_matrices(sm,:world) :
           _skinning_matrices!(mats_scratch, sm,:world)
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
    proxy.position = Vec3()
    proxy.rotation = Euler()
    proxy.scale = _skinned_proxy_scale(sm)
    proxy.parent = nothing
    proxy.visible = sm.visible
    proxy.name = sm.name
    proxy.id = sm.id
    proxy.geometry = _update_skinned_render_geometry!(proxy.geometry, sm,
                                                      mats_scratch, morph_scratch)
    proxy.scale.x < 0.0 && _mirror_skinned_proxy_geometry!(proxy.geometry)
    proxy.material = sm.material
    proxy.flat_shading = nothing
    proxy.cast_shadow = sm.cast_shadow
    proxy.receive_shadow = sm.receive_shadow
    proxy.render_order = sm.render_order
    proxy._render_group_order = _ancestor_group_order(sm)
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
                                        skinned::Vector{SkinnedMesh}; layer_mask=nothing)
    empty!(skinned)
    _collect_skinned_meshes!(skinned, scene)
    _filter_object_layers!(skinned, nothing, layer_mask)
    for sm in skinned
        push!(meshes, _skinned_render_mesh(sm))
    end
    return meshes
end

function _append_skinned_render_meshes!(meshes::Vector{Mesh}, scene::AbstractObject3D,
                                        skinned::Vector{SkinnedMesh},
                                        proxies::Vector{Mesh},
                                        mats_scratch::Union{Nothing,Vector{Mat4{Float64}}}=nothing,
                                        morph_scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing;
                                        layer_mask=nothing)
    empty!(skinned)
    _collect_skinned_meshes!(skinned, scene)
    _filter_object_layers!(skinned, nothing, layer_mask)
    length(proxies) > length(skinned) && resize!(proxies, length(skinned))
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

function _morph_render_geometry(mesh::Mesh, scratch)
    geo = mesh.geometry::BufferGeometry
    _validate_geometry_vertices(geo, "Mesh morph")
    attributes = Dict{Symbol,BufferAttribute}()
    for (name, attr) in geo.attributes
        data = name === :tangent ? _float64_copy(attr.data) : copy(attr.data)
        attributes[name] = BufferAttribute(data, attr.item_size)
    end
    posed = BufferGeometry(Vector{Float64}(undef, 3 * geo.n_vertices),
                           copy(geo.normals), copy(geo.uvs), copy(geo.indices),
                           geo.n_vertices, geo.n_faces, attributes,
                           copy(geo.groups), geo.draw_range)
    return _update_morph_render_geometry!(posed, mesh, scratch)
end

function _update_morph_render_geometry!(posed::BufferGeometry, mesh::Mesh, scratch)
    geo = mesh.geometry::BufferGeometry
    _validate_geometry_vertices(geo, "Mesh morph")
    _deformed_proxy_geometry_matches(posed, geo, length(geo.normals)) ||
        return _morph_render_geometry(mesh, scratch)
    weights = mesh.morph_target_influences
    positions = scratch === nothing ? apply_morph_targets(geo, weights) :
                apply_morph_targets!(scratch, geo, weights)
    @inbounds for i in 1:geo.n_vertices
        base = 3i - 2
        p = positions[i]
        posed.positions[base] = p.x
        posed.positions[base + 1] = p.y
        posed.positions[base + 2] = p.z
    end
    apply_morph_normals!(posed.normals, geo, weights)
    copyto!(posed.uvs, geo.uvs)
    copyto!(posed.indices, geo.indices)
    for (name, attr) in geo.attributes
        destination = posed.attributes[name].data
        if name === :tangent
            apply_morph_tangents!(destination, geo, weights)
        else
            copyto!(destination, attr.data)
        end
    end
    _copy_groups!(posed.groups, geo.groups)
    posed.draw_range = geo.draw_range
    return posed
end

function _morph_render_mesh(mesh::Mesh, scratch)
    return Mesh(mesh.position, mesh.rotation, mesh.scale, mesh.parent,
                AbstractObject3D[], mesh.visible, mesh.name, mesh.id,
                _morph_render_geometry(mesh, scratch), mesh.material,
                mesh.flat_shading, mesh.cast_shadow, mesh.receive_shadow,
                Float64[], String[], mesh.render_order, mesh._render_group_order)
end

function _update_morph_render_mesh!(posed::Mesh, mesh::Mesh, scratch)
    posed.geometry = _update_morph_render_geometry!(posed.geometry, mesh, scratch)
    posed.position = mesh.position
    posed.rotation = mesh.rotation
    posed.scale = mesh.scale
    posed.parent = mesh.parent
    posed.visible = mesh.visible
    posed.name = mesh.name
    posed.id = mesh.id
    posed.material = mesh.material
    posed.flat_shading = mesh.flat_shading
    posed.cast_shadow = mesh.cast_shadow
    posed.receive_shadow = mesh.receive_shadow
    posed.render_order = mesh.render_order
    posed._render_group_order = mesh._render_group_order
    return posed
end

function _prepare_morph_render_meshes!(meshes::Vector{Mesh},
                                       proxies::Union{Nothing,Vector{Mesh}}=nothing,
                                       scratch::Union{Nothing,Vector{Vec3{Float64}}}=nothing)
    slot = 0
    for i in eachindex(meshes)
        mesh = meshes[i]
        _has_active_morph_influences(mesh.morph_target_influences) || continue
        slot += 1
        if proxies === nothing
            meshes[i] = _morph_render_mesh(mesh, scratch)
        else
            if slot > length(proxies)
                push!(proxies, _morph_render_mesh(mesh, scratch))
            else
                _update_morph_render_mesh!(proxies[slot], mesh, scratch)
            end
            meshes[i] = proxies[slot]
        end
    end
    proxies === nothing || resize!(proxies, slot)
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
    parent = get_parent(root)
    parent_world = parent === nothing ? Mat4{Float64}() :
                   compute_world_matrix(parent)
    compute_world_matrices(root, parent_world, cache)
    return cache
end

# ========================== Render order ==========================
# three.js WebGLRenderer.projectObject (src/renderers/WebGLRenderer.js:1860-1975)
# hands every drawable the renderOrder of its nearest Group ancestor as
# `groupOrder` (0 at the scene root), and the render lists sort by groupOrder,
# then the drawable's own renderOrder, before depth (painterSortStable and
# reversePainterSortStable, src/renderers/webgl/WebGLRenderLists.js:1-51).

@noinline _throw_render_order(kind::Symbol) =
    throw(ArgumentError("$kind render_order must not be NaN"))

# Adding 0.0 maps -0.0 to 0.0, so keys that compare equal are also identical.
@inline function _checked_render_order(value::Float64, kind::Symbol)
    isnan(value) && _throw_render_order(kind)
    return value + 0.0
end

function _ancestor_group_order(obj::AbstractObject3D)
    parent = get_parent(obj)
    while parent !== nothing
        parent isa Group && return _checked_render_order(parent.render_order, :Group)
        parent = get_parent(parent)
    end
    return 0.0
end

# The parent chain is abstractly typed; branch over the drawable types so the
# Float64 field is read without boxing.
@inline function _node_render_order(obj::AbstractObject3D)
    value = if obj isa Mesh
        obj.render_order
    elseif obj isa InstancedMesh
        obj.render_order
    elseif obj isa Sprite
        obj.render_order
    elseif obj isa LineObject
        obj.render_order
    elseif obj isa LineSegments
        obj.render_order
    elseif obj isa LineLoop
        obj.render_order
    elseif obj isa PointsObject
        obj.render_order
    elseif obj isa SkinnedMesh
        obj.render_order
    else
        getfield(obj, :render_order)::Float64
    end
    return _checked_render_order(value, nameof(typeof(obj)))
end

# A posed-skin render proxy has no parent; it records its source's group order.
@inline function _render_group_order(obj::AbstractObject3D)
    if obj isa Mesh
        group = obj._render_group_order
        group === nothing || return _checked_render_order(group, :Mesh)
    end
    return _ancestor_group_order(obj)
end

@inline _render_order_key(obj::AbstractObject3D) =
    (_render_group_order(obj), _node_render_order(obj))

@inline _render_order_key(obj::AbstractObject3D, sorted::Bool) =
    sorted ? _render_order_key(obj) : (0.0, 0.0)

const _DEFAULT_RENDER_ORDER_KEYS = Float64[]

# Insert `key` into the ascending, duplicate-free key list stored as
# interleaved (group order, render order) pairs in `keys[1:2count]`.
function _insert_render_order_key!(keys::Vector{Float64}, count::Int,
                                   key::NTuple{2,Float64})
    position = count + 1
    @inbounds for bucket in 1:count
        existing = (keys[2bucket - 1], keys[2bucket])
        existing == key && return count
        if key < existing
            position = bucket
            break
        end
    end
    length(keys) < 2count + 2 && resize!(keys, 2count + 2)
    @inbounds for bucket in count:-1:position
        keys[2bucket + 1] = keys[2bucket - 1]
        keys[2bucket + 2] = keys[2bucket]
    end
    @inbounds keys[2position - 1] = key[1]
    @inbounds keys[2position] = key[2]
    return count + 1
end

function _collect_render_order_keys!(keys::Vector{Float64}, count::Int, objects)
    @inbounds for object in objects
        count = _insert_render_order_key!(keys, count, _render_order_key(object))
    end
    return count
end

function _has_render_order(objects)
    @inbounds for object in objects
        _render_order_key(object) == (0.0, 0.0) || return true
    end
    return false
end

"""
Distinct `(group order, render order)` keys of the drawables in ascending
order, as `(count, keys)` with key `i` at `keys[2i-1:2i]`. Scenes whose keys are
all zero return `(1, _DEFAULT_RENDER_ORDER_KEYS)` without touching `scratch`;
`scratch === nothing` allocates only when a non-zero key exists.
"""
function _render_order_buckets(scratch::Union{Nothing,Vector{Float64}},
                               meshes, instanced, primitives=())
    (_has_render_order(meshes) || _has_render_order(instanced) ||
     _has_render_order(primitives)) || return (1, _DEFAULT_RENDER_ORDER_KEYS)
    keys = scratch === nothing ? Float64[] : scratch
    count = _collect_render_order_keys!(keys, 0, meshes)
    count = _collect_render_order_keys!(keys, count, instanced)
    count = _collect_render_order_keys!(keys, count, primitives)
    return (count, keys)
end

@inline _in_render_order_bucket(obj::AbstractObject3D, keys::Vector{Float64},
                                bucket::Int, count::Int) =
    count == 1 || @inbounds(_render_order_key(obj) == (keys[2bucket - 1], keys[2bucket]))

# ========================== clone / copy ==========================
# three.js Object3D.copy (src/core/Object3D.js:1605-1652) copies the name,
# transform, layers, visibility, shadow flags and renderOrder, then adds a
# clone of every child when `recursive`; `clone(recursive)` is
# `new this.constructor().copy(this, recursive)` (Object3D.js:1592-1596), so
# the clone has a fresh id and no parent. Subclasses copy their own state and
# share geometry, materials and skeletons by reference (Mesh.js:110-131,
# SkinnedMesh.js:161-176, Sprite.js:216-226). Diff3D stores the three.js
# quaternion as `rotation` and keeps the same split between copied values
# and shared references.

# Fields a copy never takes from its source: the scene-graph links and the
# identity (three.js copy keeps `this.id`, `this.parent` and the children it
# already has).
const _OBJECT_COPY_LINK_FIELDS = (:parent, :children, :id)

# Per-object vectors three.js copies (Mesh.js:114-118 slices
# morphTargetInfluences; InstancedMesh.js:186-189 copies instanceMatrix and
# clones instanceColor). The morph target names belong to the geometry's
# dictionary in three.js, which Mesh.js:120-124 also copies.
const _OBJECT_COPIED_VECTORS = (:morph_target_influences, :morph_target_names,
                                :instance_matrices, :instance_colors)

# A material array is sliced as well (Mesh.js:126, Line.js:107, Points.js:85).
@inline _object_copy_value(name::Symbol, value) =
    name in _OBJECT_COPIED_VECTORS ? copy(value) :
    name === :material && value isa AbstractVector ? copy(value) : value

function _copy_object_fields!(dest::T, source::T) where {T<:AbstractObject3D}
    for name in fieldnames(T)
        name in _OBJECT_COPY_LINK_FIELDS && continue
        _object_copy_skips_field(dest, name) && continue
        setfield!(dest, name, _object_copy_value(name, getfield(source, name)))
    end
    return dest
end

# Type-specific state that is not a plain field copy.
@inline _object_copy_skips_field(::AbstractObject3D, ::Symbol) = false
@inline _object_copy_skips_field(::LOD, name::Symbol) =
    name === :levels || name === :_camera_levels || name === :_manual_level
# A light's per-frame world-matrix cache belongs to that light.
@inline _object_copy_skips_field(::AbstractLight, name::Symbol) = name === :_world_cache

function _copy_object_layers!(dest::AbstractObject3D, source::AbstractObject3D)
    mask = _object_layer_mask(source)
    if hasproperty(dest, :layers)
        getfield(dest, :layers).mask = mask
    elseif mask != _DEFAULT_OBJECT_LAYER_MASK || _object_has_layer_state(dest)
        object_layers(dest).mask = mask
    end
    return dest
end

function _object_has_layer_state(obj::AbstractObject3D)
    lock(_OBJECT_LAYER_LOCK)
    try
        return haskey(_OBJECT_LAYER_STORE, obj)
    finally
        unlock(_OBJECT_LAYER_LOCK)
    end
end

function _copy_object_children!(dest::AbstractObject3D, source::AbstractObject3D,
                                recursive::Bool)
    recursive || return dest
    # Snapshot: copying an object into its own subtree must not visit the
    # clones it adds.
    for child in copy(get_children(source))
        add!(dest, clone(child))
    end
    return dest
end

# three.js LOD.copy (src/objects/LOD.js:87-105) ignores `recursive`: it copies
# the Object3D part without children and adds a clone of each level object at
# the level's distance and hysteresis. Other children are not cloned.
function _copy_object_children!(dest::LOD, source::LOD, ::Bool)
    _validate_lod_levels(source, "LOD copy")
    for level in copy(source.levels)
        add_lod_level!(dest, level.distance, clone(level.object);
                       hysteresis=level.hysteresis)
    end
    return dest
end

"""
    copy!(dest::T, source::T; recursive=true) where {T<:AbstractObject3D} -> dest

Copy the state of `source` into `dest` of the same node type (three.js
`Object3D.copy` and its subclass overrides): name, position, rotation, scale,
layers, visibility, `render_order`, shadow flags and every type-specific
setting such as camera projection parameters, light colours and shadow
settings, or LOD `auto_update`. `dest` keeps its id, parent and existing
children. Geometry, material and skeleton references are shared, as in
three.js; morph influences and instance matrices and colours are copied.

With `recursive=true` a [`clone`](@ref) of every child of `source` is added to
`dest`. An `LOD` copies like three.js `LOD.copy`: whatever `recursive` says,
a clone of each level object is added as a level, and other children are not
copied.
"""
function Base.copy!(dest::T, source::T; recursive::Bool=true) where {T<:AbstractObject3D}
    _copy_object_fields!(dest, source)
    _copy_object_layers!(dest, source)
    _copy_object_children!(dest, source, recursive)
    return dest
end

# A detached shell of `source`'s type with its own id and no children, built
# from the full positional field list so inner-constructor validation runs.
function _object_clone_shell(source::T) where {T<:AbstractObject3D}
    values = ntuple(fieldcount(T)) do index
        name = fieldname(T, index)
        name === :parent ? nothing :
        name === :children ? AbstractObject3D[] :
        name === :id ? _next_id() :
        _object_clone_shell_value(source, name, getfield(source, index))
    end
    return T(values...)
end

_object_clone_shell_value(::AbstractObject3D, name::Symbol, value) =
    _object_copy_value(name, value)

_object_clone_shell_value(::AbstractLight, name::Symbol, value) =
    name === :_world_cache ? _LightWorldCache() : _object_copy_value(name, value)

function _object_clone_shell_value(::LOD, name::Symbol, value)
    name === :levels && return LODLevel[]
    name === :_camera_levels && return WeakKeyDict{AbstractCamera,Int}()
    name === :_manual_level && return 0
    return _object_copy_value(name, value)
end

"""
    clone(object; recursive=true) -> new object

A new node of the same type as `object` with a fresh id, no parent, and the
state of `object` copied into it by [`copy!`](@ref) (three.js
`Object3D.clone`). With `recursive=true` the children are cloned too. As in
three.js, a cloned `SkinnedMesh` keeps the skeleton of `object`, so it is still
posed by the original bones, and geometry and materials are shared.
"""
function clone(source::AbstractObject3D; recursive::Bool=true)
    dest = _object_clone_shell(source)
    _copy_object_layers!(dest, source)
    _copy_object_children!(dest, source, recursive)
    return dest
end

# three.js BufferGeometry.copy (src/core/BufferGeometry.js:1357-1462) clones
# the index and every attribute array, the groups and the draw range.
_cloned_geometry_attributes(attributes::Dict{Symbol, BufferAttribute}) =
    Dict{Symbol, BufferAttribute}(name => BufferAttribute(copy(attribute.data),
                                                          attribute.item_size)
                                  for (name, attribute) in attributes)

"""
    copy!(dest::BufferGeometry, source::BufferGeometry) -> dest

Replace the contents of `dest` with copies of the position, normal, uv and
index buffers, named attributes, groups and draw range of `source` (three.js
`BufferGeometry.copy`). No array is shared afterwards.
"""
function Base.copy!(dest::BufferGeometry, source::BufferGeometry)
    dest === source && return dest
    dest.positions = copy(source.positions)
    dest.normals = copy(source.normals)
    dest.uvs = copy(source.uvs)
    dest.indices = copy(source.indices)
    dest.n_vertices = source.n_vertices
    dest.n_faces = source.n_faces
    dest.attributes = _cloned_geometry_attributes(source.attributes)
    dest.groups = copy(source.groups)
    dest.draw_range = source.draw_range
    return dest
end

"""
    clone(geometry::BufferGeometry) -> BufferGeometry

A new geometry with copies of every buffer of `geometry` (three.js
`BufferGeometry.clone`); see [`copy!`](@ref).
"""
clone(source::BufferGeometry) = copy!(BufferGeometry(), source)

# three.js Material.copy (src/materials/Material.js:1119-1168) shares textures
# and copies the clipping-plane array (each plane is cloned; Diff3D planes are
# immutable values). ShaderMaterial.copy (ShaderMaterial.js:278-286) clones
# the uniforms with UniformsUtils.cloneUniforms, which slices array values.
_material_clone_value(value) = value
_material_clone_value(value::Vector{<:Plane}) = copy(value)
_material_clone_value(value::Dict{String, Any}) =
    Dict{String, Any}(name => (uniform isa AbstractArray ? copy(uniform) : uniform)
                      for (name, uniform) in value)

"""
    clone(material::AbstractMaterial) -> material

A material of the same type and settings (three.js `Material.clone`).
Diff3D materials are immutable, so only the mutable containers are new: the
`clipping_planes` vector and, for a `ShaderMaterial`, the `uniforms`
dictionary with its array values copied. Textures and other references are
shared, as three.js `Material.copy` shares them.
"""
function clone(source::M) where {M<:AbstractMaterial}
    values = ntuple(index -> _material_clone_value(getfield(source, index)),
                    fieldcount(M))
    return M(values...)
end

"""
    box3_from_buffer_attribute(attribute::BufferAttribute) -> Box3

Box of the first three components of every item of `attribute` (three.js
`Box3.setFromBufferAttribute`). Items with fewer than three components take
`0` for the missing ones; three.js instead reads the next item's values there
(`BufferAttribute.getY`/`getZ` index past the item, BufferAttribute.js:487).
"""
function box3_from_buffer_attribute(attribute::BufferAttribute)
    size = attribute.item_size
    1 <= size || throw(ArgumentError("box3_from_buffer_attribute needs a positive item size"))
    data = attribute.data
    rem(length(data), size) == 0 ||
        throw(ArgumentError("box3_from_buffer_attribute data length is not a multiple of the item size"))
    box = Box3()
    for start in 1:size:length(data)
        z = zero(eltype(data))
        box = box3_expand_by_point(box, Vec3(data[start],
                                             size >= 2 ? data[start + 1] : z,
                                             size >= 3 ? data[start + 2] : z))
    end
    return box
end

# three.js Frustum.intersectsSprite (Frustum.js:174-183): a sphere of radius
# √2/2 (the unit quad's half diagonal) plus the anchor's distance from the
# quad centre, around the sprite origin.
const _SPRITE_FRUSTUM_RADIUS = 0.7071067811865476

"""
    frustum_intersects_object(frustum, object) -> Bool

Whether the bounding sphere of `object`'s geometry, placed by its world matrix,
reaches into `frustum` (three.js `Frustum.intersectsObject`). For an
`InstancedMesh` the sphere bounds every instance, as three.js
`InstancedMesh.computeBoundingSphere` does, and for a `SkinnedMesh` it bounds
the posed vertices (morph targets, then skinning, in the mesh's local space),
as three.js `SkinnedMesh.computeBoundingSphere` does. three.js computes the
skinned sphere once and keeps it; this function uses the current pose on every
call. The object needs a `geometry`.
"""
function frustum_intersects_object(f::Frustum, object::AbstractObject3D)
    hasproperty(object, :geometry) ||
        throw(ArgumentError("frustum_intersects_object needs an object with a geometry"))
    geometry = getproperty(object, :geometry)
    geometry isa BufferGeometry ||
        throw(ArgumentError("frustum_intersects_object needs a BufferGeometry"))
    sphere = if object isa SkinnedMesh
        _skinned_bounding_sphere(object)
    elseif object isa InstancedMesh
        _instanced_bounding_sphere(compute_bounding_sphere(geometry),
                                   object.instance_matrices)
    else
        compute_bounding_sphere(geometry)
    end
    world = compute_world_matrix(object)
    return frustum_intersects_sphere(f, sphere_apply_matrix4(sphere, world))
end

# three.js SkinnedMesh.computeBoundingSphere (SkinnedMesh.js:138-159): an empty
# sphere expanded by every posed vertex (SkinnedMesh.getVertexPosition: morph
# targets, then the bone transform) in the mesh's local space.
function _skinned_bounding_sphere(sm::SkinnedMesh)
    sphere = BoundingSphere(Vec3(0.0, 0.0, 0.0), -1.0)
    for point in apply_skinning(sm)
        sphere = sphere_expand_by_point(sphere, point)
    end
    return sphere
end

# InstancedMesh.computeBoundingSphere (InstancedMesh.js:155-180): the union of
# the geometry sphere transformed by each instance matrix.
function _instanced_bounding_sphere(sphere::BoundingSphere, matrices::Vector{<:Mat4})
    result = BoundingSphere(Vec3(0.0, 0.0, 0.0), -1.0)
    for matrix in matrices
        result = sphere_union(result, sphere_apply_matrix4(sphere, matrix))
    end
    return result
end

"""
    frustum_intersects_sprite(frustum, sprite::Sprite) -> Bool

three.js `Frustum.intersectsSprite`: a sphere of radius `√2/2` plus the
distance of `sprite.center` from `(0.5, 0.5)`, centred on the sprite origin and
placed by its world matrix.
"""
function frustum_intersects_sprite(f::Frustum, sprite::Sprite)
    center = sprite.center
    offset = sqrt((0.5 - center.x)^2 + (0.5 - center.y)^2)
    sphere = BoundingSphere(Vec3(0.0, 0.0, 0.0), _SPRITE_FRUSTUM_RADIUS + offset)
    return frustum_intersects_sphere(f, sphere_apply_matrix4(sphere,
                                                             compute_world_matrix(sprite)))
end

# ========================== Box3 from objects ==========================
# three.js Box3.setFromObject and Box3.expandByObject (src/math/Box3.js:139-161,
# 303-385).

"""
    box3_expand_by_object(box, object; precise=false) -> Box3
    box3_from_object(object; precise=false) -> Box3

World-axis-aligned box of `object` and all of its descendants, joined with
`box` (three.js `Box3.expandByObject`; `box3_from_object` starts from the empty
box, as `Box3.setFromObject` does). Every node is visited, visible or not.

For each node with a geometry, the default bounds its local box placed by the
world matrix: the geometry's [`compute_bounding_box`](@ref) (which covers its
morph targets), for an `InstancedMesh` the union of that box under every
instance matrix (three.js `InstancedMesh.computeBoundingBox`), and for a
`SkinnedMesh` the box of its posed vertices (`SkinnedMesh.computeBoundingBox`;
three.js keeps that box from its first use, this uses the current pose). With
`precise=true` each vertex is placed by the world matrix instead, giving a
tighter box: a `Mesh` or `SkinnedMesh` uses its posed vertices (current morph
influences, and skinning; three.js `Mesh.getVertexPosition`), lines and points
their stored positions, and an `InstancedMesh` keeps the default bounds, as in
three.js. A `Sprite` is bounded by its unit quad `[-0.5, 0.5]² × {0}`, the
geometry three.js gives every sprite.
"""
function box3_expand_by_object(box::Box3, object::AbstractObject3D; precise::Bool=false)
    result = _box3_union_object_geometry(box, object, precise)
    for child in get_children(object)
        result = box3_expand_by_object(result, child; precise=precise)
    end
    return result
end

@doc (@doc box3_expand_by_object)
box3_from_object(object::AbstractObject3D; precise::Bool=false) =
    box3_expand_by_object(Box3(), object; precise=precise)

# three.js Sprite.js:20-37: the shared quad every sprite draws.
const _SPRITE_QUAD_BOX = Box3(Vec3(-0.5, -0.5, 0.0), Vec3(0.5, 0.5, 0.0))

function _box3_union_object_geometry(box::Box3, object::AbstractObject3D,
                                     precise::Bool)
    if object isa Sprite
        return box3_union(box, box3_apply_matrix4(_SPRITE_QUAD_BOX,
                                                  compute_world_matrix(object)))
    end
    object isa Union{Mesh, SkinnedMesh, InstancedMesh, LineObject, LineSegments,
                     LineLoop, PointsObject} || return box
    geometry = object.geometry
    geometry isa BufferGeometry ||
        throw(ArgumentError("box3_expand_by_object needs a BufferGeometry on $(nameof(typeof(object)))"))
    world = compute_world_matrix(object)
    if precise && !(object isa InstancedMesh)
        for point in _box3_object_vertices(object, geometry)
            box = box3_expand_by_point(box, mat4_transform_point(world, point))
        end
        return box
    end
    local_box = if object isa SkinnedMesh
        box3_from_points(apply_skinning(object))
    elseif object isa InstancedMesh
        _instanced_bounding_box(compute_bounding_box(geometry), object.instance_matrices)
    else
        compute_bounding_box(geometry)
    end
    return box3_union(box, box3_apply_matrix4(local_box, world))
end

# The vertices `expandByObject(object, true)` visits: the posed positions of a
# mesh (`Mesh.getVertexPosition` and `SkinnedMesh.getVertexPosition`), the
# stored positions of lines and points (`Vector3.fromBufferAttribute`).
function _box3_object_vertices(object::AbstractObject3D, geometry::BufferGeometry)
    object isa SkinnedMesh && return apply_skinning(object)
    _validate_geometry_vertices(geometry, "box3_expand_by_object")
    if object isa Mesh
        morphed = _object_morph_positions(object, geometry)
        morphed === nothing || return morphed
    end
    return [get_vertex(geometry, index) for index in 1:geometry.n_vertices]
end

# three.js InstancedMesh.computeBoundingBox (InstancedMesh.js:115-144): the
# union of the geometry box placed by each instance matrix.
function _instanced_bounding_box(box::Box3, matrices::Vector{<:Mat4})
    result = Box3()
    for matrix in matrices
        result = box3_union(result, box3_apply_matrix4(box, matrix))
    end
    return result
end
