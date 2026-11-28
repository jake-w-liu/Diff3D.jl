# --------------------------------------------------------------------------
# Controls, animation, and helpers (three.js examples/ counterparts), adapted
# for headless/programmatic use: camera manipulators, a Clock, keyframe
# animation, and line-based scene helpers.
# --------------------------------------------------------------------------

# ========================== Camera controls ==========================

@noinline function _throw_control_finite(label::String)
    throw(ArgumentError("$label must be finite"))
end

@inline function _checked_control_scalar(value, label::String)
    value isa Real && !(value isa Bool) || _throw_control_finite(label)
    result = Float64(value)
    isfinite(result) || _throw_control_finite(label)
    return result
end

@inline function _checked_control_vec3(value, label::String)
    value isa Vec3 || _throw_control_finite(label)
    result = convert(Vec3{Float64}, value)
    isfinite(result.x) && isfinite(result.y) && isfinite(result.z) ||
        _throw_control_finite(label)
    return result
end

# three.js MathUtils.DEG2RAD / RAD2DEG (MathUtils.js:1-2): the Float64 quotients
# of Math.PI, so degree conversions round exactly like three.js.
const _CONTROL_DEG2RAD = Float64(π) / 180.0
const _CONTROL_RAD2DEG = 180.0 / Float64(π)

const _OrbitCamera = Union{PerspectiveCamera, OrthographicCamera}

_orbit_camera_kind(::PerspectiveCamera) = :PerspectiveCamera
_orbit_camera_kind(::OrthographicCamera) = :OrthographicCamera

mutable struct OrbitControls
    camera::_OrbitCamera
    target::Vec3{Float64}
    enabled::Bool
    enable_rotate::Bool
    enable_zoom::Bool
    enable_pan::Bool
    # Damping/inertia (three.js OrbitControls.enableDamping). When enabled, each
    # interaction adds to a residual velocity that `orbit_update!` applies and
    # decays. Backward-compatible: defaults reproduce the original immediate
    # (non-damped) behaviour.
    enable_damping::Bool
    damping_factor::Float64
    min_distance::Float64
    max_distance::Float64
    min_polar_angle::Float64
    max_polar_angle::Float64
    min_azimuth_angle::Float64
    max_azimuth_angle::Float64
    # Internal residual velocity accumulated during the last interaction.
    v_azimuth::Float64       # pending azimuth delta (rad)
    v_polar::Float64         # pending polar delta (rad)
    v_zoom::Float64          # pending log-scale dolly (radius *= exp(v_zoom))
    v_pan::Vec3{Float64}     # pending world-space pan offset
    position0::Vec3{Float64}
    target0::Vec3{Float64}
    # three.js OrbitControls.screenSpacePanning: vertical pan follows the
    # camera up (true) or moves across the plane orthogonal to `camera.up`.
    screen_space_panning::Bool
    # three.js minZoom / maxZoom: an orthographic camera dollies by changing
    # `camera.zoom` within this range instead of moving.
    min_zoom::Float64
    max_zoom::Float64
    # Camera zoom saved by `orbit_save_state!` (three.js `zoom0`).
    zoom0::Float64
    # three.js autoRotate / autoRotateSpeed: `orbit_update!` turns the camera
    # about camera.up; speed 2.0 is one orbit per 30 s at 60 frames/s.
    auto_rotate::Bool
    auto_rotate_speed::Float64
    # three.js cursor / minTargetRadius / maxTargetRadius: every update keeps
    # the target within this distance range of `cursor`.
    cursor::Vec3{Float64}
    min_target_radius::Float64
    max_target_radius::Float64
    # three.js pointer, wheel and keyboard input (the `orbit_pointer_*`,
    # `orbit_wheel!` and `orbit_key_*` calls): speeds, zoomToCursor, the key,
    # mouse-button and touch mappings, and the element's client rectangle.
    zoom_speed::Float64
    rotate_speed::Float64
    key_rotate_speed::Float64
    pan_speed::Float64
    key_pan_speed::Float64
    zoom_to_cursor::Bool
    keys::NamedTuple{(:left, :up, :right, :bottom), NTuple{4, String}}
    mouse_buttons::NamedTuple{(:left, :middle, :right), NTuple{3, Symbol}}
    touches::NamedTuple{(:one, :two), NTuple{2, Symbol}}
    element_left::Float64
    element_top::Float64
    element_width::Float64
    element_height::Float64
    # MapControls drags the target over the plane through it orthogonal to
    # `camera.up` for mouse pans when `screen_space_panning` is off.
    map_panning::Bool
    # Input state (three.js state, _pointers, _pointerPositions, _rotateStart,
    # _panStart, _dollyStart, _panWorldStart, _controlActive, _scale,
    # _performCursorZoom, _mouse, _dollyDirection).
    state::Symbol
    pointers::Vector{Int}
    pointer_positions::Dict{Int, NTuple{2, Float64}}
    rotate_start::NTuple{2, Float64}
    pan_start::NTuple{2, Float64}
    dolly_start::NTuple{2, Float64}
    pan_world_start::Vec3{Float64}
    control_active::Bool
    scale::Float64
    perform_cursor_zoom::Bool
    mouse::NTuple{2, Float64}
    dolly_direction::Vec3{Float64}
end

const _ORBIT_DEFAULT_KEYS = (left="ArrowLeft", up="ArrowUp", right="ArrowRight",
                             bottom="ArrowDown")
const _ORBIT_DEFAULT_MOUSE_BUTTONS = (left=:rotate, middle=:dolly, right=:pan)
const _ORBIT_DEFAULT_TOUCHES = (one=:rotate, two=:dolly_pan)
# MapControls.js constructor.
const _MAP_DEFAULT_MOUSE_BUTTONS = (left=:pan, middle=:dolly, right=:rotate)
const _MAP_DEFAULT_TOUCHES = (one=:pan, two=:dolly_rotate)

# The field layout before the pointer, wheel and keyboard input: every input
# setting takes its three.js default.
OrbitControls(args::Vararg{Any, 29}) =
    OrbitControls(args..., 1.0, 1.0, 1.0, 1.0, 7.0, false,
                  _ORBIT_DEFAULT_KEYS, _ORBIT_DEFAULT_MOUSE_BUTTONS,
                  _ORBIT_DEFAULT_TOUCHES, 0.0, 0.0, 0.0, 0.0, false,
                  :none, Int[], Dict{Int, NTuple{2, Float64}}(),
                  (0.0, 0.0), (0.0, 0.0), (0.0, 0.0), Vec3(0.0, 0.0, 0.0),
                  false, 1.0, false, (0.0, 0.0), Vec3(0.0, 0.0, 0.0))

function _checked_orbit_target_radii(min_radius, max_radius)
    min_radius isa Real && !(min_radius isa Bool) &&
        max_radius isa Real && !(max_radius isa Bool) ||
        throw(ArgumentError("OrbitControls target radii must satisfy 0 <= min_target_radius <= max_target_radius"))
    minimum = Float64(min_radius)
    maximum = Float64(max_radius)
    isfinite(minimum) && 0.0 <= minimum <= maximum && !isnan(maximum) ||
        throw(ArgumentError("OrbitControls target radii must satisfy 0 <= min_target_radius <= max_target_radius"))
    return minimum, maximum
end

function _checked_orbit_zoom_limits(min_zoom, max_zoom)
    min_zoom isa Real && !(min_zoom isa Bool) &&
        max_zoom isa Real && !(max_zoom isa Bool) ||
        throw(ArgumentError("OrbitControls zoom limits must satisfy 0 <= min_zoom <= max_zoom"))
    minimum = Float64(min_zoom)
    maximum = Float64(max_zoom)
    isfinite(minimum) && 0.0 <= minimum <= maximum && !isnan(maximum) ||
        throw(ArgumentError("OrbitControls zoom limits must satisfy 0 <= min_zoom <= max_zoom"))
    return minimum, maximum
end

# Damping is a decay factor. Non-finite or >1 values either poison camera state
# or make residual motion grow/oscillate instead of converging.
function _checked_damping_factor(value, label::String)
    value isa Real && !(value isa Bool) ||
        throw(ArgumentError("$label must be finite and between 0 and 1"))
    f = Float64(value)
    isfinite(f) && 0.0 <= f <= 1.0 ||
        throw(ArgumentError("$label must be finite and between 0 and 1"))
    return f
end

_checked_pointer_speed(value, label::String) =
    _checked_control_scalar(value, label)

function _checked_orbit_distances(min_distance, max_distance)
    minimum = _checked_control_scalar(min_distance, "min_distance")
    minimum >= 0.0 ||
        throw(ArgumentError("min_distance must be finite and non-negative"))
    max_distance isa Real && !(max_distance isa Bool) ||
        throw(ArgumentError("max_distance must be greater than or equal to min_distance"))
    maximum = Float64(max_distance)
    ((isfinite(maximum) || maximum == Inf) && maximum >= minimum) ||
        throw(ArgumentError("max_distance must be greater than or equal to min_distance"))
    return minimum, maximum
end

@noinline function _throw_polar_limit(context::String, label::String)
    throw(ArgumentError("$context $label must be finite"))
end

function _checked_polar_limits(min_polar_angle, max_polar_angle,
                               context::String)
    min_polar_angle isa Real && !(min_polar_angle isa Bool) ||
        _throw_polar_limit(context, "min_polar_angle")
    max_polar_angle isa Real && !(max_polar_angle isa Bool) ||
        _throw_polar_limit(context, "max_polar_angle")
    minimum = Float64(min_polar_angle)
    maximum = Float64(max_polar_angle)
    isfinite(minimum) || _throw_polar_limit(context, "min_polar_angle")
    isfinite(maximum) || _throw_polar_limit(context, "max_polar_angle")
    0.0 <= minimum <= maximum <= Float64(pi) ||
        throw(ArgumentError(
            "$context polar angles must satisfy 0 <= min_polar_angle <= max_polar_angle <= pi"))
    return minimum, maximum
end

function _checked_azimuth_limits(min_azimuth_angle, max_azimuth_angle)
    min_azimuth_angle isa Real && !(min_azimuth_angle isa Bool) ||
        throw(ArgumentError("OrbitControls azimuth limits must not be NaN"))
    max_azimuth_angle isa Real && !(max_azimuth_angle isa Bool) ||
        throw(ArgumentError("OrbitControls azimuth limits must not be NaN"))
    minimum = Float64(min_azimuth_angle)
    maximum = Float64(max_azimuth_angle)
    !isnan(minimum) && !isnan(maximum) && minimum <= maximum ||
        throw(ArgumentError("OrbitControls azimuth limits must not be NaN and min_azimuth_angle must be <= max_azimuth_angle"))
    return minimum, maximum
end

function _validate_orbit_runtime(oc::OrbitControls)
    _validated_camera_view_vectors(oc.camera, _orbit_camera_kind(oc.camera))
    _checked_orbit_zoom_limits(oc.min_zoom, oc.max_zoom)
    _checked_control_scalar(oc.auto_rotate_speed,
                            "OrbitControls auto_rotate_speed")
    _checked_control_vec3(oc.cursor, "OrbitControls cursor")
    _checked_orbit_target_radii(oc.min_target_radius, oc.max_target_radius)
    _checked_control_vec3(oc.target, "OrbitControls target")
    _checked_orbit_distances(oc.min_distance, oc.max_distance)
    _checked_polar_limits(oc.min_polar_angle, oc.max_polar_angle,
                          "OrbitControls")
    _checked_azimuth_limits(oc.min_azimuth_angle, oc.max_azimuth_angle)
    _checked_damping_factor(oc.damping_factor, "damping_factor")
    _checked_control_scalar(oc.v_azimuth, "OrbitControls azimuth velocity")
    _checked_control_scalar(oc.v_polar, "OrbitControls polar velocity")
    _checked_control_scalar(oc.v_zoom, "OrbitControls zoom velocity")
    _checked_control_vec3(oc.v_pan, "OrbitControls pan velocity")
    return nothing
end

"""
    OrbitControls(camera[, target]; enabled=true, enable_rotate=true,
                  enable_zoom=true, enable_pan=true, enable_damping=false,
                  damping_factor=0.05, min_distance=0.0, max_distance=Inf,
                  min_polar_angle=0.0, max_polar_angle=π,
                  min_azimuth_angle=-Inf, max_azimuth_angle=Inf,
                  screen_space_panning=true, min_zoom=0.0, max_zoom=Inf,
                  auto_rotate=false, auto_rotate_speed=2.0,
                  cursor=Vec3(0.0, 0.0, 0.0), min_target_radius=0.0,
                  max_target_radius=Inf)

Orbit/pan/zoom camera control state matching three.js `OrbitControls` for a
`PerspectiveCamera` or an `OrthographicCamera`. The camera orbits the target
about `camera.up`. Dollying a perspective camera scales its distance to the
target; dollying an orthographic camera divides `camera.zoom` by the factor,
clamped to `[min_zoom, max_zoom]`, and leaves the camera in place (three.js
`minZoom`/`maxZoom`). With `auto_rotate=true`, `orbit_update!` also turns
the camera about `camera.up` at `auto_rotate_speed` (three.js `autoRotate`).
Every interaction and update keeps the target between `min_target_radius` and
`max_target_radius` from `cursor` (three.js `minTargetRadius`,
`maxTargetRadius`, `cursor`).

Pointer, wheel and keyboard input follow three.js r186 through
[`orbit_pointer_down!`](@ref), [`orbit_pointer_move!`](@ref),
[`orbit_pointer_up!`](@ref), [`orbit_wheel!`](@ref), [`orbit_key_down!`](@ref)
and [`orbit_key_up!`](@ref), configured by `zoom_speed`, `rotate_speed`,
`key_rotate_speed`, `pan_speed`, `key_pan_speed` (pixels per key press),
`zoom_to_cursor`, `keys` (the `KeyboardEvent.code` of each arrow),
`mouse_buttons` (`:rotate`, `:dolly`, `:pan` or `:none` for the `left`,
`middle` and `right` buttons), `touches` (`one`: `:rotate` or `:pan`; `two`:
`:dolly_pan` or `:dolly_rotate`; `:none` disables) and the element's client
rectangle `element_left`, `element_top`, `element_width`, `element_height` in
pixels, which those calls require to be positive. The extra keywords:

    zoom_speed=1.0, rotate_speed=1.0, key_rotate_speed=1.0, pan_speed=1.0,
    key_pan_speed=7.0, zoom_to_cursor=false,
    keys=(left="ArrowLeft", up="ArrowUp", right="ArrowRight", bottom="ArrowDown"),
    mouse_buttons=(left=:rotate, middle=:dolly, right=:pan),
    touches=(one=:rotate, two=:dolly_pan), element_left=0.0, element_top=0.0,
    element_width=0.0, element_height=0.0, map_panning=false

(`map_panning=true` gives mouse pans the [`MapControls`](@ref) ground-plane
drag.) [`orbit_polar_angle`](@ref), [`orbit_azimuthal_angle`](@ref) and
[`orbit_distance`](@ref) read the current orbit.
"""
function OrbitControls(cam::_OrbitCamera, target::Vec3{Float64};
                       enabled::Bool=true, enable_rotate::Bool=true,
                       enable_zoom::Bool=true, enable_pan::Bool=true,
                       enable_damping::Bool=false, damping_factor::Real=0.05,
                       min_distance::Real=0.0, max_distance::Real=Inf,
                       min_polar_angle::Real=0.0, max_polar_angle::Real=π,
                       min_azimuth_angle::Real=-Inf, max_azimuth_angle::Real=Inf,
                       screen_space_panning::Bool=true,
                       min_zoom::Real=0.0, max_zoom::Real=Inf,
                       auto_rotate::Bool=false, auto_rotate_speed::Real=2.0,
                       cursor::Vec3=Vec3(0.0, 0.0, 0.0),
                       min_target_radius::Real=0.0,
                       max_target_radius::Real=Inf,
                       zoom_speed::Real=1.0, rotate_speed::Real=1.0,
                       key_rotate_speed::Real=1.0, pan_speed::Real=1.0,
                       key_pan_speed::Real=7.0, zoom_to_cursor::Bool=false,
                       keys::NamedTuple=_ORBIT_DEFAULT_KEYS,
                       mouse_buttons::NamedTuple=_ORBIT_DEFAULT_MOUSE_BUTTONS,
                       touches::NamedTuple=_ORBIT_DEFAULT_TOUCHES,
                       element_left::Real=0.0, element_top::Real=0.0,
                       element_width::Real=0.0, element_height::Real=0.0,
                       map_panning::Bool=false)
    _prepare_camera_control_up!(cam)
    _validated_camera_view_vectors(cam, _orbit_camera_kind(cam))
    minimum_zoom, maximum_zoom = _checked_orbit_zoom_limits(min_zoom, max_zoom)
    checked_auto_rotate_speed = _checked_control_scalar(
        auto_rotate_speed, "OrbitControls auto_rotate_speed")
    checked_cursor = _checked_control_vec3(cursor, "OrbitControls cursor")
    minimum_target_radius, maximum_target_radius =
        _checked_orbit_target_radii(min_target_radius, max_target_radius)
    checked_target = _checked_control_vec3(target, "OrbitControls target")
    minimum_distance, maximum_distance =
        _checked_orbit_distances(min_distance, max_distance)
    minimum_polar, maximum_polar =
        _checked_polar_limits(min_polar_angle, max_polar_angle,
                              "OrbitControls")
    minimum_azimuth, maximum_azimuth =
        _checked_azimuth_limits(min_azimuth_angle, max_azimuth_angle)
    damping = _checked_damping_factor(damping_factor, "damping_factor")
    oc = OrbitControls(cam, checked_target, enabled, enable_rotate, enable_zoom,
                       enable_pan, enable_damping, damping,
                       minimum_distance, maximum_distance,
                       minimum_polar, maximum_polar,
                       minimum_azimuth, maximum_azimuth,
                       0.0, 0.0, 0.0, Vec3(0.0, 0.0, 0.0), cam.position,
                       checked_target, screen_space_panning,
                       minimum_zoom, maximum_zoom, cam.zoom,
                       auto_rotate, checked_auto_rotate_speed, checked_cursor,
                       minimum_target_radius, maximum_target_radius)
    oc.zoom_speed = _checked_control_scalar(zoom_speed, "OrbitControls zoom_speed")
    oc.rotate_speed = _checked_control_scalar(rotate_speed, "OrbitControls rotate_speed")
    oc.key_rotate_speed = _checked_control_scalar(
        key_rotate_speed, "OrbitControls key_rotate_speed")
    oc.pan_speed = _checked_control_scalar(pan_speed, "OrbitControls pan_speed")
    oc.key_pan_speed = _checked_control_scalar(key_pan_speed, "OrbitControls key_pan_speed")
    oc.zoom_to_cursor = zoom_to_cursor
    oc.keys = (left=String(keys.left), up=String(keys.up),
               right=String(keys.right), bottom=String(keys.bottom))
    oc.mouse_buttons = (left=Symbol(mouse_buttons.left),
                        middle=Symbol(mouse_buttons.middle),
                        right=Symbol(mouse_buttons.right))
    oc.touches = (one=Symbol(touches.one), two=Symbol(touches.two))
    oc.element_left = _checked_control_scalar(element_left, "OrbitControls element_left")
    oc.element_top = _checked_control_scalar(element_top, "OrbitControls element_top")
    oc.element_width = _checked_control_scalar(element_width, "OrbitControls element_width")
    oc.element_height = _checked_control_scalar(element_height, "OrbitControls element_height")
    oc.map_panning = map_panning
    _validate_orbit_input(oc)
    return oc
end

function OrbitControls(camera::PerspectiveCamera, target::Vec3{Float64},
                       enable_damping::Bool, damping_factor::Real,
                       min_distance::Real, max_distance::Real,
                       min_polar_angle::Real, max_polar_angle::Real,
                       min_azimuth_angle::Real, max_azimuth_angle::Real,
                       v_azimuth::Real, v_polar::Real, v_zoom::Real,
                       v_pan::Vec3{Float64}, position0::Vec3{Float64},
                       target0::Vec3{Float64})
    _validated_camera_view_vectors(camera, :PerspectiveCamera)
    checked_target = _checked_control_vec3(target, "OrbitControls target")
    minimum_distance, maximum_distance =
        _checked_orbit_distances(min_distance, max_distance)
    minimum_polar, maximum_polar =
        _checked_polar_limits(min_polar_angle, max_polar_angle,
                              "OrbitControls")
    minimum_azimuth, maximum_azimuth =
        _checked_azimuth_limits(min_azimuth_angle, max_azimuth_angle)
    damping = _checked_damping_factor(damping_factor, "damping_factor")
    OrbitControls(camera, checked_target, true, true, true, true,
                  enable_damping, damping, minimum_distance,
                  maximum_distance, minimum_polar, maximum_polar,
                  minimum_azimuth, maximum_azimuth,
                  _checked_control_scalar(v_azimuth,
                                          "OrbitControls azimuth velocity"),
                  _checked_control_scalar(v_polar,
                                          "OrbitControls polar velocity"),
                  _checked_control_scalar(v_zoom,
                                          "OrbitControls zoom velocity"),
                  _checked_control_vec3(v_pan, "OrbitControls pan velocity"),
                  _checked_control_vec3(position0,
                                        "OrbitControls saved position"),
                  _checked_control_vec3(target0,
                                        "OrbitControls saved target"),
                  true, 0.0, Inf, camera.zoom, false, 2.0,
                  Vec3(0.0, 0.0, 0.0), 0.0, Inf)
end

OrbitControls(cam::_OrbitCamera; kwargs...) =
    OrbitControls(cam, _camera_control_target(cam); kwargs...)

"""
    MapControls(camera[, target]; screen_space_panning=false,
                mouse_buttons=(left=:pan, middle=:dolly, right=:rotate),
                touches=(one=:pan, two=:dolly_rotate), kwargs...)

`OrbitControls` configured like three.js `MapControls`: vertical pan deltas
move the target across the plane orthogonal to `camera.up` (the ground for a
y-up scene) instead of along the screen's up axis, and the left mouse button
and one finger pan. A mouse pan with `screen_space_panning=false` drags the
point under the pointer across that plane (MapControls.js
`_handleMouseMovePan`). All other keywords are the `OrbitControls` ones.
"""
MapControls(cam::_OrbitCamera, target::Vec3{Float64};
            screen_space_panning::Bool=false,
            mouse_buttons::NamedTuple=_MAP_DEFAULT_MOUSE_BUTTONS,
            touches::NamedTuple=_MAP_DEFAULT_TOUCHES, kwargs...) =
    OrbitControls(cam, target; screen_space_panning=screen_space_panning,
                  mouse_buttons=mouse_buttons, touches=touches,
                  map_panning=true, kwargs...)
MapControls(cam::_OrbitCamera; kwargs...) =
    MapControls(cam, _camera_control_target(cam); kwargs...)

# three.js OrbitControls orbits about `camera.up`: it rotates the camera offset
# by `_quat = setFromUnitVectors(camera.up, +y)` into a y-up frame, works in
# spherical coordinates there, and rotates back with the inverse
# (OrbitControls.js:406-407, 703-704, 794-795). Diff3D reads `camera.up` live.
@inline function _orbit_up_quaternion(oc::OrbitControls)
    up = oc.camera.up
    # A +y up (any positive length) is the identity frame.
    iszero(up.x) && iszero(up.z) && up.y > 0.0 &&
        return Quaternion(0.0, 0.0, 0.0, 1.0)
    return quat_from_unit_vectors(up, Vec3(0.0, 1.0, 0.0))
end

# three.js Vector3.applyQuaternion. The identity (a y-up camera) returns `v`
# unchanged, so the default frame stays exact even for overflowing offsets.
@inline function _orbit_rotate_vector(q::Quaternion, v::Vec3)
    iszero(q.x) && iszero(q.y) && iszero(q.z) && return v
    tx = 2 * (q.y * v.z - q.z * v.y)
    ty = 2 * (q.z * v.x - q.x * v.z)
    tz = 2 * (q.x * v.y - q.y * v.x)
    return Vec3(v.x + q.w * tx + q.y * tz - q.z * ty,
                v.y + q.w * ty + q.z * tx - q.x * tz,
                v.z + q.w * tz + q.x * ty - q.y * tx)
end

# Current spherical (radius, polar from camera.up, azimuth) of the camera
# about the target.
_orbit_spherical(oc::OrbitControls) = cartesian_to_spherical(
    _orbit_rotate_vector(_orbit_up_quaternion(oc),
                         oc.camera.position - oc.target))

# Clamp an azimuth (read back from cartesian_to_spherical, hence in (-π, π]) to
# the configured window, matching three.js OrbitControls. The bounds are first
# normalized into (-π, π]; a window that straddles ±π (so the normalized min
# ends up above the normalized max) keeps any angle on either arc instead of
# snapping it to a boundary — without this, a back-facing range such as
# [π/2, 3π/2] is unusable because cartesian_to_spherical can never return a
# value above π. As in three.js, the window only applies when both limits are
# finite; a one-sided limit leaves the azimuth unrestricted.
@inline function _clamp_azimuth(theta, min_az, max_az)
    (isfinite(min_az) && isfinite(max_az)) || return theta
    mn = min_az < -π ? min_az + 2π : (min_az > π ? min_az - 2π : min_az)
    mx = max_az < -π ? max_az + 2π : (max_az > π ? max_az - 2π : max_az)
    if mn <= mx
        return clamp(theta, mn, mx)
    else
        return theta > (mn + mx) / 2 ? max(mn, theta) : min(mx, theta)
    end
end

function _orbit_constrained(oc::OrbitControls, s::Spherical)
    radius = clamp(s.radius, oc.min_distance, oc.max_distance)
    # three.js clamps to the polar window, then Spherical.makeSafe (EPS = 1e-6).
    phi = clamp(clamp(s.phi, oc.min_polar_angle, oc.max_polar_angle), 1e-6, π - 1e-6)
    theta = _clamp_azimuth(s.theta, oc.min_azimuth_angle, oc.max_azimuth_angle)
    return Spherical(radius, phi, theta)
end

# three.js update(): target.sub(cursor).clampLength(minTargetRadius,
# maxTargetRadius).add(cursor) (OrbitControls.js:768-771). A target already in
# range is returned unchanged; a target on the cursor has no direction and stays.
function _orbit_limited_target(oc::OrbitControls, target::Vec3{Float64})
    # The default [0, Inf) range keeps every target.
    iszero(oc.min_target_radius) && oc.max_target_radius == Inf && return target
    offset = target - oc.cursor
    distance = norm(offset)
    limited = clamp(distance, oc.min_target_radius, oc.max_target_radius)
    (limited == distance || iszero(distance)) && return target
    return _checked_control_vec3(
        oc.cursor + offset * (limited / distance), "OrbitControls target")
end

# Place the camera at the constrained spherical offset `s` from `target`
# (default: the current target), which becomes the orbit target after the
# target-radius limit.
function _orbit_apply!(oc::OrbitControls, s::Spherical,
                       target::Vec3{Float64}=oc.target)
    zoom = _orbit_limited_zoom(oc)
    target = _orbit_limited_target(oc, target)
    q = _orbit_up_quaternion(oc)
    offset = spherical_to_cartesian(_orbit_constrained(oc, s))
    position = target + _orbit_rotate_vector(
        Quaternion(-q.x, -q.y, -q.z, q.w), offset)
    position = _checked_control_vec3(
        position, "OrbitControls camera position")
    oc.target = target
    oc.camera.position = position
    oc.camera.target = target
    _sync_camera_rotation_from_view!(oc.camera)
    oc.camera isa OrthographicCamera && (oc.camera.zoom = zoom)
    return oc
end

# three.js re-applies every limit on each update(), so a pan, or an update
# after the camera started (or a limit was changed) outside the configured
# window, moves the camera back inside it (OrbitControls.js:729-786). A camera
# already inside every configured limit is left untouched, keeping such updates
# exact; this includes a camera placed exactly on the pole, which only the
# Spherical.makeSafe epsilon (1e-6 rad) would move. An orthographic zoom
# outside [min_zoom, max_zoom] is clamped as well.
function _orbit_enforce_limits!(oc::OrbitControls)
    zoom = _orbit_limited_zoom(oc)
    if _orbit_has_placement_limits(oc)
        s = _orbit_spherical(oc)
        clamp(s.radius, oc.min_distance, oc.max_distance) == s.radius &&
            clamp(s.phi, oc.min_polar_angle, oc.max_polar_angle) == s.phi &&
            _clamp_azimuth(s.theta, oc.min_azimuth_angle,
                           oc.max_azimuth_angle) == s.theta &&
            _orbit_limited_target(oc, oc.target) === oc.target ||
            _orbit_apply!(oc, s)
    end
    oc.camera isa OrthographicCamera && (oc.camera.zoom = zoom)
    return oc
end

# With the three.js default limits (distance [0, Inf), polar [0, pi], an
# unbounded azimuth and target radius) no camera is outside them: the
# spherical radius is non-negative and its polar angle lies in [0, pi].
@inline _orbit_has_placement_limits(oc::OrbitControls) =
    !iszero(oc.min_distance) || oc.max_distance != Inf ||
    !iszero(oc.min_polar_angle) || oc.max_polar_angle != Float64(π) ||
    (isfinite(oc.min_azimuth_angle) && isfinite(oc.max_azimuth_angle)) ||
    !iszero(oc.min_target_radius) || oc.max_target_radius != Inf

"""Place the camera at an absolute orbit (azimuth, polar, radius) about the target."""
function orbit_set!(oc::OrbitControls; azimuth, polar, radius)
    _validate_orbit_runtime(oc)
    checked_radius = _checked_control_scalar(radius, "OrbitControls radius")
    checked_radius >= 0.0 ||
        throw(ArgumentError("OrbitControls radius must be finite and non-negative"))
    checked_polar = _checked_control_scalar(polar, "OrbitControls polar angle")
    checked_azimuth = _checked_control_scalar(azimuth, "OrbitControls azimuth angle")
    _orbit_apply!(oc, Spherical(checked_radius, checked_polar, checked_azimuth))
end

"""Save the current camera position, zoom, and target as the reset state."""
function orbit_save_state!(oc::OrbitControls)
    _validated_camera_view_vectors(oc.camera, _orbit_camera_kind(oc.camera))
    _checked_control_vec3(oc.target, "OrbitControls target")
    oc.position0 = oc.camera.position
    oc.target0 = oc.target
    oc.zoom0 = oc.camera.zoom
    return oc
end

"""
Restore the saved orbit state (camera position, zoom, and target) and clear
any damped residual motion. Like three.js `reset()`, it then runs one update:
the limits are re-applied and, with `auto_rotate`, the camera turns by one
frame (see `orbit_update!`). A pointer gesture in progress ends, so later
updates auto-rotate again.
"""
function orbit_reset!(oc::OrbitControls)
    position = _checked_control_vec3(
        oc.position0, "OrbitControls saved position")
    target = _checked_control_vec3(oc.target0, "OrbitControls saved target")
    oc.camera.zoom = _validated_camera_zoom(oc.zoom0)
    oc.camera.position = position
    oc.target = target
    oc.camera.target = target
    _sync_camera_rotation_from_view!(oc.camera)
    oc.v_azimuth = 0.0
    oc.v_polar = 0.0
    oc.v_zoom = 0.0
    oc.v_pan = Vec3(0.0, 0.0, 0.0)
    # three.js reset() ends with update() (OrbitControls.js:621-633), which
    # applies the limits and, with auto-rotation, turns the camera one frame;
    # that update still sees the old state, and reset() then sets it to NONE.
    if oc.enabled && oc.auto_rotate
        orbit_update!(oc)
    else
        _orbit_enforce_limits!(oc)
    end
    oc.state = :none
    return oc
end

# Immediate (non-damped) primitives that always apply their deltas at once.
function _orbit_rotate_now!(oc::OrbitControls, d_azimuth, d_polar)
    s = _orbit_spherical(oc)
    _orbit_apply!(oc, Spherical(s.radius, s.phi + d_polar, s.theta + d_azimuth))
end
# three.js update() for an orthographic camera: `zoom / scale` clamped to
# [minZoom, maxZoom] (OrbitControls.js:892-895).
function _orbit_ortho_zoom(oc::OrbitControls, scale)
    zoom = clamp(oc.camera.zoom / scale, oc.min_zoom, oc.max_zoom)
    (isfinite(zoom) && zoom > 0.0) || throw(ArgumentError(
        "OrbitControls orthographic zoom must stay positive and finite"))
    return zoom
end
# Every three.js update() re-clamps an orthographic zoom (scale 1 when not
# dollying), so a zoom that starts outside [min_zoom, max_zoom], or is left
# outside by a changed limit, moves back inside it.
@inline _orbit_limited_zoom(oc::OrbitControls) =
    oc.camera isa OrthographicCamera ? _orbit_ortho_zoom(oc, 1.0) : oc.camera.zoom
function _orbit_zoom_now!(oc::OrbitControls, factor)
    camera = oc.camera
    if camera isa OrthographicCamera
        zoom = _orbit_ortho_zoom(oc, factor)
        _orbit_enforce_limits!(oc)
        camera.zoom = zoom
        return oc
    end
    s = _orbit_spherical(oc)
    _orbit_apply!(oc, Spherical(s.radius * factor, s.phi, s.theta))
end

# log(floatmax(Float64)): exp of any value in ±this range is finite and nonzero.
const _ORBIT_MAX_LOG_DOLLY = log(floatmax(Float64))

# Throw, without changing any state, when dollying by `scale` would leave the
# camera unrepresentable (the orthographic zoom or the perspective placement
# becomes non-finite or zero after the configured limits).
function _orbit_check_dolly(oc::OrbitControls, scale::Float64)
    oc.camera isa OrthographicCamera && (_orbit_ortho_zoom(oc, scale); return nothing)
    s = _orbit_constrained(oc, _orbit_spherical(oc))
    q = _orbit_up_quaternion(oc)
    offset = _orbit_rotate_vector(
        Quaternion(-q.x, -q.y, -q.z, q.w),
        spherical_to_cartesian(_orbit_constrained(
            oc, Spherical(s.radius * scale, s.phi, s.theta))))
    _checked_control_vec3(_orbit_limited_target(oc, oc.target) + offset,
                          "OrbitControls camera position")
    return nothing
end
function _camera_pan_basis(camera::AbstractCamera, target::Vec3{Float64})
    fwd = _direction_between(camera.position, target)
    raw_right = cross(fwd, camera.up)
    if norm(raw_right) <= 1e-12
        candidate = abs(fwd.x) < 0.9 ? Vec3(1.0, 0.0, 0.0) : Vec3(0.0, 1.0, 0.0)
        raw_right = candidate - fwd * dot(candidate, fwd)
    end
    right = normalize(raw_right)
    up = normalize(cross(right, fwd))
    return right, up
end
function _orbit_pan_basis(oc::OrbitControls)
    right, up = _camera_pan_basis(oc.camera, oc.target)
    oc.screen_space_panning && return right, up
    return right, normalize(cross(oc.camera.up, right))
end
# Move the target and camera together by a world-space offset, then apply the
# limits as three.js update() does after `target.add(panOffset)`.
function _orbit_shift!(oc::OrbitControls, shift::Vec3)
    target = _checked_control_vec3(
        oc.target + shift, "OrbitControls target")
    position = _checked_control_vec3(
        oc.camera.position + shift, "OrbitControls camera position")
    oc.target = target
    oc.camera.position = position
    oc.camera.target = target
    _sync_camera_rotation_from_view!(oc.camera)
    return _orbit_enforce_limits!(oc)
end
function _orbit_pan_now!(oc::OrbitControls, dx, dy)
    right, up = _orbit_pan_basis(oc)
    return _orbit_shift!(oc, right * dx + up * dy)
end

"""
Rotate the camera around the target by angular deltas (radians).

With `enable_damping=false` (default) the rotation is applied immediately, exactly
as before. With damping enabled the deltas are added to the residual angular
velocity instead, to be consumed by `orbit_update!`.
"""
function orbit_rotate!(oc::OrbitControls, d_azimuth, d_polar)
    (oc.enabled && oc.enable_rotate) || return oc
    _validate_orbit_runtime(oc)
    azimuth_delta = _checked_control_scalar(
        d_azimuth, "OrbitControls azimuth delta")
    polar_delta = _checked_control_scalar(
        d_polar, "OrbitControls polar delta")
    if oc.enable_damping
        new_azimuth_velocity = _checked_control_scalar(
            oc.v_azimuth + azimuth_delta,
            "OrbitControls azimuth velocity")
        new_polar_velocity = _checked_control_scalar(
            oc.v_polar + polar_delta,
            "OrbitControls polar velocity")
        oc.v_azimuth = new_azimuth_velocity
        oc.v_polar = new_polar_velocity
        return oc
    end
    return _orbit_rotate_now!(oc, azimuth_delta, polar_delta)
end

"""
Scale the orbit radius (dolly). `factor < 1` zooms in.

With damping enabled the dolly accumulates as a residual log-scale velocity
consumed by `orbit_update!`; non-damped behaviour is unchanged.
"""
function orbit_zoom!(oc::OrbitControls, factor)
    (oc.enabled && oc.enable_zoom) || return oc
    _validate_orbit_runtime(oc)
    f = _checked_control_scalar(factor, "OrbitControls zoom factor")
    if oc.enable_damping
        # A multiplicative dolly factor must be positive; log() of a non-positive
        # factor would poison the residual with -Inf/NaN (sticking the controller
        # forever) or throw DomainError. Apply such an out-of-contract factor
        # immediately via the non-damped path, which clamps the resulting radius
        # into [min_distance, max_distance] — the same graceful handling the rest
        # of the controller uses.
        f > 0 || return _orbit_zoom_now!(oc, f)
        # The residual saturates at the largest representable factor, so
        # exp() of it, or of any damped share of it, stays finite and nonzero.
        zoom_velocity = clamp(oc.v_zoom + log(f),
                              -_ORBIT_MAX_LOG_DOLLY, _ORBIT_MAX_LOG_DOLLY)
        # orbit_update! applies at most the whole residual, so a residual whose
        # complete dolly already leaves the representable range is rejected
        # here, as the immediate path rejects that factor, instead of being
        # queued and making every later update throw.
        _orbit_check_dolly(oc, exp(zoom_velocity))
        oc.v_zoom = zoom_velocity
        return oc
    end
    return _orbit_zoom_now!(oc, f)
end

"""
Pan the target (and camera) in the camera's right/up plane.

With damping enabled the pan offset accumulates as a residual world-space
velocity consumed by `orbit_update!`; non-damped behaviour is unchanged.
"""
function orbit_pan!(oc::OrbitControls, dx, dy)
    (oc.enabled && oc.enable_pan) || return oc
    _validate_orbit_runtime(oc)
    checked_dx = _checked_control_scalar(dx, "OrbitControls pan x delta")
    checked_dy = _checked_control_scalar(dy, "OrbitControls pan y delta")
    if oc.enable_damping
        right, up = _orbit_pan_basis(oc)
        pan = oc.v_pan + right * checked_dx + up * checked_dy
        oc.v_pan = _checked_control_vec3(
            pan, "OrbitControls pan velocity")
        return oc
    end
    return _orbit_pan_now!(oc, checked_dx, checked_dy)
end

"""
    orbit_update!(oc[, delta_time])

Advance the orbit by one frame. Like three.js `OrbitControls.update`, every
call re-applies the distance, polar, azimuth, and target-radius limits (and
`min_zoom`/`max_zoom` for an orthographic camera), so a camera that starts (or
is left by a changed limit) outside them moves back inside; a camera already
inside them is not moved. With damping disabled nothing else happens
(interactions apply immediately). With damping enabled it applies
`damping_factor` of the residual rotation, dolly, and pan velocities, then
decays them by `(1 - damping_factor)` so motion eases to a stop after the last
interaction and the total converges to the queued deltas. Velocity components
below a small threshold are zeroed to avoid endless drift.

With `oc.auto_rotate` set, each call first turns the camera about `camera.up`
by `2π/60 * auto_rotate_speed * delta_time` radians, or by
`2π/3600 * auto_rotate_speed` when `delta_time` (seconds) is omitted, as
three.js does per frame (`_getAutoRotationAngle`); with damping enabled that
turn is added to the residual azimuth velocity instead. As in three.js there
is no auto-rotation while a pointer gesture started by
[`orbit_pointer_down!`](@ref) is in progress.
"""
function orbit_update!(oc::OrbitControls, delta_time=nothing)
    oc.enabled || return oc
    _validate_orbit_runtime(oc)
    # A frame delta must be a finite real even when auto-rotation is off.
    delta_time === nothing ||
        _checked_control_scalar(delta_time, "OrbitControls delta_time")
    # three.js update() auto-rotates only while no pointer gesture is active.
    if oc.auto_rotate && oc.state === :none
        # three.js _rotateLeft(angle): sphericalDelta.theta -= angle.
        angle = _orbit_auto_rotation_angle(oc, delta_time)
        if !oc.enable_damping
            s = _orbit_spherical(oc)
            return _orbit_apply!(oc, Spherical(s.radius, s.phi, s.theta - angle))
        end
        oc.v_azimuth = _checked_control_scalar(
            oc.v_azimuth - angle, "OrbitControls azimuth velocity")
    end
    oc.enable_damping || return _orbit_enforce_limits!(oc)
    f = oc.damping_factor
    decay = 1.0 - f
    if oc.v_azimuth != 0.0 || oc.v_polar != 0.0 || oc.v_zoom != 0.0
        # Apply `damping_factor` of the residual velocities in one pass, like
        # three.js update() (OrbitControls.js:706-797): the spherical offset
        # about the current target plus the damped deltas is limited once, the
        # target moves by the damped share of the world-space pan, and the
        # camera is placed at the limited offset from the moved target.
        s = _orbit_spherical(oc)
        scale = exp(oc.v_zoom * f)
        camera = oc.camera
        ortho = camera isa OrthographicCamera
        zoom = ortho ? _orbit_ortho_zoom(oc, scale) : camera.zoom
        stepped = Spherical(ortho ? s.radius : s.radius * scale,
                            s.phi + oc.v_polar * f,
                            s.theta + oc.v_azimuth * f)
        target = _checked_control_vec3(
            oc.target + oc.v_pan * f, "OrbitControls target")
        _orbit_apply!(oc, stepped, target)
        ortho && (camera.zoom = zoom)
    elseif oc.v_pan.x != 0.0 || oc.v_pan.y != 0.0 || oc.v_pan.z != 0.0
        # A pure pan keeps the offset, so limiting before or after the move is
        # the same; this path leaves an in-limit offset bit-for-bit unchanged.
        _orbit_shift!(oc, oc.v_pan * f)
    else
        _orbit_enforce_limits!(oc)
    end
    # Decay residual velocities; snap tiny remnants to zero.
    thresh = 1e-9
    oc.v_azimuth = abs(oc.v_azimuth * decay) < thresh ? 0.0 : oc.v_azimuth * decay
    oc.v_polar   = abs(oc.v_polar   * decay) < thresh ? 0.0 : oc.v_polar   * decay
    oc.v_zoom    = abs(oc.v_zoom    * decay) < thresh ? 0.0 : oc.v_zoom    * decay
    pan = oc.v_pan * decay
    oc.v_pan = (abs(pan.x) < thresh && abs(pan.y) < thresh && abs(pan.z) < thresh) ?
        Vec3(0.0, 0.0, 0.0) : pan
    return oc
end

# OrbitControls.js _getAutoRotationAngle.
function _orbit_auto_rotation_angle(oc::OrbitControls, delta_time)
    speed = oc.auto_rotate_speed
    delta_time === nothing && return 2π / 60 / 60 * speed
    dt = _checked_control_scalar(delta_time, "OrbitControls delta_time")
    return _checked_control_scalar((2π / 60 * speed) * dt,
                                   "OrbitControls auto-rotation angle")
end

# ---- OrbitControls pointer, wheel and keyboard input (three.js r186) -------

const _ORBIT_MOUSE_ACTIONS = (:rotate, :dolly, :pan, :none)
const _ORBIT_TOUCH_ACTIONS = (:rotate, :pan, :dolly_pan, :dolly_rotate, :none)
# OrbitControls.js _TILT_LIMIT.
const _ORBIT_TILT_LIMIT = cos(70 * _CONTROL_DEG2RAD)

function _validate_orbit_input(oc::OrbitControls)
    _checked_control_scalar(oc.zoom_speed, "OrbitControls zoom_speed")
    _checked_control_scalar(oc.rotate_speed, "OrbitControls rotate_speed")
    _checked_control_scalar(oc.key_rotate_speed, "OrbitControls key_rotate_speed")
    _checked_control_scalar(oc.pan_speed, "OrbitControls pan_speed")
    _checked_control_scalar(oc.key_pan_speed, "OrbitControls key_pan_speed")
    _checked_control_scalar(oc.element_left, "OrbitControls element_left")
    _checked_control_scalar(oc.element_top, "OrbitControls element_top")
    _checked_control_scalar(oc.element_width, "OrbitControls element_width")
    _checked_control_scalar(oc.element_height, "OrbitControls element_height")
    for action in oc.mouse_buttons
        action in _ORBIT_MOUSE_ACTIONS || throw(ArgumentError(
            "OrbitControls mouse_buttons actions must be :rotate, :dolly, :pan or :none"))
    end
    for action in oc.touches
        action in _ORBIT_TOUCH_ACTIONS || throw(ArgumentError(
            "OrbitControls touches actions must be :rotate, :pan, :dolly_pan, :dolly_rotate or :none"))
    end
    return nothing
end

@noinline _throw_orbit_element() = throw(ArgumentError(
    "OrbitControls pointer and key input needs a positive element_width and element_height"))

@inline function _orbit_client_size(oc::OrbitControls)
    (oc.element_width > 0.0 && oc.element_height > 0.0) || _throw_orbit_element()
    return oc.element_width, oc.element_height
end

"""
    orbit_polar_angle(controls::OrbitControls)

The camera's polar angle from `camera.up` about the target, in radians
(three.js `getPolarAngle`).
"""
function orbit_polar_angle(oc::OrbitControls)
    _validate_orbit_runtime(oc)
    return _orbit_spherical(oc).phi
end

"""
    orbit_azimuthal_angle(controls::OrbitControls)

The camera's azimuth about `camera.up` around the target, in radians in
`(-π, π]` (three.js `getAzimuthalAngle`; three.js returns the angle from its
last update, which can lie outside that range after a rotation).
"""
function orbit_azimuthal_angle(oc::OrbitControls)
    _validate_orbit_runtime(oc)
    return _orbit_spherical(oc).theta
end

"""
    orbit_distance(controls::OrbitControls)

Distance from the camera to the orbit target (three.js `getDistance`).
"""
function orbit_distance(oc::OrbitControls)
    _validate_orbit_runtime(oc)
    return norm(oc.camera.position - oc.target)
end

# OrbitControls.js _getZoomScale, _dollyIn, _dollyOut, _rotateLeft, _rotateUp.
_orbit_zoom_scale(oc::OrbitControls, delta) =
    0.95 ^ (oc.zoom_speed * abs(delta * 0.01))
_orbit_dolly_in!(oc::OrbitControls, s) = (oc.scale *= s; oc)
_orbit_dolly_out!(oc::OrbitControls, s) = (oc.scale /= s; oc)
_orbit_rotate_left!(oc::OrbitControls, angle) = (oc.v_azimuth -= angle; oc)
_orbit_rotate_up!(oc::OrbitControls, angle) = (oc.v_polar -= angle; oc)

# OrbitControls.js _pan: deltas in pixels (right and down positive) become a
# world-space pan offset along the camera's x axis and its y axis (or the
# ground direction `up × x` without screen-space panning).
function _orbit_pan_pixels!(oc::OrbitControls, dx, dy)
    cam = oc.camera
    q = _camera_local_quaternion(cam)
    x_axis = quat_rotate_vector(q, Vec3(1.0, 0.0, 0.0))
    if cam isa PerspectiveCamera
        _, height = _orbit_client_size(oc)
        # Half of the fov is centre to top of screen.
        distance = norm(cam.position - oc.target) * tan(cam.fov / 2)
        left = 2 * dx * distance / height
        up = 2 * dy * distance / height
    else
        width, height = _orbit_client_size(oc)
        left = dx * (cam.right - cam.left) / cam.zoom / width
        up = dy * (cam.top - cam.bottom) / cam.zoom / height
    end
    up_axis = oc.screen_space_panning ?
        quat_rotate_vector(q, Vec3(0.0, 1.0, 0.0)) : cross(cam.up, x_axis)
    pan = oc.v_pan + x_axis * (-left)
    oc.v_pan = _checked_control_vec3(pan + up_axis * up, "OrbitControls pan velocity")
    return oc
end

# OrbitControls.js _updateZoomParameters: pointer position in NDC and the
# direction from the camera through it (used by zoom_to_cursor).
function _orbit_update_zoom_parameters!(oc::OrbitControls, x, y)
    oc.zoom_to_cursor || return oc
    width, height = _orbit_client_size(oc)
    mx = ((x - oc.element_left) / width) * 2 - 1
    my = -((y - oc.element_top) / height) * 2 + 1
    cam = oc.camera
    point = vec3_unproject(Vec3(mx, my, 1.0), cam)
    direction = normalize(point - cam.position)
    oc.perform_cursor_zoom = true
    oc.mouse = (mx, my)
    oc.dolly_direction = _checked_control_vec3(
        direction, "OrbitControls zoom-to-cursor direction")
    return oc
end

# Ray.intersectPlane for the plane through `point` with normal `normal`
# (Plane.setFromNormalAndCoplanarPoint); `nothing` when the ray misses.
function _orbit_ray_plane(origin::Vec3, direction::Vec3, normal::Vec3, point::Vec3)
    constant = -dot(point, normal)
    denominator = dot(normal, direction)
    if denominator == 0
        return dot(normal, origin) + constant == 0 ? origin : nothing
    end
    t = -(dot(origin, normal) + constant) / denominator
    return t >= 0 ? direction * t + origin : nothing
end

# Mouse NDC within the element rectangle (MapControls.js _handleMouseDownPan).
function _orbit_pointer_ndc(oc::OrbitControls, x, y)
    width, height = _orbit_client_size(oc)
    return ((x - oc.element_left) / width) * 2 - 1,
           -((y - oc.element_top) / height) * 2 + 1
end

@inline _orbit_clamp_distance(oc::OrbitControls, d) =
    max(oc.min_distance, min(oc.max_distance, d))

# One three.js OrbitControls.update() (OrbitControls.js:420-574) for the input
# handlers: the residual rotation and pan (`v_azimuth`, `v_polar`, `v_pan`,
# applied in full or by `damping_factor`), the pending dolly `scale`, and
# zoom_to_cursor. Everything is computed and checked before the camera
# changes.
function _orbit_event_update!(oc::OrbitControls)
    _validate_orbit_runtime(oc)
    cam = oc.camera
    ortho = cam isa OrthographicCamera
    damping = oc.enable_damping
    f = oc.damping_factor
    q = _orbit_up_quaternion(oc)
    s = cartesian_to_spherical(_orbit_rotate_vector(q, cam.position - oc.target))
    v_azimuth = oc.v_azimuth
    if oc.auto_rotate && oc.state === :none
        v_azimuth -= _orbit_auto_rotation_angle(oc, nothing)
    end
    theta = s.theta + (damping ? v_azimuth * f : v_azimuth)
    phi = s.phi + (damping ? oc.v_polar * f : oc.v_polar)
    theta = _clamp_azimuth(theta, oc.min_azimuth_angle, oc.max_azimuth_angle)
    phi = max(oc.min_polar_angle, min(oc.max_polar_angle, phi))
    phi = max(1e-6, min(π - 1e-6, phi))                    # Spherical.makeSafe
    target = oc.target + (damping ? oc.v_pan * f : oc.v_pan)
    target = _orbit_limited_target(oc, _checked_control_vec3(target, "OrbitControls target"))
    scale = oc.scale
    cursor_zoom = oc.zoom_to_cursor && oc.perform_cursor_zoom
    radius = (cursor_zoom || ortho) ? _orbit_clamp_distance(oc, s.radius) :
        _orbit_clamp_distance(oc, s.radius * scale)
    offset = _orbit_rotate_vector(Quaternion(-q.x, -q.y, -q.z, q.w),
                                  spherical_to_cartesian(Spherical(radius, phi, theta)))
    position = _checked_control_vec3(target + offset, "OrbitControls camera position")
    zoom = cam.zoom
    camera_target = target
    if cursor_zoom
        new_radius = norm(offset)
        if ortho
            # The pointer's world point before and after the zoom, both from
            # the camera's pose before this update (three.js unprojects with
            # the not yet refreshed matrixWorld).
            zoom = _validated_camera_zoom(
                max(oc.min_zoom, min(oc.max_zoom, cam.zoom / scale)))
            ndc = Vec3(oc.mouse[1], oc.mouse[2], 0.0)
            before = vec3_unproject(ndc, cam)
            previous_zoom = cam.zoom
            cam.zoom = zoom
            after = try
                vec3_unproject(ndc, cam)
            finally
                cam.zoom = previous_zoom
            end
            position = _checked_control_vec3(position - after + before,
                                              "OrbitControls camera position")
        else
            previous = new_radius
            new_radius = _orbit_clamp_distance(oc, previous * scale)
            position = _checked_control_vec3(
                position + oc.dolly_direction * (previous - new_radius),
                "OrbitControls camera position")
        end
        # The camera keeps the orientation it took looking at the target.
        view = mat4_look_at(target + offset, target, cam.up)
        forward = Vec3(-mat4_get(view, 3, 1), -mat4_get(view, 3, 2),
                       -mat4_get(view, 3, 3))
        if oc.screen_space_panning
            target = forward * new_radius + position
            camera_target = position + forward * (new_radius > 0 ? new_radius : 1.0)
        elseif abs(dot(cam.up, forward)) < _ORBIT_TILT_LIMIT
            camera_target = target                       # object.lookAt(target)
        else
            hit = _orbit_ray_plane(position, forward, cam.up, target)
            hit === nothing || (target = hit)
            reach = dot(target - position, forward)
            camera_target = position + forward * (reach > 0 ? reach : 1.0)
        end
        target = _checked_control_vec3(target, "OrbitControls target")
        camera_target = _checked_control_vec3(camera_target, "OrbitControls camera target")
    elseif ortho
        zoom = _validated_camera_zoom(max(oc.min_zoom, min(oc.max_zoom, cam.zoom / scale)))
    end
    decay = 1.0 - f
    oc.v_azimuth = damping ? v_azimuth * decay : 0.0
    oc.v_polar = damping ? oc.v_polar * decay : 0.0
    oc.v_pan = damping ? oc.v_pan * decay : Vec3(0.0, 0.0, 0.0)
    oc.scale = 1.0
    oc.perform_cursor_zoom = false
    oc.target = target
    cam.position = position
    cam.target = camera_target
    cam.zoom = zoom
    _sync_camera_rotation_from_view!(cam)
    return oc
end

function _orbit_second_pointer(oc::OrbitControls, pointer_id::Int)
    other = pointer_id == oc.pointers[1] ? oc.pointers[2] : oc.pointers[1]
    return oc.pointer_positions[other]
end

# The touch point of a gesture: the pointer itself, or with two pointers the
# midpoint with the other one.
function _orbit_touch_point(oc::OrbitControls, pointer_id::Int, x, y)
    length(oc.pointers) == 1 && return (x, y)
    px, py = _orbit_second_pointer(oc, pointer_id)
    return (0.5 * (x + px), 0.5 * (y + py))
end

function _orbit_touch_distance(oc::OrbitControls, pointer_id::Int, x, y)
    px, py = _orbit_second_pointer(oc, pointer_id)
    dx = x - px
    dy = y - py
    return sqrt(dx * dx + dy * dy)
end

function _orbit_mouse_down_pan!(oc::OrbitControls, x, y)
    oc.pan_start = (x, y)
    oc.map_panning || return oc
    # MapControls.js _handleMouseDownPan.
    oc.v_pan = Vec3(0.0, 0.0, 0.0)
    oc.screen_space_panning && return oc
    mx, my = _orbit_pointer_ndc(oc, x, y)
    ray = _camera_ray(oc.camera, mx, my)
    hit = _orbit_ray_plane(ray.origin, ray.direction, oc.camera.up, oc.target)
    hit === nothing || (oc.pan_world_start = hit)
    return oc
end

function _orbit_touch_start!(oc::OrbitControls, pointer_id::Int, x, y)
    oc.pointer_positions[pointer_id] = (x, y)
    n = length(oc.pointers)
    if n == 1
        action = oc.touches.one
        if action === :rotate
            oc.enable_rotate || return oc
            oc.rotate_start = _orbit_touch_point(oc, pointer_id, x, y)
            oc.state = :touch_rotate
        elseif action === :pan
            oc.enable_pan || return oc
            oc.pan_start = _orbit_touch_point(oc, pointer_id, x, y)
            oc.state = :touch_pan
        else
            oc.state = :none
        end
    elseif n == 2
        action = oc.touches.two
        if action === :dolly_pan
            (oc.enable_zoom || oc.enable_pan) || return oc
            oc.enable_zoom && (oc.dolly_start = (0.0, _orbit_touch_distance(oc, pointer_id, x, y)))
            oc.enable_pan && (oc.pan_start = _orbit_touch_point(oc, pointer_id, x, y))
            oc.state = :touch_dolly_pan
        elseif action === :dolly_rotate
            (oc.enable_zoom || oc.enable_rotate) || return oc
            oc.enable_zoom && (oc.dolly_start = (0.0, _orbit_touch_distance(oc, pointer_id, x, y)))
            oc.enable_rotate && (oc.rotate_start = _orbit_touch_point(oc, pointer_id, x, y))
            oc.state = :touch_dolly_rotate
        else
            oc.state = :none
        end
    else
        oc.state = :none
    end
    return oc
end

function _orbit_mouse_down!(oc::OrbitControls, x, y, button::Integer, modifier::Bool)
    action = button == 0 ? oc.mouse_buttons.left :
             button == 1 ? oc.mouse_buttons.middle :
             button == 2 ? oc.mouse_buttons.right : :none
    if action === :dolly
        oc.enable_zoom || return oc
        # OrbitControls.js _handleMouseDownDolly passes clientX for both
        # coordinates; kept for parity with three.js r186.
        _orbit_update_zoom_parameters!(oc, x, x)
        oc.dolly_start = (x, y)
        oc.state = :dolly
    elseif (action === :rotate && !modifier) || (action === :pan && modifier)
        oc.enable_rotate || return oc
        oc.rotate_start = (x, y)
        oc.state = :rotate
    elseif action === :rotate || action === :pan
        oc.enable_pan || return oc
        _orbit_mouse_down_pan!(oc, x, y)
        oc.state = :pan
    else
        oc.state = :none
    end
    return oc
end

function _orbit_apply_rotate_delta!(oc::OrbitControls, start, finish)
    _, height = _orbit_client_size(oc)
    dx = (finish[1] - start[1]) * oc.rotate_speed
    dy = (finish[2] - start[2]) * oc.rotate_speed
    _orbit_rotate_left!(oc, 2π * dx / height)        # yes, height (three.js)
    _orbit_rotate_up!(oc, 2π * dy / height)
    oc.rotate_start = finish
    return oc
end

function _orbit_apply_pan_delta!(oc::OrbitControls, start, finish)
    _orbit_pan_pixels!(oc, (finish[1] - start[1]) * oc.pan_speed,
                       (finish[2] - start[2]) * oc.pan_speed)
    oc.pan_start = finish
    return oc
end

function _orbit_mouse_move!(oc::OrbitControls, x, y)
    state = oc.state
    if state === :rotate
        oc.enable_rotate || return oc
        _orbit_apply_rotate_delta!(oc, oc.rotate_start, (x, y))
    elseif state === :dolly
        oc.enable_zoom || return oc
        dy = y - oc.dolly_start[2]
        if dy > 0
            _orbit_dolly_out!(oc, _orbit_zoom_scale(oc, dy))
        elseif dy < 0
            _orbit_dolly_in!(oc, _orbit_zoom_scale(oc, dy))
        end
        oc.dolly_start = (x, y)
    elseif state === :pan
        oc.enable_pan || return oc
        if oc.map_panning && !oc.screen_space_panning
            # MapControls.js _handleMouseMovePan: drag the grabbed ground point.
            mx, my = _orbit_pointer_ndc(oc, x, y)
            ray = _camera_ray(oc.camera, mx, my)
            hit = _orbit_ray_plane(ray.origin, ray.direction, oc.camera.up, oc.target)
            hit === nothing && return oc
            oc.v_pan = _checked_control_vec3(-(hit - oc.pan_world_start),
                                             "OrbitControls pan velocity")
        else
            _orbit_apply_pan_delta!(oc, oc.pan_start, (x, y))
        end
    else
        return oc
    end
    return _orbit_event_update!(oc)
end

function _orbit_touch_move_dolly!(oc::OrbitControls, pointer_id::Int, x, y)
    px, py = _orbit_second_pointer(oc, pointer_id)
    distance = _orbit_touch_distance(oc, pointer_id, x, y)
    _orbit_dolly_out!(oc, (distance / oc.dolly_start[2])^oc.zoom_speed)
    oc.dolly_start = (0.0, distance)
    _orbit_update_zoom_parameters!(oc, (x + px) * 0.5, (y + py) * 0.5)
    return oc
end

function _orbit_touch_move!(oc::OrbitControls, pointer_id::Int, x, y)
    oc.pointer_positions[pointer_id] = (x, y)
    state = oc.state
    if state === :touch_rotate
        oc.enable_rotate || return oc
        _orbit_apply_rotate_delta!(oc, oc.rotate_start,
                                   _orbit_touch_point(oc, pointer_id, x, y))
    elseif state === :touch_pan
        oc.enable_pan || return oc
        _orbit_apply_pan_delta!(oc, oc.pan_start,
                                _orbit_touch_point(oc, pointer_id, x, y))
    elseif state === :touch_dolly_pan
        (oc.enable_zoom || oc.enable_pan) || return oc
        oc.enable_zoom && _orbit_touch_move_dolly!(oc, pointer_id, x, y)
        oc.enable_pan && _orbit_apply_pan_delta!(
            oc, oc.pan_start, _orbit_touch_point(oc, pointer_id, x, y))
    elseif state === :touch_dolly_rotate
        (oc.enable_zoom || oc.enable_rotate) || return oc
        oc.enable_zoom && _orbit_touch_move_dolly!(oc, pointer_id, x, y)
        oc.enable_rotate && _orbit_apply_rotate_delta!(
            oc, oc.rotate_start, _orbit_touch_point(oc, pointer_id, x, y))
    else
        oc.state = :none
        return oc
    end
    return _orbit_event_update!(oc)
end

"""
    orbit_pointer_down!(controls::OrbitControls, x, y; button=0,
                        pointer_type=:mouse, pointer_id=1, ctrl_key=false,
                        meta_key=false, shift_key=false)

A pointer goes down at client position `(x, y)` pixels (three.js
`pointerdown`). A mouse button starts the gesture `mouse_buttons` assigns to
it (`left`: button 0, `middle`: 1, `right`: 2); with Ctrl, Meta or Shift held
a rotate button pans and a pan button rotates. With `pointer_type=:touch`,
the first and second touches start the `touches.one` and `touches.two`
gestures. Ignored while disabled.
"""
function orbit_pointer_down!(oc::OrbitControls, x, y; button::Integer=0,
                             pointer_type::Symbol=:mouse, pointer_id::Integer=1,
                             ctrl_key::Bool=false, meta_key::Bool=false,
                             shift_key::Bool=false)
    px = _checked_control_scalar(x, "OrbitControls pointer x")
    py = _checked_control_scalar(y, "OrbitControls pointer y")
    touch = _checked_pointer_type(pointer_type) === :touch
    oc.enabled || return oc
    _validate_orbit_input(oc)
    id = Int(pointer_id)
    id in oc.pointers && return oc
    push!(oc.pointers, id)
    touch && return _orbit_touch_start!(oc, id, px, py)
    return _orbit_mouse_down!(oc, px, py, button, ctrl_key || meta_key || shift_key)
end

"""
    orbit_pointer_move!(controls::OrbitControls, x, y; pointer_type=:mouse,
                        pointer_id=1)

A pointer moves to client position `(x, y)` pixels (three.js
`pointermove`), continuing the active gesture: rotating by `2π * rotate_speed`
per element height, dollying by `0.95^(zoom_speed * |Δy| / 100)` (a pinch by
the ratio of the touch distances), or panning by `pan_speed` (a full element
height moves the target by the visible height at its distance). Each move
runs one update. Ignored while disabled.
"""
function orbit_pointer_move!(oc::OrbitControls, x, y; pointer_type::Symbol=:mouse,
                             pointer_id::Integer=1)
    px = _checked_control_scalar(x, "OrbitControls pointer x")
    py = _checked_control_scalar(y, "OrbitControls pointer y")
    touch = _checked_pointer_type(pointer_type) === :touch
    oc.enabled || return oc
    _validate_orbit_input(oc)
    touch && return _orbit_touch_move!(oc, Int(pointer_id), px, py)
    return _orbit_mouse_move!(oc, px, py)
end

"""
    orbit_pointer_up!(controls::OrbitControls; pointer_id=1)

A pointer is released or cancelled (three.js `pointerup`/`pointercancel`).
The gesture ends when no pointer is left; with one touch left, that touch
restarts the one-finger gesture.
"""
function orbit_pointer_up!(oc::OrbitControls; pointer_id::Integer=1)
    id = Int(pointer_id)
    delete!(oc.pointer_positions, id)
    index = findfirst(==(id), oc.pointers)
    index === nothing || deleteat!(oc.pointers, index)
    if isempty(oc.pointers)
        oc.state = :none
    elseif length(oc.pointers) == 1
        remaining = oc.pointers[1]
        position = get(oc.pointer_positions, remaining, nothing)
        if position === nothing
            oc.state = :none
        else
            _orbit_touch_start!(oc, remaining, position[1], position[2])
        end
    end
    return oc
end

"""
    orbit_wheel!(controls::OrbitControls, delta_y; x=0, y=0, delta_mode=0,
                 ctrl_key=false)

A wheel step of `delta_y` (three.js `wheel`): negative values dolly in and
positive values out by `0.95^(zoom_speed * |delta_y| / 100)`. `delta_mode` 1
(lines) and 2 (pages) scale the step by 16 and 100; `ctrl_key` without a held
Control key (a trackpad pinch) by 10. `(x, y)` is the pointer's client
position, used by `zoom_to_cursor`. Ignored while disabled, while zoom is
disabled or during a pointer gesture.
"""
function orbit_wheel!(oc::OrbitControls, delta_y; x=0.0, y=0.0,
                      delta_mode::Integer=0, ctrl_key::Bool=false)
    dy = _checked_control_scalar(delta_y, "OrbitControls wheel delta")
    px = _checked_control_scalar(x, "OrbitControls pointer x")
    py = _checked_control_scalar(y, "OrbitControls pointer y")
    (oc.enabled && oc.enable_zoom && oc.state === :none) || return oc
    _validate_orbit_input(oc)
    delta_mode == 1 && (dy *= 16)
    delta_mode == 2 && (dy *= 100)
    (ctrl_key && !oc.control_active) && (dy *= 10)
    _orbit_update_zoom_parameters!(oc, px, py)
    if dy < 0
        _orbit_dolly_in!(oc, _orbit_zoom_scale(oc, dy))
    elseif dy > 0
        _orbit_dolly_out!(oc, _orbit_zoom_scale(oc, dy))
    end
    return _orbit_event_update!(oc)
end

"""
    orbit_key_down!(controls::OrbitControls, code::AbstractString;
                    ctrl_key=false, meta_key=false, shift_key=false)

A key press given by its `KeyboardEvent.code` (three.js
`listenToKeyEvents` handling): the `keys` arrows pan by `key_pan_speed`
pixels, or with Ctrl, Meta or Shift held rotate by `2π * key_rotate_speed`
per element height, followed by one update. `"ControlLeft"`/`"ControlRight"`
mark the Control key as held, which [`orbit_wheel!`](@ref) uses to tell a
pinch from a Ctrl+wheel. Arrows are ignored while disabled.
"""
function orbit_key_down!(oc::OrbitControls, code::AbstractString; ctrl_key::Bool=false,
                         meta_key::Bool=false, shift_key::Bool=false)
    (code == "ControlLeft" || code == "ControlRight") && (oc.control_active = true)
    oc.enabled || return oc
    _validate_orbit_input(oc)
    modifier = ctrl_key || meta_key || shift_key
    keys = oc.keys
    sign_rotate = code == keys.up || code == keys.left ? 1.0 :
                  code == keys.bottom || code == keys.right ? -1.0 : 0.0
    sign_rotate == 0.0 && return oc
    vertical = code == keys.up || code == keys.bottom
    if modifier
        if oc.enable_rotate
            _, height = _orbit_client_size(oc)
            angle = sign_rotate * 2π * oc.key_rotate_speed / height
            vertical ? _orbit_rotate_up!(oc, angle) : _orbit_rotate_left!(oc, angle)
        end
    elseif oc.enable_pan
        amount = sign_rotate * oc.key_pan_speed
        vertical ? _orbit_pan_pixels!(oc, 0.0, amount) : _orbit_pan_pixels!(oc, amount, 0.0)
    end
    return _orbit_event_update!(oc)
end

"""
    orbit_key_up!(controls::OrbitControls, code::AbstractString)

A key release; `"ControlLeft"`/`"ControlRight"` mark the Control key as no
longer held (see [`orbit_key_down!`](@ref)).
"""
function orbit_key_up!(oc::OrbitControls, code::AbstractString)
    (code == "ControlLeft" || code == "ControlRight") && (oc.control_active = false)
    return oc
end

# TrackballControls: free rotation about the target via screen-space deltas.
mutable struct TrackballControls
    camera::_OrbitCamera
    target::Vec3{Float64}
    enabled::Bool
    position0::Vec3{Float64}
    target0::Vec3{Float64}
    up0::Vec3{Float64}
    # three.js TrackballControls.minDistance / maxDistance: every rotate, zoom
    # and pan keeps the camera-to-target distance inside this range.
    min_distance::Float64
    max_distance::Float64
    # three.js TrackballControls options and pointer/key/wheel input state
    # (see trackball_update!).
    rotate_speed::Float64
    zoom_speed::Float64
    pan_speed::Float64
    roll_speed::Float64
    no_rotate::Bool
    no_zoom::Bool
    no_pan::Bool
    multi_touch_roll::Bool
    static_moving::Bool
    dynamic_damping_factor::Float64
    min_zoom::Float64
    max_zoom::Float64
    keys::NTuple{3, String}
    mouse_buttons::NamedTuple{(:left, :middle, :right), NTuple{3, Symbol}}
    element_left::Float64
    element_top::Float64
    element_width::Float64
    element_height::Float64
    state::Symbol
    key_state::Symbol
    key_listening::Bool
    move_prev::NTuple{2, Float64}
    move_curr::NTuple{2, Float64}
    zoom_start::NTuple{2, Float64}
    zoom_end::NTuple{2, Float64}
    pan_start::NTuple{2, Float64}
    pan_end::NTuple{2, Float64}
    last_axis::Vec3{Float64}
    last_angle::Float64
    last_roll_angle::Float64
    touch_zoom_distance_start::Float64
    touch_zoom_distance_end::Float64
    touch_roll_angle::Float64
    touch_roll_pointer_ids::Union{Nothing, NTuple{2, Int}}
    pointers::Vector{Int}
    pointer_types::Vector{Symbol}
    pointer_down_positions::Vector{NTuple{2, Float64}}
    pointer_positions::Dict{Int, NTuple{2, Float64}}
    # three.js _zoom0: the camera zoom saved with the reset state; restored
    # by trackball_reset! for an orthographic camera.
    zoom0::Float64
end

const _TRACKBALL_DEFAULT_KEYS = ("KeyA", "KeyS", "KeyD")
const _TRACKBALL_DEFAULT_MOUSE_BUTTONS = (left=:rotate, middle=:dolly, right=:pan)

TrackballControls(camera::_OrbitCamera, target::Vec3{Float64}, enabled::Bool,
                  position0::Vec3{Float64}, target0::Vec3{Float64},
                  up0::Vec3{Float64}, min_distance::Real, max_distance::Real) =
    TrackballControls(camera, target, enabled, position0, target0, up0,
                      Float64(min_distance), Float64(max_distance),
                      1.0, 1.2, 0.3, 1.0, false, false, false, false, false,
                      0.2, 0.0, Inf, _TRACKBALL_DEFAULT_KEYS,
                      _TRACKBALL_DEFAULT_MOUSE_BUTTONS, 0.0, 0.0, 0.0, 0.0,
                      :none, :none, true, (0.0, 0.0), (0.0, 0.0), (0.0, 0.0),
                      (0.0, 0.0), (0.0, 0.0), (0.0, 0.0), Vec3(), 0.0, 0.0,
                      0.0, 0.0, 0.0, nothing, Int[], Symbol[],
                      NTuple{2, Float64}[], Dict{Int, NTuple{2, Float64}}(),
                      Float64(camera.zoom))

TrackballControls(camera::PerspectiveCamera, target::Vec3{Float64},
                  enabled::Bool, position0::Vec3{Float64},
                  target0::Vec3{Float64}, up0::Vec3{Float64}) =
    TrackballControls(camera, target, enabled, position0, target0, up0,
                      0.0, Inf)

"""
    TrackballControls(camera[, target]; enabled=true, min_distance=0.0,
                      max_distance=Inf, rotate_speed=1.0, zoom_speed=1.2,
                      pan_speed=0.3, roll_speed=1.0, no_rotate=false,
                      no_zoom=false, no_pan=false, multi_touch_roll=false,
                      static_moving=false, dynamic_damping_factor=0.2,
                      min_zoom=0.0, max_zoom=Inf, keys=("KeyA", "KeyS", "KeyD"),
                      mouse_buttons=(left=:rotate, middle=:dolly, right=:pan),
                      element_left=0.0, element_top=0.0, element_width=0.0,
                      element_height=0.0)

Trackball camera manipulator (three.js `TrackballControls`) for a perspective
or orthographic camera. For a perspective camera `min_distance` and
`max_distance` bound the camera-to-target distance after every
`trackball_rotate!`, `trackball_zoom!`, and `trackball_pan!`, like three.js
`minDistance`/`maxDistance` (which apply to perspective cameras only).

The remaining keywords are the three.js r186 options used by the
event-driven API ([`trackball_pointer_down!`](@ref),
[`trackball_pointer_move!`](@ref), [`trackball_pointer_up!`](@ref),
[`trackball_pointer_cancel!`](@ref), [`trackball_wheel!`](@ref),
[`trackball_key_down!`](@ref), [`trackball_key_up!`](@ref) and
[`trackball_update!`](@ref)): per-gesture speeds, `no_rotate`/`no_zoom`/
`no_pan` switches, two-finger roll, `static_moving` (no inertia) or the
`dynamic_damping_factor` inertia, orthographic `min_zoom`/`max_zoom`, the
`keys` (`KeyboardEvent.code` values) that turn any button into rotate, zoom or
pan, the `mouse_buttons` actions (`:rotate`, `:dolly`, `:pan` or `:none`), and
the element rectangle in client pixels (three.js `screen`; width and height
must be positive for pointer input).
"""
function TrackballControls(cam::_OrbitCamera, target::Vec3{Float64}=_camera_control_target(cam);
                           enabled::Bool=true, min_distance::Real=0.0,
                           max_distance::Real=Inf, rotate_speed::Real=1.0,
                           zoom_speed::Real=1.2, pan_speed::Real=0.3,
                           roll_speed::Real=1.0, no_rotate::Bool=false,
                           no_zoom::Bool=false, no_pan::Bool=false,
                           multi_touch_roll::Bool=false, static_moving::Bool=false,
                           dynamic_damping_factor::Real=0.2, min_zoom::Real=0.0,
                           max_zoom::Real=Inf,
                           keys::NTuple{3, AbstractString}=_TRACKBALL_DEFAULT_KEYS,
                           mouse_buttons::NamedTuple=_TRACKBALL_DEFAULT_MOUSE_BUTTONS,
                           element_left::Real=0.0, element_top::Real=0.0,
                           element_width::Real=0.0, element_height::Real=0.0)
    _prepare_camera_control_up!(cam)
    _validated_camera_view_vectors(cam, nameof(typeof(cam)))
    checked_target = _checked_control_vec3(
        target, "TrackballControls target")
    minimum_distance, maximum_distance =
        _checked_orbit_distances(min_distance, max_distance)
    tc = TrackballControls(cam, checked_target, enabled, cam.position,
                           checked_target, cam.up, minimum_distance,
                           maximum_distance)
    tc.rotate_speed = _checked_control_scalar(rotate_speed, "TrackballControls rotate_speed")
    tc.zoom_speed = _checked_control_scalar(zoom_speed, "TrackballControls zoom_speed")
    tc.pan_speed = _checked_control_scalar(pan_speed, "TrackballControls pan_speed")
    tc.roll_speed = _checked_control_scalar(roll_speed, "TrackballControls roll_speed")
    tc.no_rotate = no_rotate
    tc.no_zoom = no_zoom
    tc.no_pan = no_pan
    tc.multi_touch_roll = multi_touch_roll
    tc.static_moving = static_moving
    tc.dynamic_damping_factor = _checked_damping_factor(
        dynamic_damping_factor, "TrackballControls dynamic_damping_factor")
    tc.min_zoom, tc.max_zoom = _checked_trackball_zoom_range(min_zoom, max_zoom)
    tc.keys = (String(keys[1]), String(keys[2]), String(keys[3]))
    tc.mouse_buttons = _checked_trackball_mouse_buttons(mouse_buttons)
    tc.element_left = _checked_control_scalar(element_left, "TrackballControls element_left")
    tc.element_top = _checked_control_scalar(element_top, "TrackballControls element_top")
    tc.element_width = _checked_control_scalar(element_width, "TrackballControls element_width")
    tc.element_height = _checked_control_scalar(element_height, "TrackballControls element_height")
    return tc
end

function _checked_trackball_zoom_range(min_zoom, max_zoom)
    lo = Float64(min_zoom)
    hi = Float64(max_zoom)
    (!isnan(lo) && !isnan(hi) && lo >= 0.0 && lo <= hi && isfinite(lo)) ||
        throw(ArgumentError("TrackballControls needs 0 <= min_zoom <= max_zoom"))
    return lo, hi
end

function _checked_trackball_mouse_buttons(buttons::NamedTuple)
    keys(buttons) == (:left, :middle, :right) || throw(ArgumentError(
        "TrackballControls mouse_buttons must be a NamedTuple (left=, middle=, right=)"))
    for action in buttons
        action isa Symbol && action in (:rotate, :dolly, :pan, :none) ||
            throw(ArgumentError(
                "TrackballControls mouse_buttons actions must be :rotate, :dolly, :pan or :none"))
    end
    return (left=buttons.left, middle=buttons.middle, right=buttons.right)
end

"""
Save the current camera position, up vector, and target (and the zoom of an
orthographic camera) as the reset state.
"""
function trackball_save_state!(tc::TrackballControls)
    _validated_camera_view_vectors(tc.camera, nameof(typeof(tc.camera)))
    _checked_control_vec3(tc.target, "TrackballControls target")
    tc.position0 = tc.camera.position
    tc.target0 = tc.target
    tc.up0 = tc.camera.up
    tc.zoom0 = tc.camera.zoom
    return tc
end

"""
Restore the saved trackball state (the camera position, up vector and target,
and the zoom of an orthographic camera) and end any pointer or key gesture, as
three.js `TrackballControls.reset()` does.
"""
function trackball_reset!(tc::TrackballControls)
    position = _checked_control_vec3(
        tc.position0, "TrackballControls saved position")
    up = _checked_control_vec3(tc.up0, "TrackballControls saved up")
    max(abs(up.x), abs(up.y), abs(up.z)) > 0.0 ||
        throw(ArgumentError("TrackballControls saved up must be non-zero"))
    target = _checked_control_vec3(
        tc.target0, "TrackballControls saved target")
    # TrackballControls.js reset(): object.zoom = _zoom0. A perspective
    # camera's zoom is left alone, as before orthographic support.
    tc.camera isa OrthographicCamera &&
        (tc.camera.zoom = _validated_camera_zoom(tc.zoom0))
    tc.camera.position = position
    tc.camera.up = up
    tc.target = target
    tc.camera.target = target
    _sync_camera_rotation_from_view!(tc.camera)
    # reset() also sets state and keyState to NONE.
    tc.state = :none
    tc.key_state = :none
    return tc
end

# three.js TrackballControls._checkDistances (TrackballControls.js:738-756):
# an eye longer than maxDistance, or shorter than minDistance, is rescaled to
# that length along its direction. A zero eye has no direction and stays zero.
# three.js checks distances for a perspective camera only (update(),
# TrackballControls.js:377-395), so an orthographic eye is never limited.
function _trackball_limited_eye(tc::TrackballControls, eye::Vec3)
    tc.camera isa OrthographicCamera && return eye
    min_distance, max_distance =
        _checked_orbit_distances(tc.min_distance, tc.max_distance)
    distance = norm(eye)
    if distance > max_distance
        return normalize(eye) * max_distance
    elseif distance < min_distance && distance > 0.0
        return normalize(eye) * min_distance
    end
    return eye
end

function _trackball_set_eye!(tc::TrackballControls, eye::Vec3)
    tc.camera.position = _checked_control_vec3(
        tc.target + eye, "TrackballControls camera position")
    tc.camera.target = tc.target
    _sync_camera_rotation_from_view!(tc.camera)
    return tc
end

@inline _rotate_about_unit_axis(v::Vec3, k::Vec3, c, s) =
    v * c + cross(k, v) * s + k * (dot(k, v) * (1 - c))

"""
    trackball_rotate!(tc, dx, dy)

Rotate the camera about the target like three.js `TrackballControls` for a
screen-space drag of `(dx, dy)` radians: the eye turns by `hypot(dx, dy)` about
the axis perpendicular to the drag direction and the eye, and `camera.up` turns
with it, so the camera can roll over the poles.
"""
function trackball_rotate!(tc::TrackballControls, dx, dy)
    tc.enabled || return tc
    cam = tc.camera
    _, _, up = _validated_camera_view_vectors(cam, nameof(typeof(cam)))
    target = _checked_control_vec3(tc.target, "TrackballControls target")
    checked_dx = _checked_control_scalar(dx, "TrackballControls x delta")
    checked_dy = _checked_control_scalar(dy, "TrackballControls y delta")
    angle = hypot(checked_dx, checked_dy)
    eye = cam.position - target
    (angle > 0.0 && norm(eye) > 0.0) || return tc
    eye_direction = normalize(eye)
    up_direction = normalize(up)
    sideways = cross(up_direction, eye_direction)
    if norm(sideways) <= 1e-12
        sideways, up_direction = _perp_basis(eye_direction)
    end
    move = up_direction * checked_dy + normalize(sideways) * checked_dx
    axis = normalize(cross(move, eye_direction))
    c, s = cos(angle), sin(angle)
    new_up = _checked_control_vec3(
        _rotate_about_unit_axis(up, axis, c, s), "TrackballControls camera up")
    new_eye = _trackball_limited_eye(tc, _rotate_about_unit_axis(eye, axis, c, s))
    _checked_control_vec3(target + new_eye, "TrackballControls camera position")
    cam.up = new_up
    return _trackball_set_eye!(tc, new_eye)
end

"""
Scale the camera distance from the trackball target. `factor < 1` zooms in.
A factor that is not positive leaves the distance unchanged, as three.js
`TrackballControls` ignores such zoom steps. An orthographic camera keeps its
distance and divides its `zoom` by `factor` instead, clamped to
`min_zoom`..`max_zoom` (TrackballControls.js `_zoomCamera`).
"""
function trackball_zoom!(tc::TrackballControls, factor)
    tc.enabled || return tc
    _validated_camera_view_vectors(tc.camera, nameof(typeof(tc.camera)))
    _checked_control_vec3(tc.target, "TrackballControls target")
    checked_factor = _checked_control_scalar(
        factor, "TrackballControls zoom factor")
    if tc.camera isa OrthographicCamera
        checked_factor > 0.0 && _trackball_set_zoom!(tc, tc.camera.zoom / checked_factor)
        return tc
    end
    eye = tc.camera.position - tc.target
    # TrackballControls.js:632 only scales the eye when `factor > 0`.
    scaled = checked_factor > 0.0 ? eye * checked_factor : eye
    return _trackball_set_eye!(tc, _trackball_limited_eye(tc, scaled))
end

"""Pan the trackball target and camera in the view plane."""
function trackball_pan!(tc::TrackballControls, dx, dy)
    tc.enabled || return tc
    _validated_camera_view_vectors(tc.camera, nameof(typeof(tc.camera)))
    _checked_control_vec3(tc.target, "TrackballControls target")
    checked_dx = _checked_control_scalar(dx, "TrackballControls pan x delta")
    checked_dy = _checked_control_scalar(dy, "TrackballControls pan y delta")
    right, up = _camera_pan_basis(tc.camera, tc.target)
    shift = right * checked_dx + up * checked_dy
    target = _checked_control_vec3(
        tc.target + shift, "TrackballControls target")
    eye = tc.camera.position - tc.target
    limited = _trackball_limited_eye(tc, eye)
    position = _checked_control_vec3(
        limited === eye ? tc.camera.position + shift : target + limited,
        "TrackballControls camera position")
    tc.target = target
    tc.camera.position = position
    tc.camera.target = target
    _sync_camera_rotation_from_view!(tc.camera)
    return tc
end

# ---- TrackballControls pointer, wheel and key input (three.js r186) --------

# MathUtils.clamp(zoom, minZoom, maxZoom) applied to an orthographic camera.
function _trackball_set_zoom!(tc::TrackballControls, zoom::Float64)
    min_zoom, max_zoom = _checked_trackball_zoom_range(tc.min_zoom, tc.max_zoom)
    zoom = max(min_zoom, min(max_zoom, zoom))
    (isfinite(zoom) && zoom > 0.0) || throw(ArgumentError(
        "TrackballControls orthographic zoom must stay finite and positive"))
    tc.camera.zoom = zoom
    return tc
end

function _validate_trackball_input(tc::TrackballControls)
    _checked_control_scalar(tc.element_left, "TrackballControls element_left")
    _checked_control_scalar(tc.element_top, "TrackballControls element_top")
    width = _checked_control_scalar(tc.element_width, "TrackballControls element_width")
    height = _checked_control_scalar(tc.element_height, "TrackballControls element_height")
    (width > 0.0 && height > 0.0) || throw(ArgumentError(
        "TrackballControls pointer input needs a positive element_width and element_height"))
    _checked_trackball_mouse_buttons(tc.mouse_buttons)
    return tc
end

@inline _trackball_point(x, y, label::String) =
    (_checked_control_scalar(x, "$label x"), _checked_control_scalar(y, "$label y"))

# TrackballControls._getMouseOnScreen.
_trackball_on_screen(tc::TrackballControls, x::Float64, y::Float64) =
    ((x - tc.element_left) / tc.element_width, (y - tc.element_top) / tc.element_height)

# TrackballControls._getMouseOnCircle ("screen.width intentional" for y).
_trackball_on_circle(tc::TrackballControls, x::Float64, y::Float64) =
    ((x - tc.element_width * 0.5 - tc.element_left) / (tc.element_width * 0.5),
     (tc.element_height + 2 * (tc.element_top - y)) / tc.element_width)

@inline _trackball_effective_state(tc::TrackballControls) =
    tc.key_state === :none ? tc.state : tc.key_state

"""
    trackball_pointer_down!(controls::TrackballControls, x, y; button=0,
                            pointer_type=:mouse, pointer_id=1)

three.js `TrackballControls` `pointerdown` at client pixel `(x, y)`. A mouse
or pen button (0 left, 1 middle, 2 right) starts the `mouse_buttons` action,
or the action of a held key (see [`trackball_key_down!`](@ref)); one touch
rotates and two touches zoom and pan (and roll with `multi_touch_roll`). The
camera moves on the next [`trackball_update!`](@ref).
"""
function trackball_pointer_down!(tc::TrackballControls, x, y; button::Integer=0,
                                 pointer_type::Symbol=:mouse, pointer_id::Integer=1)
    tc.enabled || return tc
    _checked_pointer_type(pointer_type)
    _validate_trackball_input(tc)
    px, py = _trackball_point(x, y, "TrackballControls pointer")
    push!(tc.pointers, Int(pointer_id))
    push!(tc.pointer_types, pointer_type)
    push!(tc.pointer_down_positions, (px, py))
    if pointer_type === :touch
        tc.pointer_positions[Int(pointer_id)] = (px, py)
        if length(tc.pointers) == 1
            tc.state = :touch_rotate
            tc.move_curr = _trackball_on_circle(tc, tc.pointer_down_positions[1]...)
            tc.move_prev = tc.move_curr
        else
            # The first two pointers' pointerdown positions, as three.js
            # reads them from the stored events.
            (x0, y0), (x1, y1) = tc.pointer_down_positions[1], tc.pointer_down_positions[2]
            distance = sqrt((x0 - x1)^2 + (y0 - y1)^2)
            tc.state = :touch_zoom_pan
            tc.touch_zoom_distance_start = distance
            tc.touch_zoom_distance_end = distance
            tc.pan_start = _trackball_on_screen(tc, (x0 + x1) / 2, (y0 + y1) / 2)
            tc.pan_end = tc.pan_start
        end
        return tc
    end
    action = button == 0 ? tc.mouse_buttons.left :
             button == 1 ? tc.mouse_buttons.middle :
             button == 2 ? tc.mouse_buttons.right : :none
    tc.state = action === :dolly ? :zoom : action === :rotate ? :rotate :
               action === :pan ? :pan : :none
    state = _trackball_effective_state(tc)
    if state === :rotate && !tc.no_rotate
        tc.move_curr = _trackball_on_circle(tc, px, py)
        tc.move_prev = tc.move_curr
    elseif state === :zoom && !tc.no_zoom
        tc.zoom_start = _trackball_on_screen(tc, px, py)
        tc.zoom_end = tc.zoom_start
    elseif state === :pan && !tc.no_pan
        tc.pan_start = _trackball_on_screen(tc, px, py)
        tc.pan_end = tc.pan_start
    end
    return tc
end

"""
    trackball_pointer_move!(controls::TrackballControls, x, y;
                            pointer_type=:mouse, pointer_id=1)

three.js `TrackballControls` `pointermove` at client pixel `(x, y)`. Moves
arrive only while a pointer is down, as three.js listens for them only then.
"""
function trackball_pointer_move!(tc::TrackballControls, x, y;
                                 pointer_type::Symbol=:mouse, pointer_id::Integer=1)
    tc.enabled || return tc
    _checked_pointer_type(pointer_type)
    isempty(tc.pointers) && return tc
    _validate_trackball_input(tc)
    px, py = _trackball_point(x, y, "TrackballControls pointer")
    if pointer_type === :touch
        id = Int(pointer_id)
        tc.pointer_positions[id] = (px, py)
        if length(tc.pointers) == 1
            tc.move_curr = _trackball_on_circle(tc, px, py)
        else
            # TrackballControls._getSecondPointerPosition.
            other = id == tc.pointers[1] ? 2 : 1
            ox, oy = get(tc.pointer_positions, tc.pointers[other],
                         tc.pointer_down_positions[other])
            tc.touch_zoom_distance_end = sqrt((px - ox)^2 + (py - oy)^2)
            tc.pan_end = _trackball_on_screen(tc, (px + ox) / 2, (py + oy) / 2)
        end
        return tc
    end
    state = _trackball_effective_state(tc)
    if state === :rotate && !tc.no_rotate
        tc.move_curr = _trackball_on_circle(tc, px, py)
    elseif state === :zoom && !tc.no_zoom
        tc.zoom_end = _trackball_on_screen(tc, px, py)
    elseif state === :pan && !tc.no_pan
        tc.pan_end = _trackball_on_screen(tc, px, py)
    end
    return tc
end

# TrackballControls._removePointer.
function _trackball_remove_pointer!(tc::TrackballControls, id::Int)
    delete!(tc.pointer_positions, id)
    i = findfirst(==(id), tc.pointers)
    if i !== nothing
        deleteat!(tc.pointers, i)
        deleteat!(tc.pointer_types, i)
        deleteat!(tc.pointer_down_positions, i)
    end
    return tc
end

"""
    trackball_pointer_up!(controls::TrackballControls, x, y;
                          pointer_type=:mouse, pointer_id=1)

three.js `TrackballControls` `pointerup` at client pixel `(x, y)`: ends the
mouse gesture, or hands a touch gesture over to the remaining finger(s).
Inertia (unless `static_moving`) continues in later
[`trackball_update!`](@ref) calls.
"""
function trackball_pointer_up!(tc::TrackballControls, x, y;
                               pointer_type::Symbol=:mouse, pointer_id::Integer=1)
    tc.enabled || return tc
    _checked_pointer_type(pointer_type)
    isempty(tc.pointers) && return tc
    _validate_trackball_input(tc)
    px, py = _trackball_point(x, y, "TrackballControls pointer")
    id = Int(pointer_id)
    if pointer_type === :touch
        # TrackballControls onTouchEnd runs before the pointer is removed.
        n = length(tc.pointers)
        if n == 0
            tc.state = :none
        elseif n == 1
            tc.state = :touch_rotate
            tc.move_curr = _trackball_on_circle(tc, px, py)
            tc.move_prev = tc.move_curr
        elseif n == 2
            tc.state = :touch_zoom_pan
            for (i, other) in enumerate(tc.pointers)
                if other != id
                    ox, oy = get(tc.pointer_positions, other, tc.pointer_down_positions[i])
                    tc.move_curr = _trackball_on_circle(tc, ox, oy)
                    tc.move_prev = tc.move_curr
                    break
                end
            end
        end
    else
        tc.state = :none
    end
    return _trackball_remove_pointer!(tc, id)
end

"""
    trackball_pointer_cancel!(controls::TrackballControls; pointer_id=1)

three.js `TrackballControls` `pointercancel`: forget the pointer without
ending its gesture state.
"""
trackball_pointer_cancel!(tc::TrackballControls; pointer_id::Integer=1) =
    _trackball_remove_pointer!(tc, Int(pointer_id))

"""
    trackball_wheel!(controls::TrackballControls, delta_y; delta_mode=0)

three.js `TrackballControls` `wheel`: `delta_y` in pixels (`delta_mode` 0),
lines (1) or pages (2) feeds the zoom applied by [`trackball_update!`](@ref).
Ignored with `no_zoom`.
"""
function trackball_wheel!(tc::TrackballControls, delta_y; delta_mode::Integer=0)
    tc.enabled || return tc
    tc.no_zoom && return tc
    dy = _checked_control_scalar(delta_y, "TrackballControls wheel delta_y")
    scale = delta_mode == 2 ? 0.025 : delta_mode == 1 ? 0.01 : 0.00025
    tc.zoom_start = (tc.zoom_start[1], tc.zoom_start[2] - dy * scale)
    return tc
end

"""
    trackball_key_down!(controls::TrackballControls, code)

three.js `TrackballControls` `keydown` with `KeyboardEvent.code` `code`:
`keys[1]`, `keys[2]` or `keys[3]` makes every button rotate, zoom or pan
until [`trackball_key_up!`](@ref). As in three.js, the first key down stops
key handling until the next key up, even when it matches no key.
"""
function trackball_key_down!(tc::TrackballControls, code::AbstractString)
    tc.enabled || return tc
    tc.key_listening || return tc
    tc.key_listening = false
    tc.key_state === :none || return tc
    if code == tc.keys[1] && !tc.no_rotate
        tc.key_state = :rotate
    elseif code == tc.keys[2] && !tc.no_zoom
        tc.key_state = :zoom
    elseif code == tc.keys[3] && !tc.no_pan
        tc.key_state = :pan
    end
    return tc
end

"""
    trackball_key_up!(controls::TrackballControls)

three.js `TrackballControls` `keyup`: clear the key action and listen for
keys again.
"""
function trackball_key_up!(tc::TrackballControls)
    tc.enabled || return tc
    tc.key_state = :none
    tc.key_listening = true
    return tc
end

# Vector3.normalize: divideScalar(length || 1), so a zero vector stays zero.
@inline function _trackball_normalize(v::Vec3)
    n = norm(v)
    return n == 0.0 ? v : v * (1 / n)
end

# Vector3.setLength: normalize (a zero vector stays zero) and scale.
@inline function _trackball_set_length(v::Vec3, length::Float64)
    n = norm(v)
    return n == 0.0 ? v * length : v * (1 / n) * length
end

# TrackballControls._getTouchRollAngle.
function _trackball_touch_roll_angle!(tc::TrackballControls)
    if length(tc.pointers) < 2 || tc.pointer_types[1] !== :touch ||
       tc.pointer_types[2] !== :touch
        tc.touch_roll_pointer_ids = nothing
        return 0.0
    end
    ids = (tc.pointers[1], tc.pointers[2])
    x0, y0 = get(tc.pointer_positions, ids[1], tc.pointer_down_positions[1])
    x1, y1 = get(tc.pointer_positions, ids[2], tc.pointer_down_positions[2])
    roll = atan(y1 - y0, x1 - x0)
    if ids != tc.touch_roll_pointer_ids
        tc.touch_roll_pointer_ids = ids
        tc.touch_roll_angle = roll
        return 0.0
    end
    angle = roll - tc.touch_roll_angle
    tc.touch_roll_angle = roll
    if angle > π
        angle -= 2π
    elseif angle < -π
        angle += 2π
    end
    return angle
end

"""
    trackball_update!(controls::TrackballControls) -> controls

One three.js r186 `TrackballControls.update()`: apply the rotation, roll,
zoom and pan accumulated from pointer, wheel and key input, with
`dynamic_damping_factor` inertia unless `static_moving`, then keep the
perspective camera within `min_distance`..`max_distance` and look at the
target. Call it once per frame. Like three.js it runs even when the controls
are disabled; a two-finger zoom whose finger distance makes the zoom factor
non-finite or not positive is skipped instead of producing a degenerate
camera.
"""
function trackball_update!(tc::TrackballControls)
    cam = tc.camera
    _, _, up = _validated_camera_view_vectors(cam, nameof(typeof(cam)))
    target = _checked_control_vec3(tc.target, "TrackballControls target")
    _checked_control_scalar(tc.rotate_speed, "TrackballControls rotate_speed")
    _checked_control_scalar(tc.zoom_speed, "TrackballControls zoom_speed")
    _checked_control_scalar(tc.pan_speed, "TrackballControls pan_speed")
    _checked_control_scalar(tc.roll_speed, "TrackballControls roll_speed")
    ddf = _checked_damping_factor(tc.dynamic_damping_factor,
                                  "TrackballControls dynamic_damping_factor")
    min_distance, max_distance = _checked_orbit_distances(tc.min_distance, tc.max_distance)
    ortho = cam isa OrthographicCamera
    zoom = ortho ? Float64(cam.zoom) : 1.0
    if ortho
        min_zoom, max_zoom = _checked_trackball_zoom_range(tc.min_zoom, tc.max_zoom)
        _checked_control_scalar(cam.left, "OrthographicCamera left")
        _checked_control_scalar(cam.right, "OrthographicCamera right")
        _checked_control_scalar(cam.top, "OrthographicCamera top")
        _checked_control_scalar(cam.bottom, "OrthographicCamera bottom")
    end
    eye = cam.position - target
    move_prev = tc.move_prev
    last_angle = tc.last_angle
    last_axis = tc.last_axis
    last_roll_angle = tc.last_roll_angle
    zoom_start = tc.zoom_start
    pan_start = tc.pan_start
    touch_zoom_start = tc.touch_zoom_distance_start
    if !tc.no_rotate
        # _rotateCamera.
        mx = tc.move_curr[1] - tc.move_prev[1]
        my = tc.move_curr[2] - tc.move_prev[2]
        angle = sqrt(mx * mx + my * my)
        if angle != 0.0
            eye_direction = _trackball_normalize(eye)
            up_direction = _trackball_normalize(up)
            sideways = _trackball_normalize(cross(up_direction, eye_direction))
            move_direction = _trackball_set_length(up_direction, my) +
                             _trackball_set_length(sideways, mx)
            axis = _trackball_normalize(cross(move_direction, eye))
            angle *= tc.rotate_speed
            q = quat_from_axis_angle(axis, angle)
            eye = quat_rotate_vector(q, eye)
            up = quat_rotate_vector(q, up)
            last_axis = axis
            last_angle = angle
        elseif !tc.static_moving && last_angle != 0.0
            last_angle *= sqrt(1.0 - ddf)
            q = quat_from_axis_angle(last_axis, last_angle)
            eye = quat_rotate_vector(q, eye)
            up = quat_rotate_vector(q, up)
        end
        move_prev = tc.move_curr
        if tc.multi_touch_roll
            # _rollCamera.
            roll = _trackball_touch_roll_angle!(tc)
            apply_roll = true
            if roll != 0.0
                last_roll_angle = roll * tc.roll_speed
            elseif !tc.static_moving && last_roll_angle != 0.0
                last_roll_angle *= sqrt(1.0 - ddf)
            else
                apply_roll = false
            end
            if apply_roll
                q = quat_from_axis_angle(_trackball_normalize(eye), last_roll_angle)
                up = quat_rotate_vector(q, up)
            end
        end
    end
    if !tc.no_zoom
        # _zoomCamera.
        if tc.state === :touch_zoom_pan
            factor = touch_zoom_start / tc.touch_zoom_distance_end
            touch_zoom_start = tc.touch_zoom_distance_end
            if isfinite(factor) && factor > 0.0
                if ortho
                    zoom = max(min_zoom, min(max_zoom, zoom / factor))
                else
                    eye = eye * factor
                end
            end
        else
            factor = 1.0 + (tc.zoom_end[2] - zoom_start[2]) * tc.zoom_speed
            if factor != 1.0 && factor > 0.0
                if ortho
                    zoom = max(min_zoom, min(max_zoom, zoom / factor))
                else
                    eye = eye * factor
                end
            end
            zoom_start = tc.static_moving ? tc.zoom_end :
                (zoom_start[1], zoom_start[2] + (tc.zoom_end[2] - zoom_start[2]) * ddf)
        end
    end
    if !tc.no_pan
        # _panCamera.
        cx = tc.pan_end[1] - pan_start[1]
        cy = tc.pan_end[2] - pan_start[2]
        if cx * cx + cy * cy != 0.0
            if ortho
                _validate_trackball_input(tc)
                cx *= (cam.right - cam.left) / zoom / tc.element_width
                cy *= (cam.top - cam.bottom) / zoom / tc.element_width
            end
            scale = norm(eye) * tc.pan_speed
            cx *= scale
            cy *= scale
            pan = _trackball_set_length(cross(eye, up), cx) + _trackball_set_length(up, cy)
            target = target + pan
            pan_start = tc.static_moving ? tc.pan_end :
                (pan_start[1] + (tc.pan_end[1] - pan_start[1]) * ddf,
                 pan_start[2] + (tc.pan_end[2] - pan_start[2]) * ddf)
        end
    end
    if !ortho && (!tc.no_zoom || !tc.no_pan)
        # _checkDistances.
        if dot(eye, eye) > max_distance * max_distance
            eye = _trackball_set_length(eye, max_distance)
            zoom_start = tc.zoom_end
        end
        if dot(eye, eye) < min_distance * min_distance
            eye = _trackball_set_length(eye, min_distance)
            zoom_start = tc.zoom_end
        end
    end
    position = _checked_control_vec3(target + eye, "TrackballControls camera position")
    up = _checked_control_vec3(up, "TrackballControls camera up")
    max(abs(up.x), abs(up.y), abs(up.z)) > 0.0 ||
        throw(ArgumentError("TrackballControls camera up became zero"))
    _checked_control_vec3(target, "TrackballControls target")
    ortho && ((isfinite(zoom) && zoom > 0.0) || throw(ArgumentError(
        "TrackballControls orthographic zoom must stay finite and positive")))
    tc.move_prev = move_prev
    tc.last_angle = last_angle
    tc.last_axis = last_axis
    tc.last_roll_angle = last_roll_angle
    tc.zoom_start = zoom_start
    tc.pan_start = pan_start
    tc.touch_zoom_distance_start = touch_zoom_start
    tc.target = target
    ortho && (cam.zoom = zoom)
    cam.up = up
    cam.position = position
    cam.target = target
    _sync_camera_rotation_from_view!(cam)
    return tc
end

"""
    FlyMoveState()

The twelve inputs of three.js `FlyControls._moveState` (`up`, `down`,
`left`, `right`, `forward`, `back`, `pitch_up`, `pitch_down`, `yaw_left`,
`yaw_right`, `roll_left`, `roll_right`), each 0 when idle. Keys set them to 0
or 1; pointer movement sets `yaw_left` and `pitch_down` to the pointer offset
from the element centre in half-sizes.
"""
mutable struct FlyMoveState
    up::Float64
    down::Float64
    left::Float64
    right::Float64
    forward::Float64
    back::Float64
    pitch_up::Float64
    pitch_down::Float64
    yaw_left::Float64
    yaw_right::Float64
    roll_left::Float64
    roll_right::Float64
end
FlyMoveState() = FlyMoveState(0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                              0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

"""
    FlyControls(camera::PerspectiveCamera; enabled=true, movement_speed=1.0,
                roll_speed=0.005, drag_to_look=false, auto_forward=false)

Free-flight camera control. [`fly_translate!`](@ref) and [`fly_rotate!`](@ref)
move and turn the camera directly. The event-driven three.js r186
`FlyControls` behaviour is available through [`fly_key_down!`](@ref),
[`fly_key_up!`](@ref), [`fly_pointer_down!`](@ref),
[`fly_pointer_move!`](@ref), [`fly_pointer_up!`](@ref),
[`fly_pointer_cancel!`](@ref) and [`fly_update!`](@ref)`(controls, delta)`:
the inputs set `move_state` ([`FlyMoveState`](@ref)), from which
`move_vector` (right, up, back) and `rotation_vector` (pitch, yaw, roll) are
derived, and each update translates the camera along its own axes by
`move_vector * movement_speed * delta` and turns it by the quaternion
`(rotation_vector * roll_speed * delta, 1)` normalized, including roll. As in
three.js, `move_vector` and `rotation_vector` are recomputed only by input
events, so `auto_forward` takes effect at the next key or pointer event.
"""
mutable struct FlyControls
    camera::PerspectiveCamera
    enabled::Bool
    movement_speed::Float64
    roll_speed::Float64
    drag_to_look::Bool
    auto_forward::Bool
    move_state::FlyMoveState
    move_vector::Vec3{Float64}
    rotation_vector::Vec3{Float64}
    # Number of pointers down while `drag_to_look` (three.js `_status`).
    status::Int
end

function FlyControls(camera::PerspectiveCamera; enabled::Bool=true,
                     movement_speed::Real=1.0, roll_speed::Real=0.005,
                     drag_to_look::Bool=false, auto_forward::Bool=false)
    return FlyControls(
        camera, enabled,
        _checked_control_scalar(movement_speed, "FlyControls movement_speed"),
        _checked_control_scalar(roll_speed, "FlyControls roll_speed"),
        drag_to_look, auto_forward, FlyMoveState(),
        Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0), 0)
end

# FlyControls.js _updateMovementVector / _updateRotationVector.
function _fly_update_movement_vector!(fc::FlyControls)
    m = fc.move_state
    forward = (m.forward != 0 || (fc.auto_forward && m.back == 0)) ? 1.0 : 0.0
    fc.move_vector = Vec3(-m.left + m.right, -m.down + m.up, -forward + m.back)
    return fc
end

function _fly_update_rotation_vector!(fc::FlyControls)
    m = fc.move_state
    fc.rotation_vector = Vec3(-m.pitch_down + m.pitch_up,
                              -m.yaw_right + m.yaw_left,
                              -m.roll_right + m.roll_left)
    return fc
end

function _fly_key!(fc::FlyControls, code::AbstractString, value::Float64)
    m = fc.move_state
    if code == "KeyW"
        m.forward = value
    elseif code == "KeyS"
        m.back = value
    elseif code == "KeyA"
        m.left = value
    elseif code == "KeyD"
        m.right = value
    elseif code == "KeyR"
        m.up = value
    elseif code == "KeyF"
        m.down = value
    elseif code == "ArrowUp"
        m.pitch_up = value
    elseif code == "ArrowDown"
        m.pitch_down = value
    elseif code == "ArrowLeft"
        m.yaw_left = value
    elseif code == "ArrowRight"
        m.yaw_right = value
    elseif code == "KeyQ"
        m.roll_left = value
    elseif code == "KeyE"
        m.roll_right = value
    end
    _fly_update_movement_vector!(fc)
    return _fly_update_rotation_vector!(fc)
end

"""
    fly_key_down!(controls::FlyControls, code::AbstractString; alt_key=false)

Press the key `code` (a `KeyboardEvent.code`), like three.js `FlyControls`:
W/S forward/back, A/D left/right, R/F up/down, the up/down arrows pitch, the
left/right arrows yaw and Q/E roll. Ignored while `alt_key` is held or the
controls are disabled.
"""
function fly_key_down!(fc::FlyControls, code::AbstractString; alt_key::Bool=false)
    (alt_key || !fc.enabled) && return fc
    return _fly_key!(fc, code, 1.0)
end

"""
    fly_key_up!(controls::FlyControls, code::AbstractString)

Release the key `code`; see [`fly_key_down!`](@ref).
"""
function fly_key_up!(fc::FlyControls, code::AbstractString)
    fc.enabled || return fc
    return _fly_key!(fc, code, 0.0)
end

"""
    fly_pointer_down!(controls::FlyControls; button=0)

A pointer button goes down (three.js `pointerdown`): with `drag_to_look` it
starts looking, otherwise button 0 flies forward and button 2 backward.
"""
function fly_pointer_down!(fc::FlyControls; button::Integer=0)
    fc.enabled || return fc
    if fc.drag_to_look
        fc.status += 1
    else
        button == 0 && (fc.move_state.forward = 1.0)
        button == 2 && (fc.move_state.back = 1.0)
        _fly_update_movement_vector!(fc)
    end
    return fc
end

"""
    fly_pointer_move!(controls::FlyControls, page_x, page_y; width, height,
                      left=0, top=0)

The pointer moves to page position `(page_x, page_y)` over an element of
`width`×`height` pixels whose top-left corner is at `(left, top)` (three.js
`pointermove` with the element's offset size and position). Unless
`drag_to_look` is set and no pointer is down, the offset from the element
centre in half-sizes sets the yaw (`yaw_left`) and pitch (`pitch_down`) rates.
"""
function fly_pointer_move!(fc::FlyControls, page_x, page_y; width::Real,
                           height::Real, left::Real=0.0, top::Real=0.0)
    x = _checked_control_scalar(page_x, "FlyControls page_x")
    y = _checked_control_scalar(page_y, "FlyControls page_y")
    w = _checked_control_scalar(width, "FlyControls element width")
    h = _checked_control_scalar(height, "FlyControls element height")
    (w > 0.0 && h > 0.0) || throw(ArgumentError(
        "FlyControls element width and height must be positive"))
    ox = _checked_control_scalar(left, "FlyControls element left")
    oy = _checked_control_scalar(top, "FlyControls element top")
    fc.enabled || return fc
    if !fc.drag_to_look || fc.status > 0
        half_width = w / 2
        half_height = h / 2
        fc.move_state.yaw_left = -((x - ox) - half_width) / half_width
        fc.move_state.pitch_down = ((y - oy) - half_height) / half_height
        _fly_update_rotation_vector!(fc)
    end
    return fc
end

"""
    fly_pointer_up!(controls::FlyControls; button=0)

A pointer button is released (three.js `pointerup`): with `drag_to_look` the
look rates stop, otherwise button 0 stops forward and button 2 backward
flight.
"""
function fly_pointer_up!(fc::FlyControls; button::Integer=0)
    fc.enabled || return fc
    if fc.drag_to_look
        fc.status -= 1
        fc.move_state.yaw_left = 0.0
        fc.move_state.pitch_down = 0.0
    else
        button == 0 && (fc.move_state.forward = 0.0)
        button == 2 && (fc.move_state.back = 0.0)
        _fly_update_movement_vector!(fc)
    end
    return _fly_update_rotation_vector!(fc)
end

"""
    fly_pointer_cancel!(controls::FlyControls)

The pointer is cancelled (three.js `pointercancel`): looking (with
`drag_to_look`) or pointer-driven flight stops.
"""
function fly_pointer_cancel!(fc::FlyControls)
    fc.enabled || return fc
    if fc.drag_to_look
        fc.status = 0
        fc.move_state.yaw_left = 0.0
        fc.move_state.pitch_down = 0.0
    else
        fc.move_state.forward = 0.0
        fc.move_state.back = 0.0
        _fly_update_movement_vector!(fc)
    end
    return _fly_update_rotation_vector!(fc)
end

"""
    fly_update!(controls::FlyControls, delta)

Advance the flight by `delta` seconds (three.js `FlyControls.update`): move
the camera along its local x, y and z axes by `move_vector * movement_speed *
delta`, then turn it by the normalized quaternion `(rotation_vector *
roll_speed * delta, 1)` in its own frame. The camera keeps its target
distance; `camera.up` follows the roll. Does nothing while disabled.
"""
function fly_update!(fc::FlyControls, delta)
    fc.enabled || return fc
    dt = _checked_control_scalar(delta, "FlyControls delta")
    speed = _checked_control_scalar(fc.movement_speed, "FlyControls movement_speed")
    roll = _checked_control_scalar(fc.roll_speed, "FlyControls roll_speed")
    mv = _checked_control_vec3(fc.move_vector, "FlyControls move_vector")
    rv = _checked_control_vec3(fc.rotation_vector, "FlyControls rotation_vector")
    cam = fc.camera
    q = _camera_local_quaternion(cam)
    distance = norm(cam.target - cam.position)
    move_mult = dt * speed
    rot_mult = dt * roll
    # Object3D.translateX/Y/Z: position += (axis rotated by q) * distance.
    position = cam.position
    position += quat_rotate_vector(q, Vec3(1.0, 0.0, 0.0)) * (mv.x * move_mult)
    position += quat_rotate_vector(q, Vec3(0.0, 1.0, 0.0)) * (mv.y * move_mult)
    position += quat_rotate_vector(q, Vec3(0.0, 0.0, 1.0)) * (mv.z * move_mult)
    position = _checked_control_vec3(position, "FlyControls camera position")
    turn = quat_normalize(Quaternion(rv.x * rot_mult, rv.y * rot_mult,
                                     rv.z * rot_mult, 1.0))
    _set_camera_pose!(cam, position, quat_multiply(q, turn), distance,
                      "FlyControls")
    return fc
end

# A rotation-driven camera renders from `rotation`, so first-person controls
# derive their look target from it before moving (keeping `up` as the world-up
# hint, like a target-driven camera), and write the result back to `rotation`.
function _first_person_view_from_rotation!(cam::PerspectiveCamera)
    cam.rotation_driven || return cam
    cam.target = _camera_control_target(cam)
    return cam
end

"""Translate the camera (and its target) along forward/right/up axes."""
function fly_translate!(fc::FlyControls, forward, right, up)
    cam = fc.camera
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    checked_forward = _checked_control_scalar(
        forward, "FlyControls forward delta")
    checked_right = _checked_control_scalar(right, "FlyControls right delta")
    checked_up = _checked_control_scalar(up, "FlyControls up delta")
    _first_person_view_from_rotation!(cam)
    f = _direction_between(cam.position, cam.target)
    r, u = _camera_pan_basis(cam, cam.target)
    shift = f * checked_forward + r * checked_right + u * checked_up
    position = _checked_control_vec3(
        cam.position + shift, "FlyControls camera position")
    target = _checked_control_vec3(
        cam.target + shift, "FlyControls camera target")
    cam.position = position
    cam.target = target
    return fc
end

"""Yaw/pitch the camera in place (target orbits around the camera position)."""
function fly_rotate!(fc::FlyControls, yaw, pitch)
    cam = fc.camera
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    checked_yaw = _checked_control_scalar(yaw, "FlyControls yaw")
    checked_pitch = _checked_control_scalar(pitch, "FlyControls pitch")
    _first_person_view_from_rotation!(cam)
    dist = norm(cam.target - cam.position)
    dir = normalize(cam.target - cam.position)
    s = cartesian_to_spherical(dir)
    s2 = Spherical(1.0, clamp(s.phi - checked_pitch, 1e-4, π - 1e-4),
                   s.theta + checked_yaw)
    target = cam.position + spherical_to_cartesian(s2) * dist
    cam.target = _checked_control_vec3(
        target, "FlyControls camera target")
    _sync_camera_rotation_from_view!(cam)
    return fc
end

# PointerLockControls: first-person look driven by pointer movement deltas.
mutable struct PointerLockControls
    camera::PerspectiveCamera
    is_locked::Bool
    pointer_speed::Float64
    min_polar_angle::Float64
    max_polar_angle::Float64
end
function PointerLockControls(cam::PerspectiveCamera; pointer_speed::Real=1.0,
                             min_polar_angle::Real=0.0, max_polar_angle::Real=π)
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    minimum_polar, maximum_polar = _checked_polar_limits(
        min_polar_angle, max_polar_angle, "PointerLockControls")
    speed = _checked_pointer_speed(pointer_speed, "pointer_speed")
    PointerLockControls(cam, false, speed, minimum_polar, maximum_polar)
end

pointerlock_lock!(pc::PointerLockControls) = (pc.is_locked = true; pc)
pointerlock_unlock!(pc::PointerLockControls) = (pc.is_locked = false; pc)

function _pointerlock_direction_distance(cam::PerspectiveCamera)
    _validate_object_transform(cam)
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    delta = cam.target - cam.position
    dist = norm(delta)
    if dist > 1e-12
        return normalize(delta), dist
    end
    rot = cam.rotation
    R = quat_to_mat4(quat_from_euler(rot.x, rot.y, rot.z; order=rot.order))
    origin = mat4_transform_point(R, Vec3(0.0, 0.0, 0.0))
    forward = mat4_transform_point(R, Vec3(0.0, 0.0, -1.0)) - origin
    return normalize(forward), 1.0
end

function pointerlock_move!(pc::PointerLockControls, movement_x, movement_y)
    pc.is_locked || return pc
    speed = _checked_pointer_speed(pc.pointer_speed, "pointer_speed")
    min_polar, max_polar = _checked_polar_limits(
        pc.min_polar_angle, pc.max_polar_angle, "PointerLockControls")
    checked_x = _checked_control_scalar(
        movement_x, "PointerLockControls movement_x")
    checked_y = _checked_control_scalar(
        movement_y, "PointerLockControls movement_y")
    cam = pc.camera
    _first_person_view_from_rotation!(cam)
    dir, dist = _pointerlock_direction_distance(cam)
    s = cartesian_to_spherical(dir)
    yaw = -checked_x * 0.002 * speed
    pitch = -checked_y * 0.002 * speed
    min_phi = max(min_polar, 1e-4)
    max_phi = min(max_polar, π - 1e-4)
    s2 = Spherical(1.0, clamp(s.phi - pitch, min_phi, max_phi), s.theta + yaw)
    target = cam.position + spherical_to_cartesian(s2) * dist
    cam.target = _checked_control_vec3(
        target, "PointerLockControls camera target")
    _sync_camera_rotation_from_view!(cam)
    return pc
end

# ---- Camera orientation as a three.js Object3D.quaternion -----------------

# Local orientation of a camera as the quaternion three.js keeps in
# `object.quaternion`: its rotation for a rotation-driven camera, otherwise the
# rotation that `Object3D.lookAt(target)` with `camera.up` produces
# (the transposed view rotation of `mat4_look_at`).
function _camera_local_quaternion(cam::AbstractCamera)
    if cam.rotation_driven
        _validate_object_transform(cam)
        r = cam.rotation
        return quat_normalize(quat_from_euler(r.x, r.y, r.z; order=r.order))
    end
    position, target, up = _validated_camera_view_vectors(
        cam, nameof(typeof(cam)))
    return quat_from_rotation_matrix(
        mat4_transpose(mat4_look_at(position, target, up)))
end

# Writes a position and local orientation to a camera, validating everything
# before changing anything. A rotation-driven camera takes the orientation as
# its rotation. The target is placed `distance` along the view direction (1
# when that is not a positive finite length) and `up` becomes the rotated +y
# axis, so a roll survives the round trip through position, target and up.
function _set_camera_pose!(cam::AbstractCamera, position::Vec3, q::Quaternion,
                           distance, label::String)
    q = quat_normalize(q)
    position = _checked_control_vec3(position, "$label camera position")
    forward = quat_rotate_vector(q, Vec3(0.0, 0.0, -1.0))
    up = _checked_control_vec3(quat_rotate_vector(q, Vec3(0.0, 1.0, 0.0)),
                               "$label camera up")
    (isfinite(distance) && distance > 0.0) || (distance = 1.0)
    target = _checked_control_vec3(position + forward * distance,
                                   "$label camera target")
    if cam.rotation_driven
        euler = _transform_quaternion_to_euler(q, cam.rotation.order)
        _checked_control_vec3(Vec3(euler.x, euler.y, euler.z),
                              "$label camera rotation")
        cam.rotation = euler
    end
    cam.position = position
    cam.target = target
    cam.up = up
    return cam
end

# three.js `object.lookAt(point)` for a camera: aim at `point` keeping
# `camera.up` as the up hint (a rotation-driven camera takes the matching
# rotation).
function _camera_control_look_at!(cam::AbstractCamera, point::Vec3,
                                  label::String)
    cam.target = _checked_control_vec3(point, "$label look target")
    _sync_camera_rotation_from_view!(cam)
    return cam
end

# ---- FirstPersonControls ----------------------------------------------------

"""
    FirstPersonControls(camera; enabled=true, movement_speed=1.0,
                        look_speed=0.005, damping_factor=0.1,
                        look_vertical=true, auto_forward=false,
                        height_speed=false, height_coef=1.0, height_min=0.0,
                        height_max=1.0, constrain_vertical=false,
                        vertical_min=0.0, vertical_max=π)

three.js r186 `FirstPersonControls` for a `PerspectiveCamera` or an
`OrthographicCamera`, with Julia calls standing in for the DOM events:
[`first_person_key_down!`](@ref)/[`first_person_key_up!`](@ref) take a
`KeyboardEvent.code` string, [`first_person_pointer_down!`](@ref),
[`first_person_pointer_move!`](@ref) and [`first_person_pointer_up!`](@ref)
take page coordinates in pixels, and [`first_person_update!`](@ref)`(controls,
delta)` advances one frame of `delta` seconds.

Keys move the camera along world axes from its yaw (W/S or the up/down
arrows: forward/back in the xz-plane; A/D or the left/right arrows: strafe;
R/F: along world y). The primary pointer button (or one touch) moves along the
look direction, the secondary button (or a second touch) backward, and while a
pointer is down its offset from where it went down turns the view at
`look_speed` per pixel per second. Movement and look velocities ease toward
their input by `damping_factor` per update (`1` disables the easing).
`height_speed` adds `(clamp(y, height_min, height_max) - height_min) *
height_coef` to the forward speed. The view latitude stays within ±85°;
`constrain_vertical` maps the polar angle onto `[vertical_min, vertical_max]`.
The heading and pitch are read from the camera at construction and by
[`first_person_look_at!`](@ref). Fields carry the three.js property names in
snake case and may be changed between updates.
"""
mutable struct FirstPersonControls
    camera::_OrbitCamera
    enabled::Bool
    movement_speed::Float64
    look_speed::Float64
    damping_factor::Float64
    look_vertical::Bool
    auto_forward::Bool
    height_speed::Bool
    height_coef::Float64
    height_min::Float64
    height_max::Float64
    constrain_vertical::Bool
    vertical_min::Float64
    vertical_max::Float64
    mouse_drag_on::Bool
    # three.js internals (FirstPersonControls.js:141-176).
    velocity::Vec3{Float64}
    pointer_x::Float64
    pointer_y::Float64
    pointer_down_x::Float64
    pointer_down_y::Float64
    pointer_count::Int
    key_forward::Bool
    key_backward::Bool
    pointer_forward::Bool
    pointer_backward::Bool
    move_left::Bool
    move_right::Bool
    move_up::Bool
    move_down::Bool
    lat::Float64
    lon::Float64
    lon_velocity::Float64
    lat_velocity::Float64
end

function FirstPersonControls(camera::_OrbitCamera; enabled::Bool=true,
                             movement_speed::Real=1.0, look_speed::Real=0.005,
                             damping_factor::Real=0.1, look_vertical::Bool=true,
                             auto_forward::Bool=false, height_speed::Bool=false,
                             height_coef::Real=1.0, height_min::Real=0.0,
                             height_max::Real=1.0, constrain_vertical::Bool=false,
                             vertical_min::Real=0.0, vertical_max::Real=π)
    fc = FirstPersonControls(
        camera, enabled,
        _checked_control_scalar(movement_speed, "FirstPersonControls movement_speed"),
        _checked_control_scalar(look_speed, "FirstPersonControls look_speed"),
        _checked_damping_factor(damping_factor, "FirstPersonControls damping_factor"),
        look_vertical, auto_forward, height_speed,
        _checked_control_scalar(height_coef, "FirstPersonControls height_coef"),
        _checked_control_scalar(height_min, "FirstPersonControls height_min"),
        _checked_control_scalar(height_max, "FirstPersonControls height_max"),
        constrain_vertical,
        _checked_control_scalar(vertical_min, "FirstPersonControls vertical_min"),
        _checked_control_scalar(vertical_max, "FirstPersonControls vertical_max"),
        false, Vec3(0.0, 0.0, 0.0), 0.0, 0.0, 0.0, 0.0, 0,
        false, false, false, false, false, false, false, false,
        0.0, 0.0, 0.0, 0.0)
    _validate_first_person(fc)
    return _first_person_set_orientation!(fc)
end

function _validate_first_person(fc::FirstPersonControls)
    _checked_control_scalar(fc.movement_speed, "FirstPersonControls movement_speed")
    _checked_control_scalar(fc.look_speed, "FirstPersonControls look_speed")
    _checked_damping_factor(fc.damping_factor, "FirstPersonControls damping_factor")
    _checked_control_scalar(fc.height_coef, "FirstPersonControls height_coef")
    _checked_control_scalar(fc.height_min, "FirstPersonControls height_min")
    _checked_control_scalar(fc.height_max, "FirstPersonControls height_max")
    vmin = _checked_control_scalar(fc.vertical_min, "FirstPersonControls vertical_min")
    vmax = _checked_control_scalar(fc.vertical_max, "FirstPersonControls vertical_max")
    # verticalLookRatio = π / (verticalMax - verticalMin) has no value for an
    # empty range.
    (!fc.constrain_vertical || vmax != vmin) || throw(ArgumentError(
        "FirstPersonControls vertical_min and vertical_max must differ when constrain_vertical is set"))
    return nothing
end

# FirstPersonControls.js _setOrientation: latitude and longitude (degrees) of
# the camera's look direction.
function _first_person_set_orientation!(fc::FirstPersonControls)
    look = quat_rotate_vector(_camera_local_quaternion(fc.camera),
                              Vec3(0.0, 0.0, -1.0))
    s = cartesian_to_spherical(look)
    fc.lat = 90 - s.phi * _CONTROL_RAD2DEG
    fc.lon = s.theta * _CONTROL_RAD2DEG
    return fc
end

"""
    first_person_look_at!(controls::FirstPersonControls, target::Vec3)

Turn the camera toward `target` and take its new heading and pitch as the
look state (three.js `FirstPersonControls.lookAt`).
"""
function first_person_look_at!(fc::FirstPersonControls, target::Vec3)
    _camera_control_look_at!(fc.camera, target, "FirstPersonControls")
    return _first_person_set_orientation!(fc)
end

"""
    first_person_key_down!(controls::FirstPersonControls, code::AbstractString)

Press a key given by its `KeyboardEvent.code`, like three.js
`FirstPersonControls`: `"KeyW"`/`"ArrowUp"` forward, `"KeyS"`/`"ArrowDown"`
backward, `"KeyA"`/`"ArrowLeft"` left, `"KeyD"`/`"ArrowRight"` right, `"KeyR"`
up and `"KeyF"` down. Other codes are ignored.
"""
first_person_key_down!(fc::FirstPersonControls, code::AbstractString) =
    _first_person_key!(fc, code, true)

"""
    first_person_key_up!(controls::FirstPersonControls, code::AbstractString)

Release the key `code`; see [`first_person_key_down!`](@ref).
"""
first_person_key_up!(fc::FirstPersonControls, code::AbstractString) =
    _first_person_key!(fc, code, false)

function _first_person_key!(fc::FirstPersonControls, code::AbstractString,
                            pressed::Bool)
    if code == "ArrowUp" || code == "KeyW"
        fc.key_forward = pressed
    elseif code == "ArrowLeft" || code == "KeyA"
        fc.move_left = pressed
    elseif code == "ArrowDown" || code == "KeyS"
        fc.key_backward = pressed
    elseif code == "ArrowRight" || code == "KeyD"
        fc.move_right = pressed
    elseif code == "KeyR"
        fc.move_up = pressed
    elseif code == "KeyF"
        fc.move_down = pressed
    end
    return fc
end

@noinline function _throw_pointer_type(pointer_type)
    throw(ArgumentError("pointer_type must be :mouse, :pen or :touch, got $(repr(pointer_type))"))
end

@inline function _checked_pointer_type(pointer_type::Symbol)
    pointer_type === :mouse || pointer_type === :pen ||
        pointer_type === :touch || _throw_pointer_type(pointer_type)
    return pointer_type
end

"""
    first_person_pointer_down!(controls::FirstPersonControls, page_x, page_y;
                               button=0, pointer_type=:mouse)

A pointer goes down at page position `(page_x, page_y)` pixels (three.js
`pointerdown`). Button 0 moves forward and button 2 backward unless a
forward/backward key is held; with `pointer_type=:touch` one touch moves
forward and two or more move backward. Looking starts from this position.
"""
function first_person_pointer_down!(fc::FirstPersonControls, page_x, page_y;
                                    button::Integer=0,
                                    pointer_type::Symbol=:mouse)
    x = _checked_control_scalar(page_x, "FirstPersonControls page_x")
    y = _checked_control_scalar(page_y, "FirstPersonControls page_y")
    touch = _checked_pointer_type(pointer_type) === :touch
    fc.pointer_count += 1
    if touch
        fc.pointer_forward = fc.pointer_count == 1
        fc.pointer_backward = fc.pointer_count >= 2
    elseif button == 0
        (fc.key_forward || fc.key_backward) || (fc.pointer_forward = true)
    elseif button == 2
        (fc.key_forward || fc.key_backward) || (fc.pointer_backward = true)
    end
    fc.pointer_down_x = x
    fc.pointer_down_y = y
    fc.pointer_x = 0.0
    fc.pointer_y = 0.0
    fc.mouse_drag_on = true
    return fc
end

"""
    first_person_pointer_move!(controls::FirstPersonControls, page_x, page_y)

A pointer moves to page position `(page_x, page_y)` pixels while one is down
(three.js `pointermove`); its offset from the press position sets the look
velocity.
"""
function first_person_pointer_move!(fc::FirstPersonControls, page_x, page_y)
    x = _checked_control_scalar(page_x, "FirstPersonControls page_x")
    y = _checked_control_scalar(page_y, "FirstPersonControls page_y")
    fc.mouse_drag_on || return fc
    fc.pointer_x = x - fc.pointer_down_x
    fc.pointer_y = y - fc.pointer_down_y
    return fc
end

"""
    first_person_pointer_up!(controls::FirstPersonControls; button=0,
                             pointer_type=:mouse)

A pointer is released or cancelled (three.js `pointerup`/`pointercancel`).
Looking stops once no pointer is down.
"""
function first_person_pointer_up!(fc::FirstPersonControls; button::Integer=0,
                                  pointer_type::Symbol=:mouse)
    touch = _checked_pointer_type(pointer_type) === :touch
    fc.mouse_drag_on || return fc
    fc.pointer_count -= 1
    if touch
        fc.pointer_forward = fc.pointer_count == 1
        fc.pointer_backward = false
    elseif button == 0
        fc.pointer_forward = false
    elseif button == 2
        fc.pointer_backward = false
    end
    fc.pointer_x = 0.0
    fc.pointer_y = 0.0
    fc.pointer_count == 0 && (fc.mouse_drag_on = false)
    return fc
end

"""
    first_person_update!(controls::FirstPersonControls, delta)

Advance the controls by `delta` seconds (three.js
`FirstPersonControls.update`): ease the velocity toward the key and pointer
input, move the camera by it, ease the look velocity toward the pointer
offset, and aim the camera at the resulting heading and pitch. Does nothing
while `enabled` is false.
"""
function first_person_update!(fc::FirstPersonControls, delta)
    fc.enabled || return fc
    _validate_first_person(fc)
    dt = _checked_control_scalar(delta, "FirstPersonControls delta")
    cam = fc.camera
    look = quat_rotate_vector(_camera_local_quaternion(cam), Vec3(0.0, 0.0, -1.0))
    drive = Int(fc.key_forward) - Int(fc.key_backward)
    look_move = Int(fc.pointer_forward) - Int(fc.pointer_backward)
    fc.auto_forward && drive == 0 && look_move == 0 && (look_move = 1)
    speed = fc.movement_speed
    forward_speed = speed
    if fc.height_speed
        # MathUtils.clamp(y, min, max) = max(min, min(max, y)).
        y = max(fc.height_min, min(fc.height_max, cam.position.y))
        forward_speed += (y - fc.height_min) * fc.height_coef
    end
    yaw = fc.lon * _CONTROL_DEG2RAD
    sin_yaw, cos_yaw = sin(yaw), cos(yaw)
    strafe = Float64(Int(fc.move_right) - Int(fc.move_left))
    climb = Float64(Int(fc.move_up) - Int(fc.move_down))
    drive_f = Float64(drive)
    key_scale = 1 / max(1.0, sqrt(strafe * strafe + climb * climb + drive_f * drive_f))
    strafe *= speed * key_scale
    climb *= speed * key_scale
    drive_f *= (drive_f > 0 ? forward_speed : speed) * key_scale
    target_velocity = Vec3(sin_yaw * drive_f - cos_yaw * strafe, climb,
                           cos_yaw * drive_f + sin_yaw * strafe)
    if look_move != 0
        s = look_move * (look_move > 0 ? forward_speed : speed)
        target_velocity = Vec3(target_velocity.x + look.x * s,
                               target_velocity.y + look.y * s,
                               target_velocity.z + look.z * s)
    end
    # Vector3.lerp: v += (target - v) * alpha.
    f = fc.damping_factor
    v = fc.velocity
    velocity = Vec3(v.x + (target_velocity.x - v.x) * f,
                    v.y + (target_velocity.y - v.y) * f,
                    v.z + (target_velocity.z - v.z) * f)
    p = cam.position
    position = _checked_control_vec3(
        Vec3(p.x + velocity.x * dt, p.y + velocity.y * dt, p.z + velocity.z * dt),
        "FirstPersonControls camera position")
    vertical_ratio = fc.constrain_vertical ?
        Float64(π) / (fc.vertical_max - fc.vertical_min) : 1.0
    target_lon = fc.mouse_drag_on ? -fc.pointer_x * fc.look_speed : 0.0
    target_lat = (fc.mouse_drag_on && fc.look_vertical) ?
        -fc.pointer_y * fc.look_speed * vertical_ratio : 0.0
    # MathUtils.lerp(x, y, t) = (1 - t) * x + t * y.
    lon_velocity = (1 - f) * fc.lon_velocity + f * target_lon
    lat_velocity = (1 - f) * fc.lat_velocity + f * target_lat
    lon = fc.lon + lon_velocity * dt
    lat = max(-85.0, min(85.0, fc.lat + lat_velocity * dt))
    phi = (90 - lat) * _CONTROL_DEG2RAD
    theta = lon * _CONTROL_DEG2RAD
    if fc.constrain_vertical
        # MathUtils.mapLinear(phi, 0, π, verticalMin, verticalMax).
        phi = fc.vertical_min + phi * (fc.vertical_max - fc.vertical_min) / Float64(π)
    end
    look_target = _checked_control_vec3(
        position + spherical_to_cartesian(Spherical(1.0, phi, theta)),
        "FirstPersonControls look target")
    _checked_control_vec3(velocity, "FirstPersonControls velocity")
    _checked_control_scalar(lon, "FirstPersonControls longitude")
    _checked_control_scalar(lat, "FirstPersonControls latitude")
    fc.velocity = velocity
    fc.lon_velocity = lon_velocity
    fc.lat_velocity = lat_velocity
    fc.lon = lon
    fc.lat = lat
    cam.position = position
    _camera_control_look_at!(cam, look_target, "FirstPersonControls")
    return fc
end

# DragControls: programmatic object selection and world-space drag movement,
# with a perspective or orthographic camera like three.js.
mutable struct DragControls
    objects::Vector{AbstractObject3D}
    camera::_OrbitCamera
    selected::Union{Nothing, AbstractObject3D}
    recursive::Bool
    transform_group::Bool
    raycaster::Raycaster
    # three.js DragControls pointer input (see drag_pointer_down!).
    enabled::Bool
    rotate_speed::Float64
    mouse_buttons::NamedTuple{(:left, :middle, :right), NTuple{3, Symbol}}
    touches::NamedTuple{(:one,), Tuple{Symbol}}
    element_left::Float64
    element_top::Float64
    element_width::Float64
    element_height::Float64
    state::Symbol
    hovered::Union{Nothing, AbstractObject3D}
    previous_pointer::NTuple{2, Float64}
    plane_normal::Vec3{Float64}
    plane_constant::Float64
    offset::Vec3{Float64}
    parent_inverse::Mat4{Float64}
    rotate_up::Vec3{Float64}
    rotate_right::Vec3{Float64}
end

const _DRAG_DEFAULT_MOUSE_BUTTONS = (left=:pan, middle=:pan, right=:rotate)
const _DRAG_DEFAULT_TOUCHES = (one=:pan,)
const _DRAG_ACTIONS = (:pan, :rotate, :none)

DragControls(objects::Vector{AbstractObject3D}, camera::_OrbitCamera,
             selected::Union{Nothing, AbstractObject3D}, recursive::Bool,
             transform_group::Bool, raycaster::Raycaster) =
    DragControls(objects, camera, selected, recursive, transform_group, raycaster,
                 true, 1.0, _DRAG_DEFAULT_MOUSE_BUTTONS, _DRAG_DEFAULT_TOUCHES,
                 0.0, 0.0, 0.0, 0.0, :none, nothing, (0.0, 0.0),
                 Vec3(0.0, 0.0, 1.0), 0.0, Vec3(), Mat4(),
                 Vec3(), Vec3())

"""
    DragControls(objects, camera; recursive=true, transform_group=false,
                 raycaster=nothing, enabled=true, rotate_speed=1.0,
                 mouse_buttons=(left=:pan, middle=:pan, right=:rotate),
                 touches=(one=:pan,), element_left=0.0, element_top=0.0,
                 element_width=0.0, element_height=0.0)

Drag managed `objects` with a perspective or orthographic camera (three.js
`DragControls`). [`drag_start!`](@ref), [`drag_pick_start!`](@ref),
[`drag_move!`](@ref) and [`drag_end!`](@ref) move objects programmatically.
[`drag_pointer_down!`](@ref), [`drag_pointer_move!`](@ref) and
[`drag_pointer_up!`](@ref) reproduce three.js r186 pointer handling instead:
`mouse_buttons` and `touches` map to `:pan` (move on the camera-facing plane
through the object), `:rotate` (turn it about the camera's up and right axes
by `rotate_speed` radians per unit of NDC movement) or `:none`, and pointer
coordinates are client pixels inside the element rectangle `element_left`,
`element_top`, `element_width`, `element_height` (the last two must be
positive for pointer input).
"""
function DragControls(objects::AbstractVector{<:AbstractObject3D}, camera::_OrbitCamera;
                      recursive::Bool=true, transform_group::Bool=false,
                      raycaster::Union{Nothing,Raycaster}=nothing,
                      enabled::Bool=true, rotate_speed::Real=1.0,
                      mouse_buttons::NamedTuple=_DRAG_DEFAULT_MOUSE_BUTTONS,
                      touches::NamedTuple=_DRAG_DEFAULT_TOUCHES,
                      element_left::Real=0.0, element_top::Real=0.0,
                      element_width::Real=0.0, element_height::Real=0.0)
    rc = raycaster === nothing ?
        Raycaster(camera.position, Vec3(0.0, 0.0, -1.0)) : raycaster
    dc = DragControls(collect(AbstractObject3D, objects), camera, nothing,
                      recursive, transform_group, rc)
    dc.enabled = enabled
    dc.rotate_speed = _checked_control_scalar(rotate_speed, "DragControls rotate_speed")
    dc.mouse_buttons = _checked_drag_mouse_buttons(mouse_buttons)
    dc.touches = _checked_drag_touches(touches)
    dc.element_left = _checked_control_scalar(element_left, "DragControls element_left")
    dc.element_top = _checked_control_scalar(element_top, "DragControls element_top")
    dc.element_width = _checked_control_scalar(element_width, "DragControls element_width")
    dc.element_height = _checked_control_scalar(element_height, "DragControls element_height")
    return dc
end

function _checked_drag_action(action, label::String)
    action isa Symbol && action in _DRAG_ACTIONS || throw(ArgumentError(
        "DragControls $label actions must be :pan, :rotate or :none"))
    return action
end

function _checked_drag_mouse_buttons(buttons::NamedTuple)
    keys(buttons) == (:left, :middle, :right) || throw(ArgumentError(
        "DragControls mouse_buttons must be a NamedTuple (left=, middle=, right=)"))
    return (left=_checked_drag_action(buttons.left, "mouse_buttons"),
            middle=_checked_drag_action(buttons.middle, "mouse_buttons"),
            right=_checked_drag_action(buttons.right, "mouse_buttons"))
end

function _checked_drag_touches(touches::NamedTuple)
    keys(touches) == (:one,) || throw(ArgumentError(
        "DragControls touches must be a NamedTuple (one=,)"))
    return (one=_checked_drag_action(touches.one, "touches"),)
end

function _drag_contains(root::AbstractObject3D, obj::AbstractObject3D)
    found = false
    traverse(root, child -> begin
        child === obj && (found = true)
    end)
    return found
end

function _drag_select_target(dc::DragControls, obj::AbstractObject3D)
    if obj in dc.objects
        return dc.transform_group && length(dc.objects) == 1 ? dc.objects[1] : obj
    end
    if dc.recursive
        for root in dc.objects
            if _drag_contains(root, obj)
                return dc.transform_group && length(dc.objects) == 1 ? root : obj
            end
        end
    end
    throw(ArgumentError("object is not managed by DragControls"))
end

function drag_start!(dc::DragControls, obj::AbstractObject3D)
    dc.selected = _drag_select_target(dc, obj)
    return dc
end

function drag_pick_start!(dc::DragControls, ndc_x, ndc_y)
    set_from_camera!(dc.raycaster, dc.camera, Float64(ndc_x), Float64(ndc_y))
    hits = Intersection[]
    for obj in dc.objects
        append!(hits, raycast(dc.raycaster, obj; recursive=dc.recursive))
    end
    sort!(hits, by=h -> h.distance)
    if isempty(hits)
        dc.selected = nothing
    else
        dc.selected = _drag_select_target(dc, first(hits).object)
    end
    return dc
end

function drag_move!(dc::DragControls, delta::Vec3)
    obj = dc.selected
    obj === nothing && return dc
    _validate_object_transform(obj)
    checked_delta = _checked_control_vec3(delta, "DragControls delta")
    parent_delta = _transform_world_delta_to_parent(obj, checked_delta)
    position = _checked_control_vec3(
        obj.position + parent_delta, "DragControls object position")
    obj.position = position
    return dc
end

drag_end!(dc::DragControls) = (dc.selected = nothing; dc)

# ---- DragControls pointer input (three.js DragControls.js r186) ------------

function _validate_drag_input(dc::DragControls)
    _checked_control_scalar(dc.rotate_speed, "DragControls rotate_speed")
    _checked_drag_mouse_buttons(dc.mouse_buttons)
    _checked_drag_touches(dc.touches)
    left = _checked_control_scalar(dc.element_left, "DragControls element_left")
    top = _checked_control_scalar(dc.element_top, "DragControls element_top")
    width = _checked_control_scalar(dc.element_width, "DragControls element_width")
    height = _checked_control_scalar(dc.element_height, "DragControls element_height")
    (width > 0.0 && height > 0.0) || throw(ArgumentError(
        "DragControls pointer input needs a positive element_width and element_height"))
    return left, top, width, height
end

# DragControls._updatePointer: client pixels to NDC.
function _drag_pointer_ndc(dc::DragControls, x, y)
    left, top, width, height = _validate_drag_input(dc)
    px = _checked_control_scalar(x, "DragControls pointer x")
    py = _checked_control_scalar(y, "DragControls pointer y")
    return (px - left) / width * 2 - 1, -(py - top) / height * 2 + 1
end

# Raycaster.intersectObjects(objects, recursive): hits sorted by distance.
function _drag_intersections(dc::DragControls, ndc)
    set_from_camera!(dc.raycaster, dc.camera, ndc[1], ndc[2])
    hits = Intersection[]
    for obj in dc.objects
        append!(hits, raycast(dc.raycaster, obj; recursive=dc.recursive))
    end
    sort!(hits, by=h -> h.distance)
    return hits
end

# DragControls.js findGroup: the outermost Group above (or at) `obj`, or
# nothing when it has no Group ancestor.
function _drag_find_group(obj::AbstractObject3D)
    group = nothing
    node = obj
    while node !== nothing
        node isa Group && (group = node)
        node = get_parent(node)
    end
    return group
end

_drag_world_position(obj::AbstractObject3D) =
    mat4_get_position(compute_world_matrix(obj)::Mat4{Float64})

# Plane.setFromNormalAndCoplanarPoint(camera.getWorldDirection(), point).
function _drag_set_plane!(dc::DragControls, point::Vec3)
    q = _camera_local_quaternion(dc.camera)
    normal = quat_rotate_vector(q, Vec3(0.0, 0.0, -1.0))
    dc.plane_normal = normal
    dc.plane_constant = -dot(point, normal)
    return dc
end

function _drag_ray_plane(dc::DragControls)
    ray = dc.raycaster.ray
    return _orbit_ray_plane(ray.origin, ray.direction, dc.plane_normal,
                            dc.plane_normal * -dc.plane_constant)
end

"""
    drag_pointer_down!(controls::DragControls, x, y; button=0, pointer_type=:mouse)

three.js `DragControls` `pointerdown` at client pixel `(x, y)`. The button
(0 left, 1 middle, 2 right) or, for `pointer_type=:touch`, `touches.one`
selects the action through `mouse_buttons`. The nearest object hit among
`objects` (with their descendants when `recursive`) becomes `selected`, or,
with `transform_group`, its outermost `Group` ancestor (nothing is selected
when there is none, where three.js throws). A miss leaves `selected` as it was,
like three.js.
"""
function drag_pointer_down!(dc::DragControls, x, y; button::Integer=0,
                            pointer_type::Symbol=:mouse)
    dc.enabled || return dc
    _checked_pointer_type(pointer_type)
    ndc = _drag_pointer_ndc(dc, x, y)
    # DragControls._updateState.
    action = if pointer_type === :touch
        dc.touches.one
    elseif button == 0
        dc.mouse_buttons.left
    elseif button == 1
        dc.mouse_buttons.middle
    elseif button == 2
        dc.mouse_buttons.right
    else
        :none
    end
    dc.state = action
    hits = _drag_intersections(dc, ndc)
    if !isempty(hits)
        hit = first(hits).object
        selected = dc.transform_group ? _drag_find_group(hit) : hit
        if selected === nothing
            dc.selected = nothing
        else
            world_position = _drag_world_position(selected)
            _drag_set_plane!(dc, world_position)
            intersection = _drag_ray_plane(dc)
            if intersection !== nothing
                if dc.state === :pan
                    parent = get_parent(selected)
                    inverse = parent === nothing ? Mat4() :
                        mat4_inverse(compute_world_matrix(parent)::Mat4{Float64})
                    all(iszero, inverse.e) && throw(ArgumentError(
                        "DragControls cannot pan an object whose parent has a singular world matrix"))
                    dc.parent_inverse = inverse
                    dc.offset = intersection - world_position
                elseif dc.state === :rotate
                    # "the controls only support Y+ up" (DragControls.js).
                    q = _camera_local_quaternion(dc.camera)
                    dc.rotate_up = normalize(quat_rotate_vector(q, Vec3(0.0, 1.0, 0.0)))
                    dc.rotate_right = normalize(quat_rotate_vector(q, Vec3(1.0, 0.0, 0.0)))
                end
            end
            dc.selected = selected
        end
    end
    dc.previous_pointer = ndc
    return dc
end

"""
    drag_pointer_move!(controls::DragControls, x, y; pointer_type=:mouse)

three.js `DragControls` `pointermove` at client pixel `(x, y)`. With a
selection, `:pan` moves it so the point grabbed on the camera-facing plane
follows the pointer, and `:rotate` turns it about the camera's up axis by the
NDC x movement and about its right axis by minus the NDC y movement, both
times `rotate_speed` (three.js `rotateOnWorldAxis`, exact for an unrotated
parent). Without a selection a mouse or pen updates `hovered`.
"""
function drag_pointer_move!(dc::DragControls, x, y; pointer_type::Symbol=:mouse)
    dc.enabled || return dc
    _checked_pointer_type(pointer_type)
    ndc = _drag_pointer_ndc(dc, x, y)
    set_from_camera!(dc.raycaster, dc.camera, ndc[1], ndc[2])
    selected = dc.selected
    if selected !== nothing
        if dc.state === :pan
            intersection = _drag_ray_plane(dc)
            if intersection !== nothing
                position = mat4_transform_point(dc.parent_inverse, intersection - dc.offset)
                _validate_object_transform(selected)
                selected.position = _checked_control_vec3(
                    position, "DragControls object position")
            end
        elseif dc.state === :rotate
            dx = (ndc[1] - dc.previous_pointer[1]) * dc.rotate_speed
            dy = (ndc[2] - dc.previous_pointer[2]) * dc.rotate_speed
            rotate_on_world_axis!(selected, dc.rotate_up, dx)
            dc.rotate_right = normalize(dc.rotate_right)
            rotate_on_world_axis!(selected, dc.rotate_right, -dy)
        end
    elseif pointer_type === :mouse || pointer_type === :pen
        hits = _drag_intersections(dc, ndc)
        if isempty(hits)
            dc.hovered = nothing
        else
            hovered = first(hits).object
            _drag_set_plane!(dc, _drag_world_position(hovered))
            dc.hovered = hovered
        end
    end
    dc.previous_pointer = ndc
    return dc
end

"""
    drag_pointer_up!(controls::DragControls)

three.js `DragControls` `pointerup`, `pointerleave` or `pointercancel`:
release the selection and return to the idle state.
"""
function drag_pointer_up!(dc::DragControls)
    dc.enabled || return dc
    dc.selected = nothing
    dc.state = :none
    return dc
end

# TransformControls: attach one object and apply translate/rotate/scale deltas;
# like three.js it accepts a perspective or orthographic camera.
mutable struct TransformControls
    camera::_OrbitCamera
    object::Union{Nothing, AbstractObject3D}
    mode::Symbol
    space::Symbol
    enabled::Bool
    axis::Union{Nothing, Symbol}
    translation_snap::Union{Nothing, Float64}
    rotation_snap::Union{Nothing, Float64}
    scale_snap::Union{Nothing, Float64}
end

function _transform_validate_mode(mode::Symbol)
    mode in (:translate, :rotate, :scale) ||
        throw(ArgumentError("unsupported transform mode: $mode"))
    return mode
end

function _transform_validate_space(space::Symbol)
    space in (:world, :local) ||
        throw(ArgumentError("unsupported transform space: $space"))
    return space
end

function _transform_validate_axis(axis::Union{Nothing,Symbol})
    axis === nothing && return axis
    axis in (:X, :Y, :Z, :XY, :YZ, :XZ, :XYZ) ||
        throw(ArgumentError("unsupported transform axis: $axis"))
    return axis
end

function _transform_validate_snap(snap::Union{Nothing,Real}, label::String)
    snap === nothing && return nothing
    snap isa Bool &&
        throw(ArgumentError("TransformControls $label snap must be finite and positive"))
    value = Float64(snap)
    isfinite(value) && value > 0 ||
        throw(ArgumentError("TransformControls $label snap must be finite and positive"))
    return value
end

function _validate_transform_runtime(tc::TransformControls)
    _transform_validate_mode(tc.mode)
    _transform_validate_space(tc.space)
    _transform_validate_axis(tc.axis)
    _transform_validate_snap(tc.translation_snap, "translation")
    _transform_validate_snap(tc.rotation_snap, "rotation")
    _transform_validate_snap(tc.scale_snap, "scale")
    return nothing
end

function TransformControls(camera::_OrbitCamera;
                           mode::Symbol=:translate,
                           space::Symbol=:world,
                           enabled::Bool=true,
                           axis::Union{Nothing,Symbol}=:XYZ,
                           translation_snap::Union{Nothing,Real}=nothing,
                           rotation_snap::Union{Nothing,Real}=nothing,
                           scale_snap::Union{Nothing,Real}=nothing)
    return TransformControls(camera, nothing,
                             _transform_validate_mode(mode),
                             _transform_validate_space(space),
                             enabled,
                             _transform_validate_axis(axis),
                             _transform_validate_snap(translation_snap, "translation"),
                             _transform_validate_snap(rotation_snap, "rotation"),
                             _transform_validate_snap(scale_snap, "scale"))
end

TransformControls(camera::_OrbitCamera,
                  object::Union{Nothing, AbstractObject3D},
                  mode::Symbol,
                  space::Symbol) =
    TransformControls(camera, object,
                      _transform_validate_mode(mode),
                      _transform_validate_space(space),
                      true, :XYZ, nothing, nothing, nothing)

transform_attach!(tc::TransformControls, obj::AbstractObject3D) = (tc.object = obj; tc)
transform_detach!(tc::TransformControls) = (tc.object = nothing; tc)
function transform_set_mode!(tc::TransformControls, mode::Symbol)
    tc.mode = _transform_validate_mode(mode)
    return tc
end
function transform_set_space!(tc::TransformControls, space::Symbol)
    tc.space = _transform_validate_space(space)
    return tc
end
function transform_set_enabled!(tc::TransformControls, enabled::Bool)
    tc.enabled = enabled
    return tc
end
function transform_set_axis!(tc::TransformControls, axis::Union{Nothing,Symbol})
    tc.axis = _transform_validate_axis(axis)
    return tc
end
function transform_set_translation_snap!(tc::TransformControls, snap::Union{Nothing,Real})
    tc.translation_snap = _transform_validate_snap(snap, "translation")
    return tc
end
function transform_set_rotation_snap!(tc::TransformControls, snap::Union{Nothing,Real})
    tc.rotation_snap = _transform_validate_snap(snap, "rotation")
    return tc
end
function transform_set_scale_snap!(tc::TransformControls, snap::Union{Nothing,Real})
    tc.scale_snap = _transform_validate_snap(snap, "scale")
    return tc
end

function _transform_local_delta(obj::AbstractObject3D, delta::Vec3)
    rot = get_rotation(obj)
    q = quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)
    return mat4_transform_direction(quat_to_mat4(q), delta)
end

function _transform_world_delta_to_parent(obj::AbstractObject3D,
                                          delta::Vec3)
    parent = get_parent(obj)
    parent === nothing && return delta
    parent_world = compute_world_matrix(parent)::Mat4{Float64}
    parent_inverse = mat4_inverse(parent_world)
    if !all(iszero, parent_inverse.e)
        return mat4_transform_direction(parent_inverse, delta)
    end
    return _transform_singular_world_vector_to_parent(
        parent_world, delta, Vec3(), "world-space movement")
end

function _transform_world_position_to_parent(obj::AbstractObject3D,
                                             position::Vec3)
    parent = get_parent(obj)
    parent === nothing && return position
    parent_world = compute_world_matrix(parent)::Mat4{Float64}
    parent_inverse = mat4_inverse(parent_world)
    if !all(iszero, parent_inverse.e)
        return mat4_transform_point(parent_inverse, position)
    end
    translation = Vec3(mat4_get(parent_world, 1, 4),
                       mat4_get(parent_world, 2, 4),
                       mat4_get(parent_world, 3, 4))
    return _transform_singular_world_vector_to_parent(
        parent_world, position - translation, obj.position,
        "world-space snapped position")
end

function _transform_singular_world_vector_to_parent(
        parent_world::Mat4, world_vector::Vec3, seed::Vec3,
        label::String)
    linear = Matrix{Float64}(undef, 3, 3)
    @inbounds for column in 1:3, row in 1:3
        linear[row, column] = mat4_get(parent_world, row, column)
    end
    all(isfinite, linear) ||
        throw(ArgumentError("$label cannot be represented by the parent transform"))

    # A singular parent has no ordinary inverse.  The pseudoinverse supplies
    # the minimum-norm local vector; for positions, retain the object's
    # existing null-space component so snapping does not change collapsed
    # local coordinates that have no world-space effect.
    pseudo = la_pinv(linear; rtol=0.0)
    rhs = Float64[world_vector.x, world_vector.y, world_vector.z]
    local_values = pseudo * rhs
    if !iszero(seed.x) || !iszero(seed.y) || !iszero(seed.z)
        seed_values = Float64[seed.x, seed.y, seed.z]
        local_values .+= seed_values - pseudo * (linear * seed_values)
    end
    local_vector = Vec3(local_values[1], local_values[2], local_values[3])
    reconstructed = mat4_transform_direction(parent_world, local_vector)
    scale = max(abs(world_vector.x), abs(world_vector.y),
                abs(world_vector.z), abs(reconstructed.x),
                abs(reconstructed.y), abs(reconstructed.z))
    error = if iszero(scale)
        0.0
    else
        max(abs(reconstructed.x / scale - world_vector.x / scale),
            abs(reconstructed.y / scale - world_vector.y / scale),
            abs(reconstructed.z / scale - world_vector.z / scale))
    end
    (isfinite(local_vector.x) && isfinite(local_vector.y) &&
     isfinite(local_vector.z) &&
     isfinite(error) && error <= 256 * eps(Float64)) ||
        throw(ArgumentError("$label cannot be represented by the parent transform"))
    return local_vector
end

function _transform_parent_position_to_world(obj::AbstractObject3D,
                                             position::Vec3)
    parent = get_parent(obj)
    parent === nothing && return position
    return mat4_transform_point(compute_world_matrix(parent), position)
end

@inline _transform_unit_quaternion_inverse(q::Quaternion) =
    Quaternion(-q.x, -q.y, -q.z, q.w)

function _transform_parent_world_quaternion(
        obj::AbstractObject3D)::Quaternion{Float64}
    world = Quaternion()
    parent = get_parent(obj)
    while parent !== nothing
        _validate_object_transform(parent)
        rotation = get_rotation(parent)::Euler{Float64}
        local_rotation = quat_from_euler(
            rotation.x, rotation.y, rotation.z; order=rotation.order)
        world = quat_multiply(local_rotation, world)
        parent = get_parent(parent)
    end
    return quat_normalize(world)
end

@inline function _transform_world_rotation_to_parent(
        obj::AbstractObject3D,
        world_delta::Quaternion{Float64})::Quaternion{Float64}
    parent = get_parent(obj)
    parent === nothing && return world_delta
    world = compute_world_matrix(parent)::Mat4{Float64}
    c1 = Vec3(mat4_get(world, 1, 1), mat4_get(world, 2, 1),
              mat4_get(world, 3, 1))
    c2 = Vec3(mat4_get(world, 1, 2), mat4_get(world, 2, 2),
              mat4_get(world, 3, 2))
    c3 = Vec3(mat4_get(world, 1, 3), mat4_get(world, 2, 3),
              mat4_get(world, 3, 3))
    l1, l2, l3 = norm(c1), norm(c2), norm(c3)
    u1, u2, u3 = normalize(c1), normalize(c2), normalize(c3)
    orientation = _mat4_linear_orientation_sign(world)
    if iszero(l1) || iszero(l2) || iszero(l3) || iszero(orientation)
        parent_rotation = _transform_parent_world_quaternion(obj)
        parent_inverse = _transform_unit_quaternion_inverse(parent_rotation)
        return quat_multiply(
            quat_multiply(parent_inverse, world_delta), parent_rotation)
    end

    vector = Vec3(world_delta.x, world_delta.y, world_delta.z)
    mapped = Vec3(
        orientation * dot(u1, vector),
        orientation * dot(u2, vector),
        orientation * dot(u3, vector),
    )
    source_length = norm(vector)
    mapped_length = norm(mapped)
    if iszero(source_length) || iszero(mapped_length)
        return Quaternion(0.0, 0.0, 0.0, world_delta.w)
    end
    mapped = mapped * (source_length / mapped_length)
    return quat_normalize(Quaternion(
        mapped.x, mapped.y, mapped.z, world_delta.w))
end

function _transform_quaternion_to_euler(q::Quaternion, order::Symbol)
    return _rotation_matrix_to_euler(quat_to_mat4(quat_normalize(q)), order)
end

@inline _transform_axis_has(::Nothing, ::Char) = false
@inline function _transform_axis_has(axis::Symbol, label::Char)
    if label == 'X'
        return axis === :X || axis === :XY || axis === :XZ || axis === :XYZ
    elseif label == 'Y'
        return axis === :Y || axis === :XY || axis === :YZ || axis === :XYZ
    elseif label == 'Z'
        return axis === :Z || axis === :XZ || axis === :YZ || axis === :XYZ
    end
    return false
end

function _transform_axis_vec(axis::Union{Nothing,Symbol}, delta::Vec3;
                             default::Float64=0.0)
    axis === nothing && return Vec3(default, default, default)
    return Vec3(_transform_axis_has(axis, 'X') ? delta.x : default,
                _transform_axis_has(axis, 'Y') ? delta.y : default,
                _transform_axis_has(axis, 'Z') ? delta.z : default)
end

@inline function _transform_snap_value(value::Real, snap::Float64)
    finite_value = Float64(value)
    quotient = finite_value / snap
    isfinite(quotient) && return round(quotient) * snap

    # The quotient may overflow even though the nearest snapped value is finite.
    # IEEE remainder with RoundNearest performs the same ties-to-even quotient
    # selection without materializing that quotient.
    return finite_value - rem(finite_value, snap, RoundNearest)
end

function _transform_snap_position(pos::Vec3, snap::Float64,
                                  axis::Union{Nothing,Symbol})
    axis === nothing && return pos
    return Vec3(_transform_axis_has(axis, 'X') ? _transform_snap_value(pos.x, snap) : pos.x,
                _transform_axis_has(axis, 'Y') ? _transform_snap_value(pos.y, snap) : pos.y,
                _transform_axis_has(axis, 'Z') ? _transform_snap_value(pos.z, snap) : pos.z)
end

function _transform_snap_scale_value(value::Real, snap::Float64)
    snapped = _transform_snap_value(value, snap)
    return snapped == 0.0 ? snap : snapped
end

function _transform_snap_scale(scale::Vec3, snap::Float64,
                               axis::Union{Nothing,Symbol})
    axis === nothing && return scale
    return Vec3(_transform_axis_has(axis, 'X') ? _transform_snap_scale_value(scale.x, snap) : scale.x,
                _transform_axis_has(axis, 'Y') ? _transform_snap_scale_value(scale.y, snap) : scale.y,
                _transform_axis_has(axis, 'Z') ? _transform_snap_scale_value(scale.z, snap) : scale.z)
end

function transform_apply!(tc::TransformControls, delta::Vec3)
    obj = tc.object
    (obj === nothing || !tc.enabled || tc.axis === nothing) && return tc
    _validate_transform_runtime(tc)
    _validate_object_transform(obj)
    checked_delta = _checked_control_vec3(delta, "TransformControls delta")
    if tc.mode === :translate
        axis_delta = _transform_axis_vec(tc.axis, checked_delta)
        move = tc.space === :local ? _transform_local_delta(obj, axis_delta) :
               _transform_world_delta_to_parent(obj, axis_delta)
        position = obj.position + move
        if tc.translation_snap !== nothing
            if tc.space === :world
                world_position = _transform_parent_position_to_world(
                    obj, position)
                world_position = _transform_snap_position(
                    world_position, tc.translation_snap, tc.axis)
                position = _transform_world_position_to_parent(
                    obj, world_position)
            else
                rotation = quat_to_mat4(quat_from_euler(
                    obj.rotation.x, obj.rotation.y, obj.rotation.z;
                    order=obj.rotation.order))
                local_position = mat4_transform_direction(
                    mat4_transpose(rotation), position)
                local_position = _transform_snap_position(
                    local_position, tc.translation_snap, tc.axis)
                position = mat4_transform_direction(rotation, local_position)
            end
        end
        obj.position = _checked_control_vec3(
            position, "TransformControls object position")
    elseif tc.mode === :scale
        factors = _transform_axis_vec(tc.axis, checked_delta; default=1.0)
        scale = Vec3(obj.scale.x * factors.x, obj.scale.y * factors.y,
                     obj.scale.z * factors.z)
        tc.scale_snap !== nothing &&
            (scale = _transform_snap_scale(scale, tc.scale_snap, tc.axis))
        obj.scale = _checked_control_vec3(
            scale, "TransformControls object scale")
    elseif tc.mode === :rotate
        angles = _transform_axis_vec(tc.axis, checked_delta)
        if tc.rotation_snap !== nothing
            angles = Vec3(_transform_axis_has(tc.axis, 'X') ?
                          _transform_snap_value(angles.x, tc.rotation_snap) : angles.x,
                          _transform_axis_has(tc.axis, 'Y') ?
                          _transform_snap_value(angles.y, tc.rotation_snap) : angles.y,
                          _transform_axis_has(tc.axis, 'Z') ?
                          _transform_snap_value(angles.z, tc.rotation_snap) : angles.z)
        end
        object_rotation = get_rotation(obj)::Euler{Float64}
        order = object_rotation.order
        current = quat_from_euler(
            object_rotation.x, object_rotation.y, object_rotation.z;
            order=order)::Quaternion{Float64}
        delta_rotation = quat_from_euler(
            angles.x, angles.y, angles.z; order=order)::Quaternion{Float64}
        rotated::Quaternion{Float64} = if tc.space === :local
            quat_multiply(current, delta_rotation)
        else
            parent_delta = _transform_world_rotation_to_parent(
                obj, delta_rotation)
            quat_multiply(parent_delta, current)
        end
        euler = _transform_quaternion_to_euler(
            quat_normalize(rotated), order)::Euler{Float64}
        rotation = _checked_control_vec3(
            Vec3(euler.x, euler.y, euler.z),
            "TransformControls object rotation")
        obj.rotation = Euler(rotation.x, rotation.y, rotation.z, order)
    end
    return tc
end

# ---- ArcballControls (three.js r186 examples/jsm/controls/ArcballControls.js) ----

# A PointerEvent as ArcballControls keeps it in _touchStart, _touchCurrent and
# _downEvents: pointerId, clientX, clientY and timeStamp (milliseconds).
struct _ArcballPointer
    id::Int
    x::Float64
    y::Float64
    time::Float64
end

# A pending requestAnimationFrame callback. `kind` names the closure three.js
# schedules (ArcballControls.js:866 :rotate_start, 2161 :rotate, 931
# :focus_start, 2110 :focus); the other fields hold what that closure captured.
# A :focus frame with `gizmo_matrix === nothing` clones the live
# _gizmoMatrixState when it runs (the first frame passes that matrix itself).
struct _ArcballFrame
    id::Int
    kind::Symbol
    axis::Vec3{Float64}
    w::Float64
    point::Vec3{Float64}
    gizmo_matrix::Union{Nothing, Mat4{Float64}}
end

const _ArcballMouseAction = NamedTuple{(:operation, :mouse, :key),
    Tuple{Symbol, Union{Int, Symbol}, Union{Nothing, Symbol}}}

# Fixed parameters of ArcballControls.js r186 (constructor, :221-224, :208,
# :1090, :3385, :736, :861, :93, :236).
const _ARCBALL_MAX_DOWN_TIME = 250.0
const _ARCBALL_MAX_INTERVAL = 300.0
const _ARCBALL_POS_THRESHOLD = 24.0
const _ARCBALL_MOVEMENT_THRESHOLD = 24.0
const _ARCBALL_SWITCH_SENSIBILITY = 32.0
const _ARCBALL_MIN_FINGER_DISTANCE = 12.0
const _ARCBALL_NOTCH_DELTA_Y = 125.0
const _ARCBALL_SCREEN_NOTCHES = 8.0
const _ARCBALL_INERTIA_WINDOW = 120.0
const _ARCBALL_EPS = 0.000001
const _ARCBALL_CURVE_POINTS = 128

"""
    ArcballControls(camera[, scene]; target=Vec3(0.0, 0.0, 0.0), enabled=true,
                    enable_pan=true, enable_rotate=true, enable_zoom=true,
                    enable_gizmos=true, enable_focus=true,
                    enable_animations=true, enable_grid=false,
                    adjust_near_far=false, cursor_zoom=false,
                    radius_factor=0.67, scale_factor=1.1, damping_factor=25.0,
                    w_max=20.0, focus_animation_time=500.0,
                    min_fov=5π/180, max_fov=π/2, rotate_speed=1.0,
                    min_distance=0.0, max_distance=Inf, min_zoom=0.0,
                    max_zoom=Inf, element_left=0.0, element_top=0.0,
                    element_width=0.0, element_height=0.0,
                    device_pixel_ratio=1.0)

three.js r186 `ArcballControls` for a `PerspectiveCamera` or an
`OrthographicCamera`: the camera turns on a virtual trackball around the
gizmo centre (`target`), with the Holroyd sphere/hyperboloid unprojection of
the pointer, pans in the plane through the centre, zooms (dollies a
perspective camera, changes the zoom of an orthographic one), changes the FOV
in a vertigo style, rolls with two fingers, focuses on a double-clicked or
double-tapped point of `scene`, and keeps spinning after a quick release
(inertia decelerating by `damping_factor` rad/s²).

Construction is three.js `new ArcballControls(camera, element, scene)` with
`target` and the keywords assigned before `setCamera(camera)`: the camera
looks at `target` and that pose becomes the reset state. As in three.js the
saved target `target0` stays at the origin until
[`arcball_save_state!`](@ref), so [`arcball_reset!`](@ref) before a save
returns the gizmo to the origin. Fields carry the three.js property names in
snake case and may be changed between calls; `target` takes effect at the
next [`arcball_update!`](@ref).

Units follow Diff3D: `min_fov` and `max_fov` are radians (three.js: degrees;
the defaults are 5° and 90°), like `camera.fov`. Times are milliseconds, as
three.js `performance.now()` and `focusAnimationTime`: every pointer call
takes `time`, and animations advance only through
[`arcball_animation_frame!`](@ref)`(controls, time)`, the stand-in for
`requestAnimationFrame`, so results are deterministic.

Input: [`arcball_pointer_down!`](@ref), [`arcball_pointer_move!`](@ref),
[`arcball_pointer_up!`](@ref), [`arcball_pointer_cancel!`](@ref) and
[`arcball_wheel!`](@ref) take client pixels inside the element rectangle
`element_left`, `element_top`, `element_width`, `element_height` (which must
be positive for input); `device_pixel_ratio` is `window.devicePixelRatio`.
Mouse buttons map to operations through `mouse_actions`, edited with
[`arcball_set_mouse_action!`](@ref) and [`arcball_unset_mouse_action!`](@ref);
the default is three.js `initializeMouseActions`: left rotates, Ctrl+left and
right pan, middle and the wheel zoom, Shift+middle and Shift+wheel change the
FOV. One finger rotates, two fingers pan, pinch and roll together, three or
more fingers change the FOV.

The camera state is written to `camera` (position, orientation, `zoom`,
`fov`, `near`, `far`). three.js keeps `camera.up` apart from the orientation
and turns it with every rotation; that vector is `controls.up` here. Diff3D
cameras are aimed through position, target and up, so between
[`arcball_update!`](@ref) calls (which aim at the gizmo with `controls.up`, as
three.js `lookAt` does) the camera's own `up` is its local +y axis.

The gizmos and the pan grid are not scene objects here: their transform
(`gizmo_position`, `gizmo_quaternion`, `gizmo_scale`), circle radius
(`gizmo_radius`), visibility (`gizmos_visible`), highlight
(`gizmos_active`, three.js opacity 1 instead of 0.6) and whether three.js
would show the grid (`grid_active`) are kept as state. `enable_gizmos` is
stored like three.js, which never reads it. `scene` (any object tree) is only
ray-cast for the double-tap focus, which needs it.
"""
mutable struct ArcballControls
    camera::_OrbitCamera
    scene::Union{Nothing, AbstractObject3D}
    target::Vec3{Float64}
    enabled::Bool
    enable_pan::Bool
    enable_rotate::Bool
    enable_zoom::Bool
    enable_gizmos::Bool
    enable_focus::Bool
    enable_animations::Bool
    enable_grid::Bool
    adjust_near_far::Bool
    cursor_zoom::Bool
    radius_factor::Float64
    scale_factor::Float64
    damping_factor::Float64
    w_max::Float64
    focus_animation_time::Float64
    min_fov::Float64
    max_fov::Float64
    rotate_speed::Float64
    min_distance::Float64
    max_distance::Float64
    min_zoom::Float64
    max_zoom::Float64
    mouse_actions::Vector{_ArcballMouseAction}
    element_left::Float64
    element_top::Float64
    element_width::Float64
    element_height::Float64
    device_pixel_ratio::Float64
    # three.js camera.up (see the docstring).
    up::Vec3{Float64}
    # Finite-state machine and pointer bookkeeping (three.js _state, _input,
    # _mouseOp, _button, the window pointermove/pointerup listeners,
    # _touchStart, _touchCurrent, the browser's primary touch, finger
    # distances/rotations, the double-tap state and the cursor positions).
    state::Symbol
    input::Symbol
    mouse_op::Union{Nothing, Symbol}
    button::Int
    listening::Bool
    touch_start::Vector{_ArcballPointer}
    touch_current::Vector{_ArcballPointer}
    active_touches::Vector{Int}
    primary_touch::Int
    start_finger_distance::Float64
    current_finger_distance::Float64
    start_finger_rotation::Float64
    current_finger_rotation::Float64
    down_valid::Bool
    nclicks::Int
    down_events::Vector{_ArcballPointer}
    click_start::Float64
    start_cursor_position::Vec3{Float64}
    current_cursor_position::Vec3{Float64}
    rotation_axis::Vec3{Float64}
    # Trackball and gizmos (_tbRadius, _currentTarget, _gizmos).
    tb_radius::Float64
    current_target::Vec3{Float64}
    gizmo_position::Vec3{Float64}
    gizmo_quaternion::Quaternion{Float64}
    gizmo_scale::Vec3{Float64}
    gizmo_radius::Float64
    gizmos_visible::Bool
    gizmos_active::Bool
    grid_active::Bool
    # Matrix and camera state (_cameraMatrixState, _gizmoMatrixState,
    # _fovState in radians, _upState, _zoomState, _nearPos, _farPos) and the
    # initial values (_up0, _zoom0, _fov0 in radians, _initialNear, _nearPos0,
    # _initialFar, _farPos0, _cameraMatrixState0, _gizmoMatrixState0, _target0).
    camera_matrix_state::Mat4{Float64}
    gizmo_matrix_state::Mat4{Float64}
    fov_state::Float64
    up_state::Vec3{Float64}
    zoom_state::Float64
    near_pos::Float64
    far_pos::Float64
    up0::Vec3{Float64}
    zoom0::Float64
    fov0::Float64
    initial_near::Float64
    near_pos0::Float64
    initial_far::Float64
    far_pos0::Float64
    camera_matrix_state0::Mat4{Float64}
    gizmo_matrix_state0::Mat4{Float64}
    target0::Vec3{Float64}
    # Animations: _timeStart, _animationId, the requestAnimationFrame queue
    # (`frames` waits for the next frame, `running` is the frame in progress)
    # and the rotation-inertia samples.
    time_start::Float64
    animation_id::Int
    frames::Vector{_ArcballFrame}
    running::Vector{_ArcballFrame}
    frame_counter::Int
    time_prev::Float64
    time_current::Float64
    angle_prev::Float64
    angle_current::Float64
    cursor_pos_prev::Vec3{Float64}
    cursor_pos_curr::Vec3{Float64}
    w_prev::Float64
    w_curr::Float64
end

"""
    ArcballState

A saved [`ArcballControls`](@ref) view, the value three.js `copyState()` puts
on the clipboard as JSON (`arcballState`): `camera_far`, `camera_fov`
(radians, `nothing` for an orthographic camera), `camera_matrix` (the
camera's local matrix), `camera_near`, `camera_up`, `camera_zoom`,
`gizmo_matrix` and `target`. Produced by [`arcball_copy_state`](@ref) and
restored by [`arcball_paste_state!`](@ref).
"""
struct ArcballState
    camera_far::Float64
    camera_fov::Union{Nothing, Float64}
    camera_matrix::Mat4{Float64}
    camera_near::Float64
    camera_up::Vec3{Float64}
    camera_zoom::Float64
    gizmo_matrix::Mat4{Float64}
    target::Vec3{Float64}
end

function ArcballControls(camera::_OrbitCamera,
                         scene::Union{Nothing, AbstractObject3D}=nothing;
                         target::Vec3=Vec3(0.0, 0.0, 0.0), enabled::Bool=true,
                         enable_pan::Bool=true, enable_rotate::Bool=true,
                         enable_zoom::Bool=true, enable_gizmos::Bool=true,
                         enable_focus::Bool=true, enable_animations::Bool=true,
                         enable_grid::Bool=false, adjust_near_far::Bool=false,
                         cursor_zoom::Bool=false, radius_factor::Real=0.67,
                         scale_factor::Real=1.1, damping_factor::Real=25.0,
                         w_max::Real=20.0, focus_animation_time::Real=500.0,
                         min_fov::Real=5 * _CONTROL_DEG2RAD,
                         max_fov::Real=90 * _CONTROL_DEG2RAD,
                         rotate_speed::Real=1.0, min_distance::Real=0.0,
                         max_distance::Real=Inf, min_zoom::Real=0.0,
                         max_zoom::Real=Inf, element_left::Real=0.0,
                         element_top::Real=0.0, element_width::Real=0.0,
                         element_height::Real=0.0,
                         device_pixel_ratio::Real=1.0)
    label = "ArcballControls"
    f(value, name) = _checked_control_scalar(value, "$label $name")
    w_max isa Bool && throw(ArgumentError("$label w_max must be a number"))
    minimum_distance, maximum_distance =
        _checked_orbit_distances(min_distance, max_distance)
    minimum_zoom, maximum_zoom = _checked_orbit_zoom_limits(min_zoom, max_zoom)
    identity = Mat4()
    zero3 = Vec3(0.0, 0.0, 0.0)
    ac = ArcballControls(
        camera, scene, _checked_control_vec3(target, "$label target"), enabled,
        enable_pan, enable_rotate, enable_zoom, enable_gizmos, enable_focus,
        enable_animations, enable_grid, adjust_near_far, cursor_zoom,
        f(radius_factor, "radius_factor"), f(scale_factor, "scale_factor"),
        f(damping_factor, "damping_factor"), Float64(w_max),
        f(focus_animation_time, "focus_animation_time"),
        f(min_fov, "min_fov"), f(max_fov, "max_fov"), f(rotate_speed, "rotate_speed"),
        minimum_distance, maximum_distance, minimum_zoom, maximum_zoom,
        _ArcballMouseAction[],
        f(element_left, "element_left"), f(element_top, "element_top"),
        f(element_width, "element_width"), f(element_height, "element_height"),
        f(device_pixel_ratio, "device_pixel_ratio"), Vec3(0.0, 1.0, 0.0),
        :idle, :none, nothing, -1, false, _ArcballPointer[], _ArcballPointer[],
        Int[], -1, 0.0, 0.0, 0.0, 0.0, true, 0, _ArcballPointer[], 0.0,
        zero3, zero3, zero3, 1.0, zero3, zero3, Quaternion(), Vec3(1.0, 1.0, 1.0),
        1.0, true, false, false, identity, identity, 1 * _CONTROL_DEG2RAD,
        zero3, 1.0, 0.0, 0.0, zero3, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, identity,
        identity, zero3, -1.0, -1, _ArcballFrame[], _ArcballFrame[], 0, 0.0,
        0.0, 0.0, 0.0, zero3, zero3, 0.0, 0.0)
    _validate_arcball(ac)
    _arcball_set_camera!(ac, camera)
    _arcball_initialize_mouse_actions!(ac)
    return ac
end

function _checked_arcball_camera(cam::_OrbitCamera)
    _validated_camera_view_vectors(cam, nameof(typeof(cam)))
    parent = get_parent(cam)
    (parent === nothing || parent isa Scene) || throw(ArgumentError(
        "ArcballControls camera must not be a child of an object other than a Scene (three.js requirement)"))
    return cam
end

function _validate_arcball(ac::ArcballControls)
    label = "ArcballControls"
    _checked_arcball_camera(ac.camera)
    _checked_control_vec3(ac.target, "$label target")
    _checked_control_scalar(ac.radius_factor, "$label radius_factor")
    scale_factor = _checked_control_scalar(ac.scale_factor, "$label scale_factor")
    scale_factor > 0.0 || throw(ArgumentError("$label scale_factor must be positive"))
    damping = _checked_control_scalar(ac.damping_factor, "$label damping_factor")
    damping >= 0.0 || throw(ArgumentError("$label damping_factor must be non-negative"))
    isnan(ac.w_max) && throw(ArgumentError("$label w_max must not be NaN"))
    focus_time = _checked_control_scalar(ac.focus_animation_time,
                                         "$label focus_animation_time")
    focus_time > 0.0 || throw(ArgumentError("$label focus_animation_time must be positive"))
    min_fov = _checked_control_scalar(ac.min_fov, "$label min_fov")
    max_fov = _checked_control_scalar(ac.max_fov, "$label max_fov")
    0.0 < min_fov <= max_fov < Float64(π) || throw(ArgumentError(
        "$label FOV limits must satisfy 0 < min_fov <= max_fov < pi radians"))
    _checked_control_scalar(ac.rotate_speed, "$label rotate_speed")
    _checked_orbit_distances(ac.min_distance, ac.max_distance)
    _checked_orbit_zoom_limits(ac.min_zoom, ac.max_zoom)
    for name in (:element_left, :element_top, :element_width, :element_height)
        _checked_control_scalar(getfield(ac, name), "$label $name")
    end
    ratio = _checked_control_scalar(ac.device_pixel_ratio, "$label device_pixel_ratio")
    ratio > 0.0 || throw(ArgumentError("$label device_pixel_ratio must be positive"))
    _checked_control_vec3(ac.up, "$label up")
    return ac
end

function _validate_arcball_input(ac::ArcballControls)
    _validate_arcball(ac)
    (ac.element_width > 0.0 && ac.element_height > 0.0) || throw(ArgumentError(
        "ArcballControls pointer input needs a positive element_width and element_height"))
    return ac
end

# ---- three.js Vector3/Matrix4 operations with their exact arithmetic ------

@inline _arcball_length(v::Vec3) = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
@inline _arcball_distance(a::Vec3, b::Vec3) = _arcball_length(a - b)
@inline _arcball_dot(a::Vec3, b::Vec3) = a.x * b.x + a.y * b.y + a.z * b.z
@inline _arcball_cross(a::Vec3, b::Vec3) =
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)

# Vector3.normalize: divideScalar(length || 1), i.e. multiply by 1 / length.
@inline function _arcball_normalize(v::Vec3)
    len = _arcball_length(v)
    return v * (1 / (len == 0.0 ? 1.0 : len))
end

# Vector3.angleTo.
function _arcball_angle_to(a::Vec3, b::Vec3)
    denominator = sqrt(_arcball_dot(a, a) * _arcball_dot(b, b))
    denominator == 0.0 && return Float64(π) / 2
    theta = _arcball_dot(a, b) / denominator
    return acos(max(-1.0, min(1.0, theta)))
end

# Vector3.applyQuaternion.
function _arcball_apply_quaternion(v::Vec3, q::Quaternion)
    tx = 2 * (q.y * v.z - q.z * v.y)
    ty = 2 * (q.z * v.x - q.x * v.z)
    tz = 2 * (q.x * v.y - q.y * v.x)
    return Vec3(v.x + q.w * tx + q.y * tz - q.z * ty,
                v.y + q.w * ty + q.z * tx - q.x * tz,
                v.z + q.w * tz + q.x * ty - q.y * tx)
end

# Vector3.applyMatrix4 (with the perspective divide).
function _arcball_apply_matrix(m::Mat4, v::Vec3)
    e = m.e
    w = 1 / (e[4] * v.x + e[8] * v.y + e[12] * v.z + e[16])
    return Vec3((e[1] * v.x + e[5] * v.y + e[9] * v.z + e[13]) * w,
                (e[2] * v.x + e[6] * v.y + e[10] * v.z + e[14]) * w,
                (e[3] * v.x + e[7] * v.y + e[11] * v.z + e[15]) * w)
end

@inline _arcball_matrix_position(m::Mat4) = Vec3(m.e[13], m.e[14], m.e[15])

# Matrix4.multiplyMatrices(a, b).
function _arcball_multiply(a::Mat4, b::Mat4)
    ae, be = a.e, b.e
    entry(r, c) = ae[r] * be[4c - 3] + ae[r + 4] * be[4c - 2] +
                  ae[r + 8] * be[4c - 1] + ae[r + 12] * be[4c]
    return Mat4{Float64}(ntuple(i -> entry((i - 1) % 4 + 1, (i - 1) ÷ 4 + 1), Val(16)))
end

@inline _arcball_translation(v::Vec3) = mat4_translation(v.x, v.y, v.z)

# Matrix4.makeRotationAxis.
function _arcball_rotation_axis_matrix(axis::Vec3, angle::Float64)
    c = cos(angle)
    s = sin(angle)
    t = 1 - c
    x, y, z = axis.x, axis.y, axis.z
    tx, ty = t * x, t * y
    return Mat4{Float64}((tx * x + c, tx * y + s * z, tx * z - s * y, 0.0,
                          tx * y - s * z, ty * y + c, ty * z + s * x, 0.0,
                          tx * z + s * y, ty * z - s * x, t * z * z + c, 0.0,
                          0.0, 0.0, 0.0, 1.0))
end

# Matrix4.decompose (r186: the affine determinant picks the scale sign).
function _arcball_decompose(m::Mat4)
    e = m.e
    position = Vec3(e[13], e[14], e[15])
    det = _mat4_determinant_affine(m)
    det == 0.0 && return position, Quaternion(), Vec3(1.0, 1.0, 1.0)
    sx = sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3])
    sy = sqrt(e[5] * e[5] + e[6] * e[6] + e[7] * e[7])
    sz = sqrt(e[9] * e[9] + e[10] * e[10] + e[11] * e[11])
    det < 0 && (sx = -sx)
    ix, iy, iz = 1 / sx, 1 / sy, 1 / sz
    rotation = Mat4{Float64}((e[1] * ix, e[2] * ix, e[3] * ix, 0.0,
                              e[5] * iy, e[6] * iy, e[7] * iy, 0.0,
                              e[9] * iz, e[10] * iz, e[11] * iz, 0.0,
                              0.0, 0.0, 0.0, 1.0))
    return position, quat_from_rotation_matrix(rotation), Vec3(sx, sy, sz)
end

# Matrix4.extractRotation followed by Quaternion.setFromRotationMatrix.
function _arcball_rotation_quaternion(m::Mat4)
    e = m.e
    sx = 1 / sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3])
    sy = 1 / sqrt(e[5] * e[5] + e[6] * e[6] + e[7] * e[7])
    sz = 1 / sqrt(e[9] * e[9] + e[10] * e[10] + e[11] * e[11])
    rotation = Mat4{Float64}((e[1] * sx, e[2] * sx, e[3] * sx, 0.0,
                              e[5] * sy, e[6] * sy, e[7] * sy, 0.0,
                              e[9] * sz, e[10] * sz, e[11] * sz, 0.0,
                              0.0, 0.0, 0.0, 1.0))
    return quat_from_rotation_matrix(rotation)
end

@inline _arcball_clamp(value, lo, hi) = max(lo, min(hi, value))

# ---- camera and gizmo state ------------------------------------------------

@inline _arcball_camera_quaternion(ac::ArcballControls) =
    _camera_local_quaternion(ac.camera)

# The camera's local matrix (three.js camera.matrix after a render).
_arcball_camera_matrix(ac::ArcballControls) =
    mat4_compose(ac.camera.position, _arcball_camera_quaternion(ac), ac.camera.scale)

_arcball_gizmo_matrix(ac::ArcballControls) =
    mat4_compose(ac.gizmo_position, ac.gizmo_quaternion, ac.gizmo_scale)

# Writes a decomposed camera matrix (position and orientation) to the camera.
function _arcball_set_camera_pose!(ac::ArcballControls, position::Vec3,
                                   q::Quaternion)
    _set_camera_pose!(ac.camera, position, q,
                      _arcball_distance(ac.gizmo_position, position),
                      "ArcballControls")
    return q
end

function _arcball_set_camera_from_matrix!(ac::ArcballControls, m::Mat4)
    position, q, _ = _arcball_decompose(m)
    return _arcball_set_camera_pose!(ac, position, q)
end

function _arcball_set_gizmos_from_matrix!(ac::ArcballControls, m::Mat4)
    position, q, s = _arcball_decompose(m)
    ac.gizmo_position = position
    ac.gizmo_quaternion = q
    ac.gizmo_scale = s
    return ac
end

# Object3D.lookAt(point) for the camera, with three.js camera.up.
function _arcball_look_at!(ac::ArcballControls, point::Vec3)
    ac.camera.up = ac.up
    _camera_control_look_at!(ac.camera, point, "ArcballControls")
    return ac
end

_arcball_is_perspective(ac::ArcballControls) = ac.camera isa PerspectiveCamera

# calculateTbRadius (ArcballControls.js:1697-1713).
function _arcball_tb_radius(ac::ArcballControls)
    cam = ac.camera
    if cam isa PerspectiveCamera
        distance = _arcball_distance(cam.position, ac.gizmo_position)
        half_fov_v = cam.fov * 0.5
        half_fov_h = atan(cam.aspect * tan(half_fov_v))
        return tan(min(half_fov_v, half_fov_h)) * distance * ac.radius_factor
    end
    return min(cam.top, cam.right) * ac.radius_factor
end

# makeGizmos (ArcballControls.js:1996-2059): new gizmo lines (opacity 0.6)
# with circles of `radius` around `center`, scaled by 1 / zoom.
function _arcball_make_gizmos!(ac::ArcballControls, center::Vec3, radius::Float64)
    ac.gizmo_radius = radius
    ac.gizmos_active = false
    state0 = _arcball_translation(center)
    state = state0
    zoom = ac.camera.zoom
    if zoom != 1
        size = 1 / zoom
        state = _arcball_multiply(_arcball_translation(-center), state)
        state = _arcball_multiply(mat4_scaling(size, size, size), state)
        state = _arcball_multiply(_arcball_translation(center), state)
    end
    ac.gizmo_matrix_state0 = state0
    ac.gizmo_matrix_state = state
    _arcball_set_gizmos_from_matrix!(ac, state)
    return ac
end

# updateMatrixState / updateTbState (ArcballControls.js:2853-2889).
function _arcball_update_matrix_state!(ac::ArcballControls)
    ac.camera_matrix_state = _arcball_camera_matrix(ac)
    ac.gizmo_matrix_state = _arcball_gizmo_matrix(ac)
    if ac.camera isa OrthographicCamera
        ac.zoom_state = ac.camera.zoom
    else
        ac.fov_state = ac.camera.fov
    end
    return ac
end

function _arcball_update_tb_state!(ac::ArcballControls, state::Symbol,
                                   update_matrices::Bool)
    ac.state = state
    update_matrices && _arcball_update_matrix_state!(ac)
    return ac
end

# setCamera (ArcballControls.js:1913-1950).
function _arcball_set_camera!(ac::ArcballControls, cam::_OrbitCamera)
    _prepare_camera_control_up!(cam)
    _checked_arcball_camera(cam)
    ac.camera = cam
    ac.up = cam.up
    _arcball_look_at!(ac, ac.target)
    if cam isa PerspectiveCamera
        ac.fov0 = cam.fov
        ac.fov_state = cam.fov
    end
    ac.camera_matrix_state0 = _arcball_camera_matrix(ac)
    ac.camera_matrix_state = ac.camera_matrix_state0
    ac.zoom0 = cam.zoom
    ac.zoom_state = ac.zoom0
    distance = _arcball_distance(cam.position, ac.target)
    ac.initial_near = cam.near
    ac.near_pos0 = distance - cam.near
    ac.near_pos = ac.initial_near
    ac.initial_far = cam.far
    ac.far_pos0 = distance - cam.far
    ac.far_pos = ac.initial_far
    ac.up0 = ac.up
    ac.up_state = ac.up
    ac.tb_radius = _arcball_tb_radius(ac)
    _arcball_make_gizmos!(ac, ac.target, ac.tb_radius)
    return ac
end

# Box3.setFromObject(gizmos) for the three circle lines (Float32 positions of
# EllipseCurve(0, 0, r, r).getPoints(128), the X circle turned by π/2 about y
# and the Y circle about x).
function _arcball_gizmo_box(ac::ArcballControls)
    lo_x = lo_y = Inf
    hi_x = hi_y = -Inf
    r = ac.gizmo_radius
    two_pi = Float64(π) * 2
    for d in 0:_ARCBALL_CURVE_POINTS
        angle = 0.0 + (d / _ARCBALL_CURVE_POINTS) * two_pi
        x = Float64(Float32(0.0 + r * cos(angle)))
        y = Float64(Float32(0.0 + r * sin(angle)))
        lo_x, hi_x = min(lo_x, x), max(hi_x, x)
        lo_y, hi_y = min(lo_y, y), max(hi_y, y)
    end
    world = _arcball_gizmo_matrix(ac)
    ac.scene === nothing || (world = _arcball_multiply(compute_world_matrix(ac.scene), world))
    half = Float64(π) * 0.5
    children = (mat4_compose(Vec3(0.0, 0.0, 0.0), quat_from_euler(0.0, half, 0.0),
                             Vec3(1.0, 1.0, 1.0)),
                mat4_compose(Vec3(0.0, 0.0, 0.0), quat_from_euler(half, 0.0, 0.0),
                             Vec3(1.0, 1.0, 1.0)),
                Mat4())
    box_lo = Vec3(Inf, Inf, Inf)
    box_hi = Vec3(-Inf, -Inf, -Inf)
    for child in children
        m = _arcball_multiply(world, child)
        for cx in (lo_x, hi_x), cy in (lo_y, hi_y)
            p = _arcball_apply_matrix(m, Vec3(cx, cy, 0.0))
            box_lo = Vec3(min(box_lo.x, p.x), min(box_lo.y, p.y), min(box_lo.z, p.z))
            box_hi = Vec3(max(box_hi.x, p.x), max(box_hi.y, p.y), max(box_hi.z, p.z))
        end
    end
    return box_lo, box_hi
end

# Box3.getBoundingSphere of the gizmo box.
function _arcball_gizmo_bounding_sphere(ac::ArcballControls)
    box_lo, box_hi = _arcball_gizmo_box(ac)
    center = (box_lo + box_hi) * 0.5
    radius = _arcball_length(box_hi - box_lo) * 0.5
    return center, radius
end

const _ArcballTransformation = NamedTuple{(:camera, :gizmos),
    Tuple{Union{Nothing, Mat4{Float64}}, Union{Nothing, Mat4{Float64}}}}

_arcball_transformation(camera, gizmos=nothing) =
    _ArcballTransformation((camera, gizmos))

# applyTransformMatrix (ArcballControls.js:1551-1632).
function _arcball_apply_transform!(ac::ArcballControls, tr::_ArcballTransformation)
    cam = ac.camera
    if tr.camera !== nothing
        q = _arcball_set_camera_from_matrix!(
            ac, _arcball_multiply(tr.camera, ac.camera_matrix_state))
        if ac.state === :rotate || ac.state === :zrotate || ac.state === :animation_rotate
            ac.up = _arcball_apply_quaternion(ac.up_state, q)
        end
    end
    if tr.gizmos !== nothing
        _arcball_set_gizmos_from_matrix!(
            ac, _arcball_multiply(tr.gizmos, ac.gizmo_matrix_state))
    end
    if ac.state === :scale || ac.state === :focus || ac.state === :animation_focus
        ac.tb_radius = _arcball_tb_radius(ac)
        if ac.adjust_near_far
            camera_distance = _arcball_distance(cam.position, ac.gizmo_position)
            center, radius = _arcball_gizmo_bounding_sphere(ac)
            center_length = _arcball_length(center)
            adjusted_near = max(ac.near_pos0, radius + center_length)
            regular_near = camera_distance - ac.initial_near
            cam.near = camera_distance - min(adjusted_near, regular_near)
            adjusted_far = min(ac.far_pos0, -radius + center_length)
            regular_far = camera_distance - ac.initial_far
            cam.far = camera_distance - min(adjusted_far, regular_far)
        else
            cam.near != ac.initial_near && (cam.near = ac.initial_near)
            cam.far != ac.initial_far && (cam.far = ac.initial_far)
        end
    end
    return ac
end

# ---- cursor unprojection ----------------------------------------------------

# getCursorNDC.
function _arcball_cursor_ndc(ac::ArcballControls, x::Float64, y::Float64)
    bottom = ac.element_top + ac.element_height
    return ((x - ac.element_left) / ac.element_width) * 2 - 1,
           ((bottom - y) / ac.element_height) * 2 - 1
end

# getCursorPosition (orthographic cameras).
function _arcball_cursor_position(ac::ArcballControls, x::Float64, y::Float64)
    nx, ny = _arcball_cursor_ndc(ac, x, y)
    cam = ac.camera
    return nx * ((cam.right - cam.left) * 0.5), ny * ((cam.top - cam.bottom) * 0.5)
end

# The cursor on the near plane in camera space (projectionMatrixInverse).
function _arcball_near_point(ac::ArcballControls, x::Float64, y::Float64)
    nx, ny = _arcball_cursor_ndc(ac, x, y)
    inverse = mat4_inverse(projection_matrix(ac.camera))
    return _arcball_apply_matrix(inverse, Vec3(nx, ny, -1.0))
end

# unprojectOnTbSurface (ArcballControls.js:2645-2763).
function _arcball_unproject_on_tb_surface(ac::ArcballControls, x::Float64,
                                          y::Float64, tb_radius::Float64)
    if ac.camera isa OrthographicCamera
        px, py = _arcball_cursor_position(ac, x, y)
        x2 = px^2
        y2 = py^2
        r2 = ac.tb_radius^2
        z = x2 + y2 <= r2 * 0.5 ? sqrt(r2 - (x2 + y2)) : (r2 * 0.5) / sqrt(x2 + y2)
        return Vec3(px, py, z)
    end
    v = _arcball_near_point(ac, x, y)
    ray = _arcball_normalize(v)
    camera_gizmo_distance = _arcball_distance(ac.camera.position, ac.gizmo_position)
    radius2 = tb_radius^2
    h = v.z
    l = sqrt(v.x^2 + v.y^2)
    l == 0.0 && return Vec3(v.x, v.y, tb_radius)
    m = h / l
    q = camera_gizmo_distance
    a = m^2 + 1
    b = 2 * m * q
    c = q^2 - radius2
    delta = b^2 - (4 * a * c)
    if delta >= 0
        ix = (-b - sqrt(delta)) / (2 * a)
        iy = m * ix + q
        angle = _CONTROL_RAD2DEG * (atan(-iy, -ix) + Float64(π))
        if angle >= 45
            ray_length = sqrt(ix^2 + (camera_gizmo_distance - iy)^2)
            r = ray * ray_length
            return Vec3(r.x, r.y, r.z + camera_gizmo_distance)
        end
    end
    a = m
    b = q
    c = -radius2 * 0.5
    delta = b^2 - (4 * a * c)
    ix = (-b - sqrt(delta)) / (2 * a)
    iy = m * ix + q
    ray_length = sqrt(ix^2 + (camera_gizmo_distance - iy)^2)
    r = ray * ray_length
    return Vec3(r.x, r.y, r.z + camera_gizmo_distance)
end

# unprojectOnTbPlane (ArcballControls.js:2777-2846).
function _arcball_unproject_on_tb_plane(ac::ArcballControls, x::Float64,
                                        y::Float64, initial_distance::Bool=false)
    if ac.camera isa OrthographicCamera
        px, py = _arcball_cursor_position(ac, x, y)
        return Vec3(px, py, 0.0)
    end
    v = _arcball_near_point(ac, x, y)
    ray = _arcball_normalize(v)
    h = v.z
    l = sqrt(v.x^2 + v.y^2)
    camera_gizmo_distance = initial_distance ?
        _arcball_distance(_arcball_matrix_position(ac.camera_matrix_state0),
                          _arcball_matrix_position(ac.gizmo_matrix_state0)) :
        _arcball_distance(ac.camera.position, ac.gizmo_position)
    l == 0.0 && return Vec3(0.0, 0.0, 0.0)
    m = h / l
    q = camera_gizmo_distance
    ix = -q / m
    r = ray * sqrt(q^2 + ix^2)
    return Vec3(r.x, r.y, 0.0)
end

# A point unprojected on the trackball plane in world space, as onRotateMove,
# onPinchMove and the cursor zoom compute it.
function _arcball_plane_point_world(ac::ArcballControls, x::Float64, y::Float64,
                                    base::Vec3, divide_by_zoom::Bool)
    p = _arcball_apply_quaternion(_arcball_unproject_on_tb_plane(ac, x, y),
                                  _arcball_camera_quaternion(ac))
    divide_by_zoom && (p = p * (1 / ac.camera.zoom))
    return p + base
end

# ---- transformations (ArcballControls.js pan/rotate/scale/zRotate/focus) ---

function _arcball_pan(ac::ArcballControls, p0::Vec3, p1::Vec3, adjust::Bool=false)
    movement = p0 - p1
    if ac.camera isa OrthographicCamera
        movement = movement * (1 / ac.camera.zoom)
    elseif adjust
        distance_factor =
            _arcball_distance(_arcball_matrix_position(ac.camera_matrix_state0),
                              _arcball_matrix_position(ac.gizmo_matrix_state0)) /
            _arcball_distance(ac.camera.position, ac.gizmo_position)
        movement = movement * (1 / distance_factor)
    end
    shift = _arcball_apply_quaternion(Vec3(movement.x, movement.y, 0.0),
                                      _arcball_camera_quaternion(ac))
    m = _arcball_translation(shift)
    return _arcball_transformation(m, m)
end

function _arcball_rotate(ac::ArcballControls, axis::Vec3, angle::Float64)
    point = ac.gizmo_position
    m = _arcball_multiply(_arcball_translation(point),
                          _arcball_rotation_axis_matrix(axis, -angle))
    m = _arcball_multiply(m, _arcball_translation(-point))
    return _arcball_transformation(m)
end

function _arcball_scale(ac::ArcballControls, size::Float64, point::Vec3,
                        scale_gizmos::Bool=true)
    size_inverse = 1 / size
    cam = ac.camera
    if cam isa OrthographicCamera
        zoom = ac.zoom_state
        zoom *= size
        if zoom > ac.max_zoom
            zoom = ac.max_zoom
            size_inverse = ac.zoom_state / ac.max_zoom
        elseif zoom < ac.min_zoom
            zoom = ac.min_zoom
            size_inverse = ac.zoom_state / ac.min_zoom
        end
        (isfinite(zoom) && zoom > 0.0) || throw(ArgumentError(
            "ArcballControls orthographic zoom must stay finite and positive"))
        cam.zoom = zoom
        v = _arcball_matrix_position(ac.gizmo_matrix_state)
        m2 = _arcball_multiply(_arcball_translation(v),
                               mat4_scaling(size_inverse, size_inverse, size_inverse))
        m2 = _arcball_multiply(m2, _arcball_translation(-v))
        offset = point - v
        offset = offset - offset * size_inverse
        m1 = _arcball_translation(offset)
        return _arcball_transformation(m1, _arcball_multiply(m1, m2))
    end
    v1 = _arcball_matrix_position(ac.camera_matrix_state)
    v2 = _arcball_matrix_position(ac.gizmo_matrix_state)
    distance = _arcball_distance(v1, point)
    amount = distance - (distance * size_inverse)
    new_distance = distance - amount
    if new_distance < ac.min_distance
        size_inverse = ac.min_distance / distance
        amount = distance - (distance * size_inverse)
    elseif new_distance > ac.max_distance
        size_inverse = ac.max_distance / distance
        amount = distance - (distance * size_inverse)
    end
    m1 = _arcball_translation(_arcball_normalize(point - v1) * amount)
    scale_gizmos || return _arcball_transformation(m1)
    distance = _arcball_distance(v2, point)
    amount = distance - (distance * size_inverse)
    offset = _arcball_normalize(point - v2) * amount
    m2 = _arcball_multiply(_arcball_translation(offset), _arcball_translation(v2))
    m2 = _arcball_multiply(m2, mat4_scaling(size_inverse, size_inverse, size_inverse))
    m2 = _arcball_multiply(m2, _arcball_translation(-v2))
    return _arcball_transformation(m1, m2)
end

function _arcball_z_rotate(ac::ArcballControls, point::Vec3, angle::Float64)
    axis = ac.rotation_axis
    m1 = _arcball_multiply(_arcball_translation(point),
                           _arcball_rotation_axis_matrix(axis, angle))
    m1 = _arcball_multiply(m1, _arcball_translation(-point))
    v1 = _arcball_matrix_position(ac.gizmo_matrix_state) - point
    half = angle / 2
    s = sin(half)
    q = Quaternion(axis.x * s, axis.y * s, axis.z * s, cos(half))
    v2 = _arcball_apply_quaternion(v1, q) - v1
    return _arcball_transformation(m1, _arcball_translation(v2))
end

# calculateRotationAxis: the axis in world space for the camera state.
function _arcball_rotation_axis!(ac::ArcballControls, a::Vec3, b::Vec3)
    q = _arcball_rotation_quaternion(ac.camera_matrix_state)
    ac.rotation_axis = _arcball_normalize(
        _arcball_apply_quaternion(_arcball_cross(a, b), q))
    return ac.rotation_axis
end

function _arcball_set_fov!(ac::ArcballControls, fov::Float64)
    ac.camera isa PerspectiveCamera &&
        (ac.camera.fov = _arcball_clamp(fov, ac.min_fov, ac.max_fov))
    return ac
end

function _arcball_focus!(ac::ArcballControls, point::Vec3, size::Float64,
                         amount::Float64=1.0)
    translation = _arcball_translation((point - ac.gizmo_position) * amount)
    gizmo_temp = ac.gizmo_matrix_state
    ac.gizmo_matrix_state = _arcball_multiply(translation, ac.gizmo_matrix_state)
    _arcball_set_gizmos_from_matrix!(ac, ac.gizmo_matrix_state)
    camera_temp = ac.camera_matrix_state
    ac.camera_matrix_state = _arcball_multiply(translation, ac.camera_matrix_state)
    _arcball_set_camera_from_matrix!(ac, ac.camera_matrix_state)
    ac.enable_zoom &&
        _arcball_apply_transform!(ac, _arcball_scale(ac, size, ac.gizmo_position))
    ac.gizmo_matrix_state = gizmo_temp
    ac.camera_matrix_state = camera_temp
    return ac
end

# The size of a vertical drag for zoom and FOV (screenNotches = 8).
function _arcball_drag_size(ac::ArcballControls, movement::Float64)
    movement < 0 && return 1 / (ac.scale_factor^(-movement * _ARCBALL_SCREEN_NOTCHES))
    movement > 0 && return ac.scale_factor^(movement * _ARCBALL_SCREEN_NOTCHES)
    return 1.0
end

# The vertigo step shared by the FOV drag and the multi-finger pan: the FOV
# that keeps the gizmo plane's visible height after scaling by `size`, and the
# camera move that goes with it.
function _arcball_vertigo!(ac::ArcballControls, size::Float64)
    x = _arcball_distance(_arcball_matrix_position(ac.camera_matrix_state),
                          ac.gizmo_position)
    x_new = _arcball_clamp(x / size, ac.min_distance, ac.max_distance)
    y = x * tan(ac.fov_state * 0.5)
    new_fov = _arcball_clamp(atan(y / x_new) * 2, ac.min_fov, ac.max_fov)
    new_distance = y / tan(new_fov / 2)
    size = x / new_distance
    v2 = _arcball_matrix_position(ac.gizmo_matrix_state)
    _arcball_set_fov!(ac, new_fov)
    _arcball_apply_transform!(ac, _arcball_scale(ac, size, v2, false))
    return ac
end

# ---- grid (drawGrid/disposeGrid: only whether three.js shows it) ----------

function _arcball_draw_grid!(ac::ArcballControls)
    ac.scene === nothing || (ac.grid_active = true)
    return ac
end

function _arcball_dispose_grid!(ac::ArcballControls)
    ac.scene === nothing || (ac.grid_active = false)
    return ac
end

# ---- requestAnimationFrame emulation ---------------------------------------

function _arcball_request_frame!(ac::ArcballControls, kind::Symbol;
                                 axis::Vec3=Vec3(0.0, 0.0, 0.0), w::Float64=0.0,
                                 point::Vec3=Vec3(0.0, 0.0, 0.0),
                                 gizmo_matrix::Union{Nothing, Mat4{Float64}}=nothing)
    ac.frame_counter += 1
    push!(ac.frames, _ArcballFrame(ac.frame_counter, kind, axis, w, point,
                                   gizmo_matrix))
    return ac.frame_counter
end

function _arcball_cancel_frame!(ac::ArcballControls, id::Int)
    filter!(frame -> frame.id != id, ac.frames)
    filter!(frame -> frame.id != id, ac.running)
    return ac
end

# ---- gestures (ArcballControls.js:489-1253) --------------------------------

function _arcball_cancel_animation!(ac::ArcballControls)
    _arcball_cancel_frame!(ac, ac.animation_id)
    ac.animation_id = -1
    ac.time_start = -1.0
    return ac
end

function _arcball_single_pan_start!(ac::ArcballControls, event::_ArcballPointer,
                                    operation::Symbol)
    ac.enabled || return ac
    cx, cy = event.x, event.y
    if operation === :pan
        ac.enable_pan || return ac
        if ac.animation_id != -1
            _arcball_cancel_animation!(ac)
            ac.gizmos_active = false
        end
        _arcball_update_tb_state!(ac, :pan, true)
        ac.start_cursor_position = _arcball_unproject_on_tb_plane(ac, cx, cy)
        ac.enable_grid && _arcball_draw_grid!(ac)
    elseif operation === :rotate
        ac.enable_rotate || return ac
        ac.animation_id != -1 && _arcball_cancel_animation!(ac)
        _arcball_update_tb_state!(ac, :rotate, true)
        ac.start_cursor_position =
            _arcball_unproject_on_tb_surface(ac, cx, cy, ac.tb_radius)
        ac.gizmos_active = true
        if ac.enable_animations
            ac.time_prev = ac.time_current = event.time
            ac.angle_current = ac.angle_prev = 0.0
            ac.cursor_pos_prev = ac.start_cursor_position
            ac.cursor_pos_curr = ac.cursor_pos_prev
            ac.w_curr = 0.0
            ac.w_prev = ac.w_curr
        end
    elseif operation === :fov || operation === :zoom
        if operation === :fov
            (_arcball_is_perspective(ac) && ac.enable_zoom) || return ac
        else
            ac.enable_zoom || return ac
        end
        if ac.animation_id != -1
            _arcball_cancel_animation!(ac)
            ac.gizmos_active = false
        end
        _arcball_update_tb_state!(ac, operation === :fov ? :fov : :scale, true)
        _, ny = _arcball_cursor_ndc(ac, cx, cy)
        s = ac.start_cursor_position
        ac.start_cursor_position = Vec3(s.x, ny * 0.5, s.z)
        ac.current_cursor_position = ac.start_cursor_position
    end
    return ac
end

function _arcball_single_pan_move!(ac::ArcballControls, event::_ArcballPointer,
                                   op_state::Symbol)
    ac.enabled || return ac
    restart = op_state !== ac.state
    cx, cy = event.x, event.y
    if op_state === :pan
        ac.enable_pan || return ac
        if restart
            _arcball_update_tb_state!(ac, :pan, true)
            ac.start_cursor_position = _arcball_unproject_on_tb_plane(ac, cx, cy)
            ac.enable_grid && _arcball_draw_grid!(ac)
            ac.gizmos_active = false
        else
            ac.current_cursor_position = _arcball_unproject_on_tb_plane(ac, cx, cy)
            _arcball_apply_transform!(ac, _arcball_pan(
                ac, ac.start_cursor_position, ac.current_cursor_position))
        end
    elseif op_state === :rotate
        ac.enable_rotate || return ac
        if restart
            _arcball_update_tb_state!(ac, :rotate, true)
            ac.start_cursor_position =
                _arcball_unproject_on_tb_surface(ac, cx, cy, ac.tb_radius)
            ac.enable_grid && _arcball_dispose_grid!(ac)
            ac.gizmos_active = true
        else
            current = _arcball_unproject_on_tb_surface(ac, cx, cy, ac.tb_radius)
            ac.current_cursor_position = current
            start = ac.start_cursor_position
            distance = _arcball_distance(start, current)
            angle = _arcball_angle_to(start, current)
            amount = max(distance / ac.tb_radius, angle) * ac.rotate_speed
            axis = _arcball_rotation_axis!(ac, start, current)
            _arcball_apply_transform!(ac, _arcball_rotate(ac, axis, amount))
            if ac.enable_animations
                ac.time_prev = ac.time_current
                ac.time_current = event.time
                ac.angle_prev = ac.angle_current
                ac.angle_current = amount
                ac.cursor_pos_prev = ac.cursor_pos_curr
                ac.cursor_pos_curr = current
                ac.w_prev = ac.w_curr
                ac.w_curr = _arcball_angular_speed(ac.angle_prev, ac.angle_current,
                                                   ac.time_prev, ac.time_current)
            end
        end
    elseif op_state === :scale || op_state === :fov
        if op_state === :fov
            (ac.enable_zoom && _arcball_is_perspective(ac)) || return ac
        else
            ac.enable_zoom || return ac
        end
        _, ny = _arcball_cursor_ndc(ac, cx, cy)
        if restart
            _arcball_update_tb_state!(ac, op_state, true)
            s = ac.start_cursor_position
            ac.start_cursor_position = Vec3(s.x, ny * 0.5, s.z)
            ac.current_cursor_position = ac.start_cursor_position
            ac.enable_grid && _arcball_dispose_grid!(ac)
            ac.gizmos_active = false
        else
            c = ac.current_cursor_position
            ac.current_cursor_position = Vec3(c.x, ny * 0.5, c.z)
            movement = ac.current_cursor_position.y - ac.start_cursor_position.y
            size = _arcball_drag_size(ac, movement)
            if op_state === :scale
                _arcball_apply_transform!(ac, _arcball_scale(
                    ac, size, _arcball_matrix_position(ac.gizmo_matrix_state)))
            else
                _arcball_vertigo!(ac, size)
            end
        end
    end
    return ac
end

# calculateAngularSpeed (times in milliseconds).
function _arcball_angular_speed(p0, p1, t0, t1)
    t = (t1 - t0) / 1000
    t == 0 && return 0.0
    return (p1 - p0) / t
end

function _arcball_single_pan_end!(ac::ArcballControls, time::Float64)
    if ac.state === :rotate
        ac.enable_rotate || return ac
        if ac.enable_animations && time - ac.time_current < _ARCBALL_INERTIA_WINDOW
            w = abs((ac.w_prev + ac.w_curr) / 2)
            ac.animation_id = _arcball_request_frame!(ac, :rotate_start; w=w)
        else
            _arcball_update_tb_state!(ac, :idle, false)
            ac.gizmos_active = false
        end
    elseif ac.state === :pan || ac.state === :idle
        _arcball_update_tb_state!(ac, :idle, false)
        ac.enable_grid && _arcball_dispose_grid!(ac)
        ac.gizmos_active = false
    end
    return ac
end

# unprojectOnObj: the nearest mesh hit of the camera ray in `scene`.
function _arcball_unproject_on_obj(ac::ArcballControls, nx::Float64, ny::Float64)
    cam = ac.camera
    rc = Raycaster(Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, -1.0);
                   near=cam.near, far=cam.far)
    set_from_camera!(rc, cam, nx, ny)
    hits = Intersection[]
    for child in get_children(ac.scene)
        append!(hits, raycast(rc, child; recursive=true))
    end
    sort!(hits; lt=_intersection_distance_lt)
    for hit in hits
        hit.face === nothing || return hit.point
    end
    return nothing
end

function _arcball_double_tap!(ac::ArcballControls, event::_ArcballPointer)
    (ac.enabled && ac.enable_pan && ac.enable_focus && ac.scene !== nothing) ||
        return ac
    nx, ny = _arcball_cursor_ndc(ac, event.x, event.y)
    hit = _arcball_unproject_on_obj(ac, nx, ny)
    hit === nothing && return ac
    if ac.enable_animations
        ac.animation_id != -1 && _arcball_cancel_frame!(ac, ac.animation_id)
        ac.time_start = -1.0
        ac.animation_id = _arcball_request_frame!(ac, :focus_start; point=hit)
    else
        _arcball_update_tb_state!(ac, :focus, true)
        _arcball_focus!(ac, hit, ac.scale_factor)
        _arcball_update_tb_state!(ac, :idle, false)
    end
    return ac
end

_arcball_two_finger_center(ac::ArcballControls) =
    ((ac.touch_current[1].x + ac.touch_current[2].x) / 2,
     (ac.touch_current[1].y + ac.touch_current[2].y) / 2)

function _arcball_double_pan_start!(ac::ArcballControls)
    (ac.enabled && ac.enable_pan) || return ac
    _arcball_update_tb_state!(ac, :pan, true)
    cx, cy = _arcball_two_finger_center(ac)
    ac.start_cursor_position = _arcball_unproject_on_tb_plane(ac, cx, cy, true)
    ac.current_cursor_position = ac.start_cursor_position
    ac.gizmos_active = false
    return ac
end

function _arcball_double_pan_move!(ac::ArcballControls)
    (ac.enabled && ac.enable_pan) || return ac
    cx, cy = _arcball_two_finger_center(ac)
    if ac.state !== :pan
        _arcball_update_tb_state!(ac, :pan, true)
        ac.start_cursor_position = ac.current_cursor_position
    end
    ac.current_cursor_position = _arcball_unproject_on_tb_plane(ac, cx, cy, true)
    _arcball_apply_transform!(ac, _arcball_pan(
        ac, ac.start_cursor_position, ac.current_cursor_position, true))
    return ac
end

# getAngle(p1, p2) in degrees.
_arcball_pointer_angle(p1::_ArcballPointer, p2::_ArcballPointer) =
    atan(p2.y - p1.y, p2.x - p1.x) * 180 / Float64(π)

_arcball_finger_rotation(ac::ArcballControls) =
    _arcball_pointer_angle(ac.touch_current[2], ac.touch_current[1]) +
    _arcball_pointer_angle(ac.touch_start[2], ac.touch_start[1])

_arcball_pointer_distance(p0, p1) = sqrt((p1.x - p0.x)^2 + (p1.y - p0.y)^2)

function _arcball_rotate_start!(ac::ArcballControls)
    (ac.enabled && ac.enable_rotate) || return ac
    _arcball_update_tb_state!(ac, :zrotate, true)
    ac.start_finger_rotation = _arcball_finger_rotation(ac)
    ac.current_finger_rotation = ac.start_finger_rotation
    # Camera.getWorldDirection: the negated, normalized local z column.
    m = _arcball_camera_matrix(ac).e
    ac.rotation_axis = -_arcball_normalize(Vec3(m[9], m[10], m[11]))
    (!ac.enable_pan && !ac.enable_zoom) && (ac.gizmos_active = true)
    return ac
end

function _arcball_rotate_move!(ac::ArcballControls)
    (ac.enabled && ac.enable_rotate) || return ac
    cx, cy = _arcball_two_finger_center(ac)
    if ac.state !== :zrotate
        _arcball_update_tb_state!(ac, :zrotate, true)
        ac.start_finger_rotation = ac.current_finger_rotation
    end
    ac.current_finger_rotation = _arcball_finger_rotation(ac)
    gizmo = _arcball_matrix_position(ac.gizmo_matrix_state)
    point = ac.enable_pan ?
        _arcball_plane_point_world(ac, cx, cy, gizmo, true) : gizmo
    amount = _CONTROL_DEG2RAD * (ac.start_finger_rotation - ac.current_finger_rotation)
    _arcball_apply_transform!(ac, _arcball_z_rotate(ac, point, amount))
    return ac
end

function _arcball_pinch_start!(ac::ArcballControls)
    (ac.enabled && ac.enable_zoom) || return ac
    _arcball_update_tb_state!(ac, :scale, true)
    ac.start_finger_distance =
        _arcball_pointer_distance(ac.touch_current[1], ac.touch_current[2])
    ac.current_finger_distance = ac.start_finger_distance
    ac.gizmos_active = false
    return ac
end

function _arcball_pinch_move!(ac::ArcballControls)
    (ac.enabled && ac.enable_zoom) || return ac
    cx, cy = _arcball_two_finger_center(ac)
    if ac.state !== :scale
        ac.start_finger_distance = ac.current_finger_distance
        _arcball_update_tb_state!(ac, :scale, true)
    end
    ac.current_finger_distance = max(
        _arcball_pointer_distance(ac.touch_current[1], ac.touch_current[2]),
        _ARCBALL_MIN_FINGER_DISTANCE * ac.device_pixel_ratio)
    amount = ac.current_finger_distance / ac.start_finger_distance
    point = !ac.enable_pan ? ac.gizmo_position :
        _arcball_plane_point_world(ac, cx, cy, ac.gizmo_position,
                                   ac.camera isa OrthographicCamera)
    _arcball_apply_transform!(ac, _arcball_scale(ac, amount, point))
    return ac
end

function _arcball_touch_center(ac::ArcballControls)
    x = 0.0
    y = 0.0
    for p in ac.touch_current
        x += p.x
        y += p.y
    end
    n = length(ac.touch_current)
    return x / n, y / n
end

function _arcball_triple_pan_start!(ac::ArcballControls)
    (ac.enabled && ac.enable_zoom) || return ac
    _arcball_update_tb_state!(ac, :scale, true)
    cx, cy = _arcball_touch_center(ac)
    _, ny = _arcball_cursor_ndc(ac, cx, cy)
    s = ac.start_cursor_position
    ac.start_cursor_position = Vec3(s.x, ny * 0.5, s.z)
    ac.current_cursor_position = ac.start_cursor_position
    return ac
end

function _arcball_triple_pan_move!(ac::ArcballControls)
    (ac.enabled && ac.enable_zoom) || return ac
    cx, cy = _arcball_touch_center(ac)
    _, ny = _arcball_cursor_ndc(ac, cx, cy)
    c = ac.current_cursor_position
    ac.current_cursor_position = Vec3(c.x, ny * 0.5, c.z)
    movement = ac.current_cursor_position.y - ac.start_cursor_position.y
    _arcball_vertigo!(ac, _arcball_drag_size(ac, movement))
    return ac
end

# ---- animations (onFocusAnim / onRotationAnim, ArcballControls.js:2070-2195)

function _arcball_focus_anim!(ac::ArcballControls, time::Float64, point::Vec3,
                              gizmo_matrix::Union{Nothing, Mat4{Float64}})
    ac.time_start == -1 && (ac.time_start = time)
    if ac.state === :animation_focus
        anim_time = (time - ac.time_start) / ac.focus_animation_time
        gizmo_matrix === nothing || (ac.gizmo_matrix_state = gizmo_matrix)
        _arcball_set_gizmos_from_matrix!(ac, ac.gizmo_matrix_state)
        if anim_time >= 1
            _arcball_focus!(ac, point, ac.scale_factor)
            ac.time_start = -1.0
            _arcball_update_tb_state!(ac, :idle, false)
            ac.gizmos_active = false
        else
            amount = 1 - (1 - anim_time)^3
            size = (1 - amount) + (ac.scale_factor * amount)
            _arcball_focus!(ac, point, size, amount)
            ac.animation_id = _arcball_request_frame!(
                ac, :focus; point=point, gizmo_matrix=gizmo_matrix)
        end
    else
        ac.animation_id = -1
        ac.time_start = -1.0
    end
    return ac
end

function _arcball_rotation_anim!(ac::ArcballControls, time::Float64, axis::Vec3,
                                 w0::Float64)
    if ac.time_start == -1
        ac.angle_prev = 0.0
        ac.angle_current = 0.0
        ac.time_start = time
    end
    if ac.state === :animation_rotate
        delta_time = (time - ac.time_start) / 1000
        w = w0 + ((-ac.damping_factor) * delta_time)
        if w > 0
            ac.angle_current = 0.5 * (-ac.damping_factor) * delta_time^2 +
                               w0 * delta_time + 0
            _arcball_apply_transform!(ac, _arcball_rotate(ac, axis, ac.angle_current))
            ac.animation_id = _arcball_request_frame!(ac, :rotate; axis=axis, w=w0)
        else
            ac.animation_id = -1
            ac.time_start = -1.0
            _arcball_update_tb_state!(ac, :idle, false)
            ac.gizmos_active = false
        end
    else
        ac.animation_id = -1
        ac.time_start = -1.0
        ac.state !== :rotate && (ac.gizmos_active = false)
    end
    return ac
end

function _arcball_run_frame!(ac::ArcballControls, frame::_ArcballFrame, time::Float64)
    if frame.kind === :rotate_start
        _arcball_update_tb_state!(ac, :animation_rotate, true)
        axis = _arcball_rotation_axis!(ac, ac.cursor_pos_prev, ac.cursor_pos_curr)
        _arcball_rotation_anim!(ac, time, axis, min(frame.w, ac.w_max))
    elseif frame.kind === :rotate
        _arcball_rotation_anim!(ac, time, frame.axis, frame.w)
    elseif frame.kind === :focus_start
        _arcball_update_tb_state!(ac, :animation_focus, true)
        _arcball_focus_anim!(ac, time, frame.point, nothing)
    else
        gizmo = frame.gizmo_matrix === nothing ? ac.gizmo_matrix_state :
                frame.gizmo_matrix
        _arcball_focus_anim!(ac, time, frame.point, gizmo)
    end
    return ac
end

"""
    arcball_animation_frame!(controls::ArcballControls, time)

Run one animation frame at `time` milliseconds: the stand-in for the
browser's `requestAnimationFrame` that three.js `ArcballControls` uses for the
rotation inertia after a quick release and for the double-tap focus. The
callbacks that were pending when the call starts run in order with `time` as
their timestamp; callbacks they request wait for the next call, and cancelled
ones never run. The focus moves the gizmo and the camera to the picked point
over `focus_animation_time` with an ease-out cubic and zooms by
`scale_factor`; the inertia turns about the last drag axis with the release
angular velocity (at most `w_max` rad/s), slowed by `damping_factor` rad/s².
Returns `controls`.
"""
function arcball_animation_frame!(ac::ArcballControls, time)
    t = _checked_control_scalar(time, "ArcballControls frame time")
    _validate_arcball(ac)
    append!(ac.running, ac.frames)
    empty!(ac.frames)
    while !isempty(ac.running)
        _arcball_run_frame!(ac, popfirst!(ac.running), t)
    end
    return ac
end

# ---- mouse actions (ArcballControls.js:1274-1508) --------------------------

const _ARCBALL_OPERATION_STATES = (pan=:pan, rotate=:rotate, zoom=:scale, fov=:fov)

function _arcball_initialize_mouse_actions!(ac::ArcballControls)
    arcball_set_mouse_action!(ac, :pan, 0, :ctrl)
    arcball_set_mouse_action!(ac, :pan, 2)
    arcball_set_mouse_action!(ac, :rotate, 0)
    arcball_set_mouse_action!(ac, :zoom, :wheel)
    arcball_set_mouse_action!(ac, :zoom, 1)
    arcball_set_mouse_action!(ac, :fov, :wheel, :shift)
    arcball_set_mouse_action!(ac, :fov, 1, :shift)
    return ac
end

_arcball_mouse_matches(action, mouse, key) =
    action.mouse == mouse && action.key === key

"""
    arcball_set_mouse_action!(controls::ArcballControls, operation, mouse,
                              key=nothing) -> Bool

Assign `operation` (`:pan`, `:rotate`, `:zoom` or `:fov`) to a mouse button
(`0`, `1`, `2`) or `:wheel`, with an optional modifier `key` (`:ctrl`, which
also stands for Meta, or `:shift`), replacing the action of the same
button/key pair (three.js `setMouseAction`). Returns `false`, changing
nothing, for an unknown operation, button or key, and for `:pan` or `:rotate`
on the wheel.
"""
function arcball_set_mouse_action!(ac::ArcballControls, operation::Symbol, mouse,
                                   key::Union{Nothing, Symbol}=nothing)
    operation in (:pan, :rotate, :zoom, :fov) || return false
    (mouse === :wheel || (mouse isa Integer && !(mouse isa Bool) && 0 <= mouse <= 2)) ||
        return false
    key in (:ctrl, :shift, nothing) || return false
    (mouse === :wheel && !(operation in (:zoom, :fov))) && return false
    button = mouse isa Integer ? Int(mouse) : mouse
    action = _ArcballMouseAction((operation, button, key))
    for i in eachindex(ac.mouse_actions)
        if _arcball_mouse_matches(ac.mouse_actions[i], button, key)
            ac.mouse_actions[i] = action
            return true
        end
    end
    push!(ac.mouse_actions, action)
    return true
end

"""
    arcball_unset_mouse_action!(controls::ArcballControls, mouse,
                                key=nothing) -> Bool

Remove the action of a mouse button (`0`, `1`, `2`) or `:wheel` with the
modifier `key` (`:ctrl`, `:shift` or `nothing`) (three.js
`unsetMouseAction`). Returns whether an action was removed.
"""
function arcball_unset_mouse_action!(ac::ArcballControls, mouse,
                                     key::Union{Nothing, Symbol}=nothing)
    mouse isa Bool && return false
    button = mouse isa Integer ? Int(mouse) : mouse
    for i in eachindex(ac.mouse_actions)
        if _arcball_mouse_matches(ac.mouse_actions[i], button, key)
            deleteat!(ac.mouse_actions, i)
            return true
        end
    end
    return false
end

# getOpFromAction / getOpStateFromAction: an exact button/key match, else
# (with a key) the button's action without a key.
function _arcball_op_from_action(ac::ArcballControls, mouse, key)
    for action in ac.mouse_actions
        _arcball_mouse_matches(action, mouse, key) && return action.operation
    end
    if key !== nothing
        for action in ac.mouse_actions
            _arcball_mouse_matches(action, mouse, nothing) && return action.operation
        end
    end
    return nothing
end

function _arcball_op_state_from_action(ac::ArcballControls, mouse, key)
    operation = _arcball_op_from_action(ac, mouse, key)
    return operation === nothing ? nothing : _ARCBALL_OPERATION_STATES[operation]
end

_arcball_modifier(ctrl_key::Bool, meta_key::Bool, shift_key::Bool) =
    ctrl_key || meta_key ? :ctrl : shift_key ? :shift : nothing

# ---- pointer and wheel events (ArcballControls.js:3051-3541) ---------------

# The browser's isPrimary: a mouse or pen is primary; the first touch of a
# gesture is the primary touch until it ends.
function _arcball_primary_down!(ac::ArcballControls, touch::Bool, id::Int)
    touch || return true
    isempty(ac.active_touches) && (ac.primary_touch = id)
    push!(ac.active_touches, id)
    return id == ac.primary_touch
end

function _arcball_primary_up!(ac::ArcballControls, touch::Bool, id::Int)
    touch || return true
    primary = id == ac.primary_touch
    index = findfirst(==(id), ac.active_touches)
    index === nothing || deleteat!(ac.active_touches, index)
    isempty(ac.active_touches) && (ac.primary_touch = -1)
    return primary
end

function _arcball_event(ac::ArcballControls, x, y, time, pointer_id, label::String)
    return _ArcballPointer(Int(pointer_id),
                           _checked_control_scalar(x, "ArcballControls $label x"),
                           _checked_control_scalar(y, "ArcballControls $label y"),
                           _checked_control_scalar(time, "ArcballControls $label time"))
end

"""
    arcball_pointer_down!(controls::ArcballControls, x, y; time, button=0,
                          pointer_type=:mouse, pointer_id=1, ctrl_key=false,
                          meta_key=false, shift_key=false, is_primary=nothing)

A pointer goes down at client position `(x, y)` pixels at `time`
milliseconds (three.js `pointerdown`). A mouse or pen button starts the
operation `mouse_actions` gives it with the held modifier (Ctrl or Meta, else
Shift); the first touch starts rotating, the second panning, pinching and
rolling, the third the FOV change. `is_primary` overrides the browser's
`isPrimary` (by default true for a mouse or pen and for the first touch of a
gesture); a primary left-button down counts towards a double click or tap.
"""
function arcball_pointer_down!(ac::ArcballControls, x, y; time, button::Integer=0,
                               pointer_type::Symbol=:mouse, pointer_id::Integer=1,
                               ctrl_key::Bool=false, meta_key::Bool=false,
                               shift_key::Bool=false,
                               is_primary::Union{Nothing, Bool}=nothing)
    event = _arcball_event(ac, x, y, time, pointer_id, "pointer")
    touch = _checked_pointer_type(pointer_type) === :touch
    _validate_arcball_input(ac)
    primary = _arcball_primary_down!(ac, touch, event.id)
    is_primary === nothing || (primary = is_primary)
    if button == 0 && primary
        ac.down_valid = true
        push!(ac.down_events, event)
    else
        ac.down_valid = false
    end
    if touch && ac.input !== :cursor
        push!(ac.touch_start, event)
        push!(ac.touch_current, event)
        if ac.input === :none
            ac.input = :one_finger
            _arcball_single_pan_start!(ac, event, :rotate)
            ac.listening = true
        elseif ac.input === :one_finger || ac.input === :one_finger_switched
            ac.input = :two_finger
            _arcball_rotate_start!(ac)
            _arcball_pinch_start!(ac)
            _arcball_double_pan_start!(ac)
        elseif ac.input === :two_finger
            ac.input = :mult_finger
            _arcball_triple_pan_start!(ac)
        end
    elseif !touch && ac.input === :none
        modifier = _arcball_modifier(ctrl_key, meta_key, shift_key)
        ac.mouse_op = _arcball_op_from_action(ac, Int(button), modifier)
        if ac.mouse_op !== nothing
            ac.listening = true
            ac.input = :cursor
            ac.button = Int(button)
            _arcball_single_pan_start!(ac, event, ac.mouse_op)
        end
    end
    return ac
end

function _arcball_update_touch_event!(ac::ArcballControls, event::_ArcballPointer)
    index = findfirst(p -> p.id == event.id, ac.touch_current)
    index === nothing || (ac.touch_current[index] = event)
    return ac
end

"""
    arcball_pointer_move!(controls::ArcballControls, x, y; time,
                          pointer_type=:mouse, pointer_id=1, ctrl_key=false,
                          meta_key=false, shift_key=false)

A pointer moves to client position `(x, y)` pixels at `time` milliseconds
(three.js `pointermove`, delivered only while a gesture holds the window
listeners): it continues the mouse operation of the pressed button with the
modifier now held (switching operation when that changes), or the touch
gesture. Moving a primary pointer more than 24 device pixels from where it
went down cancels the pending double click or tap.
"""
function arcball_pointer_move!(ac::ArcballControls, x, y; time,
                               pointer_type::Symbol=:mouse, pointer_id::Integer=1,
                               ctrl_key::Bool=false, meta_key::Bool=false,
                               shift_key::Bool=false)
    event = _arcball_event(ac, x, y, time, pointer_id, "pointer")
    touch = _checked_pointer_type(pointer_type) === :touch
    ac.listening || return ac
    _validate_arcball_input(ac)
    if touch && ac.input !== :cursor
        if ac.input === :one_finger
            _arcball_update_touch_event!(ac, event)
            _arcball_single_pan_move!(ac, event, :rotate)
        elseif ac.input === :one_finger_switched
            movement = _arcball_pointer_distance(ac.touch_current[1], event) *
                       ac.device_pixel_ratio
            if movement >= _ARCBALL_SWITCH_SENSIBILITY
                ac.input = :one_finger
                _arcball_update_touch_event!(ac, event)
                _arcball_single_pan_start!(ac, event, :rotate)
            end
        elseif ac.input === :two_finger
            _arcball_update_touch_event!(ac, event)
            _arcball_rotate_move!(ac)
            _arcball_pinch_move!(ac)
            _arcball_double_pan_move!(ac)
        elseif ac.input === :mult_finger
            _arcball_update_touch_event!(ac, event)
            _arcball_triple_pan_move!(ac)
        end
    elseif !touch && ac.input === :cursor
        modifier = _arcball_modifier(ctrl_key, meta_key, shift_key)
        op_state = _arcball_op_state_from_action(ac, ac.button, modifier)
        op_state === nothing || _arcball_single_pan_move!(ac, event, op_state)
    end
    if ac.down_valid
        movement = _arcball_pointer_distance(ac.down_events[end], event) *
                   ac.device_pixel_ratio
        movement > _ARCBALL_MOVEMENT_THRESHOLD && (ac.down_valid = false)
    end
    return ac
end

"""
    arcball_pointer_up!(controls::ArcballControls, x, y; time,
                        pointer_type=:mouse, pointer_id=1, is_primary=nothing)

A pointer is released at client position `(x, y)` pixels at `time`
milliseconds (three.js `pointerup`, delivered only while a gesture holds the
window listeners). Ending a rotation within 120 ms of its last move starts the
inertia (see [`arcball_animation_frame!`](@ref)); lifting one of two fingers
leaves one finger that rotates again after it moves 32 device pixels. Two
primary left-button clicks or taps, each held at most 250 ms, at most 300 ms
apart and at most 24 device pixels apart, focus on the first mesh of `scene`
under the pointer (animated when `enable_animations`).
"""
function arcball_pointer_up!(ac::ArcballControls, x, y; time,
                             pointer_type::Symbol=:mouse, pointer_id::Integer=1,
                             is_primary::Union{Nothing, Bool}=nothing)
    event = _arcball_event(ac, x, y, time, pointer_id, "pointer")
    touch = _checked_pointer_type(pointer_type) === :touch
    _validate_arcball_input(ac)
    primary = _arcball_primary_up!(ac, touch, event.id)
    is_primary === nothing || (primary = is_primary)
    ac.listening || return ac
    if touch && ac.input !== :cursor
        index = findfirst(p -> p.id == event.id, ac.touch_current)
        if index !== nothing
            deleteat!(ac.touch_current, index)
            deleteat!(ac.touch_start, index)
        end
        if ac.input === :one_finger || ac.input === :one_finger_switched
            ac.listening = false
            ac.input = :none
            _arcball_single_pan_end!(ac, event.time)
        elseif ac.input === :two_finger
            _arcball_update_tb_state!(ac, :idle, false)   # onDoublePanEnd
            _arcball_update_tb_state!(ac, :idle, false)   # onPinchEnd
            _arcball_update_tb_state!(ac, :idle, false)   # onRotateEnd
            ac.gizmos_active = false
            ac.input = :one_finger_switched
        elseif ac.input === :mult_finger && isempty(ac.touch_current)
            ac.listening = false
            ac.input = :none
            _arcball_update_tb_state!(ac, :idle, false)   # onTriplePanEnd
        end
    elseif !touch && ac.input === :cursor
        ac.listening = false
        ac.input = :none
        _arcball_single_pan_end!(ac, event.time)
        ac.button = -1
    end
    primary || return ac
    if !ac.down_valid
        ac.nclicks = 0
        empty!(ac.down_events)
        return ac
    end
    if event.time - ac.down_events[end].time > _ARCBALL_MAX_DOWN_TIME
        ac.down_valid = false
        ac.nclicks = 0
        empty!(ac.down_events)
        return ac
    end
    if ac.nclicks == 0
        ac.nclicks = 1
        ac.click_start = event.time
        return ac
    end
    click_interval = event.time - ac.click_start
    movement = _arcball_pointer_distance(ac.down_events[2], ac.down_events[1]) *
               ac.device_pixel_ratio
    if click_interval <= _ARCBALL_MAX_INTERVAL && movement <= _ARCBALL_POS_THRESHOLD
        ac.nclicks = 0
        empty!(ac.down_events)
        _arcball_double_tap!(ac, event)
    else
        ac.nclicks = 1
        popfirst!(ac.down_events)
        ac.click_start = event.time
    end
    return ac
end

"""
    arcball_pointer_cancel!(controls::ArcballControls; pointer_type=:mouse,
                            pointer_id=1)

A pointer is cancelled (three.js `pointercancel`): every stored touch is
dropped and the input returns to idle. The camera stays where the gesture
left it.
"""
function arcball_pointer_cancel!(ac::ArcballControls; pointer_type::Symbol=:mouse,
                                 pointer_id::Integer=1)
    touch = _checked_pointer_type(pointer_type) === :touch
    _arcball_primary_up!(ac, touch, Int(pointer_id))
    empty!(ac.touch_start)
    empty!(ac.touch_current)
    ac.input = :none
    return ac
end

"""
    arcball_wheel!(controls::ArcballControls, delta_y; delta_x=0.0, x=0.0,
                   y=0.0, ctrl_key=false, meta_key=false, shift_key=false)

A wheel step (three.js `wheel`) runs the `:wheel` action of the held
modifier. Zoom scales by `scale_factor^(-delta_y / 125)` (one 125-pixel notch
is one `scale_factor` step) about the gizmo centre, or about the point under
`(x, y)` client pixels with `cursor_zoom` and `enable_pan`; FOV (perspective
cameras) changes the field of view in a vertigo style, reading `delta_x`
instead when it is non-zero. Ignored while disabled or while zoom is
disabled.
"""
function arcball_wheel!(ac::ArcballControls, delta_y; delta_x=0.0, x=0.0, y=0.0,
                        ctrl_key::Bool=false, meta_key::Bool=false,
                        shift_key::Bool=false)
    dy = _checked_control_scalar(delta_y, "ArcballControls wheel delta_y")
    dx = _checked_control_scalar(delta_x, "ArcballControls wheel delta_x")
    px = _checked_control_scalar(x, "ArcballControls wheel x")
    py = _checked_control_scalar(y, "ArcballControls wheel y")
    (ac.enabled && ac.enable_zoom) || return ac
    _validate_arcball_input(ac)
    operation = _arcball_op_from_action(
        ac, :wheel, _arcball_modifier(ctrl_key, meta_key, shift_key))
    (operation === :zoom || operation === :fov) || return ac
    sf = ac.scale_factor
    notch_size(s) = s > 0 ? 1 / (sf^s) : s < 0 ? sf^(-s) : 1.0
    if operation === :zoom
        _arcball_update_tb_state!(ac, :scale, true)
        size = notch_size(dy / _ARCBALL_NOTCH_DELTA_Y)
        point = (ac.cursor_zoom && ac.enable_pan) ?
            _arcball_plane_point_world(ac, px, py, ac.gizmo_position,
                                       ac.camera isa OrthographicCamera) :
            ac.gizmo_position
        _arcball_apply_transform!(ac, _arcball_scale(ac, size, point))
    elseif operation === :fov && _arcball_is_perspective(ac)
        cam = ac.camera
        _arcball_update_tb_state!(ac, :fov, true)
        sgn = dy / _ARCBALL_NOTCH_DELTA_Y
        size = sgn > 0 ? 1 / sf : sgn < 0 ? sf : 1.0
        dx != 0 && (size = notch_size(dx / _ARCBALL_NOTCH_DELTA_Y))
        distance = _arcball_distance(
            _arcball_matrix_position(ac.camera_matrix_state), ac.gizmo_position)
        x_new = _arcball_clamp(distance / size, ac.min_distance, ac.max_distance)
        half_height = distance * tan(cam.fov * 0.5)
        new_fov = atan(half_height / x_new) * 2
        if new_fov > ac.max_fov
            new_fov = ac.max_fov
        elseif new_fov < ac.min_fov
            new_fov = ac.min_fov
        end
        new_distance = half_height / tan(new_fov / 2)
        _arcball_set_fov!(ac, new_fov)
        _arcball_apply_transform!(ac, _arcball_scale(
            ac, distance / new_distance, ac.gizmo_position, false))
    end
    if ac.grid_active
        _arcball_dispose_grid!(ac)
        _arcball_draw_grid!(ac)
    end
    _arcball_update_tb_state!(ac, :idle, false)
    return ac
end

# ---- public state operations -----------------------------------------------

"""
    arcball_update!(controls::ArcballControls)

three.js `ArcballControls.update()`: moves the gizmo to a changed `target`
(rebuilding it with a recomputed radius), brings an orthographic zoom back
into `min_zoom..max_zoom` or a perspective distance into
`min_distance..max_distance` and FOV into `min_fov..max_fov`, refreshes the
trackball radius and aims the camera at the gizmo centre with
`controls.up`. Animations do not need it; call
[`arcball_animation_frame!`](@ref) for those.
"""
function arcball_update!(ac::ArcballControls)
    _validate_arcball(ac)
    cam = ac.camera
    if ac.target != ac.current_target
        ac.gizmo_position = ac.target
        ac.tb_radius = _arcball_tb_radius(ac)
        _arcball_make_gizmos!(ac, ac.target, ac.tb_radius)
        ac.current_target = ac.target
    end
    if cam isa OrthographicCamera
        if cam.zoom > ac.max_zoom || cam.zoom < ac.min_zoom
            new_zoom = _arcball_clamp(cam.zoom, ac.min_zoom, ac.max_zoom)
            _arcball_apply_transform!(ac, _arcball_scale(
                ac, new_zoom / cam.zoom, ac.gizmo_position, true))
        end
    else
        distance = _arcball_distance(cam.position, ac.gizmo_position)
        if distance > ac.max_distance + _ARCBALL_EPS ||
           distance < ac.min_distance - _ARCBALL_EPS
            new_distance = _arcball_clamp(distance, ac.min_distance, ac.max_distance)
            _arcball_apply_transform!(ac, _arcball_scale(
                ac, new_distance / distance, ac.gizmo_position))
            _arcball_update_matrix_state!(ac)
        end
        if cam.fov < ac.min_fov || cam.fov > ac.max_fov
            cam.fov = _arcball_clamp(cam.fov, ac.min_fov, ac.max_fov)
        end
        old_radius = ac.tb_radius
        ac.tb_radius = _arcball_tb_radius(ac)
        if old_radius < ac.tb_radius - _ARCBALL_EPS ||
           old_radius > ac.tb_radius + _ARCBALL_EPS
            s = ac.gizmo_scale
            ac.gizmo_radius = ac.tb_radius / ((s.x + s.y + s.z) / 3)
        end
    end
    _arcball_look_at!(ac, ac.gizmo_position)
    return ac
end

"""
    arcball_set_camera!(controls::ArcballControls, camera)

three.js `setCamera`: control `camera` from now on. It is aimed at `target`,
and its pose, zoom, FOV, near and far become the reset state and the
reference for `adjust_near_far`; the gizmo is rebuilt around `target`.
"""
function arcball_set_camera!(ac::ArcballControls, camera::_OrbitCamera)
    return _arcball_set_camera!(ac, camera)
end

"""
    arcball_save_state!(controls::ArcballControls)

three.js `saveState`: remember the current target, camera pose, near, far,
zoom, up vector, FOV and gizmo transform for [`arcball_reset!`](@ref).
"""
function arcball_save_state!(ac::ArcballControls)
    _validate_arcball(ac)
    cam = ac.camera
    ac.target0 = ac.target
    ac.camera_matrix_state0 = _arcball_camera_matrix(ac)
    ac.gizmo_matrix_state0 = _arcball_gizmo_matrix(ac)
    ac.near_pos = cam.near
    ac.far_pos = cam.far
    ac.zoom0 = cam.zoom
    ac.up0 = ac.up
    cam isa PerspectiveCamera && (ac.fov0 = cam.fov)
    return ac
end

"""
    arcball_reset!(controls::ArcballControls)

three.js `reset`: restore the saved target, camera pose, zoom, FOV, near, far
and up vector (the construction or [`arcball_set_camera!`](@ref) state until
[`arcball_save_state!`](@ref) is called; the saved target starts at the
origin), rebuild the gizmo at the saved position for the restored zoom, aim
the camera at it and return to idle. Pending animation frames stop when they
next run.
"""
function arcball_reset!(ac::ArcballControls)
    _validate_arcball(ac)
    cam = ac.camera
    zoom = _validated_camera_zoom(ac.zoom0)
    ac.target = ac.target0
    cam.zoom = zoom
    cam isa PerspectiveCamera && (cam.fov = ac.fov0)
    cam.near = ac.near_pos
    cam.far = ac.far_pos
    ac.camera_matrix_state = ac.camera_matrix_state0
    _arcball_set_camera_from_matrix!(ac, ac.camera_matrix_state)
    ac.up = ac.up0
    ac.gizmo_matrix_state = ac.gizmo_matrix_state0
    _arcball_set_gizmos_from_matrix!(ac, ac.gizmo_matrix_state0)
    ac.tb_radius = _arcball_tb_radius(ac)
    _arcball_make_gizmos!(ac, ac.gizmo_position, ac.tb_radius)
    _arcball_look_at!(ac, ac.gizmo_position)
    _arcball_update_tb_state!(ac, :idle, false)
    return ac
end

"""
    arcball_copy_state(controls::ArcballControls) -> ArcballState

three.js `copyState` without the clipboard: the current camera far, FOV
(perspective), local matrix, near, up vector and zoom, the gizmo matrix and
the target as an [`ArcballState`](@ref).
"""
function arcball_copy_state(ac::ArcballControls)
    _validate_arcball(ac)
    cam = ac.camera
    return ArcballState(cam.far, cam isa PerspectiveCamera ? cam.fov : nothing,
                        _arcball_camera_matrix(ac), cam.near, ac.up, cam.zoom,
                        _arcball_gizmo_matrix(ac), ac.target)
end

"""
    arcball_paste_state!(controls::ArcballControls, state::ArcballState)

three.js `pasteState`/`setStateFromJSON` without the clipboard: apply a
state from [`arcball_copy_state`](@ref) to the camera and the gizmo, rebuild
the gizmo for the camera zoom, aim the camera at it and return to idle. A
perspective camera needs a state with a FOV. three.js reads the copied target
with `Vector3.fromArray` from the `{x, y, z}` object `copyState` wrote and so
loses it; the target is restored here.
"""
function arcball_paste_state!(ac::ArcballControls, st::ArcballState)
    _validate_arcball(ac)
    cam = ac.camera
    label = "ArcballControls pasted state"
    target = _checked_control_vec3(st.target, "$label target")
    up = _checked_control_vec3(st.camera_up, "$label camera_up")
    zoom = _validated_camera_zoom(st.camera_zoom)
    near = _checked_control_scalar(st.camera_near, "$label camera_near")
    far = Float64(st.camera_far)
    isnan(far) && throw(ArgumentError("$label camera_far must not be NaN"))
    all(isfinite, st.camera_matrix.e) && all(isfinite, st.gizmo_matrix.e) ||
        throw(ArgumentError("$label matrices must be finite"))
    fov = nothing
    if cam isa PerspectiveCamera
        st.camera_fov === nothing && throw(ArgumentError(
            "$label has no camera_fov for a PerspectiveCamera"))
        fov = _checked_control_scalar(st.camera_fov, "$label camera_fov")
    end
    ac.target = target
    ac.camera_matrix_state = st.camera_matrix
    _arcball_set_camera_from_matrix!(ac, ac.camera_matrix_state)
    ac.up = up
    cam.near = near
    cam.far = far
    cam.zoom = zoom
    fov === nothing || (cam.fov = fov)
    ac.gizmo_matrix_state = st.gizmo_matrix
    _arcball_set_gizmos_from_matrix!(ac, ac.gizmo_matrix_state)
    ac.tb_radius = _arcball_tb_radius(ac)
    gizmo_state0 = ac.gizmo_matrix_state0
    _arcball_make_gizmos!(ac, ac.gizmo_position, ac.tb_radius)
    ac.gizmo_matrix_state0 = gizmo_state0
    _arcball_look_at!(ac, ac.gizmo_position)
    _arcball_update_tb_state!(ac, :idle, false)
    return ac
end

"""
    arcball_set_tb_radius!(controls::ArcballControls, radius_factor)

three.js `setTbRadius`: set `radius_factor` (the gizmo size relative to the
smaller half side of the view) and recompute the trackball radius and the
gizmo circles.
"""
function arcball_set_tb_radius!(ac::ArcballControls, value)
    factor = _checked_control_scalar(value, "ArcballControls radius_factor")
    ac.radius_factor = factor
    _validate_arcball(ac)
    ac.tb_radius = _arcball_tb_radius(ac)
    ac.gizmo_radius = ac.tb_radius
    return ac
end

"""
    arcball_set_gizmos_visible!(controls::ArcballControls, visible::Bool)

three.js `setGizmosVisible`: set `gizmos_visible`.
"""
function arcball_set_gizmos_visible!(ac::ArcballControls, visible::Bool)
    ac.gizmos_visible = visible
    return ac
end

"""
    arcball_activate_gizmos!(controls::ArcballControls, active::Bool)

three.js `activateGizmos`: highlight the gizmos (`gizmos_active`; three.js
opacity 1 instead of 0.6), as the control does while rotating.
"""
function arcball_activate_gizmos!(ac::ArcballControls, active::Bool)
    ac.gizmos_active = active
    return ac
end

"""
    arcball_dispose_grid!(controls::ArcballControls)

three.js `disposeGrid`: stop showing the pan grid (`grid_active`), which
three.js only shows with a scene.
"""
arcball_dispose_grid!(ac::ArcballControls) = _arcball_dispose_grid!(ac)

"""
    arcball_resize!(controls::ArcballControls)

The three.js window `resize` handler: recompute the trackball radius for the
camera's current frustum (call it after changing the aspect or the
orthographic bounds) and resize the gizmo circles for the gizmo scale.
"""
function arcball_resize!(ac::ArcballControls)
    _validate_arcball(ac)
    s = ac.gizmo_scale
    scale = (s.x + s.y + s.z) / 3
    ac.tb_radius = _arcball_tb_radius(ac)
    ac.gizmo_radius = ac.tb_radius / scale
    return ac
end

# ========================== Clock ==========================

"""
    Clock(auto_start::Bool=true)

Frame timer modelled on three.js `Clock` (src/core/Clock.js), in seconds.
Fields: `start_time` (time of the last start), `last_time` (three.js
`oldTime`), `elapsed_time` (time accumulated while running), `running` and
`auto_start`.

`Clock()` starts at construction, so `start_time` is set immediately and the
first `clock_delta!` returns the time since construction (three.js starts on
the first `getDelta`, which returns 0). `Clock(false)` is created stopped:
`clock_delta!` returns 0 until `clock_start!`. A stopped clock with
`auto_start` set restarts on the next `clock_delta!`, which returns 0, as
three.js does; `clock_stop!` clears `auto_start`.

Every `now` argument defaults to the current monotonic time in seconds; pass
it explicitly for deterministic stepping.
"""
mutable struct Clock
    start_time::Float64
    last_time::Float64
    running::Bool
    auto_start::Bool
    elapsed_time::Float64
end

@inline _clock_now() = Float64(time_ns()) / 1.0e9

# Positional form kept from 1.0: a running clock whose elapsed time is the
# span since `start_time` already measured up to `last_time`.
Clock(start_time::Real, last_time::Real, running::Bool) =
    Clock(Float64(start_time), Float64(last_time), running, true,
          Float64(last_time) - Float64(start_time))

function Clock(auto_start::Bool=true)
    t = _clock_now()
    return Clock(t, t, auto_start, auto_start, 0.0)
end

function _validate_clock(c::Clock)
    _checked_control_scalar(c.start_time, "Clock start_time")
    _checked_control_scalar(c.last_time, "Clock last_time")
    _checked_control_scalar(c.elapsed_time, "Clock elapsed_time")
    return nothing
end

"""
    clock_start!(clock[, now]) -> clock

Start (or restart) `clock` at `now`: three.js `Clock.start` sets the start
and previous times to `now`, zeroes the elapsed time and sets `running`.
"""
function clock_start!(c::Clock, now=_clock_now())
    current = _checked_control_scalar(now, "Clock current time")
    c.start_time = current
    c.last_time = current
    c.elapsed_time = 0.0
    c.running = true
    return c
end

"""
    clock_stop!(clock[, now]) -> clock

Stop `clock` after accumulating the time up to `now` (three.js `Clock.stop`
calls `getElapsedTime` first). A stopped clock keeps its elapsed time and
returns 0 from `clock_delta!`; `auto_start` is cleared, so only
`clock_start!` runs it again.
"""
function clock_stop!(c::Clock, now=_clock_now())
    clock_delta!(c, now)
    c.running = false
    c.auto_start = false
    return c
end

"""
    clock_elapsed(clock[, now]) -> Float64

Seconds the clock has run up to `now`: the accumulated `elapsed_time` plus,
while running, the span since the last `clock_delta!`. A stopped clock
returns its accumulated time. Unlike three.js `getElapsedTime`, it does not
consume the pending delta, so a following `clock_delta!` still measures from
the previous `clock_delta!`.
"""
function clock_elapsed(c::Clock, now=_clock_now())
    _validate_clock(c)
    current = _checked_control_scalar(now, "Clock current time")
    c.running || return c.elapsed_time
    return _checked_control_scalar(
        c.elapsed_time + (current - c.last_time), "Clock elapsed time")
end

"""
    clock_delta!(clock[, now]) -> Float64

Seconds since the previous `clock_delta!` (or start), as three.js
`Clock.getDelta`: the time is added to `elapsed_time` and `last_time`
advances to `now`. A stopped clock returns 0; a stopped clock with
`auto_start` starts at `now` and returns 0.
"""
function clock_delta!(c::Clock, now=_clock_now())
    _validate_clock(c)
    current = _checked_control_scalar(now, "Clock current time")
    if c.auto_start && !c.running
        clock_start!(c, current)
        return 0.0
    end
    c.running || return 0.0
    d = _checked_control_scalar(current - c.last_time, "Clock delta")
    elapsed = _checked_control_scalar(c.elapsed_time + d, "Clock elapsed time")
    c.last_time = current
    c.elapsed_time = elapsed
    return d
end

"""
    FrameTimer(now=current time) -> FrameTimer

Frame timer modelled on three.js `Timer` (src/core/Timer.js), the r183
replacement for `Clock`, in seconds. Call `timer_update!` once per frame,
then read the frame's `timer_delta` and the accumulated `timer_elapsed`;
reading never changes the timer. `time_scale` (three.js `setTimescale`)
scales every later delta. The Page Visibility hook of three.js
(`connect`/`disconnect`) has no headless counterpart.

Fields: `start_time` (absolute), `previous_time` and `current_time`
(relative to `start_time`), `delta`, `elapsed` and `time_scale`.
"""
mutable struct FrameTimer
    start_time::Float64
    previous_time::Float64
    current_time::Float64
    delta::Float64
    elapsed::Float64
    time_scale::Float64
end

FrameTimer(now=_clock_now()) =
    FrameTimer(_checked_control_scalar(now, "FrameTimer start time"),
               0.0, 0.0, 0.0, 0.0, 1.0)

"""
    timer_update!(timer[, timestamp]) -> timer

Advance `timer` to the absolute `timestamp` (seconds, default now), as
three.js `Timer.update`: the frame delta is the span since the previous
update (or `timer_reset!`) times `time_scale`, and it is added to the
elapsed time.
"""
function timer_update!(t::FrameTimer, timestamp=_clock_now())
    now = _checked_control_scalar(timestamp, "FrameTimer timestamp")
    scale = _checked_control_scalar(t.time_scale, "FrameTimer time_scale")
    previous = t.current_time
    current = _checked_control_scalar(now - t.start_time, "FrameTimer current time")
    delta = _checked_control_scalar((current - previous) * scale, "FrameTimer delta")
    elapsed = _checked_control_scalar(t.elapsed + delta, "FrameTimer elapsed time")
    t.previous_time = previous
    t.current_time = current
    t.delta = delta
    t.elapsed = elapsed
    return t
end

"""
    timer_reset!(timer[, now]) -> timer

Measure the next `timer_update!` delta from `now` instead of the previous
update (three.js `Timer.reset`); the current delta and elapsed time are kept.
"""
function timer_reset!(t::FrameTimer, now=_clock_now())
    current = _checked_control_scalar(now, "FrameTimer current time")
    t.current_time = _checked_control_scalar(current - t.start_time,
                                             "FrameTimer current time")
    return t
end

"""
    timer_delta(timer) -> Float64

Scaled seconds between the two latest `timer_update!` calls (three.js
`Timer.getDelta`); 0 before the first update.
"""
timer_delta(t::FrameTimer) = t.delta

"""
    timer_elapsed(timer) -> Float64

Sum of every scaled frame delta so far (three.js `Timer.getElapsed`).
"""
timer_elapsed(t::FrameTimer) = t.elapsed

# ========================== Animation ==========================

abstract type AbstractKeyframeTrack end

function _validate_keyframe_times(kind::AbstractString, times::Vector{Float64})
    isempty(times) && throw(ArgumentError("$kind requires at least one keyframe"))
    for i in eachindex(times)
        isfinite(times[i]) ||
            throw(ArgumentError("$kind times must be finite"))
        i == firstindex(times) && continue
        times[i] > times[i - 1] ||
            throw(ArgumentError("$kind times must be strictly increasing"))
    end
    return nothing
end

function _validate_keyframe_values(kind::AbstractString, times::Vector{Float64}, values::AbstractVector)
    length(times) == length(values) ||
        throw(ArgumentError("$kind times and values must have the same length"))
    _validate_keyframe_times(kind, times)
    return nothing
end

@inline _finite_keyframe_value(value::Real) = isfinite(value)
@inline _finite_keyframe_value(value::Vec3) =
    isfinite(value.x) && isfinite(value.y) && isfinite(value.z)
@inline _finite_keyframe_value(value::Quaternion) =
    isfinite(value.x) && isfinite(value.y) &&
    isfinite(value.z) && isfinite(value.w)
@inline function _finite_keyframe_value(values::AbstractVector{<:Real})
    @inbounds for value in values
        isfinite(value) || return false
    end
    return true
end

@noinline function _throw_keyframe_values(kind::AbstractString)
    throw(ArgumentError("$kind values and tangents must be finite"))
end

function _validate_finite_keyframe_values(kind::AbstractString,
                                          values::AbstractVector)
    @inbounds for value in values
        _finite_keyframe_value(value) || _throw_keyframe_values(kind)
    end
    return nothing
end

function _validate_morph_value_widths(kind::AbstractString, values::Vector{Vector{Float64}})
    isempty(values) && return nothing
    width = length(values[1])
    width > 0 || throw(ArgumentError("$kind morph-weight keyframes must not be empty"))
    for v in values
        length(v) == width ||
            throw(ArgumentError("$kind morph-weight keyframes must have matching lengths"))
    end
    return nothing
end

# Scalar/Vec3 property track. `interpolation` selects the sampling mode:
#   :linear (default) — piecewise linear, byte-identical to the original path.
#   :step             — hold the previous keyframe value until the next key.
#   :cubic            — Catmull-Rom spline through the keyframes.
struct KeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol                 # e.g. :position, :scale
    times::Vector{Float64}
    values::Vector{Vec3{Float64}}
    interpolation::Symbol            # :linear | :step | :cubic

    function KeyframeTrack(target::AbstractObject3D, property::Symbol,
                           times::Vector{Float64}, values::Vector{Vec3{Float64}},
                           interpolation::Symbol)
        interpolation in (:linear, :step, :cubic) ||
            throw(ArgumentError("unsupported keyframe interpolation: $interpolation"))
        _validate_keyframe_values("KeyframeTrack", times, values)
        _validate_finite_keyframe_values("KeyframeTrack", values)
        new(target, property, times, values, interpolation)
    end
end

struct NumberKeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol
    component::Int                    # 0 writes the scalar property; 1-based for x/y/z/w or arrays
    times::Vector{Float64}
    values::Vector{Float64}
    interpolation::Symbol             # :linear | :step | :cubic
    # Morph target name of a `morphTargetInfluences[name]` path ("" otherwise).
    # Each node the track drives resolves it in its own `morph_target_names`,
    # as three.js PropertyBinding.bind looks it up in each bound object's
    # morphTargetDictionary; `component` is the index on the first node that
    # names it.
    morph_name::String

    function NumberKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                 component::Int, times::Vector{Float64},
                                 values::Vector{Float64}, interpolation::Symbol,
                                 morph_name::String="")
        interpolation in (:linear, :step, :cubic) ||
            throw(ArgumentError("unsupported number keyframe interpolation: $interpolation"))
        component >= 0 || throw(ArgumentError("animation component index must be non-negative"))
        _validate_keyframe_values("NumberKeyframeTrack", times, values)
        _validate_finite_keyframe_values("NumberKeyframeTrack", values)
        new(target, property, component, times, values, interpolation, morph_name)
    end
end

function _animation_component_index(s::AbstractString)
    s in ("x", "r") && return 1
    s in ("y", "g") && return 2
    s in ("z", "b") && return 3
    s in ("w", "a") && return 4
    all(isdigit, s) && return parse(Int, s) + 1
    throw(ArgumentError("unsupported animation component: $s"))
end

const _TEXTURE_ANIMATION_FIELD_ALIASES = Dict(
    "map" => "map",
    "alphaMap" => "alpha_map",
    "alpha_map" => "alpha_map",
    "aoMap" => "ao_map",
    "ao_map" => "ao_map",
    "lightMap" => "light_map",
    "light_map" => "light_map",
    "emissiveMap" => "emissive_map",
    "emissive_map" => "emissive_map",
    "roughnessMap" => "roughness_map",
    "roughness_map" => "roughness_map",
    "metalnessMap" => "metalness_map",
    "metalness_map" => "metalness_map",
    "normalMap" => "normal_map",
    "normal_map" => "normal_map",
    "matcap" => "matcap",
    "gradientMap" => "gradient_map",
    "gradient_map" => "gradient_map",
    "clearcoatMap" => "clearcoat_map",
    "clearcoat_map" => "clearcoat_map",
    "clearcoatRoughnessMap" => "clearcoat_roughness_map",
    "clearcoat_roughness_map" => "clearcoat_roughness_map",
    "clearcoatNormalMap" => "clearcoat_normal_map",
    "clearcoat_normal_map" => "clearcoat_normal_map",
    "transmissionMap" => "transmission_map",
    "transmission_map" => "transmission_map",
    "thicknessMap" => "thickness_map",
    "thickness_map" => "thickness_map",
    "sheenColorMap" => "sheen_color_map",
    "sheen_color_map" => "sheen_color_map",
    "sheenRoughnessMap" => "sheen_roughness_map",
    "sheen_roughness_map" => "sheen_roughness_map",
    "iridescenceMap" => "iridescence_map",
    "iridescence_map" => "iridescence_map",
    "iridescenceThicknessMap" => "iridescence_thickness_map",
    "iridescence_thickness_map" => "iridescence_thickness_map",
    "specularIntensityMap" => "specular_intensity_map",
    "specular_intensity_map" => "specular_intensity_map",
    "specularColorMap" => "specular_color_map",
    "specular_color_map" => "specular_color_map",
    "anisotropyMap" => "anisotropy_map",
    "anisotropy_map" => "anisotropy_map",
)

const _TEXTURE_ANIMATION_PROPERTY_ALIASES = Dict(
    "offset" => "offset",
    "repeat" => "repeat",
    "center" => "center",
    "rotation" => "rotation",
    "matrixAutoUpdate" => "matrix_auto_update",
    "matrix_auto_update" => "matrix_auto_update",
)

const _TEXTURE_ANIMATION_FIELDS = Tuple(Symbol(v) for v in
    sort!(unique(collect(values(_TEXTURE_ANIMATION_FIELD_ALIASES)));
          by=length, rev=true))
const _TEXTURE_ANIMATION_TRACK_PROPERTIES = let
    props = (:offset, :repeat, :center, :rotation, :matrix_auto_update)
    pairs = Pair{Symbol,Tuple{Symbol,Symbol}}[]
    for field in _TEXTURE_ANIMATION_FIELDS, prop in props
        push!(pairs, Symbol(String(field), "_", String(prop)) => (field, prop))
    end
    Dict(pairs)
end
const _TEXTURE_ANIMATION_CANONICAL_PROPERTIES = Dict(
    String(property) => property for property in keys(_TEXTURE_ANIMATION_TRACK_PROPERTIES)
)
const _TEXTURE_ANIMATION_PATH_PROPERTIES = Dict(
    (String(field), String(texture_property)) => property
    for (property, (field, texture_property)) in _TEXTURE_ANIMATION_TRACK_PROPERTIES
)

function _texture_animation_property_symbol(s::AbstractString)
    parts = split(String(s), ".")
    if length(parts) == 1
        return get(_TEXTURE_ANIMATION_CANONICAL_PROPERTIES, parts[1], nothing)
    end
    length(parts) == 2 || return nothing
    field = get(_TEXTURE_ANIMATION_FIELD_ALIASES, parts[1], nothing)
    property = get(_TEXTURE_ANIMATION_PROPERTY_ALIASES, parts[2], nothing)
    (field === nothing || property === nothing) && return nothing
    return get(_TEXTURE_ANIMATION_PATH_PROPERTIES, (field, property), nothing)
end

function _animation_property_alias(s::AbstractString)
    texture_property = _texture_animation_property_symbol(s)
    texture_property !== nothing && return texture_property
    s = replace(s, "." => "_")
    s == "alphaTest" && return :alpha_test
    s == "depthTest" && return :depth_test
    s == "depthWrite" && return :depth_write
    s == "normalScale" && return :normal_scale
    s == "groundColor" && return :ground_color
    s == "lineWidth" && return :linewidth
    s == "emissiveIntensity" && return :emissive_intensity
    s == "aoMapIntensity" && return :ao_map_intensity
    s == "lightMapIntensity" && return :light_map_intensity
    s == "envMapIntensity" && return :env_map_intensity
    s == "gradientSteps" && return :gradient_steps
    s == "toonSteps" && return :gradient_steps
    s == "depthNear" && return :near
    s == "depthFar" && return :far
    s == "clearcoatRoughness" && return :clearcoat_roughness
    s == "clearcoatNormalScale" && return :clearcoat_normal_scale
    s == "sheenColor" && return :sheen_color
    s == "sheenRoughness" && return :sheen_roughness
    s == "iridescenceIor" && return :iridescence_ior
    s == "iridescenceIOR" && return :iridescence_ior
    s == "iridescenceThickness" && return :iridescence_thickness
    s == "iridescenceThicknessMinimum" && return :iridescence_thickness_min
    s == "specularIntensity" && return :specular_intensity
    s == "specularColor" && return :specular_color
    s == "attenuationDistance" && return :attenuation_distance
    s == "attenuationColor" && return :attenuation_color
    s == "anisotropyRotation" && return :anisotropy_rotation
    s == "sizeAttenuation" && return :size_attenuation
    s == "morphTargetInfluences" && return :morph_target_influences
    s == "morph_target_influences" && return :morph_target_influences
    s == "material_rotation" && return :material_rotation
    s == "position" && return :position
    s == "scale" && return :scale
    s == "rotation" && return :rotation
    s == "quaternion" && return :quaternion
    return nothing
end

function _existing_animation_property(value, requested::AbstractString)
    canonical = occursin('.', requested) ? replace(requested, "." => "_") : requested
    for property in propertynames(value)
        property isa Symbol || continue
        name = String(property)
        (name == requested || name == canonical) && return property
    end
    return nothing
end

function _animation_material(target::AbstractObject3D)
    hasproperty(target, :material) || return nothing
    return getproperty(target, :material)
end

function _resolved_animation_property(target::AbstractObject3D,
                                      requested::AbstractString,
                                      material_path::Bool)
    alias = _animation_property_alias(requested)
    material = _animation_material(target)

    if alias !== nothing && haskey(_TEXTURE_ANIMATION_TRACK_PROPERTIES, alias)
        material === nothing &&
            throw(ArgumentError("animation target has no material for property path: $requested"))
        field, _ = _TEXTURE_ANIMATION_TRACK_PROPERTIES[alias]
        hasproperty(material, field) ||
            throw(ArgumentError("animation material has no property path: $requested"))
        return alias
    end

    if material_path
        material === nothing &&
            throw(ArgumentError("animation target has no material for property path: $requested"))
        alias === :material_rotation && hasproperty(material, :rotation) &&
            return :material_rotation
        if alias !== nothing && hasproperty(material, alias)
            return alias === :rotation ? :material_rotation : alias
        end
        property = _existing_animation_property(material, requested)
        property === nothing &&
            throw(ArgumentError("animation material has no property path: $requested"))
        return property === :rotation ? :material_rotation : property
    end

    if alias === :quaternion && hasproperty(target, :rotation)
        return :quaternion
    elseif alias === :morph_target_influences
        # Morph tracks may bind to a parent and update matching descendants.
        return :morph_target_influences
    elseif alias !== nothing && hasproperty(target, alias)
        return alias
    end

    property = _existing_animation_property(target, requested)
    property !== nothing && return property

    if material !== nothing
        alias === :material_rotation && hasproperty(material, :rotation) &&
            return :material_rotation
        alias !== nothing && hasproperty(material, alias) && return alias
        property = _existing_animation_property(material, requested)
        property !== nothing && return property
    end

    throw(ArgumentError("animation target has no property path: $requested"))
end

# 1-based index of the morph target called `name`, looked up like three.js
# PropertyBinding.bind (morphTargetDictionary, before any numeric reading of
# the index): on the target, else on the first descendant that names it, as
# morph tracks bound to a parent drive its descendants. With duplicate names
# the last one wins, as in Mesh.updateMorphTargets.
function _morph_target_name_index(obj, name::AbstractString)
    if hasproperty(obj, :morph_target_names)
        index = findlast(==(name), getproperty(obj, :morph_target_names))
        index === nothing || return index
    end
    for child in get_children(obj)
        index = _morph_target_name_index(child, name)
        index === nothing || return index
    end
    return nothing
end

_parse_animation_property_path(target::AbstractObject3D, path::AbstractString) =
    _parse_animation_property_path_named(target, path)[1:2]

# (property, component, morph name): the name is the bracket text of a
# morphTargetInfluences path that names a morph target of `target` or one of
# its descendants, and "" otherwise.
function _parse_animation_property_path_named(target::AbstractObject3D,
                                              path::AbstractString)
    p = startswith(path, ".") ? path[2:end] : String(path)
    isempty(p) && throw(ArgumentError("animation property path must not be empty"))
    material_path = startswith(p, "material.")
    material_path && (p = p[10:end])
    isempty(p) && throw(ArgumentError("animation material property path must not be empty"))
    bracket = match(r"^(.+)\[([^\]]+)\]$", p)
    if bracket !== nothing
        property = _resolved_animation_property(target, bracket.captures[1], material_path)
        index = bracket.captures[2]
        if property === :morph_target_influences
            named = _morph_target_name_index(target, index)
            named === nothing || return property, named, String(index)
        end
        return property, _animation_component_index(index), ""
    end
    dot = match(r"^(.+)\.([A-Za-z])$", p)
    if dot !== nothing
        return _resolved_animation_property(target, dot.captures[1], material_path),
               _animation_component_index(dot.captures[2]), ""
    end
    return _resolved_animation_property(target, p, material_path), 0, ""
end

# 1-based influence index that the morph name `name` addresses on `node`:
# its own morph_target_names entry (the last duplicate, as
# Mesh.updateMorphTargets builds the dictionary), else the numeric reading of
# the name (PropertyBinding keeps an unknown name as the array index), else 0
# (the node has no such morph target and is left unchanged).
function _node_morph_name_index(node, name::String)
    if hasproperty(node, :morph_target_names)
        names = getproperty(node, :morph_target_names)
        if names isa Vector{String}
            index = findlast(==(name), names)
        else
            index = findlast(==(name), names)
        end
        index === nothing || return index
    end
    (!isempty(name) && all(isdigit, name)) || return 0
    value = tryparse(Int, name)
    return value === nothing || value == typemax(Int) ? 0 : value + 1
end

function _parse_animation_whole_property_path(target::AbstractObject3D,
                                              path::AbstractString,
                                              track_type::AbstractString)
    property, component = _parse_animation_property_path(target, path)
    component == 0 ||
        throw(ArgumentError("$track_type component property paths require NumberKeyframeTrack"))
    return property
end

# Backward-compatible four-argument constructor: the original positional call
# `KeyframeTrack(target, property, times, values)` keeps working and defaults to
# linear; `interpolation=:cubic` selects the spline mode.
KeyframeTrack(target::AbstractObject3D, property::Symbol,
              times::Vector{Float64}, values::Vector{Vec3{Float64}};
              interpolation::Symbol=:linear) =
    interpolation in (:linear, :step, :cubic) ?
        KeyframeTrack(target, property, times, values, interpolation) :
        throw(ArgumentError("unsupported keyframe interpolation: $interpolation"))

KeyframeTrack(target::AbstractObject3D, property_path::AbstractString,
              times::Vector{Float64}, values::Vector{Vec3{Float64}};
              interpolation::Symbol=:linear) =
    KeyframeTrack(target,
                  _parse_animation_whole_property_path(target, property_path,
                                                       "KeyframeTrack"),
                  times, values; interpolation=interpolation)

function NumberKeyframeTrack(target::AbstractObject3D, property::Symbol,
                             times::Vector{Float64}, values::Vector{Float64};
                             interpolation::Symbol=:linear, component::Int=0)
    interpolation in (:linear, :step, :cubic) ||
        throw(ArgumentError("unsupported number keyframe interpolation: $interpolation"))
    component >= 0 || throw(ArgumentError("animation component index must be non-negative"))
    NumberKeyframeTrack(target, property, component, times, values, interpolation)
end

function NumberKeyframeTrack(target::AbstractObject3D, property_path::AbstractString,
                             times::Vector{Float64}, values::Vector{Float64};
                             interpolation::Symbol=:linear)
    interpolation in (:linear, :step, :cubic) ||
        throw(ArgumentError("unsupported number keyframe interpolation: $interpolation"))
    property, component, morph_name =
        _parse_animation_property_path_named(target, property_path)
    NumberKeyframeTrack(target, property, component, times, values, interpolation,
                        morph_name)
end

# Dedicated rotation track: quaternion keyframes interpolated with slerp between
# adjacent frames by default (three.js `QuaternionKeyframeTrack`). `:step`
# holds the previous keyframe for glTF STEP interpolation.
struct QuaternionKeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol                          # e.g. :quaternion
    times::Vector{Float64}
    values::Vector{Quaternion{Float64}}
    interpolation::Symbol                     # :slerp | :step

    function QuaternionKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                     times::Vector{Float64},
                                     values::Vector{Quaternion{Float64}},
                                     interpolation::Symbol)
        interpolation in (:slerp, :step) ||
            throw(ArgumentError("unsupported quaternion keyframe interpolation: $interpolation"))
        _validate_keyframe_values("QuaternionKeyframeTrack", times, values)
        _validate_finite_keyframe_values("QuaternionKeyframeTrack", values)
        new(target, property, times, values, interpolation)
    end
end

QuaternionKeyframeTrack(target::AbstractObject3D, property::Symbol,
                        times::Vector{Float64},
                        values::Vector{Quaternion{Float64}};
                        interpolation::Symbol=:slerp) =
    QuaternionKeyframeTrack(target, property, times, values, interpolation)

QuaternionKeyframeTrack(target::AbstractObject3D, property_path::AbstractString,
                        times::Vector{Float64},
                        values::Vector{Quaternion{Float64}};
                        interpolation::Symbol=:slerp) =
    QuaternionKeyframeTrack(target,
                            _parse_animation_whole_property_path(target, property_path,
                                                                 "QuaternionKeyframeTrack"),
                            times, values; interpolation=interpolation)

struct MorphWeightsKeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol
    times::Vector{Float64}
    values::Vector{Vector{Float64}}
    interpolation::Symbol

    function MorphWeightsKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                       times::Vector{Float64},
                                       values::Vector{Vector{Float64}},
                                       interpolation::Symbol)
        interpolation in (:linear, :step) ||
            throw(ArgumentError("unsupported morph-weight interpolation: $interpolation"))
        _validate_keyframe_values("MorphWeightsKeyframeTrack", times, values)
        _validate_morph_value_widths("MorphWeightsKeyframeTrack", values)
        _validate_finite_keyframe_values("MorphWeightsKeyframeTrack", values)
        new(target, property, times, values, interpolation)
    end
end

function MorphWeightsKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                   times::Vector{Float64},
                                   values::Vector{Vector{Float64}};
                                   interpolation::Symbol=:linear)
    interpolation in (:linear, :step) ||
        throw(ArgumentError("unsupported morph-weight interpolation: $interpolation"))
    MorphWeightsKeyframeTrack(target, property, times,
                              [collect(Float64, v) for v in values],
                              interpolation)
end

function MorphWeightsKeyframeTrack(target::AbstractObject3D, property_path::AbstractString,
                                   times::Vector{Float64},
                                   values::Vector{Vector{Float64}};
                                   interpolation::Symbol=:linear)
    property = _parse_animation_whole_property_path(target, property_path,
                                                    "MorphWeightsKeyframeTrack")
    return MorphWeightsKeyframeTrack(target, property, times, values;
                                     interpolation=interpolation)
end

struct CubicSplineKeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol
    times::Vector{Float64}
    values::Vector{Vec3{Float64}}
    in_tangents::Vector{Vec3{Float64}}
    out_tangents::Vector{Vec3{Float64}}

    function CubicSplineKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                      times::Vector{Float64}, values::Vector{Vec3{Float64}},
                                      in_tangents::Vector{Vec3{Float64}},
                                      out_tangents::Vector{Vec3{Float64}})
        _validate_keyframe_values("CubicSplineKeyframeTrack", times, values)
        length(in_tangents) == length(times) ||
            throw(ArgumentError("CubicSplineKeyframeTrack in_tangents length must match times"))
        length(out_tangents) == length(times) ||
            throw(ArgumentError("CubicSplineKeyframeTrack out_tangents length must match times"))
        _validate_finite_keyframe_values("CubicSplineKeyframeTrack", values)
        _validate_finite_keyframe_values("CubicSplineKeyframeTrack", in_tangents)
        _validate_finite_keyframe_values("CubicSplineKeyframeTrack", out_tangents)
        new(target, property, times, values, in_tangents, out_tangents)
    end
end

struct CubicSplineQuaternionKeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol
    times::Vector{Float64}
    values::Vector{Quaternion{Float64}}
    in_tangents::Vector{Quaternion{Float64}}
    out_tangents::Vector{Quaternion{Float64}}

    function CubicSplineQuaternionKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                                times::Vector{Float64},
                                                values::Vector{Quaternion{Float64}},
                                                in_tangents::Vector{Quaternion{Float64}},
                                                out_tangents::Vector{Quaternion{Float64}})
        _validate_keyframe_values("CubicSplineQuaternionKeyframeTrack", times, values)
        length(in_tangents) == length(times) ||
            throw(ArgumentError("CubicSplineQuaternionKeyframeTrack in_tangents length must match times"))
        length(out_tangents) == length(times) ||
            throw(ArgumentError("CubicSplineQuaternionKeyframeTrack out_tangents length must match times"))
        _validate_finite_keyframe_values(
            "CubicSplineQuaternionKeyframeTrack", values)
        _validate_finite_keyframe_values(
            "CubicSplineQuaternionKeyframeTrack", in_tangents)
        _validate_finite_keyframe_values(
            "CubicSplineQuaternionKeyframeTrack", out_tangents)
        new(target, property, times, values, in_tangents, out_tangents)
    end
end

struct CubicSplineMorphWeightsKeyframeTrack <: AbstractKeyframeTrack
    target::AbstractObject3D
    property::Symbol
    times::Vector{Float64}
    values::Vector{Vector{Float64}}
    in_tangents::Vector{Vector{Float64}}
    out_tangents::Vector{Vector{Float64}}

    function CubicSplineMorphWeightsKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                                  times::Vector{Float64},
                                                  values::Vector{Vector{Float64}},
                                                  in_tangents::Vector{Vector{Float64}},
                                                  out_tangents::Vector{Vector{Float64}})
        _validate_keyframe_values("CubicSplineMorphWeightsKeyframeTrack", times, values)
        length(in_tangents) == length(times) ||
            throw(ArgumentError("CubicSplineMorphWeightsKeyframeTrack in_tangents length must match times"))
        length(out_tangents) == length(times) ||
            throw(ArgumentError("CubicSplineMorphWeightsKeyframeTrack out_tangents length must match times"))
        _validate_morph_value_widths("CubicSplineMorphWeightsKeyframeTrack", values)
        _validate_morph_value_widths("CubicSplineMorphWeightsKeyframeTrack", in_tangents)
        _validate_morph_value_widths("CubicSplineMorphWeightsKeyframeTrack", out_tangents)
        _validate_finite_keyframe_values(
            "CubicSplineMorphWeightsKeyframeTrack", values)
        _validate_finite_keyframe_values(
            "CubicSplineMorphWeightsKeyframeTrack", in_tangents)
        _validate_finite_keyframe_values(
            "CubicSplineMorphWeightsKeyframeTrack", out_tangents)
        new(target, property, times, values, in_tangents, out_tangents)
    end
end

CubicSplineKeyframeTrack(target::AbstractObject3D, property_path::AbstractString,
                         times::Vector{Float64}, values::Vector{Vec3{Float64}},
                         in_tangents::Vector{Vec3{Float64}},
                         out_tangents::Vector{Vec3{Float64}}) =
    CubicSplineKeyframeTrack(target,
                             _parse_animation_whole_property_path(target, property_path,
                                                                  "CubicSplineKeyframeTrack"),
                             times, values, in_tangents, out_tangents)

CubicSplineQuaternionKeyframeTrack(target::AbstractObject3D,
                                   property_path::AbstractString,
                                   times::Vector{Float64},
                                   values::Vector{Quaternion{Float64}},
                                   in_tangents::Vector{Quaternion{Float64}},
                                   out_tangents::Vector{Quaternion{Float64}}) =
    CubicSplineQuaternionKeyframeTrack(target,
                                       _parse_animation_whole_property_path(
                                           target, property_path,
                                           "CubicSplineQuaternionKeyframeTrack"),
                                       times, values, in_tangents, out_tangents)

CubicSplineMorphWeightsKeyframeTrack(target::AbstractObject3D,
                                     property_path::AbstractString,
                                     times::Vector{Float64},
                                     values::Vector{Vector{Float64}},
                                     in_tangents::Vector{Vector{Float64}},
                                     out_tangents::Vector{Vector{Float64}}) =
    CubicSplineMorphWeightsKeyframeTrack(target,
                                         _parse_animation_whole_property_path(
                                             target, property_path,
                                             "CubicSplineMorphWeightsKeyframeTrack"),
                                         times, values, in_tangents, out_tangents)

@inline _cr_scale(a::Real, s) = a * s
@inline _cr_scale(a::Vec3, s) = a * s
@inline _cr_add(a::Real, b::Real) = a + b
@inline _cr_add(a::Vec3, b::Vec3) = a + b

# Hermite/Catmull-Rom evaluation between p1 (at α=0) and p2 (at α=1) with
# tangents m1, m2 (already scaled to the local segment), parameter α∈[0,1].
@inline function _hermite(p1, p2, m1, m2, α)
    α2 = α * α
    α3 = α2 * α
    h00 = 2α3 - 3α2 + 1
    h10 = α3 - 2α2 + α
    h01 = -2α3 + 3α2
    h11 = α3 - α2
    _cr_add(_cr_add(_cr_scale(p1, h00), _cr_scale(m1, h10)),
            _cr_add(_cr_scale(p2, h01), _cr_scale(m2, h11)))
end

# three.js CubicInterpolant (InterpolateSmooth) (src/math/interpolants/
# CubicInterpolant.js: intervalChanged_ picks the neighbours and weights,
# interpolate_ evaluates the polynomials in the same operation order). The
# endings are :zero_curvature (the interpolant default), :zero_slope or
# :wrap_around. Inputs are already validated; `t` is not NaN. `lo` is the key
# at or before `t` (three.js `i1 - 1`), so a query on a key evaluates the
# interval that starts there.
function _cubic_interpolant_sample(times::AbstractVector, values::AbstractVector, t,
                                   ending_start::Symbol=:zero_curvature,
                                   ending_end::Symbol=:zero_curvature)
    n = length(times)
    t <= times[1] && return values[1]
    t >= times[n] && return values[n]
    lo = searchsortedlast(times, t)
    hi = lo + 1
    t0 = times[lo]
    t1 = times[hi]
    iprev, tprev = if lo > 1
        lo - 1, times[lo - 1]
    elseif ending_start === :zero_slope         # f'(t0) = 0
        hi, 2 * t0 - t1
    elseif ending_start === :wrap_around        # continue from the other end
        n - 1, t0 + times[n - 1] - times[n]
    else                                        # f''(t0) = 0
        hi, t1
    end
    inext, tnext = if hi < n
        hi + 1, times[hi + 1]
    elseif ending_end === :zero_slope           # f'(tN) = 0
        hi, 2 * t1 - t0
    elseif ending_end === :wrap_around
        2, t1 + times[2] - times[1]
    else                                        # f''(tN) = 0
        lo, t0
    end
    half_dt = (t1 - t0) / 2
    wp = half_dt / (t0 - tprev)
    wn = half_dt / (tnext - t1)
    p = (t - t0) / (t1 - t0)
    pp = p * p
    ppp = pp * p
    half = oftype(wp, 0.5)
    three_halves = oftype(wp, 1.5)
    sp = -wp * ppp + 2 * wp * pp - wp * p
    s0 = (1 + wp) * ppp + (-three_halves - 2 * wp) * pp + (-half + wp) * p + 1
    s1 = (-1 - wn) * ppp + (three_halves + wn) * pp + half * p
    sn = wn * ppp - wn * pp
    return _cr_add(_cr_add(_cr_add(_cr_scale(values[iprev], sp),
                                   _cr_scale(values[lo], s0)),
                           _cr_scale(values[hi], s1)),
                   _cr_scale(values[inext], sn))
end

"""
    interpolate_catmull_rom(times, values, t)

Smooth cubic sample of `values` at strictly increasing `times`, evaluated at
`t` and clamped to the endpoints. This is three.js `CubicInterpolant`
(`InterpolateSmooth`) with its default zero-curvature endings: interior
tangents average the slopes of the two adjacent intervals, which reduces to
uniform Catmull-Rom on evenly spaced keys. `values` may be reals or `Vec3`.
"""
function interpolate_catmull_rom(times::AbstractVector, values::AbstractVector, t)
    _validate_interpolant_inputs("interpolate_catmull_rom", times, values)
    # A NaN time passes both endpoint checks (all NaN comparisons are false) and
    # then indexes one past the end via searchsortedlast; reject it cleanly, as
    # interpolate_linear does, instead of leaking a BoundsError.
    isnan(t) && throw(ArgumentError("interpolate_catmull_rom: query time t must not be NaN"))
    return _cubic_interpolant_sample(times, values, t)
end

# interpolate_linear (math.jl) without its per-call O(n) validation of the
# key times: tracks validate their keys once at construction, and callers
# reject a NaN `t`. Same interval choice and lerp, so results are identical.
function _linear_track_sample(times::AbstractVector, values::AbstractVector, t)
    n = length(times)
    t <= times[1] && return values[1]
    t >= times[n] && return values[n]
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    α = (t - times[lo]) / (times[hi] - times[lo])
    return _lerp_value(values[lo], values[hi], α)
end

# Sample a single track value at absolute time `t` according to its mode.
function _track_value(tr::KeyframeTrack, t)
    if tr.interpolation === :cubic
        return _cubic_interpolant_sample(tr.times, tr.values, t)
    elseif tr.interpolation === :step
        n = length(tr.times)
        n == 0 && error("cannot sample an empty KeyframeTrack")
        t <= tr.times[1] && return tr.values[1]
        t >= tr.times[n] && return tr.values[n]
        return tr.values[searchsortedlast(tr.times, t)]
    else
        return _linear_track_sample(tr.times, tr.values, t)
    end
end

function _track_value(tr::NumberKeyframeTrack, t)
    if tr.interpolation === :cubic
        return _cubic_interpolant_sample(tr.times, tr.values, t)
    elseif tr.interpolation === :step
        n = length(tr.times)
        n == 0 && error("cannot sample an empty NumberKeyframeTrack")
        t <= tr.times[1] && return tr.values[1]
        t >= tr.times[n] && return tr.values[n]
        return tr.values[searchsortedlast(tr.times, t)]
    else
        return _linear_track_sample(tr.times, tr.values, t)
    end
end

function _track_value(tr::CubicSplineKeyframeTrack, t)
    times = tr.times
    n = length(times)
    n == 0 && error("cannot sample an empty CubicSplineKeyframeTrack")
    t <= times[1] && return tr.values[1]
    t >= times[n] && return tr.values[n]
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    h = times[hi] - times[lo]
    α = (t - times[lo]) / h
    return _hermite(tr.values[lo], tr.values[hi],
                    tr.out_tangents[lo] * h, tr.in_tangents[hi] * h, α)
end

@inline _quat_add(a::Quaternion, b::Quaternion) =
    Quaternion(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w)
@inline _quat_scale(a::Quaternion, s) =
    Quaternion(a.x * s, a.y * s, a.z * s, a.w * s)

function _quat_hermite(p1::Quaternion, p2::Quaternion,
                       m1::Quaternion, m2::Quaternion, α)
    α2 = α * α
    α3 = α2 * α
    h00 = 2α3 - 3α2 + 1
    h10 = α3 - 2α2 + α
    h01 = -2α3 + 3α2
    h11 = α3 - α2
    quat_normalize(_quat_add(_quat_add(_quat_scale(p1, h00), _quat_scale(m1, h10)),
                             _quat_add(_quat_scale(p2, h01), _quat_scale(m2, h11))))
end

function _track_value(tr::CubicSplineQuaternionKeyframeTrack, t)
    times = tr.times
    n = length(times)
    n == 0 && error("cannot sample an empty CubicSplineQuaternionKeyframeTrack")
    # three.js GLTFCubicSplineQuaternionInterpolant copies the raw key only
    # outside the keyed range; at the first key Interpolant.evaluate still
    # interpolates (p = 0) and the result is normalized.
    t < times[1] && return tr.values[1]
    t >= times[n] && return tr.values[n]
    lo = searchsortedlast(times, t)
    hi = lo + 1
    h = times[hi] - times[lo]
    α = (t - times[lo]) / h
    return _quat_hermite(tr.values[lo], tr.values[hi],
                         _quat_scale(tr.out_tangents[lo], h),
                         _quat_scale(tr.in_tangents[hi], h), α)
end

"""Slerp a quaternion track between adjacent keyframes (clamped at the ends)."""
function _track_value(tr::QuaternionKeyframeTrack, t)
    times = tr.times; values = tr.values
    n = length(times)
    n == 0 && error("cannot sample an empty QuaternionKeyframeTrack")
    t <= times[1] && return values[1]
    t >= times[n] && return values[n]
    # Both modes use the interval starting at the key at or before t, like
    # three.js Interpolant.evaluate. On an interior key slerp then runs with
    # alpha = 0 and returns that key itself, not its negation from the
    # previous key's hemisphere (QuaternionLinearInterpolant.interpolate_).
    lo = searchsortedlast(times, t)
    tr.interpolation === :step && return values[lo]
    hi = lo + 1
    α = (t - times[lo]) / (times[hi] - times[lo])
    return quat_slerp(values[lo], values[hi], α)
end

function _track_value(tr::MorphWeightsKeyframeTrack, t)
    times = tr.times
    values = tr.values
    n = length(times)
    n == 0 && error("cannot sample an empty MorphWeightsKeyframeTrack")
    t <= times[1] && return copy(values[1])
    t >= times[n] && return copy(values[n])
    lo = searchsortedlast(times, t)
    hi = lo + 1
    tr.interpolation === :step && return copy(values[lo])
    α = (t - times[lo]) / (times[hi] - times[lo])
    length(values[lo]) == length(values[hi]) ||
        error("morph-weight keyframes must have matching lengths")
    return [values[lo][i] + (values[hi][i] - values[lo][i]) * α for i in eachindex(values[lo])]
end

function _track_value(tr::CubicSplineMorphWeightsKeyframeTrack, t)
    times = tr.times
    values = tr.values
    n = length(times)
    n == 0 && error("cannot sample an empty CubicSplineMorphWeightsKeyframeTrack")
    t <= times[1] && return copy(values[1])
    t >= times[n] && return copy(values[n])
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    h = times[hi] - times[lo]
    α = (t - times[lo]) / h
    p1 = values[lo]; p2 = values[hi]
    m1 = tr.out_tangents[lo]; m2 = tr.in_tangents[hi]
    length(p1) == length(p2) == length(m1) == length(m2) ||
        error("morph-weight cubic spline keyframes must have matching lengths")
    α2 = α * α
    α3 = α2 * α
    h00 = 2α3 - 3α2 + 1
    h10 = α3 - 2α2 + α
    h01 = -2α3 + 3α2
    h11 = α3 - α2
    return [p1[i] * h00 + (m1[i] * h) * h10 +
            p2[i] * h01 + (m2[i] * h) * h11 for i in eachindex(p1)]
end

function _copy_morph_weights!(out::Vector{Float64}, src::Vector{Float64})
    resize!(out, length(src))
    length(src) > 0 && copyto!(out, 1, src, 1, length(src))
    return out
end

function _sample_morph_weights!(out::Vector{Float64}, tr::MorphWeightsKeyframeTrack, t)
    times = tr.times
    values = tr.values
    n = length(times)
    n == 0 && error("cannot sample an empty MorphWeightsKeyframeTrack")
    t <= times[1] && return _copy_morph_weights!(out, values[1])
    t >= times[n] && return _copy_morph_weights!(out, values[n])
    lo = searchsortedlast(times, t)
    hi = lo + 1
    tr.interpolation === :step && return _copy_morph_weights!(out, values[lo])
    p1 = values[lo]
    p2 = values[hi]
    length(p1) == length(p2) ||
        error("morph-weight keyframes must have matching lengths")
    resize!(out, length(p1))
    α = (t - times[lo]) / (times[hi] - times[lo])
    @inbounds for i in eachindex(p1)
        out[i] = p1[i] + (p2[i] - p1[i]) * α
    end
    return out
end

function _sample_morph_weights!(out::Vector{Float64},
                                tr::CubicSplineMorphWeightsKeyframeTrack, t)
    times = tr.times
    values = tr.values
    n = length(times)
    n == 0 && error("cannot sample an empty CubicSplineMorphWeightsKeyframeTrack")
    t <= times[1] && return _copy_morph_weights!(out, values[1])
    t >= times[n] && return _copy_morph_weights!(out, values[n])
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    h = times[hi] - times[lo]
    α = (t - times[lo]) / h
    p1 = values[lo]; p2 = values[hi]
    m1 = tr.out_tangents[lo]; m2 = tr.in_tangents[hi]
    length(p1) == length(p2) == length(m1) == length(m2) ||
        error("morph-weight cubic spline keyframes must have matching lengths")
    resize!(out, length(p1))
    α2 = α * α
    α3 = α2 * α
    h00 = 2α3 - 3α2 + 1
    h10 = α3 - 2α2 + α
    h01 = -2α3 + 3α2
    h11 = α3 - α2
    @inbounds for i in eachindex(p1)
        out[i] = p1[i] * h00 + (m1[i] * h) * h10 +
                 p2[i] * h01 + (m2[i] * h) * h11
    end
    return out
end

"""
    sample_track(track, t)

Interpolated value of a keyframe `track` at absolute time `t`, using the track's
own interpolation mode (linear, Catmull-Rom cubic, or quaternion slerp). Returns a
`Vec3` for property tracks and a `Quaternion` for a `QuaternionKeyframeTrack`.
"""
function sample_track(track::AbstractKeyframeTrack, t)
    # Reject a NaN query time cleanly (matching interpolate_linear/catmull_rom);
    # otherwise the cubic/quaternion/cubic-spline/morph samplers index past the
    # end of their keyframe arrays and raise a bare BoundsError.
    isnan(t) && throw(ArgumentError("sample_track: query time t must not be NaN"))
    return _track_value(track, t)
end

"""
    AnimationClip(name, duration, tracks; loop=:repeat, repetitions=-1,
                  clamp_when_finished=false, time_scale=1.0, blend_mode=:normal)
    AnimationClip(name, tracks; kwargs...)

Named collection of animation tracks with duration metadata (three.js
`AnimationClip`). Without `duration` it is the latest last key, and at least
0. `loop`, `repetitions`, `clamp_when_finished` and `time_scale` are the
defaults an [`AnimationMixer`](@ref) plays the clip with.

`blend_mode` is three.js `AnimationClip.blendMode`: `:normal` clips set the
animated properties, `:additive` clips (see [`clip_make_additive`](@ref)) add
offsets to them. An [`AnimationActionMixer`](@ref) action plays a clip with
the clip's blend mode by default; `AnimationMixer`, `save_gltf` and the WebGL
export apply clip values directly and reject additive clips.
"""
struct AnimationClip
    name::String
    duration::Float64
    tracks::Vector{AbstractKeyframeTrack}
    loop::Symbol
    repetitions::Int
    clamp_when_finished::Bool
    time_scale::Float64
    # three.js AnimationClip.blendMode: :normal or :additive.
    blend_mode::Symbol
end

# The 2.0 positional form, without a blend mode, makes a normal clip.
AnimationClip(name, duration, tracks, loop, repetitions, clamp_when_finished, time_scale) =
    AnimationClip(name, duration, tracks, loop, repetitions, clamp_when_finished,
                  time_scale, :normal)

# three.js NormalAnimationBlendMode / AdditiveAnimationBlendMode.
function _animation_blend_mode(mode::Symbol)
    (mode === :normal || mode === :additive) && return mode
    throw(ArgumentError("unsupported animation blend mode: $mode (expected :normal or :additive)"))
end

# Players that apply a clip's sampled values directly cannot show an
# additive clip, whose values are offsets from a reference pose.
function _require_normal_blend_clip(clip::AnimationClip, player::AbstractString)
    clip.blend_mode === :normal || throw(ArgumentError(
        "$player cannot play the additive clip $(repr(clip.name)); play it with " *
        "mixer_clip_action on an AnimationActionMixer"))
    return nothing
end

function _animation_loop_mode(loop::Symbol)
    loop === :repeat && return :repeat
    loop === :once && return :once
    (loop === :pingpong || loop === :ping_pong) && return :pingpong
    throw(ArgumentError("unsupported animation loop mode: $loop"))
end

function _validated_animation_duration(value::Real)
    value isa Bool &&
        throw(ArgumentError("AnimationClip duration must be finite and non-negative"))
    duration = Float64(value)
    isfinite(duration) && duration >= 0.0 ||
        throw(ArgumentError("AnimationClip duration must be finite and non-negative"))
    return duration
end

function _validated_animation_time_scale(value::Real)
    value isa Bool &&
        throw(ArgumentError("animation time_scale must be finite"))
    time_scale = Float64(value)
    isfinite(time_scale) ||
        throw(ArgumentError("animation time_scale must be finite"))
    return time_scale
end

function _validated_animation_repetitions(value::Integer)
    value isa Bool &&
        throw(ArgumentError("animation repetitions must be an integer"))
    return try
        Int(value)
    catch
        throw(ArgumentError("animation repetitions are too large"))
    end
end

function AnimationClip(name::String, duration::Real,
                       tracks::AbstractVector{<:AbstractKeyframeTrack};
                       loop::Symbol=:repeat,
                       repetitions::Integer=-1,
                       clamp_when_finished::Bool=false,
                       time_scale::Real=1.0,
                       blend_mode::Symbol=:normal)
    AnimationClip(
        name, _validated_animation_duration(duration),
        collect(AbstractKeyframeTrack, tracks),
        _animation_loop_mode(loop),
        _validated_animation_repetitions(repetitions),
        clamp_when_finished,
        _validated_animation_time_scale(time_scale),
        _animation_blend_mode(blend_mode),
    )
end

function AnimationClip(name::String, tracks::AbstractVector{<:AbstractKeyframeTrack};
                       loop::Symbol=:repeat,
                       repetitions::Integer=-1,
                       clamp_when_finished::Bool=false,
                       time_scale::Real=1.0,
                       blend_mode::Symbol=:normal)
    # three.js AnimationClip.resetDuration starts from 0, so tracks that end
    # before time zero give a zero-length clip instead of a negative one.
    duration = 0.0
    for track in tracks
        isempty(track.times) || (duration = max(duration, last(track.times)))
    end
    AnimationClip(name, duration, tracks; loop=loop, repetitions=repetitions,
                  clamp_when_finished=clamp_when_finished, time_scale=time_scale,
                  blend_mode=blend_mode)
end

# ---- Track and clip utilities (three.js KeyframeTrack / AnimationClip /
# AnimationUtils) ----------------------------------------------------------

# The track with only the keys `idx` (new key vectors; targets are shared).
_track_subset(tr::KeyframeTrack, idx) =
    KeyframeTrack(tr.target, tr.property, tr.times[idx], tr.values[idx], tr.interpolation)
_track_subset(tr::NumberKeyframeTrack, idx) =
    NumberKeyframeTrack(tr.target, tr.property, tr.component, tr.times[idx],
                        tr.values[idx], tr.interpolation, tr.morph_name)
_track_subset(tr::QuaternionKeyframeTrack, idx) =
    QuaternionKeyframeTrack(tr.target, tr.property, tr.times[idx], tr.values[idx],
                            tr.interpolation)
_track_subset(tr::MorphWeightsKeyframeTrack, idx) =
    MorphWeightsKeyframeTrack(tr.target, tr.property, tr.times[idx],
                              [copy(v) for v in tr.values[idx]], tr.interpolation)
_track_subset(tr::CubicSplineKeyframeTrack, idx) =
    CubicSplineKeyframeTrack(tr.target, tr.property, tr.times[idx], tr.values[idx],
                             tr.in_tangents[idx], tr.out_tangents[idx])
_track_subset(tr::CubicSplineQuaternionKeyframeTrack, idx) =
    CubicSplineQuaternionKeyframeTrack(tr.target, tr.property, tr.times[idx],
                                       tr.values[idx], tr.in_tangents[idx],
                                       tr.out_tangents[idx])
_track_subset(tr::CubicSplineMorphWeightsKeyframeTrack, idx) =
    CubicSplineMorphWeightsKeyframeTrack(tr.target, tr.property, tr.times[idx],
                                         [copy(v) for v in tr.values[idx]],
                                         [copy(v) for v in tr.in_tangents[idx]],
                                         [copy(v) for v in tr.out_tangents[idx]])

# Whether keys i and j hold the same value, compared like three.js
# KeyframeTrack.optimize (`!==` on every stored number, tangents included).
_key_equal(a::Real, b::Real) = a == b
_key_equal(a::Vec3, b::Vec3) = a.x == b.x && a.y == b.y && a.z == b.z
_key_equal(a::Quaternion, b::Quaternion) =
    a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w
_key_equal(a::AbstractVector, b::AbstractVector) =
    length(a) == length(b) && all(k -> a[k] == b[k], eachindex(a, b))
_track_keys_equal(tr::AbstractKeyframeTrack, i::Int, j::Int) =
    all(keys -> _key_equal(keys[i], keys[j]), _track_key_vectors(tr))

_track_smooth(tr::Union{KeyframeTrack,NumberKeyframeTrack}) = tr.interpolation === :cubic
_track_smooth(::AbstractKeyframeTrack) = false

# Key times must stay finite and strictly increasing; a change that breaks
# that is rejected before any key moves.
function _set_track_times!(tr::AbstractKeyframeTrack, times::Vector{Float64},
                           label::String)
    try
        _validate_keyframe_times(label, times)
    catch err
        err isa ArgumentError || rethrow()
        throw(ArgumentError("$label: the new key times must be finite and strictly increasing"))
    end
    copyto!(tr.times, times)
    return tr
end

"""
    track_shift!(track, time_offset) -> track

Add `time_offset` seconds to every key time of `track`, in place (three.js
`KeyframeTrack.shift`). Like three.js it changes the time vector itself, so
tracks that share that vector move together. Throws `ArgumentError`, leaving
the track unchanged, if the shifted times are not finite and strictly
increasing.
"""
function track_shift!(tr::AbstractKeyframeTrack, time_offset::Real)
    offset = _checked_control_scalar(time_offset, "track_shift! time_offset")
    offset == 0.0 && return tr
    return _set_track_times!(tr, tr.times .+ offset, "track_shift!")
end

"""
    track_scale!(track, time_scale) -> track

Multiply every key time of `track` by `time_scale`, in place (three.js
`KeyframeTrack.scale`); the values, and the tangents of cubic-spline tracks,
are unchanged, as in three.js. `time_scale` must be positive (Diff3D keys
stay strictly increasing); otherwise, or if a time overflows, an
`ArgumentError` is thrown and the track is unchanged.
"""
function track_scale!(tr::AbstractKeyframeTrack, time_scale::Real)
    scale = _checked_control_scalar(time_scale, "track_scale! time_scale")
    scale > 0.0 || throw(ArgumentError("track_scale! time_scale must be positive"))
    scale == 1.0 && return tr
    return _set_track_times!(tr, tr.times .* scale, "track_scale!")
end

"""
    track_trim(track, start_time, end_time) -> track

Copy of `track` without the keys before `start_time` or after `end_time`
(three.js `KeyframeTrack.trim`). At least one key is kept: when no key lies
in the range, the key at the boundary three.js keeps remains. Returns
`track` itself when nothing is removed.
"""
function track_trim(tr::AbstractKeyframeTrack, start_time::Real, end_time::Real)
    times = tr.times
    n = length(times)
    from = 1
    while from <= n && times[from] < start_time
        from += 1
    end
    to = n
    while to >= 1 && times[to] > end_time
        to -= 1
    end
    (from == 1 && to == n) && return tr
    # three.js keeps one key when the range is empty: to = max(to, 1),
    # from = to - 1 in its 0-based exclusive bounds.
    if from > to
        to = max(to, 1)
        from = to
    end
    return _track_subset(tr, from:to)
end

"""
    track_optimize(track) -> track

Copy of `track` without the interior keys that equal both neighbours
(three.js `KeyframeTrack.optimize`). `:cubic` tracks keep every key, since
their neighbours shape the curve. The first and last keys always remain.
Returns `track` itself when no key is removed.
"""
function track_optimize(tr::AbstractKeyframeTrack)
    n = length(tr.times)
    keep = trues(n)
    smooth = _track_smooth(tr)
    for i in 2:(n - 1)
        smooth && continue
        keep[i] = !(_track_keys_equal(tr, i, i - 1) && _track_keys_equal(tr, i, i + 1))
    end
    all(keep) && return tr
    return _track_subset(tr, findall(keep))
end

const _CubicSplineTrack = Union{CubicSplineKeyframeTrack,CubicSplineQuaternionKeyframeTrack,
                                CubicSplineMorphWeightsKeyframeTrack}

_track_key_vectors(tr::AbstractKeyframeTrack) = (tr.values,)
_track_key_vectors(tr::_CubicSplineTrack) = (tr.values, tr.in_tangents, tr.out_tangents)

"""
    track_validate(track) -> Bool

Whether `track` is still a valid track after in-place edits of its vectors,
like three.js `KeyframeTrack.validate`: it has keys, one value (and tangent)
per key, and its times are in increasing order. Diff3D tracks are stricter
than three.js here, as their constructors are: times and values must be
finite (three.js only rejects NaN) and two keys may not share a time.
"""
function track_validate(tr::AbstractKeyframeTrack)
    times = tr.times
    isempty(times) && return false
    for i in eachindex(times)
        isfinite(times[i]) || return false
        i > 1 && !(times[i] > times[i - 1]) && return false
    end
    for keys in _track_key_vectors(tr)
        length(keys) == length(times) || return false
        for v in keys
            _finite_keyframe_value(v) || return false
        end
    end
    return true
end

# A clip with the settings of `clip`, new name, duration and tracks.
_clip_with(clip::AnimationClip, name::String, duration::Real, tracks) =
    AnimationClip(name, duration, tracks; loop=clip.loop, repetitions=clip.repetitions,
                  clamp_when_finished=clip.clamp_when_finished,
                  time_scale=clip.time_scale, blend_mode=clip.blend_mode)

# three.js AnimationClip.resetDuration: the latest last key, starting from 0.
function _clip_track_duration(tracks)
    duration = 0.0
    for track in tracks
        isempty(track.times) || (duration = max(duration, last(track.times)))
    end
    return duration
end

"""
    clip_reset_duration(clip) -> AnimationClip

Copy of `clip` whose duration is the time of the latest last key of its
tracks, and at least 0 (three.js `AnimationClip.resetDuration`).
"""
clip_reset_duration(clip::AnimationClip) =
    _clip_with(clip, clip.name, _clip_track_duration(clip.tracks), clip.tracks)

"""
    clip_trim(clip) -> AnimationClip

Copy of `clip` with every track trimmed to `[0, clip.duration]` (three.js
`AnimationClip.trim`, see `track_trim`).
"""
clip_trim(clip::AnimationClip) =
    _clip_with(clip, clip.name, clip.duration,
               AbstractKeyframeTrack[track_trim(tr, 0.0, clip.duration) for tr in clip.tracks])

"""
    clip_optimize(clip) -> AnimationClip

Copy of `clip` with every track optimized (three.js `AnimationClip.optimize`,
see `track_optimize`).
"""
clip_optimize(clip::AnimationClip) =
    _clip_with(clip, clip.name, clip.duration,
               AbstractKeyframeTrack[track_optimize(tr) for tr in clip.tracks])

"""
    clip_validate(clip) -> Bool

Whether every track of `clip` passes `track_validate` (three.js
`AnimationClip.validate`).
"""
clip_validate(clip::AnimationClip) = all(track_validate, clip.tracks)

"""
    clip_find_by_name(clips, name) -> Union{AnimationClip,Nothing}

The first clip of `clips` called `name`, or `nothing` (three.js
`AnimationClip.findByName` for a clip array).
"""
function clip_find_by_name(clips::AbstractVector{<:AnimationClip}, name::AbstractString)
    for clip in clips
        clip.name == name && return clip
    end
    return nothing
end

"""
    clip_subclip(clip, name, start_frame, end_frame, fps=30) -> AnimationClip

Clip of the keys of `clip` whose frame `time * fps` lies in
`[start_frame, end_frame)`, shifted so the earliest kept key is at time 0,
with the duration reset (three.js `AnimationUtils.subclip`). Tracks without a
key in the range are dropped. The loop settings of `clip` are kept.
"""
function clip_subclip(clip::AnimationClip, name::AbstractString, start_frame::Real,
                      end_frame::Real, fps::Real=30)
    rate = _checked_control_scalar(fps, "clip_subclip fps")
    first_frame = _checked_control_scalar(start_frame, "clip_subclip start_frame")
    last_frame = _checked_control_scalar(end_frame, "clip_subclip end_frame")
    tracks = AbstractKeyframeTrack[]
    for tr in clip.tracks
        idx = findall(t -> first_frame <= t * rate < last_frame, tr.times)
        isempty(idx) || push!(tracks, _track_subset(tr, idx))
    end
    if !isempty(tracks)
        start = minimum(first(tr.times) for tr in tracks)
        for tr in tracks
            track_shift!(tr, -start)
        end
    end
    return _clip_with(clip, String(name), _clip_track_duration(tracks), tracks)
end

# three.js KeyframeTrack.ValueTypeName of a track, for matching reference and
# target tracks in clip_make_additive: morph-weight tracks are number tracks
# there, and a number track that drives a Bool property is a 'bool' track.
_additive_value_type(::Union{KeyframeTrack,CubicSplineKeyframeTrack}) = :vector
_additive_value_type(::Union{QuaternionKeyframeTrack,CubicSplineQuaternionKeyframeTrack}) =
    :quaternion
_additive_value_type(::Union{MorphWeightsKeyframeTrack,CubicSplineMorphWeightsKeyframeTrack}) =
    :number
_additive_value_type(tr::NumberKeyframeTrack) =
    tr.component == 0 && _original_property_value(tr.target, tr.property) isa Bool ?
        :bool : :number

_additive_track_name(tr::NumberKeyframeTrack) =
    (tr.target, tr.property, tr.component, tr.morph_name)
_additive_track_name(tr::AbstractKeyframeTrack) = (tr.target, tr.property, 0, "")

function _same_additive_track_name(a::AbstractKeyframeTrack, b::AbstractKeyframeTrack)
    na = _additive_track_name(a)
    nb = _additive_track_name(b)
    return na[1] === nb[1] && na[2] === nb[2] && na[3] == nb[3] && na[4] == nb[4]
end

# The reference value of `tr` at `t`: the first or last key outside the keys,
# else the track's own interpolant with its default settings
# (AnimationUtils.makeClipAdditive). For cubic-spline tracks this is the
# spline value; three.js r186 slices the value out of a result buffer that
# holds only the value there, and subtracts undefined (NaN).
function _additive_reference_value(tr::AbstractKeyframeTrack, t::Float64)
    t <= tr.times[1] && return tr.values[1]
    t >= tr.times[end] && return tr.values[end]
    return _track_value(tr, t)
end

# Normalized conjugate of a reference quaternion (Quaternion.normalize,
# Quaternion.conjugate).
function _additive_reference_conjugate(q::Quaternion)
    l = sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    l == 0 && return Quaternion{Float64}(-0.0, -0.0, -0.0, 1.0)
    l = 1 / l
    return Quaternion{Float64}(-(q.x * l), -(q.y * l), -(q.z * l), q.w * l)
end

# Quaternion.multiplyQuaternionsFlat(reference, key).
_additive_quaternion(r::Quaternion, q::Quaternion) = Quaternion{Float64}(
    r.x * q.w + r.w * q.x + r.y * q.z - r.z * q.y,
    r.y * q.w + r.w * q.y + r.z * q.x - r.x * q.z,
    r.z * q.w + r.w * q.z + r.x * q.y - r.y * q.x,
    r.w * q.w - r.x * q.x - r.y * q.y - r.z * q.z)

_track_minus_reference(tr::KeyframeTrack, ref) =
    KeyframeTrack(tr.target, tr.property, copy(tr.times), [v - ref for v in tr.values],
                  tr.interpolation)
_track_minus_reference(tr::CubicSplineKeyframeTrack, ref) =
    CubicSplineKeyframeTrack(tr.target, tr.property, copy(tr.times),
                             [v - ref for v in tr.values], copy(tr.in_tangents),
                             copy(tr.out_tangents))
_track_minus_reference(tr::NumberKeyframeTrack, ref) =
    NumberKeyframeTrack(tr.target, tr.property, tr.component, copy(tr.times),
                        [v - ref for v in tr.values], tr.interpolation, tr.morph_name)
_track_minus_reference(tr::MorphWeightsKeyframeTrack, ref) =
    MorphWeightsKeyframeTrack(tr.target, tr.property, copy(tr.times),
                              [_morph_minus_reference(v, ref) for v in tr.values],
                              tr.interpolation)
_track_minus_reference(tr::CubicSplineMorphWeightsKeyframeTrack, ref) =
    CubicSplineMorphWeightsKeyframeTrack(tr.target, tr.property, copy(tr.times),
                                         [_morph_minus_reference(v, ref) for v in tr.values],
                                         [copy(v) for v in tr.in_tangents],
                                         [copy(v) for v in tr.out_tangents])
_track_minus_reference(tr::QuaternionKeyframeTrack, ref) =
    QuaternionKeyframeTrack(tr.target, tr.property, copy(tr.times),
                            [_additive_quaternion(ref, q) for q in tr.values],
                            tr.interpolation)
# As in three.js, only the spline values are rotated, not their tangents.
_track_minus_reference(tr::CubicSplineQuaternionKeyframeTrack, ref) =
    CubicSplineQuaternionKeyframeTrack(tr.target, tr.property, copy(tr.times),
                                       [_additive_quaternion(ref, q) for q in tr.values],
                                       copy(tr.in_tangents), copy(tr.out_tangents))

# Reference values are subtracted component by component, over the target
# track's width (missing reference components count as 0).
_morph_minus_reference(v::Vector{Float64}, ref::AbstractVector) =
    [v[i] - (i <= length(ref) ? ref[i] : 0.0) for i in eachindex(v)]

_reference_for(tr::AbstractKeyframeTrack, ref) = ref
_reference_for(::Union{QuaternionKeyframeTrack,CubicSplineQuaternionKeyframeTrack},
               ref::Quaternion) = _additive_reference_conjugate(ref)

"""
    clip_make_additive(clip, reference_frame=0, reference_clip=clip, fps=30) -> AnimationClip

Additive copy of `clip` (three.js `AnimationUtils.makeClipAdditive`): every
track that has a match in `reference_clip` (same target, property and
component, and the same kind of value) holds its values relative to the
match's value at frame `reference_frame` (time `reference_frame / fps`, with
`fps <= 0` meaning 30). Vector, number and morph-weight keys subtract the
reference; quaternion keys are multiplied by its normalized conjugate
(`conj(ref) * q`; cubic-spline tangents are kept, as in three.js). Tracks
that drive a `Bool` property are left as they are. The result has
`blend_mode = :additive`; `clip` is not changed (three.js changes the clip
in place).
"""
function clip_make_additive(clip::AnimationClip, reference_frame::Real=0,
                            reference_clip::AnimationClip=clip, fps::Real=30)
    frame = _checked_control_scalar(reference_frame, "clip_make_additive reference_frame")
    rate = _checked_control_scalar(fps, "clip_make_additive fps")
    rate <= 0 && (rate = 30.0)
    reference_time = frame / rate
    same = reference_clip === clip
    tracks = collect(AbstractKeyframeTrack, clip.tracks)
    for i in eachindex(reference_clip.tracks)
        # three.js edits the clip in place, so a clip that is its own
        # reference reads each reference track as edited so far.
        ref_track = same ? tracks[i] : reference_clip.tracks[i]
        value_type = _additive_value_type(ref_track)
        value_type === :bool && continue
        k = findfirst(tr -> _same_additive_track_name(tr, ref_track) &&
                            _additive_value_type(tr) === value_type, tracks)
        k === nothing && continue
        ref = _reference_for(ref_track, _additive_reference_value(ref_track, reference_time))
        tracks[k] = _track_minus_reference(tracks[k], ref)
    end
    return AnimationClip(clip.name, clip.duration, tracks; loop=clip.loop,
                         repetitions=clip.repetitions,
                         clamp_when_finished=clip.clamp_when_finished,
                         time_scale=clip.time_scale, blend_mode=:additive)
end

"""
    clip_from_morph_target_sequence(target, name, morph_names, fps; no_loop=false)

Clip that shows the morph targets `morph_names` of `target` (or of its
descendants, see `NumberKeyframeTrack`) one after another at `fps` frames per
second (three.js `AnimationClip.CreateFromMorphTargetSequence`): target `i`
has influence 1 at frame `i - 1` and 0 at its neighbouring frames. Unless
`no_loop`, a sequence key at frame 0 repeats at the last frame so the loop
closes. For one or two names three.js stacks equal keys on one frame; those
become a single key, which samples the same.
"""
function clip_from_morph_target_sequence(target::AbstractObject3D, name::AbstractString,
                                         morph_names::AbstractVector{<:AbstractString},
                                         fps::Real; no_loop::Bool=false)
    n = length(morph_names)
    rate =_checked_control_scalar(fps, "clip_from_morph_target_sequence fps")
    rate > 0.0 || throw(ArgumentError("clip_from_morph_target_sequence fps must be positive"))
    tracks = AbstractKeyframeTrack[]
    for i in 0:(n - 1)
        keys = [((i + n - 1) % n, 0.0), (i, 1.0), ((i + 1) % n, 0.0)]
        sort!(keys; by=first, alg=Base.Sort.InsertionSort)   # stable, as getKeyframeOrder
        # Fewer than three targets put several keys on one frame. three.js
        # samples the first of them only as the end of the interval before
        # that frame and the last one from the frame on; both are 0 here, so
        # one key per frame with the last value gives the same curve and
        # keeps the times strictly increasing.
        times = Float64[]
        values = Float64[]
        first_values = Float64[]
        for (frame, value) in keys
            if !isempty(times) && times[end] == frame
                values[end] = value
                continue
            end
            push!(times, frame)
            push!(values, value)
            push!(first_values, value)
        end
        first_values == values || throw(ArgumentError(
            "clip_from_morph_target_sequence: keys on one frame disagree"))
        if !no_loop && times[1] == 0.0
            push!(times, Float64(n))
            push!(values, values[1])
        end
        track = NumberKeyframeTrack(target, "morphTargetInfluences[$(morph_names[i + 1])]",
                                    times, values)
        track_scale!(track, 1.0 / rate)
        push!(tracks, track)
    end
    return AnimationClip(String(name), tracks)
end

"""
    clips_from_morph_target_sequences(target, fps; no_loop=false) -> Vector{AnimationClip}

One `clip_from_morph_target_sequence` clip per animation found in the morph
target names of `target` (three.js
`AnimationClip.CreateClipsFromMorphTargetSequences`): names such as
`walk_001`, `walk_002`, `run_001` are grouped by the text before their
trailing digits, in order of first appearance.
"""
function clips_from_morph_target_sequences(target::AbstractObject3D, fps::Real;
                                           no_loop::Bool=false)
    hasproperty(target, :morph_target_names) || throw(ArgumentError(
        "clips_from_morph_target_sequences target has no morph target names"))
    groups = Pair{String,Vector{String}}[]
    for morph_name in getproperty(target, :morph_target_names)
        m = match(r"^([A-Za-z0-9_-]*?)([0-9]+)$", morph_name)
        m === nothing && continue
        key = String(m.captures[1])
        k = findfirst(g -> g.first == key, groups)
        k === nothing ? push!(groups, key => [String(morph_name)]) :
                        push!(groups[k].second, String(morph_name))
    end
    return AnimationClip[clip_from_morph_target_sequence(target, key, names, fps;
                                                         no_loop=no_loop)
                         for (key, names) in groups]
end

"""
    AnimationMixer(clip; loop=clip.loop, repetitions=clip.repetitions,
                   clamp_when_finished=clip.clamp_when_finished,
                   time_scale=clip.time_scale, zero_slope_at_start=true,
                   zero_slope_at_end=true)

Plays `clip` on its tracks' targets like a three.js `AnimationMixer` driving
the one action of `clipAction(clip).play()` (src/animation/AnimationAction.js,
AnimationMixer.js, PropertyMixer.js).

`mixer_update!(mixer, dt)` advances the mixer by `dt * time_scale` seconds
and steps the action like `AnimationAction._updateTime`: `:repeat` and
`:pingpong` count every loop crossed in either direction (playing backward
from zero the first wrap is free), and after `repetitions` loops (`-1`:
unlimited) or at either end of a `:once` clip the action finishes. With
`clamp_when_finished` a finished action pauses on its last pose (`paused`
becomes true); otherwise it is disabled (`enabled` becomes false) and every
animated property returns to its original value, the value it had when the
mixer was created or last `mixer_play!`ed (three.js
`PropertyMixer.saveOriginalState`). A finished action stays finished whatever
the later `dt`; `mixer_reset!` and `mixer_set_time!` restart it, and
`mixer_stop!` restores the original values and stops applying the clip.

`zero_slope_at_start`/`zero_slope_at_end` (three.js `zeroSlopeAtStart`/
`zeroSlopeAtEnd`) select zero-slope (true) or zero-curvature (false) endings
for `:cubic` tracks at the clip start of the first loop and the clip end of
the last; `:pingpong` always uses zero slope. As in three.js, a cubic track
keeps the endings it had when its sample entered the current key interval.

The fields `time` (mixer time), `loop`, `repetitions`, `clamp_when_finished`,
`time_scale`, `zero_slope_at_start`, `zero_slope_at_end`, `enabled` and
`paused` may be changed between updates, as on a three.js action; the
action's clip-local time is `action_time`. Unlike three.js, an enabled
action writes its sampled values on every update, also when they did not
change since the previous frame.

`clip` must be a `:normal` clip; an additive clip (see `clip_make_additive`)
throws `ArgumentError`. To play several clips at once, with weights, fades
and additive layers, use [`AnimationActionMixer`](@ref).
"""
mutable struct AnimationMixer
    clip::AnimationClip
    time::Float64
    loop::Symbol
    repetitions::Int
    clamp_when_finished::Bool
    time_scale::Float64
    # Internal: clip-local time of the update being applied. Track writers
    # read it from the mixer, so dispatching on a track's target type passes
    # only heap references and the per-frame update does not box the time.
    sample_time::Float64
    # Internal: the action's interpolant endings (AnimationAction._setEndings).
    ending_start::Symbol
    ending_end::Symbol
    zero_slope_at_start::Bool
    zero_slope_at_end::Bool
    # three.js AnimationAction state: clip-local time, loop count (-1 before
    # the first time step), enabled/paused, and whether the action is
    # scheduled (played and not stopped).
    action_time::Float64
    loop_count::Int
    enabled::Bool
    paused::Bool
    active::Bool
    # Internal: whether the last update wrote sampled values (so that the
    # next update without weight writes the original values back).
    applied::Bool
    # Internal: index of the track being applied and the per-track
    # CubicInterpolant cache (key interval, 0 outside the keys, and the
    # endings its weights were computed with).
    track_index::Int
    cubic_interval::Vector{Int}
    cubic_ending_start::Vector{Symbol}
    cubic_ending_end::Vector{Symbol}
    # Internal: original value of each track's property, or nothing when it
    # cannot be read (see _track_original).
    originals::Vector{Any}
end

function _new_animation_mixer(clip::AnimationClip, loop::Symbol, repetitions::Int,
                              clamp_when_finished::Bool, time_scale::Float64,
                              zero_slope_at_start::Bool, zero_slope_at_end::Bool)
    _require_normal_blend_clip(clip, "AnimationMixer")
    n = length(clip.tracks)
    mixer = AnimationMixer(clip, 0.0, loop, repetitions, clamp_when_finished,
                           time_scale, 0.0,
                           # AnimationAction's interpolant settings start at
                           # ZeroCurvatureEnding until its first time step.
                           :zero_curvature, :zero_curvature,
                           zero_slope_at_start, zero_slope_at_end,
                           0.0, -1, true, false, true, false, 0,
                           zeros(Int, n), fill(:zero_curvature, n),
                           fill(:zero_curvature, n), Vector{Any}(nothing, n))
    _save_originals!(mixer)
    return mixer
end

# 1.0 positional form: a playing mixer already stepped, without applying the
# clip, to mixer time `time`.
function AnimationMixer(clip::AnimationClip, time::Real, loop::Symbol,
                        repetitions::Integer, clamp_when_finished::Bool,
                        time_scale::Real)
    mixer = _new_animation_mixer(clip, _animation_loop_mode(loop),
                                 _validated_animation_repetitions(repetitions),
                                 clamp_when_finished,
                                 _validated_animation_time_scale(time_scale),
                                 true, true)
    t = _checked_control_scalar(time, "AnimationMixer time")
    _update_action_time!(mixer, t)
    mixer.time = t
    return mixer
end

function AnimationMixer(clip::AnimationClip; loop::Union{Symbol,Nothing}=nothing,
                        repetitions::Union{Integer,Nothing}=nothing,
                        clamp_when_finished::Union{Bool,Nothing}=nothing,
                        time_scale::Union{Real,Nothing}=nothing,
                        zero_slope_at_start::Bool=true,
                        zero_slope_at_end::Bool=true)
    _new_animation_mixer(clip,
                         loop === nothing ? clip.loop : _animation_loop_mode(loop),
                         repetitions === nothing ? clip.repetitions :
                         _validated_animation_repetitions(repetitions),
                         clamp_when_finished === nothing ? clip.clamp_when_finished :
                         clamp_when_finished,
                         time_scale === nothing ? clip.time_scale :
                         _validated_animation_time_scale(time_scale),
                         zero_slope_at_start, zero_slope_at_end)
end

# ---- Multi-action mixing (three.js AnimationMixer / AnimationAction /
# PropertyMixer) ------------------------------------------------------------

# One animated property of one object: three.js PropertyMixer with its
# PropertyBinding. `buffer` holds `stride` values per region, in the
# three.js layout [incoming | accu0 | accu1 | orig | additive | work].
mutable struct _AnimationBinding
    node::Any                       # object whose property is written
    property::Symbol
    component::Int                  # component (1-based) or 0 for the whole value
    kind::Int                       # _BINDING_* below
    stride::Int
    buffer::Vector{Float64}
    cumulative_weight::Float64
    cumulative_weight_additive::Float64
    use_count::Int
    cache_index::Int                # position in the mixer's binding list
    apply_offset::Int               # 0-based region offset `_binding_set!` writes from
    # Whole influence vector a vector binding restores when its width differs
    # from the binding's (empty otherwise).
    original_vector::Vector{Float64}
    # Euler rotation a quaternion binding restores, so the original angles
    # come back exactly rather than as the quaternion's canonical Euler
    # angles (nothing for other bindings).
    original_rotation::Any
    # Vector tracks bound here: their keyframe vectors must not be written.
    vector_tracks::Vector{AbstractKeyframeTrack}
end

# Weight and time-scale ramps: three.js LinearInterpolant over two
# Float32Array keys with a Float32Array result (AnimationMixer.js
# _lendControlInterpolant). `cached_index` is Interpolant._cachedIndex,
# which a pooled interpolant keeps between uses.
mutable struct _ControlInterpolant
    t0::Float32
    t1::Float32
    v0::Float32
    v1::Float32
    cached_index::Int
    cache_index::Int
end

"""
    AnimationAction

Handle for one clip scheduled on an [`AnimationActionMixer`](@ref), returned
by [`mixer_clip_action`](@ref) (three.js `AnimationAction`). Its fields
follow the three.js properties and may be changed between updates:

- `weight` (1.0), `time_scale` (1.0), `time` (clip-local time, 0.0),
  `enabled` (true), `paused` (false);
- `loop` (`:repeat`, `:once` or `:pingpong`), `repetitions` (`-1` for
  unlimited), `clamp_when_finished` (false), all taken from the clip;
- `zero_slope_at_start`, `zero_slope_at_end` (true): the endings of
  `:cubic` tracks, as for `AnimationMixer`;
- `blend_mode` (`:normal` or `:additive`).

`clip` and `mixer` are read-only. The `action_*` functions (`action_play!`,
`action_fade_in!`, `action_cross_fade_to!`, `action_warp!`, ...) mirror the
three.js methods.
"""
mutable struct AnimationAction{M}
    mixer::M
    clip::AnimationClip
    blend_mode::Symbol
    loop::Symbol
    repetitions::Int
    clamp_when_finished::Bool
    zero_slope_at_start::Bool
    zero_slope_at_end::Bool
    time::Float64
    time_scale::Float64
    weight::Float64
    enabled::Bool
    paused::Bool
    # three.js internals: effective values of the last update, loop count
    # (-1 before the first time step), scheduled start, warp restore value and
    # the fade/warp ramps lent by the mixer.
    effective_time_scale::Float64
    effective_weight::Float64
    loop_count::Int
    start_time::Union{Nothing,Float64}
    restore_time_scale::Union{Nothing,Float64}
    weight_interpolant::Union{Nothing,_ControlInterpolant}
    time_scale_interpolant::Union{Nothing,_ControlInterpolant}
    cache_index::Int                # position in the mixer's action list
    # Interpolant settings and per-track CubicInterpolant cache, as on
    # AnimationMixer (read by _mixer_track_value).
    ending_start::Symbol
    ending_end::Symbol
    sample_time::Float64
    track_index::Int
    cubic_interval::Vector{Int}
    cubic_ending_start::Vector{Symbol}
    cubic_ending_end::Vector{Symbol}
    # Bindings of each track (several for a morph track bound to a parent),
    # all bindings in activation order, and per-track scratch samples.
    track_bindings::Vector{Vector{_AnimationBinding}}
    bindings::Vector{_AnimationBinding}
    vector_samples::Vector{Vector{Float64}}
end

"""
    AnimationActionMixer()

Mixer that plays any number of clips at once and blends them per property,
like a three.js `AnimationMixer` driving several actions
(src/animation/AnimationMixer.js, AnimationAction.js, PropertyMixer.js).
`AnimationMixer(clip)` keeps playing one clip on its own; this mixer adds the
three.js action API on top:

```julia
mixer = AnimationActionMixer()
walk = mixer_clip_action(mixer, walk_clip)
run = mixer_clip_action(mixer, run_clip)
action_play!(walk); action_play!(run)
action_set_effective_weight!(run, 0.0)
action_cross_fade_to!(walk, run, 0.5; warp=true)
mixer_update!(mixer, 1 / 60)
```

[`mixer_clip_action`](@ref) returns the [`AnimationAction`](@ref) of a clip.
Each update steps every playing action ([`action_play!`](@ref)) like
`AnimationMixer` (loops, repetitions, clamping, cubic endings), evaluates
fades and warps, and accumulates the weighted samples of each property
exactly as three.js `PropertyMixer`: a weighted average of the `:normal`
actions (vectors, scalars and morph influences lerp, quaternion tracks slerp,
and a `NumberKeyframeTrack` that drives a `Bool` property selects like a
three.js `BooleanKeyframeTrack`), the original value filling the weight
missing to 1, and then the `:additive` actions added on top (quaternions
compose). Original values are read when the first action using a property
starts playing and restored when the last one stops. A property is written
only when its blended value changed since the previous update.

The fields `time` (mixer time) and `time_scale` may be changed between
updates. Fade and warp ramps store their times and values as `Float32`, as
three.js does. Two Diff3D differences: tracks are already bound to their
targets, so the mixer has no root object and an action is looked up by clip;
and `:rotation` (Euler) `KeyframeTrack`s blend their angles, where three.js
`Euler.fromArray` ignores the mixer's buffer offset and writes the last
sampled value. Material properties replace the material object when their
blended value changes, as `AnimationMixer` does.
"""
mutable struct AnimationActionMixer
    time::Float64
    time_scale::Float64
    accu_index::Int
    actions::Vector{AnimationAction{AnimationActionMixer}}
    n_active_actions::Int
    bindings::Vector{_AnimationBinding}
    n_active_bindings::Int
    control_interpolants::Vector{_ControlInterpolant}
    n_active_control_interpolants::Int
    # three.js _actionsByClip: each clip and its latest action.
    clips::Vector{AnimationClip}
    clip_actions::Vector{AnimationAction{AnimationActionMixer}}
end

AnimationActionMixer() =
    AnimationActionMixer(0.0, 1.0, 0, AnimationAction{AnimationActionMixer}[], 0,
                         _AnimationBinding[], 0, _ControlInterpolant[], 0,
                         AnimationClip[], AnimationAction{AnimationActionMixer}[])

const _MixerAction = AnimationAction{AnimationActionMixer}
const _ActionStepper = Union{AnimationMixer, _MixerAction}

# Clip-local time of the action being stepped.
@inline _action_local_time(mixer::AnimationMixer) = mixer.action_time
@inline _action_local_time(action::_MixerAction) = action.time
@inline _set_action_local_time!(mixer::AnimationMixer, t::Float64) = (mixer.action_time = t)
@inline _set_action_local_time!(action::_MixerAction, t::Float64) = (action.time = t)

# three.js AnimationAction._setEndings (AnimationAction.js:882-917).
function _set_action_endings!(mixer::_ActionStepper, at_start::Bool, at_end::Bool,
                              pingpong::Bool)
    if pingpong
        mixer.ending_start = :zero_slope
        mixer.ending_end = :zero_slope
    else
        mixer.ending_start = at_start ?
            (mixer.zero_slope_at_start ? :zero_slope : :zero_curvature) : :wrap_around
        mixer.ending_end = at_end ?
            (mixer.zero_slope_at_end ? :zero_slope : :zero_curvature) : :wrap_around
    end
    return nothing
end

# A finishing action pauses on its last pose when clamping, otherwise it is
# disabled (AnimationAction.js:771-772, 822-823).
@inline function _finish_action!(mixer::_ActionStepper)
    mixer.clamp_when_finished ? (mixer.paused = true) : (mixer.enabled = false)
    return nothing
end

# Whole loops in `x = time / duration` (three.js `Math.floor`), returned as
# the Float64 the time is wrapped by and as the loop-count increment
# |floor(x)|. The increment saturates at 2^53, which keeps its parity (every
# Float64 at or above 2^53 is even), so the Int conversion cannot throw; the
# wrapped time still uses the exact floor, as three.js does.
@inline function _action_loop_delta(x::Float64)
    loops = floor(x)
    return loops, Int(min(abs(loops), 2.0^53))
end

# Loop count plus `n` wraps, saturated instead of overflowing.
@inline _action_add_loops(count::Int, n::Int) =
    count > typemax(Int) - n ? typemax(Int) : count + n

# three.js AnimationAction._updateTime (AnimationAction.js:724-880): advance
# the clip-local time by the scaled `delta` and return the clip time to
# sample. A zero-length repeating clip samples time 0 (three.js divides by
# the zero duration there).
function _update_action_time!(mixer::_ActionStepper, delta::Float64)
    duration = mixer.clip.duration
    loop = _animation_loop_mode(mixer.loop)
    time = _checked_control_scalar(_action_local_time(mixer) + delta, "animation time")
    loop_count = mixer.loop_count
    pingpong = loop === :pingpong
    if delta == 0.0
        loop_count == -1 && return time
        return pingpong && isodd(loop_count) ? duration - time : time
    end
    if loop === :once
        if loop_count == -1
            mixer.loop_count = 0
            _set_action_endings!(mixer, true, true, false)
        end
        if time >= duration
            time = duration
        elseif time < 0.0
            time = 0.0
        else
            _set_action_local_time!(mixer, time)
            return time
        end
        _finish_action!(mixer)
        _set_action_local_time!(mixer, time)
        return time
    end
    repetitions = mixer.repetitions          # negative: unlimited (Infinity)
    if loop_count == -1
        if delta >= 0.0
            loop_count = 0
            _set_action_endings!(mixer, true, repetitions == 0, pingpong)
        else
            # Looping in reverse, the initial transition through zero counts
            # as a repetition, so the loop count stays at -1.
            _set_action_endings!(mixer, repetitions == 0, true, pingpong)
        end
    end
    if duration <= 0.0
        mixer.loop_count = loop_count
        _set_action_local_time!(mixer, 0.0)
        return 0.0
    end
    if time >= duration || time < 0.0
        loop_delta, wraps = _action_loop_delta(time / duration)
        time -= duration * loop_delta
        loop_count = _action_add_loops(loop_count, wraps)
        if repetitions >= 0 && repetitions - loop_count <= 0
            _finish_action!(mixer)
            time = delta > 0.0 ? duration : 0.0
            # three.js keeps _loopCount at its previous value here, so the
            # frames after a clamped ping-pong finish can mirror the pose.
            _set_action_local_time!(mixer, time)
        else
            if repetitions >= 0 && repetitions - loop_count == 1
                at_start = delta < 0.0
                _set_action_endings!(mixer, at_start, !at_start, pingpong)
            else
                _set_action_endings!(mixer, false, false, pingpong)
            end
            mixer.loop_count = loop_count
            _set_action_local_time!(mixer, time)
        end
    else
        mixer.loop_count = loop_count
        _set_action_local_time!(mixer, time)
    end
    return pingpong && isodd(loop_count) ? duration - time : time
end

# Clip time of an action played from its start up to (scaled) time `t` in
# frame steps shorter than the clip, in closed form for the exported web
# player's clipTime; `nothing` once the action finishes unclamped (disabled,
# so the original values show). While running this is what one
# _update_action_time! step of `t` gives (mixer_set_time!). After a clamped
# finish three.js keeps the loop count from before the final wrap
# (AnimationAction.js:815-829 leaves `_loopCount` unchanged), so later frames
# mirror a pingpong clip by that count, not by the finishing step's count.
function _animation_loop_time(t::Real, duration::Real, loop::Symbol,
                              repetitions::Int, clamp_when_finished::Bool)
    duration isa Bool &&
        throw(ArgumentError("animation duration must be finite and non-negative"))
    d = Float64(duration)
    isfinite(d) && d >= 0.0 ||
        throw(ArgumentError("animation duration must be finite and non-negative"))
    t isa Bool && throw(ArgumentError("animation time must be finite"))
    x = Float64(t)
    isfinite(x) ||
        throw(ArgumentError("animation time must be finite"))
    loop = _animation_loop_mode(loop)
    x == 0.0 && return 0.0
    if loop === :once
        0.0 < x < d && return x
        clamp_when_finished || return nothing
        return x >= d ? d : 0.0
    end
    d <= 0.0 && return 0.0
    time = x
    loop_count = x > 0.0 ? 0 : -1
    if time >= d || time < 0.0
        loop_delta, wraps = _action_loop_delta(time / d)
        time -= d * loop_delta
        loop_count = _action_add_loops(loop_count, wraps)
        if repetitions >= 0 && repetitions - loop_count <= 0
            clamp_when_finished || return nothing
            time = x > 0.0 ? d : 0.0
            # Frame steps wrap one loop at a time, so the kept count is the
            # finishing count minus one: forward max(repetitions, 1) - 1,
            # backward (from -1, first wrap free) repetitions - 1. A kept
            # count of -1 returns the time unmirrored (_updateTime, deltaTime 0).
            kept = (x > 0.0 ? max(repetitions, 1) : repetitions) - 1
            return loop === :pingpong && kept >= 0 && isodd(kept) ? d - time : time
        end
    end
    return loop === :pingpong && isodd(loop_count) ? d - time : time
end

# Write an interpolated value to a track target. Quaternion samples targeting the
# `:rotation` field are converted to an `Euler` so the typed field accepts them.
_write_track_value!(target, property::Symbol, v) = setproperty!(target, property, v)
function _with_component(v::Vec3, component::Int, x::Real)
    component == 1 && return Vec3(Float64(x), v.y, v.z)
    component == 2 && return Vec3(v.x, Float64(x), v.z)
    component == 3 && return Vec3(v.x, v.y, Float64(x))
    throw(ArgumentError("Vec3 animation component must be x/y/z"))
end
function _with_component(v::Vec2, component::Int, x::Real)
    component == 1 && return Vec2(Float64(x), v.y)
    component == 2 && return Vec2(v.x, Float64(x))
    throw(ArgumentError("Vec2 animation component must be x/y"))
end
function _with_component(v::Euler, component::Int, x::Real)
    component == 1 && return Euler(Float64(x), v.y, v.z, v.order)
    component == 2 && return Euler(v.x, Float64(x), v.z, v.order)
    component == 3 && return Euler(v.x, v.y, Float64(x), v.order)
    throw(ArgumentError("Euler animation component must be x/y/z"))
end
function _with_component(v::Quaternion, component::Int, x::Real)
    component == 1 && return Quaternion(Float64(x), v.y, v.z, v.w)
    component == 2 && return Quaternion(v.x, Float64(x), v.z, v.w)
    component == 3 && return Quaternion(v.x, v.y, Float64(x), v.w)
    component == 4 && return Quaternion(v.x, v.y, v.z, Float64(x))
    throw(ArgumentError("Quaternion animation component must be x/y/z/w"))
end
function _target_rotation_quaternion(target)
    rot = hasproperty(target, :rotation) ? getproperty(target, :rotation) : Euler()
    return quat_from_euler(rot.x, rot.y, rot.z; order=rot.order)
end
function _write_quaternion_component!(target, component::Int, v::Real)
    q = _with_component(_target_rotation_quaternion(target), component, v)
    return _write_track_value!(target, :quaternion, quat_normalize(q))
end
function _with_component(v::Color3, component::Int, x::Real)
    component == 1 && return Color3(Float64(x), v.g, v.b)
    component == 2 && return Color3(v.r, Float64(x), v.b)
    component == 3 && return Color3(v.r, v.g, Float64(x))
    throw(ArgumentError("Color3 animation component must be r/g/b"))
end

struct _UnhandledField end

# `_replace_field_value` unrolled over the fields of `x` whose declared type
# is exactly the replacement type (`value`, or `value >= 0.5` for a `Bool`
# field and a real value), so the rebuild is a statically typed positional
# constructor call. Any other field name returns `_UnhandledField()`.
@generated function _replace_typed_field(x, property::Symbol, value)
    names = fieldnames(x)
    types = fieldtypes(x)
    replacement(i) = types[i] === Bool && value <: Real && value !== Bool ?
        :(value >= 0.5) : :value
    handled(i) = types[i] === value || (types[i] === Bool && value <: Real)
    checks = [:(if property === $(QuoteNode(names[i]))
                    matched = true
                    unchanged = isequal($(replacement(i)), getfield(x, $i))
                end) for i in eachindex(names) if handled(i)]
    isempty(checks) && return :(_UnhandledField())
    args = [handled(i) ?
            :(property === $(QuoteNode(names[i])) ? $(replacement(i)) : getfield(x, $i)) :
            :(getfield(x, $i)) for i in eachindex(names)]
    return quote
        matched = false
        unchanged = false
        $(checks...)
        matched || return _UnhandledField()
        unchanged && return x
        return $x($(args...))
    end
end

function _replace_field_value(x, property::Symbol, value)
    typed = _replace_typed_field(x, property, value)
    typed isa _UnhandledField || return typed
    hasproperty(x, property) || return nothing
    current = getproperty(x, property)
    replacement = current isa Bool && value isa Real ? value >= 0.5 : value
    isequal(replacement, current) && return x
    names = fieldnames(typeof(x))
    vals = map(names) do name
        name === property ? replacement : getproperty(x, name)
    end
    return typeof(x)(vals...)
end

function _replace_field_value(material::MeshPhongMaterial, property::Symbol, value)
    if property !== :shininess && property !== :glossiness
        return invoke(_replace_field_value, Tuple{Any,Symbol,Any},
                      material, property, value)
    end
    # These are two representations of one surface parameter. Resolve both
    # through the constructor policy before replacing the target's material.
    shininess, glossiness = property === :shininess ?
        _resolve_material_phong_parameters(value, nothing) :
        _resolve_material_phong_parameters(nothing, value)
    if isequal(shininess, material.shininess) &&
       isequal(glossiness, material.glossiness)
        return material
    end
    values = map(fieldnames(MeshPhongMaterial)) do field
        field === :shininess ? shininess :
        field === :glossiness ? glossiness : getfield(material, field)
    end
    return MeshPhongMaterial(values...)
end

@inline _material_noop_update(::Any, ::Symbol, ::Any) = false
@inline function _material_noop_update(mat::MeshBasicMaterial, property::Symbol, value)
    if property === :opacity
        value isa Real || return false
        return isequal(Float64(value), mat.opacity)
    elseif property === :depth_test
        value isa Real || return false
        return isequal(value >= 0.5, mat.depth_test)
    elseif property === :color
        value isa Color3 || return false
        return isequal(Color3(Float64(value.r), Float64(value.g), Float64(value.b)), mat.color)
    end
    return false
end

@inline _material_component_noop_update(::Any, ::Symbol, ::Int, ::Real) = false
@inline function _material_component_noop_update(
    mat::MeshBasicMaterial, property::Symbol, component::Int, value::Real,
)
    property === :color || return false
    return isequal(_with_component(mat.color, component, value), mat.color)
end

_material_animation_property(property::Symbol) =
    property === :material_rotation ? :rotation : property

# `target.material` is untyped; the helpers below take it as an argument so
# the material work is specialized on the concrete material type.
function _write_material_track_value!(target, property::Symbol, value)
    hasproperty(target, :material) || return false
    return _write_material_value!(target, getproperty(target, :material),
                                  _material_animation_property(property), value)
end

function _write_material_value!(target, mat, property::Symbol, value)
    _material_noop_update(mat, property, value) && return true
    return _write_material_replacement!(target, mat, property, value)
end

function _write_material_replacement!(target, mat, property::Symbol, value)
    newmat = _replace_field_value(mat, property, value)
    newmat === nothing && return false
    setproperty!(target, :material, newmat)
    return true
end

# The current value of the component-addressable field `property` of `x`
# with one component replaced, or `_UnhandledField()` when `property` names
# no field of a type `_with_component` accepts.
@generated function _with_typed_field_component(x, property::Symbol, component::Int,
                                               value::Real)
    names = fieldnames(x)
    types = fieldtypes(x)
    branches = [:(property === $(QuoteNode(names[i])) &&
                  return _with_component(getfield(x, $i), component, value))
                for i in eachindex(names)
                if types[i] <: Union{Vec2, Vec3, Euler, Quaternion, Color3} &&
                   isconcretetype(types[i])]
    return Expr(:block, branches..., :(return _UnhandledField()))
end

function _write_material_track_value!(target, property::Symbol, component::Int, value::Real)
    hasproperty(target, :material) || return false
    return _write_material_component!(target, getproperty(target, :material),
                                      _material_animation_property(property),
                                      component, value)
end

function _write_material_component!(target, mat, property::Symbol, component::Int,
                                    value::Real)
    _material_component_noop_update(mat, property, component, value) && return true
    hasproperty(mat, property) || return false
    replacement = _with_typed_field_component(mat, property, component, value)
    replacement isa _UnhandledField &&
        return _write_material_replacement!(
            target, mat, property,
            _with_component(getproperty(mat, property), component, value))
    return _write_material_replacement!(target, mat, property, replacement)
end

# Field `name` of a material, unrolled over its non-isbits fields (where
# texture slots live) so a runtime name does not box the material.
@generated function _material_slot(mat, name::Symbol)
    branches = [:(name === $(QuoteNode(field)) && return getfield(mat, $(QuoteNode(field))))
                for (field, type) in zip(fieldnames(mat), fieldtypes(mat))
                if !isbitstype(type)]
    return Expr(:block, branches..., :(return getproperty(mat, name)))
end

_material_texture_slot(mat, field::Symbol) =
    hasproperty(mat, field) ? _material_slot(mat, field) : _UnhandledField()

# The texture addressed by a texture-transform track property such as
# :map_offset, with its texture property; `nothing` when `property` is not a
# texture property or the target's material has no such slot.
@inline _split_texture_track_property(property::Symbol) =
    haskey(_TEXTURE_ANIMATION_TRACK_PROPERTIES, property) ?
        _TEXTURE_ANIMATION_TRACK_PROPERTIES[property] : nothing

@inline function _material_texture_for_track(target, property::Symbol)
    split = _split_texture_track_property(property)
    split === nothing && return nothing
    hasproperty(target, :material) || return nothing
    field, texture_property = split
    tex = _material_texture_slot(getproperty(target, :material), field)
    tex isa _UnhandledField && return nothing
    tex isa Texture || throw(ArgumentError("material.$field is not a Texture"))
    return tex, texture_property
end

function _refresh_texture_track_matrix!(tex::Texture)
    tex.matrix_auto_update && texture_update_matrix!(tex)
    return tex
end

# Constant-name access to the Vec2 texture transforms (offset/repeat/center
# are the only Vec2 entries of _TEXTURE_ANIMATION_TRACK_PROPERTIES).
@noinline _throw_texture_vec2(texture_property::Symbol) =
    throw(ArgumentError("texture $texture_property is not a Vec2 animation property"))

@inline function _set_texture_vec2!(tex::Texture, texture_property::Symbol, value::Vec2)
    if texture_property === :offset
        tex.offset = value
    elseif texture_property === :repeat
        tex.repeat = value
    elseif texture_property === :center
        tex.center = value
    else
        _throw_texture_vec2(texture_property)
    end
    return tex
end

@inline function _texture_vec2(tex::Texture, texture_property::Symbol)
    texture_property === :offset && return tex.offset
    texture_property === :repeat && return tex.repeat
    texture_property === :center && return tex.center
    _throw_texture_vec2(texture_property)
end

function _write_texture_track_value!(target, property::Symbol, component::Int, value::Real)
    resolved = _material_texture_for_track(target, property)
    resolved === nothing && return false
    tex, texture_property = resolved
    if texture_property === :matrix_auto_update
        component == 0 || throw(ArgumentError("matrixAutoUpdate is a scalar animation property"))
        tex.matrix_auto_update = value >= 0.5
    elseif texture_property === :rotation
        component == 0 || throw(ArgumentError("texture rotation is a scalar animation property"))
        tex.rotation = Float64(value)
    else
        current = _texture_vec2(tex, texture_property)
        _set_texture_vec2!(tex, texture_property, _with_component(current, component, value))
    end
    _refresh_texture_track_matrix!(tex)
    return true
end

function _write_texture_track_value!(target, property::Symbol, value::Float64)
    resolved = _material_texture_for_track(target, property)
    resolved === nothing && return false
    tex, texture_property = resolved
    if texture_property === :matrix_auto_update
        tex.matrix_auto_update = value >= 0.5
    elseif texture_property === :rotation
        tex.rotation = value
    else
        throw(ArgumentError("texture $texture_property requires a component animation path"))
    end
    _refresh_texture_track_matrix!(tex)
    return true
end

function _write_texture_track_value!(target, property::Symbol, value::Vec3)
    resolved = _material_texture_for_track(target, property)
    resolved === nothing && return false
    tex, texture_property = resolved
    if texture_property in (:offset, :repeat, :center)
        _set_texture_vec2!(tex, texture_property, Vec2(value.x, value.y))
    elseif texture_property === :rotation
        tex.rotation = value.x
    elseif texture_property === :matrix_auto_update
        tex.matrix_auto_update = value.x >= 0.5
    else
        return false
    end
    _refresh_texture_track_matrix!(tex)
    return true
end

function _write_morph_component_value!(values::AbstractVector, component::Int,
                                       value::Float64)
    1 <= component <= length(values) ||
        throw(ArgumentError("morph influence component $(component - 1) is out of range"))
    values[component] = value
    return values
end

# Stores into the target type's `Vec3{Float64}`/`Color3{Float64}` fields,
# and component stores into its vector-like fields, unrolled with constant
# field names: the generic runtime-Symbol getproperty/setproperty! path boxes
# the value on every frame. Each returns false for any other property.
@generated function _set_vec3_track_field!(target, property::Symbol, v::Vec3)
    stmts = Any[]
    for (name, type) in zip(fieldnames(target), fieldtypes(target))
        value = type === Vec3{Float64} ? :v :
                type === Color3{Float64} ? :(Color3(v.x, v.y, v.z)) : nothing
        value === nothing && continue
        push!(stmts, :(property === $(QuoteNode(name)) &&
                       (setproperty!(target, $(QuoteNode(name)), $value); return true)))
    end
    return Expr(:block, stmts..., :(return false))
end

@generated function _set_component_track_field!(target, property::Symbol,
                                                component::Int, v::Real)
    stmts = Any[]
    for (name, type) in zip(fieldnames(target), fieldtypes(target))
        type in (Vec2{Float64}, Vec3{Float64}, Euler{Float64}, Color3{Float64}) || continue
        field = QuoteNode(name)
        push!(stmts, :(property === $field &&
                       (setproperty!(target, $field,
                                     _with_component(getproperty(target, $field),
                                                     component, v));
                        return true)))
    end
    return Expr(:block, stmts..., :(return false))
end

# Morph-influence components are written by `_apply_track!` across the
# target's subtree before this generic path is reached.
function _write_track_value!(target, property::Symbol, component::Int, v::Real)
    component == 0 && return _write_track_value!(target, property, Float64(v))
    property === :quaternion &&
        return _write_quaternion_component!(target, component, v)
    _set_component_track_field!(target, property, component, v) && return target
    _write_texture_track_value!(target, property, component, Float64(v)) &&
        return target
    if !hasproperty(target, property) &&
       _write_material_track_value!(target, property, component, Float64(v))
        return target
    end
    current = getproperty(target, property)
    setproperty!(target, property, _with_component(current, component, v))
    return target
end


function _write_track_value!(target, property::Symbol, v::Quaternion)
    if property === :rotation || property === :quaternion
        order = hasproperty(target, :rotation) ?
            getproperty(target, :rotation).order : :XYZ
        setproperty!(target, :rotation, _transform_quaternion_to_euler(v, order))
    else
        setproperty!(target, property, v)
    end
    return target
end

function _write_track_value!(target, property::Symbol, v::Vec3)
    if property === :rotation
        current = hasproperty(target, :rotation) ? getproperty(target, :rotation) : Euler()
        setproperty!(target, :rotation, Euler(v.x, v.y, v.z, current.order))
        return target
    end
    _set_vec3_track_field!(target, property, v) && return target
    if hasproperty(target, property)
        current = getproperty(target, property)
        setproperty!(target, property,
                     current isa Color3 ? Color3(v.x, v.y, v.z) : v)
    elseif _write_texture_track_value!(target, property, v)
        return target
    elseif _write_material_track_value!(target, property, Color3(v.x, v.y, v.z))
        return target
    else
        setproperty!(target, property, v)
    end
    return target
end

# Unrolled constant-name stores for the target type's `Float64` and `Bool`
# fields (Bool thresholds at 0.5 like the generic path below); the generic
# runtime-Symbol `setproperty!` boxes the value on every frame.
@generated function _set_scalar_track_field!(target, property::Symbol, v::Float64)
    stmts = Any[]
    for (name, field_type) in zip(fieldnames(target), fieldtypes(target))
        (field_type === Float64 || field_type === Bool) || continue
        value = field_type === Bool ? :(v >= 0.5) : :v
        push!(stmts, :(property === $(QuoteNode(name)) &&
                       (setproperty!(target, $(QuoteNode(name)), $value); return true)))
    end
    return Expr(:block, stmts..., :(return false))
end

function _write_track_value!(target, property::Symbol, v::Float64)
    _set_scalar_track_field!(target, property, v) && return target
    if hasproperty(target, property)
        current = getproperty(target, property)
        setproperty!(target, property, current isa Bool ? v >= 0.5 : v)
    elseif _write_texture_track_value!(target, property, v)
        return target
    elseif _write_material_track_value!(target, property, v)
        return target
    else
        setproperty!(target, property, v)
    end
    return target
end

function _morph_buffer_aliases_track(values::Vector{Float64},
                                     tr::MorphWeightsKeyframeTrack)
    for frame in tr.values
        values === frame && return true
    end
    return false
end

function _morph_buffer_aliases_track(values::Vector{Float64},
                                     tr::CubicSplineMorphWeightsKeyframeTrack)
    for frame in tr.values
        values === frame && return true
    end
    for frame in tr.in_tangents
        values === frame && return true
    end
    for frame in tr.out_tangents
        values === frame && return true
    end
    return false
end

# Track application. `_apply_track!` is called with the track's target as a
# separate argument so one dynamic dispatch selects code specialized on both
# the concrete target and track types; the sample time travels inside the
# mixer, so that dispatch boxes nothing. The morph-influence subtree walks
# below are not specialized on the node type: their recursive calls then
# resolve statically, and the immutable track is not re-boxed per node.
const _MorphWeightsTrack =
    Union{MorphWeightsKeyframeTrack, CubicSplineMorphWeightsKeyframeTrack}

function _generic_morph_track_output_buffer!(target, property::Symbol, tr)
    width = length(tr.values[1])
    values = getproperty(target, property)
    if length(values) != width || _morph_buffer_aliases_track(values, tr)
        values = Vector{Float64}(undef, width)
        setproperty!(target, property, values)
    end
    return values
end

# The node's influence vector when it already has the track's width and does
# not alias a keyframe; otherwise a fresh vector stored on the node.
function _morph_track_output_buffer!(@nospecialize(node), property::Symbol,
                                     tr::_MorphWeightsTrack)
    values = getproperty(node, property)
    values isa Vector{Float64} ||
        return _generic_morph_track_output_buffer!(node, property, tr)
    width = length(tr.values[1])
    if length(values) != width || _morph_buffer_aliases_track(values, tr)
        values = Vector{Float64}(undef, width)
        setproperty!(node, property, values)
    end
    return values
end

function _write_morph_track_at_time_tree!(@nospecialize(node), property::Symbol,
                                          tr::_MorphWeightsTrack,
                                          mixer::AnimationMixer)
    wrote = false
    if hasproperty(node, property)
        out = _morph_track_output_buffer!(node, property, tr)
        _sample_morph_weights!(out, tr, mixer.sample_time)
        wrote = true
    end
    children = get_children(node)
    if children isa Vector{AbstractObject3D}
        for child in children
            wrote |= _write_morph_track_at_time_tree!(child, property, tr, mixer)
        end
    else
        for child in children
            wrote |= _write_morph_track_at_time_tree!(child, property, tr, mixer)
        end
    end
    return wrote
end

function _write_morph_component_track_tree!(@nospecialize(node), tr::NumberKeyframeTrack,
                                            mixer::AnimationMixer)
    wrote = false
    if hasproperty(node, :morph_target_influences)
        component = isempty(tr.morph_name) ? tr.component :
            _node_morph_name_index(node, tr.morph_name)
        if component != 0
            values = getproperty(node, :morph_target_influences)
            value = Float64(_mixer_track_value(tr, mixer))
            if values isa Vector{Float64}
                _write_morph_component_value!(values, component, value)
            else
                _write_morph_component_value!(values, component, value)
            end
        end
        wrote = true
    end
    children = get_children(node)
    if children isa Vector{AbstractObject3D}
        for child in children
            wrote |= _write_morph_component_track_tree!(child, tr, mixer)
        end
    else
        for child in children
            wrote |= _write_morph_component_track_tree!(child, tr, mixer)
        end
    end
    return wrote
end

# Sample `tr` at the mixer's clip time. A :cubic track evaluates like the
# action's CubicInterpolant (Interpolant.js:92-248, CubicInterpolant.js:41-155):
# outside the keys it copies the end value and forgets its interval; inside,
# it computes its weights with the action's current endings only when the
# sample enters a different key interval, and keeps them while it stays.
_mixer_track_value(tr::AbstractKeyframeTrack, mixer::_ActionStepper) =
    _track_value(tr, mixer.sample_time)
function _mixer_track_value(tr::Union{KeyframeTrack,NumberKeyframeTrack},
                            mixer::_ActionStepper)
    tr.interpolation === :cubic || return _track_value(tr, mixer.sample_time)
    t = mixer.sample_time
    times = tr.times
    i = mixer.track_index
    n = length(times)
    if t < times[1] || t >= times[n]
        mixer.cubic_interval[i] = 0
        return t < times[1] ? tr.values[1] : tr.values[n]
    end
    interval = searchsortedlast(times, t)
    if mixer.cubic_interval[i] != interval
        mixer.cubic_interval[i] = interval
        mixer.cubic_ending_start[i] = mixer.ending_start
        mixer.cubic_ending_end[i] = mixer.ending_end
    end
    return _cubic_interpolant_sample(times, tr.values, t, mixer.cubic_ending_start[i],
                                     mixer.cubic_ending_end[i])
end

_apply_track!(target, tr::AbstractKeyframeTrack, mixer::AnimationMixer) =
    _write_track_value!(target, tr.property, _mixer_track_value(tr, mixer))

function _apply_track!(target, tr::NumberKeyframeTrack, mixer::AnimationMixer)
    if tr.property === :morph_target_influences && tr.component != 0
        _write_morph_component_track_tree!(target, tr, mixer) ||
            throw(ArgumentError("target does not expose morph target influences"))
        return target
    end
    return _write_track_value!(target, tr.property, tr.component,
                               _mixer_track_value(tr, mixer))
end

function _apply_track!(target, tr::_MorphWeightsTrack, mixer::AnimationMixer)
    if tr.property === :morph_target_influences &&
       _write_morph_track_at_time_tree!(target, tr.property, tr, mixer)
        return target
    end
    return _write_track_value!(target, tr.property, _track_value(tr, mixer.sample_time))
end

# ---- Original values (three.js PropertyMixer.saveOriginalState) ----------
#
# Each track's original is stored in the form its writer takes, and restored
# through that writer, so a restore undoes exactly what the track writes.
# Readers return `nothing` for a property they cannot read; the writer then
# reports the problem on the first update.

@inline _rotation_track_property(property::Symbol) =
    property === :rotation || property === :quaternion

function _original_texture(target, property::Symbol)
    split = _split_texture_track_property(property)
    split === nothing && return nothing
    hasproperty(target, :material) || return nothing
    field, texture_property = split
    tex = _material_texture_slot(getproperty(target, :material), field)
    tex isa Texture || return nothing
    return tex, texture_property
end

function _original_material_value(target, property::Symbol)
    hasproperty(target, :material) || return nothing
    mat = getproperty(target, :material)
    name = _material_animation_property(property)
    hasproperty(mat, name) || return nothing
    return getproperty(mat, name)
end

_original_vec3(v::Vec3) = Vec3{Float64}(v.x, v.y, v.z)
_original_vec3(v::Color3) = Vec3{Float64}(v.r, v.g, v.b)
_original_vec3(::Any) = nothing

_original_scalar(v::Bool) = v ? 1.0 : 0.0
_original_scalar(v::Real) = Float64(v)
_original_scalar(::Any) = nothing

_original_component(v::Union{Vec2,Vec3,Euler}, k::Int) =
    k == 1 ? Float64(v.x) : k == 2 ? Float64(v.y) :
    (k == 3 && !(v isa Vec2)) ? Float64(v.z) : nothing
_original_component(v::Quaternion, k::Int) =
    k == 1 ? v.x : k == 2 ? v.y : k == 3 ? v.z : k == 4 ? v.w : nothing
_original_component(v::Color3, k::Int) =
    k == 1 ? v.r : k == 2 ? v.g : k == 3 ? v.b : nothing
_original_component(::Any, ::Int) = nothing

function _original_texture_value(tex::Texture, texture_property::Symbol)
    texture_property === :rotation && return tex.rotation
    texture_property === :matrix_auto_update && return tex.matrix_auto_update
    return _texture_vec2(tex, texture_property)
end

# The value of `property` a writer of the given kind reads back: from the
# target, else the texture slot, else the material (the writers' order).
function _original_property_value(target, property::Symbol)
    hasproperty(target, property) && return getproperty(target, property)
    tex = _original_texture(target, property)
    tex === nothing || return _original_texture_value(tex[1], tex[2])
    return _original_material_value(target, property)
end

function _original_vec3_property(target, property::Symbol)
    value = _original_property_value(target, property)
    value isa Vec2 && return Vec3{Float64}(value.x, value.y, 0.0)
    value isa Union{Bool,Real} && return Vec3{Float64}(_original_scalar(value), 0.0, 0.0)
    return _original_vec3(value)
end

function _morph_component_originals(node, tr::NumberKeyframeTrack,
                                    out::Vector{Tuple{Any,Int,Float64}})
    if hasproperty(node, :morph_target_influences)
        k = isempty(tr.morph_name) ? tr.component :
            _node_morph_name_index(node, tr.morph_name)
        values = getproperty(node, :morph_target_influences)
        1 <= k <= length(values) && push!(out, (node, k, Float64(values[k])))
    end
    for child in get_children(node)
        _morph_component_originals(child, tr, out)
    end
    return out
end

function _morph_vector_originals(node, out::Vector{Tuple{Any,Vector{Float64}}})
    if hasproperty(node, :morph_target_influences)
        push!(out, (node, collect(Float64, getproperty(node, :morph_target_influences))))
    end
    for child in get_children(node)
        _morph_vector_originals(child, out)
    end
    return out
end

function _track_original(target, tr::Union{KeyframeTrack,CubicSplineKeyframeTrack})
    tr.property === :rotation &&
        return hasproperty(target, :rotation) ? getproperty(target, :rotation) : nothing
    return _original_vec3_property(target, tr.property)
end

function _track_original(target, tr::NumberKeyframeTrack)
    if tr.property === :morph_target_influences && tr.component != 0
        return _morph_component_originals(target, tr, Tuple{Any,Int,Float64}[])
    elseif tr.property === :quaternion && tr.component != 0
        return hasproperty(target, :rotation) ? getproperty(target, :rotation) : nothing
    elseif tr.component == 0
        return _original_scalar(_original_property_value(target, tr.property))
    end
    return _original_component(_original_property_value(target, tr.property),
                               tr.component)
end

function _track_original(target, tr::Union{QuaternionKeyframeTrack,
                                          CubicSplineQuaternionKeyframeTrack})
    _rotation_track_property(tr.property) &&
        return hasproperty(target, :rotation) ? getproperty(target, :rotation) : nothing
    return hasproperty(target, tr.property) ? getproperty(target, tr.property) : nothing
end

function _track_original(target, tr::_MorphWeightsTrack)
    if tr.property === :morph_target_influences
        out = _morph_vector_originals(target, Tuple{Any,Vector{Float64}}[])
        isempty(out) || return out
    end
    hasproperty(target, tr.property) || return nothing
    value = getproperty(target, tr.property)
    return value isa AbstractVector ? copy(value) : value
end

function _restore_rotation!(target, rotation)
    rotation isa Euler && setproperty!(target, :rotation, rotation)
    return nothing
end

_restore_track_original!(target, tr::Union{KeyframeTrack,CubicSplineKeyframeTrack}, orig) =
    tr.property === :rotation ? _restore_rotation!(target, orig) :
    (_write_track_value!(target, tr.property, orig::Vec3{Float64}); nothing)

function _restore_track_original!(target, tr::NumberKeyframeTrack, orig)
    if tr.property === :morph_target_influences && tr.component != 0
        for (node, k, value) in orig::Vector{Tuple{Any,Int,Float64}}
            values = getproperty(node, :morph_target_influences)
            1 <= k <= length(values) && (values[k] = value)
        end
    elseif tr.property === :quaternion && tr.component != 0
        _restore_rotation!(target, orig)
    elseif tr.component == 0
        _write_track_value!(target, tr.property, orig::Float64)
    else
        _write_track_value!(target, tr.property, tr.component, orig::Float64)
    end
    return nothing
end

function _restore_track_original!(target, tr::Union{QuaternionKeyframeTrack,
                                                   CubicSplineQuaternionKeyframeTrack},
                                  orig)
    _rotation_track_property(tr.property) && return _restore_rotation!(target, orig)
    setproperty!(target, tr.property, orig)
    return nothing
end

function _restore_track_original!(target, tr::_MorphWeightsTrack, orig)
    if orig isa Vector{Tuple{Any,Vector{Float64}}}
        for (node, saved) in orig
            values = getproperty(node, :morph_target_influences)
            if values isa Vector{Float64} && length(values) == length(saved) &&
               !_morph_buffer_aliases_track(values, tr)
                copyto!(values, saved)
            else
                setproperty!(node, :morph_target_influences, copy(saved))
            end
        end
        return nothing
    end
    setproperty!(target, tr.property, orig isa AbstractVector ? copy(orig) : orig)
    return nothing
end

function _save_originals!(mixer::AnimationMixer)
    for (i, tr) in pairs(mixer.clip.tracks)
        mixer.originals[i] = _track_original(tr.target, tr)
    end
    return mixer
end

function _restore_originals!(mixer::AnimationMixer)
    for (i, tr) in pairs(mixer.clip.tracks)
        orig = mixer.originals[i]
        orig === nothing || _restore_track_original!(tr.target, tr, orig)
    end
    return mixer
end

# ---- Action stepping -------------------------------------------------------

function _mixer_apply_tracks!(mixer::AnimationMixer)
    tracks = mixer.clip.tracks
    for i in eachindex(tracks)
        tr = tracks[i]
        mixer.track_index = i
        _apply_track!(tr.target, tr, mixer)
    end
    return mixer
end

# One action update (AnimationAction._update with weight 1 and
# PropertyMixer.apply): a disabled action contributes nothing; the update
# that disables it writes the original values back.
function _mixer_step!(mixer::AnimationMixer, delta::Float64)
    mixer.active || return mixer
    if mixer.enabled
        clip_time = _update_action_time!(mixer, mixer.paused ? 0.0 : delta)
        if mixer.enabled
            mixer.sample_time = clip_time
            _mixer_apply_tracks!(mixer)
            mixer.applied = true
            return mixer
        end
    end
    # Weight 0: PropertyMixer.apply mixes in the original value, which changes
    # the property only on the first such update after the clip was applied.
    mixer.applied && _restore_originals!(mixer)
    mixer.applied = false
    return mixer
end

"""
    mixer_set_time!(mixer, t) -> mixer

Restart the action and play it to time `t`, scaled once by
`mixer.time_scale`, applying the pose there: three.js `action.reset()`
followed by `mixer.setTime(t)` (AnimationMixer.js `setTime` zeroes the
action time and runs one update of `t`). From a restart, every loop and
finish rule of `mixer_update!` applies to that single step; a stopped mixer
only records the time.
"""
function mixer_set_time!(mixer::AnimationMixer, t)
    t isa Real && !(t isa Bool) ||
        throw(ArgumentError("mixer_set_time!: time must be finite"))
    time = Float64(t)
    isfinite(time) ||
        throw(ArgumentError("mixer_set_time!: time must be finite"))
    time_scale = _validated_animation_time_scale(mixer.time_scale)
    scaled_time = _checked_control_scalar(
        time * time_scale, "animation time")
    _animation_loop_mode(mixer.loop)
    _reset_action!(mixer)
    _mixer_step!(mixer, scaled_time)
    mixer.time = scaled_time
    return mixer
end

"""
    mixer_update!(mixer, dt) -> mixer

Advance the mixer time by `dt * mixer.time_scale` and step the action by
that amount (three.js `AnimationMixer.update`), applying the sampled pose;
see `AnimationMixer` for the loop, finish and restore rules.
"""
function mixer_update!(mixer::AnimationMixer, dt)
    delta = _checked_control_scalar(dt, "mixer_update!: dt")
    time = _checked_control_scalar(
        mixer.time, "AnimationMixer current time")
    time_scale = _validated_animation_time_scale(mixer.time_scale)
    scaled_delta = _checked_control_scalar(
        delta * time_scale, "AnimationMixer scaled delta")
    next_time = _checked_control_scalar(
        time + scaled_delta, "AnimationMixer updated time")
    _mixer_step!(mixer, scaled_delta)
    mixer.time = next_time
    return mixer
end

function _reset_action!(mixer::AnimationMixer)
    mixer.paused = false
    mixer.enabled = true
    mixer.action_time = 0.0
    mixer.loop_count = -1
    return mixer
end

"""
    mixer_reset!(mixer) -> mixer

Restart the action without applying anything (three.js
`AnimationAction.reset`): it is enabled and unpaused again, its clip time is
0 and its loop count is forgotten. The mixer time and the original values are
kept.
"""
mixer_reset!(mixer::AnimationMixer) = _reset_action!(mixer)

"""
    mixer_stop!(mixer) -> mixer

Stop the action (three.js `AnimationAction.stop`): every animated property
gets its original value back, the action is reset, and `mixer_update!` and
`mixer_set_time!` stop applying the clip until `mixer_play!`.
"""
function mixer_stop!(mixer::AnimationMixer)
    mixer.active && _restore_originals!(mixer)
    mixer.active = false
    mixer.applied = false
    return _reset_action!(mixer)
end

"""
    mixer_play!(mixer) -> mixer

Schedule a stopped action again (three.js `AnimationAction.play`): the
current property values become the originals that a finish or
`mixer_stop!` restores. A mixer plays from construction, so this only acts
after `mixer_stop!`.
"""
function mixer_play!(mixer::AnimationMixer)
    mixer.active && return mixer
    _save_originals!(mixer)
    mixer.active = true
    return mixer
end

"""
    mixer_is_running(mixer) -> Bool

Whether the action is currently advancing (three.js
`AnimationAction.isRunning`): scheduled, enabled, not paused and with a
nonzero `time_scale`.
"""
mixer_is_running(mixer::AnimationMixer) =
    mixer.active && mixer.enabled && !mixer.paused && mixer.time_scale != 0.0

"""
    mixer_is_scheduled(mixer) -> Bool

Whether the action is scheduled, that is played and not stopped (three.js
`AnimationAction.isScheduled`); a finished action stays scheduled.
"""
mixer_is_scheduled(mixer::AnimationMixer) = mixer.active

"""
    mixer_set_loop!(mixer, loop[, repetitions]) -> mixer

Set the loop mode (`:repeat`, `:once` or `:pingpong`) and the repetitions
(`-1` for unlimited, the default), as three.js `AnimationAction.setLoop`.
"""
function mixer_set_loop!(mixer::AnimationMixer, loop::Symbol, repetitions::Integer=-1)
    mode = _animation_loop_mode(loop)
    reps = _validated_animation_repetitions(repetitions)
    mixer.loop = mode
    mixer.repetitions = reps
    return mixer
end

# ---- Multi-action mixer: property bindings (three.js PropertyBinding) ------

const _BINDING_VEC3 = 1          # Vec3 track on a Vec3/Color3/Vec2/scalar property
const _BINDING_EULER = 2         # Vec3 track on :rotation (Euler angles)
const _BINDING_SCALAR = 3        # whole-value number track
const _BINDING_BOOL = 4          # number track on a Bool property (three.js 'bool')
const _BINDING_COMPONENT = 5     # number track on one component of a property
const _BINDING_MORPH = 6         # one morph influence of one node
const _BINDING_QUATERNION = 7    # quaternion track
const _BINDING_VECTOR = 8        # whole influence vector of one node

@noinline _throw_unreadable_binding(property::Symbol) = throw(ArgumentError(
    "animation property $property cannot be read for blending"))

_binding_original_euler(node) =
    hasproperty(node, :rotation) && (r = getproperty(node, :rotation)) isa Euler ? r : nothing

# PropertyBinding.getValue into the `orig` region.
function _binding_get!(node, b::_AnimationBinding)
    buf = b.buffer
    o = 3 * b.stride
    kind = b.kind
    property = b.property
    if kind == _BINDING_VEC3
        v = _original_vec3_property(node, property)
        v === nothing && _throw_unreadable_binding(property)
        buf[o + 1] = v.x
        buf[o + 2] = v.y
        buf[o + 3] = v.z
    elseif kind == _BINDING_EULER
        r = getproperty(node, :rotation)
        r isa Euler || _throw_unreadable_binding(property)
        buf[o + 1] = r.x
        buf[o + 2] = r.y
        buf[o + 3] = r.z
    elseif kind == _BINDING_SCALAR || kind == _BINDING_BOOL
        v = _original_scalar(_original_property_value(node, property))
        v === nothing && _throw_unreadable_binding(property)
        buf[o + 1] = v
    elseif kind == _BINDING_COMPONENT
        value = property === :quaternion ? _target_rotation_quaternion(node) :
            _original_property_value(node, property)
        v = _original_component(value, b.component)
        v === nothing && _throw_unreadable_binding(property)
        buf[o + 1] = v
        property === :quaternion && (b.original_rotation = _binding_original_euler(node))
    elseif kind == _BINDING_MORPH
        values = getproperty(node, :morph_target_influences)
        1 <= b.component <= length(values) || throw(ArgumentError(
            "morph influence component $(b.component - 1) is out of range"))
        buf[o + 1] = Float64(values[b.component])
    elseif kind == _BINDING_QUATERNION
        q = _rotation_track_property(property) ? _target_rotation_quaternion(node) :
            getproperty(node, property)
        q isa Quaternion || _throw_unreadable_binding(property)
        buf[o + 1] = q.x
        buf[o + 2] = q.y
        buf[o + 3] = q.z
        buf[o + 4] = q.w
        _rotation_track_property(property) &&
            (b.original_rotation = _binding_original_euler(node))
    else
        values = getproperty(node, property)
        values isa AbstractVector{<:Real} || _throw_unreadable_binding(property)
        s = b.stride
        n = length(values)
        for i in 1:s
            buf[o + i] = i <= n ? Float64(values[i]) : 0.0
        end
        b.original_vector = n == s ? Float64[] : collect(Float64, values)
    end
    return nothing
end

# PropertyBinding.setValue from the region at `b.apply_offset`, through the
# writers AnimationMixer uses.
function _binding_set!(node, b::_AnimationBinding)
    buf = b.buffer
    o = b.apply_offset
    kind = b.kind
    property = b.property
    @inbounds if kind == _BINDING_VEC3
        _write_track_value!(node, property, Vec3{Float64}(buf[o + 1], buf[o + 2], buf[o + 3]))
    elseif kind == _BINDING_EULER
        _write_track_value!(node, :rotation, Vec3{Float64}(buf[o + 1], buf[o + 2], buf[o + 3]))
    elseif kind == _BINDING_SCALAR || kind == _BINDING_BOOL
        _write_track_value!(node, property, buf[o + 1])
    elseif kind == _BINDING_COMPONENT
        _write_track_value!(node, property, b.component, buf[o + 1])
    elseif kind == _BINDING_MORPH
        _write_morph_component_value!(getproperty(node, :morph_target_influences),
                                      b.component, buf[o + 1])
    elseif kind == _BINDING_QUATERNION
        _write_track_value!(node, property,
                            Quaternion{Float64}(buf[o + 1], buf[o + 2], buf[o + 3], buf[o + 4]))
    else
        _binding_set_vector!(node, b, o)
    end
    return nothing
end

# A whole influence vector is written into the node's vector, which is
# replaced when its length differs or it is one of the keyframe vectors of
# a track bound here (writing into it would change the track).
function _binding_set_vector!(node, b::_AnimationBinding, o::Int)
    s = b.stride
    values = getproperty(node, b.property)
    if !(values isa Vector{Float64}) || length(values) != s ||
       _binding_aliases_keyframes(b, values)
        values = Vector{Float64}(undef, s)
        setproperty!(node, b.property, values)
    end
    copyto!(values, 1, b.buffer, o + 1, s)
    return nothing
end

function _binding_aliases_keyframes(b::_AnimationBinding, values::Vector{Float64})
    for tr in b.vector_tracks
        _morph_buffer_aliases_track(values, tr) && return true
    end
    return false
end

# PropertyMixer.restoreOriginalState. A vector binding whose node had a
# vector of another width gets that vector's values back, and a quaternion
# binding the original Euler angles, as AnimationMixer restores them.
function _binding_restore_original!(b::_AnimationBinding)
    if b.kind == _BINDING_VECTOR && !isempty(b.original_vector)
        original = b.original_vector
        values = getproperty(b.node, b.property)
        if values isa Vector{Float64} && length(values) == length(original) &&
           !_binding_aliases_keyframes(b, values)
            copyto!(values, original)
        else
            setproperty!(b.node, b.property, copy(original))
        end
        return nothing
    end
    rotation = b.original_rotation
    if rotation isa Euler
        setproperty!(b.node, :rotation, rotation)
        return nothing
    end
    b.apply_offset = 3 * b.stride
    _binding_set!(b.node, b)
    return nothing
end

# ---- Multi-action mixer: PropertyMixer numerics ----------------------------

# three.js Quaternion.slerpFlat (src/math/Quaternion.js) on quadruples of
# `buf` at 0-based offsets, in the same operation order.
@inline function _slerp_flat!(buf::Vector{Float64}, dst::Int, src0::Int, src1::Int,
                              t::Float64)
    @inbounds begin
        x0 = buf[src0 + 1]; y0 = buf[src0 + 2]; z0 = buf[src0 + 3]; w0 = buf[src0 + 4]
        x1 = buf[src1 + 1]; y1 = buf[src1 + 2]; z1 = buf[src1 + 3]; w1 = buf[src1 + 4]
        if w0 != w1 || x0 != x1 || y0 != y1 || z0 != z1
            dot = x0 * x1 + y0 * y1 + z0 * z1 + w0 * w1
            if dot < 0
                x1 = -x1; y1 = -y1; z1 = -z1; w1 = -w1
                dot = -dot
            end
            s = 1 - t
            if dot < 0.9995
                theta = acos(dot)
                sn = sin(theta)
                s = sin(s * theta) / sn
                t = sin(t * theta) / sn
                x0 = x0 * s + x1 * t
                y0 = y0 * s + y1 * t
                z0 = z0 * s + z1 * t
                w0 = w0 * s + w1 * t
            else
                x0 = x0 * s + x1 * t
                y0 = y0 * s + y1 * t
                z0 = z0 * s + z1 * t
                w0 = w0 * s + w1 * t
                f = 1 / sqrt(x0 * x0 + y0 * y0 + z0 * z0 + w0 * w0)
                x0 *= f; y0 *= f; z0 *= f; w0 *= f
            end
        end
        buf[dst + 1] = x0; buf[dst + 2] = y0; buf[dst + 3] = z0; buf[dst + 4] = w0
    end
    return nothing
end

# three.js Quaternion.multiplyQuaternionsFlat: dst = src0 * src1.
@inline function _multiply_quaternions_flat!(buf::Vector{Float64}, dst::Int, src0::Int,
                                             src1::Int)
    @inbounds begin
        x0 = buf[src0 + 1]; y0 = buf[src0 + 2]; z0 = buf[src0 + 3]; w0 = buf[src0 + 4]
        x1 = buf[src1 + 1]; y1 = buf[src1 + 2]; z1 = buf[src1 + 3]; w1 = buf[src1 + 4]
        buf[dst + 1] = x0 * w1 + w0 * x1 + y0 * z1 - z0 * y1
        buf[dst + 2] = y0 * w1 + w0 * y1 + z0 * x1 - x0 * z1
        buf[dst + 3] = z0 * w1 + w0 * z1 + x0 * y1 - y0 * x1
        buf[dst + 4] = w0 * w1 - x0 * x1 - y0 * y1 - z0 * z1
    end
    return nothing
end

# PropertyMixer._select / _slerp / _lerp: mix the region at `src` into the
# region at `dst` with weight `t`.
@inline function _binding_mix!(b::_AnimationBinding, dst::Int, src::Int, t::Float64)
    buf = b.buffer
    s = b.stride
    if b.kind == _BINDING_QUATERNION
        _slerp_flat!(buf, dst, dst, src, t)
    elseif b.kind == _BINDING_BOOL
        if t >= 0.5
            @inbounds for i in 1:s
                buf[dst + i] = buf[src + i]
            end
        end
    else
        u = 1 - t
        @inbounds for i in 1:s
            j = dst + i
            buf[j] = buf[j] * u + buf[src + i] * t
        end
    end
    return nothing
end

# PropertyMixer._select / _slerpAdditive / _lerpAdditive.
@inline function _binding_mix_additive!(b::_AnimationBinding, dst::Int, src::Int,
                                        t::Float64)
    buf = b.buffer
    s = b.stride
    if b.kind == _BINDING_QUATERNION
        work = 5 * s
        _multiply_quaternions_flat!(buf, work, dst, src)
        _slerp_flat!(buf, dst, dst, work, t)
    elseif b.kind == _BINDING_BOOL
        if t >= 0.5
            @inbounds for i in 1:s
                buf[dst + i] = buf[src + i]
            end
        end
    else
        @inbounds for i in 1:s
            j = dst + i
            buf[j] = buf[j] + buf[src + i] * t
        end
    end
    return nothing
end

# PropertyMixer._setAdditiveIdentity{Numeric,Quaternion,Other}.
function _binding_set_additive_identity!(b::_AnimationBinding)
    buf = b.buffer
    s = b.stride
    add = 4 * s
    @inbounds if b.kind == _BINDING_BOOL
        for i in 1:s
            buf[add + i] = buf[3 * s + i]
        end
    else
        for i in 1:s
            buf[add + i] = 0.0
        end
        b.kind == _BINDING_QUATERNION && (buf[add + 4] = 1.0)
    end
    return nothing
end

# PropertyMixer.accumulate (PropertyMixer.js accumulate).
function _binding_accumulate!(b::_AnimationBinding, accu_index::Int, weight::Float64)
    buf = b.buffer
    s = b.stride
    offset = accu_index * s + s
    current = b.cumulative_weight
    if current == 0
        @inbounds for i in 1:s
            buf[offset + i] = buf[i]
        end
        current = weight
    else
        current += weight
        _binding_mix!(b, offset, 0, weight / current)
    end
    b.cumulative_weight = current
    return nothing
end

# PropertyMixer.accumulateAdditive.
function _binding_accumulate_additive!(b::_AnimationBinding, weight::Float64)
    b.cumulative_weight_additive == 0 && _binding_set_additive_identity!(b)
    _binding_mix_additive!(b, 4 * b.stride, 0, weight)
    b.cumulative_weight_additive += weight
    return nothing
end

# PropertyMixer.apply: fill the missing weight with the original value, add
# the additive layer, and write the result when it differs from the
# previous update's.
function _binding_apply!(b::_AnimationBinding, accu_index::Int)
    buf = b.buffer
    s = b.stride
    offset = accu_index * s + s
    weight = b.cumulative_weight
    weight_additive = b.cumulative_weight_additive
    b.cumulative_weight = 0.0
    b.cumulative_weight_additive = 0.0
    weight < 1 && _binding_mix!(b, offset, 3 * s, 1 - weight)
    weight_additive > 0 && _binding_mix_additive!(b, offset, 4 * s, 1.0)
    @inbounds for i in (s + 1):(2 * s)
        if buf[i] != buf[i + s]
            if weight == 0 && !(weight_additive > 0)
                # No action contributes, so the result is the original
                # value: write it as saved, which also keeps the width of a
                # morph-influence vector the track's width does not match
                # and the original Euler angles of a quaternion property.
                _binding_restore_original!(b)
            else
                b.apply_offset = offset
                _binding_set!(b.node, b)
            end
            break
        end
    end
    return nothing
end

# PropertyMixer.saveOriginalState.
function _binding_save_original!(b::_AnimationBinding)
    buf = b.buffer
    s = b.stride
    orig = 3 * s
    _binding_get!(b.node, b)
    @inbounds for i in s:(orig - 1)
        buf[i + 1] = buf[orig + i % s + 1]
    end
    _binding_set_additive_identity!(b)
    b.cumulative_weight = 0.0
    b.cumulative_weight_additive = 0.0
    return nothing
end

# ---- Multi-action mixer: binding tracks to properties ---------------------

# (node, property, component, kind, stride) of every property a track
# drives. Morph tracks bound to a parent drive each descendant that has
# influences, as AnimationMixer applies them.
const _BindingSpec = Tuple{Any,Symbol,Int,Int,Int}

function _track_binding_specs(tr::Union{KeyframeTrack,CubicSplineKeyframeTrack})
    target = tr.target
    kind = tr.property === :rotation && hasproperty(target, :rotation) ?
        _BINDING_EULER : _BINDING_VEC3
    return _BindingSpec[(target, tr.property, 0, kind, 3)]
end

function _morph_component_specs!(node, tr::NumberKeyframeTrack, out::Vector{_BindingSpec})
    found = false
    if hasproperty(node, :morph_target_influences)
        found = true
        k = isempty(tr.morph_name) ? tr.component : _node_morph_name_index(node, tr.morph_name)
        k == 0 || push!(out, (node, :morph_target_influences, k, _BINDING_MORPH, 1))
    end
    for child in get_children(node)
        found |= _morph_component_specs!(child, tr, out)
    end
    return found
end

function _track_binding_specs(tr::NumberKeyframeTrack)
    target = tr.target
    if tr.property === :morph_target_influences && tr.component != 0
        specs = _BindingSpec[]
        _morph_component_specs!(target, tr, specs) ||
            throw(ArgumentError("target does not expose morph target influences"))
        return specs
    elseif tr.component == 0
        kind = _original_property_value(target, tr.property) isa Bool ?
            _BINDING_BOOL : _BINDING_SCALAR
        return _BindingSpec[(target, tr.property, 0, kind, 1)]
    end
    return _BindingSpec[(target, tr.property, tr.component, _BINDING_COMPONENT, 1)]
end

_track_binding_specs(tr::Union{QuaternionKeyframeTrack,CubicSplineQuaternionKeyframeTrack}) =
    _BindingSpec[(tr.target, tr.property, 0, _BINDING_QUATERNION, 4)]

function _morph_vector_specs!(node, property::Symbol, width::Int,
                              out::Vector{_BindingSpec})
    hasproperty(node, property) && push!(out, (node, property, 0, _BINDING_VECTOR, width))
    for child in get_children(node)
        _morph_vector_specs!(child, property, width, out)
    end
    return out
end

function _track_binding_specs(tr::_MorphWeightsTrack)
    width = length(tr.values[1])
    specs = _BindingSpec[]
    if tr.property === :morph_target_influences
        _morph_vector_specs!(tr.target, tr.property, width, specs)
    elseif hasproperty(tr.target, tr.property)
        push!(specs, (tr.target, tr.property, 0, _BINDING_VECTOR, width))
    end
    isempty(specs) && throw(ArgumentError(
        "animation target has no property $(tr.property) for a morph-weight track"))
    return specs
end

_binding_matches(b::_AnimationBinding, spec::_BindingSpec) =
    b.node === spec[1] && b.property === spec[2] && b.component == spec[3] &&
    b.kind == spec[4] && b.stride == spec[5]

# three.js AnimationMixer._bindAction: each track's properties get the
# mixer's existing PropertyMixer or a new one. New bindings are read once
# (so an unreadable property fails here) and join the mixer only after every
# track of the clip has bound.
function _bind_action_tracks!(mixer::AnimationActionMixer, clip::AnimationClip)
    added = _AnimationBinding[]
    track_bindings = Vector{_AnimationBinding}[]
    for tr in clip.tracks
        bound = _AnimationBinding[]
        for spec in _track_binding_specs(tr)
            k = findfirst(b -> _binding_matches(b, spec), mixer.bindings)
            b = k === nothing ? nothing : mixer.bindings[k]
            if b === nothing
                k = findfirst(b -> _binding_matches(b, spec), added)
                b = k === nothing ? nothing : added[k]
            end
            if b === nothing
                node, property, component, kind, stride = spec
                b = _AnimationBinding(node, property, component, kind, stride,
                                      zeros(6 * stride), 0.0, 0.0, 0, 0, 0, Float64[],
                                      nothing, AbstractKeyframeTrack[])
                _binding_get!(node, b)
                push!(added, b)
            end
            if b.kind == _BINDING_VECTOR && !any(t -> t === tr, b.vector_tracks)
                push!(b.vector_tracks, tr)
            end
            push!(bound, b)
        end
        push!(track_bindings, bound)
    end
    for b in added
        push!(mixer.bindings, b)
        b.cache_index = length(mixer.bindings)
    end
    return track_bindings
end

# ---- Multi-action mixer: memory manager (AnimationMixer.js) ---------------
#
# `actions` and `bindings` keep the active entries first, in the order three.js
# swaps them in and out, so updates accumulate in the three.js order.

_is_active_action(a::_MixerAction) = a.cache_index <= a.mixer.n_active_actions

function _lend_action!(mixer::AnimationActionMixer, a::_MixerAction)
    actions = mixer.actions
    prev = a.cache_index
    last_active = mixer.n_active_actions += 1
    first_inactive = actions[last_active]
    a.cache_index = last_active
    actions[last_active] = a
    first_inactive.cache_index = prev
    actions[prev] = first_inactive
    return nothing
end

function _take_back_action!(mixer::AnimationActionMixer, a::_MixerAction)
    actions = mixer.actions
    prev = a.cache_index
    first_inactive = mixer.n_active_actions
    mixer.n_active_actions -= 1
    last_active = actions[first_inactive]
    a.cache_index = first_inactive
    actions[first_inactive] = a
    last_active.cache_index = prev
    actions[prev] = last_active
    return nothing
end

function _lend_binding!(mixer::AnimationActionMixer, b::_AnimationBinding)
    bindings = mixer.bindings
    prev = b.cache_index
    last_active = mixer.n_active_bindings += 1
    first_inactive = bindings[last_active]
    b.cache_index = last_active
    bindings[last_active] = b
    first_inactive.cache_index = prev
    bindings[prev] = first_inactive
    return nothing
end

function _take_back_binding!(mixer::AnimationActionMixer, b::_AnimationBinding)
    bindings = mixer.bindings
    prev = b.cache_index
    first_inactive = mixer.n_active_bindings
    mixer.n_active_bindings -= 1
    last_active = bindings[first_inactive]
    b.cache_index = first_inactive
    bindings[first_inactive] = b
    last_active.cache_index = prev
    bindings[prev] = last_active
    return nothing
end

# AnimationMixer._lendControlInterpolant: reuse a pooled ramp (keeping its
# Interpolant._cachedIndex) or make a new one.
function _lend_control_interpolant!(mixer::AnimationActionMixer)
    pool = mixer.control_interpolants
    index = mixer.n_active_control_interpolants += 1
    if index > length(pool)
        push!(pool, _ControlInterpolant(0.0f0, 0.0f0, 0.0f0, 0.0f0, 0, index))
    end
    return pool[index]
end

function _take_back_control_interpolant!(mixer::AnimationActionMixer,
                                         ci::_ControlInterpolant)
    pool = mixer.control_interpolants
    prev = ci.cache_index
    first_inactive = mixer.n_active_control_interpolants
    mixer.n_active_control_interpolants -= 1
    last_active = pool[first_inactive]
    ci.cache_index = first_inactive
    pool[first_inactive] = ci
    last_active.cache_index = prev
    pool[prev] = last_active
    return nothing
end

# Key `i` (0-based) of a ramp; NaN stands for JavaScript's `undefined`
# outside the two keys, since every comparison with either is false.
@inline _control_time(ci::_ControlInterpolant, i::Int) =
    i == 0 ? Float64(ci.t0) : i == 1 ? Float64(ci.t1) : NaN
@inline _control_value(ci::_ControlInterpolant, i::Int) =
    i == 0 ? Float64(ci.v0) : i == 1 ? Float64(ci.v1) : NaN

# Interpolant.evaluate (src/math/Interpolant.js) with LinearInterpolant.
# interpolate_ for the two keys of a ramp, including its interval cache;
# the result is rounded to Float32 like the Float32Array result buffer.
function _control_evaluate(ci::_ControlInterpolant, t::Float64)
    i1 = ci.cached_index
    t1 = _control_time(ci, i1)
    t0 = _control_time(ci, i1 - 1)
    found = false           # `break seek`
    binary = false          # fall through to the binary search
    right = 0
    if !(t < t1)            # forward_scan
        give_up = i1 + 2
        scan_broken = false
        while true
            if isnan(t1)
                if t < t0
                    scan_broken = true
                    break
                end
                ci.cached_index = 2
                return Float32(_control_value(ci, 1))
            end
            i1 == give_up && break
            t0 = t1
            i1 += 1
            t1 = _control_time(ci, i1)
            if t < t1
                found = true
                break
            end
        end
        if !found && !scan_broken
            right = 2
            binary = true
        end
    end
    valid = false
    if !found && !binary
        if !(t >= t0)
            t1global = _control_time(ci, 1)
            if t < t1global
                i1 = 2
                t0 = t1global
            end
            give_up = i1 - 2
            while true
                if isnan(t0)
                    ci.cached_index = 0
                    return Float32(_control_value(ci, 0))
                end
                i1 == give_up && break
                t1 = t0
                i1 -= 1
                t0 = _control_time(ci, i1 - 1)
                if t >= t0
                    found = true
                    break
                end
            end
            if !found
                right = i1
                i1 = 0
                binary = true
            end
        else
            valid = true
        end
    end
    if binary
        while i1 < right
            mid = (i1 + right) >>> 1
            if t < _control_time(ci, mid)
                right = mid
            else
                i1 = mid + 1
            end
        end
        t1 = _control_time(ci, i1)
        t0 = _control_time(ci, i1 - 1)
        if isnan(t0)
            ci.cached_index = 0
            return Float32(_control_value(ci, 0))
        end
        if isnan(t1)
            ci.cached_index = 2
            return Float32(_control_value(ci, 1))
        end
    end
    valid || (ci.cached_index = i1)
    weight1 = (t - t0) / (t1 - t0)
    weight0 = 1 - weight1
    return Float32(_control_value(ci, i1 - 1) * weight0 + _control_value(ci, i1) * weight1)
end

# ---- Multi-action mixer: action update (AnimationAction._update) -----------

# Sample a track at the action's clip time into the incoming region of each
# binding it drives.
function _action_sample!(tr::Union{KeyframeTrack,CubicSplineKeyframeTrack},
                         action::_MixerAction)
    v = _mixer_track_value(tr, action)
    @inbounds for b in action.track_bindings[action.track_index]
        buf = b.buffer
        buf[1] = v.x
        buf[2] = v.y
        buf[3] = v.z
    end
    return nothing
end

function _action_sample!(tr::NumberKeyframeTrack, action::_MixerAction)
    v = Float64(_mixer_track_value(tr, action))
    @inbounds for b in action.track_bindings[action.track_index]
        b.buffer[1] = v
    end
    return nothing
end

function _action_sample!(tr::Union{QuaternionKeyframeTrack,CubicSplineQuaternionKeyframeTrack},
                         action::_MixerAction)
    q = _track_value(tr, action.sample_time)
    @inbounds for b in action.track_bindings[action.track_index]
        buf = b.buffer
        buf[1] = q.x
        buf[2] = q.y
        buf[3] = q.z
        buf[4] = q.w
    end
    return nothing
end

function _action_sample!(tr::_MorphWeightsTrack, action::_MixerAction)
    out = action.vector_samples[action.track_index]
    _sample_morph_weights!(out, tr, action.sample_time)
    @inbounds for b in action.track_bindings[action.track_index]
        copyto!(b.buffer, 1, out, 1, length(out))
    end
    return nothing
end

# AnimationAction._updateWeight.
function _action_update_weight!(action::_MixerAction, time::Float64)
    weight = 0.0
    if action.enabled
        weight = action.weight
        ci = action.weight_interpolant
        if ci !== nothing
            value = Float64(_control_evaluate(ci, time))
            weight *= value
            if time > ci.t1
                _action_stop_fading!(action)
                value == 0 && (action.enabled = false)
            end
        end
    end
    action.effective_weight = weight
    return weight
end

# AnimationAction._updateTimeScale.
function _action_update_time_scale!(action::_MixerAction, time::Float64)
    time_scale = 0.0
    if !action.paused
        time_scale = action.time_scale
        ci = action.time_scale_interpolant
        if ci !== nothing
            time_scale *= Float64(_control_evaluate(ci, time))
            if time > ci.t1
                if time_scale == 0
                    action.paused = true
                else
                    restore = action.restore_time_scale
                    restore === nothing || (time_scale = restore)
                    action.time_scale = time_scale
                end
                _action_stop_warping!(action)
            end
        end
    end
    action.effective_time_scale = time_scale
    return time_scale
end

function _action_update!(action::_MixerAction, time::Float64, delta::Float64,
                         direction::Float64, accu_index::Int)
    if !action.enabled
        _action_update_weight!(action, time)
        return nothing
    end
    start_time = action.start_time
    if start_time !== nothing
        running = (time - start_time) * direction
        if running < 0 || direction == 0
            delta = 0.0
        else
            action.start_time = nothing
            delta = direction * running
        end
    end
    delta *= _action_update_time_scale!(action, time)
    clip_time = _update_action_time!(action, delta)
    weight = _action_update_weight!(action, time)
    if weight > 0
        action.sample_time = clip_time
        additive = action.blend_mode === :additive
        tracks = action.clip.tracks
        for j in eachindex(tracks)
            action.track_index = j
            _action_sample!(tracks[j], action)
            for b in action.track_bindings[j]
                if additive
                    _binding_accumulate_additive!(b, weight)
                else
                    _binding_accumulate!(b, accu_index, weight)
                end
            end
        end
    end
    return nothing
end

@noinline _throw_action_setting(name::String) =
    throw(ArgumentError("AnimationAction $name must be finite"))

# Settings a caller may have changed between updates, checked before an
# update changes anything.
function _validate_action_settings(action::_MixerAction)
    _animation_loop_mode(action.loop)
    _animation_blend_mode(action.blend_mode)
    isfinite(action.weight) || _throw_action_setting("weight")
    isfinite(action.time_scale) || _throw_action_setting("time_scale")
    isfinite(action.time) || _throw_action_setting("time")
    start_time = action.start_time
    start_time === nothing || isfinite(start_time) || _throw_action_setting("start time")
    return nothing
end

function _mixer_actions_step!(mixer::AnimationActionMixer, delta::Float64)
    for i in 1:mixer.n_active_actions
        _validate_action_settings(mixer.actions[i])
    end
    time = _checked_control_scalar(mixer.time + delta, "AnimationActionMixer updated time")
    mixer.time = time
    direction = sign(delta)
    accu_index = mixer.accu_index = xor(mixer.accu_index, 1)
    actions = mixer.actions
    for i in 1:mixer.n_active_actions
        _action_update!(actions[i], time, delta, direction, accu_index)
    end
    bindings = mixer.bindings
    for i in 1:mixer.n_active_bindings
        _binding_apply!(bindings[i], accu_index)
    end
    return mixer
end

# ---- Multi-action mixer: public API ----------------------------------------

"""
    mixer_update!(mixer::AnimationActionMixer, dt) -> mixer

Advance the mixer time by `dt * mixer.time_scale`, step every playing
action by that amount (scaled by its own time scale and warp, delayed by
`action_start_at!`), evaluate fades, and write the blended value of every
animated property that changed (three.js `AnimationMixer.update`).
"""
function mixer_update!(mixer::AnimationActionMixer, dt)
    delta = _checked_control_scalar(dt, "mixer_update!: dt")
    time_scale = _validated_animation_time_scale(mixer.time_scale)
    scaled = _checked_control_scalar(delta * time_scale, "AnimationActionMixer scaled delta")
    _checked_control_scalar(mixer.time, "AnimationActionMixer current time")
    return _mixer_actions_step!(mixer, scaled)
end

"""
    mixer_set_time!(mixer::AnimationActionMixer, t) -> mixer

Set the mixer time and the time of every action to 0, then update by `t`
(three.js `AnimationMixer.setTime`; `t` is scaled by `mixer.time_scale`).
Loop counts, fades and warps are kept.
"""
function mixer_set_time!(mixer::AnimationActionMixer, t)
    delta = _checked_control_scalar(t, "mixer_set_time!: time")
    time_scale = _validated_animation_time_scale(mixer.time_scale)
    scaled = _checked_control_scalar(delta * time_scale, "AnimationActionMixer scaled delta")
    for i in 1:mixer.n_active_actions
        _validate_action_settings(mixer.actions[i])
    end
    mixer.time = 0.0
    for action in mixer.actions
        action.time = 0.0
    end
    return _mixer_actions_step!(mixer, scaled)
end

"""
    mixer_clip_action(mixer, clip; blend_mode=clip.blend_mode) -> AnimationAction

The action that plays `clip` on `mixer` (three.js `AnimationMixer.clipAction`):
the clip's existing action when its blend mode is `blend_mode`, otherwise a
new, stopped action. A new action takes `loop`, `repetitions`,
`clamp_when_finished` and `time_scale` from the clip; start it with
[`action_play!`](@ref). Throws `ArgumentError` when a track's property cannot
be read or written by the mixer.
"""
function mixer_clip_action(mixer::AnimationActionMixer, clip::AnimationClip;
                           blend_mode::Symbol=clip.blend_mode)
    mode = _animation_blend_mode(blend_mode)
    k = findfirst(c -> c === clip, mixer.clips)
    if k !== nothing
        existing = mixer.clip_actions[k]
        existing.blend_mode === mode && return existing
    end
    track_bindings = _bind_action_tracks!(mixer, clip)
    n = length(clip.tracks)
    flat = _AnimationBinding[]
    for bound in track_bindings
        append!(flat, bound)
    end
    action = _MixerAction(mixer, clip, mode, clip.loop, clip.repetitions,
                          clip.clamp_when_finished, true, true, 0.0, clip.time_scale, 1.0,
                          true, false, clip.time_scale, 1.0, -1, nothing, nothing,
                          nothing, nothing, 0,
                          # AnimationAction's interpolant settings start at
                          # ZeroCurvatureEnding until its first time step.
                          :zero_curvature, :zero_curvature, 0.0, 0, zeros(Int, n),
                          fill(:zero_curvature, n), fill(:zero_curvature, n),
                          track_bindings, flat, [Float64[] for _ in 1:n])
    push!(mixer.actions, action)
    action.cache_index = length(mixer.actions)
    if k === nothing
        push!(mixer.clips, clip)
        push!(mixer.clip_actions, action)
    else
        mixer.clip_actions[k] = action
    end
    return action
end

"""
    mixer_existing_action(mixer, clip) -> Union{AnimationAction,Nothing}

The latest action `mixer_clip_action` made for `clip` on `mixer`, or
`nothing` (three.js `AnimationMixer.existingAction`).
"""
function mixer_existing_action(mixer::AnimationActionMixer, clip::AnimationClip)
    k = findfirst(c -> c === clip, mixer.clips)
    return k === nothing ? nothing : mixer.clip_actions[k]
end

"""
    mixer_stop_all_action!(mixer) -> mixer

Stop every playing action of `mixer` (three.js `AnimationMixer.stopAllAction`).
"""
function mixer_stop_all_action!(mixer::AnimationActionMixer)
    for i in mixer.n_active_actions:-1:1
        action_stop!(mixer.actions[i])
    end
    return mixer
end

"""
    action_play!(action) -> action

Schedule `action` on its mixer (three.js `AnimationAction.play`). Properties
no other playing action animates save their current value as the original.
Playing a playing action does nothing.
"""
function action_play!(action::_MixerAction)
    _is_active_action(action) && return action
    mixer = action.mixer
    # Read every new original before changing any state, so a property that
    # became unreadable leaves the mixer as it was.
    for b in action.bindings
        b.use_count == 0 && _binding_save_original!(b)
    end
    for b in action.bindings
        b.use_count == 0 && _lend_binding!(mixer, b)
        b.use_count += 1
    end
    _lend_action!(mixer, action)
    return action
end

"""
    action_stop!(action) -> action

Unschedule `action` and reset it (three.js `AnimationAction.stop`). Properties
no other playing action animates get their original value back.
"""
function action_stop!(action::_MixerAction)
    if _is_active_action(action)
        mixer = action.mixer
        for b in action.bindings
            b.use_count -= 1
            if b.use_count == 0
                _binding_restore_original!(b)
                _take_back_binding!(mixer, b)
            end
        end
        _take_back_action!(mixer, action)
    end
    return action_reset!(action)
end

"""
    action_reset!(action) -> action

Restart `action` (three.js `AnimationAction.reset`): enabled, unpaused, time
0, loop count forgotten, scheduled start, fade and warp cancelled.
"""
function action_reset!(action::_MixerAction)
    action.paused = false
    action.enabled = true
    action.time = 0.0
    action.loop_count = -1
    action.start_time = nothing
    _action_stop_fading!(action)
    _action_stop_warping!(action)
    return action
end

"""
    action_is_running(action) -> Bool

Whether `action` is advancing (three.js `AnimationAction.isRunning`): playing,
enabled, not paused, nonzero `time_scale` and not waiting for its start time.
"""
action_is_running(action::_MixerAction) =
    action.enabled && !action.paused && action.time_scale != 0 &&
    action.start_time === nothing && _is_active_action(action)

"""
    action_is_scheduled(action) -> Bool

Whether `action` is playing, that is played and not stopped (three.js
`AnimationAction.isScheduled`).
"""
action_is_scheduled(action::_MixerAction) = _is_active_action(action)

"""
    action_start_at!(action, mixer_time) -> action

Hold `action` until the mixer time reaches `mixer_time` (three.js
`AnimationAction.startAt`).
"""
function action_start_at!(action::_MixerAction, mixer_time::Real)
    action.start_time = _checked_control_scalar(mixer_time, "action_start_at! time")
    return action
end

"""
    action_set_loop!(action, loop[, repetitions]) -> action

Set the loop mode (`:repeat`, `:once` or `:pingpong`) and repetitions (`-1`,
the default, for unlimited) of `action` (three.js `AnimationAction.setLoop`).
"""
function action_set_loop!(action::_MixerAction, loop::Symbol, repetitions::Integer=-1)
    mode = _animation_loop_mode(loop)
    action.repetitions = _validated_animation_repetitions(repetitions)
    action.loop = mode
    return action
end

"""
    action_set_effective_weight!(action, weight) -> action

Set `action.weight` and its effective weight (0 while disabled), cancelling
a fade (three.js `AnimationAction.setEffectiveWeight`).
"""
function action_set_effective_weight!(action::_MixerAction, weight::Real)
    w = _checked_control_scalar(weight, "action_set_effective_weight! weight")
    action.weight = w
    action.effective_weight = action.enabled ? w : 0.0
    return _action_stop_fading!(action)
end

"""
    action_effective_weight(action) -> Float64

The weight `action` contributed in the last update, fades included (three.js
`AnimationAction.getEffectiveWeight`).
"""
action_effective_weight(action::_MixerAction) = action.effective_weight

"""
    action_set_effective_time_scale!(action, time_scale) -> action

Set `action.time_scale` and its effective time scale (0 while paused),
cancelling a warp (three.js `AnimationAction.setEffectiveTimeScale`).
"""
function action_set_effective_time_scale!(action::_MixerAction, time_scale::Real)
    s = _checked_control_scalar(time_scale, "action_set_effective_time_scale! time_scale")
    action.time_scale = s
    action.effective_time_scale = action.paused ? 0.0 : s
    return _action_stop_warping!(action)
end

"""
    action_effective_time_scale(action) -> Float64

The time scale `action` advanced with in the last update, warps included
(three.js `AnimationAction.getEffectiveTimeScale`).
"""
action_effective_time_scale(action::_MixerAction) = action.effective_time_scale

"""
    action_set_duration!(action, duration) -> action

Set `time_scale` so one loop of the clip lasts `duration` seconds, cancelling
a warp (three.js `AnimationAction.setDuration`).
"""
function action_set_duration!(action::_MixerAction, duration::Real)
    d = _checked_control_scalar(duration, "action_set_duration! duration")
    s = action.clip.duration / d
    isfinite(s) || throw(ArgumentError(
        "action_set_duration!: clip duration / duration must be finite"))
    action.time_scale = s
    return _action_stop_warping!(action)
end

"""
    action_sync_with!(action, other) -> action

Copy the time and time scale of `other` into `action`, cancelling a warp
(three.js `AnimationAction.syncWith`).
"""
function action_sync_with!(action::_MixerAction, other::_MixerAction)
    action.time = other.time
    action.time_scale = other.time_scale
    return _action_stop_warping!(action)
end

function _schedule_fading!(action::_MixerAction, duration::Real, weight_now::Float32,
                           weight_then::Float32, label::String)
    d = _checked_control_scalar(duration, label)
    mixer = action.mixer
    now = mixer.time
    ci = action.weight_interpolant
    if ci === nothing
        ci = _lend_control_interpolant!(mixer)
        action.weight_interpolant = ci
    end
    ci.t0 = Float32(now)
    ci.v0 = weight_now
    ci.t1 = Float32(now + d)
    ci.v1 = weight_then
    return action
end

"""
    action_fade_in!(action, duration) -> action

Ramp the weight factor of `action` from 0 to 1 over the next `duration`
seconds of mixer time (three.js `AnimationAction.fadeIn`).
"""
action_fade_in!(action::_MixerAction, duration::Real) =
    _schedule_fading!(action, duration, 0.0f0, 1.0f0, "action_fade_in! duration")

"""
    action_fade_out!(action, duration) -> action

Ramp the weight factor of `action` from 1 to 0 over the next `duration`
seconds of mixer time; at the end the action is disabled (three.js
`AnimationAction.fadeOut`).
"""
action_fade_out!(action::_MixerAction, duration::Real) =
    _schedule_fading!(action, duration, 1.0f0, 0.0f0, "action_fade_out! duration")

function _action_stop_fading!(action::_MixerAction)
    ci = action.weight_interpolant
    if ci !== nothing
        action.weight_interpolant = nothing
        _take_back_control_interpolant!(action.mixer, ci)
    end
    return action
end

"""
    action_stop_fading!(action) -> action

Cancel a fade of `action` (three.js `AnimationAction.stopFading`).
"""
action_stop_fading!(action::_MixerAction) = _action_stop_fading!(action)

function _action_stop_warping!(action::_MixerAction)
    ci = action.time_scale_interpolant
    if ci !== nothing
        action.time_scale_interpolant = nothing
        _take_back_control_interpolant!(action.mixer, ci)
    end
    action.restore_time_scale = nothing
    return action
end

"""
    action_stop_warping!(action) -> action

Cancel a warp of `action` (three.js `AnimationAction.stopWarping`).
"""
action_stop_warping!(action::_MixerAction) = _action_stop_warping!(action)

# The Float32 ramp values a warp from `start` to `stop` stores: the time
# scales relative to the action's `time_scale`.
function _warp_values(action::_MixerAction, start::Float64, stop::Float64)
    v0 = Float32(start / action.time_scale)
    v1 = Float32(stop / action.time_scale)
    (isfinite(v0) && isfinite(v1)) || throw(ArgumentError(
        "action warp: the time scales divided by time_scale = $(action.time_scale) " *
        "must be finite Float32 values"))
    return v0, v1
end

function _warp!(action::_MixerAction, v0::Float32, v1::Float32, duration::Float64)
    mixer = action.mixer
    now = mixer.time
    ci = action.time_scale_interpolant
    if ci === nothing
        ci = _lend_control_interpolant!(mixer)
        action.time_scale_interpolant = ci
    end
    ci.t0 = Float32(now)
    ci.t1 = Float32(now + duration)
    ci.v0 = v0
    ci.v1 = v1
    return action
end

"""
    action_warp!(action, start_time_scale, end_time_scale, duration) -> action

Ramp the time scale of `action` from `start_time_scale` to `end_time_scale`
over the next `duration` seconds of mixer time; at the end `time_scale`
becomes the final value, or the action pauses if that is 0 (three.js
`AnimationAction.warp`). The ramp is relative to the current `time_scale`,
which must not be 0.
"""
function action_warp!(action::_MixerAction, start_time_scale::Real,
                      end_time_scale::Real, duration::Real)
    start = _checked_control_scalar(start_time_scale, "action_warp! start_time_scale")
    stop = _checked_control_scalar(end_time_scale, "action_warp! end_time_scale")
    d = _checked_control_scalar(duration, "action_warp! duration")
    v0, v1 = _warp_values(action, start, stop)
    return _warp!(action, v0, v1, d)
end

"""
    action_halt!(action, duration) -> action

Slow `action` to a stop over `duration` seconds and pause it (three.js
`AnimationAction.halt`).
"""
action_halt!(action::_MixerAction, duration::Real) =
    action_warp!(action, action.effective_time_scale, 0.0, duration)

"""
    action_cross_fade_from!(action, fade_out_action, duration; warp=false) -> action

Fade `fade_out_action` out and `action` in over `duration` seconds (three.js
`AnimationAction.crossFadeFrom`). With `warp`, the time scales also ramp so
the two clips' durations meet: `fade_out_action` from 1 to the duration
ratio, `action` from the inverse ratio to 1, after which both get their
previous `time_scale` back.
"""
function action_cross_fade_from!(action::_MixerAction, fade_out_action::_MixerAction,
                                 duration::Real; warp::Bool=false)
    fade_out_action.mixer === action.mixer || throw(ArgumentError(
        "action_cross_fade_from!: both actions must belong to the same mixer"))
    d = _checked_control_scalar(duration, "action_cross_fade_from! duration")
    if warp
        fade_in_duration = action.clip.duration
        fade_out_duration = fade_out_action.clip.duration
        start_end_ratio = fade_out_duration / fade_in_duration
        end_start_ratio = fade_in_duration / fade_out_duration
        out_v0, out_v1 = _warp_values(fade_out_action, 1.0, start_end_ratio)
        in_v0, in_v1 = _warp_values(action, end_start_ratio, 1.0)
    end
    action_fade_out!(fade_out_action, d)
    action_fade_in!(action, d)
    if warp
        fade_out_action.restore_time_scale = fade_out_action.time_scale
        action.restore_time_scale = action.time_scale
        _warp!(fade_out_action, out_v0, out_v1, d)
        _warp!(action, in_v0, in_v1, d)
    end
    return action
end

"""
    action_cross_fade_to!(action, fade_in_action, duration; warp=false) -> action

Fade `action` out and `fade_in_action` in (three.js
`AnimationAction.crossFadeTo`); see [`action_cross_fade_from!`](@ref).
Returns `fade_in_action`, as three.js does.
"""
action_cross_fade_to!(action::_MixerAction, fade_in_action::_MixerAction, duration::Real;
                      warp::Bool=false) =
    action_cross_fade_from!(fade_in_action, action, duration; warp=warp)

function Base.show(io::IO, action::_MixerAction)
    print(io, "AnimationAction(", repr(action.clip.name), ", ", action.blend_mode,
          _is_active_action(action) ? ", playing" : ", stopped", ")")
end

function Base.show(io::IO, mixer::AnimationActionMixer)
    print(io, "AnimationActionMixer(time=", mixer.time, ", ", length(mixer.actions),
          " actions, ", mixer.n_active_actions, " playing)")
end

# ========================== Helpers ==========================
function _line_geo(positions::Vector{Float64})
    length(positions) % 3 == 0 ||
        throw(ArgumentError("helper line position length must be divisible by 3"))
    length(positions) <= _GEOMETRY_MAX_BUFFER_ELEMENTS ||
        throw(ArgumentError(
            "helper line position buffer exceeds the " *
            "$_GEOMETRY_MAX_BUFFER_ELEMENTS-element safety limit"))
    @inbounds for value in positions
        isfinite(value) ||
            throw(ArgumentError("helper line positions must be finite"))
    end
    return BufferGeometry(
        positions, Float64[], Float64[], Int[], length(positions) ÷ 3, 0)
end

function _helper_line_position_length(n_segments::Int, label::String)
    n_segments >= 0 || throw(ArgumentError("$label must be non-negative"))
    len = _geometry_checked_mul(6, n_segments, label, "position buffer")
    len <= _GEOMETRY_MAX_BUFFER_ELEMENTS ||
        throw(ArgumentError(
            "$label position buffer exceeds the " *
            "$_GEOMETRY_MAX_BUFFER_ELEMENTS-element safety limit"))
    return len
end

@inline function _write_line_vertex!(positions::Vector{Float64}, vi::Int, x, y, z)
    base = 3vi - 2
    positions[base] = x
    positions[base + 1] = y
    positions[base + 2] = z
    return nothing
end

@inline function _write_line_segment!(positions::Vector{Float64}, vi::Int,
                                      a::Vec3, b::Vec3)
    _write_line_vertex!(positions, vi, a.x, a.y, a.z)
    _write_line_vertex!(positions, vi + 1, b.x, b.y, b.z)
    return vi + 2
end

@inline function _write_line_color!(colors::Vector{Float64}, vi::Int, c::Color3)
    base = 3vi - 2
    colors[base] = c.r
    colors[base + 1] = c.g
    colors[base + 2] = c.b
    return nothing
end

"""
Diff3D line segments along +x (red), +y (green), +z (blue). As in three.js
`AxesHelper`, each axis fades from its pure colour at the origin to a lighter
tint at its tip (`:color` attribute).
"""
function AxesHelper(size=1.0)
    size = _geometry_finite_float(size, "AxesHelper size")
    pos = Float64[0,0,0, size,0,0,  0,0,0, 0,size,0,  0,0,0, 0,0,size]
    geo = _line_geo(pos)
    # three.js AxesHelper.js colors array.
    set_attribute!(geo, :color, Float64[1,0,0, 1,0.6,0,  0,1,0, 0.6,1,0,  0,0,1, 0,0.6,1], 3)
    LineSegments(geo, LineBasicMaterial(color=Color3(1.0,1.0,1.0)); name="AxesHelper")
end

# three.js `new Color(hex)` in the linear working space (Color.setHex with
# ColorManagement converting from sRGB).
_helper_hex_color(hex::Integer) = Color3(srgb_to_linear(((hex >> 16) & 0xff) / 255),
                                         srgb_to_linear(((hex >> 8) & 0xff) / 255),
                                         srgb_to_linear((hex & 0xff) / 255))

# GridHelper.js / PolarGridHelper.js default colours 0x444444 and 0x888888.
const _HELPER_GRID_COLOR1 = _helper_hex_color(0x444444)
const _HELPER_GRID_COLOR2 = _helper_hex_color(0x888888)

# Line material and per-vertex colours of a helper: three.js helpers draw
# with `vertexColors` and a white material; an explicit `color` instead
# draws every line in that one colour.
function _helper_line_object(T, pos::Vector{Float64}, colors::Vector{Float64}, color,
                             name::String; depth_test::Bool=true)
    geo = _line_geo(pos)
    if color === nothing
        set_attribute!(geo, :color, colors, 3)
        color = Color3(1.0, 1.0, 1.0)
    end
    return T(geo, LineBasicMaterial(color=color, depth_test=depth_test,
                                    depth_write=depth_test); name=name)
end

"""
    GridHelper(size=10.0, divisions=10; color=nothing,
               color1=<0x444444>, color2=<0x888888>)

A `divisions`×`divisions` grid of size `size` on the xz-plane, with the
vertex order of three.js `GridHelper`: for each offset `k` from `-size/2`, a
line parallel to x and then one parallel to z. As in three.js the centre
lines (present when `divisions` is even) take `color1` and the others
`color2`, as a per-vertex `:color` attribute; the defaults are three.js's
`0x444444` and `0x888888` in the linear working space. Passing `color`
draws every line in that colour instead.
"""
function GridHelper(size=10.0, divisions=10; color=nothing,
                    color1=_HELPER_GRID_COLOR1, color2=_HELPER_GRID_COLOR2)
    size = _geometry_finite_float(size, "GridHelper size")
    color1 = _validated_material_color(color1, :color1)
    color2 = _validated_material_color(color2, :color2)
    divisions = _clamp_seg(divisions, 1)   # divisions=0 would make step=Inf -> NaN vertices
    lines = _geometry_checked_mul(
        2, _geometry_checked_add(divisions, 1, "GridHelper line count"),
        "GridHelper line count")
    len = _helper_line_position_length(lines, "GridHelper")
    pos = Vector{Float64}(undef, len)
    colors = Vector{Float64}(undef, color === nothing ? len : 0)
    step = size / divisions; half = size / 2
    center = divisions / 2
    vi = 1
    k = -half
    # GridHelper.js: `k` advances by `k += step`, not `-half + i*step`.
    for i in 0:divisions
        _write_line_vertex!(pos, vi, -half, 0.0, k)
        _write_line_vertex!(pos, vi + 1, half, 0.0, k)      # parallel to x
        _write_line_vertex!(pos, vi + 2, k, 0.0, -half)
        _write_line_vertex!(pos, vi + 3, k, 0.0, half)      # parallel to z
        if color === nothing
            c = i == center ? color1 : color2
            for j in 0:3
                _write_line_color!(colors, vi + j, c)
            end
        end
        vi += 4
        k += step
    end
    _helper_line_object(LineSegments, pos, colors, color, "GridHelper")
end

function _box_edge_positions(c1::Vec3, c2::Vec3, c3::Vec3, c4::Vec3,
                             c5::Vec3, c6::Vec3, c7::Vec3, c8::Vec3)
    pos = Vector{Float64}(undef, 72)
    vi = 1
    vi = _write_line_segment!(pos, vi, c1, c2)
    vi = _write_line_segment!(pos, vi, c2, c3)
    vi = _write_line_segment!(pos, vi, c3, c4)
    vi = _write_line_segment!(pos, vi, c4, c1)
    vi = _write_line_segment!(pos, vi, c5, c6)
    vi = _write_line_segment!(pos, vi, c6, c7)
    vi = _write_line_segment!(pos, vi, c7, c8)
    vi = _write_line_segment!(pos, vi, c8, c5)
    vi = _write_line_segment!(pos, vi, c1, c5)
    vi = _write_line_segment!(pos, vi, c2, c6)
    vi = _write_line_segment!(pos, vi, c3, c7)
    _write_line_segment!(pos, vi, c4, c8)
    return pos
end

# 12 edges of an axis-aligned box given as min/max corners.
function _box_edges(mn::Vec3, mx::Vec3)
    return _box_edge_positions(
        Vec3(mn.x,mn.y,mn.z), Vec3(mx.x,mn.y,mn.z),
        Vec3(mx.x,mx.y,mn.z), Vec3(mn.x,mx.y,mn.z),
        Vec3(mn.x,mn.y,mx.z), Vec3(mx.x,mn.y,mx.z),
        Vec3(mx.x,mx.y,mx.z), Vec3(mn.x,mx.y,mx.z),
    )
end

function _box_expand_by_transformed_box(box::Box3, local_box::Box3, m::Mat4)
    mn = local_box.min
    mx = local_box.max
    for x in (mn.x, mx.x), y in (mn.y, mx.y), z in (mn.z, mx.z)
        box = box3_expand_by_point(box, mat4_transform_point(m, Vec3(x, y, z)))
    end
    return box
end

# three.js Box3.expandByObject (precise = false): geometry bounds of the object
# and its descendants, each transformed by its world matrix; instanced meshes
# use the union of their instance bounds.
function _box_expand_by_object(box::Box3, obj::AbstractObject3D)
    geometry = hasproperty(obj, :geometry) ? getproperty(obj, :geometry) : nothing
    if geometry isa BufferGeometry && geometry.n_vertices > 0
        local_box = compute_bounding_box(geometry)
        world = compute_world_matrix(obj)::Mat4{Float64}
        if obj isa InstancedMesh
            for m in obj.instance_matrices
                box = _box_expand_by_transformed_box(box, local_box, world * m)
            end
        else
            box = _box_expand_by_transformed_box(box, local_box, world)
        end
    end
    for child in get_children(obj)
        box = _box_expand_by_object(box, child)
    end
    return box
end

"""
Wireframe of the world-space axis-aligned bounding box of `obj` and its
descendants (three.js `BoxHelper`); the helper itself needs no transform.
"""
function BoxHelper(obj::AbstractObject3D; color=Color3(1.0,1.0,0.0))
    box = _box_expand_by_object(Box3(), obj)
    box.min.x <= box.max.x && box.min.y <= box.max.y && box.min.z <= box.max.z ||
        throw(ArgumentError("BoxHelper object has no geometry to bound"))
    LineSegments(_line_geo(_box_edges(box.min, box.max)), LineBasicMaterial(color=color); name="BoxHelper")
end

# CameraHelper.js setColors defaults: frustum, cone, up, target and cross.
const _CAMERA_HELPER_FRUSTUM_COLOR = _helper_hex_color(0xffaa00)
const _CAMERA_HELPER_CONE_COLOR = _helper_hex_color(0xff0000)
const _CAMERA_HELPER_UP_COLOR = _helper_hex_color(0x00aaff)
const _CAMERA_HELPER_TARGET_COLOR = _helper_hex_color(0xffffff)
const _CAMERA_HELPER_CROSS_COLOR = _helper_hex_color(0x333333)

# CameraHelper.js line list: point ids of each segment, in vertex order.
const _CAMERA_HELPER_LINES = (
    (:n1, :n2), (:n2, :n4), (:n4, :n3), (:n3, :n1),          # near
    (:f1, :f2), (:f2, :f4), (:f4, :f3), (:f3, :f1),          # far
    (:n1, :f1), (:n2, :f2), (:n3, :f3), (:n4, :f4),          # sides
    (:p, :n1), (:p, :n2), (:p, :n3), (:p, :n4),              # cone
    (:u1, :u2), (:u2, :u3), (:u3, :u1),                      # up
    (:c, :t), (:p, :c),                                      # target
    (:cn1, :cn2), (:cn3, :cn4), (:cf1, :cf2), (:cf3, :cf4))  # cross

# CameraHelper.js update(): normalized device coordinates of each point
# (near z = -1, far z = 1); `p` is the camera origin.
function _camera_helper_ndc(id::Symbol)
    id === :c && return (0.0, 0.0, -1.0)
    id === :t && return (0.0, 0.0, 1.0)
    id === :n1 && return (-1.0, -1.0, -1.0)
    id === :n2 && return (1.0, -1.0, -1.0)
    id === :n3 && return (-1.0, 1.0, -1.0)
    id === :n4 && return (1.0, 1.0, -1.0)
    id === :f1 && return (-1.0, -1.0, 1.0)
    id === :f2 && return (1.0, -1.0, 1.0)
    id === :f3 && return (-1.0, 1.0, 1.0)
    id === :f4 && return (1.0, 1.0, 1.0)
    id === :u1 && return (0.7, 1.1, -1.0)
    id === :u2 && return (-0.7, 1.1, -1.0)
    id === :u3 && return (0.0, 2.0, -1.0)
    id === :cf1 && return (-1.0, 0.0, 1.0)
    id === :cf2 && return (1.0, 0.0, 1.0)
    id === :cf3 && return (0.0, -1.0, 1.0)
    id === :cf4 && return (0.0, 1.0, 1.0)
    id === :cn1 && return (-1.0, 0.0, -1.0)
    id === :cn2 && return (1.0, 0.0, -1.0)
    id === :cn3 && return (0.0, -1.0, -1.0)
    return (0.0, 1.0, -1.0)                                  # :cn4
end

"""
    CameraHelper(camera; color=Color3(1,1,1), style=:box,
                 frustum_color=<0xffaa00>, cone_color=<0xff0000>,
                 up_color=<0x00aaff>, target_color=<0xffffff>,
                 cross_color=<0x333333>)

Wireframe of a camera's view volume in world space, from its inverse
view and projection. The default `style=:box` draws Diff3D's 12 frustum
edges in `color`. `style=:threejs` draws the 25 segments of three.js
`CameraHelper` in its vertex order: near and far rectangles, side edges, the
cone from the camera to the near corners, the up triangle, the centre line
and the near/far crosses, with three.js's per-vertex `:color`s (the `*_color`
keywords, three.js `setColors`, in the linear working space) multiplied by the
material `color`.
"""
function CameraHelper(camera::AbstractCamera; color=Color3(1.0,1.0,1.0),
                      style::Symbol=:box,
                      frustum_color=_CAMERA_HELPER_FRUSTUM_COLOR,
                      cone_color=_CAMERA_HELPER_CONE_COLOR,
                      up_color=_CAMERA_HELPER_UP_COLOR,
                      target_color=_CAMERA_HELPER_TARGET_COLOR,
                      cross_color=_CAMERA_HELPER_CROSS_COLOR)
    style === :box || style === :threejs ||
        throw(ArgumentError("CameraHelper style must be :box or :threejs"))
    style === :threejs && return _camera_helper_threejs(
        camera, color, frustum_color, cone_color, up_color, target_color,
        cross_color)
    inv = mat4_inverse(projection_matrix(camera) * view_matrix(camera))
    corner(x,y,z) = mat4_transform_point(inv, Vec3(x,y,z))
    pos = _box_edge_positions(
        corner(-1,-1,-1), corner(1,-1,-1),
        corner(1,1,-1), corner(-1,1,-1),
        corner(-1,-1, 1), corner(1,-1, 1),
        corner(1,1, 1), corner(-1,1, 1),
    )
    all(isfinite, pos) || throw(ArgumentError(
        "CameraHelper requires a camera with a finite, invertible frustum"))
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="CameraHelper")
end

function _camera_helper_threejs(camera::AbstractCamera, color, frustum_color,
                                cone_color, up_color, target_color, cross_color)
    palette = (frustum=_validated_material_color(frustum_color, :frustum_color),
               cone=_validated_material_color(cone_color, :cone_color),
               up=_validated_material_color(up_color, :up_color),
               target=_validated_material_color(target_color, :target_color),
               cross=_validated_material_color(cross_color, :cross_color))
    # Vector3.unproject: projection inverse, then the camera's world matrix.
    inverse_projection = mat4_inverse(projection_matrix(camera))
    inverse_view = mat4_inverse(view_matrix(camera))
    point(id) = id === :p ? mat4_transform_point(inverse_view, Vec3(0.0, 0.0, 0.0)) :
        mat4_transform_point(inverse_view, mat4_transform_point(
            inverse_projection, Vec3(_camera_helper_ndc(id)...)))
    n = 2 * length(_CAMERA_HELPER_LINES)
    pos = Vector{Float64}(undef, 3n)
    colors = Vector{Float64}(undef, 3n)
    vi = 1
    for (k, (a, b)) in enumerate(_CAMERA_HELPER_LINES)
        # CameraHelper.js setColors: segments 1-12 frustum, 13-16 cone,
        # 17-19 up, 20 target, 21-25 cross (the `p`-`c` line included).
        c = k <= 12 ? palette.frustum : k <= 16 ? palette.cone :
            k <= 19 ? palette.up : k == 20 ? palette.target : palette.cross
        _write_line_color!(colors, vi, c)
        _write_line_color!(colors, vi + 1, c)
        vi = _write_line_segment!(pos, vi, point(a), point(b))
    end
    all(isfinite, pos) || throw(ArgumentError(
        "CameraHelper requires a camera with a finite, invertible frustum"))
    geo = _line_geo(pos)
    set_attribute!(geo, :color, colors, 3)
    return LineSegments(geo, LineBasicMaterial(color=color); name="CameraHelper")
end

# Translation (column 4) of a 4×4 transform.
@inline _mat4_translation_vec(m::Mat4) =
    Vec3(mat4_get(m, 1, 4), mat4_get(m, 2, 4), mat4_get(m, 3, 4))

# World matrix of a helper part placed at the origin of `parent` (a light's
# world matrix) and turned by three.js `Object3D.lookAt(target)`
# (Object3D.js lookAt): Matrix4.lookAt(target, position, up) gives the world
# rotation, which is made relative to the parent's rotation
# (Matrix4.extractRotation), so the parent's scale still applies.
function _helper_look_at_world(parent::Mat4, target::Vec3)
    position = _mat4_translation_vec(parent)
    v = mat4_look_at(target, position, Vec3(0.0, 1.0, 0.0)).e
    # mat4_look_at returns the transposed (view) rotation: its rows are the
    # x, y and z axes of the rotation three.js builds.
    look = Mat4{Float64}((v[1], v[5], v[9], 0.0,
                          v[2], v[6], v[10], 0.0,
                          v[3], v[7], v[11], 0.0,
                          0.0, 0.0, 0.0, 1.0))
    s1 = _mat4_linear_column_norm(parent, 1)
    s2 = _mat4_linear_column_norm(parent, 2)
    s3 = _mat4_linear_column_norm(parent, 3)
    m(r, c) = mat4_get(parent, r, c)
    inverse_rotation = Mat4{Float64}((m(1, 1) / s1, m(1, 2) / s2, m(1, 3) / s3, 0.0,
                                      m(2, 1) / s1, m(2, 2) / s2, m(2, 3) / s3, 0.0,
                                      m(3, 1) / s1, m(3, 2) / s2, m(3, 3) / s3, 0.0,
                                      0.0, 0.0, 0.0, 1.0))
    return parent * inverse_rotation * look
end

"""
    DirectionalLightHelper(light::DirectionalLight, size=1.0; color=light.color)

Wireframe of three.js `DirectionalLightHelper`: a square of half-width
`size` at the light, facing its target, and a line from the light to the
target. Both follow the light's world matrix (so a scaled light scales them)
and are turned toward the target like `Object3D.lookAt`.
"""
function DirectionalLightHelper(light::DirectionalLight, size=1.0; color=light.color)
    size = _geometry_finite_float(size, "DirectionalLightHelper size")
    parent = compute_world_matrix(light)::Mat4{Float64}
    target = _light_world_target(light)
    world = _helper_look_at_world(parent, target)
    s = size
    pos = Vector{Float64}(undef, 30)
    vi = 1
    # DirectionalLightHelper.js lightPlane: a Line through these five points.
    corners = ((-s, s), (s, s), (s, -s), (-s, -s), (-s, s))
    for k in 1:4
        a = mat4_transform_point(world, Vec3(corners[k][1], corners[k][2], 0.0))
        b = mat4_transform_point(world, Vec3(corners[k + 1][1], corners[k + 1][2], 0.0))
        vi = _write_line_segment!(pos, vi, a, b)
    end
    # targetLine: (0,0,0)-(0,0,1) with scale.z = |target - light|.
    distance = norm(target - _mat4_translation_vec(parent))
    _write_line_segment!(pos, vi, mat4_transform_point(world, Vec3(0.0, 0.0, 0.0)),
                         mat4_transform_point(world, Vec3(0.0, 0.0, distance)))
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color);
                 name="DirectionalLightHelper")
end

@inline function _write_triangle_edges!(pos::Vector{Float64}, vi::Int, a::Vec3, b::Vec3, c::Vec3)
    vi = _write_line_segment!(pos, vi, a, b)
    vi = _write_line_segment!(pos, vi, b, c)
    return _write_line_segment!(pos, vi, c, a)
end

"""
    PointLightHelper(light::PointLight, size=1.0; color=light.color)

three.js `PointLightHelper`: the wireframe of `SphereGeometry(size, 4, 2)`
(an octahedron) placed by the light's world matrix, drawn as the three edges
of each of its eight triangles like a `wireframe` mesh.
"""
function PointLightHelper(light::PointLight, size=1.0; color=light.color)
    size = _geometry_finite_float(size, "PointLightHelper size")
    world = compute_world_matrix(light)::Mat4{Float64}
    # SphereGeometry.js vertex grid for widthSegments 4, heightSegments 2.
    grid = ntuple(Val(3)) do row
        v = (row - 1) / 2
        ntuple(Val(5)) do column
            u = (column - 1) / 4
            mat4_transform_point(world, Vec3(-size * cos(u * (2π)) * sin(v * π),
                                             size * cos(v * π),
                                             size * sin(u * (2π)) * sin(v * π)))
        end
    end
    pos = Vector{Float64}(undef, 144)
    vi = 1
    # SphereGeometry.js indices: the top row keeps only (b, c, d) and the
    # bottom row only (a, b, d).
    for iy in 1:2, ix in 1:4
        a = grid[iy][ix + 1]; b = grid[iy][ix]
        c = grid[iy + 1][ix]; d = grid[iy + 1][ix + 1]
        iy != 1 && (vi = _write_triangle_edges!(pos, vi, a, b, d))
        iy != 2 && (vi = _write_triangle_edges!(pos, vi, b, c, d))
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="PointLightHelper")
end

"""
    SpotLightHelper(light::SpotLight; color=light.color, segments=32)

three.js `SpotLightHelper`: five lines from the light to `(0,0,1)`,
`(±1,0,1)` and `(0,±1,1)` and a `segments`-chord circle of radius 1 at
`z = 1` (three.js uses 32), scaled to the cone width
`length * tan(light.angle)` and length `light.distance` (1000 when the
distance is 0), turned toward the target and placed by the light's world
matrix.
"""
function SpotLightHelper(light::SpotLight; color=light.color, segments::Int=32)
    segments = _geometry_nonnegative_int(segments, "SpotLightHelper segments")
    total_segments = _geometry_checked_add(
        segments, 5, "SpotLightHelper segment count")
    pos = Vector{Float64}(
        undef, _helper_line_position_length(
            total_segments, "SpotLightHelper"))
    parent = compute_world_matrix(light)::Mat4{Float64}
    world = _helper_look_at_world(parent, _light_world_target(light))
    cone_length = light.distance != 0 ? light.distance : 1000.0
    cone_width = cone_length * tan(light.angle)
    cone(x, y, z) = mat4_transform_point(
        world, Vec3(x * cone_width, y * cone_width, z * cone_length))
    apex = cone(0.0, 0.0, 0.0)
    vi = 1
    for (x, y) in ((0.0, 0.0), (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0))
        vi = _write_line_segment!(pos, vi, apex, cone(x, y, 1.0))
    end
    for i in 0:segments-1
        p1 = (i / segments) * π * 2
        p2 = ((i + 1) / segments) * π * 2
        vi = _write_line_segment!(pos, vi, cone(cos(p1), sin(p1), 1.0),
                                  cone(cos(p2), sin(p2), 1.0))
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="SpotLightHelper")
end

# OctahedronGeometry (PolyhedronGeometry with detail 0) emits each face
# (a, b, c) of these indices as (b, c, a).
const _OCTAHEDRON_VERTICES = ((1.0, 0.0, 0.0), (-1.0, 0.0, 0.0), (0.0, 1.0, 0.0),
                              (0.0, -1.0, 0.0), (0.0, 0.0, 1.0), (0.0, 0.0, -1.0))
const _OCTAHEDRON_FACES = ((1, 3, 5), (1, 5, 4), (1, 4, 6), (1, 6, 3),
                           (2, 3, 6), (2, 6, 4), (2, 4, 5), (2, 5, 3))

"""
    HemisphereLightHelper(light::HemisphereLight, size=1.0; color=nothing)

three.js `HemisphereLightHelper`: the wireframe of `OctahedronGeometry(size)`
turned by `rotateY(π/2)`, placed by the light's world matrix and turned to
look at the negated light position, drawn as the three edges of each of its
eight triangles. Without `color`, the first four faces take the sky colour
and the last four the ground colour as a per-vertex `:color` attribute;
`color` draws every line in that one colour instead.
"""
function HemisphereLightHelper(light::HemisphereLight, size=1.0; color=nothing)
    size = _geometry_finite_float(size, "HemisphereLightHelper size")
    parent = compute_world_matrix(light)::Mat4{Float64}
    world = _helper_look_at_world(parent, -_mat4_translation_vec(parent))
    c, s = cos(π * 0.5), sin(π * 0.5)          # geometry.rotateY(Math.PI * 0.5)
    vertex(i) = begin
        x, y, z = _OCTAHEDRON_VERTICES[i]
        mat4_transform_point(world, Vec3((c * x + s * z) * size, y * size,
                                         (-s * x + c * z) * size))
    end
    pos = Vector{Float64}(undef, 144)
    colors = Vector{Float64}(undef, color === nothing ? 144 : 0)
    vi = 1
    for (f, (a, b, cc)) in enumerate(_OCTAHEDRON_FACES)
        first_vertex = vi
        vi = _write_triangle_edges!(pos, vi, vertex(b), vertex(cc), vertex(a))
        if color === nothing
            face_color = f <= 4 ? light.color : light.ground_color
            for j in first_vertex:vi-1
                _write_line_color!(colors, j, face_color)
            end
        end
    end
    _helper_line_object(LineSegments, pos, colors, color, "HemisphereLightHelper")
end

function _skeleton_world_matrix!(worlds::Vector{Mat4{Float64}}, computed::Vector{Bool},
                                 bone_index::Dict{UInt,Int}, bones::Vector{Bone},
                                 i::Int)::Mat4{Float64}
    computed[i] && return worlds[i]
    bone = bones[i]
    local_mat = compute_local_matrix(bone)
    parent = get_parent(bone)
    world = if parent isa Bone
        parent_i = get(bone_index, objectid(parent), 0)
        parent_i == 0 ? compute_world_matrix(parent) * local_mat :
                         _skeleton_world_matrix!(worlds, computed, bone_index, bones, parent_i) * local_mat
    elseif parent === nothing
        local_mat
    else
        compute_world_matrix(parent) * local_mat
    end
    worlds[i] = world
    computed[i] = true
    return world
end

"""
    SkeletonHelper(skeleton; color=nothing, color1=Color3(0,0,1), color2=Color3(0,1,0))

Line segments connecting each bone to its parent bone in world space
(three.js `SkeletonHelper`). Bones whose parent is not itself a bone in the
skeleton are skipped, matching three.js which only links bone-to-bone. As in
three.js each segment runs from the bone (`color1`, blue) to its parent
(`color2`, green) with per-vertex `:color`s, and the material neither tests
nor writes depth, so the skeleton draws over the mesh. Passing `color` draws
every segment in that one colour instead.
"""
function SkeletonHelper(skeleton::Skeleton; color=nothing,
                        color1=Color3(0.0, 0.0, 1.0), color2=Color3(0.0, 1.0, 0.0))
    color1 = _validated_material_color(color1, :color1)
    color2 = _validated_material_color(color2, :color2)
    bones = skeleton.bones
    n_bones = length(bones)
    pos = Vector{Float64}(
        undef, _helper_line_position_length(n_bones, "SkeletonHelper"))
    vi = 1
    if n_bones < 16
        boneids = Set{UInt}()
        sizehint!(boneids, n_bones)
        for bone in bones
            push!(boneids, objectid(bone))
        end
        for bone in bones
            par = get_parent(bone)
            (par isa Bone && objectid(par) in boneids) || continue
            cw = _mat4_translation_vec(compute_world_matrix(bone))
            pw = _mat4_translation_vec(compute_world_matrix(par))
            vi = _write_line_segment!(pos, vi, cw, pw)
        end
    else
        bone_index = Dict{UInt,Int}()
        sizehint!(bone_index, n_bones)
        for (i, bone) in pairs(bones)
            bone_index[objectid(bone)] = i
        end
        worlds = Vector{Mat4{Float64}}(undef, n_bones)
        computed = fill(false, n_bones)
        for (i, bone) in pairs(bones)
            par = get_parent(bone)
            par isa Bone || continue
            parent_i = get(bone_index, objectid(par), 0)
            parent_i == 0 && continue
            cw = _mat4_translation_vec(_skeleton_world_matrix!(worlds, computed, bone_index, bones, i))
            pw = _mat4_translation_vec(_skeleton_world_matrix!(worlds, computed, bone_index, bones, parent_i))
            vi = _write_line_segment!(pos, vi, cw, pw)
        end
    end
    resize!(pos, 3 * (vi - 1))
    colors = Vector{Float64}(undef, color === nothing ? length(pos) : 0)
    if color === nothing
        for j in 1:2:vi-1
            _write_line_color!(colors, j, color1)
            _write_line_color!(colors, j + 1, color2)
        end
    end
    _helper_line_object(LineSegments, pos, colors, color, "SkeletonHelper"; depth_test=false)
end

"""Build a `SkeletonHelper` from the skeleton owned by a `SkinnedMesh`."""
SkeletonHelper(mesh::SkinnedMesh; color=nothing,
               color1=Color3(0.0, 0.0, 1.0), color2=Color3(0.0, 1.0, 0.0)) =
    SkeletonHelper(mesh.skeleton; color=color, color1=color1, color2=color2)

"""
    PlaneHelper(plane::Plane, size=1.0; color=Color3(1,1,0), style=:box)

Square of side `size` lying in `plane` (`n·x + d = 0`, centred on its point
nearest the origin) in world space. The default `style=:box` draws Diff3D's
`LineSegments`: the square's outline plus a segment of length `size/2` along
the normal. `style=:threejs` returns three.js `PlaneHelper`: a `LineObject`
(line strip) through its eight points, turned like `Object3D.lookAt(normal)`
(including three.js's perturbation for a normal along ±y), and a child `Mesh` of the
two filled triangles in `color` with opacity 0.2, transparent and without
depth writes.
"""
function PlaneHelper(plane::Plane, size=1.0; color=Color3(1.0, 1.0, 0.0),
                     style::Symbol=:box)
    style === :box || style === :threejs ||
        throw(ArgumentError("PlaneHelper style must be :box or :threejs"))
    style === :threejs && return _plane_helper_threejs(plane, size, color)
    size = _geometry_finite_float(size, "PlaneHelper size")
    normal = plane.normal
    isfinite(normal.x) && isfinite(normal.y) && isfinite(normal.z) &&
        isfinite(plane.constant) ||
        throw(ArgumentError("PlaneHelper plane must be finite"))
    normal_scale = max(abs(normal.x), abs(normal.y), abs(normal.z))
    normal_scale > 0.0 ||
        throw(ArgumentError("PlaneHelper plane normal must be non-zero"))
    scaled_normal = normal / normal_scale
    scaled_length = norm(scaled_normal)
    n = scaled_normal / scaled_length
    distance = -(plane.constant / normal_scale) / scaled_length
    isfinite(distance) ||
        throw(ArgumentError(
            "PlaneHelper plane is too far from the origin to represent"))
    center = n * distance                 # closest point to the origin on n⋅x+d=0
    u, v = _perp_basis(n)
    h = size / 2
    c1 = center + (u *  h + v *  h)
    c2 = center + (u * -h + v *  h)
    c3 = center + (u * -h + v * -h)
    c4 = center + (u *  h + v * -h)
    pos = Vector{Float64}(undef, 30)
    vi = 1
    vi = _write_line_segment!(pos, vi, c1, c2)
    vi = _write_line_segment!(pos, vi, c2, c3)
    vi = _write_line_segment!(pos, vi, c3, c4)
    vi = _write_line_segment!(pos, vi, c4, c1)
    _write_line_segment!(pos, vi, center, center + n * h)
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="PlaneHelper")
end

# Unit normal and signed distance of `plane` from the origin (the plane is
# n·x + d = 0, so its point nearest the origin is unit_normal * distance).
function _plane_helper_frame(plane::Plane, label::String)
    normal = plane.normal
    isfinite(normal.x) && isfinite(normal.y) && isfinite(normal.z) &&
        isfinite(plane.constant) ||
        throw(ArgumentError("$label plane must be finite"))
    normal_scale = max(abs(normal.x), abs(normal.y), abs(normal.z))
    normal_scale > 0.0 ||
        throw(ArgumentError("$label plane normal must be non-zero"))
    scaled_normal = normal / normal_scale
    scaled_length = norm(scaled_normal)
    n = scaled_normal / scaled_length
    distance = -(plane.constant / normal_scale) / scaled_length
    isfinite(distance) ||
        throw(ArgumentError("$label plane is too far from the origin to represent"))
    return n, distance
end

# Triangle-mesh geometry from flat world positions, every vertex with `normal`.
function _helper_mesh_geo(positions::Vector{Float64}, normal::Vec3)
    n = length(positions) ÷ 3
    normals = Vector{Float64}(undef, 3n)
    for i in 1:n
        _write_line_vertex!(normals, i, normal.x, normal.y, normal.z)
    end
    return BufferGeometry(positions, normals, Float64[], collect(1:n), n, n ÷ 3)
end

# PlaneHelper.js positions (line strip) and positions2 (mesh triangles).
const _PLANE_HELPER_LINE = ((1.0, -1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, 1.0),
                            (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0), (1.0, 1.0))
const _PLANE_HELPER_FILL = ((1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0),
                            (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0))

function _plane_helper_threejs(plane::Plane, size, color)
    size = _geometry_finite_float(size, "PlaneHelper size")
    color = _validated_material_color(color, :color)
    n, distance = _plane_helper_frame(plane, "PlaneHelper")
    # PlaneHelper.updateMatrixWorld: scale (size/2, size/2, 1), lookAt(normal)
    # from the origin (Matrix4.lookAt(normal, origin, +y); its rows are the
    # helper's x, y and z axes), then translateZ(-constant) along the normal.
    view = mat4_look_at(n, Vec3(0.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0))
    x_axis = Vec3(mat4_get(view, 1, 1), mat4_get(view, 1, 2), mat4_get(view, 1, 3))
    y_axis = Vec3(mat4_get(view, 2, 1), mat4_get(view, 2, 2), mat4_get(view, 2, 3))
    z_axis = Vec3(mat4_get(view, 3, 1), mat4_get(view, 3, 2), mat4_get(view, 3, 3))
    center = z_axis * distance
    h = size / 2
    corner((u, v)) = center + x_axis * (u * h) + y_axis * (v * h)
    line_pos = Vector{Float64}(undef, 3 * length(_PLANE_HELPER_LINE))
    for (i, uv) in enumerate(_PLANE_HELPER_LINE)
        p = corner(uv)
        _write_line_vertex!(line_pos, i, p.x, p.y, p.z)
    end
    fill_pos = Vector{Float64}(undef, 3 * length(_PLANE_HELPER_FILL))
    for (i, uv) in enumerate(_PLANE_HELPER_FILL)
        p = corner(uv)
        _write_line_vertex!(fill_pos, i, p.x, p.y, p.z)
    end
    all(isfinite, line_pos) ||
        throw(ArgumentError("PlaneHelper size and plane must give finite points"))
    helper = LineObject(_line_geo(line_pos), LineBasicMaterial(color=color);
                        name="PlaneHelper")
    add!(helper, Mesh(_helper_mesh_geo(fill_pos, z_axis),
                      MeshBasicMaterial(color=color, opacity=0.2, transparent=true,
                                        depth_write=false);
                      name="PlaneHelperMesh"))
    return helper
end

"""
Polar grid on the xz-plane: `rings` concentric circles out to `radius` and
`sectors` evenly spaced radial spokes (three.js `PolarGridHelper`). Circles are
approximated by `circle_segments` chords each. As in three.js, spokes start on
+z and advance toward +x, a single sector draws no spoke, and rings are listed
from the outermost inward. Odd-numbered spokes and rings (counting from 0)
take `color1` and the others `color2`, as a per-vertex `:color` attribute
with three.js's defaults `0x444444` and `0x888888`; passing `color` draws
every line in that one colour instead.
"""
function PolarGridHelper(radius=10.0, sectors::Int=16, rings::Int=8;
                         circle_segments::Int=64, color=nothing,
                         color1=_HELPER_GRID_COLOR1, color2=_HELPER_GRID_COLOR2)
    radius = _geometry_finite_float(radius, "PolarGridHelper radius")
    color1 = _validated_material_color(color1, :color1)
    color2 = _validated_material_color(color2, :color2)
    sectors = _geometry_nonnegative_int(sectors, "PolarGridHelper sectors")
    rings = _geometry_nonnegative_int(rings, "PolarGridHelper rings")
    circle_segments = _geometry_nonnegative_int(
        circle_segments, "PolarGridHelper circle_segments")
    # PolarGridHelper.js only draws sectors when `sectors > 1`.
    spokes = sectors > 1 ? sectors : 0
    ring_segments = _geometry_checked_mul(
        rings, circle_segments, "PolarGridHelper segment count")
    n_segments = _geometry_checked_add(
        spokes, ring_segments, "PolarGridHelper segment count")
    len = _helper_line_position_length(n_segments, "PolarGridHelper")
    pos = Vector{Float64}(undef, len)
    colors = Vector{Float64}(undef, color === nothing ? len : 0)
    vi = 1
    # Radial spokes: angle v = (i / sectors) * 2pi, point (sin v, 0, cos v) * radius.
    for i in 0:spokes-1
        v = (i / sectors) * (2π)
        vi = _write_line_segment!(pos, vi, Vec3(0.0, 0.0, 0.0),
                                  Vec3(sin(v) * radius, 0.0, cos(v) * radius))
        if color === nothing
            c = isodd(i) ? color1 : color2
            _write_line_color!(colors, vi - 2, c)
            _write_line_color!(colors, vi - 1, c)
        end
    end
    # Rings from the outside in: r = radius - radius / rings * i.
    # Chord j ends where chord j + 1 starts (the same angle expression), so
    # each ring evaluates sin/cos once per vertex.
    for i in 0:rings-1
        r = radius - (radius / rings * i)
        previous = Vec3(sin(0.0) * r, 0.0, cos(0.0) * r)
        for j in 0:circle_segments-1
            v = ((j + 1) / circle_segments) * (2π)
            current = Vec3(sin(v) * r, 0.0, cos(v) * r)
            vi = _write_line_segment!(pos, vi, previous, current)
            previous = current
            if color === nothing
                c = isodd(i) ? color1 : color2
                _write_line_color!(colors, vi - 2, c)
                _write_line_color!(colors, vi - 1, c)
            end
        end
    end
    _helper_line_object(LineSegments, pos, colors, color, "PolarGridHelper")
end

"""
    Box3Helper(box::Box3; color=Color3(1.0, 1.0, 0.0))

Wireframe (12 edges) of an axis-aligned `Box3` in world space (three.js
`Box3Helper`). An empty box raises an `ArgumentError`.
"""
function Box3Helper(box::Box3; color=Color3(1.0, 1.0, 0.0))
    mn = box.min
    mx = box.max
    mn.x <= mx.x && mn.y <= mx.y && mn.z <= mx.z ||
        throw(ArgumentError("Box3Helper box must not be empty"))
    LineSegments(_line_geo(_box_edges(mn, mx)), LineBasicMaterial(color=color);
                 name="Box3Helper")
end

"""
    ArrowHelper(dir=Vec3(0,0,1), origin=Vec3(0,0,0), length=1.0;
                color=Color3(1,1,0), head_length=0.2length,
                head_width=0.2head_length)

Arrow from `origin` along `dir` (three.js `ArrowHelper`): a `Group` placed at
`origin` and rotated so its +y axis follows `dir`, holding a shaft `LineObject`
and a five-sided cone `Mesh` whose tip sits at distance `length`.
"""
function ArrowHelper(dir::Vec3=Vec3(0.0, 0.0, 1.0),
                     origin::Vec3=Vec3(0.0, 0.0, 0.0), length::Real=1.0;
                     color=Color3(1.0, 1.0, 0.0),
                     head_length::Real=0.2 * length,
                     head_width::Real=0.2 * head_length)
    d = _checked_control_vec3(dir, "ArrowHelper dir")
    scale = max(abs(d.x), abs(d.y), abs(d.z))
    scale > 0.0 || throw(ArgumentError("ArrowHelper dir must be non-zero"))
    d = normalize(d / scale)
    o = _checked_control_vec3(origin, "ArrowHelper origin")
    len = _geometry_finite_float(length, "ArrowHelper length")
    head = _geometry_finite_float(head_length, "ArrowHelper head_length")
    width = _geometry_finite_float(head_width, "ArrowHelper head_width")
    q = if d.y > 0.99999
        Quaternion(0.0, 0.0, 0.0, 1.0)
    elseif d.y < -0.99999
        Quaternion(1.0, 0.0, 0.0, 0.0)
    else
        axis = normalize(Vec3(d.z, 0.0, -d.x))
        half = acos(d.y) / 2
        Quaternion(axis.x * sin(half), axis.y * sin(half), axis.z * sin(half), cos(half))
    end
    arrow = Group(name="ArrowHelper")
    arrow.position = o
    arrow.rotation = _transform_quaternion_to_euler(q, :XYZ)
    shaft = _line_geo(Float64[0.0, 0.0, 0.0, 0.0, max(0.0001, len - head), 0.0])
    add!(arrow, LineObject(shaft, LineBasicMaterial(color=color); name="ArrowHelperLine"))
    cone = Mesh(ConeGeometry(radius=width / 2, height=head, radial_segments=5,
                             height_segments=1),
                MeshBasicMaterial(color=color); name="ArrowHelperCone")
    cone.position = Vec3(0.0, len - head / 2, 0.0)
    add!(arrow, cone)
    return arrow
end

# World matrix and vertex count of a mesh whose per-vertex `label` vectors a
# helper draws.
function _vertex_helper_source(object::AbstractObject3D, label::String)
    hasproperty(object, :geometry) && getproperty(object, :geometry) isa BufferGeometry ||
        throw(ArgumentError("$label needs an object with a BufferGeometry"))
    geometry = getproperty(object, :geometry)::BufferGeometry
    world = compute_world_matrix(object)::Mat4{Float64}
    return geometry, world
end

"""
    VertexNormalsHelper(object, size=1.0; color=Color3(1,0,0))

three.js `VertexNormalsHelper`: one segment per vertex of `object`'s geometry,
from the world-space vertex along its normal transformed by the normal matrix
(inverse transpose of the world matrix), normalized and scaled to `size`.
Built once from the object's current state, in world space.
"""
function VertexNormalsHelper(object::AbstractObject3D, size=1.0;
                             color=_helper_hex_color(0xff0000))
    size = _geometry_finite_float(size, "VertexNormalsHelper size")
    color = _validated_material_color(color, :color)
    geometry, world = _vertex_helper_source(object, "VertexNormalsHelper")
    n = geometry.n_vertices
    length(geometry.normals) == 3n ||
        throw(ArgumentError("VertexNormalsHelper needs a geometry with vertex normals"))
    # Matrix3.getNormalMatrix: the transposed inverse of the linear part; a
    # singular matrix inverts to zero, whose normals stay zero.
    inverse = mat4_inverse(world)
    pos = Vector{Float64}(undef, _helper_line_position_length(n, "VertexNormalsHelper"))
    vi = 1
    for j in 1:n
        b = 3j - 2
        p = mat4_transform_point(world, Vec3(geometry.positions[b], geometry.positions[b + 1],
                                             geometry.positions[b + 2]))
        nx, ny, nz = geometry.normals[b], geometry.normals[b + 1], geometry.normals[b + 2]
        normal = Vec3(mat4_get(inverse, 1, 1) * nx + mat4_get(inverse, 2, 1) * ny + mat4_get(inverse, 3, 1) * nz,
                      mat4_get(inverse, 1, 2) * nx + mat4_get(inverse, 2, 2) * ny + mat4_get(inverse, 3, 2) * nz,
                      mat4_get(inverse, 1, 3) * nx + mat4_get(inverse, 2, 3) * ny + mat4_get(inverse, 3, 3) * nz)
        vi = _write_line_segment!(pos, vi, p, normalize(normal) * size + p)
    end
    return LineSegments(_line_geo(pos), LineBasicMaterial(color=color);
                        name="VertexNormalsHelper")
end

"""
    VertexTangentsHelper(object, size=1.0; color=Color3(0,1,1))

three.js `VertexTangentsHelper`: one segment per vertex of `object`'s
geometry, from the world-space vertex along its `:tangent` attribute (see
[`compute_tangents!`](@ref)) transformed as a direction by the world matrix,
normalized and scaled to `size`. Built once, in world space.
"""
function VertexTangentsHelper(object::AbstractObject3D, size=1.0;
                              color=_helper_hex_color(0x00ffff))
    size = _geometry_finite_float(size, "VertexTangentsHelper size")
    color = _validated_material_color(color, :color)
    geometry, world = _vertex_helper_source(object, "VertexTangentsHelper")
    has_attribute(geometry, :tangent) ||
        throw(ArgumentError("VertexTangentsHelper needs a geometry with a :tangent attribute"))
    tangent = get_attribute(geometry, :tangent)
    stride = tangent.item_size
    n = geometry.n_vertices
    (stride >= 3 && length(tangent.data) >= stride * n) ||
        throw(ArgumentError("VertexTangentsHelper needs a tangent per vertex"))
    pos = Vector{Float64}(undef, _helper_line_position_length(n, "VertexTangentsHelper"))
    vi = 1
    for j in 1:n
        b = 3j - 2
        p = mat4_transform_point(world, Vec3(geometry.positions[b], geometry.positions[b + 1],
                                             geometry.positions[b + 2]))
        t = stride * (j - 1)
        direction = mat4_transform_direction(world, Vec3(Float64(tangent.data[t + 1]),
                                                         Float64(tangent.data[t + 2]),
                                                         Float64(tangent.data[t + 3])))
        # Vector3.transformDirection normalizes.
        vi = _write_line_segment!(pos, vi, p, normalize(direction) * size + p)
    end
    return LineSegments(_line_geo(pos), LineBasicMaterial(color=color);
                        name="VertexTangentsHelper")
end

# RectAreaLightHelper.js positions (line strip) and positions2 (mesh).
const _RECT_AREA_HELPER_LINE = ((1.0, 1.0), (-1.0, 1.0), (-1.0, -1.0), (1.0, -1.0),
                                (1.0, 1.0))

"""
    RectAreaLightHelper(light::RectAreaLight; color=nothing)

three.js `RectAreaLightHelper`: the light's `width`×`height` rectangle as a
`LineObject` (closed line strip) with a child `Mesh` of its two triangles
drawn from the back side (the side the light shines toward). Without `color`
both take `light.color * light.intensity`, scaled down so its largest
component is at most 1, as three.js does. The rectangle lies in the frame
Diff3D shades the light with (centred on it, facing its target); for a light
not aimed straight up or down that is three.js's `lookAt` frame. Built once,
in world space.
"""
function RectAreaLightHelper(light::RectAreaLight; color=nothing)
    if color === nothing
        c = light.color * light.intensity
        largest = max(c.r, c.g, c.b)
        largest > 1 && (c = c * (1 / largest))
        color = c
    end
    color = _validated_material_color(color, :color)
    forward, right, up, position = _rect_area_frame(light)
    # three.js light.lookAt(target): x axis = -right, y axis = up, z = -forward.
    x_axis = -right
    sx = 0.5 * light.width
    sy = 0.5 * light.height
    corner((u, v)) = position + x_axis * (u * sx) + up * (v * sy)
    line_pos = Vector{Float64}(undef, 3 * length(_RECT_AREA_HELPER_LINE))
    for (i, uv) in enumerate(_RECT_AREA_HELPER_LINE)
        p = corner(uv)
        _write_line_vertex!(line_pos, i, p.x, p.y, p.z)
    end
    fill_pos = Vector{Float64}(undef, 3 * length(_PLANE_HELPER_FILL))
    for (i, uv) in enumerate(_PLANE_HELPER_FILL)
        p = corner(uv)
        _write_line_vertex!(fill_pos, i, p.x, p.y, p.z)
    end
    helper = LineObject(_line_geo(line_pos), LineBasicMaterial(color=color);
                        name="RectAreaLightHelper")
    add!(helper, Mesh(_helper_mesh_geo(fill_pos, -forward),
                      MeshBasicMaterial(color=color, side=:back);
                      name="RectAreaLightHelperMesh"))
    return helper
end
