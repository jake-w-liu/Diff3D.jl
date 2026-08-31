# --------------------------------------------------------------------------
# Cameras: PerspectiveCamera, OrthographicCamera
# --------------------------------------------------------------------------

abstract type AbstractCamera <: AbstractObject3D end

mutable struct PerspectiveCamera <: AbstractCamera
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    fov::Float64       # vertical field of view in radians
    aspect::Float64
    near::Float64
    far::Float64
    zoom::Float64
    target::Vec3{Float64}  # look-at target
    up::Vec3{Float64}
    ignore_parent_scale::Bool
end

function PerspectiveCamera(position::Vec3{Float64}, rotation::Euler{Float64},
                           scale::Vec3{Float64},
                           parent::Union{Nothing, AbstractObject3D},
                           children::Vector{AbstractObject3D}, visible::Bool,
                           name::String, id::Int, fov, aspect, near, far, zoom,
                           target::Vec3{Float64}, up::Vec3{Float64})
    f, a, n, fr = _validated_perspective_params(fov, aspect, near, far)
    PerspectiveCamera(position, rotation, scale, parent, children, visible,
                      name, id, f, a, n, fr, _validated_camera_zoom(zoom),
                      target, up, false)
end

function PerspectiveCamera(position::Vec3{Float64}, rotation::Euler{Float64},
                           scale::Vec3{Float64},
                           parent::Union{Nothing, AbstractObject3D},
                           children::Vector{AbstractObject3D}, visible::Bool,
                           name::String, id::Int, fov, aspect, near, far,
                           target::Vec3{Float64}, up::Vec3{Float64})
    f, a, n, fr = _validated_perspective_params(fov, aspect, near, far)
    PerspectiveCamera(position, rotation, scale, parent, children, visible,
                      name, id, f, a, n, fr, 1.0, target, up, false)
end

function _validated_camera_zoom(zoom)
    zoom isa Real && !(zoom isa Bool) ||
        throw(ArgumentError("camera zoom must be positive and finite"))
    z = Float64(zoom)
    (isfinite(z) && z > 0.0) || throw(ArgumentError("camera zoom must be positive and finite"))
    return z
end

@noinline function _throw_camera_vector(kind::Symbol, label::Symbol)
    throw(ArgumentError("$kind $label must be a Vec3 with finite components"))
end

@inline function _validated_camera_vector(value, kind::Symbol, label::Symbol)
    value isa Vec3 || _throw_camera_vector(kind, label)
    result = convert(Vec3{Float64}, value)
    isfinite(result.x) && isfinite(result.y) && isfinite(result.z) ||
        _throw_camera_vector(kind, label)
    return result
end

@noinline function _throw_camera_zero_up(kind::Symbol)
    throw(ArgumentError("$kind up must be non-zero"))
end

@inline function _validated_camera_view_vectors(camera, kind::Symbol)
    position = _validated_camera_vector(camera.position, kind, :position)
    target = _validated_camera_vector(camera.target, kind, :target)
    up = _validated_camera_vector(camera.up, kind, :up)
    max(abs(up.x), abs(up.y), abs(up.z)) > 0.0 ||
        _throw_camera_zero_up(kind)
    return position, target, up
end

