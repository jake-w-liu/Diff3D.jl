using Test, Diff3D, ForwardDiff

# Sum of the green channel of many linear-light samples: a non-inlined probe so
# the allocation count covers only the sampler calls.
function _audit3b_sample_sum(texture, us, vs)
    total = 0.0
    @inbounds for index in eachindex(us)
        total += sample_texture_linear(texture, us[index], vs[index]).g
    end
    return total
end

function _audit3b_sample_allocations(texture, us, vs)
    _audit3b_sample_sum(texture, us, vs)
    return @allocated _audit3b_sample_sum(texture, us, vs)
end

@testset "sRGB textures decode each texel before filtering" begin
    # three.js uploads sRGB color maps as SRGB8_ALPHA8 (WebGLTextures.js:234),
    # and GL converts every texel to linear light before it is filtered
    # (EXT_sRGB / GLES 3.0 sRGB texture conversion). A black|white pair
    # sampled halfway between the texel centres is therefore 0.5 in linear
    # light, not srgb_to_linear(0.5) = 0.214.
    data = zeros(1, 2, 3)
    data[1, 2, :] .= 1.0
    texture = Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:bilinear,
                      colorspace=:srgb)
    @test sample_texture_linear(texture, 0.5, 0.5).r == 0.5
    # u = 0.375 puts weight 1/4 on the white texel.
    @test sample_texture_linear(texture, 0.375, 0.5).g == 0.25
    @test sample_texture_linear(texture, 0.25, 0.5).b == 0.0
    # Raw sampling keeps filtering the stored values.
    @test sample_texture(texture, 0.375, 0.5).r == 0.25

    # Single-channel (luminance) storage decodes the same way.
    gray = Texture(reshape([0.0, 1.0], 1, 2, 1); wrap_s=:clamp, wrap_t=:clamp,
                   colorspace=:srgb)
    @test sample_texture_linear(gray, 0.5, 0.5) == Color3(0.5, 0.5, 0.5)

    # A mid-gray byte (188/255) blended with black: decode-then-filter gives
    # half of the decoded value.
    mid = zeros(1, 2, 3)
    mid[1, 2, :] .= 188 / 255
    mid_texture = Texture(mid; wrap_s=:clamp, wrap_t=:clamp, colorspace=:srgb)
    @test sample_texture_linear(mid_texture, 0.5, 0.5).r ≈
          srgb_to_linear(188 / 255) / 2 rtol = 1e-15

    # Linear textures are unchanged.
    linear_texture = Texture(copy(data); wrap_s=:clamp, wrap_t=:clamp,
                             colorspace=:linear)
    @test sample_texture_linear(linear_texture, 0.375, 0.5).r == 0.25
end

@testset "sRGB mip blending decodes before the trilinear blend" begin
    # 1x2 black|white: generate_mipmaps! box-filters the stored values to a
    # 1x1 level holding 0.5. At lod = 1/2 (duv * 2 = sqrt(2)) on the black texel
    # centre, GL blends the decoded level samples: (0 + srgb_to_linear(0.5)) / 2.
    data = zeros(1, 2, 3)
    data[1, 2, :] .= 1.0
    texture = Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:bilinear,
                      min_filter=:linear_mipmap_linear, colorspace=:srgb)
    generate_mipmaps!(texture)
    duv = sqrt(2.0) / 2
    color = sample_texture_linear(texture, 0.25, 0.5, duv)
    @test color.r ≈ srgb_to_linear(0.5) / 2 rtol = 1e-12
    # Magnification uses the decoded bilinear base level.
    @test sample_texture_linear(texture, 0.5, 0.5, 0.1).r == 0.5
    # The raw sampler keeps returning stored values.
    @test sample_texture_auto(texture, 0.25, 0.5, duv).r ≈ 0.25 rtol = 1e-12
    linear_texture = Texture(copy(data); wrap_s=:clamp, wrap_t=:clamp,
                             min_filter=:linear_mipmap_linear, colorspace=:linear)
    generate_mipmaps!(linear_texture)
    @test sample_texture_linear(linear_texture, 0.25, 0.5, duv) ==
          sample_texture_auto(linear_texture, 0.25, 0.5, duv)
end

