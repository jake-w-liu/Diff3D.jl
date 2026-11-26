using Test, Diff3D

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
    # three.js blends sprites by default (SpriteMaterial.js:107), so a
    # half-opaque default sprite renders like an explicitly transparent one.
    function render_sprite(material)
        scene = Scene()
        scene.background = Color3(1.0, 0.0, 0.0)
        add!(scene, Sprite(material))
        camera = PerspectiveCamera()
        camera.position = Vec3(0.0, 0.0, 2.0)
        target = RenderTarget(16, 16)
        render!(target, scene, camera)
        return target.color[8, 8, :]
    end
    default_pixel = render_sprite(SpriteMaterial(color=Color3(0.0, 0.0, 1.0), opacity=0.5))
    @test default_pixel == render_sprite(SpriteMaterial(color=Color3(0.0, 0.0, 1.0),
                                                        opacity=0.5, transparent=true))
    # Blue at opacity 0.5 over a red background keeps half of the red.
    @test default_pixel[1] > 0.1 && default_pixel[3] > 0.1
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