function _camera_world_pose(camera::AbstractCamera)
    kind = nameof(typeof(camera))
    position, target, up = _validated_camera_view_vectors(camera, kind)
    parent = get_parent(camera)
    parent === nothing && return position, target, up
    parent_world = compute_world_matrix(parent)::Mat4{Float64}
    world_position = _validated_camera_vector(
        mat4_transform_point(parent_world, position), kind, :position)
    if hasfield(typeof(camera), :ignore_parent_scale) &&
       getfield(camera, :ignore_parent_scale)
        parent_rotation = Quaternion()
        ancestor = parent
        while ancestor !== nothing
            _validate_object_transform(ancestor)
            rotation = get_rotation(ancestor)::Euler{Float64}
            local_rotation = quat_from_euler(
                rotation.x, rotation.y, rotation.z; order=rotation.order)
            parent_rotation = quat_multiply(local_rotation, parent_rotation)
            ancestor = get_parent(ancestor)
        end
        rotation_matrix = quat_to_mat4(quat_normalize(parent_rotation))
        world_direction = _validated_camera_vector(
            mat4_transform_direction(rotation_matrix, target - position),
            kind, :target)
        world_target = _validated_camera_vector(
            world_position + world_direction, kind, :target)
        world_up = _validated_camera_vector(
            normalize(mat4_transform_direction(rotation_matrix, up)), kind, :up)
        max(abs(world_up.x), abs(world_up.y), abs(world_up.z)) > 0.0 ||
            _throw_camera_zero_up(kind)
        return world_position, world_target, world_up
    end
    world_target = _validated_camera_vector(
        mat4_transform_point(parent_world, target), kind, :target)
    world_up = _validated_camera_vector(
        normalize(mat4_transform_direction(parent_world, up)), kind, :up)
    max(abs(world_up.x), abs(world_up.y), abs(world_up.z)) > 0.0 ||
        _throw_camera_zero_up(kind)
    return world_position, world_target, world_up
end

@inline _camera_world_position(camera::AbstractCamera) =
    first(_camera_world_pose(camera))

@inline function _camera_backward_from_view(view::Mat4)
    return Vec3(mat4_get(view, 3, 1),
                mat4_get(view, 3, 2),
                mat4_get(view, 3, 3))
end

function _validated_perspective_params(fov, aspect, near, far)
    fov isa Real && !(fov isa Bool) ||
        throw(ArgumentError("PerspectiveCamera fov must be finite and between 0 and pi radians"))
    aspect isa Real && !(aspect isa Bool) ||
        throw(ArgumentError("PerspectiveCamera aspect must be finite and positive"))
    near isa Real && !(near isa Bool) ||
        throw(ArgumentError("PerspectiveCamera near must be finite and positive"))
    far isa Real && !(far isa Bool) ||
        throw(ArgumentError("PerspectiveCamera far must be finite and greater than near, or +Inf"))
    f = Float64(fov)
    a = Float64(aspect)
    n = Float64(near)
    fr = Float64(far)
    isfinite(f) && 0.0 < f < Float64(pi) ||
        throw(ArgumentError("PerspectiveCamera fov must be finite and between 0 and pi radians"))
    isfinite(a) && a > 0.0 ||
        throw(ArgumentError("PerspectiveCamera aspect must be finite and positive"))
    isfinite(n) && n > 0.0 ||
        throw(ArgumentError("PerspectiveCamera near must be finite and positive"))
    !isnan(fr) || throw(ArgumentError("PerspectiveCamera far must not be NaN"))
    (isinf(fr) && fr > 0.0) || (isfinite(fr) && fr > n) ||
        throw(ArgumentError("PerspectiveCamera far must be finite and greater than near, or +Inf"))
    return f, a, n, fr
end

function _validated_orthographic_params(left, right, bottom, top, near, far)
    left isa Real && !(left isa Bool) &&
        right isa Real && !(right isa Bool) ||
        throw(ArgumentError("OrthographicCamera left and right must be finite"))
    bottom isa Real && !(bottom isa Bool) &&
        top isa Real && !(top isa Bool) ||
        throw(ArgumentError("OrthographicCamera bottom and top must be finite"))
    near isa Real && !(near isa Bool) ||
        throw(ArgumentError("OrthographicCamera near must be finite and non-negative"))
    far isa Real && !(far isa Bool) ||
        throw(ArgumentError("OrthographicCamera far must be finite and greater than near"))
    l = Float64(left)
    r = Float64(right)
    b = Float64(bottom)
    t = Float64(top)
    n = Float64(near)
    fr = Float64(far)
    isfinite(l) && isfinite(r) ||
        throw(ArgumentError("OrthographicCamera left and right must be finite"))
    isfinite(b) && isfinite(t) ||
        throw(ArgumentError("OrthographicCamera bottom and top must be finite"))
    l != r || throw(ArgumentError("OrthographicCamera left and right must differ"))
    b != t || throw(ArgumentError("OrthographicCamera bottom and top must differ"))
    isfinite(n) && n >= 0.0 ||
        throw(ArgumentError("OrthographicCamera near must be finite and non-negative"))
    isfinite(fr) && fr > n ||
        throw(ArgumentError("OrthographicCamera far must be finite and greater than near"))
    return l, r, b, t, n, fr
