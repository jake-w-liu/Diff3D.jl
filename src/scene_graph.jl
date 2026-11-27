# --------------------------------------------------------------------------
# Scene graph: Object3D, Scene, Group, Mesh, Line, Points
# Mutable structs matching three.js API semantics.
# --------------------------------------------------------------------------

abstract type AbstractObject3D end

mutable struct Object3D <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
end

# Global ID counter
const _OBJECT_ID_COUNTER = Threads.Atomic{Int}(0)

@inline function _next_id!(counter::Threads.Atomic{Int})
    current = counter[]
    while current != typemax(Int)
        next = current + 1
        observed = Threads.atomic_cas!(counter, current, next)
        observed == current && return next
        current = observed
    end
    throw(OverflowError("Object3D ID counter exhausted"))
end

_next_id() = _next_id!(_OBJECT_ID_COUNTER)

function Object3D(; name="")
    Object3D(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
             nothing, AbstractObject3D[], true, name, _next_id())
end

function add!(parent::AbstractObject3D, child::AbstractObject3D)
    parent === child && throw(ArgumentError("Object3D cannot be added as a child of itself"))
    _is_ancestor(child, parent) &&
        throw(ArgumentError("Object3D cannot be added to one of its descendants"))
    old_parent = get_parent(child)
    children = get_children(parent)
    if old_parent === parent
        index = findfirst(candidate -> candidate === child, children)
        index === nothing || deleteat!(children, index)
    elseif old_parent !== nothing
        remove!(old_parent, child)
    end
    push!(children, child)
    set_parent!(child, parent)
    return parent
end

function _is_ancestor(candidate::AbstractObject3D, obj::AbstractObject3D)
    p = get_parent(obj)
    while p !== nothing
        p === candidate && return true
        p = get_parent(p)
    end
    return false
end

function remove!(parent::AbstractObject3D, child::AbstractObject3D)
    children = get_children(parent)
    idx = findfirst(c -> c === child, children)
    if idx !== nothing
        deleteat!(children, idx)
        set_parent!(child, nothing)
    end
    return parent
end

# Default accessors for Object3D fields — subtypes override via their own fields
get_position(o::Object3D) = o.position
get_rotation(o::Object3D) = o.rotation
get_scale(o::Object3D) = o.scale
get_children(o::Object3D) = o.children
get_parent(o::Object3D) = o.parent
is_visible(o::Object3D) = o.visible
set_parent!(o::Object3D, p) = (o.parent = p)

@noinline function _throw_object_transform(kind::Symbol, label::Symbol)
    throw(ArgumentError("$kind $label must have finite components"))
end

@inline function _validate_object_transform(obj::AbstractObject3D)
    kind = nameof(typeof(obj))
    position = get_position(obj)
    isfinite(position.x) && isfinite(position.y) && isfinite(position.z) ||
        _throw_object_transform(kind, :position)
    rotation = get_rotation(obj)
    isfinite(rotation.x) && isfinite(rotation.y) && isfinite(rotation.z) ||
        _throw_object_transform(kind, :rotation)
    scale = get_scale(obj)
    isfinite(scale.x) && isfinite(scale.y) && isfinite(scale.z) ||
        _throw_object_transform(kind, :scale)
    return nothing
end

function compute_local_matrix(obj::AbstractObject3D)
    _validate_object_transform(obj)
    pos = get_position(obj)
    rot = get_rotation(obj)
    scl = get_scale(obj)
    q = quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)
    composed = mat4_compose(pos, q, scl)
    _compose_matches_product(composed, quat_to_mat4(q), scl) && return composed
    T = mat4_translation(pos.x, pos.y, pos.z)
    R = quat_to_mat4(q)
    S = mat4_scaling(scl.x, scl.y, scl.z)
    T * R * S
end

# The direct composition equals T * R * S bit for bit unless a scaled rotation
# entry overflows or underflows; those rare inputs keep the product's rounding.
@inline function _compose_matches_product(composed::Mat4, rotation::Mat4, scale::Vec3)
    @inbounds for column in 1:3, row in 1:3
        index = (column - 1) * 4 + row
        value = composed.e[index]
        factor = column == 1 ? scale.x : column == 2 ? scale.y : scale.z
        isfinite(value) && !issubnormal(value) || return false
        iszero(value) && !iszero(rotation.e[index]) && !iszero(factor) && return false
    end
    return true
