using Test, Diff3D

@testset "anim audit: one-sided azimuth limit leaves azimuth free" begin
    # three.js OrbitControls.update restricts theta only when both
    # minAzimuthAngle and maxAzimuthAngle are finite.
    for kwargs in ((; max_azimuth_angle=0.5), (; min_azimuth_angle=-0.5))
        cam = PerspectiveCamera()
        cam.position = Vec3(0.0, 0.0, 5.0)
        cam.target = Vec3(0.0, 0.0, 0.0)
        oc = OrbitControls(cam; kwargs...)
        orbit_rotate!(oc, 2.0, 0.0)
        @test Diff3D._orbit_spherical(oc).theta ≈ 2.0
        orbit_rotate!(oc, -4.0, 0.0)
        @test Diff3D._orbit_spherical(oc).theta ≈ -2.0
    end
    @test Diff3D._clamp_azimuth(2.0, -Inf, 0.5) == 2.0
    @test Diff3D._clamp_azimuth(-2.0, -0.5, Inf) == -2.0
    @test Diff3D._clamp_azimuth(2.0, -0.5, 0.5) == 0.5
end

# Reference port of three.js r186 AnimationAction._updateTime (+ the paused /
# disabled handling in AnimationAction._update) for repeat/pingpong loops.
# Returns the sampled clip time, or `nothing` once the action is disabled.
mutable struct _AnimAuditRefAction
    time::Float64
    loop_count::Int
    paused::Bool
    enabled::Bool
end

function _anim_audit_ref_update!(a::_AnimAuditRefAction, dt, d, loop, reps, clamp)
    a.enabled || return nothing
    a.paused && (dt = 0.0)
    repetitions = reps < 0 ? Inf : reps
    pingpong = loop === :pingpong
    time = a.time + dt
    loop_count = a.loop_count
    if dt == 0.0
        loop_count == -1 && return time
        return pingpong && isodd(loop_count) ? d - time : time
    end
    if loop_count == -1 && dt >= 0
        loop_count = 0
    end
    if time >= d || time < 0
        loop_delta = floor(time / d)
        time -= d * loop_delta
        loop_count += Int(abs(loop_delta))
        if repetitions - loop_count <= 0
            clamp ? (a.paused = true) : (a.enabled = false)
            time = dt > 0 ? d : 0.0
            a.time = time
        else
            a.loop_count = loop_count
            a.time = time
        end
    else
        a.loop_count = loop_count
        a.time = time
    end
    a.enabled || return nothing
    return pingpong && isodd(loop_count) ? d - time : time
end

@testset "anim audit: repeat/pingpong loop time matches three.js" begin
    for (d, dt) in ((1.0, 0.25), (1.5, 0.375)), loop in (:repeat, :pingpong),
        reps in (-1, 0, 1, 2, 3), clamp in (true, false), sign in (1.0, -1.0)
        ref = _AnimAuditRefAction(0.0, -1, false, true)
        x = 0.0
        for _ in 1:40
            was_running = !ref.paused && ref.enabled
            expected = _anim_audit_ref_update!(ref, sign * dt, d, loop, reps, clamp)
            x += sign * dt
            actual = Diff3D._animation_loop_time(x, d, loop, reps, clamp)
            # Skip the single transient frame on which three.js finishes (its
            # local loop count differs from the persisted one) and the disabled
            # state, where Diff3D documents a reset to the first frame.
            was_running && (ref.paused || !ref.enabled) && continue
            expected === nothing && continue
            @test actual ≈ expected atol=1e-12
        end
    end
end

@testset "anim audit: finite backward playback terminates" begin
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial())
    tr = KeyframeTrack(mesh, :position, [0.0, 1.0], [Vec3(0.0, 0, 0), Vec3(5.0, 0, 0)])
    m = AnimationMixer(AnimationClip("bk", [tr]; repetitions=1, clamp_when_finished=true);
                       time_scale=-1.0)
    mixer_update!(m, 0.5)
    @test mesh.position.x ≈ 2.5
    mixer_update!(m, 0.5)
    @test mesh.position.x ≈ 0.0
    for _ in 1:4
        mixer_update!(m, 0.5)
        @test mesh.position.x == 0.0
    end
end

