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
        _audit3b_sample_sum(texture, us, vs)
        @test (@allocated _audit3b_sample_sum(texture, us, vs)) == 0
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
