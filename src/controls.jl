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

mutable struct OrbitControls
    camera::PerspectiveCamera
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
    _validated_camera_view_vectors(oc.camera, :PerspectiveCamera)
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

# Positional/keyword constructors. The two original positional forms still work;
# damping and constraint fields are keyword-only with three.js-matching defaults.
function OrbitControls(cam::PerspectiveCamera, target::Vec3{Float64};
                       enabled::Bool=true, enable_rotate::Bool=true,
                       enable_zoom::Bool=true, enable_pan::Bool=true,
                       enable_damping::Bool=false, damping_factor::Real=0.05,
                       min_distance::Real=0.0, max_distance::Real=Inf,
                       min_polar_angle::Real=0.0, max_polar_angle::Real=π,
                       min_azimuth_angle::Real=-Inf, max_azimuth_angle::Real=Inf)
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
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
                  checked_target)
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
                                        "OrbitControls saved target"))
end

OrbitControls(cam::PerspectiveCamera; kwargs...) =
    OrbitControls(cam, cam.target; kwargs...)

# Current spherical (radius, polar from +y, azimuth) of the camera about target.
_orbit_spherical(oc::OrbitControls) = cartesian_to_spherical(oc.camera.position - oc.target)

# Clamp an azimuth (read back from cartesian_to_spherical, hence in (-π, π]) to
# the configured window, matching three.js OrbitControls. The bounds are first
# normalized into (-π, π]; a window that straddles ±π (so the normalized min
# ends up above the normalized max) keeps any angle on either arc instead of
# snapping it to a boundary — without this, a back-facing range such as
# [π/2, 3π/2] is unusable because cartesian_to_spherical can never return a
# value above π. A non-finite (default unbounded / one-sided) limit takes the
# plain clamp, which already does the right thing with ±Inf.
@inline function _clamp_azimuth(theta, min_az, max_az)
    (isfinite(min_az) && isfinite(max_az)) || return clamp(theta, min_az, max_az)
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
    phi = clamp(s.phi, max(oc.min_polar_angle, 1e-4), min(oc.max_polar_angle, π - 1e-4))
    theta = _clamp_azimuth(s.theta, oc.min_azimuth_angle, oc.max_azimuth_angle)
    return Spherical(radius, phi, theta)
end

function _orbit_apply!(oc::OrbitControls, s::Spherical)
    position = oc.target + spherical_to_cartesian(_orbit_constrained(oc, s))
    position = _checked_control_vec3(
        position, "OrbitControls camera position")
    oc.camera.position = position
    oc.camera.target = oc.target
    return oc
end

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

"""Save the current camera position and target as the reset state."""
function orbit_save_state!(oc::OrbitControls)
    _validated_camera_view_vectors(oc.camera, :PerspectiveCamera)
    _checked_control_vec3(oc.target, "OrbitControls target")
    oc.position0 = oc.camera.position
    oc.target0 = oc.target
    return oc
end

"""Restore the saved orbit state and clear any damped residual motion."""
function orbit_reset!(oc::OrbitControls)
    position = _checked_control_vec3(
        oc.position0, "OrbitControls saved position")
    target = _checked_control_vec3(oc.target0, "OrbitControls saved target")
    oc.camera.position = position
    oc.target = target
    oc.camera.target = target
    oc.v_azimuth = 0.0
    oc.v_polar = 0.0
    oc.v_zoom = 0.0
    oc.v_pan = Vec3(0.0, 0.0, 0.0)
    return oc
end

# Immediate (non-damped) primitives that always apply their deltas at once.
function _orbit_rotate_now!(oc::OrbitControls, d_azimuth, d_polar)
    s = _orbit_spherical(oc)
    _orbit_apply!(oc, Spherical(s.radius, s.phi + d_polar, s.theta + d_azimuth))
end
function _orbit_zoom_now!(oc::OrbitControls, factor)
    s = _orbit_spherical(oc)
    _orbit_apply!(oc, Spherical(s.radius * factor, s.phi, s.theta))
end
function _camera_pan_basis(camera::PerspectiveCamera, target::Vec3{Float64})
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
_orbit_pan_basis(oc::OrbitControls) = _camera_pan_basis(oc.camera, oc.target)
function _orbit_pan_now!(oc::OrbitControls, dx, dy)
    right, up = _orbit_pan_basis(oc)
    shift = right * dx + up * dy
    target = _checked_control_vec3(
        oc.target + shift, "OrbitControls target")
    position = _checked_control_vec3(
        oc.camera.position + shift, "OrbitControls camera position")
    oc.target = target
    oc.camera.position = position
    oc.camera.target = target
    return oc
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
        zoom_velocity = _checked_control_scalar(
            oc.v_zoom + log(f), "OrbitControls zoom velocity")
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
    orbit_update!(oc)

