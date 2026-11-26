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
