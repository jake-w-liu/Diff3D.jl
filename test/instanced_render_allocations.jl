using Test, Diff3D

function instanced_frame_allocations(target, scene, camera, cache)
    render!(target, scene, camera; cache)
    return @allocated render!(target, scene, camera; cache)
end

@testset "Cached colored instance rendering avoids dynamic keyword allocations" begin
    for Material in (MeshBasicMaterial, MeshLambertMaterial), count in (1, 80)
        scene = Scene()
        instances = InstancedMesh(PlaneGeometry(width=0.2, height=0.2),
                                  Material(side=:double), count)
        for index in 1:count
            x = 0.25 * ((index - 1) % 10) - 1.125
            y = 0.25 * ((index - 1) ÷ 10) - 0.875
            set_instance_matrix!(instances, index, mat4_translation(x, y, 0.0))
            set_instance_color!(instances, index,
                                Color3(0.2 + index / 100, 0.6, 0.8))
        end
        add!(scene, instances)
        add!(scene, AmbientLight(intensity=1.0))
        camera = PerspectiveCamera()
        camera.position = Vec3(0.0, 0.0, 4.0)
        target = RenderTarget(48, 48)
        reference = RenderTarget(48, 48)
        cache = RenderCache()
        reference_cache = RenderCache()
        render_pooled!(reference, scene, camera, reference_cache)
        render!(target, scene, camera; cache)
        @test target.color == reference.color
        @test target.depth == reference.depth
        @test any(>(0.0), target.color)
        materials = only(cache.instanced_materials).materials
        if Base.JLOptions().opt_level > 0
            instanced_frame_allocations(target, scene, camera, cache)
            # Preserve the existing public cached-instance frame budget.
            @test instanced_frame_allocations(target, scene, camera, cache) <= 1024
        end
        set_instance_color!(instances, 1, Color3(0.8, 0.2, 0.1))
        render_pooled!(reference, scene, camera, reference_cache)
        render!(target, scene, camera; cache)
        @test target.color == reference.color
        @test target.depth == reference.depth
        @test only(cache.instanced_materials).materials === materials
    end
end