end

function compute_world_matrix(obj::AbstractObject3D)
    local_mat = compute_local_matrix(obj)
    p = get_parent(obj)
    if p === nothing
        return local_mat
    else
        return compute_world_matrix(p) * local_mat
    end
end

macro _compute_world_matrix_method(T, parent_types...)
    branch = :(compute_world_matrix(p) * local_mat)
    for parent_type in reverse(parent_types)
        branch = quote
            if p isa $parent_type
                compute_world_matrix(p) * local_mat
            else
                $branch
            end
        end
    end

    esc(quote
        function compute_world_matrix(obj::$T)::Mat4{Float64}
            local_mat = compute_local_matrix(obj)
            p = obj.parent
            if p === nothing
                local_mat
            else
                $branch
            end
        end
    end)
end

# ========================== Fog ==========================

abstract type AbstractFog end

@noinline function _throw_scene_color(label::String)
    throw(ArgumentError("$label must be a Color3 with finite components"))
end

@inline function _validated_scene_color(value, label::String)
    value isa Color3 || _throw_scene_color(label)
    color = convert(Color3{Float64}, value)
    isfinite(color.r) && isfinite(color.g) && isfinite(color.b) ||
        _throw_scene_color(label)
    return color
end

function _validated_fog_range(near, far)
    near isa Real && !(near isa Bool) ||
        throw(ArgumentError("Fog near must be finite and non-negative"))
    far isa Real && !(far isa Bool) ||
        throw(ArgumentError("Fog far must be finite and greater than near"))
    near_value = Float64(near)
    far_value = Float64(far)
    isfinite(near_value) && near_value >= 0.0 ||
        throw(ArgumentError("Fog near must be finite and non-negative"))
    isfinite(far_value) && far_value > near_value ||
        throw(ArgumentError("Fog far must be finite and greater than near"))
    return near_value, far_value
end

struct Fog <: AbstractFog
    color::Color3{Float64}
    near::Float64
    far::Float64

    function Fog(color, near, far)
        near_value, far_value = _validated_fog_range(near, far)
        return new(_validated_scene_color(color, "Fog color"),
                   near_value, far_value)
    end
end

Fog(; color=Color3(1.0, 1.0, 1.0), near=1.0, far=1000.0) =
    Fog(color, near, far)

function _validated_fog_density(density)
    density isa Real && !(density isa Bool) ||
        throw(ArgumentError("FogExp2 density must be finite and non-negative"))
    value = Float64(density)
    isfinite(value) && value >= 0.0 ||
        throw(ArgumentError("FogExp2 density must be finite and non-negative"))
    return value
end

struct FogExp2 <: AbstractFog
    color::Color3{Float64}
    density::Float64

    function FogExp2(color, density)
        return new(_validated_scene_color(color, "FogExp2 color"),
                   _validated_fog_density(density))
    end
end

FogExp2(; color=Color3(1.0, 1.0, 1.0), density=0.00025) =
    FogExp2(color, density)

@inline _validate_fog(::Nothing) = nothing

@inline function _validate_fog(fog::Fog)
    _validated_scene_color(fog.color, "Fog color")
    _validated_fog_range(fog.near, fog.far)
    return nothing
end

@inline function _validate_fog(fog::FogExp2)
    _validated_scene_color(fog.color, "FogExp2 color")
    _validated_fog_density(fog.density)
    return nothing
end

# ========================== Scene ==========================

mutable struct Scene <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    background::Color3{Float64}
    fog::Union{Nothing, AbstractFog}
end

function Scene(; background=Color3(0.0, 0.0, 0.0), fog=nothing, name="Scene")
    fog === nothing || fog isa AbstractFog ||
        throw(ArgumentError("Scene fog must be nothing, Fog, or FogExp2"))
    _validate_fog(fog)
    Scene(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
          nothing, AbstractObject3D[], true, name, _next_id(),
          _validated_scene_color(background, "Scene background"), fog)
