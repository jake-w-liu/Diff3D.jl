using Test, Diff3D

@testset "OrbitControls damped dolly cannot overflow exp()" begin
    # A queued log-dolly whose exp() overflows used to make every later
    # orbit_update! throw ("camera position must be finite") forever. The
    # residual now saturates at log(floatmax) and a residual whose complete
    # dolly leaves the representable range is rejected when it is queued,
    # exactly as the immediate path rejects the same factor.
    for f in (1.0, 0.05)
        cam = PerspectiveCamera(fov=π / 4, aspect=1.0)
        cam.position = Vec3(0.0, 0.0, 5.0)
        oc = OrbitControls(cam, Vec3(0.0, 0.0, 0.0); enable_damping=true,
                           damping_factor=f)
        orbit_zoom!(oc, 1e300)
        v = oc.v_zoom
        @test_throws ArgumentError orbit_zoom!(oc, 1e300)
        @test oc.v_zoom == v                      # state untouched by the rejection
        for _ in 1:30
            orbit_update!(oc)
            @test all(isfinite, (cam.position.x, cam.position.y, cam.position.z))
        end
        # The immediate (undamped) path rejects the same overflowing factor.
        cam2 = PerspectiveCamera(fov=π / 4, aspect=1.0)
        cam2.position = Vec3(0.0, 0.0, 5.0)
        @test_throws ArgumentError orbit_zoom!(OrbitControls(cam2, Vec3(0.0, 0.0, 0.0)), 1e308)
    end
    # A finite max_distance makes any outward dolly representable: it clamps.
    cam = PerspectiveCamera(fov=π / 4, aspect=1.0)
    cam.position = Vec3(0.0, 0.0, 5.0)
    oc = OrbitControls(cam, Vec3(0.0, 0.0, 0.0); enable_damping=true,
                       damping_factor=1.0, max_distance=100.0)
    for _ in 1:3
        orbit_zoom!(oc, 1e308)
    end
    @test abs(oc.v_zoom) <= log(floatmax(Float64))
    orbit_update!(oc)
    @test cam.position.z ≈ 100.0
    # Orthographic: zoom / exp(residual) stays positive and finite.
    ocam = OrthographicCamera()
    ocam.position = Vec3(0.0, 0.0, 5.0)
    oo = OrbitControls(ocam, Vec3(0.0, 0.0, 0.0); enable_damping=true,
                       damping_factor=1.0)
    for _ in 1:3
        orbit_zoom!(oo, 1e308)
    end
    for _ in 1:3
        orbit_update!(oo)
        @test isfinite(ocam.zoom) && ocam.zoom > 0.0
    end
    ocam = OrthographicCamera()
    ocam.position = Vec3(0.0, 0.0, 5.0)
    oo = OrbitControls(ocam, Vec3(0.0, 0.0, 0.0); enable_damping=true,
                       damping_factor=1.0, min_zoom=0.1, max_zoom=10.0)
    for _ in 1:3
        orbit_zoom!(oo, 1e-308)
    end
    orbit_update!(oo)
    @test ocam.zoom == 10.0
end

@testset "Clock honours running, start and stop like three.js Clock" begin
    # Oracle: three.js r186 src/core/Clock.js driven by a fake performance.now
    # (ms); sequence start@1000, delta@1016, delta@1150, stop@1300, delta@1400,
    # start@2000, delta@2250, stop@2500, delta@2600 gives deltas
    # 0.016, (0.134), 0, 0.25, 0 and elapsed 0.3 after the first stop.
    c = Clock(false)
    @test !c.running && !c.auto_start
    @test clock_delta!(c, 0.7) == 0.0              # Clock(false): not started
    Diff3D.clock_start!(c, 1.0)
    @test clock_delta!(c, 1.016) ≈ 0.016 atol = 1e-12
    @test clock_elapsed(c, 1.1) ≈ 0.1 atol = 1e-12   # does not consume the delta
    @test clock_delta!(c, 1.15) ≈ 0.134 atol = 1e-12
    Diff3D.clock_stop!(c, 1.3)
    @test !c.running && !c.auto_start
    @test c.elapsed_time ≈ 0.3 atol = 1e-12          # three.js 0.30000000000000004
    @test clock_delta!(c, 1.4) == 0.0                # stopped: Clock.js getDelta
    @test clock_elapsed(c, 1.5) ≈ 0.3 atol = 1e-12   # frozen while stopped
    Diff3D.clock_start!(c, 2.0)
    @test c.elapsed_time == 0.0
    @test clock_delta!(c, 2.25) ≈ 0.25 atol = 1e-12
    Diff3D.clock_stop!(c, 2.5)
    @test c.elapsed_time ≈ 0.5 atol = 1e-12
    @test clock_delta!(c, 2.6) == 0.0
    # A stopped clock that still auto-starts restarts on getDelta and returns 0.
    a = Clock(10.0, 10.0, false)
    @test clock_delta!(a, 12.0) == 0.0
    @test a.running && a.start_time == 12.0 && a.elapsed_time == 0.0
    @test clock_delta!(a, 12.5) == 0.5
    # The 1.0 constructors keep their meaning.
    d = Clock()
    @test d.running && d.auto_start && d.start_time == d.last_time
    @test clock_elapsed(d, d.start_time + 2.0) ≈ 2.0
    injected = Clock(10.0, 10.0, true)
    @test clock_elapsed(injected, 12.5) == 2.5
    @test clock_delta!(injected, 10.25) == 0.25
    @test_throws ArgumentError Diff3D.clock_start!(Clock(), NaN)
