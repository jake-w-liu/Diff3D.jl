using Diff3D
using Base64

function skin_binding_fixture(directory, container, inverse_mode, mesh_scale)
    stream=IOBuffer()
    positions=Float32[-0.4,-0.4,0, 0.4,-0.4,0, 0,0.4,0]
    for value in positions;write(stream,htol(reinterpret(UInt32,value)));end
    write(stream,repeat(UInt8[0,1,0,0],3))
    for value in repeat(Float32[0.25,0.75,0,0],3);write(stream,htol(reinterpret(UInt32,value)));end
    for value in repeat(Float32[0,0,1],3);write(stream,htol(reinterpret(UInt32,value)));end
    inverse_offset=position(stream)
    inverse_matrices=inverse_mode===:custom ? [mat4_translation(-4.5,0.0,0.0),mat4_translation(-5.0,-0.25,0.0)] : [Mat4(),Mat4()]
    if inverse_mode!==:omitted
        for matrix in inverse_matrices, value in matrix.e
            write(stream,htol(reinterpret(UInt32,Float32(value))))
        end
    end
    binary=take!(stream)
    inverse_view=inverse_mode===:omitted ? "" : ",{\"buffer\":0,\"byteOffset\":$inverse_offset,\"byteLength\":128}"
    inverse_accessor=inverse_mode===:omitted ? "" : ",{\"bufferView\":4,\"componentType\":5126,\"count\":2,\"type\":\"MAT4\"}"
    inverse_reference=inverse_mode===:omitted ? "" : ",\"inverseBindMatrices\":4"
    buffer_uri=container===:glb ? "" : ",\"uri\":\"data:application/octet-stream;base64,$(base64encode(binary))\""
    document="""
    {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
     "nodes":[{"name":"skin-node","mesh":0,"skin":0,"translation":[10,0,0],
               "scale":[$(mesh_scale.x),$(mesh_scale.y),$(mesh_scale.z)],"children":[4]},
              {"translation":[4,0,0],"children":[2,3]},
              {"translation":[1,0,0]},
              {"translation":[1,0.4,0],"scale":[1.2,0.8,1]},
              {"name":"ordinary-child","translation":[0.3,0.2,0]}],
     "buffers":[{"byteLength":$(length(binary))$buffer_uri}],
     "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},
                    {"buffer":0,"byteOffset":36,"byteLength":12},
                    {"buffer":0,"byteOffset":48,"byteLength":48},
                    {"buffer":0,"byteOffset":96,"byteLength":36}$inverse_view],
     "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[-0.4,-0.4,0],"max":[0.4,0.4,0]},
                  {"bufferView":1,"componentType":5121,"count":3,"type":"VEC4"},
                  {"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"},
                  {"bufferView":3,"componentType":5126,"count":3,"type":"VEC3"}$inverse_accessor],
     "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2,"NORMAL":3}}]}],
     "skins":[{"joints":[2,3]$inverse_reference}]}
    """
    path=joinpath(directory,"skin.$container")
    if container===:glb
        json_bytes=collect(codeunits(document))
        while length(json_bytes)%4!=0;push!(json_bytes,0x20);end
        # GLB2 uses little-endian headers and four-byte-aligned JSON/BIN chunks.
        open(path,"w") do output
            for word in (0x46546c67,UInt32(2),UInt32(28+length(json_bytes)+length(binary)),
                         UInt32(length(json_bytes)),0x4e4f534a)
                write(output,htol(word))
            end
            write(output,json_bytes)
            write(output,htol(UInt32(length(binary))),htol(UInt32(0x004e4942)),binary)
        end
    else
        write(path,document)
    end
    asset=container===:glb ? load_glb_asset(path) : load_gltf_asset(path)
    imported_skin=only(filter(object->object isa SkinnedMesh,get_children(first(get_children(asset.scene)))))
    return asset,imported_skin,inverse_matrices
end

# Independent world-space oracle for the authored joint transforms in this fixture.
function skin_binding_reference_positions(geometry, inverse_matrices;
                                          bind=Mat4(), prefix=Mat4(),
                                          joint_shift=0.0)
    joints=[mat4_translation(5.0+joint_shift,0.0,0.0),
            mat4_translation(5.0,0.4,0.0)*mat4_scaling(1.2,0.8,1.0)]
    result=Vec3{Float64}[]
    for vertex in 1:geometry.n_vertices
        point=get_vertex(geometry,vertex)
        push!(result,mat4_transform_point(prefix*joints[1]*inverse_matrices[1]*bind,point)*0.25+
                     mat4_transform_point(prefix*joints[2]*inverse_matrices[2]*bind,point)*0.75)
    end
    return result
end
