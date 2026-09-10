using Diff3D, Test
include("fixtures/packed_gray_png.jl")

@testset "Packed grayscale PNG samples, filters and Adam7" begin
    mktempdir() do directory
        path=joinpath(directory,"gray.png")
        for depth in (1,2,4),interlace in (false,true),filter in 0:4,
            (height,width) in ((1,1),(2,3),(9,11)),transparent in (nothing,0,(1<<depth)-1)
            maximum_sample=(1<<depth)-1
            samples=UInt8[mod(x+3y,maximum_sample+1) for y in 1:height,x in 1:width]
            bytes=packed_gray_png(samples,depth;interlace=interlace,filter=filter,transparent=transparent)
            write(path,bytes)
            image=load_png(path)
            @test size(image)==(height,width,transparent===nothing ? 1 : 2)
            @test image[:,:,1]≈Float64.(samples)./maximum_sample atol=1e-15
            if transparent!==nothing
                @test image[:,:,2]==Float64.(samples.!=transparent)
            end
        end
    end
end

@testset "Packed grayscale reaches texture consumers" begin
    mktempdir() do directory
        path=joinpath(directory,"texture.png")
        samples=UInt8[0 1;2 3]
        write(path,packed_gray_png(samples,2;interlace=true,filter=4,transparent=3))
        texture=TextureLoader(path)
        @test size(texture.data)==(2,2,2)
        @test sample_texture(texture,0.25,0.75)==Color3(0.0,0.0,0.0)
        @test sample_texture(texture,0.75,0.25)==Color3(1.0,1.0,1.0)
        @test Diff3D.sample_texture_channel(texture,0.75,0.25,2)==0.0
        @test Diff3D._fragment_alpha(0.8,texture,nothing,0.75,0.25,0.75,0.25)==0.0
        payload=Diff3D._json_parse(Diff3D._web_texture_json(texture))
        @test payload["data"][5:8]==[255,255,255,0]
    end
end

@testset "Packed grayscale rejects invalid image data" begin
    for depth in (1,2,4)
        original=packed_gray_png(reshape(UInt8[0],1,1),depth)
        function altered(raw;transparency=nothing,color_type=0)
            output=IOBuffer()
            write(output,original[1:8])
            # The PNG signature and fixed IHDR layout put its 13 data bytes at 17:29.
            header=copy(original[17:29]);header[10]=UInt8(color_type)
            Diff3D._png_chunk(output,"IHDR",header)
            transparency===nothing || Diff3D._png_chunk(output,"tRNS",transparency)
            Diff3D._png_chunk(output,"IDAT",Diff3D._zlib_store(raw))
            Diff3D._png_chunk(output,"IEND",UInt8[])
            return take!(output)
        end
        @test_throws "image data is truncated" Diff3D._decode_png(altered(UInt8[]))
        @test_throws "image data has trailing bytes" Diff3D._decode_png(altered(UInt8[0,0,0]))
        @test_throws ErrorException Diff3D._decode_png(altered(UInt8[5,0]))
        @test_throws "grayscale tRNS chunk length must be 2" Diff3D._decode_png(altered(UInt8[0,0];transparency=UInt8[0]))
        @test_throws ErrorException Diff3D._decode_png(altered(UInt8[0,0];color_type=4))
        corrupted=copy(original);corrupted[end]⊻=0x01
        @test_throws "CRC mismatch" Diff3D._decode_png(corrupted)
    end
end
