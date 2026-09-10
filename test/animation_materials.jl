using Test
using Diff3D

@testset "Animated Phong parameters remain renderable" begin
    texture = Texture(fill(0.75, 1, 1, 3); colorspace=:linear)
    options = (
        color=Color3(0.2, 0.4, 0.6),
        specular=Color3(0.1, 0.2, 0.3),
        emissive=Color3(0.03, 0.02, 0.01),
        emissive_intensity=0.6,
        opacity=0.8, transparent=true, side=:double,
        map=texture, normal_scale=0.7,
        ao_map_intensity=0.3, light_map_intensity=0.4,
        clipping_planes=[Plane(Vec3(1.0, 0.0, 0.0), 2.0)],
        depth_write=false,
    )

    function render_material(material, shading)
        scene = Scene()
        add!(scene, Mesh(PlaneGeometry(), material))
        add!(scene, AmbientLight(intensity=0.2))
        add!(scene, DirectionalLight(
            intensity=0.4, position=Vec3(1.0, 1.0, 3.0)))
        target = RenderTarget(8, 8)
        render!(target, scene, PerspectiveCamera(); shading=shading)
        return target.color
    end

    for (property, values) in ((:shininess, [0.0, 80.0]),
                               (:glossiness, [0.2, 1.0]))
        @testset "$property" begin
            original = MeshPhongMaterial(; options..., shininess=20.0)
            mesh = Mesh(PlaneGeometry(), original)
            track = NumberKeyframeTrack(
                mesh, "material.$property", [0.0, 1.0], values)
            mixer = AnimationMixer(AnimationClip(
                "surface", [track]; loop=:once, clamp_when_finished=true))
            for time in (0.0, 0.25, 0.5, 1.0)
                mixer_set_time!(mixer, time)
                value = (1.0 - time) * values[1] + time * values[2]
                expected = property === :shininess ?
                    MeshPhongMaterial(; options..., shininess=value) :
                    MeshPhongMaterial(; options..., glossiness=value)
                @test mesh.material.shininess ≈ expected.shininess
                @test mesh.material.glossiness ≈ expected.glossiness
                for field in fieldnames(MeshPhongMaterial)
                    field in (:shininess, :glossiness) && continue
                    @test getfield(mesh.material, field) === getfield(original, field)
                end
                for shading in (:flat, :smooth)
                    actual_image = render_material(mesh.material, shading)
                    expected_image = render_material(expected, shading)
                    @test any(>(0.0), actual_image)
                    @test actual_image ≈ expected_image
                end
                exported = Diff3D._json_parse(
                    Diff3D._web_drawable_json(mesh, Mat4()))
                @test exported["shininess"] ≈ max(expected.shininess,
                                                  Diff3D._PHONG_SHININESS_FLOOR)
                @test exported["glossiness"] ≈ expected.glossiness
            end

            # A finite keyframe may still violate the material's numeric range.
            # Reject the update before replacing the material on the target.
            before = mesh.material
            invalid_values = property === :shininess ? [-2.0, -1.0] : [2.0, 3.0]
            invalid_track = NumberKeyframeTrack(
                mesh, property, [0.0, 1.0], invalid_values)
            invalid_mixer = AnimationMixer(AnimationClip("invalid", [invalid_track]))
            @test_throws ArgumentError mixer_set_time!(invalid_mixer, 0.5)
            @test mesh.material === before

            color_track = NumberKeyframeTrack(
                mesh, "specular.g", [0.0, 1.0], [0.1, 0.5])
            mixer_set_time!(AnimationMixer(AnimationClip("color", [color_track])), 0.5)
            @test mesh.material.specular.g ≈ 0.3
            @test mesh.material.shininess == before.shininess
            @test mesh.material.glossiness == before.glossiness
        end
    end
end
