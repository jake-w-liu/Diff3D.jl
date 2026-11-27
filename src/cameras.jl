# --------------------------------------------------------------------------
# Cameras: PerspectiveCamera, OrthographicCamera
# --------------------------------------------------------------------------

abstract type AbstractCamera <: AbstractObject3D end

"""
    CameraView(enabled, full_width, full_height, offset_x, offset_y, width, height)

View-offset window of a `PerspectiveCamera` or `OrthographicCamera` (three.js
`camera.view`). The camera renders the `width`×`height` sub-rectangle whose top
left corner is `(offset_x, offset_y)` inside a `full_width`×`full_height`
virtual view. Set it with [`set_view_offset!`](@ref) and disable it with
[`clear_view_offset!`](@ref), which keeps the stored window with
`enabled == false` as three.js does.
"""
struct CameraView
    enabled::Bool
    full_width::Float64
    full_height::Float64
    offset_x::Float64
    offset_y::Float64
    width::Float64
    height::Float64
end

"""
    PerspectiveCamera(; fov=π/4, aspect=1.0, near=0.1, far=1000.0, zoom=1.0,
                      focus=10.0, film_gauge=35.0, film_offset=0.0,
                      name="PerspectiveCamera", rotation_driven=false)

Perspective camera with a vertical field of view `fov` in radians. It is aimed
through its `position`, `target` and `up` fields (or its `rotation` when
`rotation_driven`). As in three.js `PerspectiveCamera`, `zoom` scales the
image, `film_gauge` (mm) and `film_offset` (mm, horizontal) describe the film
used by [`get_focal_length`](@ref) and the off-axis film shift, `focus` is the
object distance used by `StereoCamera`, and `view` holds an optional
[`CameraView`](@ref) set with [`set_view_offset!`](@ref).
[`projection_matrix`](@ref) follows three.js `updateProjectionMatrix` for every
combination of these properties. An infinite `far` gives the limiting
infinite-far projection.
"""
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
    rotation_driven::Bool
    focus::Float64
    film_gauge::Float64
    film_offset::Float64
    view::Union{Nothing, CameraView}
end

# Earlier field layouts: without `rotation_driven`, and without the film,
# focus and view-offset fields added after it (three.js defaults).
PerspectiveCamera(args::Vararg{Any,16}) = PerspectiveCamera(args..., false)
PerspectiveCamera(args::Vararg{Any,17}) =
    PerspectiveCamera(args..., 10.0, 35.0, 0.0, nothing)

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

# A camera's ancestors are abstractly typed. Branch over the concrete node
# types so per-node work dispatches statically; a dynamic call would box each
# returned matrix or Euler value on every view_matrix call. The fallback
# asserts the result type so the known branches are not merged into `Any`.
@inline function _with_concrete_node(f::F, node::AbstractObject3D,
                                     ::Type{R}) where {F, R}
    node isa Group && return f(node)::R
    node isa Scene && return f(node)::R
    node isa Object3D && return f(node)::R
    node isa Mesh && return f(node)::R
    node isa PerspectiveCamera && return f(node)::R
    node isa OrthographicCamera && return f(node)::R
    node isa Bone && return f(node)::R
    node isa SkinnedMesh && return f(node)::R
    node isa InstancedMesh && return f(node)::R
    node isa LineObject && return f(node)::R
    node isa PointsObject && return f(node)::R
    return f(node)::R
end

@inline _node_world_matrix(node::AbstractObject3D) =
    @inline _with_concrete_node(compute_world_matrix, node, Mat4{Float64})

@inline function _validated_node_rotation(node::AbstractObject3D)
    _validate_object_transform(node)
    return get_rotation(node)
end

function _camera_world_pose(camera::AbstractCamera)
    if hasfield(typeof(camera), :rotation_driven) && camera.rotation_driven
        position, direction, up = _camera_rotation_pose(camera)
        return position, position + direction, up
    end
    kind = nameof(typeof(camera))
    position, target, up = _validated_camera_view_vectors(camera, kind)
    parent = get_parent(camera)
    parent === nothing && return position, target, up
    parent_world = _node_world_matrix(parent)
    world_position = _validated_camera_vector(
        mat4_transform_point(parent_world, position), kind, :position)
    if hasfield(typeof(camera), :ignore_parent_scale) &&
       getfield(camera, :ignore_parent_scale)
        rotation_matrix = @inline _rotation_without_scale(parent)
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

