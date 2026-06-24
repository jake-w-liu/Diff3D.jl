# --------------------------------------------------------------------------
# Controls, animation, and helpers (three.js examples/ counterparts), adapted
# for headless/programmatic use: camera manipulators, a Clock, keyframe
# animation, and line-based scene helpers.
# --------------------------------------------------------------------------

# ========================== Camera controls ==========================

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

# Positional/keyword constructors. The two original positional forms still work;
# damping and constraint fields are keyword-only with three.js-matching defaults.
function OrbitControls(cam::PerspectiveCamera, target::Vec3{Float64};
                       enabled::Bool=true, enable_rotate::Bool=true,
                       enable_zoom::Bool=true, enable_pan::Bool=true,
                       enable_damping::Bool=false, damping_factor::Real=0.05,
                       min_distance::Real=0.0, max_distance::Real=Inf,
                       min_polar_angle::Real=0.0, max_polar_angle::Real=π,
                       min_azimuth_angle::Real=-Inf, max_azimuth_angle::Real=Inf)
    min_distance <= max_distance ||
        throw(ArgumentError("min_distance must be <= max_distance"))
    min_polar_angle <= max_polar_angle ||
        throw(ArgumentError("min_polar_angle must be <= max_polar_angle"))
    min_azimuth_angle <= max_azimuth_angle ||
        throw(ArgumentError("min_azimuth_angle must be <= max_azimuth_angle"))
    OrbitControls(cam, target, enabled, enable_rotate, enable_zoom, enable_pan,
                  enable_damping, Float64(damping_factor),
                  Float64(min_distance), Float64(max_distance),
                  Float64(min_polar_angle), Float64(max_polar_angle),
                  Float64(min_azimuth_angle), Float64(max_azimuth_angle),
                  0.0, 0.0, 0.0, Vec3(0.0, 0.0, 0.0), cam.position, target)
end

function OrbitControls(camera::PerspectiveCamera, target::Vec3{Float64},
                       enable_damping::Bool, damping_factor::Real,
                       min_distance::Real, max_distance::Real,
                       min_polar_angle::Real, max_polar_angle::Real,
                       min_azimuth_angle::Real, max_azimuth_angle::Real,
                       v_azimuth::Real, v_polar::Real, v_zoom::Real,
                       v_pan::Vec3{Float64}, position0::Vec3{Float64},
                       target0::Vec3{Float64})
    OrbitControls(camera, target, true, true, true, true, enable_damping,
                  Float64(damping_factor), Float64(min_distance),
                  Float64(max_distance), Float64(min_polar_angle),
                  Float64(max_polar_angle), Float64(min_azimuth_angle),
                  Float64(max_azimuth_angle), Float64(v_azimuth),
                  Float64(v_polar), Float64(v_zoom), v_pan, position0, target0)
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
    oc.camera.position = oc.target + spherical_to_cartesian(_orbit_constrained(oc, s))
    oc.camera.target = oc.target
    return oc
end

"""Place the camera at an absolute orbit (azimuth, polar, radius) about the target."""
function orbit_set!(oc::OrbitControls; azimuth, polar, radius)
    _orbit_apply!(oc, Spherical(Float64(radius), Float64(polar), Float64(azimuth)))
end

"""Save the current camera position and target as the reset state."""
function orbit_save_state!(oc::OrbitControls)
    oc.position0 = oc.camera.position
    oc.target0 = oc.target
    return oc
end

"""Restore the saved orbit state and clear any damped residual motion."""
function orbit_reset!(oc::OrbitControls)
    oc.camera.position = oc.position0
    oc.target = oc.target0
    oc.camera.target = oc.target0
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
function _orbit_pan_basis(oc::OrbitControls)
    fwd = normalize(oc.target - oc.camera.position)
    raw_right = cross(fwd, oc.camera.up)
    if norm(raw_right) <= 1e-12
        candidate = abs(fwd.x) < 0.9 ? Vec3(1.0, 0.0, 0.0) : Vec3(0.0, 1.0, 0.0)
        raw_right = candidate - fwd * dot(candidate, fwd)
    end
    right = normalize(raw_right)
    up = normalize(cross(right, fwd))
    return right, up