end

@testset "FrameTimer follows three.js Timer" begin
    # Oracle: three.js r186 src/core/Timer.js with performance.now() = 1000 ms
    # at construction; update@1016, update@1050, setTimescale(2), update@1100,
    # reset@1500, update@1520, setTimescale(0.5), update@1600 gives
    # [delta, elapsed] = [0.016,0.016], [0.034,0.05], [0.1,0.15], [0.04,0.19],
    # [0.04,0.23].
    t = Diff3D.FrameTimer(1.0)
    @test Diff3D.timer_delta(t) == 0.0 && Diff3D.timer_elapsed(t) == 0.0
    expected = [(0.016, 0.016), (0.034, 0.05), (0.1, 0.15), (0.04, 0.19), (0.04, 0.23)]
    got = Tuple{Float64,Float64}[]
    Diff3D.timer_update!(t, 1.016); push!(got, (Diff3D.timer_delta(t), Diff3D.timer_elapsed(t)))
    Diff3D.timer_update!(t, 1.05);  push!(got, (Diff3D.timer_delta(t), Diff3D.timer_elapsed(t)))
    t.time_scale = 2.0
    Diff3D.timer_update!(t, 1.1);   push!(got, (Diff3D.timer_delta(t), Diff3D.timer_elapsed(t)))
    Diff3D.timer_reset!(t, 1.5)
    Diff3D.timer_update!(t, 1.52);  push!(got, (Diff3D.timer_delta(t), Diff3D.timer_elapsed(t)))
    t.time_scale = 0.5
    Diff3D.timer_update!(t, 1.6);   push!(got, (Diff3D.timer_delta(t), Diff3D.timer_elapsed(t)))
    for (g, e) in zip(got, expected)
        @test g[1] ≈ e[1] atol = 1e-12
        @test g[2] ≈ e[2] atol = 1e-12
    end
    # Explicit timestamps may go backwards (Timer.update(timestamp)):
    # 10, 30, 25 ms from start 0 -> [0.01,0.01], [0.02,0.03], [-0.005,0.025].
    u = Diff3D.FrameTimer(0.0)
    Diff3D.timer_update!(u, 0.010); Diff3D.timer_update!(u, 0.030); Diff3D.timer_update!(u, 0.025)
    @test Diff3D.timer_delta(u) ≈ -0.005 atol = 1e-15
    @test Diff3D.timer_elapsed(u) ≈ 0.025 atol = 1e-15
    @test_throws ArgumentError Diff3D.timer_update!(u, Inf)
    @test Diff3D.timer_elapsed(u) ≈ 0.025 atol = 1e-15
    @test Diff3D.FrameTimer().time_scale == 1.0
end

@testset "Morph-name tracks on a parent resolve the name per target" begin
    # three.js PropertyBinding.bind looks a morphTargetInfluences[name] index up
    # in each bound object's own morphTargetDictionary. Oracle (r186, one
    # NumberKeyframeTrack per mesh, [0,1] -> [0,1], update(0.5)):
    # a=[0.5,0], b=[0,0,0.5], c=[0] (c has no "smile" and is not written).
    geo = BoxGeometry()
    a = Mesh(geo, MeshBasicMaterial(); morph_target_influences=[0.0, 0.0],
             morph_target_names=["smile", "frown"])
    b = Mesh(geo, MeshBasicMaterial(); morph_target_influences=[0.0, 0.0, 0.0],
             morph_target_names=["blink", "frown", "smile"])
    c = Mesh(geo, MeshBasicMaterial(); morph_target_influences=[0.0],
             morph_target_names=["other"])
    g = Group(); add!(g, a); add!(g, b); add!(g, c)
    tr = NumberKeyframeTrack(g, "morphTargetInfluences[smile]", [0.0, 1.0], [0.0, 1.0])
    @test tr.component == 1           # index on the first node naming it (1.0 field)
    @test tr.morph_name == "smile"
    mixer = AnimationMixer(AnimationClip("m", AbstractKeyframeTrack[tr]))
    mixer_set_time!(mixer, 0.5)
    @test a.morph_target_influences == [0.5, 0.0]
    @test b.morph_target_influences == [0.0, 0.0, 0.5]
    @test c.morph_target_influences == [0.0]
    # Numeric and x/y/z component paths keep their fixed index.
    n = NumberKeyframeTrack(g, "morphTargetInfluences[1]", [0.0, 1.0], [0.0, 1.0])
    @test n.morph_name == "" && n.component == 2
    # Browser export carries the same per-object index.
    io = IOBuffer()
    Diff3D._web_write_track_json(io, tr, UInt8[])
    json = Diff3D._json_parse(String(take!(io)))
    @test json["morphComponents"] == Dict(string(a.id) => 1, string(b.id) => 3)
