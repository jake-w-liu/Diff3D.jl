using Test
using Diff3D
using Base64

include("fixtures/skin_binding.jl")

@testset "glTF skin binding and world-space poses" begin
    mktempdir() do directory
        for container in (:gltf,:glb), inverse_mode in (:omitted,:identity,:custom),
            mesh_scale in (Vec3(1.0,1.0,1.0),Vec3(0.0,0.0,0.0),Vec3(-2.0,0.5,1.5))
            asset,skin,inverse_matrices=skin_binding_fixture(directory,container,inverse_mode,mesh_scale)
            @test skin.bind_matrix == Mat4()
            @test skin.skeleton.bind_inverses == inverse_matrices
            mesh_node=first(get_children(asset.scene))
            ordinary_child=only(filter(object->object.name=="ordinary-child",get_children(mesh_node)))
            @test compute_world_matrix(ordinary_child) ==
                mat4_translation(10.0,0.0,0.0)*mat4_scaling(mesh_scale.x,mesh_scale.y,mesh_scale.z)*mat4_translation(0.3,0.2,0.0)
            expected_positions=skin_binding_reference_positions(skin.geometry,inverse_matrices)
            @test all(norm(actual-expected)<1e-6 for (actual,expected) in zip(apply_skinning(skin;space=:world),expected_positions))
            skin.material=MeshBasicMaterial(color=Color3(0.0,0.0,1.0),side=:double)
            skin.cast_shadow=true
            reference_geometry=deepcopy(skin.geometry)
            reference_geometry.positions=reduce(vcat,([point.x,point.y,point.z] for point in expected_positions))
            reference_scene=Scene();add!(reference_scene,Mesh(reference_geometry,skin.material;cast_shadow=true))
            center=sum(expected_positions)/length(expected_positions)
            camera=OrthographicCamera(left=-1.0,right=1.0,bottom=-1.0,top=1.0,near=0.1,far=10.0)
            camera.position=center+Vec3(0.0,0.0,4.0);camera.target=center
            expected_target=RenderTarget(24,24);render!(expected_target,reference_scene,camera)
            @test count(>(0.5),expected_target.color[:,:,3])>10
            for method in (:main,:cached,:pooled,:tiled)
                target=RenderTarget(24,24)
                if method===:pooled
                    render_pooled!(target,asset.scene,camera,RenderCache())
                elseif method===:tiled
                    render_tiled!(target,asset.scene,camera;tiles=1,cache=[RenderCache()])
                else
                    render!(target,asset.scene,camera;cache=method===:cached ? RenderCache() : nothing)
                end
                @test target.color ≈ expected_target.color atol=1e-12
            end
            ray=Raycaster(center+Vec3(0.0,0.0,4.0),Vec3(0.0,0.0,-1.0))
            hits=raycast(ray,skin)
            @test length(hits)==1 && only(hits).object===skin
            sun=DirectionalLight(position=center+Vec3(0.0,0.0,4.0))
            actual_shadow=compute_shadow_map(asset.scene,sun;resolution=16)
            expected_shadow=compute_shadow_map(reference_scene,sun;resolution=16)
            @test actual_shadow.depth ≈ expected_shadow.depth
        end
    end
end

@testset "Skin coordinate spaces and near-unit weights" begin
    bone=Bone();bone.position=Vec3(1.0,0.0,0.0)
    geometry=BufferGeometry([0.2,0.3,0.4],Float64[],Float64[],Int[],1,0)
    for mode in (:attached,:detached)
        skin=SkinnedMesh(geometry,MeshBasicMaterial(),Skeleton([bone],[Mat4()]),
            [(1,1,1,1)],[(0.5000002,0.4999999,0.0,0.0)];bind_mode=mode,
            bind_matrix=mat4_translation(2.0,0.0,0.0))
        skin.position=Vec3(3.0,-1.0,0.0);skin.scale=Vec3(1.2,0.7,1.1)
        local_position=only(apply_skinning(skin))
        @test norm(only(apply_skinning(skin;space=:world))-mat4_transform_point(compute_world_matrix(skin),local_position))<1e-12
        @test_throws "skinning space must be :local or :world" apply_skinning(skin;space=:bad)
    end
end

@testset "Skin world poses follow joint and outer-scene motion" begin
    mktempdir() do directory
        asset,skin,inverse_matrices=skin_binding_fixture(directory,:gltf,:omitted,Vec3())
        outer=Group();outer.position=Vec3(-5.0,0.2,0.0);outer.rotation=Euler(0.0,0.0,0.1)
        outer.scale=Vec3(1.5,0.7,1.2);add!(outer,asset.scene)
        skin.material=MeshBasicMaterial(color=Color3(0.0,0.0,1.0),side=:double)
        cache=RenderCache()
        for shift in (0.0,0.3,-0.2)
            skin.skeleton.bones[1].position=Vec3(1.0+shift,0.0,0.0)
            asset.scene.position=Vec3(0.1*shift,0.0,0.0)
            expected_parent=mat4_translation(-5.0,0.2,0.0)*mat4_rotation_z(0.1)*
                mat4_scaling(1.5,0.7,1.2)*mat4_translation(0.1*shift,0.0,0.0)
            expected_world=Vec3{Float64}[]
            for vertex in 1:skin.geometry.n_vertices
                base=get_vertex(skin.geometry,vertex)
                local_pose=mat4_transform_point(mat4_translation(5.0+shift,0.0,0.0),base)*0.25+
                    mat4_transform_point(mat4_translation(5.0,0.4,0.0)*mat4_scaling(1.2,0.8,1.0),base)*0.75
                push!(expected_world,mat4_transform_point(expected_parent,local_pose))
            end
            actual_world=apply_skinning(skin;space=:world)
            @test length(actual_world)==length(expected_world)
            @test all(norm(actual_world[i]-expected_world[i])<1e-12 for i in eachindex(expected_world))
            reference_geo=deepcopy(skin.geometry)
            reference_geo.positions=reduce(vcat,([point.x,point.y,point.z] for point in expected_world))
            reference=Scene();add!(reference,Mesh(reference_geo,skin.material))
            camera=OrthographicCamera(left=-1.0,right=1.0,bottom=-1.0,top=1.0,near=0.1,far=10.0)
            camera.position=Vec3(0.0,0.0,4.0)
            actual_target=RenderTarget(24,24);expected_target=RenderTarget(24,24)
            render!(actual_target,asset.scene,camera;cache=cache)
            render!(expected_target,reference,camera)
            @test actual_target.color == expected_target.color
        end
    end
end

@testset "glTF inverse binds have affine fourth rows" begin
    for slot in (4,8,12,16)
        values=Float32.(collect(Mat4().e));values[slot]=slot==16 ? 0.0f0 : 0.1f0
        bytes=collect(reinterpret(UInt8,htol.(reinterpret(UInt32,values))))
        document=Dict{String,Any}("accessors"=>[Dict{String,Any}("bufferView"=>0,
            "componentType"=>5126,"count"=>1,"type"=>"MAT4")],
            "bufferViews"=>[Dict{String,Any}("buffer"=>0,"byteLength"=>length(bytes))])
        @test_throws "inverseBindMatrices must have affine fourth rows" Diff3D._gltf_inverse_bind_matrices(
            document,[bytes],Dict("inverseBindMatrices"=>0),1)
    end
end