end
function _orbit_pan_now!(oc::OrbitControls, dx, dy)
    right, up = _orbit_pan_basis(oc)
    shift = right * dx + up * dy
    oc.target = oc.target + shift
    oc.camera.position = oc.camera.position + shift
    oc.camera.target = oc.target
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
    if oc.enable_damping
        oc.v_azimuth += d_azimuth
        oc.v_polar += d_polar
        return oc
    end
    return _orbit_rotate_now!(oc, d_azimuth, d_polar)
end

"""
Scale the orbit radius (dolly). `factor < 1` zooms in.

With damping enabled the dolly accumulates as a residual log-scale velocity
consumed by `orbit_update!`; non-damped behaviour is unchanged.
"""
function orbit_zoom!(oc::OrbitControls, factor)
    (oc.enabled && oc.enable_zoom) || return oc
    if oc.enable_damping
        f = Float64(factor)
        # A multiplicative dolly factor must be positive; log() of a non-positive
        # factor would poison the residual with -Inf/NaN (sticking the controller
        # forever) or throw DomainError. Apply such an out-of-contract factor
        # immediately via the non-damped path, which clamps the resulting radius
        # into [min_distance, max_distance] — the same graceful handling the rest
        # of the controller uses.
        f > 0 || return _orbit_zoom_now!(oc, f)
        oc.v_zoom += log(f)
        return oc
    end
    return _orbit_zoom_now!(oc, factor)
end

"""
Pan the target (and camera) in the camera's right/up plane.

With damping enabled the pan offset accumulates as a residual world-space
velocity consumed by `orbit_update!`; non-damped behaviour is unchanged.
"""
function orbit_pan!(oc::OrbitControls, dx, dy)
    (oc.enabled && oc.enable_pan) || return oc
    if oc.enable_damping
        right, up = _orbit_pan_basis(oc)
        oc.v_pan = oc.v_pan + right * dx + up * dy
        return oc
    end
    return _orbit_pan_now!(oc, dx, dy)
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
        oc.target = oc.target + step
        oc.camera.position = oc.camera.position + step
        oc.camera.target = oc.target
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
    TrackballControls(cam, target, enabled, cam.position, target, cam.up)
end

"""Save the current camera position, up vector, and target as the reset state."""
function trackball_save_state!(tc::TrackballControls)
    tc.position0 = tc.camera.position
    tc.target0 = tc.target
    tc.up0 = tc.camera.up
    return tc
end

"""Restore the saved trackball state."""
function trackball_reset!(tc::TrackballControls)
    tc.camera.position = tc.position0
    tc.camera.up = tc.up0
    tc.target = tc.target0
    tc.camera.target = tc.target0
    return tc
end

function trackball_rotate!(tc::TrackballControls, dx, dy)
    tc.enabled || return tc
    oc = OrbitControls(tc.camera, tc.target)
    orbit_rotate!(oc, dx, dy)
    tc.target = oc.target
    tc.camera.target = tc.target
    return tc
end

"""Scale the camera distance from the trackball target. `factor < 1` zooms in."""
function trackball_zoom!(tc::TrackballControls, factor)
    tc.enabled || return tc
    oc = OrbitControls(tc.camera, tc.target)
    orbit_zoom!(oc, factor)
    tc.target = oc.target
    tc.camera.target = tc.target
    return tc
end

"""Pan the trackball target and camera in the view plane."""
function trackball_pan!(tc::TrackballControls, dx, dy)
    tc.enabled || return tc
    oc = OrbitControls(tc.camera, tc.target)
    orbit_pan!(oc, dx, dy)
    tc.target = oc.target
    tc.camera.target = tc.target
    tc.camera = oc.camera
    return tc
end

# FlyControls: first-person translation/rotation along the camera basis.
mutable struct FlyControls
    camera::PerspectiveCamera
end