end

# Differential oracle for the stateful mixer: three.js r186, one action of a
# 2-second clip on an Object3D at position (7,8,9) and scale (2,3,4) with
#   VectorKeyframeTrack  position  [0, 0.75, 2] -> (0,0,0), (1,2,3), (-1,4,0.5)
#   NumberKeyframeTrack  scale[x]  [0, 2] -> [1, 3]                       (smooth)
#   NumberKeyframeTrack  scale[y]  [0, .25, 1, 1.625, 2] -> [0,1,-2,4,.5] (smooth)
#   NumberKeyframeTrack  scale[z]  [.25, 1.125, 1.75] -> [5,-1,2]         (smooth)
# driven by a seeded random sequence of mixer.update(dt), action.timeScale=,
# action.reset()+mixer.setTime(t), reset(), stop(), play(), setLoop(),
# clampWhenFinished=, paused=, enabled=. After each operation: position,
# scale, and (enabled, paused, isRunning(), isScheduled()). Generated by a node
# script importing build/three.module.js (all key data is float32-exact).
const _MIXER_ORACLE = [
    (seed=3, loop=:repeat, reps=3, clamp=false, steps=[
        ((:update, -0.07), (-0.8879999999999999, 3.888, 0.6400000000000001, 2.96141075, 0.9915414518518524, 2.0), (true, false, true, true)),
        ((:loop, :pingpong, 0), (-0.8879999999999999, 3.888, 0.6400000000000001, 2.96141075, 0.9915414518518524, 2.0), (true, false, true, true)),
        ((:play, 0.0), (-0.8879999999999999, 3.888, 0.6400000000000001, 2.96141075, 0.9915414518518524, 2.0), (true, false, true, true)),
        ((:scale, 0.5), (-0.8879999999999999, 3.888, 0.6400000000000001, 2.96141075, 0.9915414518518524, 2.0), (true, false, true, true)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:scale, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.31), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, -0.07), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:reset, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, true)),
        ((:clamp, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, true)),
        ((:enabled, true), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, true)),
        ((:update, 0.31), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, false, true)),
        ((:update, 0.13), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, false, true)),
        ((:update, 0.13), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, false, true)),
        ((:scale, 2.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:settime, 1.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.31), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:scale, -1.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:reset, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:paused, true), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, true, false, true)),
        ((:update, -0.07), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, true, false, true)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, true, false, true)),
        ((:update, 0.31), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, true, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, true, false, true)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, true, false, true)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.31), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:scale, 0.5), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:play, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, true, true)),
        ((:clamp, true), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, true, true)),
        ((:update, 0.9), (0.6, 1.2, 1.7999999999999998, 1.35409375, 0.3642666666666666, 4.23916501457726), (true, false, true, true)),
        ((:reset, 0.0), (0.6, 1.2, 1.7999999999999998, 1.35409375, 0.3642666666666666, 4.23916501457726), (true, false, true, true)),
        ((:update, 0.31), (0.20666666666666667, 0.41333333333333333, 0.62, 1.09458778125, 0.676544, 5.0), (true, false, true, true)),
        ((:update, 0.0), (0.20666666666666667, 0.41333333333333333, 0.62, 1.09458778125, 0.676544, 5.0), (true, false, true, true)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:enabled, true), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:clamp, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:paused, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:scale, -0.75), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, -0.29), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, -0.29), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:paused, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
    ]),
    (seed=7, loop=:pingpong, reps=2, clamp=true, steps=[
        ((:update, -1.7), (0.4000000000000001, 0.8000000000000002, 1.2000000000000002, 1.102375, 0.9530666666666665, 4.946234402332362), (true, false, true, true)),
        ((:update, -1.7), (-0.039999999999999813, 3.04, 1.7000000000000004, 2.421, 2.359935999999999, -0.020032000000000605), (true, false, true, true)),
        ((:update, 2.3), (-1.0, 4.0, 0.5, 3.0, 0.5, 2.0), (true, true, false, true)),
        ((:update, 0.05), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, -1.7), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:enabled, true), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, -0.07), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, 0.9), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:reset, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:play, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 0.9), (0.76, 2.24, 2.7, 1.739125, -2.0645333333333333, 0.11387988338192412), (true, false, true, true)),
        ((:play, 0.0), (0.76, 2.24, 2.7, 1.739125, -2.0645333333333333, 0.11387988338192412), (true, false, true, true)),
        ((:update, 0.13), (0.552, 2.4480000000000004, 2.4400000000000004, 1.9163523749999996, -1.8839083519999997, -0.7255300104956275), (true, false, true, true)),
        ((:enabled, true), (0.552, 2.4480000000000004, 2.4400000000000004, 1.9163523749999996, -1.8839083519999997, -0.7255300104956275), (true, false, true, true)),
        ((:update, 0.0), (0.552, 2.4480000000000004, 2.4400000000000004, 1.9163523749999996, -1.8839083519999997, -0.7255300104956275), (true, false, true, true)),
        ((:update, 0.13), (0.3439999999999998, 2.6560000000000006, 2.18, 2.0966640000000005, -0.7777576959999984, -1.009351168), (true, false, true, true)),
        ((:scale, 2.0), (0.3439999999999998, 2.6560000000000006, 2.18, 2.0966640000000005, -0.7777576959999984, -1.009351168), (true, false, true, true)),
        ((:update, -0.29), (0.7733333333333335, 1.546666666666667, 2.3200000000000007, 1.3473330000000003, -0.4589696000000012, 3.1631954472303185), (true, false, true, true)),
        ((:clamp, true), (0.7733333333333335, 1.546666666666667, 2.3200000000000007, 1.3473330000000003, -0.4589696000000012, 3.1631954472303185), (true, false, true, true)),
        ((:update, 0.47), (-0.23199999999999998, 3.232, 1.4600000000000002, 2.5710719999999996, 3.5802705920000006, 0.8046973074285714), (true, false, true, true)),
        ((:update, -0.07), (-0.007999999999999785, 3.008, 1.7400000000000004, 2.394973, 2.108306261333332, -0.14906960457142931), (true, false, true, true)),
        ((:settime, 1.3), (-0.039999999999999813, 3.04, 1.7000000000000004, 2.421, 2.359935999999999, -0.020032000000000605), (true, false, true, true)),
        ((:update, 2.3), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:scale, 0.5), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:enabled, true), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, 0.31), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:clamp, false), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, 0.13), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, 0.13), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:update, -0.29), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, true, false, true)),
        ((:reset, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, -0.07), (-0.9440000000000002, 3.944, 0.5699999999999998, 2.981291078125, 0.7204375703703698, 2.0), (true, false, true, true)),
        ((:settime, -2.5), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, false, true, true)),
        ((:update, 0.0), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, false, true, true)),
        ((:scale, 2.0), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, false, true, true)),
        ((:update, 0.0), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, false, true, true)),
        ((:reset, 0.0), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, false, true, true)),
        ((:paused, true), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, true, false, true)),
        ((:loop, :repeat, 0), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, true, false, true)),
        ((:paused, false), (1.0, 2.0, 3.0, 1.544921875, -1.5333333333333332, 1.4874635568513126), (true, false, true, true)),
        ((:update, 0.05), (0.13333333333333333, 0.26666666666666666, 0.4, 1.0121250000000002, 0.3520000000000001, 5.0), (true, false, true, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:reset, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, true, true)),
        ((:update, -0.07), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, 2.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, -0.29), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:scale, 0.5), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, -0.07), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, -0.6), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:reset, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, true, true)),
        ((:update, -0.29), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, -0.6), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:clamp, true), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:enabled, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, false)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, false)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, false)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, false)),
        ((:play, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
    ]),
    (seed=12, loop=:once, reps=-1, clamp=false, steps=[
        ((:update, 0.47), (0.6266666666666666, 1.2533333333333332, 1.88, 1.237191375, 0.2493482666666669, 4.09542855276968), (true, false, true, true)),
        ((:update, 0.13), (0.7999999999999999, 1.5999999999999999, 2.4, 1.3689999999999998, -0.594133333333333, 2.9744000000000006), (true, false, true, true)),
        ((:update, -0.07), (0.7066666666666667, 1.4133333333333333, 2.12, 1.295296125, -0.12561493333333332, 3.6126847999999994), (true, false, true, true)),
        ((:update, -0.29), (0.32000000000000006, 0.6400000000000001, 0.9600000000000002, 1.0668160000000002, 0.9953279999999998, 5.0), (true, false, true, true)),
        ((:update, 0.31), (0.7333333333333334, 1.4666666666666668, 2.2, 1.315734375, -0.2576000000000004, 3.437243148688046), (true, false, true, true)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.47), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:enabled, true), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:stop, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, -0.07), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:paused, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:settime, 4.1), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:loop, :repeat, 2), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.05), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:reset, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, false, false)),
        ((:play, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (true, false, true, true)),
        ((:update, 2.3), (0.39999999999999974, 0.7999999999999995, 1.1999999999999993, 1.1023749999999999, 0.9530666666666671, 5.007193002915452), (true, false, true, true)),
        ((:reset, 0.0), (0.39999999999999974, 0.7999999999999995, 1.1999999999999993, 1.1023749999999999, 0.9530666666666671, 5.007193002915452), (true, false, true, true)),
        ((:update, 0.0), (0.0, 0.0, 0.0, 1.0, 0.0, 5.0), (true, false, true, true)),
        ((:update, 2.3), (0.39999999999999974, 0.7999999999999995, 1.1999999999999993, 1.1023749999999999, 0.9530666666666671, 5.007193002915452), (true, false, true, true)),
        ((:update, -0.07), (0.3066666666666664, 0.6133333333333328, 0.9199999999999993, 1.061562375, 0.9769173333333327, 5.0), (true, false, true, true)),
        ((:update, 0.31), (0.7199999999999998, 1.4399999999999995, 2.1599999999999993, 1.305451, -0.1913045333333322, 3.7035293481049583), (true, false, true, true)),
        ((:settime, 0.4), (0.5333333333333333, 1.0666666666666667, 1.6, 1.176, 0.6208, 4.694619241982507), (true, false, true, true)),
        ((:clamp, false), (0.5333333333333333, 1.0666666666666667, 1.6, 1.176, 0.6208, 4.694619241982507), (true, false, true, true)),
        ((:update, 0.47), (0.808, 2.192, 2.7600000000000002, 1.699186375, -2.0095957333333336, 0.4356385212827989), (true, false, true, true)),
        ((:update, 0.13), (0.6000000000000001, 2.4000000000000004, 2.5000000000000004, 1.875, -2.0, -0.5521865889212828), (true, false, true, true)),
        ((:update, -0.07), (0.7120000000000002, 2.2880000000000003, 2.6400000000000006, 1.779491125, -2.087598933333333, -0.07139194402332205), (true, false, true, true)),
        ((:update, 0.13), (0.504, 2.4960000000000004, 2.3800000000000003, 1.957869, -1.7081308159999997, -0.8421654763848403), (true, false, true, true)),
        ((:loop, :repeat, 1), (0.504, 2.4960000000000004, 2.3800000000000003, 1.957869, -1.7081308159999997, -0.8421654763848403), (true, false, true, true)),
        ((:update, -0.29), (0.968, 2.032, 2.96, 1.569925125, -1.6362197333333337, 1.4078324804664721), (true, false, true, true)),
        ((:settime, 2.6), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:play, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:clamp, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, -2.5), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.9), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.13), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.31), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:settime, 0.4), (0.5333333333333333, 1.0666666666666667, 1.6, 1.176, 0.6208, 4.694619241982507), (true, false, true, true)),
        ((:enabled, false), (0.5333333333333333, 1.0666666666666667, 1.6, 1.176, 0.6208, 4.694619241982507), (false, false, false, true)),
        ((:update, -1.7), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 2.3), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:play, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:clamp, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, 0.0), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:update, -0.07), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
        ((:clamp, false), (7.0, 8.0, 9.0, 2.0, 3.0, 4.0), (false, false, false, true)),
    ]),
]