Advance the orbit by one frame. With damping disabled this is a no-op (state is
already current). With damping enabled it applies `damping_factor` of the
residual rotation, dolly, and pan velocities, then decays them by
`(1 - damping_factor)` so motion eases to a stop after the last interaction and
the total converges to the queued deltas (three.js `OrbitControls.update`).
Velocity components below a small threshold are zeroed to avoid endless drift.
"""
function orbit_update!(oc::OrbitControls)
    oc.enabled || return oc
    oc.enable_damping || return oc
    _validate_orbit_runtime(oc)
    decay = 1.0 - oc.damping_factor
    # Apply `damping_factor` of the residual velocities for this frame, so the
    # total motion converges to exactly the queued deltas (three.js applies
    # `sphericalDelta * dampingFactor` per frame before decaying).
    if oc.v_azimuth != 0.0 || oc.v_polar != 0.0
        _orbit_rotate_now!(oc, oc.v_azimuth * oc.damping_factor,
                           oc.v_polar * oc.damping_factor)
    end
    if oc.v_zoom != 0.0
        _orbit_zoom_now!(oc, exp(oc.v_zoom * oc.damping_factor))
    end
    if oc.v_pan.x != 0.0 || oc.v_pan.y != 0.0 || oc.v_pan.z != 0.0
        # Pan velocity is already a world-space offset; apply its damped share.
        step = oc.v_pan * oc.damping_factor
        target = _checked_control_vec3(
            oc.target + step, "OrbitControls target")
        position = _checked_control_vec3(
            oc.camera.position + step, "OrbitControls camera position")
        oc.target = target
        oc.camera.position = position
        oc.camera.target = target
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

# TrackballControls: free rotation about the target via screen-space deltas.
mutable struct TrackballControls
    camera::PerspectiveCamera
    target::Vec3{Float64}
    enabled::Bool
    position0::Vec3{Float64}
    target0::Vec3{Float64}
    up0::Vec3{Float64}
end

function TrackballControls(cam::PerspectiveCamera, target::Vec3{Float64}=cam.target;
                           enabled::Bool=true)
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    checked_target = _checked_control_vec3(
        target, "TrackballControls target")
    TrackballControls(cam, checked_target, enabled, cam.position,
                      checked_target, cam.up)
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
    return tc
end

function _trackball_apply!(tc::TrackballControls, s::Spherical)
    radius = max(s.radius, 0.0)
    phi = clamp(s.phi, 1e-4, π - 1e-4)
    position = tc.target + spherical_to_cartesian(
        Spherical(radius, phi, s.theta))
    tc.camera.position = _checked_control_vec3(
        position, "TrackballControls camera position")
    tc.camera.target = tc.target
    return tc
end

function trackball_rotate!(tc::TrackballControls, dx, dy)
    tc.enabled || return tc
    _validated_camera_view_vectors(tc.camera, :PerspectiveCamera)
    _checked_control_vec3(tc.target, "TrackballControls target")
    checked_dx = _checked_control_scalar(dx, "TrackballControls x delta")
    checked_dy = _checked_control_scalar(dy, "TrackballControls y delta")
    s = cartesian_to_spherical(tc.camera.position - tc.target)
    return _trackball_apply!(
        tc, Spherical(s.radius, s.phi + checked_dy, s.theta + checked_dx))
end

"""Scale the camera distance from the trackball target. `factor < 1` zooms in."""
function trackball_zoom!(tc::TrackballControls, factor)
    tc.enabled || return tc
    _validated_camera_view_vectors(tc.camera, :PerspectiveCamera)
    _checked_control_vec3(tc.target, "TrackballControls target")
    checked_factor = _checked_control_scalar(
        factor, "TrackballControls zoom factor")
    s = cartesian_to_spherical(tc.camera.position - tc.target)
    return _trackball_apply!(
        tc, Spherical(s.radius * checked_factor, s.phi, s.theta))
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
    position = _checked_control_vec3(
        tc.camera.position + shift, "TrackballControls camera position")
    tc.target = target
    tc.camera.position = position
    tc.camera.target = target
    return tc
end

# FlyControls: first-person translation/rotation along the camera basis.
mutable struct FlyControls
    camera::PerspectiveCamera
end

"""Translate the camera (and its target) along forward/right/up axes."""
function fly_translate!(fc::FlyControls, forward, right, up)
    cam = fc.camera
    _validated_camera_view_vectors(cam, :PerspectiveCamera)
    checked_forward = _checked_control_scalar(
        forward, "FlyControls forward delta")
    checked_right = _checked_control_scalar(right, "FlyControls right delta")
    checked_up = _checked_control_scalar(up, "FlyControls up delta")
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
    dist = norm(cam.target - cam.position)
    dir = normalize(cam.target - cam.position)
    s = cartesian_to_spherical(dir)
    s2 = Spherical(1.0, clamp(s.phi - checked_pitch, 1e-4, π - 1e-4),
                   s.theta + checked_yaw)
    target = cam.position + spherical_to_cartesian(s2) * dist
    cam.target = _checked_control_vec3(
        target, "FlyControls camera target")
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
    return pc
end

# DragControls: programmatic object selection and world-space drag movement.
mutable struct DragControls
    objects::Vector{AbstractObject3D}
    camera::PerspectiveCamera
    selected::Union{Nothing, AbstractObject3D}
    recursive::Bool
    transform_group::Bool
    raycaster::Raycaster
end

function DragControls(objects::AbstractVector{<:AbstractObject3D}, camera::PerspectiveCamera;
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
    position = _checked_control_vec3(
        obj.position + checked_delta, "DragControls object position")
    obj.position = position
    return dc
end

drag_end!(dc::DragControls) = (dc.selected = nothing; dc)

# TransformControls: attach one object and apply translate/rotate/scale deltas.
mutable struct TransformControls
    camera::PerspectiveCamera
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

function TransformControls(camera::PerspectiveCamera;
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

TransformControls(camera::PerspectiveCamera,
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

_transform_snap_value(value::Real, snap::Float64) =
    round(Float64(value) / snap) * snap

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
        move = tc.space === :local ? _transform_local_delta(obj, axis_delta) : axis_delta
        position = obj.position + move
        tc.translation_snap !== nothing &&
            (position = _transform_snap_position(position, tc.translation_snap, tc.axis))
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
        rotation = _checked_control_vec3(
            Vec3(obj.rotation.x + angles.x, obj.rotation.y + angles.y,
                 obj.rotation.z + angles.z),
            "TransformControls object rotation")
        obj.rotation = Euler(rotation.x, rotation.y, rotation.z,
                             obj.rotation.order)
    end
    return tc
end

# ========================== Clock ==========================

mutable struct Clock
    start_time::Float64
    last_time::Float64
    running::Bool
end
Clock() = (t = time(); Clock(t, t, true))

function _validate_clock(c::Clock)
    _checked_control_scalar(c.start_time, "Clock start_time")
    _checked_control_scalar(c.last_time, "Clock last_time")
    return nothing
end

function clock_elapsed(c::Clock, now=time())
    _validate_clock(c)
    current = _checked_control_scalar(now, "Clock current time")
    return _checked_control_scalar(
        current - c.start_time, "Clock elapsed time")
end

function clock_delta!(c::Clock, now=time())
    _validate_clock(c)
    current = _checked_control_scalar(now, "Clock current time")
    d = _checked_control_scalar(current - c.last_time, "Clock delta")
    c.last_time = current
    return d
end

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

    function NumberKeyframeTrack(target::AbstractObject3D, property::Symbol,
                                 component::Int, times::Vector{Float64},
                                 values::Vector{Float64}, interpolation::Symbol)
        interpolation in (:linear, :step, :cubic) ||
            throw(ArgumentError("unsupported number keyframe interpolation: $interpolation"))
        component >= 0 || throw(ArgumentError("animation component index must be non-negative"))
        _validate_keyframe_values("NumberKeyframeTrack", times, values)
        _validate_finite_keyframe_values("NumberKeyframeTrack", values)
        new(target, property, component, times, values, interpolation)
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

function _parse_animation_property_path(target::AbstractObject3D,
                                        path::AbstractString)
    p = startswith(path, ".") ? path[2:end] : String(path)
    isempty(p) && throw(ArgumentError("animation property path must not be empty"))
    material_path = startswith(p, "material.")
    material_path && (p = p[10:end])
    isempty(p) && throw(ArgumentError("animation material property path must not be empty"))
    bracket = match(r"^(.+)\[([^\]]+)\]$", p)
    if bracket !== nothing
        return _resolved_animation_property(target, bracket.captures[1], material_path),
               _animation_component_index(bracket.captures[2])
    end
    dot = match(r"^(.+)\.([A-Za-z])$", p)
    if dot !== nothing
        return _resolved_animation_property(target, dot.captures[1], material_path),
               _animation_component_index(dot.captures[2])
    end
    return _resolved_animation_property(target, p, material_path), 0
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
    property, component = _parse_animation_property_path(target, property_path)
    NumberKeyframeTrack(target, property, times, values;
                        interpolation=interpolation, component=component)
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

# Catmull-Rom spline tangent: derivative estimated from the neighbouring
# keyframes, clamped at the endpoints (matches three.js CubicInterpolant on a
# uniform-Catmull-Rom basis). Works for Real and Vec3 values.
@inline _cr_sub(a::Real, b::Real) = a - b
@inline _cr_sub(a::Vec3, b::Vec3) = a - b
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

"""
    interpolate_catmull_rom(times, values, t)

