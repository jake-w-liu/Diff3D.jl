using Test
using Diff3D

@testset "ArrayCamera projects each viewport" begin
    scene = Scene(background=Color3(0.02, 0.03, 0.04))
    add!(scene, Mesh(BoxGeometry(width=1.6, height=1.4, depth=0.8),
                     MeshBasicMaterial(color=Color3(0.8, 0.15, 0.1))))
    sprite = Sprite(SpriteMaterial(color=Color3(0.1, 0.8, 0.2)))
    sprite.position = Vec3(-1.3, 0.3, 0.5)
    add!(scene, sprite)
    points = BufferGeometry([1.2, -0.8, 0.5, 1.3, 0.8, 0.5],
                            Float64[], Float64[], Int[], 2, 0)
    add!(scene, PointsObject(points, PointsMaterial(color=Color3(0.1, 0.2, 0.9),
                                                   size=2.0, size_attenuation=false)))
    line = BufferGeometry([-1.5, -1.1, 0.2, 1.5, -1.1, 0.2],
                          Float64[], Float64[], Int[], 2, 0)
    add!(scene, LineObject(line, LineBasicMaterial(color=Color3(0.9, 0.8, 0.1))))
    pane = Mesh(PlaneGeometry(width=1.5, height=0.7),
                MeshBasicMaterial(color=Color3(0.3, 0.7, 0.9), transparent=true, opacity=0.4))
    pane.position = Vec3(0.25, 0.1, 0.8)
    add!(scene, pane)

    first_camera = PerspectiveCamera(fov=pi/3, aspect=0.8)
    second_camera = PerspectiveCamera(fov=pi/3, aspect=1.2)
    second_camera.position = Vec3(1.0, 0.5, 5.0)
    before = (projection_matrix(first_camera), projection_matrix(second_camera),
              first_camera.position, second_camera.position)
    width, height = 36, 38
    initial = Color3(0.3, 0.2, 0.4)

    function reference(camera, shading, scissor)
        result = RenderTarget(width, height)
        clear!(result, initial)
        inside(x, y) = scissor === nothing ||
            (scissor[1] < x <= scissor[1] + scissor[3] &&
             scissor[2] < y <= scissor[2] + scissor[4])
        for y in 1:height, x in 1:width
            inside(x, y) || continue
            result.color[y, x, :] .= (scene.background.r, scene.background.g, scene.background.b)
        end
        for (subcamera, (sx, sy, sw, sh)) in zip(camera.cameras, camera.viewports)
            sw > 0 && sh > 0 || continue
            tile = RenderTarget(sw, sh)
            render!(tile, scene, subcamera; shading=shading)
            for y in 1:sh, x in 1:sw
                gx, gy = sx + x, sy + y
                1 <= gx <= width && 1 <= gy <= height && inside(gx, gy) || continue
                result.color[gy, gx, :] .= tile.color[y, x, :]
                result.depth[gy, gx] = tile.depth[y, x]
            end
        end
        return result
    end

    layouts = (
        [(0, 0, 17, 23), (17, 0, 19, 23), (0, 23, 18, 15)],
        [(-3, 4, 23, 20), (14, 12, 26, 22), (40, 40, 3, 3)],
        [(2, -5, 29, 25), (0, 0, 0, 0), (4, 26, 25, 18)],
    )
    cache = RenderCache()
    for viewports in layouts, shading in (:flat, :smooth),
        scissor in (nothing, (7, 5, 20, 28)), frustum_cull in (false, true)
        camera = ArrayCamera([first_camera, second_camera, first_camera], viewports)
        expected = reference(camera, shading, scissor)
        @test any(>(0.7), expected.color)
        for scratch in (nothing, cache)
            actual = RenderTarget(width, height)
            clear!(actual, initial)
            render!(actual, scene, camera; shading=shading, scissor=scissor,
                    scissor_test=scissor !== nothing, frustum_cull=frustum_cull, cache=scratch)
            @test actual.color ≈ expected.color atol=1e-12
            @test isinf.(actual.depth) == isinf.(expected.depth)
            mask = isfinite.(expected.depth)
            @test actual.depth[mask] ≈ expected.depth[mask] atol=1e-12
        end
    end
    @test projection_matrix(first_camera) == before[1]
    @test projection_matrix(second_camera) == before[2]
    @test first_camera.position == before[3]
    @test second_camera.position == before[4]
end