@testset "sRGB texel decode matches srgb_to_linear bit for bit" begin
    for k in 0:255
        value = k / 255
        @test Diff3D._srgb_texel_to_linear(value) === srgb_to_linear(value)
    end
    for value in (-0.0, 0.0, 0.5, 1 / 3, 0.04045, 0.0404500001, 1.0, 1.5, -0.25,
                  prevfloat(1.0), nextfloat(0.0), 17 / 255 + eps(), 65535 / 65535,
                  1234 / 65535)
        @test Diff3D._srgb_texel_to_linear(value) === srgb_to_linear(value)
    end
    @test isnan(Diff3D._srgb_texel_to_linear(NaN))
    # Nearest filtering returns exactly the decoded stored texel.
    data = reshape(collect(range(0.0, 1.0; length=12)), 2, 2, 3)
    texture = Texture(data; filter=:nearest, colorspace=:srgb)
    for u in (0.1, 0.6), v in (0.1, 0.6)
        raw = sample_texture(texture, u, v)
        @test sample_texture_linear(texture, u, v) ===
              Color3(srgb_to_linear(raw.r), srgb_to_linear(raw.g), srgb_to_linear(raw.b))
    end
end

@testset "sRGB sampling is type stable, AD-transparent, and allocation free" begin
    data = rand(8, 8, 3)
    data[:, :, 1] .= round.(data[:, :, 1] .* 255) ./ 255
    for filter in (:nearest, :bilinear)
        texture = Texture(copy(data); filter=filter, colorspace=:srgb)
        @test (@inferred sample_texture_linear(texture, 0.3, 0.7)) isa Color3{Float64}
        dual = ForwardDiff.Dual(0.3, 1.0)
        @test (@inferred sample_texture_linear(texture, dual, 0.7)) isa
              Color3{typeof(dual)}
        generate_mipmaps!(texture)
        @test (@inferred sample_texture_linear(texture, 0.3, 0.7, 0.2)) isa Color3{Float64}
        us = rand(64); vs = rand(64)
        if Base.JLOptions().opt_level > 0
            @test _audit3b_sample_allocations(texture, us, vs) == 0
        end
    end
    # Derivative of a bilinear sample is the decoded texel difference times W.
    data = zeros(1, 2, 3)
    data[1, 2, :] .= 1.0
    texture = Texture(data; wrap_s=:clamp, wrap_t=:clamp, colorspace=:srgb)
    slope = ForwardDiff.derivative(u -> sample_texture_linear(texture, u, 0.5).r, 0.5)
    @test slope ≈ 2.0 rtol = 1e-12
end

@testset "Light defaults follow three.js" begin
    # HemisphereLight.js:50 `new Color(groundColor)` is white when omitted
    # (node oracle: new HemisphereLight().groundColor = [1, 1, 1]).
    @test HemisphereLight().ground_color == Color3(1.0, 1.0, 1.0)
    @test HemisphereLight().color == Color3(1.0, 1.0, 1.0)
    # RectAreaLight.js:38 `width = 10, height = 10` (oracle: 10, 10), so the
    # default luminous power is intensity * 10 * 10 * pi (RectAreaLight.js:87).
    rect = RectAreaLight()
    @test (rect.width, rect.height) == (10.0, 10.0)
    @test rect.power ≈ 100pi rtol = 1e-15
    @test RectAreaLight(width=2.0, height=3.0).width == 2.0
end

# OpenGL ES 3.0 cube map texture selection (Table 3.21): major axis picks the
# face, s = (sc/|ma| + 1)/2, t = (tc/|ma| + 1)/2 with t counted from the first
# uploaded row. three.js uploads CubeTexture faces with flipY = false
# (CubeTexture.js), so t = 0 is storage row 1.
function _audit3b_gl_cube_texel(direction)
    x, y, z = direction.x, direction.y, direction.z
    ax, ay, az = abs(x), abs(y), abs(z)
    if ax >= ay && ax >= az
        face, sc, tc, ma = x > 0 ? (1, -z, -y, ax) : (2, z, -y, ax)
    elseif ay >= az
        face, sc, tc, ma = y > 0 ? (3, x, z, ay) : (4, x, -z, ay)
    else
        face, sc, tc, ma = z > 0 ? (5, x, -y, az) : (6, -x, -y, az)
    end
    return face, (sc / ma + 1) / 2, (tc / ma + 1) / 2
end

function _audit3b_cube_faces(filter; kwargs...)
    return ntuple(6) do face
        data = zeros(4, 4, 3)
        for row in 1:4, col in 1:4
            data[row, col, 1] = col
            data[row, col, 2] = row
            data[row, col, 3] = face
        end
        Texture(data; filter=filter, colorspace=:linear, kwargs...)
    end