"""Translate the camera (and its target) along forward/right/up axes."""
function fly_translate!(fc::FlyControls, forward, right, up)
    cam = fc.camera
    f = normalize(cam.target - cam.position)
    r = normalize(cross(f, cam.up))
    u = cross(r, f)
    shift = f * forward + r * right + u * up
    cam.position = cam.position + shift
    cam.target = cam.target + shift
    return fc
end

"""Yaw/pitch the camera in place (target orbits around the camera position)."""
function fly_rotate!(fc::FlyControls, yaw, pitch)
    cam = fc.camera
    dist = norm(cam.target - cam.position)
    dir = normalize(cam.target - cam.position)
    s = cartesian_to_spherical(dir)
    s2 = Spherical(1.0, clamp(s.phi - pitch, 1e-4, π - 1e-4), s.theta + yaw)
    cam.target = cam.position + spherical_to_cartesian(s2) * dist
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
    min_polar_angle <= max_polar_angle ||
        throw(ArgumentError("min_polar_angle must be <= max_polar_angle"))
    PointerLockControls(cam, false, Float64(pointer_speed),
                        Float64(min_polar_angle), Float64(max_polar_angle))
end

pointerlock_lock!(pc::PointerLockControls) = (pc.is_locked = true; pc)
pointerlock_unlock!(pc::PointerLockControls) = (pc.is_locked = false; pc)

function _pointerlock_direction_distance(cam::PerspectiveCamera)
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
    speed = pc.pointer_speed
    cam = pc.camera
    dir, dist = _pointerlock_direction_distance(cam)
    s = cartesian_to_spherical(dir)
    yaw = -Float64(movement_x) * 0.002 * speed
    pitch = -Float64(movement_y) * 0.002 * speed
    min_phi = max(pc.min_polar_angle, 1e-4)
    max_phi = min(pc.max_polar_angle, π - 1e-4)
    s2 = Spherical(1.0, clamp(s.phi - pitch, min_phi, max_phi), s.theta + yaw)
    cam.target = cam.position + spherical_to_cartesian(s2) * dist
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
    obj.position = obj.position + delta
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
    value = Float64(snap)
    isfinite(value) && value > 0 ||
        throw(ArgumentError("TransformControls $label snap must be finite and positive"))
    return value
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

_transform_axis_has(axis::Union{Nothing,Symbol}, label::Char) =
    axis !== nothing && occursin(string(label), String(axis))

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
    if tc.mode === :translate
        axis_delta = _transform_axis_vec(tc.axis, delta)
        move = tc.space === :local ? _transform_local_delta(obj, axis_delta) : axis_delta
        obj.position = obj.position + move
        tc.translation_snap !== nothing &&
            (obj.position = _transform_snap_position(obj.position, tc.translation_snap, tc.axis))
    elseif tc.mode === :scale
        factors = _transform_axis_vec(tc.axis, delta; default=1.0)
        obj.scale = Vec3(obj.scale.x * factors.x, obj.scale.y * factors.y, obj.scale.z * factors.z)
        tc.scale_snap !== nothing &&
            (obj.scale = _transform_snap_scale(obj.scale, tc.scale_snap, tc.axis))
    elseif tc.mode === :rotate
        angles = _transform_axis_vec(tc.axis, delta)
        if tc.rotation_snap !== nothing
            angles = Vec3(_transform_axis_has(tc.axis, 'X') ?
                          _transform_snap_value(angles.x, tc.rotation_snap) : angles.x,
                          _transform_axis_has(tc.axis, 'Y') ?
                          _transform_snap_value(angles.y, tc.rotation_snap) : angles.y,
                          _transform_axis_has(tc.axis, 'Z') ?
                          _transform_snap_value(angles.z, tc.rotation_snap) : angles.z)
        end
        obj.rotation = Euler(obj.rotation.x + angles.x, obj.rotation.y + angles.y,
                             obj.rotation.z + angles.z, obj.rotation.order)
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

clock_elapsed(c::Clock, now=time()) = now - c.start_time
function clock_delta!(c::Clock, now=time())
    d = now - c.last_time
    c.last_time = now
    return d