end

get_position(o::Scene) = o.position
get_rotation(o::Scene) = o.rotation
get_scale(o::Scene) = o.scale
get_children(o::Scene) = o.children
get_parent(o::Scene) = o.parent
is_visible(o::Scene) = o.visible
set_parent!(o::Scene, p) = (o.parent = p)

# ========================== Group ==========================

mutable struct Group <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
end

function Group(; name="Group")
    Group(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
          nothing, AbstractObject3D[], true, name, _next_id())
end

get_position(o::Group) = o.position
get_rotation(o::Group) = o.rotation
get_scale(o::Group) = o.scale
get_children(o::Group) = o.children
get_parent(o::Group) = o.parent
is_visible(o::Group) = o.visible
set_parent!(o::Group, p) = (o.parent = p)

# ========================== Mesh ==========================

mutable struct Mesh <: AbstractObject3D
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    geometry::Any  # BufferGeometry
    material::Any  # AbstractMaterial
    flat_shading::Union{Nothing, Bool}  # nothing = follow renderer default; true/false = override
    cast_shadow::Bool
    receive_shadow::Bool
    morph_target_influences::Vector{Float64}
    morph_target_names::Vector{String}
end

function Mesh(geometry, material; name="Mesh", flat_shading=nothing,
              cast_shadow::Bool=false, receive_shadow::Bool=false,
              morph_target_influences=Float64[], morph_target_names=String[])
    Mesh(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
         nothing, AbstractObject3D[], true, name, _next_id(),
         geometry, material, flat_shading, cast_shadow, receive_shadow,
         collect(Float64, morph_target_influences),
         collect(String, morph_target_names))
end

get_position(o::Mesh) = o.position
get_rotation(o::Mesh) = o.rotation
get_scale(o::Mesh) = o.scale
get_children(o::Mesh) = o.children
get_parent(o::Mesh) = o.parent
is_visible(o::Mesh) = o.visible
set_parent!(o::Mesh, p) = (o.parent = p)
apply_morph_targets(mesh::Mesh) =
    apply_morph_targets(mesh.geometry, mesh.morph_target_influences)
apply_morph_normals(mesh::Mesh) =
    apply_morph_normals(mesh.geometry, mesh.morph_target_influences)
apply_morph_tangents(mesh::Mesh) =
    apply_morph_tangents(mesh.geometry, mesh.morph_target_influences)

object_casts_shadow(obj) =
    hasproperty(obj, :cast_shadow) ? Bool(getproperty(obj, :cast_shadow)) : false
object_receives_shadow(obj) =
    hasproperty(obj, :receive_shadow) ? Bool(getproperty(obj, :receive_shadow)) : false

# ========================== Line ==========================

mutable struct LineObject <: AbstractObject3D
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

function LineObject(geometry, material; name="Line",
                    morph_target_influences=Float64[], morph_target_names=String[])
    LineObject(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
              nothing, AbstractObject3D[], true, name, _next_id(),
              geometry, material, collect(Float64, morph_target_influences),
              collect(String, morph_target_names))
end

function LineObject(position::Vec3{Float64}, rotation::Euler{Float64},
                    scale::Vec3{Float64},
                    parent::Union{Nothing, AbstractObject3D},
                    children::Vector{AbstractObject3D},
                    visible::Bool, name::String, id::Int, geometry, material)
    LineObject(position, rotation, scale, parent, children, visible, name, id,
               geometry, material, Float64[], String[])
end

get_position(o::LineObject) = o.position
get_rotation(o::LineObject) = o.rotation
get_scale(o::LineObject) = o.scale
get_children(o::LineObject) = o.children
get_parent(o::LineObject) = o.parent
is_visible(o::LineObject) = o.visible
set_parent!(o::LineObject, p) = (o.parent = p)
apply_morph_targets(line::LineObject) =
    apply_morph_targets(line.geometry, line.morph_target_influences)

# ========================== Points ==========================

mutable struct PointsObject <: AbstractObject3D
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

function PointsObject(geometry, material; name="Points",
                      morph_target_influences=Float64[], morph_target_names=String[])
    PointsObject(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
                 nothing, AbstractObject3D[], true, name, _next_id(),
                 geometry, material, collect(Float64, morph_target_influences),
                 collect(String, morph_target_names))
