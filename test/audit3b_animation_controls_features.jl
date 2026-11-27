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