function _mixer_oracle_scene(loop, reps, clamp)
    obj = Group()
    obj.position = Vec3(7.0, 8.0, 9.0)
    obj.scale = Vec3(2.0, 3.0, 4.0)
    tracks = AbstractKeyframeTrack[
        KeyframeTrack(obj, :position, [0.0, 0.75, 2.0],
                      [Vec3(0.0, 0, 0), Vec3(1.0, 2, 3), Vec3(-1.0, 4, 0.5)]),
        NumberKeyframeTrack(obj, "scale[x]", [0.0, 2.0], [1.0, 3.0]; interpolation=:cubic),
        NumberKeyframeTrack(obj, "scale[y]", [0.0, 0.25, 1.0, 1.625, 2.0],
                            [0.0, 1, -2, 4, 0.5]; interpolation=:cubic),
        NumberKeyframeTrack(obj, "scale[z]", [0.25, 1.125, 1.75], [5.0, -1, 2];
                            interpolation=:cubic),
    ]
    mixer = AnimationMixer(AnimationClip("c", 2.0, tracks); loop=loop, repetitions=reps,
                           clamp_when_finished=clamp)
    return obj, mixer
end

function _mixer_oracle_apply!(m, op)
    name = op[1]
    if name === :update
        mixer_update!(m, op[2])
    elseif name === :scale
        m.time_scale = op[2]
    elseif name === :settime
        mixer_set_time!(m, op[2])
    elseif name === :reset
        Diff3D.mixer_reset!(m)
    elseif name === :stop
        Diff3D.mixer_stop!(m)
    elseif name === :play
        Diff3D.mixer_play!(m)
    elseif name === :loop
        Diff3D.mixer_set_loop!(m, op[2], op[3])
    elseif name === :clamp
        m.clamp_when_finished = op[2]
    elseif name === :paused
        m.paused = op[2]
    elseif name === :enabled
        m.enabled = op[2]
    end
    return m
