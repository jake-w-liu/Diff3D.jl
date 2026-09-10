using Test
using Diff3D

@testset "Parented render roots retain ancestor transforms" begin
    child_scene = Scene(background=Color3(0.02, 0.03, 0.04))
    child_scene.position = Vec3(0.1, 0.0, -0.2)
    child_scene.rotation = Euler(0.1, 0.0, 0.0)
    inner = Group()
    inner.scale = Vec3(1.1, 0.9, 1.2)
    outer = Group()
    outer.position = Vec3(0.8, 0.0, 0.0)
    outer.rotation = Euler(0.0, 0.15, 0.2)
    add!(inner, child_scene)
    add!(outer, inner)
    containing_scene = Scene(background=child_scene.background)
    add!(containing_scene, outer)

    mesh = Mesh(BoxGeometry(width=0.8, height=0.7, depth=0.5),
                MeshBasicMaterial(color=Color3(0.8, 0.2, 0.1)))
    add!(child_scene, mesh)
    instances = InstancedMesh(PlaneGeometry(width=0.3, height=0.3),
                              MeshBasicMaterial(color=Color3(0.6, 0.2, 0.8)), 1)
    set_instance_matrix!(instances, 1, mat4_translation(-0.6, -0.5, 0.0))
    add!(child_scene, instances)
    points = BufferGeometry([0.7, 0.5, 0.3], Float64[], Float64[], Int[], 1, 0)
    add!(child_scene, PointsObject(points, PointsMaterial(size=3.0, color=Color3(0.0, 1.0, 0.0))))
    line = BufferGeometry([-0.8, -0.7, 0.1, 0.8, -0.7, 0.1],
                          Float64[], Float64[], Int[], 2, 0)
    add!(child_scene, LineSegments(line, LineBasicMaterial(color=Color3(0.2, 0.3, 1.0))))
    sprite = Sprite(SpriteMaterial(color=Color3(0.1, 0.7, 0.8)))
    sprite.position = Vec3(-0.7, 0.5, 0.0)
    sprite.scale = Vec3(0.4, 0.4, 0.4)
    add!(child_scene, sprite)

    camera = PerspectiveCamera()
    cache = RenderCache()
    tiled_cache = [RenderCache() for _ in 1:Threads.nthreads()]
    local_before = compute_local_matrix(child_scene)
    for position in (Vec3(0.8, 0.0, 0.0), Vec3(-0.5, 0.2, 0.1))
        outer.position = position
        for shading in (:flat, :smooth), scratch in (nothing, cache)
            actual, expected = RenderTarget(24, 24), RenderTarget(24, 24)
            render!(actual, child_scene, camera; shading=shading, cache=scratch)
            render!(expected, containing_scene, camera; shading=shading)
            @test any(>(0.5), expected.color)
            @test actual.color ≈ expected.color atol=1e-12
            @test isinf.(actual.depth) == isinf.(expected.depth)
        end
        @test only(cache.mesh_worlds).e == compute_world_matrix(mesh).e
        for draw in (render_lines!, render_points!, render_sprites!), scratch in (nothing, cache)
            actual, expected = RenderTarget(24, 24), RenderTarget(24, 24)
            draw(actual, child_scene, camera; cache=scratch)
            draw(expected, containing_scene, camera)
            @test any(>(0.0), expected.color)
            @test actual.color ≈ expected.color atol=1e-12
        end
        pooled, expected_pooled = RenderTarget(24, 24), RenderTarget(24, 24)
        render_pooled!(pooled, child_scene, camera, cache)
        render_pooled!(expected_pooled, containing_scene, camera, RenderCache())
        @test pooled.color ≈ expected_pooled.color atol=1e-12
        tiled, expected_tiled = RenderTarget(24, 24), RenderTarget(24, 24)
        render_tiled!(tiled, child_scene, camera; tiles=2, cache=tiled_cache)
        render_tiled!(expected_tiled, containing_scene, camera; tiles=2)
        @test tiled.color ≈ expected_tiled.color atol=1e-12
        @test compute_local_matrix(child_scene).e == local_before.e
    end
end
