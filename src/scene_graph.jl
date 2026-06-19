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
const _OBJECT_ID_COUNTER = Ref(0)
function _next_id()
    _OBJECT_ID_COUNTER[] += 1
    return _OBJECT_ID_COUNTER[]
end

function Object3D(; name="")
    Object3D(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
             nothing, AbstractObject3D[], true, name, _next_id())
end

function add!(parent::AbstractObject3D, child::AbstractObject3D)
    parent === child && throw(ArgumentError("Object3D cannot be added as a child of itself"))
    _is_ancestor(child, parent) &&
        throw(ArgumentError("Object3D cannot be added to one of its descendants"))
    old_parent = get_parent(child)
    old_parent === parent && return parent
    old_parent !== nothing && remove!(old_parent, child)
    push!(get_children(parent), child)
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

function compute_local_matrix(obj::AbstractObject3D)
    pos = get_position(obj)
    rot = get_rotation(obj)
    scl = get_scale(obj)
    q = quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)
    T = mat4_translation(pos.x, pos.y, pos.z)
    R = quat_to_mat4(q)
    S = mat4_scaling(scl.x, scl.y, scl.z)
    T * R * S
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

# ========================== Fog ==========================

abstract type AbstractFog end

struct Fog <: AbstractFog
    color::Color3{Float64}
    near::Float64
    far::Float64
end

Fog(; color=Color3(1.0, 1.0, 1.0), near::Real=1.0, far::Real=1000.0) =
    Fog(color, Float64(near), Float64(far))

struct FogExp2 <: AbstractFog
    color::Color3{Float64}
    density::Float64
end

FogExp2(; color=Color3(1.0, 1.0, 1.0), density::Real=0.00025) =
    FogExp2(color, Float64(density))

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
    Scene(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0),
          nothing, AbstractObject3D[], true, name, _next_id(), background, fog)
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

# ========================== Traversal ==========================

function traverse(obj::AbstractObject3D, callback::Function)
    callback(obj)
    for child in get_children(obj)
        traverse(child, callback)
    end
end

# Visibility-aware traversal: invisible nodes are skipped along with their
# entire subtree, matching three.js hierarchical visibility semantics.
function _collect_meshes!(meshes::Vector{Mesh}, obj::AbstractObject3D)
    is_visible(obj) || return nothing
    obj isa Mesh && push!(meshes, obj)
    for child in get_children(obj)
        _collect_meshes!(meshes, child)
    end
    return nothing
end

function collect_meshes(scene::AbstractObject3D)
    meshes = Mesh[]
    _collect_meshes!(meshes, scene)
    return meshes
end