Catmull-Rom spline sample of `values` at sorted `times`, evaluated at `t`,
clamped to the endpoints. Tangents use the centripetal/uniform Catmull-Rom rule
on possibly non-uniform `times`; endpoint tangents are one-sided. `values` may be
reals or `Vec3`.
"""
function interpolate_catmull_rom(times::AbstractVector, values::AbstractVector, t)
    n = _validate_interpolant_inputs("interpolate_catmull_rom", times, values)
    # A NaN time passes both endpoint checks (all NaN comparisons are false) and
    # then indexes one past the end via searchsortedfirst; reject it cleanly, as
    # interpolate_linear does, instead of leaking a BoundsError.
    isnan(t) && throw(ArgumentError("interpolate_catmull_rom: query time t must not be NaN"))
    t <= times[1] && return values[1]
    t >= times[n] && return values[n]
    n == 1 && return values[1]
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    h = times[hi] - times[lo]
    α = (t - times[lo]) / h
    p1 = values[lo]; p2 = values[hi]
    # One-sided tangents at the ends, central tangents in the interior, scaled by
    # the local interval h so the Hermite basis matches the parameter spacing.
    if lo > 1
        m1 = _cr_scale(_cr_sub(values[hi], values[lo-1]), h / (times[hi] - times[lo-1]))
    else
        m1 = _cr_sub(values[hi], values[lo])           # forward difference
    end
    if hi < n
        m2 = _cr_scale(_cr_sub(values[hi+1], values[lo]), h / (times[hi+1] - times[lo]))
    else
        m2 = _cr_sub(values[hi], values[lo])           # backward difference
    end
    return _hermite(p1, p2, m1, m2, α)
end

# Sample a single track value at absolute time `t` according to its mode.
function _track_value(tr::KeyframeTrack, t)
    if tr.interpolation === :cubic
        return interpolate_catmull_rom(tr.times, tr.values, t)
    elseif tr.interpolation === :step
        n = length(tr.times)
        n == 0 && error("cannot sample an empty KeyframeTrack")
        t <= tr.times[1] && return tr.values[1]
        t >= tr.times[n] && return tr.values[n]
        return tr.values[searchsortedlast(tr.times, t)]
    else
        return interpolate_linear(tr.times, tr.values, t)
    end
end

function _track_value(tr::NumberKeyframeTrack, t)
    if tr.interpolation === :cubic
        return interpolate_catmull_rom(tr.times, tr.values, t)
    elseif tr.interpolation === :step
        n = length(tr.times)
        n == 0 && error("cannot sample an empty NumberKeyframeTrack")
        t <= tr.times[1] && return tr.values[1]
        t >= tr.times[n] && return tr.values[n]
        return tr.values[searchsortedlast(tr.times, t)]
    else
        return interpolate_linear(tr.times, tr.values, t)
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
    t <= times[1] && return tr.values[1]
    t >= times[n] && return tr.values[n]
    hi = searchsortedfirst(times, t)
    lo = hi - 1
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
    hi = searchsortedfirst(times, t)
    lo = hi - 1
    # STEP holds the value of the keyframe AT or before t; at an exact interior
    # keyframe time searchsortedfirst lands on that key, so use searchsortedlast
    # (the previous-keyframe `lo` above is correct only for the slerp interval).
    tr.interpolation === :step && return values[searchsortedlast(times, t)]
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

# Quaternion → Euler (intrinsic XYZ order, matching the default `Euler`).
# Mirrors three.js `Euler.setFromQuaternion` for order XYZ.
function _quat_to_euler_xyz(q::Quaternion)
    qn = quat_normalize(q)
    x, y, z, w = qn.x, qn.y, qn.z, qn.w
    # Correct the small residual norm error left by floating-point
    # normalization. The scale-invariant matrix terms also make exact gimbal
    # rotations stable when their glTF components originated as Float32.
    norm2 = x*x + y*y + z*z + w*w
    scale = (one(norm2) + one(norm2)) / norm2
    m13 = scale * (x*z + w*y)
    m13c = clamp(m13, -one(m13), one(m13))
    ey = asin(m13c)
    if abs(m13) < 0.9999999
        m23 = scale * (y*z - w*x)
        m33 = one(scale) - scale * (x*x + y*y)
        m12 = scale * (x*y - w*z)
        m11 = one(scale) - scale * (y*y + z*z)
        ex = atan(-m23, m33)
        ez = atan(-m12, m11)
    else                                   # gimbal lock
        m32 = scale * (y*z + w*x)
        m22 = one(scale) - scale * (x*x + z*z)
        ex = atan(m32, m22)
        ez = zero(ey)
    end
    return Euler(ex, ey, ez, :XYZ)
end

struct AnimationClip
    name::String
    duration::Float64
    tracks::Vector{AbstractKeyframeTrack}
    loop::Symbol
    repetitions::Int
    clamp_when_finished::Bool
    time_scale::Float64
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
                       time_scale::Real=1.0)
    AnimationClip(
        name, _validated_animation_duration(duration),
        collect(AbstractKeyframeTrack, tracks),
        _animation_loop_mode(loop),
        _validated_animation_repetitions(repetitions),
        clamp_when_finished,
        _validated_animation_time_scale(time_scale),
    )
end

function AnimationClip(name::String, tracks::AbstractVector{<:AbstractKeyframeTrack};
                       loop::Symbol=:repeat,
                       repetitions::Integer=-1,
                       clamp_when_finished::Bool=false,
                       time_scale::Real=1.0)
    duration = isempty(tracks) ? 0.0 :
        maximum(isempty(t.times) ? 0.0 : maximum(t.times) for t in tracks)
    AnimationClip(name, duration, tracks; loop=loop, repetitions=repetitions,
                  clamp_when_finished=clamp_when_finished, time_scale=time_scale)
end

mutable struct AnimationMixer
    clip::AnimationClip
    time::Float64
    loop::Symbol
    repetitions::Int
    clamp_when_finished::Bool
    time_scale::Float64
end
function AnimationMixer(clip::AnimationClip; loop::Union{Symbol,Nothing}=nothing,
                        repetitions::Union{Integer,Nothing}=nothing,
                        clamp_when_finished::Union{Bool,Nothing}=nothing,
                        time_scale::Union{Real,Nothing}=nothing)
    AnimationMixer(clip, 0.0,
                   loop === nothing ? clip.loop : _animation_loop_mode(loop),
                   repetitions === nothing ? clip.repetitions :
                   _validated_animation_repetitions(repetitions),
                   clamp_when_finished === nothing ? clip.clamp_when_finished : clamp_when_finished,
                   time_scale === nothing ? clip.time_scale :
                   _validated_animation_time_scale(time_scale))
end

function _animation_loop_time(t::Real, duration::Real, loop::Symbol,
                              repetitions::Int, clamp_when_finished::Bool)
    duration isa Bool &&
        throw(ArgumentError("animation duration must be finite and non-negative"))
    d = Float64(duration)
    isfinite(d) && d >= 0.0 ||
        throw(ArgumentError("animation duration must be finite and non-negative"))
    d <= 0.0 && return 0.0
    t isa Bool && throw(ArgumentError("animation time must be finite"))
    x = Float64(t)
    isfinite(x) ||
        throw(ArgumentError("animation time must be finite"))
    loop = _animation_loop_mode(loop)
    if loop === :once
        x <= 0.0 && return 0.0
        x >= d && return clamp_when_finished ? d : 0.0
        return x
    end
    reps = repetitions < 0 ? typemax(Int) : max(repetitions, 0)
    if reps == 0
        return clamp_when_finished ? 0.0 : 0.0
    end
    if repetitions >= 0 && x >= d * reps
        if !clamp_when_finished
            return 0.0
        end
        return loop === :pingpong && iseven(reps) ? 0.0 : d
    end
    if loop === :pingpong
        y = mod(x, 2d)
        return y <= d ? y : 2d - y
    end
    y = mod(x, d)
    return x > 0.0 && isapprox(y, 0.0; atol=eps(Float64) * max(1.0, abs(x))) ? d : y
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

function _replace_field_value(x, property::Symbol, value)
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

function _write_material_track_value!(target, property::Symbol, value)
    hasproperty(target, :material) || return false
    mat = getproperty(target, :material)
    property = _material_animation_property(property)
    _material_noop_update(mat, property, value) && return true
    newmat = _replace_field_value(mat, property, value)
    newmat === nothing && return false
    setproperty!(target, :material, newmat)
    return true
end

function _write_material_track_value!(target, property::Symbol, component::Int, value::Real)
    hasproperty(target, :material) || return false
    mat = getproperty(target, :material)
    property = _material_animation_property(property)
    _material_component_noop_update(mat, property, component, value) && return true
    hasproperty(mat, property) || return false
    current = getproperty(mat, property)
    newmat = _replace_field_value(mat, property, _with_component(current, component, value))
    newmat === nothing && return false
    setproperty!(target, :material, newmat)
    return true
end

function _split_texture_track_property(property::Symbol)
    return get(_TEXTURE_ANIMATION_TRACK_PROPERTIES, property, nothing)
end

function _material_texture_for_track(target, property::Symbol)
    split = _split_texture_track_property(property)
    split === nothing && return nothing
    hasproperty(target, :material) || return nothing
    field, texture_property = split
    mat = getproperty(target, :material)
    hasproperty(mat, field) || return nothing
    tex = getproperty(mat, field)
    tex isa Texture || throw(ArgumentError("material.$field is not a Texture"))
    return tex, texture_property
end

function _refresh_texture_track_matrix!(tex::Texture)
    tex.matrix_auto_update && texture_update_matrix!(tex)
    return tex
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
        current = getproperty(tex, texture_property)
        setproperty!(tex, texture_property, _with_component(current, component, value))
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
        setproperty!(tex, texture_property, Vec2(value.x, value.y))
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

function _write_morph_component_tree!(obj, property::Symbol, component::Int,
                                      value::Float64)
    wrote = false
    if hasproperty(obj, property)
        values = getproperty(obj, property)
        1 <= component <= length(values) ||
            throw(ArgumentError("morph influence component $(component - 1) is out of range"))
        values[component] = value
        wrote = true
    end
    for child in get_children(obj)
        wrote |= _write_morph_component_tree!(child, property, component, value)
    end
    return wrote
end

function _write_morph_component!(target, property::Symbol, component::Int, v::Real)
    wrote = _write_morph_component_tree!(target, property, component, Float64(v))
    wrote || throw(ArgumentError("target does not expose morph target influences"))
    return target
end
function _write_track_value!(target, property::Symbol, component::Int, v::Real)
    component == 0 && return _write_track_value!(target, property, Float64(v))
    property === :quaternion &&
        return _write_quaternion_component!(target, component, v)
    property === :morph_target_influences &&
        return _write_morph_component!(target, property, component, v)
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

function _copy_morph_track_values!(target, property::Symbol, v::Vector{Float64})
    values = getproperty(target, property)
    values === v && return target
    if length(values) == length(v)
        length(v) > 0 && copyto!(values, 1, v, 1, length(v))
    else
        setproperty!(target, property, copy(v))
    end
    return target
end

function _write_morph_track_values_tree!(target, property::Symbol, v::Vector{Float64})
    wrote = false
    if hasproperty(target, property)
        _copy_morph_track_values!(target, property, v)
        wrote = true
    end
    for child in get_children(target)
        wrote |= _write_morph_track_values_tree!(child, property, v)
    end
    return wrote
end

function _write_track_value!(target, property::Symbol, v::Vector{Float64})
    if property === :morph_target_influences
        wrote = _write_morph_track_values_tree!(target, property, v)
        wrote || setproperty!(target, property, copy(v))
    else
        setproperty!(target, property, copy(v))
    end
    return target
end
_write_track!(tr::AbstractKeyframeTrack, v) = _write_track_value!(tr.target, tr.property, v)
_write_track!(tr::NumberKeyframeTrack, v) = _write_track_value!(tr.target, tr.property, tr.component, v)

function _write_track_value!(target, property::Symbol, v::Quaternion)
    if property === :rotation || property === :quaternion
        setproperty!(target, :rotation, _quat_to_euler_xyz(v))
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

function _write_track_value!(target, property::Symbol, v::Float64)
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

const _MorphInfluenceObject =
    Union{Mesh, LineObject, PointsObject, LineSegments, LineLoop, SkinnedMesh}

function _generic_morph_track_output_buffer!(target, property::Symbol, tr)
    width = length(tr.values[1])
    values = getproperty(target, property)
    if length(values) != width || _morph_buffer_aliases_track(values, tr)
        values = Vector{Float64}(undef, width)
        setproperty!(target, property, values)
    end
    return values
end

_morph_track_output_buffer!(target, property::Symbol, tr) =
    _generic_morph_track_output_buffer!(target, property, tr)

function _morph_track_output_buffer!(
    target::_MorphInfluenceObject, property::Symbol, tr,
)
    property === :morph_target_influences ||
        return _generic_morph_track_output_buffer!(target, property, tr)
    width = length(tr.values[1])
    values = target.morph_target_influences
    if length(values) != width || _morph_buffer_aliases_track(values, tr)
        values = Vector{Float64}(undef, width)
        target.morph_target_influences = values
    end
    return values
end

function _write_morph_track_at_time_tree!(target, property::Symbol, tr, t)
    wrote = false
    if hasproperty(target, property)
        out = _morph_track_output_buffer!(target, property, tr)
        _sample_morph_weights!(out, tr, t)
        wrote = true
    end
    for child in get_children(target)
        wrote |= _write_morph_track_at_time_tree!(child, property, tr, t)
    end
    return wrote
end

function _write_track_at_time!(tr::AbstractKeyframeTrack, t)
    v = _track_value(tr, t)
    _write_track!(tr, v)
    return tr
end

function _write_track_at_time!(tr::MorphWeightsKeyframeTrack, t)
    if tr.property === :morph_target_influences
        wrote = _write_morph_track_at_time_tree!(tr.target, tr.property, tr, t)
        wrote || _write_track!(tr, _track_value(tr, t))
        return tr
    end
    v = _track_value(tr, t)
    _write_track!(tr, v)
    return tr
end

function _write_track_at_time!(tr::CubicSplineMorphWeightsKeyframeTrack, t)
    if tr.property === :morph_target_influences
        wrote = _write_morph_track_at_time_tree!(tr.target, tr.property, tr, t)
        wrote || _write_track!(tr, _track_value(tr, t))
        return tr
    end
    v = _track_value(tr, t)
    _write_track!(tr, v)
    return tr
end

"""Sample the clip at absolute time `t` and write each track's value to its target."""
function mixer_set_time!(mixer::AnimationMixer, t)
    t isa Real && !(t isa Bool) ||
        throw(ArgumentError("mixer_set_time!: time must be finite"))
    time = Float64(t)
    isfinite(time) ||
        throw(ArgumentError("mixer_set_time!: time must be finite"))
    time_scale =
        _validated_animation_time_scale(mixer.time_scale)
    sample_time = _animation_loop_time(time * time_scale,
                                       mixer.clip.duration,
                                       mixer.loop,
                                       mixer.repetitions,
                                       mixer.clamp_when_finished)
    for tr in mixer.clip.tracks
        _write_track_at_time!(tr, sample_time)
    end
    mixer.time = time
    return mixer
