using Test
using Diff3D
using Base64

@testset "glTF omitted materials use glTF defaults" begin
    definitions = Dict("materials" => [Dict{String,Any}()])
    implicit = Diff3D._gltf_material(definitions,Vector{UInt8}[],"",nothing)
    explicit = Diff3D._gltf_material(definitions,Vector{UInt8}[],"",0)
    @test typeof(implicit) === typeof(explicit) === MeshStandardMaterial
    for field in fieldnames(MeshStandardMaterial)
        @test isequal(getfield(implicit,field),getfield(explicit,field))
    end
    @test implicit.metalness == 1.0
    @test implicit.roughness == 1.0
    @test MeshStandardMaterial().metalness == 0.0
    for bad_index in (-1,1,true,0.5)
        @test_throws ErrorException Diff3D._gltf_material(definitions,Vector{UInt8}[],"",bad_index)
    end
    nondefault = Dict("materials" => [Dict("pbrMetallicRoughness" =>
        Dict("metallicFactor"=>0.25,"roughnessFactor"=>0.75))])
    customized = Diff3D._gltf_material(nondefault,Vector{UInt8}[],"",0)
    @test customized.metalness == 0.25
    @test customized.roughness == 0.75

    mktempdir() do directory
        # glTF buffers store little-endian Float32 components on every host.
        data = IOBuffer()
        for component in Float32[-0.5,-0.5,0, 0.5,-0.5,0, 0,0.5,0,
                                  1,0,0, 0,1,0, 0,0,1]
            write(data,htol(reinterpret(UInt32,component)))
        end
        bytes = take!(data)
        uri = "data:application/octet-stream;base64," * base64encode(bytes)
        for with_colors in (false,true), mode in ("omitted","empty","pbr")
            material_definition = mode == "omitted" ? "" :
                mode == "empty" ? "\"materials\":[{}]," :
                "\"materials\":[{\"pbrMetallicRoughness\":{}}],"
            material_reference = mode == "omitted" ? "" : ",\"material\":0"
            color_reference = with_colors ? ",\"COLOR_0\":1" : ""
            document = """
            {"asset":{"version":"2.0"},$material_definition
             "scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
             "meshes":[{"primitives":[{"attributes":{"POSITION":0$color_reference}$material_reference}]}],
             "buffers":[{"byteLength":$(length(bytes)),"uri":"$uri"}],
             "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},
                            {"buffer":0,"byteOffset":36,"byteLength":36}],
             "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
                           "min":[-0.5,-0.5,0],"max":[0.5,0.5,0]},
                          {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"}]}
            """
            path = joinpath(directory,"$(mode)-$(with_colors).gltf")
            write(path,document)
            loaded_scene = load_gltf(path)
            loaded_mesh = only(collect_meshes(loaded_scene))
            @test loaded_mesh.geometry.n_vertices == 3
            @test loaded_mesh.geometry.n_faces == 1
            @test loaded_mesh.material.metalness == 1.0
            @test loaded_mesh.material.roughness == 1.0
            @test loaded_mesh.material.vertex_colors == with_colors
            serialized = Diff3D._json_parse(only(Diff3D._web_collect_drawables(loaded_scene)))
            @test serialized["metalness"] == 1.0
            @test serialized["roughness"] == 1.0
            @test (serialized["colors"] !== nothing) == with_colors
        end
    end
end
