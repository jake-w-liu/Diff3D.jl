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