end

function mixer_update!(mixer::AnimationMixer, dt)
    delta = _checked_control_scalar(dt, "mixer_update!: dt")
    time = _checked_control_scalar(
        mixer.time, "AnimationMixer current time")
    next_time = _checked_control_scalar(
        time + delta, "AnimationMixer updated time")
    return mixer_set_time!(mixer, next_time)
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

"""Diff3D line segments along +x (red), +y (green), +z (blue)."""
function AxesHelper(size=1.0)
    size = _geometry_finite_float(size, "AxesHelper size")
    pos = Float64[0,0,0, size,0,0,  0,0,0, 0,size,0,  0,0,0, 0,0,size]
    geo = _line_geo(pos)
    set_attribute!(geo, :color, Float64[1,0,0, 1,0,0,  0,1,0, 0,1,0,  0,0,1, 0,0,1], 3)
    LineSegments(geo, LineBasicMaterial(color=Color3(1.0,1.0,1.0)); name="AxesHelper")
end

"""A `divisions`×`divisions` grid of size `size` on the xz-plane."""
function GridHelper(size=10.0, divisions=10; color=Color3(0.5,0.5,0.5))
    size = _geometry_finite_float(size, "GridHelper size")
    divisions = _clamp_seg(divisions, 1)   # divisions=0 would make step=Inf -> NaN vertices
    lines = _geometry_checked_mul(
        2, _geometry_checked_add(divisions, 1, "GridHelper line count"),
        "GridHelper line count")
    pos = Vector{Float64}(
        undef, _helper_line_position_length(lines, "GridHelper"))
    step = size / divisions; half = size / 2
    vi = 1
    for i in 0:divisions
        c = -half + i*step
        _write_line_vertex!(pos, vi, c, 0.0, -half)
        _write_line_vertex!(pos, vi + 1, c, 0.0, half)      # parallel to z
        _write_line_vertex!(pos, vi + 2, -half, 0.0, c)
        _write_line_vertex!(pos, vi + 3, half, 0.0, c)      # parallel to x
        vi += 4
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="GridHelper")
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