end

function PerspectiveCamera(; fov=π/4, aspect=1.0, near=0.1, far=1000.0,
                           zoom=1.0, name="PerspectiveCamera")
    f, a, n, fr = _validated_perspective_params(fov, aspect, near, far)
    PerspectiveCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        f, a, n, fr, _validated_camera_zoom(zoom),
        Vec3(), Vec3(0.0, 1.0, 0.0), false
    )
end

get_position(c::PerspectiveCamera) = c.position
get_rotation(c::PerspectiveCamera) = c.rotation
get_scale(c::PerspectiveCamera) = c.scale
get_children(c::PerspectiveCamera) = c.children
get_parent(c::PerspectiveCamera) = c.parent
is_visible(c::PerspectiveCamera) = c.visible
set_parent!(c::PerspectiveCamera, p) = (c.parent = p)

@noinline function _throw_camera_zoom_projection(kind::Symbol)
    throw(ArgumentError(
        "$kind zoom produces unrepresentable projection coefficients"))
end

@inline function _camera_zoom_required(value::Float64, zoom::Float64,
                                       kind::Symbol)
    result = value * zoom
    isfinite(result) && !iszero(result) ||
        _throw_camera_zoom_projection(kind)
    return result
end

function _perspective_zoom_projection(base::Mat4{Float64}, zoom::Float64)
    sx = _camera_zoom_required(base.e[1], zoom, :PerspectiveCamera)
    sy = _camera_zoom_required(base.e[6], zoom, :PerspectiveCamera)
    elements = Base.setindex(base.e, sx, 1)
    elements = Base.setindex(elements, sy, 6)
    return Mat4{Float64}(elements)
end

function projection_matrix(c::PerspectiveCamera)
    zoom = _validated_camera_zoom(c.zoom)
    f, a, n, fr = _validated_perspective_params(c.fov, c.aspect, c.near, c.far)
    return _perspective_zoom_projection(
        mat4_perspective(f, a, n, fr), zoom)
end

function view_matrix(c::PerspectiveCamera)
    position, target, up = _camera_world_pose(c)
    mat4_look_at(position, target, up)
end

mutable struct OrthographicCamera <: AbstractCamera
    position::Vec3{Float64}
    rotation::Euler{Float64}
    scale::Vec3{Float64}
    parent::Union{Nothing, AbstractObject3D}
    children::Vector{AbstractObject3D}
    visible::Bool
    name::String
    id::Int
    left::Float64
    right::Float64
    bottom::Float64
    top::Float64
    near::Float64
    far::Float64
    zoom::Float64
    target::Vec3{Float64}
    up::Vec3{Float64}
    ignore_parent_scale::Bool
end

function OrthographicCamera(position::Vec3{Float64}, rotation::Euler{Float64},
                            scale::Vec3{Float64},
                            parent::Union{Nothing, AbstractObject3D},
                            children::Vector{AbstractObject3D}, visible::Bool,
                            name::String, id::Int, left, right, bottom, top,
                            near, far, zoom, target::Vec3{Float64},
                            up::Vec3{Float64})
    l, r, b, t, n, fr = _validated_orthographic_params(
        left, right, bottom, top, near, far)
    OrthographicCamera(position, rotation, scale, parent, children, visible,
                       name, id, l, r, b, t, n, fr,
                       _validated_camera_zoom(zoom), target, up, false)
end