function _rotation_without_scale(object::AbstractObject3D)
    quaternion = Quaternion()
    node::Union{Nothing, AbstractObject3D} = object
    while node !== nothing
        angles = @inline _with_concrete_node(
            _validated_node_rotation, node, Euler{Float64})
        quaternion = quat_multiply(quat_from_euler(
            angles.x, angles.y, angles.z; order=angles.order), quaternion)
        node = get_parent(node)
    end
    return quat_to_mat4(quat_normalize(quaternion))
end

# Camera orientation excludes its own scale. glTF also excludes inherited scale.
function _camera_rotation_pose(camera::AbstractCamera)
    _validate_object_transform(camera)
    parent = get_parent(camera)
    parent_world = parent === nothing ? Mat4() : _node_world_matrix(parent)
    position = mat4_transform_point(parent_world, camera.position)
    rotation = camera.rotation
    local_rotation = quat_to_mat4(quat_from_euler(
        rotation.x, rotation.y, rotation.z; order=rotation.order))
    world_rotation = if camera.ignore_parent_scale
        _rotation_without_scale(camera)
    else
        parent_world * local_rotation
    end
    direction = normalize(mat4_transform_direction(world_rotation, Vec3(0.0,0.0,-1.0)))
    up = normalize(mat4_transform_direction(world_rotation, Vec3(0.0,1.0,0.0)))
    kind = nameof(typeof(camera))
    position = _validated_camera_vector(position, kind, :position)
    direction = _validated_camera_vector(direction, kind, :target)
    up = _validated_camera_vector(up, kind, :up)
    max(abs(up.x), abs(up.y), abs(up.z)) > 0.0 || _throw_camera_zero_up(kind)
    return position, direction, up
end

function _camera_control_target(camera::AbstractCamera)
    camera.rotation_driven || return camera.target
    angles = camera.rotation
    rotation = quat_to_mat4(quat_from_euler(angles.x, angles.y, angles.z; order=angles.order))
    return camera.position + mat4_transform_direction(rotation, Vec3(0.0,0.0,-1.0))
end

function _prepare_camera_control_up!(camera::AbstractCamera)
    camera.rotation_driven || return camera
    _validate_object_transform(camera)
    angles = camera.rotation
    rotation = quat_to_mat4(quat_from_euler(angles.x, angles.y, angles.z; order=angles.order))
    camera.up = mat4_transform_direction(rotation, Vec3(0.0,1.0,0.0))
    return camera
end

@inline function _view_from_direction(position::Vec3, direction::Vec3, up::Vec3)
    return mat4_look_at(Vec3(), direction, up) *
           mat4_translation(-position.x, -position.y, -position.z)
end

function _sync_camera_rotation_from_view!(camera::AbstractCamera)
    hasfield(typeof(camera), :rotation_driven) && camera.rotation_driven || return camera
    rotation = mat4_transpose(mat4_look_at(camera.position, camera.target, camera.up))
    camera.rotation = _rotation_matrix_to_euler(rotation, camera.rotation.order)
    return camera
end

# Retargeting a glTF-style camera (rotation_driven && ignore_parent_scale)
# through the public target/up fields must re-derive the driving rotation,
# otherwise the stale node rotation silently keeps the old aim. Cameras that
# are only rotation_driven treat rotation as the sole orientation contract.
function Base.setproperty!(camera::AbstractCamera, name::Symbol, value)
    setfield!(camera, name, convert(fieldtype(typeof(camera), name), value))
    if (name === :target || name === :up) &&
       hasfield(typeof(camera), :ignore_parent_scale) &&
       getfield(camera, :ignore_parent_scale)
        _sync_camera_rotation_from_view!(camera)
    end
    return value
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
                           zoom=1.0, focus=10.0, film_gauge=35.0,
                           film_offset=0.0, name="PerspectiveCamera",
                           rotation_driven::Bool=false)
    f, a, n, fr = _validated_perspective_params(fov, aspect, near, far)
    PerspectiveCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        f, a, n, fr, _validated_camera_zoom(zoom),
        Vec3(), Vec3(0.0, 1.0, 0.0), false, rotation_driven,
        _validated_camera_positive(focus, :PerspectiveCamera, :focus),
        _validated_camera_positive(film_gauge, :PerspectiveCamera, :film_gauge),
        _validated_camera_finite(film_offset, :PerspectiveCamera, :film_offset),
        nothing
    )