end

function PointsObject(position::Vec3{Float64}, rotation::Euler{Float64},
                      scale::Vec3{Float64},
                      parent::Union{Nothing, AbstractObject3D},
                      children::Vector{AbstractObject3D},
                      visible::Bool, name::String, id::Int, geometry, material)
    PointsObject(position, rotation, scale, parent, children, visible, name, id,
                 geometry, material, Float64[], String[])
end

get_position(o::PointsObject) = o.position
get_rotation(o::PointsObject) = o.rotation
get_scale(o::PointsObject) = o.scale
get_children(o::PointsObject) = o.children
get_parent(o::PointsObject) = o.parent
is_visible(o::PointsObject) = o.visible
set_parent!(o::PointsObject, p) = (o.parent = p)
apply_morph_targets(points::PointsObject) =
    apply_morph_targets(points.geometry, points.morph_target_influences)

@_compute_world_matrix_method Object3D Scene Group Object3D Mesh LineObject PointsObject
@_compute_world_matrix_method Scene Scene Group Object3D Mesh LineObject PointsObject
@_compute_world_matrix_method Group Scene Group Object3D Mesh LineObject PointsObject
@_compute_world_matrix_method Mesh Scene Group Object3D Mesh LineObject PointsObject
@_compute_world_matrix_method LineObject Scene Group Object3D Mesh LineObject PointsObject
@_compute_world_matrix_method PointsObject Scene Group Object3D Mesh LineObject PointsObject

# ========================== Traversal ==========================

function traverse(obj::AbstractObject3D, callback::Function)
    callback(obj)
    for child in get_children(obj)
        traverse(child, callback)
    end
end

# Visibility-aware traversal: invisible nodes are skipped along with their
# entire subtree, matching three.js hierarchical visibility semantics.
function _count_meshes(obj::AbstractObject3D)
    is_visible(obj) || return 0
    n = obj isa Mesh ? 1 : 0
    @inbounds for child in get_children(obj)
        n += _count_meshes(child)
    end
    return n
end

function _fill_meshes!(meshes::Vector{Mesh}, obj::AbstractObject3D, i::Int)
    is_visible(obj) || return i
    if obj isa Mesh
        meshes[i] = obj
        i += 1
    end
    @inbounds for child in get_children(obj)
        i = _fill_meshes!(meshes, child, i)
    end
    return i
end

function _collect_meshes!(meshes::Vector{Mesh}, obj::AbstractObject3D)
    is_visible(obj) || return nothing
    obj isa Mesh && push!(meshes, obj)
    for child in get_children(obj)
        _collect_meshes!(meshes, child)
    end
    return nothing
end

function collect_meshes(scene::AbstractObject3D)
    meshes = Vector{Mesh}(undef, _count_meshes(scene))
    _fill_meshes!(meshes, scene, 1)
    return meshes
end

"""
    traverse_visible(object, callback)

Call `callback` on `object` and its descendants, skipping every invisible node
together with its subtree (three.js `Object3D.traverseVisible`).
"""
function traverse_visible(obj::AbstractObject3D, callback)
    is_visible(obj) || return nothing
    callback(obj)
    for child in get_children(obj)
        traverse_visible(child, callback)
    end
    return nothing
end

"""
    traverse_ancestors(object, callback)

Call `callback` on the parent of `object`, then on its parent and so on up to
the root; `object` itself is not visited (three.js
`Object3D.traverseAncestors`).
"""
function traverse_ancestors(obj::AbstractObject3D, callback)
    parent = get_parent(obj)
    while parent !== nothing
        callback(parent)
        parent = get_parent(parent)
    end
    return nothing
end

"""
    get_object_by_property(root, name::Symbol, value) -> object or nothing

First node, in depth-first pre-order starting at `root` itself, whose
property `name` is equal (`isequal`) to `value` (three.js
`Object3D.getObjectByProperty`). Returns `nothing` when no node matches.
"""
function get_object_by_property(obj::AbstractObject3D, name::Symbol, value)
    hasproperty(obj, name) && isequal(getproperty(obj, name), value) && return obj
    for child in get_children(obj)
        found = get_object_by_property(child, name, value)
        found === nothing || return found
    end
    return nothing