function OrthographicCamera(position::Vec3{Float64}, rotation::Euler{Float64},
                            scale::Vec3{Float64},
                            parent::Union{Nothing, AbstractObject3D},
                            children::Vector{AbstractObject3D}, visible::Bool,
                            name::String, id::Int, left, right, bottom, top,
                            near, far, target::Vec3{Float64}, up::Vec3{Float64})
    l, r, b, t, n, fr = _validated_orthographic_params(left, right, bottom, top, near, far)
    OrthographicCamera(position, rotation, scale, parent, children, visible,
                       name, id, l, r, b, t, n, fr, 1.0, target, up, false)
end

function OrthographicCamera(; left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                             near=0.1, far=1000.0, zoom=1.0,
                             name="OrthographicCamera")
    l, r, b, t, n, fr = _validated_orthographic_params(left, right, bottom, top, near, far)
    OrthographicCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        l, r, b, t, n, fr, _validated_camera_zoom(zoom),
        Vec3(), Vec3(0.0, 1.0, 0.0), false
    )
end

get_position(c::OrthographicCamera) = c.position
get_rotation(c::OrthographicCamera) = c.rotation
get_scale(c::OrthographicCamera) = c.scale
get_children(c::OrthographicCamera) = c.children
get_parent(c::OrthographicCamera) = c.parent
is_visible(c::OrthographicCamera) = c.visible
set_parent!(c::OrthographicCamera, p) = (c.parent = p)

@_compute_world_matrix_method(PerspectiveCamera,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera)
@_compute_world_matrix_method(OrthographicCamera,
    Scene, Group, Object3D, Mesh, LineObject, PointsObject,
    PerspectiveCamera, OrthographicCamera)

function _orthographic_zoom_projection(base::Mat4{Float64}, zoom::Float64)
    sx = _camera_zoom_required(base.e[1], zoom, :OrthographicCamera)
    sy = _camera_zoom_required(base.e[6], zoom, :OrthographicCamera)
    tx = base.e[13] * zoom
    ty = base.e[14] * zoom
    isfinite(tx) && isfinite(ty) ||
        _throw_camera_zoom_projection(:OrthographicCamera)
    elements = Base.setindex(base.e, sx, 1)
    elements = Base.setindex(elements, sy, 6)
    elements = Base.setindex(elements, tx, 13)
    elements = Base.setindex(elements, ty, 14)
    return Mat4{Float64}(elements)
end

function projection_matrix(c::OrthographicCamera)
    zoom = _validated_camera_zoom(c.zoom)
    l, r, b, t, n, fr = _validated_orthographic_params(
        c.left, c.right, c.bottom, c.top, c.near, c.far)
    return _orthographic_zoom_projection(
        mat4_orthographic(l, r, b, t, n, fr), zoom)
end

function view_matrix(c::OrthographicCamera)
    position, target, up = _camera_world_pose(c)
    mat4_look_at(position, target, up)
end

# ========================== StereoCamera ==========================
# Produces a left/right eye camera pair for stereo rendering.

mutable struct StereoCamera
    eye_sep::Float64
    cameraL::PerspectiveCamera
    cameraR::PerspectiveCamera
end

function _validated_stereo_eye_sep(eye_sep)
    eye_sep isa Real && !(eye_sep isa Bool) ||
        throw(ArgumentError("StereoCamera eye_sep must be finite"))
    separation = Float64(eye_sep)
    isfinite(separation) ||
        throw(ArgumentError("StereoCamera eye_sep must be finite"))
    return separation
end

function StereoCamera(; eye_sep=0.064, aspect=1.0)
    StereoCamera(
        _validated_stereo_eye_sep(eye_sep),
        PerspectiveCamera(aspect=aspect),
        PerspectiveCamera(aspect=aspect),
    )
end