end

@testset "Cube lookups follow the GL face selection and clamp at face edges" begin
    cube = CubeTexture(_audit3b_cube_faces(:nearest))   # faces keep wrap = :repeat
    directions = [Vec3(1.0, 0.3, -0.2), Vec3(-1.0, -0.4, 0.7), Vec3(0.2, 1.0, 0.6),
                  Vec3(-0.5, -1.0, -0.1), Vec3(0.6, -0.3, 1.0), Vec3(0.1, 0.8, -1.0),
                  # exactly on face edges and corners
                  Vec3(1.0, 0.0, -1.0), Vec3(1.0, 1.0, 1.0), Vec3(-1.0, 0.0, 1.0),
                  Vec3(0.0, -1.0, 1.0), Vec3(-1.0, -1.0, -1.0)]
    for direction in directions
        face, s, t = _audit3b_gl_cube_texel(direction)
        # GL ignores the wrap mode: an edge coordinate of 1 selects texel n-1.
        expected = Color3(Float64(clamp(floor(Int, 4s), 0, 3) + 1),
                          Float64(clamp(floor(Int, 4t), 0, 3) + 1), Float64(face))
        @test sample_cube(cube, direction) == expected
    end
    # Bilinear edge sample: clamped to the edge column instead of blending in the
    # opposite edge of the face (repeat would give the (4 + 1)/2 average).
    bilinear = CubeTexture(_audit3b_cube_faces(:bilinear))
    @test sample_cube(bilinear, Vec3(1.0, 0.0, -1.0)).r == 4.0
    @test sample_cube(bilinear, Vec3(1.0, 0.0, -0.99)).r == 4.0
    # A face UV transform is not part of a cube lookup (three.js envmap
    # shaders sample textureCube(envMap, direction) with no uv transform).
    shifted = CubeTexture(_audit3b_cube_faces(:nearest; offset=Vec2(0.5, 0.0)))
    @test sample_cube(shifted, Vec3(1.0, 0.0, 0.0)) == sample_cube(cube, Vec3(1.0, 0.0, 0.0))
    # Mip levels are clamped the same way.
    faces = _audit3b_cube_faces(:nearest)
    foreach(generate_mipmaps!, faces)
    mipped = CubeTexture(faces)
    @test sample_cube_lod(mipped, Vec3(1.0, 0.0, -1.0), 1.0).r == 3.5
end

function _audit3b_tile_scene(light)
    scene = Scene()
    floor = Mesh(BoxGeometry(width=10.0, height=0.2, depth=10.0), MeshStandardMaterial())
    floor.position = Vec3(0.0, -0.1, 0.0)
    tile = Mesh(BoxGeometry(width=1.0, height=0.1, depth=1.0), MeshStandardMaterial())
    tile.position = Vec3(0.0, 0.05, 0.0)
    floor.cast_shadow = true
    tile.cast_shadow = true
    add!(scene, floor)
    add!(scene, tile)
    add!(scene, light)
    return scene
end

@testset "Perspective shadow cameras inside the scene keep thin casters" begin
    # A 0.1-thick tile on a 10x10 floor, light 3 units above: the floor under
    # the tile is occluded (three.js renders this shadow with its default
    # bias 0; the light sits inside the scene bounding sphere, where the old
    # radius/100 near plane stretched the 3e-3 NDC bias over ~0.27 world units).
    for light in (PointLight(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true),
                  SpotLight(position=Vec3(0.0, 3.0, 0.0), target=Vec3(0.0, 0.0, 0.0),
                            angle=pi / 4, cast_shadow=true))
        shadow = compute_shadow_map(_audit3b_tile_scene(light), light; resolution=256)
        for x in (0.0, 0.3, -0.3)
            @test shadow_visibility(shadow, Vec3(x, 0.0, 0.0)) == 0.0
        end
        @test shadow_visibility(shadow, Vec3(3.0, 0.0, 0.0)) == 1.0
        @test shadow_visibility(shadow, Vec3(0.0, 0.1, 0.0)) == 1.0
    end
    # The caster bound is the distance to the nearest caster triangle box.
    light = PointLight(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true)
    scene = _audit3b_tile_scene(light)
    meshes = collect_meshes(scene)
    @test Diff3D._shadow_caster_distance(meshes, InstancedMesh[], Vec3(0.0, 3.0, 0.0)) ≈ 2.9
