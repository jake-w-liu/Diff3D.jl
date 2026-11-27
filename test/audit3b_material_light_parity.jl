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