end

@noinline function _throw_camera_scalar(kind::Symbol, label::Symbol,
                                        requirement::String)
    throw(ArgumentError("$kind $label must be $requirement"))
end

@inline function _validated_camera_finite(value, kind::Symbol, label::Symbol)
    value isa Real && !(value isa Bool) ||
        _throw_camera_scalar(kind, label, "finite")
    result = Float64(value)
    isfinite(result) || _throw_camera_scalar(kind, label, "finite")
    return result
end

@inline function _validated_camera_positive(value, kind::Symbol, label::Symbol)
    value isa Real && !(value isa Bool) ||
        _throw_camera_scalar(kind, label, "finite and positive")
    result = Float64(value)
    isfinite(result) && result > 0.0 ||
        _throw_camera_scalar(kind, label, "finite and positive")
    return result
end

@inline _camera_view_active(view::Nothing) = false
@inline _camera_view_active(view::CameraView) = view.enabled

function _validated_camera_view(view::CameraView, kind::Symbol)
    for (label, value) in ((:full_width, view.full_width),
                           (:full_height, view.full_height),
                           (:width, view.width), (:height, view.height))
        isfinite(value) && value > 0.0 ||
            _throw_camera_scalar(kind, Symbol(:view_, label), "finite and positive")
    end
    isfinite(view.offset_x) ||
        _throw_camera_scalar(kind, :view_offset_x, "finite")
    isfinite(view.offset_y) ||
        _throw_camera_scalar(kind, :view_offset_y, "finite")
    return view
end

function _camera_view(kind::Symbol, full_width, full_height, x, y, width, height)
    return _validated_camera_view(CameraView(true,
        _validated_camera_positive(full_width, kind, :view_full_width),
        _validated_camera_positive(full_height, kind, :view_full_height),
        _validated_camera_finite(x, kind, :view_offset_x),
        _validated_camera_finite(y, kind, :view_offset_y),
        _validated_camera_positive(width, kind, :view_width),
        _validated_camera_positive(height, kind, :view_height)), kind)
end

"""
    set_view_offset!(camera, full_width, full_height, x, y, width, height) -> camera

Render only the `width`×`height` window at offset `(x, y)` (from the top left)
of a `full_width`×`full_height` virtual view, as three.js
`setViewOffset` does for multi-monitor or tiled rendering. For a
`PerspectiveCamera` this also sets `aspect = full_width / full_height`. The
window is stored in `camera.view` and applied by [`projection_matrix`](@ref).
"""
function set_view_offset!(camera::PerspectiveCamera, full_width, full_height,
                          x, y, width, height)
    view = _camera_view(:PerspectiveCamera, full_width, full_height, x, y,
                        width, height)
    aspect = view.full_width / view.full_height
    isfinite(aspect) && aspect > 0.0 ||
        throw(ArgumentError("PerspectiveCamera view offset aspect must be finite and positive"))
    camera.aspect = aspect
    camera.view = view
    return camera
end

"""
    get_film_width(camera::PerspectiveCamera) -> Float64

Width of the image on the film in mm, `film_gauge * min(aspect, 1)` (three.js
`getFilmWidth`).
"""
get_film_width(camera::PerspectiveCamera) =
    _validated_camera_positive(camera.film_gauge, :PerspectiveCamera, :film_gauge) *
    min(camera.aspect, 1.0)

"""
    get_film_height(camera::PerspectiveCamera) -> Float64

Height of the image on the film in mm, `film_gauge / max(aspect, 1)` (three.js
`getFilmHeight`).
"""
get_film_height(camera::PerspectiveCamera) =
    _validated_camera_positive(camera.film_gauge, :PerspectiveCamera, :film_gauge) /
    max(camera.aspect, 1.0)

"""
    get_focal_length(camera::PerspectiveCamera) -> Float64

Focal length in mm for the current `fov` and film height (three.js
`getFocalLength`).
"""
function get_focal_length(camera::PerspectiveCamera)
    f, _, _, _ = _validated_perspective_params(camera.fov, camera.aspect,
                                               camera.near, camera.far)
    return 0.5 * get_film_height(camera) / tan(0.5 * f)
end

