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