@testset "anim audit: repeat samples the first frame at exact loop multiples" begin
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial())
    tr = KeyframeTrack(mesh, :position, [0.0, 1.0], [Vec3(0.0, 0, 0), Vec3(5.0, 0, 0)])
    m = AnimationMixer(AnimationClip("r", [tr]))
    for t in (1.0, 2.0, 3.0)
        mixer_set_time!(m, t)
        @test mesh.position.x == 0.0
    end
    mixer_set_time!(AnimationMixer(AnimationClip("once", [tr]; loop=:once,
                                                 clamp_when_finished=true)), 1.0)
    @test mesh.position.x == 5.0
    mixer_set_time!(AnimationMixer(AnimationClip("fin", [tr]; repetitions=1,
                                                 clamp_when_finished=true)), 1.0)
    @test mesh.position.x == 5.0
    # repetitions=0 plays one forward loop, like three.js.
    mixer_set_time!(AnimationMixer(AnimationClip("zero", [tr]; repetitions=0)), 0.5)
    @test mesh.position.x ≈ 2.5
end

@testset "anim audit: first-person controls drive rotation-driven cameras" begin
    function camera_pair()
        rc = PerspectiveCamera(rotation_driven=true)
        rc.position = Vec3(1.0, 2.0, 5.0)
        rc.rotation = Euler(0.2, 0.4, 0.0, :YXZ)
        plain = PerspectiveCamera()
        plain.position = rc.position
        plain.target = Diff3D._camera_control_target(rc)
        plain.up = Vec3(0.0, 1.0, 0.0)
        @test collect(view_matrix(rc).e) ≈ collect(view_matrix(plain).e) atol=1e-9
        return rc, plain
    end
    rc, plain = camera_pair()
    before = view_matrix(rc)
    fly_rotate!(FlyControls(rc), 0.5, 0.1)
    fly_rotate!(FlyControls(plain), 0.5, 0.1)
    @test view_matrix(rc) != before
    @test collect(view_matrix(rc).e) ≈ collect(view_matrix(plain).e) atol=1e-9
    fly_translate!(FlyControls(rc), 1.0, 0.5, 0.25)
    fly_translate!(FlyControls(plain), 1.0, 0.5, 0.25)
    @test collect(view_matrix(rc).e) ≈ collect(view_matrix(plain).e) atol=1e-9

    rc, plain = camera_pair()
    before = view_matrix(rc)
    for cam in (rc, plain)
        pc = PointerLockControls(cam)
        pointerlock_lock!(pc)
        pointerlock_move!(pc, 120.0, -40.0)
    end
    @test view_matrix(rc) != before
    @test collect(view_matrix(rc).e) ≈ collect(view_matrix(plain).e) atol=1e-9

    # Rejected input leaves a rotation-driven camera untouched.
    rc, _ = camera_pair()
    snapshot = (rc.position, rc.target, rc.up, rc.rotation)
    @test_throws ArgumentError fly_rotate!(FlyControls(rc), NaN, 0.0)
    @test_throws ArgumentError fly_translate!(FlyControls(rc), Inf, 0.0, 0.0)
    @test (rc.position, rc.target, rc.up, rc.rotation) == snapshot
end

@testset "anim audit: quaternion tracks keep the target Euler order" begin
    # three.js Object3D: quaternion changes update rotation via
    # rotation.setFromQuaternion(quaternion, undefined), i.e. the current order.
    g = Group()
    g.rotation = Euler(0.1, 0.2, 0.3, :YXZ)
    q1 = quat_from_euler(0.4, -0.7, 0.2; order=:ZYX)
    qt = QuaternionKeyframeTrack(g, :quaternion, [0.0, 1.0], [Quaternion(), q1])
    mixer_set_time!(AnimationMixer(AnimationClip("q", [qt])), 0.5)
    @test g.rotation.order === :YXZ
    expected = sample_track(qt, 0.5)
    actual = quat_from_euler(g.rotation.x, g.rotation.y, g.rotation.z; order=:YXZ)
    @test abs(quat_dot(actual, expected)) ≈ 1.0 atol=1e-12

    h = Group()
    h.rotation = Euler(0.0, 0.0, 0.0, :ZXY)
    ny = NumberKeyframeTrack(h, "quaternion.y", [0.0, 1.0], [0.0, sin(pi / 8)])
    mixer_set_time!(AnimationMixer(AnimationClip("qy", [ny])), 0.5)
    @test h.rotation.order === :ZXY
end

_anim_v3(v) = [v.x, v.y, v.z]

