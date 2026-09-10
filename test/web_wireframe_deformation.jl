using Diff3D, Test

@testset "Web wireframes retain deformation and selected topology" begin
    geometry=PlaneGeometry(width=1.0,height=1.0)
    set_attribute!(geometry,:morphPosition0,
        repeat([0.2,0.1,0.0],geometry.n_vertices),3)
    set_draw_range!(geometry,4,3)
    material=MeshBasicMaterial(color=Color3(0.2,0.4,0.8),wireframe=true)
    before=deepcopy(geometry)
    for kind in (:mesh,:skin,:instances)
        scene=Scene()
        object=if kind===:skin
            bone=Bone();bone.position=Vec3(0.3,0.0,0.0)
            SkinnedMesh(geometry,material,Skeleton([bone],[Mat4()]),
                fill((1,1,1,1),geometry.n_vertices),
                fill((1.0,0.0,0.0,0.0),geometry.n_vertices);
                morph_target_influences=[0.5],morph_target_names=["shift"])
        elseif kind===:mesh
            Mesh(geometry,material;morph_target_influences=[0.5],morph_target_names=["shift"])
        else
            InstancedMesh(geometry,material,2)
        end
        object.position=Vec3(0.1,0.0,0.0)
        add!(scene,object)
        payload=Diff3D._json_parse(only(Diff3D._web_collect_drawables(scene)))
        streamed=IOBuffer()
        Diff3D._web_write_drawables_json(streamed,scene)
        @test only(Diff3D._json_parse(String(take!(streamed))))==payload
        @test payload["mode"]=="lines"
        @test payload["id"]==object.id
        @test length(payload["indices"])==6
        @test payload["drawStart"]==0
        @test payload["drawCount"]==6
        if kind!==:instances
            @test payload["morphWeights"]==[0.5]
            @test length(payload["morphTargets"])==1
            if length(payload["morphTargets"])==1
                @test payload["morphTargets"][1]==repeat([0.2,0.1,0.0],length(payload["positions"])÷3)
            end
        else
            @test length(payload["instanceMatrices"])==2
        end
        if kind===:skin
            @test payload["skin"]!==nothing
            if payload["skin"]!==nothing
                @test length(payload["skin"]["weights"])==4*length(payload["positions"])÷3
                @test payload["skin"]["bones"][1]["matrix"][13]≈0.3
            end
        end
        @test geometry.positions==before.positions
        @test geometry.indices==before.indices
        @test geometry.draw_range==before.draw_range
        @test get_attribute(geometry,:morphPosition0).data==get_attribute(before,:morphPosition0).data
    end

    empty_range_geometry=deepcopy(geometry);set_draw_range!(empty_range_geometry,1,0)
    empty_range_scene=Scene();add!(empty_range_scene,Mesh(empty_range_geometry,material))
    empty_payload=Diff3D._json_parse(only(Diff3D._web_collect_drawables(empty_range_scene)))
    @test empty_payload["drawCount"]==0

    # Triangle geometry requires an index buffer, including in wireframe mode.
    unindexed=BufferGeometry([0.0,0.0,0.0,1.0,0.0,0.0,0.0,1.0,0.0],
                             Float64[],Float64[],Int[],3,1)
    unindexed_scene=Scene();add!(unindexed_scene,Mesh(unindexed,material))
    @test_throws "indices length must cover n_faces" Diff3D._web_collect_drawables(unindexed_scene)
    unindexed.indices=[1,2,3]
    unindexed_payload=Diff3D._json_parse(only(Diff3D._web_collect_drawables(unindexed_scene)))
    @test unindexed_payload["indices"]==[0,1,1,2,0,2]
    @test unindexed_payload["drawCount"]==6
end
