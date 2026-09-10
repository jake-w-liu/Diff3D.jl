using Base64

function animated_view_fixture(directory; interpolation=:linear,
                               camera_kind=:perspective, parent_scale=(2.0,3.0,4.0))
    interpolation in (:linear,:step,:cubicspline) || error("unsupported fixture interpolation")
    camera_kind in (:perspective,:orthographic) || error("unsupported fixture camera")
    rotation_keys=Float32[0,0,0,1,0,sin(pi/4),0,cos(pi/4)]
    position_keys=Float32[3,0,2,5,2,3]
    function output_data(keys,width)
        interpolation===:cubicspline || return keys
        result=Float32[]
        for key in 0:1
            append!(result,zeros(Float32,width))
            append!(result,@view keys[key*width+1:(key+1)*width])
            append!(result,zeros(Float32,width))
        end
        return result
    end
    rotations=output_data(rotation_keys,4);positions=output_data(position_keys,3)
    binary=IOBuffer()
    for value in vcat(Float32[0,1],rotations,positions)
        write(binary,htol(reinterpret(UInt32,value)))
    end
    bytes=take!(binary)
    uri="data:application/octet-stream;base64,"*base64encode(bytes)
    rotation_bytes=4length(rotations);position_bytes=4length(positions)
    count=interpolation===:cubicspline ? 6 : 2
    mode=uppercase(String(interpolation))
    camera_definition=camera_kind===:perspective ?
        "\"type\":\"perspective\",\"perspective\":{\"yfov\":1.0,\"znear\":0.1,\"zfar\":100.0}" :
        "\"type\":\"orthographic\",\"orthographic\":{\"xmag\":2.0,\"ymag\":2.0,\"znear\":0.1,\"zfar\":100.0}"
    channels=join(("{\"sampler\":$sampler,\"target\":{\"node\":$node,\"path\":\"$path\"}}"
                   for node in 1:3 for (sampler,path) in ((0,"rotation"),(1,"translation"))),',')
    document="""
    {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
     "nodes":[{"name":"view-rig","translation":[10,3,0],"rotation":[0,0,$(sqrt(0.5)),$(sqrt(0.5))],"scale":[$(join(parent_scale,','))],"children":[1,2,3]},
              {"name":"view-camera","camera":0,"translation":[3,0,2]},
              {"name":"view-directional","translation":[3,0,2],"extensions":{"KHR_lights_punctual":{"light":0}}},
              {"name":"view-spot","translation":[3,0,2],"extensions":{"KHR_lights_punctual":{"light":1}}}],
     "cameras":[{$camera_definition}],
     "extensions":{"KHR_lights_punctual":{"lights":[{"type":"directional"},{"type":"spot","spot":{"outerConeAngle":0.4}}]}},
     "buffers":[{"byteLength":$(length(bytes)),"uri":"$uri"}],
     "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":8},
                    {"buffer":0,"byteOffset":8,"byteLength":$rotation_bytes},
                    {"buffer":0,"byteOffset":$(8+rotation_bytes),"byteLength":$position_bytes}],
     "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR"},
                  {"bufferView":1,"componentType":5126,"count":$count,"type":"VEC4"},
                  {"bufferView":2,"componentType":5126,"count":$count,"type":"VEC3"}],
     "animations":[{"samplers":[{"input":0,"output":1,"interpolation":"$mode"},
                                  {"input":0,"output":2,"interpolation":"$mode"}],"channels":[$channels]}]}
    """
    path=joinpath(directory,"animated-view.gltf")
    write(path,document)
    return load_gltf_asset(path)
end
