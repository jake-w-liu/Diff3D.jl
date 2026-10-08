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