end

@testset "AnimationMixer steps like a three.js AnimationAction" begin
    for case in _MIXER_ORACLE
        obj, m = _mixer_oracle_scene(case.loop, case.reps, case.clamp)
        for (op, pose, flags) in case.steps
            _mixer_oracle_apply!(m, op)
            got = (obj.position.x, obj.position.y, obj.position.z,
                   obj.scale.x, obj.scale.y, obj.scale.z)
            @test all(isapprox.(got, pose; atol=1e-12))
            @test (m.enabled, m.paused, Diff3D.mixer_is_running(m),
                   Diff3D.mixer_is_scheduled(m)) == flags
        end
    end
end

@testset "AnimationMixer finish, reversal and restore through the 1.0 API" begin
    # AnimationAction.js:780-812: every wrap adds |loopDelta| to the loop count,
    # in either direction; at 0 pending repetitions an unclamped action is
    # disabled and PropertyMixer.apply mixes the original value back in
    # (weight 0). Repeat, 2 repetitions, d = 2: +1.5, +1.0 (wrap, loop 1),
    # -1.0 (wrap back: loop 2) finishes and restores (7,8,9).
    obj = Group(); obj.position = Vec3(7.0, 8.0, 9.0)
    tr = KeyframeTrack(obj, :position, [0.0, 2.0], [Vec3(0.0, 0, 0), Vec3(2.0, 0, 0)])
    m = AnimationMixer(AnimationClip("r", AbstractKeyframeTrack[tr]; repetitions=2))
    mixer_update!(m, 1.5); @test obj.position.x == 1.5
    mixer_update!(m, 1.0); @test obj.position.x == 0.5
    mixer_update!(m, -1.0)
    @test obj.position == Vec3(7.0, 8.0, 9.0)       # 1.0 code sampled clip time 1.5
    @test !m.enabled
    # The finish is sticky: later deltas in either direction change nothing
    # (a disabled action is skipped, AnimationAction.js:562-567).
    obj.position = Vec3(-4.0, 0.0, 0.0)
    mixer_update!(m, -0.5); mixer_update!(m, 0.75)
    @test obj.position == Vec3(-4.0, 0.0, 0.0)
    # mixer_set_time! restarts (action.reset() + mixer.setTime).
    mixer_set_time!(m, 0.5)
    @test obj.position.x == 0.5 && m.enabled
    # A :once clip past its end without clamping restores the original value.
    obj.position = Vec3(7.0, 8.0, 9.0)
    once = AnimationMixer(AnimationClip("o", AbstractKeyframeTrack[tr]; loop=:once))
    mixer_update!(once, 2.5)
    @test obj.position == Vec3(7.0, 8.0, 9.0)
    mixer_update!(once, -1.0)                       # sticky: no replay at t = 1.5
    @test obj.position == Vec3(7.0, 8.0, 9.0)
    # mixer_stop! restores immediately; mixer_play! takes new originals.
    m2 = AnimationMixer(AnimationClip("s", AbstractKeyframeTrack[tr]))
    mixer_update!(m2, 1.0)
    @test obj.position.x == 1.0
    Diff3D.mixer_stop!(m2)
    @test obj.position == Vec3(7.0, 8.0, 9.0)
    mixer_update!(m2, 0.5)
    @test obj.position == Vec3(7.0, 8.0, 9.0) && !Diff3D.mixer_is_scheduled(m2)
    obj.position = Vec3(1.0, 1.0, 1.0)
    Diff3D.mixer_play!(m2)
    mixer_update!(m2, 0.25); @test obj.position.x == 0.25
    Diff3D.mixer_stop!(m2)
    @test obj.position == Vec3(1.0, 1.0, 1.0)
