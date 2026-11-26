using Test, Diff3D, ForwardDiff

# Reference NEAREST texel lookup from GLES 3.0 §3.8.10 (the sampling rule of
# WebGL 2, which three.js r186 targets): i = wrap(floor(s * W)),
# j = wrap(floor(t * H)), with j counted from the bottom image row because
# three.js uploads images with flipY=true (Texture.js: `this.flipY = true`).
function _audit3_gl_nearest(data, s, t, wrap_s, wrap_t)
    H, W = size(data, 1), size(data, 2)
    wrap(i, n, mode) = mode === :repeat ? mod(i, n) :
                       mode === :clamp ? clamp(i, 0, n - 1) :
                       (n - 1) - (a -> a >= 0 ? a : -(1 + a))(mod(i, 2n) - n)
    i = wrap(floor(Int, s * W), W, wrap_s)
    j = wrap(floor(Int, t * H), H, wrap_t)
    return data[H - j, i + 1, 1]
end

@testset "Nearest filtering selects floor(uv * size) texels" begin
    # Column c holds c - 1 and bottom-up row j holds j in the second channel,
    # so each sample reports the texel indices it selected.
    data = zeros(4, 4, 3)
    for row in 1:4, col in 1:4
        data[row, col, 1] = col - 1
        data[row, col, 2] = 4 - row
    end
    texture = Texture(data; filter=:nearest, wrap_s=:clamp, wrap_t=:clamp,
                      colorspace=:linear)
    for u in (0.0, 0.25, 0.5, 0.75, 1.0), v in (0.0, 0.25, 0.5, 0.75, 1.0)
        color = sample_texture(texture, u, v)
        # GLES 3.0 §3.8.10 eq. 3.20: i = floor(u), j = floor(v) in texel units.
        @test color.r == clamp(floor(Int, 4u), 0, 3)
        @test color.g == clamp(floor(Int, 4v), 0, 3)
        @test Diff3D.sample_texture_channel(texture, u, v, 1) == color.r
        @test Diff3D.sample_texture_channel(texture, u, v, 2) == color.g
    end
    # A two-texel toon gradient map sampled at the terminator (coord 0.5)
    # reads the upper texel: floor(0.5 * 2) = 1.
    gradient = Texture(reshape([0.25, 1.0], 1, 2, 1); filter=:nearest,
                       colorspace=:linear)
    @test sample_texture(gradient, 0.5, 0.0).r == 1.0

    # Every wrap mode at exact in-range texel boundaries.
    for H in 1:5, W in 1:5, wrap_s in (:repeat, :clamp, :mirror),
        wrap_t in (:repeat, :clamp, :mirror)
        values = reshape(collect(1.0:(H * W)), H, W, 1)
        texture = Texture(values; filter=:nearest, wrap_s, wrap_t,
                          colorspace=:linear)
        for i in 0:W, j in 0:H
            s, t = i / W, j / H
            @test sample_texture(texture, s, t).r ==
                  _audit3_gl_nearest(values, s, t, wrap_s, wrap_t)
        end
    end
end

@testset "Material defaults follow the three.js classes" begin
    # MeshPhongMaterial.js:63 `this.specular = new Color( 0x111111 )`; Color
    # stores the sRGB hex in the linear working space:
    # node: new THREE.MeshPhongMaterial().specular.r === 0.005605391621829108
    @test MeshPhongMaterial().specular ==
          Color3(0.005605391621829108, 0.005605391621829108, 0.005605391621829108)
    # ColorManagement.js SRGBToLinear uses rounded constants (0.9478672986,
    # 0.0521327014), so the exact sRGB decode differs in the 10th digit.
    @test MeshPhongMaterial().specular.r ≈ srgb_to_linear(17 / 255) atol=1e-11
    # SpriteMaterial.js:107 `this.transparent = true`.
    @test SpriteMaterial().transparent
    @test !SpriteMaterial(transparent=false).transparent
    # MeshPhysicalMaterial.js:225 `this.sheenColor = new Color( 0x000000 )`;
    # WebGLMaterials.js:419 multiplies it by `sheen`, so `sheen = 1` alone adds
    # no sheen lobe.
    @test MeshPhysicalMaterial().sheen_color == Color3(0.0, 0.0, 0.0)
    material = MeshPhysicalMaterial(sheen=1.0, sheen_roughness=0.8)
    normal = Vec3(0.0, 0.0, 1.0)
    light = normalize(Vec3(1.0, 0.0, 0.5)); view = normalize(Vec3(1.0, 0.25, 0.5))
    @test Diff3D._sheen_lobe(material, normal, light, view) == Color3(0.0, 0.0, 0.0)
end

