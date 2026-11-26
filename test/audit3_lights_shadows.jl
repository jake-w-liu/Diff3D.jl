using Test, Diff3D, ForwardDiff

const _AUDIT3_IES_PROFILE = IESProfile([0.0, 30.0, 60.0, 90.0],
                                       [100.0, 80.0, 40.0, 0.0])

@testset "IES lookups carry derivatives of the vertical angle" begin
    profile = _AUDIT3_IES_PROFILE
    # Plain reals keep the documented Float64 result.
    @test ies_candela(profile, 45) === 60.0
    @test ies_candela(profile, 45.0f0) === 60.0
    @test ies_intensity(profile, 45.0) === 0.6
    # Interior slope on [30, 60]: (40 - 80) / 30 candela per degree.
    slope = (40.0 - 80.0) / 30.0
    @test ForwardDiff.derivative(t -> ies_candela(profile, t), 45.0) ≈ slope
    @test ForwardDiff.derivative(t -> ies_intensity(profile, t), 45.0) ≈ slope / 100
    @test reverse_gradient(v -> ies_intensity(profile, v[1]), [45.0])[1] ≈ slope / 100
    # Clamped endpoints keep the differentiable type with a zero derivative.
    @test ForwardDiff.derivative(t -> ies_intensity(profile, t), 120.0) == 0.0
    @test reverse_gradient(v -> ies_intensity(profile, v[1]), [-5.0])[1] == 0.0

    # The spot/point IES factor is part of the differentiable light response:
    # compare against a central finite difference of the Float64 primal.
    spot = SpotLight(position=Vec3(0.0, 2.0, 0.0), target=Vec3(0.0, 0.0, 0.0),
                     angle=1.2, ies_profile=profile)
    point = PointLight(position=Vec3(0.0, 2.0, 0.0), ies_profile=profile)
    for light in (spot, point)
        f(x) = light_contribution(light, Vec3(x, 0.0, 0.0))[2]
        h = 1e-6
        fd = (f(0.7 + h) - f(0.7 - h)) / (2h)
        @test ForwardDiff.derivative(f, 0.7) ≈ fd rtol = 1e-6
        @test reverse_gradient(v -> f(v[1]), [0.7])[1] ≈ fd rtol = 1e-6
    end
end

@testset "parse_ies reads TILT=INCLUDE tables by value count" begin
    # LM-63 lets the tilt angle and factor vectors wrap across lines. three.js
    # IESLoader `readTilt`/`readArray` (examples/jsm/loaders/IESLoader.js:223-259, called at :305)
    # reads them by count; node r186 parses this file into vertical angles
    # [0, 45, 90] with candela [100, 50, 10] (its texture holds the normalised
    # squares 1, 0.25, 0.01 at phi = 0, 45, 90).
    text = "IESNA:LM-63-2002\n[TEST] wrapped tilt\nTILT=INCLUDE\n1\n7\n" *
           "0 15 30 45\n60 75 90\n1.0 0.95 0.9 0.85\n0.8 0.75 0.7\n" *
           "1 1000 1 3 1 1 2 0 0 0\n1 1 100\n0 45 90\n0\n100 50 10\n"
    profile = parse_ies(text)
    @test profile.angles == [0.0, 45.0, 90.0]
    @test profile.candela == [100.0, 50.0, 10.0]
    # The same table on the conventional four lines parses identically.
    compact = "IESNA:LM-63-2002\nTILT=INCLUDE\n1\n2\n0 90\n1 0.5\n" *
              "1 1000 1 3 1 1 2 0 0 0\n1 1 100\n0 45 90\n0\n100 50 10\n"
    @test parse_ies(compact).candela == [100.0, 50.0, 10.0]
    # An empty tilt table (N = 0) has no angle or factor lines.
    empty_tilt = "IESNA:LM-63-2002\nTILT=INCLUDE\n1\n0\n" *
                 "1 1000 1 3 1 1 2 0 0 0\n1 1 100\n0 45 90\n0\n100 50 10\n"
    @test parse_ies(empty_tilt).angles == [0.0, 45.0, 90.0]
    @test_throws "tilt-angle count must be a non-negative integer" parse_ies(
        "TILT=INCLUDE\n1\n2.5\n0 90\n1 1\n1 1000 1 1 1 1 2 0 0 0\n1 1 1\n0\n0\n1\n")
    @test_throws "truncated TILT=INCLUDE data" parse_ies("TILT=INCLUDE\n1\n3\n0 45\n")
    # The detailed docstring documents the public function itself.
    @test occursin("TILT=INCLUDE", string(@doc parse_ies))
end
