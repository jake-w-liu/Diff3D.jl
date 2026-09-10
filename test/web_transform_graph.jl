using Test
using Diff3D

@testset "Exported transform carriers retain their world hierarchy" begin
    for instanced in (false,true)
        outside=Group()
        outside.position=Vec3(0.2,0.3,0.4)
        outside.rotation=Euler(0.1,0.2,-0.1)
        scene=Scene()
        scene.position=Vec3(0.1,0.0,0.0)
        add!(outside,scene)
        material=MeshBasicMaterial(transparent=true,opacity=0.5)
        parent=instanced ? InstancedMesh(PlaneGeometry(),material,2) : Mesh(PlaneGeometry(),material)
        parent.position=Vec3(0.6,0.0,0.0)
        parent.scale=Vec3(1.2,0.7,1.1)
        if instanced
            set_instance_matrix!(parent,1,mat4_translation(-1.0,0.0,0.0))
            set_instance_matrix!(parent,2,mat4_translation(1.0,0.0,0.0))
        end
        middle=Group()
        middle.rotation=Euler(0.0,0.2,0.1)
        child=Mesh(PlaneGeometry(),MeshBasicMaterial())
        add!(middle,child);add!(parent,middle);add!(scene,parent)
        nodes=Diff3D._json_parse.(Diff3D._web_collect_transform_nodes(scene,Set([scene.id])))
        draws=Diff3D._json_parse.(Diff3D._web_collect_drawables(scene))
        @test any(node->node["id"]==scene.id,nodes)
        for (payload,object) in ((only(filter(n->n["id"]==middle.id,nodes)),middle),
                                  (only(filter(n->n["id"]==child.id,draws)),child))
            @test payload["matrix"] ≈ collect(compute_world_matrix(object).e)
            @test payload["parentMatrix"] ≈ collect(compute_world_matrix(get_parent(object)).e)
        end
        parent_payloads=filter(n->n["id"]==parent.id,draws)
        @test length(parent_payloads)==(instanced ? 2 : 1)
        for (index,payload) in enumerate(parent_payloads)
            expected=compute_world_matrix(parent)
            instanced && (expected=expected*parent.instance_matrices[index])
            @test payload["matrix"] ≈ collect(expected.e)
            @test payload["parentMatrix"] ≈ collect(compute_world_matrix(scene).e)
        end
    end
end