@testset "Default SpriteMaterial blends its opacity" begin
    # three.js blends sprites by default (SpriteMaterial.js:107), and
    # WebGLRenderLists.push sends `transparent` materials to the blended list.
    # The renderer's blend decision for a default half-opaque sprite therefore
    # matches an explicitly transparent one (renderer_audit.jl checks that a
    # blending primitive composites over the background).
    default_sprite = Sprite(SpriteMaterial(color=Color3(0.0, 0.0, 1.0), opacity=0.5))
    @test Diff3D._render_primitive_blends(default_sprite)
    @test Diff3D._primitive_blend_alpha(default_sprite.material) == 0.5
    opaque_sprite = Sprite(SpriteMaterial(opacity=0.5, transparent=false))
    @test !Diff3D._render_primitive_blends(opaque_sprite)
    @test Diff3D._primitive_blend_alpha(opaque_sprite.material) == 1.0
end

@testset "DataTexture and DepthTexture default to nearest filtering" begin
    # DataTexture.js:32 and DepthTexture.js:28 default magFilter and minFilter
    # to NearestFilter.
    data_texture = DataTexture(reshape([0.0, 1.0], 1, 2, 1))
    @test data_texture.filter === :nearest
    @test data_texture.min_filter === :nearest
    @test data_texture.mag_filter === :nearest
    # Halfway between the texels, nearest reads floor(0.5 * 2) = texel 1.
    @test sample_texture(data_texture, 0.5, 0.5).r == 1.0
    depth_texture = DepthTexture([0.25 0.75])
    @test depth_texture.filter === :nearest
    @test depth_texture.min_filter === :nearest && depth_texture.mag_filter === :nearest
    @test sample_texture(depth_texture, 0.5, 0.5).r == 0.75
    # Explicit filters still apply.
    @test DataTexture(reshape([0.0, 1.0], 1, 2, 1); filter=:bilinear).filter === :bilinear
    @test sample_texture(DepthTexture([0.25 0.75]; filter=:linear), 0.5, 0.5).r == 0.5
    @test CanvasTexture(reshape([0.0, 1.0], 1, 2, 1)).filter === :bilinear
end

@testset "Samplers return one concrete type for Dual coordinates" begin
    bilinear = Texture(reshape(collect(range(0.0, 1.0; length=48)), 4, 4, 3))
    nearest = Texture(copy(bilinear.data); filter=:nearest)
    mipmapped = Texture(rand(8, 8, 3); min_filter=:linear_mipmap_linear)
    generate_mipmaps!(mipmapped)
    cube = CubeTexture(ntuple(_ -> mipmapped, 6))
    dual = ForwardDiff.Dual(0.3, 1.0)
    D = typeof(dual)
    for texture in (bilinear, nearest)
        @test @inferred(sample_texture(texture, dual, 0.4)) isa Color3{D}
        @test @inferred(sample_texture_linear(texture, 0.6, dual)) isa Color3{D}
        @test @inferred(Diff3D.sample_texture_channel(texture, dual, dual, 2)) isa D
        @test @inferred(Diff3D._sample_texture_unit_channel(texture, dual, 0.4, 4)) isa D
    end
    # Nearest samples are constants: zero derivative, unchanged value.
    nearest_sample = sample_texture(nearest, dual, 0.4)
    @test ForwardDiff.value(nearest_sample.r) == sample_texture(nearest, 0.3, 0.4).r
    @test ForwardDiff.partials(nearest_sample.r)[1] == 0.0
    # Magnified, minified, and nearest-mip footprints share one return type.
    for duv in (0.01, 0.3, 0.9)
        @test @inferred(sample_texture_auto(mipmapped, 0.3, 0.4,
                                            ForwardDiff.Dual(duv, 1.0))) isa Color3{D}
    end
    nearest_mip = Texture(rand(8, 8, 3); min_filter=:nearest_mipmap_nearest)
    generate_mipmaps!(nearest_mip)
    @test @inferred(sample_texture_auto(nearest_mip, 0.3, 0.4, dual)) isa Color3{D}
    for texture in (mipmapped, bilinear)
        @test @inferred(sample_texture_aniso(texture, 0.3, 0.4, dual, 0.01)) isa Color3{D}
        @test @inferred(sample_texture_aniso(texture, 0.3, 0.4, 0.01, dual)) isa Color3{D}
    end
    # The zero-direction fallback keeps the direction's scalar type.
    zero_dual = ForwardDiff.Dual(0.0, 1.0)
    zero_sample = @inferred(sample_cube(cube, Vec3(zero_dual, zero_dual, zero_dual)))
    @test zero_sample isa Color3{D}
    # A zero Dual direction (value 0, nonzero partials) uses the face-center
    # fallback instead of dividing 0/0 into NaN coordinates.
    @test ForwardDiff.value(zero_sample.g) == sample_cube(cube, Vec3(0.0, 0.0, 0.0)).g
    @test ForwardDiff.partials(zero_sample.g)[1] == 0.0
    @test @inferred(sample_cube(cube, Vec3(dual, 0.2, -0.1))) isa Color3{D}
    @test sample_cube(cube, Vec3(0.0, 0.0, 0.0)) ==
          sample_texture(cube.faces[1], 0.5, 0.5)
