using Test
using Diff3D

function camera_soft_scene_allocations(scene, camera, workspace)
    soft_render_scene(scene, camera, 1, 1; workspace)
    return @allocated soft_render_scene(scene, camera, 1, 1; workspace)
end

@testset "Camera poses retain concrete numeric types" begin
    for Camera in (PerspectiveCamera, OrthographicCamera),
        rotation_driven in (false, true), ignore_parent_scale in (false, true),
        parented in (false, true)
        camera = Camera(; rotation_driven)
        camera.ignore_parent_scale = ignore_parent_scale
        camera.rotation = Euler(0.2, -0.3, 0.1)
        if parented
            parent = Group()
            parent.position = Vec3(1.0, 2.0, -3.0)
            parent.rotation = Euler(-0.1, 0.4, 0.2)
            parent.scale = Vec3(2.0, 0.5, 3.0)
            add!(parent, camera)
        end
        pose = @inferred Diff3D._camera_rotation_pose(camera)
        @test pose isa NTuple{3,Vec3{Float64}}
        world_pose = @inferred Diff3D._camera_world_pose(camera)
        @test world_pose isa NTuple{3,Vec3{Float64}}
        view = @inferred view_matrix(camera)
        @test view isa Mat4{Float64}
        @test all(isfinite, view.e)
    end
end

@testset "Soft scene workspace allocation stays bounded as meshes grow" begin
    for Camera in (PerspectiveCamera, OrthographicCamera),
        Material in (MeshBasicMaterial, MeshLambertMaterial), count in (0, 1, 10, 100)
        scene = Scene()
        add!(scene, AmbientLight(intensity=0.5))
        for index in 1:count
            mesh = Mesh(PlaneGeometry(), Material())
            mesh.position = Vec3(2.0 * (index - 1), 0.0, 0.0)
            add!(scene, mesh)
        end
        camera = Camera()
        camera.position = Vec3(0.0, 0.0, 2.0)
        workspace = SoftRenderSceneWorkspace()
        image = soft_render_scene(scene, camera, 1, 1; workspace)
        @test image === workspace.soft.image
        @test image == soft_render_scene(scene, camera, 1, 1)
        count > 0 && @test any(>(0.0), image)
        if Base.JLOptions().opt_level > 0
            camera_soft_scene_allocations(scene, camera, workspace)
            # The existing soft_render_scene budget must hold beyond one scene size.
            @test camera_soft_scene_allocations(scene, camera, workspace) <= 256
        end
    end
end
