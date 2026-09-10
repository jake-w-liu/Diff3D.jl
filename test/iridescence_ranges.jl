using Diff3D, Test

@testset "glTF iridescence thickness uses its full range" begin
    mktempdir() do directory
        for (minimum,maximum) in ((100.0,400.0),(500.0,100.0),(0.0,0.0),(250.0,250.0))
            extension=Dict{String,Any}("iridescenceFactor"=>1.0,
                "iridescenceThicknessMinimum"=>minimum,"iridescenceThicknessMaximum"=>maximum)
            definitions=Dict{String,Any}("materials"=>[Dict("extensions"=>Dict("KHR_materials_iridescence"=>extension))])
            material=Diff3D._gltf_material(definitions,Vector{UInt8}[],directory,0)
            @test material.iridescence_thickness==maximum
            @test hasproperty(material,:iridescence_thickness_min)
            hasproperty(material,:iridescence_thickness_min) && @test material.iridescence_thickness_min==minimum
            for green in (0,85,255)
                save_png(joinpath(directory,"thickness.png"),reshape(UInt8[200,green,30],1,1,3))
                definitions["images"]=[Dict("uri"=>"thickness.png")]
                definitions["textures"]=[Dict("source"=>0)]
                extension["iridescenceThicknessTexture"]=Dict("index"=>0)
                mapped=Diff3D._gltf_material(definitions,Vector{UInt8}[],directory,0)
                expected=(1-green/255)*minimum+(green/255)*maximum
                terms=Diff3D._physical_mapped_terms(mapped,nothing,nothing,0.5,0.5,0.5,0.5)
                @test terms.iridescence_thickness≈expected atol=1e-12
                @test Diff3D._apply_pbr_maps(mapped,nothing,nothing,0.5,0.5).iridescence_thickness≈expected atol=1e-12
                @test Diff3D._apply_pbr_maps(mapped,nothing,nothing,0.5,0.5,0.5,0.5).iridescence_thickness≈expected atol=1e-12
            end
        end
    end
end

@testset "Iridescence range survives material operations" begin
    texture=Texture(reshape([0.9,1/3,0.2],1,1,3);colorspace=:linear)
    material=MeshPhysicalMaterial(iridescence=1.0,iridescence_thickness=400.0,
        iridescence_thickness_min=100.0,iridescence_thickness_map=texture)
    @test Diff3D._mapped_iridescence_thickness(material,0.5,0.5)≈200.0 atol=1e-12
    for copied in (Diff3D._with_vertex_color(material,Color3(0.5,0.5,0.5)),
                   Diff3D._gltf_enable_vertex_colors(material))
        @test copied.iridescence_thickness_min==100.0
        @test copied.iridescence_thickness==400.0
        @test copied.iridescence_thickness_map===texture
    end
    object=Mesh(PlaneGeometry(),material)
    track=NumberKeyframeTrack(object,"material.iridescenceThicknessMinimum",[0.0,1.0],[100.0,200.0])
    mixer=AnimationMixer(AnimationClip("thickness",[track]))
    mixer_set_time!(mixer,0.5)
    @test object.material.iridescence_thickness_min==150.0
    @test object.material.iridescence_thickness==400.0
    payload=Diff3D._json_parse(Diff3D._web_drawable_json(object,Mat4()))
    @test payload["iridescenceThicknessMinimum"]==150.0
    @test payload["iridescenceThickness"]==400.0
    ordinary=MeshPhysicalMaterial()
    fields=Tuple(getfield(ordinary,name) for name in fieldnames(MeshPhysicalMaterial))
    @test MeshPhysicalMaterial(fields[1:57]...).iridescence_thickness_min==0.0
    @test MeshPhysicalMaterial(fields[1:56]...).iridescence_thickness_min==0.0
    @test Diff3D._mapped_iridescence_thickness(ordinary,0.5,0.5)==400.0
    for invalid in (-1.0,Inf,NaN,true)
        @test_throws ArgumentError MeshPhysicalMaterial(iridescence_thickness_min=invalid)
    end
end