"""
    set_focal_length!(camera::PerspectiveCamera, focal_length) -> camera

Set `fov` from a focal length in mm and the current film height (three.js
`setFocalLength`; the default 35 mm film gauge gives the usual 35 mm camera
focal lengths).
"""
function set_focal_length!(camera::PerspectiveCamera, focal_length)
    length_mm = _validated_camera_positive(focal_length, :PerspectiveCamera,
                                           :focal_length)
    slope = 0.5 * get_film_height(camera) / length_mm
    fov = 2 * atan(slope)
    _validated_perspective_params(fov, camera.aspect, camera.near, camera.far)
    camera.fov = fov
    return camera
end

"""
    get_effective_fov(camera::PerspectiveCamera) -> Float64

Vertical field of view in radians after `zoom` (three.js `getEffectiveFOV`,
which returns degrees).
"""
function get_effective_fov(camera::PerspectiveCamera)
    f, _, _, _ = _validated_perspective_params(camera.fov, camera.aspect,
                                               camera.near, camera.far)
    return 2 * atan(tan(0.5 * f) / _validated_camera_zoom(camera.zoom))
end

"""
    get_view_bounds(camera::PerspectiveCamera, distance) -> (min::Vec2, max::Vec2)

Bottom-left and top-right corners of the view rectangle at `distance` in front
of the camera, in camera space (three.js `getViewBounds`). Zoom, view offset
and film offset are included through the projection matrix.
"""
function get_view_bounds(camera::PerspectiveCamera, distance)
    d = _validated_camera_finite(distance, :PerspectiveCamera, :view_distance)
    inverse = mat4_inverse(projection_matrix(camera))
    low = mat4_transform_point(inverse, Vec3(-1.0, -1.0, 0.5))
    high = mat4_transform_point(inverse, Vec3(1.0, 1.0, 0.5))
    low_scale = -d / low.z
    high_scale = -d / high.z
    return Vec2(low.x * low_scale, low.y * low_scale),
           Vec2(high.x * high_scale, high.y * high_scale)
end

"""
    get_view_size(camera::PerspectiveCamera, distance) -> Vec2

Width and height of the view rectangle at `distance` (three.js `getViewSize`).
"""
function get_view_size(camera::PerspectiveCamera, distance)
    low, high = get_view_bounds(camera, distance)
    return Vec2(high.x - low.x, high.y - low.y)
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

@noinline function _throw_camera_offset_projection(kind::Symbol)
    throw(ArgumentError(
        "$kind view or film offset produces unrepresentable projection coefficients"))
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
    base = mat4_perspective(f, a, n, fr)
    view = c.view
    skew = _validated_camera_finite(c.film_offset, :PerspectiveCamera, :film_offset)
    if !_camera_view_active(view) && iszero(skew)
        return _perspective_zoom_projection(base, zoom)
    end
    # Off-axis frustum of three.js PerspectiveCamera.updateProjectionMatrix
    # (src/cameras/PerspectiveCamera.js:366-393), with the depth terms of the
    # symmetric projection so an infinite far plane keeps its limit form.
    top = n * tan(0.5 * f) / zoom
    height = 2 * top
    width = a * height
    left = -0.5 * width
    if view isa CameraView && view.enabled
        _validated_camera_view(view, :PerspectiveCamera)
        left += view.offset_x * width / view.full_width
        top -= view.offset_y * height / view.full_height
        width *= view.width / view.full_width
        height *= view.height / view.full_height
    end
    iszero(skew) || (left += n * skew / get_film_width(c))
    right = left + width
    bottom = top - height
    # Matrix4.makePerspective (src/math/Matrix4.js:1140-1184).
    x = 2 * n / (right - left)
    y = 2 * n / (top - bottom)
    ax = (right + left) / (right - left)
    by = (top + bottom) / (top - bottom)
    isfinite(x) && !iszero(x) && isfinite(y) && !iszero(y) &&
        isfinite(ax) && isfinite(by) ||
        _throw_camera_offset_projection(:PerspectiveCamera)
    elements = Base.setindex(base.e, x, 1)
    elements = Base.setindex(elements, y, 6)
    elements = Base.setindex(elements, ax, 9)
    elements = Base.setindex(elements, by, 10)
    return Mat4{Float64}(elements)
end

function view_matrix(c::PerspectiveCamera)
    c.rotation_driven && return _view_from_direction(_camera_rotation_pose(c)...)
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
    rotation_driven::Bool
    view::Union{Nothing, CameraView}
