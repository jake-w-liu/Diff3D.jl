using Test
using Diff3D

@testset "WebGL distinguishes empty and absent instance batches" begin
    for count in (0, 1, 3), (mode, material) in (
        (:triangles, MeshBasicMaterial()),
        (:triangles, MeshBasicMaterial(wireframe=true)),
        (:lines, LineBasicMaterial()),
        (:points, PointsMaterial()),
    )
        scene = Scene()
        batch = InstancedMesh(BoxGeometry(), material, count; draw_mode=mode)
        add!(scene, batch)
        payload = Diff3D._json_parse(only(Diff3D._web_collect_drawables(scene)))
        @test payload["instanceMatrices"] isa Vector
        if payload["instanceMatrices"] isa Vector
            @test length(payload["instanceMatrices"]) == count
        end
    end
    for count in (0, 1, 3)
        scene = Scene()
        batch = InstancedMesh(BoxGeometry(), MeshBasicMaterial(transparent=true, opacity=0.5), count)
        add!(scene, batch)
        payloads = Diff3D._web_collect_drawables(scene)
        @test length(payloads) == count
        for payload in payloads
            parsed = Diff3D._json_parse(payload)
            @test parsed["instanceMatrices"] === nothing
            @test parsed["instanceMatrix"] isa Vector
        end
    end
    ordinary = Scene()
    add!(ordinary, Mesh(BoxGeometry(), MeshBasicMaterial()))
    @test Diff3D._json_parse(only(Diff3D._web_collect_drawables(ordinary)))["instanceMatrices"] === nothing
end