end

"""
    get_object_by_name(root, name) -> object or nothing

First node named `name` in depth-first pre-order from `root` (three.js
`Object3D.getObjectByName`).
"""
get_object_by_name(obj::AbstractObject3D, name::AbstractString) =
    get_object_by_property(obj, :name, name)

"""
    get_object_by_id(root, id) -> object or nothing

Node with object id `id` in the subtree of `root` (three.js
`Object3D.getObjectById`).
"""
get_object_by_id(obj::AbstractObject3D, id::Integer) =
    get_object_by_property(obj, :id, id)

"""
    remove_from_parent!(object) -> object

Detach `object` from its parent, if it has one (three.js
`Object3D.removeFromParent`).
"""
function remove_from_parent!(obj::AbstractObject3D)
    parent = get_parent(obj)
    parent === nothing || remove!(parent, obj)
    return obj
end

"""
    clear_children!(object) -> object

Remove every child of `object` (three.js `Object3D.clear`).
"""
function clear_children!(obj::AbstractObject3D)
    children = get_children(obj)
    for child in children
        set_parent!(child, nothing)
    end
    empty!(children)
    return obj
end

# ------------------------- Transform helpers -------------------------
# Diff3D stores an Euler rotation; three.js stores the equivalent quaternion
# and re-derives the Euler angles with the same order after each change.

@inline function _object_quaternion(obj::AbstractObject3D)
    rotation = get_rotation(obj)
    return quat_from_euler(rotation.x, rotation.y, rotation.z; order=rotation.order)
end

@noinline _throw_object_vector(label::String) =
    throw(ArgumentError("$label must be a Vec3 with finite components"))

@inline function _validated_object_vector(value, label::String)
    value isa Vec3 || _throw_object_vector(label)
    vector = convert(Vec3{Float64}, value)
    isfinite(vector.x) && isfinite(vector.y) && isfinite(vector.z) ||
        _throw_object_vector(label)
    return vector
end

@inline function _validated_object_scalar(value, label::String)
    value isa Real && !(value isa Bool) ||
        throw(ArgumentError("$label must be finite"))
    scalar = Float64(value)
    isfinite(scalar) || throw(ArgumentError("$label must be finite"))
    return scalar
end

function _set_object_quaternion!(obj::AbstractObject3D, q::Quaternion)
    _object_rotation_settable(obj)
    rotation = euler_from_quaternion(quat_normalize(q), get_rotation(obj).order)
    isfinite(rotation.x) && isfinite(rotation.y) && isfinite(rotation.z) ||
        throw(ArgumentError("$(nameof(typeof(obj))) rotation update is not finite"))
    obj.rotation = rotation
    return obj
end

# Hook for node types whose rendered orientation does not come from
# `rotation` (target-aimed cameras); see cameras.jl.
@inline _object_rotation_settable(::AbstractObject3D) = nothing

"""
    rotate_on_axis!(object, axis, angle) -> object

Rotate `object` by `angle` radians about the unit `axis` in its local space
(three.js `Object3D.rotateOnAxis`). The Euler order of `object.rotation` is
kept.
"""
function rotate_on_axis!(obj::AbstractObject3D, axis::Vec3, angle::Real)
    _validate_object_transform(obj)
    a = _validated_object_vector(axis, "rotate_on_axis! axis")
    q = quat_from_axis_angle(a, _validated_object_scalar(angle, "rotate_on_axis! angle"))
    return _set_object_quaternion!(obj, quat_multiply(_object_quaternion(obj), q))
end

"""
    rotate_on_world_axis!(object, axis, angle) -> object

Rotate `object` by `angle` radians about the unit `axis` given in its parent's
frame, which is world space for an unrotated parent (three.js
`Object3D.rotateOnWorldAxis`, which also assumes no rotated parent).
"""
function rotate_on_world_axis!(obj::AbstractObject3D, axis::Vec3, angle::Real)
    _validate_object_transform(obj)
    a = _validated_object_vector(axis, "rotate_on_world_axis! axis")
    q = quat_from_axis_angle(a, _validated_object_scalar(angle, "rotate_on_world_axis! angle"))
    return _set_object_quaternion!(obj, quat_multiply(q, _object_quaternion(obj)))