end

# Earlier field layouts: without `rotation_driven`, and without `view`.
OrthographicCamera(args::Vararg{Any,18}) = OrthographicCamera(args..., false)
OrthographicCamera(args::Vararg{Any,19}) = OrthographicCamera(args..., nothing)

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
                             name="OrthographicCamera", rotation_driven::Bool=false)
    l, r, b, t, n, fr = _validated_orthographic_params(left, right, bottom, top, near, far)
    OrthographicCamera(
        Vec3(0.0, 0.0, 5.0), Euler(), Vec3(1.0, 1.0, 1.0),
        nothing, AbstractObject3D[], true, name, _next_id(),
        l, r, b, t, n, fr, _validated_camera_zoom(zoom),
        Vec3(), Vec3(0.0, 1.0, 0.0), false, rotation_driven, nothing
    )
end

"""
    OrthographicCamera(; left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                       near=0.1, far=1000.0, zoom=1.0,
                       name="OrthographicCamera", rotation_driven=false)

Orthographic camera with the given view-volume bounds. As in three.js,
`zoom` scales the bounds about their center and `view` holds an optional
[`CameraView`](@ref) set with [`set_view_offset!`](@ref);
[`projection_matrix`](@ref) follows three.js `updateProjectionMatrix`.
"""
OrthographicCamera

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
    view = c.view
    _camera_view_active(view) ||
        return _orthographic_zoom_projection(mat4_orthographic(l, r, b, t, n, fr), zoom)
    # three.js OrthographicCamera.updateProjectionMatrix
    # (src/cameras/OrthographicCamera.js:195-223).
    _validated_camera_view(view, :OrthographicCamera)
    scale_w = (r - l) / view.full_width / zoom
    scale_h = (t - b) / view.full_height / zoom
    center_x = (r + l) / 2
    center_y = (t + b) / 2
    view_left = center_x - (r - l) / (2 * zoom) + scale_w * view.offset_x
    view_right = view_left + scale_w * view.width
    view_top = center_y + (t - b) / (2 * zoom) - scale_h * view.offset_y
    view_bottom = view_top - scale_h * view.height
    isfinite(view_left) && isfinite(view_right) && isfinite(view_top) &&
        isfinite(view_bottom) && view_left != view_right &&
        view_top != view_bottom ||
        _throw_camera_offset_projection(:OrthographicCamera)
    return mat4_orthographic(view_left, view_right, view_bottom, view_top, n, fr)
end

function set_view_offset!(camera::OrthographicCamera, full_width, full_height,
                          x, y, width, height)
    camera.view = _camera_view(:OrthographicCamera, full_width, full_height,
                               x, y, width, height)
    return camera
end

"""
    clear_view_offset!(camera) -> camera

Disable a view offset set by [`set_view_offset!`](@ref) (three.js
`clearViewOffset`). The stored window is kept with `enabled == false`.
"""
function clear_view_offset!(camera::Union{PerspectiveCamera, OrthographicCamera})
    view = camera.view
    view === nothing && return camera
    camera.view = CameraView(false, view.full_width, view.full_height,
                             view.offset_x, view.offset_y, view.width, view.height)
    return camera
end

function view_matrix(c::OrthographicCamera)
    c.rotation_driven && return _view_from_direction(_camera_rotation_pose(c)...)
    position, target, up = _camera_world_pose(c)
    mat4_look_at(position, target, up)
end

# ------------------- Object3D transform API for cameras -------------------
# A camera that is not rotation_driven is aimed by position/target/up, so the
# rotation-based Object3D operations act on that aim instead of `rotation`.

@noinline function _throw_camera_rotation_unused(camera::AbstractCamera)
    throw(ArgumentError(
        "$(nameof(typeof(camera))) is aimed by target and up; use look_at! or " *
        "set rotation_driven=true before rotating it"))
end

@inline _object_rotation_settable(camera::AbstractCamera) =
    camera.rotation_driven ? nothing : _throw_camera_rotation_unused(camera)