end

# ========================== Animation ==========================

abstract type AbstractKeyframeTrack end

function _validate_keyframe_times(kind::AbstractString, times::Vector{Float64})
    isempty(times) && throw(ArgumentError("$kind requires at least one keyframe"))
    for i in 2:length(times)
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

function _texture_animation_property_symbol(s::AbstractString)
    parts = split(String(s), ".")
    length(parts) == 2 || return nothing
    field = get(_TEXTURE_ANIMATION_FIELD_ALIASES, parts[1], nothing)
    property = get(_TEXTURE_ANIMATION_PROPERTY_ALIASES, parts[2], nothing)
    (field === nothing || property === nothing) && return nothing
    return Symbol(field * "_" * property)
end

function _animation_property_symbol(s::AbstractString)
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
    s in ("position", "scale", "rotation", "quaternion") && return Symbol(s)
    return Symbol(s)
end

function _parse_animation_property_path(path::AbstractString)
    p = startswith(path, ".") ? path[2:end] : String(path)
    material_path = startswith(p, "material.")
    material_path && (p = p[10:end])
    bracket = match(r"^(.+)\[([^\]]+)\]$", p)
    if bracket !== nothing
        return _animation_property_symbol(bracket.captures[1]),
               _animation_component_index(bracket.captures[2])
    end
    dot = match(r"^(.+)\.([A-Za-z])$", p)
    if dot !== nothing
        return _animation_property_symbol(dot.captures[1]),
               _animation_component_index(dot.captures[2])
    end
    material_path && p == "rotation" && return :material_rotation, 0
    return _animation_property_symbol(p), 0
end

