using Diff3D, Test
include("fixtures/texture_transform.jl")

@testset "glTF texture transforms scale in UV axes before rotation" begin
    mktempdir() do directory
        for scale in (Vec2(2.0,3.0),Vec2(-2.0,0.5),Vec2(0.0,1.5),Vec2(0.5,0.5)),
            rotation in (0.0,0.75,-0.5,pi/2),tex_coord in (0,1)
            offset=Vec2(0.25,0.5)
            scene,mesh=texture_transform_fixture(directory;offset=offset,scale=scale,rotation=rotation,tex_coord=tex_coord)
            texture=mesh.material.map
            @test texture.offset==offset && texture.repeat==scale && texture.rotation==rotation
            @test texture.tex_coord==tex_coord
            for (u,v) in ((0.0,0.0),(0.2,0.3),(-0.5,1.25),(1.0,1.0))
                expected=texture_transform_reference(u,v,offset,scale,rotation)
                @test collect(texture_transform_uv(texture,u,v))≈collect(expected) atol=2e-15
            end
            payload=Diff3D._json_parse(only(Diff3D._web_collect_drawables(scene)))
            @test payload["texture"]["matrix"]≈collect(texture.matrix.e) atol=1e-15
            @test payload["texture"]["matrixAutoUpdate"]==texture.matrix_auto_update
        end
        # The extension's lower-left-quadrant example also anchors rotation sign.
        _,mesh=texture_transform_fixture(directory;offset=Vec2(0.0,1.0),scale=Vec2(0.5,0.5),rotation=pi/2,tex_coord=0)
        @test collect(texture_transform_uv(mesh.material.map,0.25,0.75))≈[0.375,0.875] atol=1e-15
    end
end

@testset "glTF texture cache reuses loaded resources" begin
    mktempdir() do directory
        image_path=joinpath(directory,"cached.png")
        save_png(image_path,fill(0.5,2,2,3))
        definitions=Dict{String,Any}("textures"=>[Dict("source"=>0)],
                                    "images"=>[Dict("uri"=>"cached.png")])
        info=Dict{String,Any}("index"=>0)
        cache=Dict{Any,Texture}()
        texture=Diff3D._gltf_texture(definitions,Vector{UInt8}[],directory,info;texture_cache=cache)
        @test length(cache)==1
        # A cache hit owns the already-loaded texture and performs no image I/O.
        moved=joinpath(directory,"moved.png");mv(image_path,moved)
        @test Diff3D._gltf_texture(definitions,Vector{UInt8}[],directory,info;texture_cache=cache)===texture
        @test_throws SystemError Diff3D._gltf_texture(definitions,Vector{UInt8}[],directory,info;
            texture_cache=cache,colorspace=:linear)
        mv(moved,image_path)
        linear=Diff3D._gltf_texture(definitions,Vector{UInt8}[],directory,info;
            texture_cache=cache,colorspace=:linear)
        @test linear!==texture && linear.colorspace===:linear && texture.colorspace===:srgb
        @test linear.data==texture.data
        transformed=deepcopy(info)
        transformed["extensions"]=Dict("KHR_texture_transform"=>Dict("rotation"=>0.5,"scale"=>[2.0,3.0]))
        rotated=Diff3D._gltf_texture(definitions,Vector{UInt8}[],directory,transformed;texture_cache=cache)
        @test rotated!==texture && !rotated.matrix_auto_update
        @test length(cache)==3
        @test texture.matrix_auto_update && texture.matrix.e==Mat3().e
        transformed["extensions"]["KHR_texture_transform"]["rotation"]=NaN
        @test_throws "texture transform rotation must be a finite number" Diff3D._gltf_texture(
            definitions,Vector{UInt8}[],directory,transformed;texture_cache=cache)
    end
end