"""Wireframe of a mesh's (local) bounding box."""
function BoxHelper(obj; color=Color3(1.0,1.0,0.0))
    box = compute_bounding_box(obj.geometry)
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
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="CameraHelper")
end

"""A single segment from a directional light's position toward its target."""
function DirectionalLightHelper(light::DirectionalLight; color=Color3(1.0,1.0,0.0))
    p = light.position; t = light.target
    LineSegments(_line_geo(Float64[p.x,p.y,p.z, t.x,t.y,t.z]),
                 LineBasicMaterial(color=color); name="DirectionalLightHelper")
end

"""Cross-hair lines marking a point light's position."""
function PointLightHelper(light::PointLight, size=0.5; color=Color3(1.0,1.0,0.0))
    p = light.position
    size = _geometry_finite_float(size, "PointLightHelper size")
    pos = Float64[p.x-size,p.y,p.z, p.x+size,p.y,p.z,
                  p.x,p.y-size,p.z, p.x,p.y+size,p.z,
                  p.x,p.y,p.z-size, p.x,p.y,p.z+size]
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="PointLightHelper")
end

# Append the two endpoints of a segment a→b to a flat position buffer.
@inline function _push_seg!(pos::Vector{Float64}, a::Vec3, b::Vec3)
    push!(pos, a.x, a.y, a.z, b.x, b.y, b.z)
    return pos