end

@testset "LightShadow intensity and normalBias" begin
    # three.js LightShadow.js:41/74 defaults: intensity 1, normalBias 0.
    for Light in (DirectionalLight, PointLight, SpotLight)
        light = Light()
        @test light.shadow_intensity == 1.0
        @test light.shadow_normal_bias == 0.0
        @test_throws ArgumentError Light(shadow_intensity=1.5)
        @test_throws ArgumentError Light(shadow_intensity=NaN)
        @test_throws ArgumentError Light(shadow_normal_bias=Inf)
    end
    light = PointLight(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true,
                       shadow_intensity=0.4, shadow_normal_bias=0.15)
    shadow = compute_shadow_map(_audit3b_tile_scene(light), light; resolution=256)
    @test shadow.intensity == 0.4
    @test shadow.normal_bias == 0.15
    # shadowmap_pars_fragment.glsl.js:180: mix(1.0, shadow, shadowIntensity).
    @test shadow_visibility(shadow, Vec3(0.0, 0.0, 0.0)) ≈ 0.6 rtol = 1e-15
    @test shadow_visibility(shadow, Vec3(3.0, 0.0, 0.0)) == 1.0
    # shadowmap_vertex.glsl.js: the lookup moves along the normal by normalBias;
    # 0.15 lifts the floor point above the 0.1-high tile top.
    @test shadow_visibility(shadow, Vec3(0.0, 0.0, 0.0); normal=Vec3(0.0, 1.0, 0.0)) == 1.0
    @test shadow_visibility(shadow, Vec3(0.0, 0.0, 0.0); normal=Vec3(0.0, -1.0, 0.0)) ≈ 0.6
    # Mutating the light property is honoured by the next shadow pass.
    light.shadow_intensity = 1.0
    shadow = compute_shadow_map(_audit3b_tile_scene(light), light; resolution=256)
    @test shadow_visibility(shadow, Vec3(0.0, 0.0, 0.0)) == 0.0
    # Explicit ShadowMap construction accepts the same settings.
    manual = ShadowMap(fill(-1.0, 4, 4), Mat4(), 0.0, 0; intensity=0.25)
    @test manual.intensity == 0.25
    @test manual.normal_bias == 0.0
    @test_throws ArgumentError ShadowMap(fill(-1.0, 4, 4), Mat4(), 0.0, 0; intensity=-0.1)

    # End to end: render! with shadows multiplies the direct light by
    # mix(1, visibility, intensity). A slab 1.5 above a subdivided floor, sun
    # along (1, 1, 0): the shadow falls on x in [-2, -1], beside the slab as
    # seen from above.
    function shadow_render(intensity)
        scene = Scene()
        floor = Mesh(PlaneGeometry(width=4.0, height=4.0, width_segments=32,
                                   height_segments=32), MeshLambertMaterial())
        floor.rotation = Euler(-pi / 2, 0.0, 0.0)
        floor.receive_shadow = true
        blocker = Mesh(BoxGeometry(width=1.0, height=0.1, depth=1.0), MeshLambertMaterial())
        blocker.position = Vec3(0.0, 1.5, 0.0)
        blocker.cast_shadow = true
        add!(scene, floor)
        add!(scene, blocker)
        add!(scene, DirectionalLight(position=Vec3(1.0, 1.0, 0.0), cast_shadow=true,
                                     shadow_intensity=intensity))
        camera = OrthographicCamera(left=-2.0, right=2.0, top=2.0, bottom=-2.0,
                                    near=0.1, far=20.0)
        camera.position = Vec3(0.0, 3.0, 0.0)
        camera.target = Vec3(0.0, 0.0, 0.0)
        camera.up = Vec3(0.0, 0.0, -1.0)
        target = RenderTarget(32, 32)
        render!(target, scene, camera; shadows=true)
        return target.color
    end
    full = shadow_render(1.0)
    half = shadow_render(0.5)
    lit = cos(pi / 4) / pi                  # Lambert, N·L = cos 45°, BRDF 1/π
    shadowed = findall(==(0.0), full)
    @test length(shadowed) > 100
    @test all(i -> isapprox(full[i], lit; rtol=1e-12) || full[i] == 0.0, eachindex(full))
    @test all(i -> isapprox(half[i], 0.5 * lit; rtol=1e-12), shadowed)
    @test all(i -> half[i] == full[i], findall(>(0.0), full))
end