# Local (parent-space) target and up that reproduce a world-space aim, the
# inverse of `_camera_world_pose`.
function _camera_local_aim(camera::AbstractCamera, world_target::Vec3, world_up::Vec3)
    parent = get_parent(camera)
    parent === nothing && return world_target, world_up
    parent_world = _node_world_matrix(parent)
    if camera.ignore_parent_scale
        rotation = mat4_transpose(_rotation_without_scale(parent))
        world_position = mat4_transform_point(parent_world, camera.position)
        local_target = camera.position +
            mat4_transform_direction(rotation, world_target - world_position)
        return local_target, normalize(mat4_transform_direction(rotation, world_up))
    end
    inverse = mat4_inverse(parent_world)
    return mat4_transform_point(inverse, world_target),
           normalize(mat4_transform_direction(inverse, world_up))
end

"""
    look_at!(camera::AbstractCamera, target; up=camera.up) -> camera

Aim `camera` at the world-space `target`. As in three.js `Object3D.lookAt`
for cameras, `rotation` is set so that the local -z axis points at `target`
with `up` as the up hint, accounting for the parent's world rotation. A camera
that is not `rotation_driven` also stores the equivalent parent-space
`target`, so its view matrix looks at `target`.
"""
function look_at!(camera::AbstractCamera, target::Vec3; up::Vec3=camera.up)
    point = _validated_camera_vector(target, nameof(typeof(camera)), :target)
    up_vector = _validated_camera_vector(up, nameof(typeof(camera)), :up)
    q = _look_at_quaternion(camera, point, up_vector, true)
    rotation = euler_from_quaternion(quat_normalize(q), camera.rotation.order)
    isfinite(rotation.x) && isfinite(rotation.y) && isfinite(rotation.z) ||
        throw(ArgumentError("$(nameof(typeof(camera))) look_at! rotation is not finite"))
    camera.rotation = rotation
    if !camera.rotation_driven
        local_target, _ = _camera_local_aim(camera, point, up_vector)
        camera.target = _validated_camera_vector(
            local_target, nameof(typeof(camera)), :target)
    end
    return camera
end

function translate_on_axis!(camera::AbstractCamera, axis::Vec3, distance::Real)
    camera.rotation_driven && return invoke(
        translate_on_axis!, Tuple{AbstractObject3D, Vec3, Real}, camera, axis, distance)
    a = _validated_object_vector(axis, "translate_on_axis! axis")
    d = _validated_object_scalar(distance, "translate_on_axis! distance")
    position, target, up = _validated_camera_view_vectors(camera, nameof(typeof(camera)))
    # Columns of the transposed look-at basis are the camera's local axes in
    # its parent frame.
    basis = mat4_transpose(mat4_look_at(position, target, up))
    offset = mat4_transform_direction(basis, a) * d
    camera.position = _validated_object_vector(position + offset, "translate_on_axis! position")
    camera.target = _validated_object_vector(target + offset, "translate_on_axis! target")
    return camera
end

"""
    get_world_direction(camera::AbstractCamera) -> Vec3

Unit world-space viewing direction of `camera` (three.js
`Camera.getWorldDirection`), taken from its view matrix.
"""
get_world_direction(camera::AbstractCamera) =
    -_camera_backward_from_view(view_matrix(camera))

function attach!(parent::AbstractObject3D, camera::AbstractCamera)
    camera.rotation_driven && return invoke(
        attach!, Tuple{AbstractObject3D, AbstractObject3D}, parent, camera)
    _, world_target, world_up = _camera_world_pose(camera)
    invoke(attach!, Tuple{AbstractObject3D, AbstractObject3D}, parent, camera)
    local_target, local_up = _camera_local_aim(camera, world_target, world_up)
    kind = nameof(typeof(camera))
    camera.target = _validated_camera_vector(local_target, kind, :target)
    camera.up = _validated_camera_vector(local_up, kind, :up)
    return parent
end

"""
    vec3_project(point, camera) -> Vec3

Normalized device coordinates of the world-space `point` seen by `camera`
(three.js `Vector3.project`): the view matrix, then the projection matrix with
the perspective divide.
"""
vec3_project(point::Vec3, camera::AbstractCamera) =
    mat4_transform_point(projection_matrix(camera),
                         mat4_transform_point(view_matrix(camera), point))

"""
    vec3_unproject(ndc, camera) -> Vec3

World-space point for the normalized device coordinates `ndc` of `camera`,
the inverse of [`vec3_project`](@ref) (three.js `Vector3.unproject`).
"""
vec3_unproject(ndc::Vec3, camera::AbstractCamera) =
    mat4_transform_point(mat4_inverse(view_matrix(camera)),
                         mat4_transform_point(mat4_inverse(projection_matrix(camera)), ndc))

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
    stereo_update!(stereo::StereoCamera, camera::PerspectiveCamera) -> stereo