end

# Orthonormal basis (u, v) spanning the plane perpendicular to unit vector `w`.
function _perp_basis(w::Vec3)
    ref = abs(w.y) < 0.99 ? Vec3(0.0, 1.0, 0.0) : Vec3(1.0, 0.0, 0.0)
    u = normalize(cross(ref, w))
    v = cross(w, u)
    return u, v
end

"""
Cone outline of a spot light: the apex sits at the light position and the base
circle marks the cone of half-angle `light.angle` at the distance to the target
(three.js `SpotLightHelper`). Four apex-to-rim spokes plus the base ring.
"""
function SpotLightHelper(light::SpotLight; color=light.color, segments::Int=16)
    segments = _geometry_nonnegative_int(segments, "SpotLightHelper segments")
    apex = light.position
    axis = light.target - apex
    len = norm(axis)
    dir = len > 0 ? normalize(axis) : Vec3(0.0, -1.0, 0.0)
    len = len > 0 ? len : 1.0
    base = apex + dir * len
    r = len * tan(light.angle)              # cone base radius at the target plane
    u, v = _perp_basis(dir)
    total_segments = _geometry_checked_add(
        segments, 4, "SpotLightHelper segment count")
    pos = Vector{Float64}(
        undef, _helper_line_position_length(
            total_segments, "SpotLightHelper"))
    vi = 1
    # Base ring.
    prev = base + u * r
    for k in 1:segments
        φ = 2π * k / segments
        cur = base + (u * (r * cos(φ)) + v * (r * sin(φ)))
        vi = _write_line_segment!(pos, vi, prev, cur)
        prev = cur
    end
    # Four spokes from apex to the rim.
    for φ in (0.0, π/2, π, 3π/2)
        rim = base + (u * (r * cos(φ)) + v * (r * sin(φ)))
        vi = _write_line_segment!(pos, vi, apex, rim)
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="SpotLightHelper")
end