# three.js r186 oracle (node, scratch sh_oracle.mjs): LightProbeGenerator
# .fromCubeTexture on six 3x3 RGBA byte faces whose texel p (row-major from the
# top) holds channel c = (37 face + 11 p + 5 c^2 + 3) mod 256, face 0-based.
const _AUDIT3B_SH_SRGB = [
    (1.0940213140780002, 1.117825762695413, 1.2239500528927483),
    (-0.1783896417199619, -0.14537630934111473, -0.12333106927543125),
    (-0.052751592473017105, 0.009041959221841627, 0.06605552609654644),
    (-0.01548824444838248, 0.026807249489732, 0.005614725557244952),
    (0.04097215832166889, -0.0016872648535054943, -0.04656643207855053),
    (-0.04901315649433875, -0.11778417537615926, -0.06739307625340916),
    (0.6303820943157326, 0.6240337613276759, 0.5760159452786826),
    (0.01632735444602144, -0.047972213801656644, 0.15110409680765652),
    (-0.22795119506221742, -0.2416832302352915, -0.32915850500245436)]
const _AUDIT3B_SH_LINEAR = [
    (1.8215964673704261, 1.8439466053724527, 1.9347927407900265),
    (-0.16797455349656043, -0.1283539759919432, -0.08873339848732595),
    (0.037300772150974944, 0.09673163840790083, 0.1389310700696233),
    (0.058875102699591425, 0.09849568020420876, 0.07036272576306038),
    (0.04297449021853791, 2.6996143433202836e-17, -0.04297449021853788),
    (-0.059044282255733146, -0.12350601758354005, -0.05904428225573306),
    (0.5235750367716133, 0.49256081492734405, 0.3766377648712525),
    (0.06446173532780684, -5.099271537382758e-17, 0.19051843000595314),
    (-0.32719483989848347, -0.32719483989848336, -0.36921373812453223)]

function _audit3b_probe_faces(colorspace)
    return ntuple(6) do face
        data = zeros(3, 3, 3)
        for row in 1:3, col in 1:3, channel in 1:3
            p = (row - 1) * 3 + (col - 1)
            data[row, col, channel] =
                mod(37 * (face - 1) + 11 * p + 5 * (channel - 1)^2 + 3, 256) / 255
        end
        Texture(data; colorspace=colorspace)
    end
end