"""
Update the left/right eye cameras from a base camera: each eye is the base
camera shifted by ∓`eye_sep`/2 along the camera's world right axis.
"""
function stereo_update!(s::StereoCamera, cam::PerspectiveCamera)
    view = view_matrix(cam)
    camera_position, camera_target, camera_up = _camera_world_pose(cam)
    # The first view-matrix row is the camera's normalized world-right axis.
    # Reuse the overflow-safe look-at construction instead of subtracting
    # opposite extreme eye/target coordinates here.
    right = Vec3(
        mat4_get(view, 1, 1),
        mat4_get(view, 1, 2),
        mat4_get(view, 1, 3),
    )
    half = _validated_stereo_eye_sep(s.eye_sep) / 2
    for (sub, sign) in ((s.cameraL, -1.0), (s.cameraR, 1.0))
        off = right * (sign * half)
        sub.fov = cam.fov; sub.aspect = cam.aspect
        sub.near = cam.near; sub.far = cam.far; sub.zoom = cam.zoom; sub.up = camera_up
        sub.position = camera_position + off
        sub.target = camera_target + off
    end
    return s
end

# ========================== CubeCamera ==========================
# Six 90°-fov cameras facing the principal axes, for cube-map capture.

struct CubeCamera
    cameras::Vector{PerspectiveCamera}   # order: +x, -x, +y, -y, +z, -z
end

@noinline function _throw_cube_camera_target(axis::String)
    throw(ArgumentError(
        "CubeCamera position cannot represent a finite target in the $axis direction"))
end

@inline function _cube_camera_target_coordinate(value::Float64,
                                                direction::Float64,
                                                axis::String)
    candidate = value + direction
    isfinite(candidate) && candidate != value && return candidate
    adjacent = direction > 0.0 ? nextfloat(value) : prevfloat(value)
    isfinite(adjacent) && adjacent != value && return adjacent
    return _throw_cube_camera_target(axis)
end

@inline function _cube_camera_target(position::Vec3{Float64},
                                     direction::Vec3{Float64},
                                     axis::String)
    return Vec3(
        iszero(direction.x) ? position.x :
            _cube_camera_target_coordinate(position.x, direction.x, axis),
        iszero(direction.y) ? position.y :
            _cube_camera_target_coordinate(position.y, direction.y, axis),
        iszero(direction.z) ? position.z :
            _cube_camera_target_coordinate(position.z, direction.z, axis),
    )
end

function CubeCamera(; near=0.1, far=1000.0, position=Vec3())
    cube_position = _validated_camera_vector(position, :CubeCamera, :position)
    faces = ((Vec3( 1.0,0,0), Vec3(0.0,-1,0), "+X"),
             (Vec3(-1.0,0,0), Vec3(0.0,-1,0), "-X"),
             (Vec3(0.0, 1,0), Vec3(0.0,0, 1), "+Y"),
             (Vec3(0.0,-1,0), Vec3(0.0,0,-1), "-Y"),
             (Vec3(0.0,0, 1), Vec3(0.0,-1,0), "+Z"),
             (Vec3(0.0,0,-1), Vec3(0.0,-1,0), "-Z"))
    cams = PerspectiveCamera[]
    for (dir, up, axis) in faces
        c = PerspectiveCamera(fov=π/2, aspect=1.0, near=near, far=far)
        c.position = cube_position
        c.target = _cube_camera_target(cube_position, dir, axis)
        c.up = up
        push!(cams, c)
    end
    CubeCamera(cams)
end

# ========================== ArrayCamera ==========================
# A set of sub-cameras, each owning a screen viewport (x, y, width, height).

struct ArrayCamera
    cameras::Vector{PerspectiveCamera}
    viewports::Vector{NTuple{4,Int}}
end
ArrayCamera(cameras::Vector{PerspectiveCamera}) =
    ArrayCamera(cameras, [(0, 0, 0, 0) for _ in cameras])

# Parametric view/projection for AD — takes raw camera parameters
function view_matrix_from_params(eye_x, eye_y, eye_z, target_x, target_y, target_z,
                                  up_x, up_y, up_z)
    eye = Vec3(eye_x, eye_y, eye_z)
    target = Vec3(target_x, target_y, target_z)
    up = Vec3(up_x, up_y, up_z)
    mat4_look_at(eye, target, up)
end

function projection_matrix_from_params(fov, aspect, near, far)
    mat4_perspective(fov, aspect, near, far)
end