"""
Small octahedron wireframe at a hemisphere light's position, sized by `size`
(three.js `HemisphereLightHelper` uses a sphere/octahedron icon). The upper apex
takes the sky colour, the lower apex the ground colour, stored as a per-vertex
`:color` attribute.
"""
function HemisphereLightHelper(light::HemisphereLight, size=1.0; color=light.color)
    size = _geometry_finite_float(size, "HemisphereLightHelper size")
    p = light.position; s = size
    top = Vec3(p.x, p.y+s, p.z); bot = Vec3(p.x, p.y-s, p.z)
    px = Vec3(p.x+s, p.y, p.z); nx = Vec3(p.x-s, p.y, p.z)
    pz = Vec3(p.x, p.y, p.z+s); nz = Vec3(p.x, p.y, p.z-s)
    eq = (px, pz, nx, nz)
    pos = Vector{Float64}(undef, 72)
    vi = 1
    # Equator ring.
    for k in 1:4
        vi = _write_line_segment!(pos, vi, eq[k], eq[mod1(k+1, 4)])
    end
    # Spokes to the two apices.
    for e in eq
        vi = _write_line_segment!(pos, vi, top, e)
        vi = _write_line_segment!(pos, vi, bot, e)
    end
    geo = _line_geo(pos)
    sky = light.color; grd = light.ground_color
    cols = Vector{Float64}(undef, 72)
    blend = _stable_color_lerp(sky, grd, 0.5)
    # First 4 segments are the (mid-latitude) equator: blend; the remaining
    # spokes inherit the apex colour (sky for top spokes, ground for bottom).
    for seg in 1:12
        c = seg <= 4 ? blend : ((seg - 5) % 2 == 0 ? sky : grd)
        vi = 2seg - 1
        _write_line_color!(cols, vi, c)
        _write_line_color!(cols, vi + 1, c)
    end
    set_attribute!(geo, :color, cols, 3)
    LineSegments(geo, LineBasicMaterial(color=color); name="HemisphereLightHelper")