function _parse_animation_whole_property_path(path::AbstractString,
                                              track_type::AbstractString)
    property, component = _parse_animation_property_path(path)
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
                  _parse_animation_whole_property_path(property_path, "KeyframeTrack"),
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
    property, component = _parse_animation_property_path(property_path)
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
                            _parse_animation_whole_property_path(property_path,
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
    property = _parse_animation_whole_property_path(property_path,
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
        new(target, property, times, values, in_tangents, out_tangents)
    end
end

CubicSplineKeyframeTrack(target::AbstractObject3D, property_path::AbstractString,
                         times::Vector{Float64}, values::Vector{Vec3{Float64}},
                         in_tangents::Vector{Vec3{Float64}},
                         out_tangents::Vector{Vec3{Float64}}) =
    CubicSplineKeyframeTrack(target,
                             _parse_animation_whole_property_path(property_path,
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
                                           property_path,
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
                                             property_path,
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
    n = length(times)
    @assert n == length(values) && n >= 1 "times and values must align and be non-empty"
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
    tr.interpolation === :step && return values[lo]
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

"""
    sample_track(track, t)

Interpolated value of a keyframe `track` at absolute time `t`, using the track's
own interpolation mode (linear, Catmull-Rom cubic, or quaternion slerp). Returns a
`Vec3` for property tracks and a `Quaternion` for a `QuaternionKeyframeTrack`.
"""
sample_track(track::AbstractKeyframeTrack, t) = _track_value(track, t)

# Quaternion → Euler (intrinsic XYZ order, matching the default `Euler`).
# Mirrors three.js `Euler.setFromQuaternion` for order XYZ.
function _quat_to_euler_xyz(q::Quaternion)
    qn = quat_normalize(q)
    x, y, z, w = qn.x, qn.y, qn.z, qn.w
    m13 = 2*(x*z + w*y)
    m13c = clamp(m13, -one(m13), one(m13))
    ey = asin(m13c)
    if abs(m13) < 0.9999999
        m23 = 2*(y*z - w*x)
        m33 = 1 - 2*(x*x + y*y)
        m12 = 2*(x*y - w*z)
        m11 = 1 - 2*(y*y + z*z)
        ex = atan(-m23, m33)
        ez = atan(-m12, m11)
    else                                   # gimbal lock
        m32 = 2*(y*z + w*x)
        m22 = 1 - 2*(x*x + z*z)
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

function AnimationClip(name::String, duration::Real,
                       tracks::AbstractVector{<:AbstractKeyframeTrack};
                       loop::Symbol=:repeat,
                       repetitions::Integer=-1,
                       clamp_when_finished::Bool=false,
                       time_scale::Real=1.0)
    AnimationClip(name, Float64(duration), collect(AbstractKeyframeTrack, tracks),
                  _animation_loop_mode(loop), Int(repetitions),
                  clamp_when_finished, Float64(time_scale))
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
                   repetitions === nothing ? clip.repetitions : Int(repetitions),
                   clamp_when_finished === nothing ? clip.clamp_when_finished : clamp_when_finished,
                   time_scale === nothing ? clip.time_scale : Float64(time_scale))
end

function _animation_loop_time(t::Real, duration::Real, loop::Symbol,
                              repetitions::Int, clamp_when_finished::Bool)
    d = Float64(duration)
    d <= 0.0 && return 0.0
    x = Float64(t)
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
    names = fieldnames(typeof(x))
    vals = map(names) do name
        current = getproperty(x, name)
        name === property ? (current isa Bool && value isa Real ? value >= 0.5 : value) : current
    end
    return typeof(x)(vals...)
end

_material_animation_property(property::Symbol) =
    property === :material_rotation ? :rotation : property

function _write_material_track_value!(target, property::Symbol, value)
    hasproperty(target, :material) || return false
    mat = getproperty(target, :material)
    property = _material_animation_property(property)
    newmat = _replace_field_value(mat, property, value)
    newmat === nothing && return false
    setproperty!(target, :material, newmat)
    return true
end

function _write_material_track_value!(target, property::Symbol, component::Int, value::Real)
    hasproperty(target, :material) || return false
    mat = getproperty(target, :material)
    property = _material_animation_property(property)
    hasproperty(mat, property) || return false
    current = getproperty(mat, property)
    newmat = _replace_field_value(mat, property, _with_component(current, component, value))
    newmat === nothing && return false
    setproperty!(target, :material, newmat)
    return true
end

function _split_texture_track_property(property::Symbol)
    name = String(property)
    for field in _TEXTURE_ANIMATION_FIELDS
        prefix = String(field) * "_"
        startswith(name, prefix) || continue
        texture_property = Symbol(name[(lastindex(prefix) + 1):end])
        texture_property in (:offset, :repeat, :center, :rotation, :matrix_auto_update) ||
            return nothing
        return field, texture_property
    end
    return nothing
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

function _write_morph_component!(target, property::Symbol, component::Int, v::Real)
    wrote = false
    function write_one!(obj)
        hasproperty(obj, property) || return false
        values = copy(getproperty(obj, property))
        1 <= component <= length(values) ||
            throw(ArgumentError("morph influence component $(component - 1) is out of range"))
        values[component] = Float64(v)
        setproperty!(obj, property, values)
        return true
    end
    wrote |= write_one!(target)
    traverse(target, obj -> obj !== target && (wrote |= write_one!(obj)))
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
function _write_track_value!(target, property::Symbol, v::Vector{Float64})
    if property === :morph_target_influences
        wrote = false
        if hasproperty(target, property)
            setproperty!(target, property, copy(v))
            wrote = true
        end
        traverse(target, child -> begin
            child === target && return
            if hasproperty(child, property)
                setproperty!(child, property, copy(v))
                wrote = true
            end
        end)
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

"""Sample the clip at absolute time `t` and write each track's value to its target."""
function mixer_set_time!(mixer::AnimationMixer, t)
    mixer.time = Float64(t)
    sample_time = _animation_loop_time(mixer.time * mixer.time_scale,
                                       mixer.clip.duration,
                                       mixer.loop,
                                       mixer.repetitions,
                                       mixer.clamp_when_finished)
    for tr in mixer.clip.tracks
        v = _track_value(tr, sample_time)
        _write_track!(tr, v)
    end
    return mixer
end

mixer_update!(mixer::AnimationMixer, dt) = mixer_set_time!(mixer, mixer.time + dt)

# ========================== Helpers ==========================

_line_geo(positions::Vector{Float64}) =
    BufferGeometry(positions, Float64[], Float64[], collect(1:length(positions)÷3),
                   length(positions) ÷ 3, 0)

"""Diff3D line segments along +x (red), +y (green), +z (blue)."""
function AxesHelper(size=1.0)
    pos = Float64[0,0,0, size,0,0,  0,0,0, 0,size,0,  0,0,0, 0,0,size]
    geo = _line_geo(pos)
    set_attribute!(geo, :color, Float64[1,0,0, 1,0,0,  0,1,0, 0,1,0,  0,0,1, 0,0,1], 3)
    LineSegments(geo, LineBasicMaterial(color=Color3(1.0,1.0,1.0)); name="AxesHelper")
end

"""A `divisions`×`divisions` grid of size `size` on the xz-plane."""
function GridHelper(size=10.0, divisions=10; color=Color3(0.5,0.5,0.5))
    pos = Float64[]
    step = size / divisions; half = size / 2
    for i in 0:divisions
        c = -half + i*step
        append!(pos, [c,0,-half, c,0,half])     # parallel to z
        append!(pos, [-half,0,c, half,0,c])     # parallel to x
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="GridHelper")
end

# 12 edges of an axis-aligned box given as min/max corners.
function _box_edges(mn::Vec3, mx::Vec3)
    c = [Vec3(mn.x,mn.y,mn.z), Vec3(mx.x,mn.y,mn.z), Vec3(mx.x,mx.y,mn.z), Vec3(mn.x,mx.y,mn.z),
         Vec3(mn.x,mn.y,mx.z), Vec3(mx.x,mn.y,mx.z), Vec3(mx.x,mx.y,mx.z), Vec3(mn.x,mx.y,mx.z)]
    edges = [(1,2),(2,3),(3,4),(4,1), (5,6),(6,7),(7,8),(8,5), (1,5),(2,6),(3,7),(4,8)]
    pos = Float64[]
    for (a,b) in edges
        append!(pos, [c[a].x,c[a].y,c[a].z, c[b].x,c[b].y,c[b].z])
    end
    return pos
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
    c = [corner(-1,-1,-1), corner(1,-1,-1), corner(1,1,-1), corner(-1,1,-1),
         corner(-1,-1, 1), corner(1,-1, 1), corner(1,1, 1), corner(-1,1, 1)]
    edges = [(1,2),(2,3),(3,4),(4,1), (5,6),(6,7),(7,8),(8,5), (1,5),(2,6),(3,7),(4,8)]
    pos = Float64[]
    for (a,b) in edges
        append!(pos, [c[a].x,c[a].y,c[a].z, c[b].x,c[b].y,c[b].z])
    end
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
    apex = light.position
    axis = light.target - apex
    len = norm(axis)
    dir = len > 0 ? normalize(axis) : Vec3(0.0, -1.0, 0.0)
    len = len > 0 ? len : 1.0
    base = apex + dir * len
    r = len * tan(light.angle)              # cone base radius at the target plane
    u, v = _perp_basis(dir)
    pos = Float64[]
    # Base ring.
    prev = base + u * r
    for k in 1:segments
        φ = 2π * k / segments
        cur = base + (u * (r * cos(φ)) + v * (r * sin(φ)))
        _push_seg!(pos, prev, cur)
        prev = cur
    end
    # Four spokes from apex to the rim.
    for φ in (0.0, π/2, π, 3π/2)
        rim = base + (u * (r * cos(φ)) + v * (r * sin(φ)))
        _push_seg!(pos, apex, rim)
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
    p = light.position; s = size
    top = Vec3(p.x, p.y+s, p.z); bot = Vec3(p.x, p.y-s, p.z)
    px = Vec3(p.x+s, p.y, p.z); nx = Vec3(p.x-s, p.y, p.z)
    pz = Vec3(p.x, p.y, p.z+s); nz = Vec3(p.x, p.y, p.z-s)
    eq = (px, pz, nx, nz)
    pos = Float64[]
    # Equator ring.
    for k in 1:4
        _push_seg!(pos, eq[k], eq[mod1(k+1, 4)])
    end
    # Spokes to the two apices.
    for e in eq
        _push_seg!(pos, top, e)
        _push_seg!(pos, bot, e)
    end
    geo = _line_geo(pos)
    sky = light.color; grd = light.ground_color
    cols = Float64[]
    nseg = length(pos) ÷ 6
    # First 4 segments are the (mid-latitude) equator: blend; the remaining
    # spokes inherit the apex colour (sky for top spokes, ground for bottom).
    for seg in 1:nseg
        if seg <= 4
            for _ in 1:2; push!(cols, (sky.r+grd.r)/2, (sky.g+grd.g)/2, (sky.b+grd.b)/2); end
        elseif (seg - 5) % 2 == 0          # top-apex spoke
            push!(cols, sky.r, sky.g, sky.b, sky.r, sky.g, sky.b)
        else                                # bottom-apex spoke
            push!(cols, grd.r, grd.g, grd.b, grd.r, grd.g, grd.b)
        end
    end
    set_attribute!(geo, :color, cols, 3)
    LineSegments(geo, LineBasicMaterial(color=color); name="HemisphereLightHelper")
end

# World-space translation (column 4) of a 4×4 transform.
@inline _mat4_translation_vec(m::Mat4) =
    Vec3(mat4_get(m, 1, 4), mat4_get(m, 2, 4), mat4_get(m, 3, 4))

"""
Line segments connecting each bone to its parent bone in world space
(three.js `SkeletonHelper`). Bones whose parent is not itself a bone in the
skeleton are skipped, matching three.js which only links bone-to-bone.
"""
function SkeletonHelper(skeleton::Skeleton; color=Color3(0.0, 0.0, 1.0))
    boneset = Set(objectid(b) for b in skeleton.bones)
    pos = Float64[]
    for bone in skeleton.bones
        par = get_parent(bone)
        (par isa Bone && objectid(par) in boneset) || continue
        cw = _mat4_translation_vec(compute_world_matrix(bone))
        pw = _mat4_translation_vec(compute_world_matrix(par))
        _push_seg!(pos, pw, cw)
    end
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
    n = normalize(plane.normal)
    center = n * (-plane.constant)          # closest point to the origin on the plane
    u, v = _perp_basis(n)
    h = size / 2
    c1 = center + (u *  h + v *  h)
    c2 = center + (u * -h + v *  h)
    c3 = center + (u * -h + v * -h)
    c4 = center + (u *  h + v * -h)
    pos = Float64[]
    _push_seg!(pos, c1, c2); _push_seg!(pos, c2, c3)
    _push_seg!(pos, c3, c4); _push_seg!(pos, c4, c1)
    _push_seg!(pos, center, center + n * h) # normal indicator
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="PlaneHelper")
end

"""
Polar grid on the xz-plane: `rings` concentric circles out to `radius` and
`sectors` evenly spaced radial spokes (three.js `PolarGridHelper`). Circles are
approximated by `circle_segments` chords each.
"""
function PolarGridHelper(radius=10.0, sectors::Int=16, rings::Int=8;
                         circle_segments::Int=64, color=Color3(0.5, 0.5, 0.5))
    pos = Float64[]
    # Radial spokes.
    for k in 0:sectors-1
        φ = 2π * k / sectors
        x = radius * cos(φ); z = radius * sin(φ)
        _push_seg!(pos, Vec3(0.0, 0.0, 0.0), Vec3(x, 0.0, z))
    end
    # Concentric rings.
    for ri in 1:rings
        r = radius * ri / rings
        prev = Vec3(r, 0.0, 0.0)
        for k in 1:circle_segments
            φ = 2π * k / circle_segments
            cur = Vec3(r * cos(φ), 0.0, r * sin(φ))
            _push_seg!(pos, prev, cur)
            prev = cur
        end
    end
    LineSegments(_line_geo(pos), LineBasicMaterial(color=color); name="PolarGridHelper")
end