@testset "anim audit: MapControls pans across the ground plane" begin
    function tilted_camera()
        cam = PerspectiveCamera()
        cam.position = Vec3(0.0, 10.0, 10.0)
        cam.target = Vec3(0.0, 0.0, 0.0)
        return cam
    end
    # three.js MapControls sets screenSpacePanning=false: panUp moves along
    # cross(camera.up, cameraRight), keeping the target height.
    mc = MapControls(tilted_camera())
    @test mc isa OrbitControls
    @test !mc.screen_space_panning
    orbit_pan!(mc, 0.0, 2.0)
    @test _anim_v3(mc.target) ≈ [0.0, 0.0, -2.0]
    @test _anim_v3(mc.camera.position) ≈ [0.0, 10.0, 8.0]
    orbit_pan!(mc, 3.0, 0.0)
    @test _anim_v3(mc.target) ≈ [3.0, 0.0, -2.0]

    oc = OrbitControls(tilted_camera())
    @test oc.screen_space_panning
    orbit_pan!(oc, 0.0, 2.0)
    @test _anim_v3(oc.target) ≈ [0.0, sqrt(2.0), -sqrt(2.0)]

    damped = MapControls(tilted_camera(), Vec3(0.0, 0.0, 0.0);
                         enable_damping=true, damping_factor=0.5)
    orbit_pan!(damped, 0.0, 2.0)
    for _ in 1:80
        orbit_update!(damped)
    end
    @test _anim_v3(damped.target) ≈ [0.0, 0.0, -2.0] atol=1e-8
    @test MapControls(tilted_camera(); screen_space_panning=true).screen_space_panning
end

@testset "anim audit: CameraHelper rejects an unbounded frustum clearly" begin
    @test CameraHelper(PerspectiveCamera(far=100.0)).geometry.n_vertices == 24
    @test_throws "CameraHelper requires a camera with a finite, invertible frustum" CameraHelper(
        PerspectiveCamera(far=Inf))
end

@testset "anim audit: OrbitControls polar clamp follows Spherical.makeSafe" begin
    function orbit_cam()
        cam = PerspectiveCamera()
        cam.position = Vec3(0.0, 0.0, 5.0)
        cam.target = Vec3(0.0, 0.0, 0.0)
        return cam
    end
    oc = OrbitControls(orbit_cam())
    orbit_set!(oc; azimuth=0.0, polar=0.0, radius=5.0)
    @test Diff3D._orbit_spherical(oc).phi ≈ 1e-6 rtol=1e-3
    orbit_set!(oc; azimuth=0.0, polar=pi, radius=5.0)
    @test Diff3D._orbit_spherical(oc).phi ≈ pi - 1e-6 atol=1e-9
    # A zero-width window at the pole still keeps the camera off the axis.
    pinned = OrbitControls(orbit_cam(); min_polar_angle=0.0, max_polar_angle=0.0)
    orbit_rotate!(pinned, 0.0, 0.3)
    @test Diff3D._orbit_spherical(pinned).phi ≈ 1e-6 rtol=1e-3
    @test all(isfinite, collect(view_matrix(pinned.camera).e))
end

@testset "anim audit: BoxHelper and HemisphereLightHelper use world space" begin
    _corners(h) = (p = h.geometry.positions;
                   ([minimum(p[1:3:end]), minimum(p[2:3:end]), minimum(p[3:3:end])],
                    [maximum(p[1:3:end]), maximum(p[2:3:end]), maximum(p[3:3:end])]))
    # three.js BoxHelper: Box3.setFromObject (world transforms, descendants).
    root = Group()
    root.position = Vec3(10.0, 0.0, 0.0)
    root.scale = Vec3(2.0, 2.0, 2.0)
    mesh = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0), MeshBasicMaterial())
    mesh.position = Vec3(0.0, 1.0, 0.0)
    mesh.rotation = Euler(0.0, pi / 4, 0.0)
    add!(root, mesh)
    lo, hi = _corners(BoxHelper(mesh))
    r = sqrt(2.0) / 2 * 2
    @test lo ≈ [10.0 - r, 1.0, -r] atol=1e-12
    @test hi ≈ [10.0 + r, 3.0, r] atol=1e-12
    other = Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0), MeshBasicMaterial())
    other.position = Vec3(0.0, -3.0, 0.0)
    add!(root, other)
    lo, hi = _corners(BoxHelper(root))
    @test lo ≈ [10.0 - r, -7.0, -r] atol=1e-12
    @test hi ≈ [10.0 + r, 3.0, r] atol=1e-12
    inst = InstancedMesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                         MeshBasicMaterial(), 2)
    set_instance_matrix!(inst, 1, mat4_translation(-4.0, 0.0, 0.0))
    set_instance_matrix!(inst, 2, mat4_translation(5.0, 0.0, 0.0))
    lo, hi = _corners(BoxHelper(inst))
    @test lo ≈ [-4.5, -0.5, -0.5]
    @test hi ≈ [5.5, 0.5, 0.5]
    @test_throws ArgumentError BoxHelper(Group())

    rig = Group()
    rig.position = Vec3(0.0, 5.0, 0.0)
    hemi = HemisphereLight()
    hemi.position = Vec3(1.0, 0.0, 0.0)
    add!(rig, hemi)
    lo, hi = _corners(HemisphereLightHelper(hemi, 1.0))
    @test (lo .+ hi) ./ 2 ≈ [1.0, 5.0, 0.0]
end