end

"""
    rotate_x!(object, angle) -> object

Rotate about the local x axis (three.js `Object3D.rotateX`).
"""
rotate_x!(obj::AbstractObject3D, angle::Real) =
    rotate_on_axis!(obj, Vec3(1.0, 0.0, 0.0), angle)

"""
    rotate_y!(object, angle) -> object

Rotate about the local y axis (three.js `Object3D.rotateY`).
"""
rotate_y!(obj::AbstractObject3D, angle::Real) =
    rotate_on_axis!(obj, Vec3(0.0, 1.0, 0.0), angle)

"""
    rotate_z!(object, angle) -> object

Rotate about the local z axis (three.js `Object3D.rotateZ`).
"""
rotate_z!(obj::AbstractObject3D, angle::Real) =
    rotate_on_axis!(obj, Vec3(0.0, 0.0, 1.0), angle)

"""
    translate_on_axis!(object, axis, distance) -> object

Move `object` by `distance` along the unit `axis` in its local (rotated)
frame (three.js `Object3D.translateOnAxis`).
"""
function translate_on_axis!(obj::AbstractObject3D, axis::Vec3, distance::Real)
    _validate_object_transform(obj)
    a = _validated_object_vector(axis, "translate_on_axis! axis")
    d = _validated_object_scalar(distance, "translate_on_axis! distance")
    position = get_position(obj) + quat_rotate_vector(_object_quaternion(obj), a) * d
    obj.position = _validated_object_vector(position, "translate_on_axis! position")
    return obj
end

"""
    translate_x!(object, distance) -> object

Move along the local x axis (three.js `Object3D.translateX`).
"""
translate_x!(obj::AbstractObject3D, distance::Real) =
    translate_on_axis!(obj, Vec3(1.0, 0.0, 0.0), distance)

"""
    translate_y!(object, distance) -> object

Move along the local y axis (three.js `Object3D.translateY`).
"""
translate_y!(obj::AbstractObject3D, distance::Real) =
    translate_on_axis!(obj, Vec3(0.0, 1.0, 0.0), distance)

"""
    translate_z!(object, distance) -> object

Move along the local z axis (three.js `Object3D.translateZ`).
"""
translate_z!(obj::AbstractObject3D, distance::Real) =
    translate_on_axis!(obj, Vec3(0.0, 0.0, 1.0), distance)

"""
    local_to_world(object, point) -> Vec3

Transform `point` from the local space of `object` to world space (three.js
`Object3D.localToWorld`).
"""
local_to_world(obj::AbstractObject3D, point::Vec3) =
    mat4_transform_point(compute_world_matrix(obj), point)

"""
    world_to_local(object, point) -> Vec3

Transform the world-space `point` into the local space of `object` (three.js
`Object3D.worldToLocal`).
"""
world_to_local(obj::AbstractObject3D, point::Vec3) =
    mat4_transform_point(mat4_inverse(compute_world_matrix(obj)), point)

"""
    get_world_position(object) -> Vec3

World-space position of `object` (three.js `Object3D.getWorldPosition`).
"""
function get_world_position(obj::AbstractObject3D)
    e = compute_world_matrix(obj).e
    return Vec3(e[13], e[14], e[15])
end

"""
    get_world_quaternion(object) -> Quaternion

Rotation part of the world matrix of `object`, from `mat4_decompose` (three.js
`Object3D.getWorldQuaternion`).
"""
get_world_quaternion(obj::AbstractObject3D) = mat4_decompose(compute_world_matrix(obj))[2]

"""
    get_world_scale(object) -> Vec3

Scale part of the world matrix of `object`, from `mat4_decompose` (three.js
`Object3D.getWorldScale`).
"""
get_world_scale(obj::AbstractObject3D) = mat4_decompose(compute_world_matrix(obj))[3]