end

function _audit3_sampler_allocations(texture, mipmapped, cube)
    sample_texture(texture, 0.3, 0.7)
    sample_texture_linear(texture, 0.3, 0.7)
    Diff3D._sample_texture_unit_channel(texture, 0.3, 0.7, 2)
    sample_texture_auto(mipmapped, 0.3, 0.7, 0.2)
    sample_cube(cube, Vec3(0.3, -0.7, 0.2))
    return (@allocated(sample_texture(texture, 1.3, -0.7)),
            @allocated(sample_texture_linear(texture, 0.3, 0.7)),
            @allocated(Diff3D._sample_texture_unit_channel(texture, -2.3, 0.7, 2)),
            @allocated(sample_texture_auto(mipmapped, 0.3, 0.7, 0.2)),
            @allocated(sample_cube(cube, Vec3(0.3, -0.7, 0.2))))
end

@testset "Per-pixel texture samplers do not allocate" begin
    for filter in (:nearest, :bilinear), wrap in (:repeat, :clamp, :mirror)
        texture = Texture(rand(16, 16, 3); filter, wrap_s=wrap, wrap_t=wrap,
                          offset=Vec2(0.1, 0.2), repeat=Vec2(2.0, 3.0), rotation=0.3)
        mipmapped = Texture(rand(16, 16, 3); filter, min_filter=:linear_mipmap_linear)
        generate_mipmaps!(mipmapped)
        cube = CubeTexture(ntuple(_ -> mipmapped, 6))
        if Base.JLOptions().opt_level > 0
            _audit3_sampler_allocations(texture, mipmapped, cube)
            @test all(iszero, _audit3_sampler_allocations(texture, mipmapped, cube))
        end
    end
end

@testset "sample_texture documents its own method" begin
    # The docstring was attached to an internal helper, leaving the generic
    # docs.jl summary on the exported function.
    text = string(@doc sample_texture)
    @test occursin("sample_texture(tex, u, v)", text)
    @test occursin("floor(u·W)", text)
end

@testset "Physical attenuation distance accepts the three.js Infinity default" begin
    # MeshPhysicalMaterial.js: `this.attenuationDistance = Infinity` means no
    # absorption; Diff3D stores that volume as distance 0 (attenuation off).
    infinite = MeshPhysicalMaterial(transmission=1.0, thickness=0.5,
                                    attenuation_color=Color3(0.2, 0.5, 0.9),
                                    attenuation_distance=Inf)
    @test infinite.attenuation_distance == 0.0
    off = MeshPhysicalMaterial(transmission=1.0, thickness=0.5,
                               attenuation_color=Color3(0.2, 0.5, 0.9))
    @test Diff3D._web_material_attenuation_distance(infinite) == 0.0
    @test MeshPhysicalMaterial(attenuation_distance=2.5).attenuation_distance == 2.5
    for invalid in (-Inf, NaN, -1.0, true)
        @test_throws ArgumentError MeshPhysicalMaterial(attenuation_distance=invalid)
    end
    @test getfield.(Ref(infinite), fieldnames(MeshPhysicalMaterial)) ==
          getfield.(Ref(off), fieldnames(MeshPhysicalMaterial))
end

@testset "AD footprints select the same samples as Float64 footprints" begin
    # ForwardDiff orders tied values by their partials (Dual(0, 1) <= 0 is
    # false), so discrete choices must use primal values or the primal result
    # changes with the number type. sample_texture_aniso documents that its
    # discrete decisions use the Float64 magnitudes.
    mipmapped = Texture(reshape(collect(range(0.0, 1.0; length=768)), 16, 16, 3);
                        min_filter=:linear_mipmap_linear)
    generate_mipmaps!(mipmapped)
    for (du, dv) in ((0.0, 0.3), (0.3, 0.0), (0.2, 0.2), (0.0, 0.0), (0.05, 0.3))
        expected = sample_texture_aniso(mipmapped, 0.3, 0.6, du, dv)
        for (ddu, ddv) in ((ForwardDiff.Dual(du, 1.0), dv), (du, ForwardDiff.Dual(dv, 1.0)),
                           (ForwardDiff.Dual(du, -1.0), ForwardDiff.Dual(dv, 1.0)))
            actual = sample_texture_aniso(mipmapped, 0.3, 0.6, ddu, ddv)
            @test ForwardDiff.value(actual.r) == expected.r
            @test ForwardDiff.value(actual.g) == expected.g
            @test ForwardDiff.value(actual.b) == expected.b
        end
    end
    # A footprint exactly one texel wide magnifies for every number type.
    for duv in (1 / 16, 0.25)
        expected = sample_texture_auto(mipmapped, 0.3, 0.6, duv)
        actual = sample_texture_auto(mipmapped, 0.3, 0.6, ForwardDiff.Dual(duv, 1.0))
        @test ForwardDiff.value(actual.r) == expected.r
    end
end
