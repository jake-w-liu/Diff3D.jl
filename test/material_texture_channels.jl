using Test
using Diff3D

@testset "Material maps sample normalized RGBA components" begin
    function rgba_texture(texture)
        height, width, channels = size(texture.data)
        data = Array{Float64}(undef, height, width, 4)
        normalize(value) = isfinite(value) ? clamp(value, 0.0, 1.0) : 0.0
        for x in 1:width, y in 1:height
            for component in 1:3
                source = channels < 3 ? 1 : component
                data[y, x, component] = normalize(texture.data[y, x, source])
            end
            data[y, x, 4] = channels == 2 ? normalize(texture.data[y, x, 2]) :
                            channels >= 4 ? normalize(texture.data[y, x, 4]) : 1.0
        end
        return Texture(data; filter=texture.filter, colorspace=:linear,
                       wrap_s=texture.wrap_s, wrap_t=texture.wrap_t,
                       offset=texture.offset, repeat=texture.repeat,
                       rotation=texture.rotation, center=texture.center,
                       tex_coord=texture.tex_coord)
    end

    for channels in 1:4, filter in (:nearest, :bilinear)
        values = (0.2, 0.8, 1.5, -0.4, NaN, Inf, -Inf, 0.6)
        data = reshape([values[mod1(i, length(values))] for i in 1:4channels],
                       2, 2, channels)
        texture = Texture(data; filter=filter, colorspace=:linear,
                          offset=Vec2(0.1, -0.2), repeat=Vec2(1.2, 0.7),
                          rotation=0.3, wrap_s=:mirror, wrap_t=:clamp)
        rgba = rgba_texture(texture)
        for (u, v) in ((0.1, 0.3), (0.5, 0.5), (0.8, 0.6), (-0.2, 1.4)),
            component in 1:4
            expected = Diff3D.sample_texture_channel(rgba, u, v, component)
            @test Diff3D._sample_texture_unit_channel(texture, u, v, component) ≈ expected
        end
        @test Diff3D._json_parse(Diff3D._web_texture_json(texture))["data"] ==
              Diff3D._json_parse(Diff3D._web_texture_json(rgba))["data"]
    end

    gray_alpha = Texture(reshape([0.2, 0.8], 1, 1, 2); filter=:nearest,
                         colorspace=:linear)
    @test sample_texture(gray_alpha, 0.5, 0.5) == Color3(0.2, 0.2, 0.2)
    @test Diff3D.sample_texture_channel(gray_alpha, 0.5, 0.5, 2) == 0.8
    @test Diff3D.sample_texture_channel(gray_alpha, 0.5, 0.5, 3; default=0.7) == 0.7
    @test Diff3D.sample_texture_channel(
        Texture(fill(2.0, 1, 1, 1)), 0.5, 0.5, 4) == 2.0
    @test Diff3D._fragment_alpha(0.5, gray_alpha, gray_alpha,
                                0.5, 0.5, 0.5, 0.5) ≈ 0.5 * 0.8 * 0.2

    function rendered(material, shading)
        scene = Scene()
        geometry = PlaneGeometry()
        set_attribute!(geometry, :uv2, fill(0.7, 2geometry.n_vertices), 2)
        add!(scene, Mesh(geometry, material))
        add!(scene, AmbientLight(intensity=0.3))
        add!(scene, DirectionalLight(intensity=0.5, position=Vec3(1.0, 1.0, 3.0)))
        target = RenderTarget(8, 8)
        render!(target, scene, PerspectiveCamera(); shading=shading)
        return target.color
    end

    for channels in 1:4
        texture = Texture(reshape(collect((0.2, 0.8, 0.4, 0.6)[1:channels]),
                                  1, 1, channels); colorspace=:linear)
        expanded = rgba_texture(texture)
        for make_material in (
            t -> MeshStandardMaterial(metalness=0.8, roughness=0.6,
                                      roughness_map=t, metalness_map=t),
            t -> MeshPhysicalMaterial(metalness=0.7, roughness=0.5, clearcoat=0.6,
                                      roughness_map=t, metalness_map=t,
                                      clearcoat_roughness_map=t,
                                      sheen_roughness_map=t, specular_intensity_map=t),
            t -> MeshPhongMaterial(glossiness=0.7, glossiness_map=t),
            t -> MeshBasicMaterial(color=Color3(0.3, 0.5, 0.6), ao_map=t),
            t -> MeshBasicMaterial(color=Color3(0.3, 0.5, 0.6), opacity=0.7,
                                   transparent=true, alpha_map=t),
        ), shading in (:flat, :smooth)
            image = rendered(make_material(texture), shading)
            @test all(isfinite, image)
            @test any(>(0.0), image)
            @test image ≈ rendered(make_material(expanded), shading)
        end
    end

    for value in (NaN, Inf, -Inf, -1.0, 2.0)
        data = fill(0.5, 1, 2, 4)
        data[1, 1, :] .= value
        texture = Texture(data; colorspace=:linear, filter=:bilinear,
                          wrap_s=:clamp, wrap_t=:clamp, tex_coord=1)
        expanded = rgba_texture(texture)
        for make_material in (
            t -> MeshStandardMaterial(roughness=0.8, roughness_map=t),
            t -> MeshStandardMaterial(metalness=0.6, roughness=0.7,
                                      roughness_map=t, metalness_map=t),
            t -> MeshBasicMaterial(ao_map=t),
            t -> MeshBasicMaterial(transparent=true, alpha_map=t),
        ), shading in (:flat, :smooth)
            image = rendered(make_material(texture), shading)
            @test all(isfinite, image)
            @test image ≈ rendered(make_material(expanded), shading)
        end
        # Color-map alpha must normalize without normalizing its HDR RGB.
        alpha_data = fill(0.25, 1, 2, 4)
        alpha_data[1, 1, 4] = value
        alpha_texture = Texture(alpha_data; filter=:bilinear, colorspace=:linear)
        @test Diff3D._fragment_alpha(0.7, alpha_texture, nothing, 0.5, 0.5, 0.5, 0.5) ≈
              Diff3D._fragment_alpha(0.7, rgba_texture(alpha_texture), nothing,
                                      0.5, 0.5, 0.5, 0.5)
    end
end