@testset "LightProbe spherical harmonics (order 2)" begin
    # Generator parity. Diff3D cube faces are unmirrored (sample_cube follows the
    # GL face table, like three.js render-target cubes), while fromCubeTexture
    # mirrors x for image cube textures (LightProbeGenerator.js face 0 maps to
    # x = -1; WebGLMaterials.js:247-251 flipEnvMap). The basis functions odd in
    # x (three.js indices 3, 4, 7) therefore change sign.
    signs = (1, 1, 1, -1, -1, 1, 1, -1, 1)
    # three.js decodes sRGB with 10-digit constants (ColorManagement.js:207
    # `pow(c * 0.9478672986 + 0.0521327014, 2.4)`), Diff3D with the exact
    # (c + 0.055) / 1.055, so the sRGB faces agree to ~1e-11 relative.
    for (colorspace, oracle, rtol) in ((:srgb, _AUDIT3B_SH_SRGB, 1e-9),
                                       (:linear, _AUDIT3B_SH_LINEAR, 1e-12))
        probe = Diff3D.light_probe_from_cube_texture(CubeTexture(_audit3b_probe_faces(colorspace)))
        @test probe isa LightProbe
        @test probe.coeffs == ntuple(_ -> Color3(0.0, 0.0, 0.0), 4)
        for j in 1:9, (channel, value) in enumerate(oracle[j])
            got = (probe.sh[j].r, probe.sh[j].g, probe.sh[j].b)[channel]
            @test isapprox(got, signs[j] * value; rtol=rtol, atol=1e-15)
        end
    end
    @test Diff3D.light_probe_from_cube_texture(CubeTexture(_audit3b_probe_faces(:linear));
                                        intensity=0.5).intensity == 0.5
    bad_faces = (Texture(zeros(2, 3, 3)), _audit3b_probe_faces(:linear)[2:6]...)
    @test_throws ArgumentError Diff3D.light_probe_from_cube_texture(CubeTexture(bad_faces))

    # Irradiance: three.js SphericalHarmonics3.getIrradianceAt oracle for
    # coefficients c_j = (0.1(j+1), 0.05(9-j), 0.02 j^2 - 0.3), j = 0..8.
    sh = ntuple(j -> Color3(0.1 * j, 0.05 * (10 - j), 0.02 * (j - 1)^2 - 0.3), 9)
    probe = LightProbe(sh=sh)
    oracle = [((0.0, 1.0, 0.0), (-0.266246, 0.7495250000000001, -1.0768994399999998)),
              ((1.0, 0.0, 0.0), (0.7106969999999999, 0.6900965000000001, -0.07224267999999995)),
              ((0.0, 0.0, -1.0), (0.12841619999999998, 0.11494989999999997, 0.16733919999999997)),
              ((0.48, -0.6, 0.64), (0.23802673344000014, 0.43418654048, -0.21925809164799986))]
    for (normal, expected) in oracle
        got = Diff3D._fill_color(Vec3(normal...), probe)
        # three.js adds shGetIrradianceAt unclamped (lights_fragment_begin.glsl.js:230),
        # so negative irradiance (three of these channels) is kept.
        @test got.r ≈ expected[1] atol = 1e-15
        @test got.g ≈ expected[2] atol = 1e-15
        @test got.b ≈ expected[3] atol = 1e-15
    end
    # The clamped order-1 `coeffs` term and the unclamped SH term add.
    mixed = LightProbe(coeffs=(Color3(-0.2, 0.1, 0.0), Color3(0.0, 0.0, 0.0),
                               Color3(0.0, 0.0, 0.0), Color3(0.0, 0.0, 0.0)), sh=sh)
    got = Diff3D._fill_color(Vec3(0.0, 1.0, 0.0), mixed)
    @test got.r ≈ 0.0 + oracle[1][2][1] atol = 1e-15
    @test got.g ≈ 0.1 + oracle[1][2][2] atol = 1e-15
    doubled = Diff3D._fill_color(Vec3(1.0, 0.0, 0.0), LightProbe(sh=sh, intensity=2.0))
    single = Diff3D._fill_color(Vec3(1.0, 0.0, 0.0), probe)
    @test (doubled.r, doubled.g, doubled.b) == (2single.r, 2single.g, 2single.b)

    # The order-1 `coeffs` form is unchanged and equals the matching SH9 probe:
    # DC = 0.886227 L00, gradient = 2 * 0.511664 * (L11, L1-1, L10).
    coeffs = (Color3(0.5, 0.4, 0.3), Color3(0.1, 0.0, -0.05), Color3(0.2, 0.1, 0.0),
              Color3(-0.1, 0.05, 0.02))
    legacy = LightProbe(coeffs=coeffs)
    @test legacy.sh == ntuple(_ -> Color3(0.0, 0.0, 0.0), 9)
    k1 = 2.0 * 0.511664
    zero_color = Color3(0.0, 0.0, 0.0)
    as_sh = LightProbe(sh=(coeffs[1] * (1 / 0.886227), coeffs[3] * (1 / k1),
                           coeffs[4] * (1 / k1), coeffs[2] * (1 / k1),
                           zero_color, zero_color, zero_color, zero_color, zero_color))
    for normal in (Vec3(0.0, 1.0, 0.0), normalize(Vec3(0.3, -0.4, 0.8)), Vec3(-1.0, 0.0, 0.0))
        a = Diff3D._fill_color(normal, legacy)
        b = Diff3D._fill_color(normal, as_sh)
        @test a.r ≈ b.r atol = 1e-15
        @test a.g ≈ b.g atol = 1e-15
        @test a.b ≈ b.b atol = 1e-15
        manual = coeffs[1] + coeffs[2] * normal.x + coeffs[3] * normal.y + coeffs[4] * normal.z
        @test a.r ≈ max(manual.r, 0.0) atol = 1e-15
        @test a.g ≈ max(manual.g, 0.0) atol = 1e-15
        @test a.b ≈ max(manual.b, 0.0) atol = 1e-15
    end
    # Positional (10-field) construction keeps working with an empty SH.
    positional = LightProbe(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0), nothing,
                            Diff3D.AbstractObject3D[], true, "p", 1, coeffs, 1.0)
    @test positional.sh == legacy.sh
    @test_throws ArgumentError LightProbe(sh=ntuple(_ -> Color3(0.0, 0.0, 0.0), 4))
    @test_throws ArgumentError LightProbe(sh=(Color3(NaN, 0.0, 0.0),
                                              ntuple(_ -> zero_color, 8)...))
    # ForwardDiff normals flow through the SH term.
    derivative = ForwardDiff.derivative(
        t -> Diff3D._fill_color(Vec3(t, sqrt(1 - t^2), 0.0), probe).g, 0.6)
    @test isfinite(derivative)

    # Rendered: an SH probe with only L00 lights a surface like an AmbientLight
    # of colour 0.886227 L00 (both feed the same irradiance, lights_fragment_begin).
    function sphere_image(light)
        scene = Scene()
        add!(scene, Mesh(SphereGeometry(radius=1.0), MeshLambertMaterial()))
        add!(scene, light)
        camera = PerspectiveCamera(fov=pi / 4, aspect=1.0)
        camera.position = Vec3(0.0, 0.0, 4.0)
        target = RenderTarget(16, 16)
        render!(target, scene, camera)
        return copy(target.color)
    end
    l00 = Color3(0.3, 0.6, 0.9)
    sh_image = sphere_image(LightProbe(sh=(l00, ntuple(_ -> zero_color, 8)...)))
    ambient_image = sphere_image(AmbientLight(color=l00 * 0.886227))
    @test maximum(abs.(sh_image .- ambient_image)) <= 1e-12
    @test maximum(sh_image) > 0
