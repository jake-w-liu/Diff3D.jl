using Test
using Diff3D

@testset "Soft scenes include posed skins and triangle instances" begin
    camera=PerspectiveCamera();camera.position=Vec3(0.0,0.0,3.0)
    geometry=PlaneGeometry(width=0.6,height=0.6)
    material=MeshBasicMaterial(color=Color3(0.8,0.7,0.6))
    function soft_image(root,view_camera; workspace=nothing)
        copy(soft_render_scene(root,view_camera,12,10;sigma=0.2,gamma=0.5,workspace=workspace))
    end
    for case in (:skin,:instances)
        scene=Scene();reference=Scene();workspace=SoftRenderSceneWorkspace()
        if case===:skin
            bone=Bone();bone.position=Vec3(0.3,0.0,0.0)
            object=SkinnedMesh(geometry,material,Skeleton([bone],[Mat4()]),
                fill((1,1,1,1),geometry.n_vertices),fill((1.0,0.0,0.0,0.0),geometry.n_vertices))
            object.position=Vec3(4.0,0.0,0.0);object.scale=Vec3()
            expected=Mesh(geometry,material);expected.position=Vec3(0.3,0.0,0.0)
            add!(reference,expected)
        else
            object=InstancedMesh(geometry,material,2)
            set_instance_matrix!(object,1,mat4_translation(-0.4,0.0,0.0))
            set_instance_matrix!(object,2,mat4_translation(0.4,0.0,0.0))
            set_instance_color!(object,1,Color3(1.0,0.2,0.1))
            set_instance_color!(object,2,Color3(0.1,0.3,1.0))
            for (x,tint) in ((-0.4,Color3(0.8,0.14,0.06)),(0.4,Color3(0.08,0.21,0.6)))
                expected=Mesh(geometry,MeshBasicMaterial(color=tint));expected.position=Vec3(x,0.0,0.0)
                add!(reference,expected)
            end
        end
        add!(scene,object)
        expected_image=soft_image(reference,camera)
        @test maximum(expected_image)>0.1
        @test soft_image(scene,camera) ≈ expected_image atol=1e-12
        @test soft_image(scene,camera;workspace=workspace) ≈ expected_image atol=1e-12
        if case===:skin
            bone.position=Vec3(-0.2,0.1,0.0)
            only(get_children(reference)).position=Vec3(-0.2,0.1,0.0)
        else
            set_instance_matrix!(object,2,mat4_translation(0.2,0.3,0.0))
            get_children(reference)[2].position=Vec3(0.2,0.3,0.0)
        end
        @test soft_image(scene,camera;workspace=workspace) ≈ soft_image(reference,camera) atol=1e-12
        layers_set!(object_layers(object),3)
        @test maximum(soft_image(scene,camera;workspace=workspace))==0.0
        layers_set!(object_layers(camera),3)
        for reference_object in get_children(reference);layers_set!(object_layers(reference_object),3);end
        @test soft_image(scene,camera;workspace=workspace) ≈ soft_image(reference,camera) atol=1e-12
        layers_set!(object_layers(camera),0)
    end

    # Selecting one complete triangle must match an independently selected mesh.
    ranged=PlaneGeometry(width=1.0,height=1.0)
    set_draw_range!(ranged,4,3)
    selected=deepcopy(ranged);selected.indices=selected.indices[4:6];selected.n_faces=1;selected.draw_range=nothing
    ranged_scene=Scene();selected_scene=Scene()
    add!(ranged_scene,InstancedMesh(ranged,material,1));add!(selected_scene,Mesh(selected,material))
    @test soft_image(ranged_scene,camera) ≈ soft_image(selected_scene,camera) atol=1e-12
    ordinary_ranged=Scene();add!(ordinary_ranged,Mesh(ranged,material))
    @test soft_image(ordinary_ranged,camera) ≈ soft_image(selected_scene,camera) atol=1e-12

    empty_scene=Scene();add!(empty_scene,InstancedMesh(geometry,material,0))
    @test maximum(soft_image(empty_scene,camera))==0.0
    for mode in (:points,:lines,:line_strip,:line_loop)
        primitive_scene=Scene();add!(primitive_scene,InstancedMesh(geometry,material,1;draw_mode=mode))
        @test maximum(soft_image(primitive_scene,camera))==0.0
    end
    parent=Group();parent.position=Vec3(0.3,0.0,0.0)
    parented_scene=Scene();add!(parent,parented_scene)
    parented_object=InstancedMesh(geometry,material,1);add!(parented_scene,parented_object)
    positioned_scene=Scene();positioned_object=Mesh(geometry,material);positioned_object.position=parent.position;add!(positioned_scene,positioned_object)
    @test soft_image(parented_scene,camera) ≈ soft_image(positioned_scene,camera) atol=1e-12

    # A skinned morph is evaluated before the joint transform and draw range.
    morph_geometry=deepcopy(ranged)
    set_attribute!(morph_geometry,:morphPosition0,
        repeat([0.2,0.1,0.0],morph_geometry.n_vertices),3)
    morph_bone=Bone();morph_bone.scale=Vec3(1.2,0.8,1.0)
    morph_skin=SkinnedMesh(morph_geometry,material,Skeleton([morph_bone],[Mat4()]),
        fill((1,1,1,1),morph_geometry.n_vertices),
        fill((1.0,0.0,0.0,0.0),morph_geometry.n_vertices);
        morph_target_influences=[0.5])
    morph_scene=Scene();add!(morph_scene,morph_skin)
    morph_workspace=SoftRenderSceneWorkspace()
    for weight in (0.5,-0.25,0.0)
        morph_skin.morph_target_influences[1]=weight
        baked_geometry=deepcopy(selected)
        for vertex in 1:baked_geometry.n_vertices
            baked_geometry.positions[3vertex-2]=1.2*(selected.positions[3vertex-2]+0.2weight)
            baked_geometry.positions[3vertex-1]=0.8*(selected.positions[3vertex-1]+0.1weight)
        end
        baked_scene=Scene();add!(baked_scene,Mesh(baked_geometry,material))
        @test soft_image(morph_scene,camera;workspace=morph_workspace) ≈ soft_image(baked_scene,camera) atol=1e-12
    end

    # Reuse must follow both material/color edits and removal of complete batches.
    reused_scene=Scene();reused_workspace=SoftRenderSceneWorkspace()
    reused_instances=InstancedMesh(geometry,material,2);add!(reused_scene,reused_instances)
    soft_image(reused_scene,camera;workspace=reused_workspace)
    resized_reference=Scene();add!(resized_reference,Mesh(geometry,material))
    resize!(reused_instances.instance_matrices,1);resize!(reused_instances.instance_colors,1)
    @test soft_image(reused_scene,camera;workspace=reused_workspace) ≈ soft_image(resized_reference,camera) atol=1e-12
    reused_instances.material=MeshBasicMaterial(color=Color3(0.4,0.8,0.2))
    set_instance_color!(reused_instances,1,Color3(0.5,0.25,1.0))
    only(get_children(resized_reference)).material=MeshBasicMaterial(color=Color3(0.2,0.2,0.2))
    @test soft_image(reused_scene,camera;workspace=reused_workspace) ≈ soft_image(resized_reference,camera) atol=1e-12
    remove!(reused_scene,reused_instances)
    @test maximum(soft_image(reused_scene,camera;workspace=reused_workspace))==0.0
    @test isempty(reused_workspace.instanced)
    @test isempty(reused_workspace.instanced_materials)

    invalid_scene=Scene();invalid_instances=InstancedMesh(geometry,material,1)
    add!(invalid_scene,invalid_instances)
    empty!(invalid_instances.instance_colors)
    @test_throws "instance_colors length must match" soft_image(invalid_scene,camera)
    # Invisible and unselected objects do not become validation failures.
    invalid_instances.visible=false
    @test maximum(soft_image(invalid_scene,camera))==0.0
    invalid_instances.visible=true;layers_set!(object_layers(invalid_instances),1)
    @test maximum(soft_image(invalid_scene,camera))==0.0
    layers_set!(object_layers(invalid_instances),0)
    push!(invalid_instances.instance_colors,Color3(1.0,1.0,1.0))
    invalid_instances.instance_matrices[1]=mat4_translation(NaN,0.0,0.0)
    @test_throws "instance matrix 1 must be finite" soft_image(invalid_scene,camera;workspace=reused_workspace)
    invalid_instances.instance_matrices[1]=Mat4()
    invalid_geometry=deepcopy(geometry);invalid_geometry.indices[1]=geometry.n_vertices+1
    invalid_instances.geometry=invalid_geometry
    @test_throws ArgumentError soft_image(invalid_scene,camera;workspace=reused_workspace)

    # Released positional workspace constructors still delegate to reusable buffers.
    for fields in (5,7)
        buffers=(Vec3{Float64}[],NTuple{3,Int}[],Color3{Float64}[],Color3{Float64}[],
                 SoftRenderWorkspace(),Mesh[],Diff3D.SceneLight[])
        constructed=SoftRenderSceneWorkspace(buffers[1:fields]...)
        @test constructed.vertices === buffers[1]
        @test soft_image(positioned_scene,camera;workspace=constructed) ≈ soft_image(positioned_scene,camera) atol=1e-12
    end
end
