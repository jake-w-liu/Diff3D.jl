using Diff3D, Base64

function texture_transform_fixture(directory; offset=Vec2(0.25,0.5),
                                     scale=Vec2(2.0,3.0),rotation=0.75,tex_coord=1)
    data=zeros(4,4,3)
    for y in 1:4,x in 1:4
        data[y,x,1]=0.2+0.6*(x-1)/3
        data[y,x,2]=0.2+0.6*(y-1)/3
        data[y,x,3]=0.25+0.5*(x+y-2)/6
    end
    save_png(joinpath(directory,"texture.png"),data)
    geometry=PlaneGeometry(width=1.5,height=1.5)
    uv2=[isodd(index) ? 0.1+0.7value : 0.15+0.6value for (index,value) in pairs(geometry.uvs)]
    stream=IOBuffer()
    for values in (geometry.positions,geometry.uvs,uv2),value in values
        write(stream,htol(reinterpret(UInt32,Float32(value))))
    end
    for index in geometry.indices;write(stream,htol(UInt16(index-1)));end
    binary=take!(stream)
    document="""
    {"asset":{"version":"2.0"},"extensionsUsed":["KHR_texture_transform","KHR_materials_unlit"],
     "scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
     "buffers":[{"byteLength":$(length(binary)),"uri":"data:application/octet-stream;base64,$(base64encode(binary))"}],
     "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},
                    {"buffer":0,"byteOffset":48,"byteLength":32},
                    {"buffer":0,"byteOffset":80,"byteLength":32},
                    {"buffer":0,"byteOffset":112,"byteLength":12}],
     "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-0.75,-0.75,0],"max":[0.75,0.75,0]},
                  {"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},
                  {"bufferView":2,"componentType":5126,"count":4,"type":"VEC2"},
                  {"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"}],
     "samplers":[{"magFilter":9729,"minFilter":9729,"wrapS":10497,"wrapT":10497}],
     "images":[{"uri":"texture.png"}],"textures":[{"source":0,"sampler":0}],
     "materials":[{"extensions":{"KHR_materials_unlit":{}},"pbrMetallicRoughness":{"baseColorTexture":
       {"index":0,"texCoord":0,"extensions":{"KHR_texture_transform":{
         "offset":[$(offset.x),$(offset.y)],"scale":[$(scale.x),$(scale.y)],
         "rotation":$rotation,"texCoord":$tex_coord}}}}}],
     "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1,"TEXCOORD_1":2},"indices":3,"material":0}]}]}
    """
    path=joinpath(directory,"texture.gltf");write(path,document)
    scene=load_gltf(path)
    return scene,only(collect_meshes(scene))
end

# Scale in the glTF UV axes before rotation, then translate. The sign matches
# the Khronos Sample Renderer and GLTFLoader (UV origin at the image's top left).
function texture_transform_reference(u,v,offset,scale,rotation)
    x,y=scale.x*u,scale.y*v
    cosine,sine=cos(rotation),sin(rotation)
    return (offset.x+cosine*x+sine*y,offset.y-sine*x+cosine*y)
end