end

function _audit3b_normal_lookup_allocations(query, light, points, normal)
    total = 0.0
    for p in points
        total += Diff3D._shadow_fn_visibility(query, light, p, normal)
    end
    return @allocated for p in points
        total += Diff3D._shadow_fn_visibility(query, light, p, normal)
    end
end

@testset "Normal-biased shadow queries stay allocation free" begin
    light = PointLight(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true,
                       shadow_intensity=0.5, shadow_normal_bias=0.05)
    scene = _audit3b_tile_scene(light)
    maps = IdDict{Diff3D.AbstractLight,ShadowMap}()
    query = Diff3D._build_shadow_query_from_drawables!(maps, Matrix{Float64}[], [light],
                                                       collect_meshes(scene),
                                                       InstancedMesh[]; resolution=32)
    points = [Vec3(0.1i - 2.0, 0.0, 0.05i) for i in 1:40]
    normal = Vec3(0.0, 1.0, 0.0)
    @test (@inferred Diff3D._shadow_fn_visibility(query, light, points[1], normal)) isa Float64
    # A caller-supplied two-argument shadow function keeps working.
    @test Diff3D._shadow_fn_visibility((l, p) -> 0.25, light, points[1], normal) == 0.25
    if Base.JLOptions().opt_level > 0
        @test _audit3b_normal_lookup_allocations(query, light, points, normal) == 0
    end
end

function _audit3b_web_html(scene)
    path = tempname() * ".html"
    try
        save_webgl_html(path, [WebGLExportCase("audit3b", "Audit", "audit", scene)]; chrome=false)
        return read(path, String)
    finally
        rm(path; force=true)
    end
end

@testset "WebGL export refuses light settings its viewer cannot honour" begin
    function web_scene(light)
        scene = Scene()
        floor = Mesh(BoxGeometry(width=4.0, height=0.2, depth=4.0), MeshStandardMaterial())
        floor.cast_shadow = true
        add!(scene, floor)
        add!(scene, light)
        return scene
    end
    # The viewer evaluates only the order-1 coeffs of a probe.
    sh = ntuple(j -> Color3(0.1j, 0.0, 0.0), 9)
    @test_throws ArgumentError _audit3b_web_html(web_scene(LightProbe(sh=sh)))
    @test occursin("lightProbe", _audit3b_web_html(web_scene(LightProbe(Color3(0.2, 0.2, 0.2)))))
    # Its shadow shaders take neither shadow intensity nor normal bias.
    for Light in (DirectionalLight, PointLight, SpotLight)
        @test_throws ArgumentError _audit3b_web_html(web_scene(
            Light(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true, shadow_intensity=0.5)))
        @test_throws ArgumentError _audit3b_web_html(web_scene(
            Light(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true, shadow_normal_bias=0.1)))
        # A light that casts no shadow exports whatever its shadow settings.
        @test _audit3b_web_html(web_scene(
            Light(position=Vec3(0.0, 3.0, 0.0), shadow_intensity=0.5))) isa String
        @test _audit3b_web_html(web_scene(
            Light(position=Vec3(0.0, 3.0, 0.0), cast_shadow=true))) isa String
    end
end
