using Test
using Diff3D

@testset "Deformed tangent frames preserve handedness" begin
    for diagonal in (Vec3(-2.0,1.0,0.5),Vec3(2.0,-1.0,0.5),Vec3(-2.0,-1.0,0.5),Vec3(2.0,1.0,0.5)),
        tangent in (Vec3(1.0,0.0,0.0),Vec3(0.0,1.0,0.0)), sign in (-1.0,1.0), stride in (3,4,5)
        bone=Bone();bone.rotation=Euler(0.0,0.0,0.3);bone.scale=diagonal
        geometry=BufferGeometry([0.0,0.0,0.0],[0.0,0.0,1.0],Float64[],Int[],1,0)
        data=[tangent.x,tangent.y,tangent.z]
        stride>=4 && push!(data,sign)
        stride==5 && push!(data,42.0)
        set_attribute!(geometry,:tangent,data,stride)
        skin=SkinnedMesh(geometry,MeshNormalMaterial(),Skeleton([bone],[Mat4()]),
            [(1,1,1,1)],[(1.0,0.0,0.0,0.0)])
        posed=Diff3D._skinned_render_geometry(skin)
        actual=copy(get_attribute(posed,:tangent).data)
        expected_tangent=normalize(mat4_transform_direction(compute_world_matrix(bone),tangent))
        @test actual[1:3] ≈ [expected_tangent.x,expected_tangent.y,expected_tangent.z] atol=1e-14
        if stride>=4
            expected_sign=sign*(diagonal.x*diagonal.y*diagonal.z<0 ? -1.0 : 1.0)
            @test actual[4] == expected_sign
            normal=Vec3(posed.normals...)
            expected_bitangent=normalize(mat4_transform_direction(compute_world_matrix(bone),cross(Vec3(0.0,0.0,1.0),tangent)*sign))
            actual_bitangent=normalize(cross(normal,Vec3(actual[1:3]...))*actual[4])
            @test norm(actual_bitangent-expected_bitangent)<1e-14
        end
        stride==5 && @test actual[5] == 42.0
        for _ in 1:2
            @test Diff3D._update_skinned_render_geometry!(posed,skin,Mat4{Float64}[],Vec3{Float64}[]) === posed
            @test get_attribute(posed,:tangent).data == actual
        end
        @test get_attribute(geometry,:tangent).data == data
    end
end

@testset "Tangent orientation reuse follows influences and later poses" begin
    geometry=BufferGeometry(zeros(12),repeat([0.0,0.0,1.0],4),Float64[],Int[],4,0)
    set_attribute!(geometry,:tangent,repeat([1.0,0.0,0.0,1.0],4),4)
    set_attribute!(geometry,:morphTangent0,repeat([0.0,1.0,0.0],4),3)
    positive=Bone();positive.scale=Vec3(2.0,1.0,1.0)
    negative=Bone();negative.scale=Vec3(-2.0,1.0,1.0)
    indices=[(1,2,1,1),(1,2,1,1),(1,2,1,1),(2,1,1,1)]
    weights=[(0.25,0.75,0.0,0.0),(0.25,0.75,0.0,0.0),
             (0.75,0.25,0.0,0.0),(0.75,0.25,0.0,0.0)]
    skin=SkinnedMesh(geometry,MeshNormalMaterial(),Skeleton([positive,negative],[Mat4(),Mat4()]),
        indices,weights;morph_target_influences=[0.5])
    cached=Diff3D._skinned_render_geometry(skin)
    for pose in (1.0,-1.0)
        positive.scale=Vec3(2pose,1.0,1.0);negative.scale=Vec3(-2pose,1.0,1.0)
        Diff3D._update_skinned_render_geometry!(cached,skin,Mat4{Float64}[],Vec3{Float64}[])
        fresh=Diff3D._skinned_render_geometry(skin)
        @test get_attribute(cached,:tangent).data==get_attribute(fresh,:tangent).data
        for vertex in 1:4
            scale_x=sum(weights[vertex][slot]*(indices[vertex][slot]==1 ? 2pose : -2pose) for slot in 1:4)
            expected=normalize(Vec3(scale_x,0.5,0.0))
            actual=get_attribute(cached,:tangent).data[4vertex-3:4vertex]
            @test actual[1:3]≈[expected.x,expected.y,expected.z] atol=1e-14
            @test actual[4]==(scale_x<0 ? -1.0 : 1.0)
        end
    end
    @test get_attribute(geometry,:tangent).data==repeat([1.0,0.0,0.0,1.0],4)
end