end

# World-space translation (column 4) of a 4×4 transform.
@inline _mat4_translation_vec(m::Mat4) =
    Vec3(mat4_get(m, 1, 4), mat4_get(m, 2, 4), mat4_get(m, 3, 4))

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
Line segments connecting each bone to its parent bone in world space
(three.js `SkeletonHelper`). Bones whose parent is not itself a bone in the
skeleton are skipped, matching three.js which only links bone-to-bone.
"""
function SkeletonHelper(skeleton::Skeleton; color=Color3(0.0, 0.0, 1.0))
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
            vi = _write_line_segment!(pos, vi, pw, cw)
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
            vi = _write_line_segment!(pos, vi, pw, cw)
        end
    end
    resize!(pos, 3 * (vi - 1))
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="SkeletonHelper")
end

"""Build a `SkeletonHelper` from the skeleton owned by a `SkinnedMesh`."""
SkeletonHelper(mesh::SkinnedMesh; color=Color3(0.0, 0.0, 1.0)) =
    SkeletonHelper(mesh.skeleton; color=color)

"""
Square outline lying in `plane` with side length `size`, plus a segment along the
plane normal from the plane's nearest point to the origin (three.js
`PlaneHelper`). The plane is `n·x + d = 0`; its representative point is `-d·n`.
"""
function PlaneHelper(plane::Plane, size=1.0; color=Color3(1.0, 1.0, 0.0))
    size = _geometry_finite_float(size, "PlaneHelper size")
    n = normalize(plane.normal)
    center = n * (-plane.constant)          # closest point to the origin on the plane
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
approximated by `circle_segments` chords each.
"""
function PolarGridHelper(radius=10.0, sectors::Int=16, rings::Int=8;
                         circle_segments::Int=64, color=Color3(0.5, 0.5, 0.5))
    radius = _geometry_finite_float(radius, "PolarGridHelper radius")
    sectors = _geometry_nonnegative_int(sectors, "PolarGridHelper sectors")
    rings = _geometry_nonnegative_int(rings, "PolarGridHelper rings")
    circle_segments = _geometry_nonnegative_int(
        circle_segments, "PolarGridHelper circle_segments")
    ring_segments = _geometry_checked_mul(
        rings, circle_segments, "PolarGridHelper segment count")
    n_segments = _geometry_checked_add(
        sectors, ring_segments, "PolarGridHelper segment count")
    pos = Vector{Float64}(
        undef, _helper_line_position_length(
            n_segments, "PolarGridHelper"))
    vi = 1
    # Radial spokes.
    for k in 0:sectors-1
        φ = 2π * k / sectors
        x = radius * cos(φ); z = radius * sin(φ)
        vi = _write_line_segment!(pos, vi, Vec3(0.0, 0.0, 0.0), Vec3(x, 0.0, z))
    end
    # Concentric rings.
    for ri in 1:rings
        r = radius * ri / rings
        prev = Vec3(r, 0.0, 0.0)
        for k in 1:circle_segments
            φ = 2π * k / circle_segments
            cur = Vec3(r * cos(φ), 0.0, r * sin(φ))
            vi = _write_line_segment!(pos, vi, prev, cur)
            prev = cur
        end
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="PolarGridHelper")
end