end

@testset "AnimationMixer zero_slope_at_start / zero_slope_at_end" begin
    # AnimationAction._setEndings (AnimationAction.js:882-915) with
    # zeroSlopeAtStart/End. Oracle (node, r186): smooth position[x] keys
    # [0, .5, 2] -> [0, 1, -3], clip 2 s, updates 0.25, 1.0, 0.5, 0.75, 0.375.
    expected = Dict(
        (true, true, :once) => [0.5208333333333334, -0.8125, -2.4837962962962963, 0.0, 0.0],
        (false, true, :once) => [0.6458333333333334, -0.8125, -2.4837962962962963, 0.0, 0.0],
        (true, false, :once) => [0.5208333333333334, -0.5625, -2.252314814814815, 0.0, 0.0],
        (false, false, :once) => [0.6458333333333334, -0.5625, -2.252314814814815, 0.0, 0.0],
        (true, true, :repeat) => [0.5208333333333334, -1.5625, -3.1782407407407405, 1.0, 0.1171875],
        (false, true, :repeat) => [0.6458333333333334, -1.5625, -3.1782407407407405, 1.0, 0.1171875],
        (true, false, :repeat) => [0.5208333333333334, -1.5625, -3.1782407407407405, 1.0, 0.1171875],
        (false, false, :repeat) => [0.6458333333333334, -1.5625, -3.1782407407407405, 1.0, 0.1171875])
    for ((zs, ze, loop), xs) in expected
        obj = Group()
        tr = NumberKeyframeTrack(obj, "position[x]", [0.0, 0.5, 2.0], [0.0, 1.0, -3.0];
                                 interpolation=:cubic)
        m = AnimationMixer(AnimationClip("z", 2.0, AbstractKeyframeTrack[tr]); loop=loop,
                           repetitions=loop === :once ? 1 : 2,
                           zero_slope_at_start=zs, zero_slope_at_end=ze)
        got = Float64[]
        for dt in (0.25, 1.0, 0.5, 0.75, 0.375)
            mixer_update!(m, dt)
            push!(got, obj.position.x)
        end
        @test got ≈ xs atol = 1e-12
    end
