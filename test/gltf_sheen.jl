using Diff3D, Test

@testset "glTF sheen color is applied once" begin
    normal=Vec3(0.0,0.0,1.0)
    light=normalize(Vec3(1.0,0.0,0.5));view=normalize(Vec3(1.0,0.25,0.5))
    unit=MeshPhysicalMaterial(sheen=1.0,sheen_roughness=0.8)
    unit_lobe=Diff3D._sheen_lobe(unit,normal,light,view)
    @test unit_lobe.r>0.01
    for factor in ([0.5,0.25,0.125],[0.0,0.0,0.0],[1.0,1.0,1.0],[1e-300,0.25,0.0])
        definitions=Dict("materials"=>[Dict("extensions"=>Dict("KHR_materials_sheen"=>
            Dict("sheenColorFactor"=>factor,"sheenRoughnessFactor"=>0.8)))])
        material=Diff3D._gltf_material(definitions,Vector{UInt8}[],"",0)
        @test material.sheen==1.0
        @test material.sheen_color==Color3(factor...)
        actual=Diff3D._sheen_lobe(material,normal,light,view)
        @test [actual.r,actual.g,actual.b]≈factor.*unit_lobe.r atol=1e-15
        payload=Diff3D._json_parse(Diff3D._web_drawable_json(Mesh(PlaneGeometry(),material),Mat4()))
        @test payload["sheen"]==1.0 && payload["sheenColor"]==factor
    end
    other=Dict("materials"=>[Dict("extensions"=>Dict("KHR_materials_ior"=>Dict("ior"=>1.5)))])
    @test Diff3D._gltf_material(other,Vector{UInt8}[],"",0).sheen==0.0
    for factor in ([-0.1,0.5,0.5],[0.5,-0.1,0.5],[0.5,0.5,-0.1],[1.1,0.5,0.5])
        definitions=Dict("materials"=>[Dict("extensions"=>Dict("KHR_materials_sheen"=>
            Dict("sheenColorFactor"=>factor)))])
        @test_throws ArgumentError Diff3D._gltf_material(definitions,Vector{UInt8}[],"",0)
    end
    omitted=Dict("materials"=>[Dict("extensions"=>Dict("KHR_materials_sheen"=>Dict()))])
    disabled=Diff3D._gltf_material(omitted,Vector{UInt8}[],"",0)
    @test Diff3D._sheen_lobe(disabled,normal,light,view)==Color3(0.0,0.0,0.0)
    mktempdir() do directory
        save_png(joinpath(directory,"sheen.png"),reshape(UInt8[64,128,192],1,1,3))
        factor=[0.5,0.25,0.125]
        definitions=Dict{String,Any}("images"=>[Dict("uri"=>"sheen.png")],"textures"=>[Dict("source"=>0)],
            "materials"=>[Dict("extensions"=>Dict("KHR_materials_sheen"=>Dict(
                "sheenColorFactor"=>factor,"sheenColorTexture"=>Dict("index"=>0),"sheenRoughnessFactor"=>0.8)))])
        mapped=Diff3D._gltf_material(definitions,Vector{UInt8}[],directory,0)
        terms=Diff3D._physical_mapped_terms(mapped,nothing,nothing,0.5,0.5,0.5,0.5)
        expected=factor.*srgb_to_linear.([64.0,128.0,192.0]./255)
        @test [terms.sheen_color.r,terms.sheen_color.g,terms.sheen_color.b].*mapped.sheen≈expected atol=1e-15
        @test mapped.sheen_color_map.colorspace===:srgb
    end
end
