using Diff3D, Test

@testset "Punctual distance attenuation follows three.js getDistanceAttenuation" begin
    attenuation(d, cutoff, decay) =
        1 / max(d^decay, 0.01) * clamp(1 - (d / cutoff)^4, 0.0, 1.0)^2
    point = PointLight(distance=10.0, decay=2.0)
    _, li, _ = light_contribution(point, Vec3(5.0, 0.0, 0.0))
    @test li ≈ attenuation(5.0, 10.0, 2.0) rtol=1e-12
    @test li ≈ 0.9375^2 / 25 rtol=1e-12
    _, li, _ = light_contribution(point, Vec3(12.0, 0.0, 0.0))
    @test li == 0.0
    # The inverse-power falloff is capped at 100x near the emitter.
    _, li, _ = light_contribution(PointLight(decay=2.0), Vec3(0.01, 0.0, 0.0))
    @test li ≈ 100.0 rtol=1e-12
    _, li, _ = light_contribution(PointLight(decay=2.0), Vec3(3.0, 0.0, 0.0))
    @test li ≈ 1 / 9 rtol=1e-12

    spot = SpotLight(intensity=1.0, distance=5.0, decay=2.0, position=Vec3(0.0, 0.0, 0.0),
                     target=Vec3(0.0, 0.0, -1.0))
    _, li, _ = light_contribution(spot, Vec3(0.0, 0.0, -3.0))
    @test li ≈ attenuation(3.0, 5.0, 2.0) rtol=1e-12
end

@testset "Spot penumbra uses three.js smoothstep" begin
    angle, penumbra = 0.5, 0.5
    spot = SpotLight(angle=angle, penumbra=penumbra, decay=0.0,
                     position=Vec3(0.0, 0.0, 0.0), target=Vec3(0.0, 0.0, -1.0))
    cos_outer = cos(angle)
    cos_inner = cos(angle * (1 - penumbra))
    for t in (0.0, 0.25, 0.5, 0.75, 1.0)
        c = cos_outer + t * (cos_inner - cos_outer)
        s = sqrt(1 - c^2)
        _, li, _ = light_contribution(spot, Vec3(s, 0.0, -c))
        @test li ≈ t * t * (3 - 2t) atol=1e-9
    end
end
