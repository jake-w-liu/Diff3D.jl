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
