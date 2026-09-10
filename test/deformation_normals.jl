using Test
using Diff3D
import LinearAlgebra

@testset "Skin normal directions follow the blended inverse transpose" begin
    n0=normalize(Vec3(1.0,1.0,1.0));t0=normalize(Vec3(1.0,-1.0,0.0))
    bone1=Bone();bone1.rotation=Euler(0.0,0.0,0.3);bone1.scale=Vec3(2.0,0.5,1.0)
    bone2=Bone();bone2.rotation=Euler(0.0,-0.4,0.0);bone2.scale=Vec3(0.5,2.0,1.5)
    bone_worlds=[compute_world_matrix(bone1),compute_world_matrix(bone2)]
    inverse_binds=[mat4_translation(-0.2,0.0,0.0),mat4_rotation_x(0.2)]
    bind=mat4_translation(0.2,-0.1,0.3)*mat4_rotation_z(0.25)*mat4_scaling(1.1,0.9,1.3)
    for mode in (:attached,:detached), reflected in (false,true), morph in (false,true)
        geometry=BufferGeometry([-0.4,-0.3,0.0,0.6,-0.3,0.0,0.0,0.6,0.0],
            repeat([n0.x,n0.y,n0.z],3),Float64[],[1,2,3],3,1)
        set_attribute!(geometry,:tangent,repeat([t0.x,t0.y,t0.z,1.0],3),4)
        morph && set_attribute!(geometry,:morphNormal0,repeat([0.1,-0.2,0.05],3),3)
        chosen_binds=deepcopy(inverse_binds)
        reflected && (chosen_binds[1]=chosen_binds[1]*mat4_scaling(-1.0,1.0,1.0))
        vertex_indices=[(1,1,1,1),(2,1,2,1),(1,2,1,2)]
        vertex_weights=[(1.0,0.0,0.0,0.0),(0.2,0.5,0.3,0.0),(0.3,0.7,0.0,0.0)]
        skin=SkinnedMesh(geometry,MeshNormalMaterial(),Skeleton([bone1,bone2],chosen_binds),
            vertex_indices,vertex_weights;bind_mode=mode,bind_matrix=bind,
            morph_target_influences=morph ? [0.4] : Float64[])
        skin.position=Vec3(0.2,0.1,0.0);skin.scale=Vec3(1.4,0.8,1.1)
        parent=Group();parent.rotation=Euler(0.0,-0.1,0.0);parent.scale=Vec3(0.7,1.2,1.0)
        add!(parent,skin)
        before_positions=copy(geometry.positions);before_normals=copy(geometry.normals)
        posed=Diff3D._skinned_render_geometry(skin)
        cached=deepcopy(posed)
        @test Diff3D._update_skinned_render_geometry!(cached,skin,Mat4{Float64}[],Vec3{Float64}[]) === cached
        @test cached.positions == posed.positions
        @test cached.normals == posed.normals
        @test geometry.positions == before_positions && geometry.normals == before_normals
        prefix=mode===:attached ? Mat4() : compute_world_matrix(skin)*mat4_inverse(bind)
        matrices=[prefix*bone_worlds[i]*chosen_binds[i]*bind for i in 1:2]
        source_normal=morph ? normalize(n0+Vec3(0.1,-0.2,0.05)*0.4) : n0
        for vertex in 1:3
            linear=zeros(BigFloat,3,3)
            for slot in 1:4, row in 1:3, column in 1:3
                linear[row,column] += BigFloat(vertex_weights[vertex][slot])*
                    BigFloat(Diff3D.mat4_get(matrices[vertex_indices[vertex][slot]],row,column))
            end
            expected_n=transpose(LinearAlgebra.inv(linear))*BigFloat[source_normal.x,source_normal.y,source_normal.z]
            expected_n ./= LinearAlgebra.norm(expected_n)
            expected_t=linear*BigFloat[t0.x,t0.y,t0.z]
            expected_t ./= LinearAlgebra.norm(expected_t)
            actual_n=posed.normals[3vertex-2:3vertex]
            actual_t=posed.attributes[:tangent].data[4vertex-3:4vertex-1]
            @test actual_n ≈ Float64.(expected_n) atol=1e-12
            @test actual_t ≈ Float64.(expected_t) atol=1e-12
            !morph && @test abs(sum(actual_n.*actual_t)) < 1e-12
        end
    end

    for scale in (Vec3(2.0,1.0,1.0),Vec3(-2.0,1.0,1.0),
                  Vec3(1e-320,1.0,1.0),Vec3(1e300,1e-300,1.0),Vec3(0.0,1.0,1.0))
        extreme_bone=Bone();extreme_bone.scale=scale
        extreme_geo=BufferGeometry([0.0,0.0,0.0],[1.0,1.0,0.0],Float64[],Int[],1,0)
        extreme_skin=SkinnedMesh(extreme_geo,MeshNormalMaterial(),Skeleton([extreme_bone],[Mat4()]),
            [(1,1,1,1)],[(1.0,0.0,0.0,0.0)])
        extreme_normal=Diff3D._skinned_render_geometry(extreme_skin).normals
        expected_extreme=setprecision(BigFloat,8192) do
            if iszero(scale.x)
                zeros(3) # The existing normal-matrix contract returns zero for singular inverses.
            else
                values=BigFloat[inv(BigFloat(scale.x)),inv(BigFloat(scale.y)),0]
                Float64.(values/LinearAlgebra.norm(values))
            end
        end
        @test all(isfinite,extreme_normal)
        @test extreme_normal ≈ expected_extreme atol=1e-14
    end
    invalid_geo=BufferGeometry([0.0,0.0,0.0],[NaN,0.0,1.0],Float64[],Int[],1,0)
    invalid_skin=SkinnedMesh(invalid_geo,MeshNormalMaterial(),Skeleton([Bone()],[Mat4()]),
        [(1,1,1,1)],[(1.0,0.0,0.0,0.0)])
    @test_throws "SkinnedMesh normals must be finite" Diff3D._skinned_render_geometry(invalid_skin)

    # Reusing a joint blend must still transform each vertex's own normal, and
    # must be reset when the bone palette changes in the following frame.
    reused_bone=Bone();reused_bone.scale=Vec3(2.0,0.5,1.0)
    varying_normals=[1.0,0.0,0.0, 0.0,1.0,0.0, 1.0,1.0,1.0, 1.0,1.0,0.0]
    reused_geo=BufferGeometry(zeros(12),varying_normals,Float64[],Int[],4,0)
    reused_skin=SkinnedMesh(reused_geo,MeshNormalMaterial(),Skeleton([reused_bone],[Mat4()]),
        fill((1,1,1,1),4),fill((1.0,0.0,0.0,0.0),4))
    reused_proxy=Diff3D._skinned_render_geometry(reused_skin)
    for diagonal in (Vec3(2.0,0.5,1.0),Vec3(0.5,2.0,1.5))
        reused_bone.scale=diagonal
        Diff3D._update_skinned_render_geometry!(reused_proxy,reused_skin,Mat4{Float64}[],Vec3{Float64}[])
        for vertex in 1:4
            expected_direction=normalize(Vec3(varying_normals[3vertex-2]/diagonal.x,
                varying_normals[3vertex-1]/diagonal.y,varying_normals[3vertex]/diagonal.z))
            @test reused_proxy.normals[3vertex-2:3vertex] ≈
                  [expected_direction.x,expected_direction.y,expected_direction.z] atol=1e-14
        end
    end
    if Base.JLOptions().opt_level > 0
        function normal_buffer_bytes(skin_object)
            palette=Diff3D._skinning_matrices(skin_object)
            output=zeros(length(skin_object.geometry.normals))
            for _ in 1:3;Diff3D._skin_normal_buffer!(output,skin_object,palette);end
            return @allocated Diff3D._skin_normal_buffer!(output,skin_object,palette)
        end
        @test normal_buffer_bytes(reused_skin) == 0
    end
end