end

function _audit3b_mixer_allocations(mixer, dt)
    mixer_update!(mixer, dt)
    return @allocated mixer_update!(mixer, dt)
end

@testset "stateful mixer updates do not allocate" begin
    obj, m = _mixer_oracle_scene(:repeat, -1, false)
    if Base.JLOptions().opt_level > 0
        @test _audit3b_mixer_allocations(m, 0.016) == 0
        @test _audit3b_mixer_allocations(m, -0.37) == 0   # wraps backward
        m.paused = true
        @test _audit3b_mixer_allocations(m, 0.016) == 0
    end
end

@testset "KeyframeTrack and AnimationClip utilities match three.js" begin
    # Oracle: node, three.js r186 KeyframeTrack.optimize/trim/shift/scale,
    # AnimationUtils.subclip, AnimationClip.CreateFromMorphTargetSequence /
    # CreateClipsFromMorphTargetSequences / findByName.
    o = Group()
    keys(tr) = (tr.times, tr.values)
    n = NumberKeyframeTrack(o, "position[x]", collect(0.0:6.0), [0.0, 0, 0, 1, 1, 1, 0])
    @test keys(Diff3D.track_optimize(n)) == ([0.0, 2, 3, 5, 6], [0.0, 0, 1, 1, 0])
    v = KeyframeTrack(o, :position, [0.0, 1, 2, 3],
                      [Vec3(1.0, 2, 3), Vec3(1.0, 2, 3), Vec3(1.0, 2, 3), Vec3(1.0, 2, 4)])
    @test keys(Diff3D.track_optimize(v)) ==
          ([0.0, 2, 3], [Vec3(1.0, 2, 3), Vec3(1.0, 2, 3), Vec3(1.0, 2, 4)])
    smooth = NumberKeyframeTrack(o, "position[x]", [0.0, 1, 2, 3], zeros(4); interpolation=:cubic)
    @test Diff3D.track_optimize(smooth) === smooth          # smooth keeps every key
    step = NumberKeyframeTrack(o, "position[x]", [0.0, 1, 2, 3, 4], [5.0, 5, 6, 6, 6];
                               interpolation=:step)
    @test keys(Diff3D.track_optimize(step)) == ([0.0, 1, 2, 4], [5.0, 5, 6, 6])
    @test n.times == collect(0.0:6.0)                       # optimize copies
    mk() = NumberKeyframeTrack(o, "position[x]", [0.0, 0.5, 1, 1.5, 2], [10.0, 11, 12, 13, 14])
    for ((a, b), expect) in (((0.6, 1.4), ([1.0], [12.0])),
                             ((0.5, 1.5), ([0.5, 1, 1.5], [11.0, 12, 13])),
                             ((1.6, 1.7), ([1.5], [13.0])),
                             ((3.0, 4.0), ([2.0], [14.0])),
                             ((-2.0, -1.0), ([0.0], [10.0])),
                             ((-1.0, 5.0), ([0.0, 0.5, 1, 1.5, 2], [10.0, 11, 12, 13, 14])))
        @test keys(Diff3D.track_trim(mk(), a, b)) == expect
    end
    t = mk()
    @test Diff3D.track_scale!(Diff3D.track_shift!(t, -0.25), 2.0) === t
    @test keys(t) == ([-0.5, 0.5, 1.5, 2.5, 3.5], [10.0, 11, 12, 13, 14])
    @test_throws ArgumentError Diff3D.track_scale!(t, -1.0)
    @test_throws ArgumentError Diff3D.track_scale!(t, 0.0)
    @test_throws ArgumentError Diff3D.track_shift!(t, Inf)
    @test t.times == [-0.5, 0.5, 1.5, 2.5, 3.5]             # rejected edits change nothing
    @test Diff3D.track_validate(t)
    t.times[2] = t.times[1]
    @test !Diff3D.track_validate(t)
    t.times[2] = NaN
    @test !Diff3D.track_validate(t)
    q = QuaternionKeyframeTrack(o, :quaternion, [0.0, 1, 2],
                                [Quaternion(), Quaternion(), Quaternion()])
    @test keys(Diff3D.track_optimize(q)) == ([0.0, 2.0], [Quaternion(), Quaternion()])
    w = MorphWeightsKeyframeTrack(o, :morph_target_influences, [0.0, 1, 2, 3],
                                  [[0.0, 1], [0.0, 1], [0.0, 1], [1.0, 1]])
    @test keys(Diff3D.track_optimize(w)) == ([0.0, 2, 3], [[0.0, 1], [0.0, 1], [1.0, 1]])

    # subclip(clip, "part", 1, 4, fps 4): duration 0.5;
    # position[x] [0,.25,.5] -> [1,2,3]; scale [0.25] -> (1,1,1); position[y] dropped.
    full = AnimationClip("full", AbstractKeyframeTrack[
        NumberKeyframeTrack(o, "position[x]", [0.0, 0.25, 0.5, 0.75, 1, 1.25], [0.0, 1, 2, 3, 4, 5]),
        KeyframeTrack(o, :scale, [0.5, 1.5], [Vec3(1.0, 1, 1), Vec3(2.0, 2, 2)]),
        NumberKeyframeTrack(o, "position[y]", [2.0, 3], [7.0, 8])]; loop=:pingpong)
    part = Diff3D.clip_subclip(full, "part", 1, 4, 4)
    @test part.name == "part" && part.duration == 0.5 && part.loop === :pingpong
    @test length(part.tracks) == 2
    @test keys(part.tracks[1]) == ([0.0, 0.25, 0.5], [1.0, 2, 3])
    @test keys(part.tracks[2]) == ([0.25], [Vec3(1.0, 1, 1)])
    @test full.tracks[1].times == [0.0, 0.25, 0.5, 0.75, 1, 1.25]   # source untouched

    # resetDuration / trim / optimize / validate / findByName.
    long = AnimationClip("long", 1.0, AbstractKeyframeTrack[mk()])
    @test Diff3D.clip_reset_duration(long).duration == 2.0
    @test keys(Diff3D.clip_trim(long).tracks[1]) == ([0.0, 0.5, 1.0], [10.0, 11, 12])
    @test Diff3D.clip_validate(long)
    @test Diff3D.clip_optimize(AnimationClip("n", AbstractKeyframeTrack[n])).tracks[1].times ==
          [0.0, 2, 3, 5, 6]
    @test Diff3D.clip_find_by_name([long, part], "part") === part
    @test Diff3D.clip_find_by_name([long, part], "none") === nothing

    # CreateFromMorphTargetSequence(name, [a,b,c], fps 4): duration 0.75,
    # a [0,.25,.5,.75] -> [1,0,0,1], b -> [0,1,0,0], c -> [0,0,1,0]; noLoop:
    # duration 0.5 and three keys. Two targets: three.js keys a [0,.25,.25,.5]
    # -> [1,0,0,1] and b [0,0,.25,.5] -> [0,0,1,0]; the duplicate (equal)
    # key is merged, which samples identically.
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=zeros(7),
                morph_target_names=["a", "b", "c", "walk_001", "walk_002", "run1", "walk_003"])
    seq = Diff3D.clip_from_morph_target_sequence(mesh, "seq3", ["a", "b", "c"], 4)
    @test seq.duration == 0.75
    @test [keys(tr) for tr in seq.tracks] ==
          [([0.0, 0.25, 0.5, 0.75], [1.0, 0, 0, 1]), ([0.0, 0.25, 0.5, 0.75], [0.0, 1, 0, 0]),
           ([0.0, 0.25, 0.5, 0.75], [0.0, 0, 1, 0])]
    @test [tr.component for tr in seq.tracks] == [1, 2, 3]
    nl = Diff3D.clip_from_morph_target_sequence(mesh, "seq3nl", ["a", "b", "c"], 4; no_loop=true)
    @test nl.duration == 0.5
    @test [keys(tr) for tr in nl.tracks] ==
          [([0.0, 0.25, 0.5], [1.0, 0, 0]), ([0.0, 0.25, 0.5], [0.0, 1, 0]),
           ([0.0, 0.25, 0.5], [0.0, 0, 1])]
    two = Diff3D.clip_from_morph_target_sequence(mesh, "seq2", ["a", "b"], 4)
    @test two.duration == 0.5
    @test [keys(tr) for tr in two.tracks] ==
          [([0.0, 0.25, 0.5], [1.0, 0, 1]), ([0.0, 0.25, 0.5], [0.0, 1, 0])]
    # One target: three.js keys [0,0,0,0.25] -> [0,1,0,0] sample 0 everywhere.
    one = Diff3D.clip_from_morph_target_sequence(mesh, "one", ["a"], 4)
    @test keys(one.tracks[1]) == ([0.0, 0.25], [0.0, 0.0])
    # CreateClipsFromMorphTargetSequences(walk_001, walk_002, run1, walk_003,
    # run2, idle, run3; fps 2): clips "walk_" (1.5 s; walk_001..walk_003) and
    # "run" (1.5 s; run1..run3) in order of first appearance; "idle" has no
    # frame number. findByName(clips, "run") is the second clip.
    seqmesh = Mesh(BoxGeometry(), MeshBasicMaterial(); morph_target_influences=zeros(7),
                   morph_target_names=["walk_001", "walk_002", "run1", "walk_003",
                                       "run2", "idle", "run3"])
    groups = Diff3D.clips_from_morph_target_sequences(seqmesh, 2)
    @test [c.name for c in groups] == ["walk_", "run"]
    @test [c.duration for c in groups] == [1.5, 1.5]
    @test [tr.component for tr in groups[1].tracks] == [1, 2, 4]
    @test [tr.component for tr in groups[2].tracks] == [3, 5, 7]
    @test Diff3D.clip_find_by_name(groups, "run") === groups[2]
end
