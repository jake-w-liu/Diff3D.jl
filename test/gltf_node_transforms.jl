using Test
using Diff3D
using Base64

@testset "glTF node transforms preserve authored components" begin
    function node_transform_document(node_definition, kind)
        encoded_node=deepcopy(node_definition)
        encoded_document=Dict{String,Any}("nodes"=>[encoded_node],"scene"=>0,
            "scenes"=>[Dict{String,Any}("nodes"=>[0])])
        if kind===:bone
            encoded_document["skins"]=[Dict{String,Any}("joints"=>[0])]
        elseif kind===:perspective || kind===:orthographic
            encoded_node["camera"]=0
            camera_definition = kind===:perspective ?
                Dict{String,Any}("type"=>"perspective","perspective"=>Dict("yfov"=>1.0,"znear"=>0.1)) :
                Dict{String,Any}("type"=>"orthographic","orthographic"=>Dict("xmag"=>2.0,"ymag"=>1.0,"znear"=>0.1,"zfar"=>10.0))
            encoded_document["cameras"]=[camera_definition]
        elseif kind in (:point,:spot,:directional)
            encoded_node["extensions"]=Dict("KHR_lights_punctual"=>Dict("light"=>0))
            encoded_document["extensions"]=Dict("KHR_lights_punctual"=>
                Dict("lights"=>[Dict("type"=>String(kind))]))
        end
        return encoded_document
    end
    position=Vec3(3.0,-2.0,4.0)
    scales=(Vec3(0.0,1.0,1.0),Vec3(1.0,0.0,1.0),Vec3(1.0,1.0,0.0),
            Vec3(0.0,0.0,1.0),Vec3(0.0,1.0,0.0),Vec3(1.0,0.0,0.0),Vec3(),
            Vec3(-1.0,1.0,1.0),Vec3(1.0,-1.0,1.0),Vec3(-1.0,-1.0,1.0),
            Vec3(1.0,2.0,3.0),Vec3(1e-300,2.0,-1e300))
    for scale in scales, angles in ((0.3,0.4,0.5),(0.3,pi/2-1e-6,0.5))
        quaternion=quat_from_euler(angles...)
        rotation=quat_to_mat4(quaternion)
        expected=mat4_translation(position.x,position.y,position.z)*rotation*
                 mat4_scaling(scale.x,scale.y,scale.z)
        definition=Dict{String,Any}("translation"=>[position.x,position.y,position.z],
            "rotation"=>[quaternion.x,quaternion.y,quaternion.z,quaternion.w],
            "scale"=>[scale.x,scale.y,scale.z])
        for kind in (:group,:bone,:perspective,:orthographic,:point,:spot,:directional)
            imported=Diff3D._gltf_build_scene(node_transform_document(definition,kind),Vector{UInt8}[])
            target=only(get_children(imported))
            @test target.position == position
            @test target.scale == scale
            recovered_rotation=quat_to_mat4(quat_from_euler(target.rotation.x,target.rotation.y,target.rotation.z;
                order=target.rotation.order))
            @test maximum(abs.(collect(recovered_rotation.e).-collect(rotation.e))) < 2e-14
            if target isa AbstractCamera
                @test norm(target.target-target.position-mat4_transform_direction(rotation,Vec3(0.0,0.0,-1.0))) <= 2e-14
                @test norm(target.up-mat4_transform_direction(rotation,Vec3(0.0,1.0,0.0))) <= 2e-14
            elseif target isa DirectionalLight || target isa SpotLight
                @test norm(target.target-target.position-mat4_transform_direction(rotation,Vec3(0.0,0.0,-1.0))) <= 2e-14
            end
        end
        # Matrix-only nodes have no authored scale signs or missing-axis
        # rotation to preserve, but their complete transform must reconstruct.
        matrix_document=node_transform_document(Dict{String,Any}("matrix"=>collect(expected.e)),:group)
        matrix_node=only(get_children(Diff3D._gltf_build_scene(matrix_document,Vector{UInt8}[])))
        reconstructed=compute_local_matrix(matrix_node)
        for column in 1:3
            magnitude=abs((scale.x,scale.y,scale.z)[column])
            divisor=iszero(magnitude) ? 1.0 : magnitude
            for row in 1:3
                @test Diff3D.mat4_get(reconstructed,row,column)/divisor ≈
                      Diff3D.mat4_get(expected,row,column)/divisor atol=2e-14
            end
        end
        @test matrix_node.position == position
    end

    # Finite matrix entries can require a scale outside the node's Float64
    # representation; reject that before constructing a nonfinite scene pose.
    huge=1.4e308
    excessive_scale=Mat4((huge,huge,0.0,0.0, -huge,huge,0.0,0.0,
                          0.0,0.0,1.0,0.0, 0.0,0.0,0.0,1.0))
    @test_throws "node matrix scale must be finite" Diff3D._gltf_build_scene(
        node_transform_document(Dict{String,Any}("matrix"=>collect(excessive_scale.e)),:group),Vector{UInt8}[])

    mktempdir() do directory
        for scale in (Vec3(0.0,1.0,1.0),Vec3(1.0,-1.0,1.0),Vec3(-1.0,-1.0,1.0)),
            channel in ("rotation","scale")
            binary=IOBuffer()
            output_values=channel=="rotation" ? Float32[0,0,0,1,0,0,sin(pi/4),cos(pi/4)] :
                                                 Float32[1,1,1,2,3,4]
            for value in vcat(Float32[0,1],output_values)
                write(binary,htol(reinterpret(UInt32,value)))
            end
            bytes=take!(binary)
            uri="data:application/octet-stream;base64,"*base64encode(bytes)
            output_type=channel=="rotation" ? "VEC4" : "VEC3"
            rotation=quat_from_euler(0.0,0.0,0.5)
            for matrix_only in (false,true)
                initial_matrix=quat_to_mat4(rotation)*mat4_scaling(scale.x,scale.y,scale.z)
                transform_fields=matrix_only ? "\"matrix\":[$(join(initial_matrix.e,','))]" :
                    "\"rotation\":[0,0,$(rotation.z),$(rotation.w)],\"scale\":[$(scale.x),$(scale.y),$(scale.z)]"
                document="""
                {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
                 "nodes":[{$transform_fields}],
                 "buffers":[{"uri":"$uri","byteLength":$(length(bytes))}],
                 "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8},
                                {"buffer":0,"byteOffset":8,"byteLength":$(length(bytes)-8)}],
                 "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
                              {"bufferView":1,"componentType":5126,"count":2,"type":"$output_type"}],
                 "animations":[{"samplers":[{"input":0,"output":1}],
                                 "channels":[{"sampler":0,"target":{"node":0,"path":"$channel"}}]}]}
                """
                path=joinpath(directory,"transform.gltf");write(path,document)
                if matrix_only
                    @test_throws "animated node 0 must not define matrix" load_gltf_asset(path)
                    @test_throws "animated node 0 must not define matrix" load_gltf(path)
                else
                    asset=load_gltf_asset(path)
                    animated_node=only(get_children(asset.scene))
                    mixer=AnimationMixer(only(asset.animations))
                    mixer_set_time!(mixer,0.5)
                    expected_pose=channel=="rotation" ? mat4_rotation_z(pi/4)*mat4_scaling(scale.x,scale.y,scale.z) :
                        mat4_rotation_z(0.5)*mat4_scaling(1.5,2.0,2.5)
                    @test maximum(abs.(collect(compute_local_matrix(animated_node).e).-collect(expected_pose.e))) < 2e-14
                end
            end
        end
    end
end
