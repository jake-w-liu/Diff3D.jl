using Test
using Diff3D

struct StandardDirectCustomLight <: AbstractLight
    color::Color3{Float64}
end
Diff3D.light_contribution(light::StandardDirectCustomLight, ::Vec3) =
    (light.color, 0.5, Vec3(0.0, 0.0, 1.0))

_standard_direct_bytes(operation::F, arguments) where {F} = @allocated operation(arguments...)

@testset "Mapped standard direct lighting preserves filtered and custom lights" begin
    material = MeshStandardMaterial(color=Color3(0.8, 0.4, 0.3))
    sources = (
        Diff3D.SceneLight[],
        Diff3D.SceneLight[AmbientLight(), HemisphereLight(), LightProbe()],
        Diff3D.SceneLight[AmbientLight(), DirectionalLight(), PointLight(),
                         RectAreaLight(), HemisphereLight(), SpotLight(), LightProbe()],
        AbstractLight[AmbientLight(), StandardDirectCustomLight(Color3(0.4, 0.5, 0.6))],
    )
    for T in (Float64, BigFloat), lights in sources
        normal = Vec3(T(0), T(0), T(1))
        position = Vec3(T(0.1), T(0.2), T(-0.3))
        direct = filter(light -> !(light isa Union{AmbientLight,HemisphereLight,LightProbe}), lights)
        view = Diff3D._DirectLightView(lights)
        for vertex_color in (nothing, Color3(0.3, 0.8, 0.5))
            operation = vertex_color === nothing ? Diff3D._shade_standard_mapped :
                        Diff3D._shade_standard_mapped_vertex_color
            arguments = (normal, normal, position, material, view, nothing, 0.2, 0.8)
            expected_arguments = (normal, normal, position, material, direct, nothing, 0.2, 0.8)
            if vertex_color !== nothing
                arguments = (arguments..., vertex_color)
                expected_arguments = (expected_arguments..., vertex_color)
            end
            actual = operation(arguments...)
            expected = operation(expected_arguments...)
            @test (actual.r, actual.g, actual.b) == (expected.r, expected.g, expected.b)
            if T === Float64 && lights isa Vector{Diff3D.SceneLight} && Base.JLOptions().opt_level > 0
                _standard_direct_bytes(operation, arguments)
                @test _standard_direct_bytes(operation, arguments) == 0
            end
        end
    end
end