Update the left/right eye cameras from `camera` as three.js
`StereoCamera.update` does. Each eye is `camera` shifted by ∓`eye_sep`/2 along
its world right axis, with parallel view directions, and uses an off-axis
(asymmetric) frustum that converges at `camera.focus`: the eye projections
equal three.js's with the near-plane shift `±(eye_sep/2)·near/focus`. The
shift is stored as the eyes' `film_offset` (in mm of `film_gauge`), so
[`projection_matrix`](@ref) and every renderer reproduce it. The eyes copy
`fov`, `aspect`, `near`, `far`, `zoom`, `focus` and `film_gauge`; as in
three.js, the vertical part of an enabled view offset of `camera` is kept and
its horizontal part and film offset are replaced by the stereo frustum.
"""
function stereo_update!(s::StereoCamera, cam::PerspectiveCamera)
    view = view_matrix(cam)
    camera_position, camera_target, camera_up = _camera_world_pose(cam)
    focus = _validated_camera_positive(cam.focus, :PerspectiveCamera, :focus)
    film_gauge = _validated_camera_positive(cam.film_gauge, :PerspectiveCamera,
                                            :film_gauge)
    _validated_perspective_params(cam.fov, cam.aspect, cam.near, cam.far)
    zoom = _validated_camera_zoom(cam.zoom)
    base_view = cam.view
    eye_view = if base_view isa CameraView && base_view.enabled
        _validated_camera_view(base_view, :PerspectiveCamera)
        # Keep only the vertical window: three.js replaces the horizontal
        # projection terms (elements 0 and 8) of the copied matrix.
        CameraView(true, base_view.full_width, base_view.full_height, 0.0,
                   base_view.offset_y, base_view.full_width, base_view.height)
    else
        nothing
    end
    # The first view-matrix row is the camera's normalized world-right axis.
    # Reuse the overflow-safe look-at construction instead of subtracting
    # opposite extreme eye/target coordinates here.
    right = Vec3(
        mat4_get(view, 1, 1),
        mat4_get(view, 1, 2),
        mat4_get(view, 1, 3),
    )
    half = _validated_stereo_eye_sep(s.eye_sep) / 2
    # three.js shifts the near-plane window by eyeSepOnProjection =
    # (eyeSep/2)·near/focus (src/cameras/StereoCamera.js:116-143). A film
    # offset shifts it by near·film_offset/film_width, so the equivalent film
    # offset is (eyeSep/2)·film_width/focus: positive (window to the right)
    # for the left eye.
    film_width = film_gauge * min(cam.aspect, 1.0)
    film_shift = half * film_width / focus
    isfinite(film_shift) ||
        throw(ArgumentError("StereoCamera eye_sep and focus produce an unrepresentable eye frustum"))
    for (sub, sign) in ((s.cameraL, -1.0), (s.cameraR, 1.0))
        off = right * (sign * half)
        sub.fov = cam.fov; sub.aspect = cam.aspect
        sub.near = cam.near; sub.far = cam.far; sub.zoom = zoom; sub.up = camera_up
        sub.focus = focus; sub.film_gauge = film_gauge
        sub.film_offset = -sign * film_shift
        sub.view = eye_view
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

"""
    CubeCamera(; near=0.1, far=1000.0, position=Vec3())

Six 90° perspective cameras at `position` facing +x, -x, +y, -y, +z and -z
(`cameras[1:6]`). Each face camera's `projection_matrix(c) * view_matrix(c)`
equals that of three.js `CubeCamera` in the WebGL coordinate system, whose
face cameras use `fov = -90` with up vectors (0,1,0), (0,1,0), (0,0,-1),
(0,0,1), (0,1,0), (0,1,0); Diff3D expresses the same transform with a
positive field of view and negated up vectors.

`render!` stores image rows top-down, whereas WebGL stores a render-target
face bottom-up. To use a face render as a [`CubeTexture`](@ref) face in the
three.js/WebGL cube layout sampled by `sample_cube`, reverse its rows, e.g.
`Texture(reverse(target.color; dims=1); colorspace=:linear)` (`render!`
writes linear colors).
"""
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
