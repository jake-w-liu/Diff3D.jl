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
end

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
                       max_target_radius::Real=Inf)
    _prepare_camera_control_up!(cam)
    _validated_camera_view_vectors(cam, _orbit_camera_kind(cam))
    minimum_zoom, maximum_zoom = _checked_orbit_zoom_limits(min_zoom, max_zoom)
    rotate_speed = _checked_control_scalar(
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
    OrbitControls(cam, checked_target, enabled, enable_rotate, enable_zoom,
                  enable_pan, enable_damping, damping,
                  minimum_distance, maximum_distance,
                  minimum_polar, maximum_polar,
                  minimum_azimuth, maximum_azimuth,
                  0.0, 0.0, 0.0, Vec3(0.0, 0.0, 0.0), cam.position,
                  checked_target, screen_space_panning,
                  minimum_zoom, maximum_zoom, cam.zoom,
                  auto_rotate, rotate_speed, checked_cursor,
                  minimum_target_radius, maximum_target_radius)
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
    MapControls(camera[, target]; screen_space_panning=false, kwargs...)

`OrbitControls` configured like three.js `MapControls`: vertical pan deltas
move the target across the plane orthogonal to `camera.up` (the ground for a
y-up scene) instead of along the screen's up axis. All other keywords are the
`OrbitControls` ones.
"""
MapControls(cam::_OrbitCamera, target::Vec3{Float64};
            screen_space_panning::Bool=false, kwargs...) =
    OrbitControls(cam, target; screen_space_panning=screen_space_panning, kwargs...)
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
frame (see `orbit_update!`).
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
    # applies the limits and, with auto-rotation, turns the camera one frame.
    oc.enabled && oc.auto_rotate && return orbit_update!(oc)
    return _orbit_enforce_limits!(oc)
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
turn is added to the residual azimuth velocity instead.
"""
function orbit_update!(oc::OrbitControls, delta_time=nothing)
    oc.enabled || return oc
    _validate_orbit_runtime(oc)
    # A frame delta must be a finite real even when auto-rotation is off.
    delta_time === nothing ||
        _checked_control_scalar(delta_time, "OrbitControls delta_time")
    if oc.auto_rotate
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

# TrackballControls: free rotation about the target via screen-space deltas.
mutable struct TrackballControls
    camera::PerspectiveCamera
    target::Vec3{Float64}
    enabled::Bool
    position0::Vec3{Float64}
    target0::Vec3{Float64}
    up0::Vec3{Float64}
    # three.js TrackballControls.minDistance / maxDistance: every rotate, zoom
    # and pan keeps the camera-to-target distance inside this range.
    min_distance::Float64
    max_distance::Float64
end

TrackballControls(camera::PerspectiveCamera, target::Vec3{Float64},
                  enabled::Bool, position0::Vec3{Float64},
                  target0::Vec3{Float64}, up0::Vec3{Float64}) =
    TrackballControls(camera, target, enabled, position0, target0, up0,
                      0.0, Inf)

"""
    TrackballControls(camera[, target]; enabled=true, min_distance=0.0,
                      max_distance=Inf)

Trackball camera manipulator (three.js `TrackballControls`). `min_distance`
and `max_distance` bound the camera-to-target distance after every
`trackball_rotate!`, `trackball_zoom!`, and `trackball_pan!`, like three.js
`minDistance`/`maxDistance`.
"""
function TrackballControls(cam::PerspectiveCamera, target::Vec3{Float64}=_camera_control_target(cam);
                           enabled::Bool=true, min_distance::Real=0.0,
                           max_distance::Real=Inf)
    _prepare_camera_control_up!(cam)
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    checked_target = _checked_control_vec3(
        target, "TrackballControls target")
    minimum_distance, maximum_distance =
        _checked_orbit_distances(min_distance, max_distance)
    TrackballControls(cam, checked_target, enabled, cam.position,
                      checked_target, cam.up, minimum_distance,
                      maximum_distance)
end

"""Save the current camera position, up vector, and target as the reset state."""
function trackball_save_state!(tc::TrackballControls)
    _validated_camera_view_vectors(tc.camera, :PerspectiveCamera)
    _checked_control_vec3(tc.target, "TrackballControls target")
    tc.position0 = tc.camera.position
    tc.target0 = tc.target
    tc.up0 = tc.camera.up
    return tc
end

"""Restore the saved trackball state."""
function trackball_reset!(tc::TrackballControls)
    position = _checked_control_vec3(
        tc.position0, "TrackballControls saved position")
    up = _checked_control_vec3(tc.up0, "TrackballControls saved up")
    max(abs(up.x), abs(up.y), abs(up.z)) > 0.0 ||
        throw(ArgumentError("TrackballControls saved up must be non-zero"))
    target = _checked_control_vec3(
        tc.target0, "TrackballControls saved target")
    tc.camera.position = position
    tc.camera.up = up
    tc.target = target
    tc.camera.target = target
    _sync_camera_rotation_from_view!(tc.camera)
    return tc
end

# three.js TrackballControls._checkDistances (TrackballControls.js:738-756):
# an eye longer than maxDistance, or shorter than minDistance, is rescaled to
# that length along its direction. A zero eye has no direction and stays zero.
function _trackball_limited_eye(tc::TrackballControls, eye::Vec3)
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
    _, _, up = _validated_camera_view_vectors(cam, :PerspectiveCamera)
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
`TrackballControls` ignores such zoom steps.
"""
function trackball_zoom!(tc::TrackballControls, factor)
    tc.enabled || return tc
    _validated_camera_view_vectors(tc.camera, :PerspectiveCamera)
    _checked_control_vec3(tc.target, "TrackballControls target")
    checked_factor = _checked_control_scalar(
        factor, "TrackballControls zoom factor")
    eye = tc.camera.position - tc.target
    # TrackballControls.js:632 only scales the eye when `factor > 0`.
    scaled = checked_factor > 0.0 ? eye * checked_factor : eye
    return _trackball_set_eye!(tc, _trackball_limited_eye(tc, scaled))
end

"""Pan the trackball target and camera in the view plane."""
function trackball_pan!(tc::TrackballControls, dx, dy)
    tc.enabled || return tc
    _validated_camera_view_vectors(tc.camera, :PerspectiveCamera)
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

# FlyControls: first-person translation/rotation along the camera basis.
mutable struct FlyControls
    camera::PerspectiveCamera
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

# DragControls: programmatic object selection and world-space drag movement,
# with a perspective or orthographic camera like three.js.
mutable struct DragControls
    objects::Vector{AbstractObject3D}
    camera::_OrbitCamera
    selected::Union{Nothing, AbstractObject3D}
    recursive::Bool
    transform_group::Bool
    raycaster::Raycaster
end

function DragControls(objects::AbstractVector{<:AbstractObject3D}, camera::_OrbitCamera;
                      recursive::Bool=true, transform_group::Bool=false,
                      raycaster::Union{Nothing,Raycaster}=nothing)
    rc = raycaster === nothing ?
        Raycaster(camera.position, Vec3(0.0, 0.0, -1.0)) : raycaster
    DragControls(collect(AbstractObject3D, objects), camera, nothing,
                 recursive, transform_group, rc)
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
# vector of another width gets that vector's values back.
function _binding_restore_original!(b::_AnimationBinding)
    if b.kind == _BINDING_VECTOR && !isempty(b.original_vector)
        setproperty!(b.node, b.property, copy(b.original_vector))
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
            b.apply_offset = offset
            _binding_set!(b.node, b)
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
                                      AbstractKeyframeTrack[])
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

"""Frustum wireframe (12 edges) of a camera from its inverse view-projection."""
function CameraHelper(camera::AbstractCamera; color=Color3(1.0,1.0,1.0))
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
Square outline lying in `plane` with side length `size`, plus a segment along the
plane normal from the plane's nearest point to the origin (three.js
`PlaneHelper`). The plane is `n·x + d = 0`; its representative point is `-d·n`.
"""
function PlaneHelper(plane::Plane, size=1.0; color=Color3(1.0, 1.0, 0.0))
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