"""
    get_world_direction(object) -> Vec3

Unit world direction of the local +z axis of `object` (three.js
`Object3D.getWorldDirection`). Cameras return their viewing direction, the
local -z axis, as three.js `Camera.getWorldDirection` does.
"""
function get_world_direction(obj::AbstractObject3D)
    e = compute_world_matrix(obj).e
    return normalize(Vec3(e[9], e[10], e[11]))
end

# Rotation part of a world matrix with the column scales removed
# (three.js Matrix4.extractRotation followed by Quaternion.setFromRotationMatrix).
function _world_rotation_quaternion(world::Mat4)
    e = world.e
    sx = 1 / _norm3(e[1], e[2], e[3])
    sy = 1 / _norm3(e[5], e[6], e[7])
    sz = 1 / _norm3(e[9], e[10], e[11])
    rotation = Mat4((e[1] * sx, e[2] * sx, e[3] * sx, 0.0,
                     e[5] * sy, e[6] * sy, e[7] * sy, 0.0,
                     e[9] * sz, e[10] * sz, e[11] * sz, 0.0,
                     0.0, 0.0, 0.0, 1.0))
    return quat_from_rotation_matrix(rotation)
end

# three.js Object3D.lookAt (src/core/Object3D.js:609-643): cameras and lights
# point their -z axis at the target, other objects their +z axis.
function _look_at_quaternion(obj::AbstractObject3D, target::Vec3, up::Vec3,
                             eye_convention::Bool)
    _validate_object_transform(obj)
    world = compute_world_matrix(obj)
    position = Vec3(world.e[13], world.e[14], world.e[15])
    view = eye_convention ? mat4_look_at(position, target, up) :
                            mat4_look_at(target, position, up)
    q = quat_from_rotation_matrix(mat4_transpose(view))
    parent = get_parent(obj)
    parent === nothing && return q
    parent_rotation = _world_rotation_quaternion(compute_world_matrix(parent))
    return quat_multiply(quat_invert(quat_normalize(parent_rotation)), q)
end

"""
    look_at!(object, target; up=Vec3(0, 1, 0)) -> object

Rotate `object` so that its local +z axis points at the world-space `target`
(three.js `Object3D.lookAt`), accounting for the world transform of its
parent. Lights point their -z axis at `target` as in three.js. Cameras have
their own method that also aims their `target`.
"""
function look_at!(obj::AbstractObject3D, target::Vec3; up::Vec3=Vec3(0.0, 1.0, 0.0))
    point = _validated_object_vector(target, "look_at! target")
    up_vector = _validated_object_vector(up, "look_at! up")
    eye = obj isa AbstractLight
    return _set_object_quaternion!(obj, _look_at_quaternion(obj, point, up_vector, eye))
end

"""
    attach!(parent, child) -> parent

Make `child` a child of `parent` while keeping its world transform (three.js
`Object3D.attach`). The new local transform is decomposed into position,
rotation (keeping the Euler order) and scale, so shear produced by non-uniform
ancestor scales is dropped as in three.js.
"""
function attach!(parent::AbstractObject3D, child::AbstractObject3D)
    parent === child && throw(ArgumentError("Object3D cannot be added as a child of itself"))
    _is_ancestor(child, parent) &&
        throw(ArgumentError("Object3D cannot be added to one of its descendants"))
    _validate_object_transform(child)
    old_parent = get_parent(child)
    parent_world = compute_world_matrix(parent)
    determinant = mat4_determinant(parent_world)
    isfinite(determinant) && !iszero(determinant) ||
        throw(ArgumentError("attach! parent world matrix must be invertible"))
    to_new = mat4_inverse(parent_world)
    old_parent === nothing || (to_new = to_new * compute_world_matrix(old_parent))
    position, quaternion, scale = mat4_decompose(to_new * compute_local_matrix(child))
    all(isfinite, (position.x, position.y, position.z, quaternion.x, quaternion.y,
                   quaternion.z, quaternion.w, scale.x, scale.y, scale.z)) ||
        throw(ArgumentError("attach! produces a non-finite local transform"))
    child.position = position
    child.rotation = euler_from_quaternion(quaternion, get_rotation(child).order)
    child.scale = scale
    add!(parent, child)
    return parent
end
