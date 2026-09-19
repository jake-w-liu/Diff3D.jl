using Test
using Diff3D
using ForwardDiff

function light_direction_allocation(from, to)
    Diff3D._light_direction_and_distance(from, to)
    return @allocated Diff3D._light_direction_and_distance(from, to)
end

function area_direction_allocation(from, to)
    Diff3D._rect_area_sample_direction(from, to)
    return @allocated Diff3D._rect_area_sample_direction(from, to)
end

@testset "Light directions are independent of distance attenuation" begin
    origin = Vec3()
    for scale in (nextfloat(0.0), floatmin(Float64), 1e-12, 1e-6, 1.0, 1e200)
        point = Vec3(scale, -2scale, 3scale)
        expected = normalize(Vec3(1.0, -2.0, 3.0))
        direction, distance = Diff3D._light_direction_and_distance(origin, point)
        @test norm(direction - expected) < 1e-14
        @test distance == hypot(point.x, point.y, point.z)

        area_direction, distance_squared = Diff3D._rect_area_sample_direction(origin, point)
        @test norm(area_direction - expected) < 1e-14
        # The attenuation floor is independent of the direction's unit length.
        @test distance_squared == max(dot(point, point), 1e-10)
        if Base.JLOptions().opt_level > 0
            light_direction_allocation(origin, point)
            area_direction_allocation(origin, point)
            @test light_direction_allocation(origin, point) <= 64
            @test area_direction_allocation(origin, point) <= 64
        end
    end
    @test Diff3D._light_direction_and_distance(origin, origin) == (origin, 0.0)
    @test Diff3D._rect_area_sample_direction(origin, origin) == (origin, 1e-10)

    # Subtraction overflow must still preserve the direction and infinite range.
    from = Vec3(-floatmax(Float64), 0.0, 0.0)
    to = Vec3(floatmax(Float64), 0.0, 0.0)
    @test Diff3D._light_direction_and_distance(from, to) == (Vec3(1.0, 0.0, 0.0), Inf)
    @test Diff3D._rect_area_sample_direction(from, to) == (Vec3(1.0, 0.0, 0.0), Inf)

    for scale in (nextfloat(0.0), 1e-12, 1e-6, 1.0)
        normal = Vec3(0.0, 0.0, 1.0)
        position = Vec3(0.0, 0.0, scale)
        lights = (PointLight(; position, decay=0.0),
                  SpotLight(; position, target=origin, decay=0.0),
                  RectAreaLight(; position))
        for light in lights
            color, intensity, direction = light_contribution(light, origin)
            @test direction == normal
            @test intensity == 1.0
            @test shade_lambert(normal, direction, color, intensity, Color3()) == Color3()
        end
        for light in lights[1:2]
            @test shade_face(normal, normal, origin, MeshLambertMaterial(), [light]) == Color3()
        end
    end

    # Moving a nearby light sideways changes its unit direction by 1/distance.
    for scale in (1e-12, 1e-6, 1.0)
        for sample_direction in (Diff3D._light_direction_and_distance,
                                 Diff3D._rect_area_sample_direction)
            derivative = ForwardDiff.derivative(0.0) do x
                first(sample_direction(origin, Vec3(x, 0.0, scale))).x
            end
            @test derivative ≈ 1 / scale
        end
    end
end
