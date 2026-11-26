using Test, Diff3D, ForwardDiff

# Oracle values below come from a Float64 evaluation of three.js r186
# src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js run in
# Node (each operator transcribed from that chunk; GLSL mat3 arguments are
# columns). Inputs: (exposure, linear RGB).
const _TONE_MAP_ORACLE = [
    (1.0, (0.5, 0.25, 0.1), Dict(
        :linear => (0.5, 0.25, 0.1),
        :reinhard => (0.3333333333333333, 0.2, 0.09090909090909091),
        :cineon => (0.5006992230350052, 0.30602136481273395, 0.11560532652435328),
        :aces_filmic => (0.5679584881766624, 0.3206169050801387, 0.12501640086793822),
        :agx => (0.4369136375920812, 0.2720101389863574, 0.15515228108211515),
        :neutral => (0.46, 0.21, 0.060000000000000005))),
    (1.0, (10.0, 3.0, 0.2), Dict(
        :linear => (1.0, 1.0, 0.2),
        :reinhard => (0.9090909090909091, 0.75, 0.16666666666666669),
        :cineon => (0.9588089521584482, 0.8724999791706037, 0.24992934528190786),
        :aces_filmic => (1.0, 0.9402163871064835, 0.706685508113777),
        :agx => (1.0, 0.8331183090316939, 0.6232630276983082),
        :neutral => (0.9938983050847457, 0.6960099682172178, 0.5768546334702067))),
    (2.5, (0.9, 0.8, 0.85), Dict(
        :linear => (1.0, 1.0, 1.0),
        :reinhard => (0.6923076923076923, 0.6666666666666666, 0.68),
        :cineon => (0.835640824281543, 0.8181262844941597, 0.8273255551239812),
        :aces_filmic => (0.9011966979709731, 0.8880034895506862, 0.8947123041232354),
        :agx => (0.7654732205853045, 0.745126728351149, 0.7551441657302306),
        :neutral => (0.9659171597633136, 0.8738343156647471, 0.9198757377140303))),
    (0.5, (0.07, 0.5, 0.9), Dict(
        :linear => (0.035, 0.25, 0.45),
        :reinhard => (0.03381642512077295, 0.2, 0.3103448275862069),
        :cineon => (0.02323005147858707, 0.30602136481273395, 0.4705335151496075),
        :aces_filmic => (0.03230033391311119, 0.30872384172198736, 0.5034505647284333),
        :agx => (0.09416083175699835, 0.2915916898258915, 0.41975641035159855),
        :neutral => (0.007656250000000003, 0.22265625, 0.42265625))),
]

@testset "tone_map matches three.js tonemapping_pars_fragment" begin
    for (exposure, rgb, expected) in _TONE_MAP_ORACLE, (mode, want) in expected
        img = reshape(collect(rgb), 1, 1, 3)
        got = Diff3D.tone_map(img, mode; exposure=exposure)
        @test size(got) == (1, 1, 3) && eltype(got) == Float64
        @test collect(vec(got)) ≈ collect(want) rtol=1e-14 atol=1e-15
        color = Diff3D.tone_map(Color3(rgb...), mode; exposure=exposure)
        @test (color.r, color.g, color.b) == (got[1], got[2], got[3])
    end
    # NoToneMapping copies the input (OutputShader.js applies no operator).
    img = rand(3, 4, 3) .* 4
    copy_out = Diff3D.tone_map(img, :none)
    @test copy_out == img && copy_out !== img
    # Image layout: per-pixel operators see each pixel's own RGB triple.
    big = rand(5, 7, 3) .* 3
    mapped = Diff3D.tone_map(big, :agx; exposure=1.7)
    for j in 1:7, i in 1:5
        c = Diff3D.tone_map(Color3(big[i, j, 1], big[i, j, 2], big[i, j, 3]), :agx; exposure=1.7)
        @test (mapped[i, j, 1], mapped[i, j, 2], mapped[i, j, 3]) == (c.r, c.g, c.b)
    end
    @test_throws ArgumentError Diff3D.tone_map(img, :aces)
    @test_throws ArgumentError Diff3D.tone_map(img, :agx; exposure=Inf)
    @test_throws ArgumentError Diff3D.tone_map(img, :agx; exposure=true)
    @test_throws ArgumentError Diff3D.tone_map(rand(2, 2, 4), :agx)
end

@testset "tone_map is differentiable" begin
    for mode in (:linear, :reinhard, :cineon, :aces_filmic, :agx, :neutral)
        f(x) = sum(Diff3D.tone_map(reshape([x, 0.6x, 0.3x], 1, 1, 3), mode; exposure=1.3))
        g = ForwardDiff.derivative(f, 0.7)
        h = 1e-6
        @test g ≈ (f(0.7 + h) - f(0.7 - h)) / (2h) rtol=1e-6
        dual_exposure = ForwardDiff.derivative(
            e -> sum(Diff3D.tone_map(reshape([0.4, 0.2, 0.1], 1, 1, 3), mode; exposure=e)), 1.1)
        @test isfinite(dual_exposure)
        rg = reverse_gradient(v -> sum(Diff3D.tone_map(reshape([v[1], 0.6v[1], 0.3v[1]], 1, 1, 3),
                                                       mode; exposure=1.3)), [0.7])
        @test rg[1] ≈ g rtol=1e-12
    end
end

@testset "output_pass follows three.js OutputShader" begin
    img = reshape([0.5, 0.25, 0.1, 2.0, 0.003, 0.0], 2, 1, 3)
    # OutputShader.js: tone mapping, then sRGBTransferOETF when the output
    # colour space has the sRGB transfer.
    pass = Diff3D.output_pass(tone_mapping=:aces_filmic, exposure=0.8)
    @test pass(img) == linear_to_srgb.(Diff3D.tone_map(img, :aces_filmic; exposure=0.8))
    @test Diff3D.output_pass(tone_mapping=:neutral, output_color_space=:linear)(img) ==
          Diff3D.tone_map(img, :neutral)
    # NoToneMapping + sRGB transfer, unclamped like the shader.
    @test Diff3D.output_pass()(img) == linear_to_srgb.(img)
    composer = EffectComposer()
    add_pass!(composer, Diff3D.output_pass(tone_mapping=:agx))
    @test compose(composer, img) == linear_to_srgb.(Diff3D.tone_map(img, :agx))
    @test_throws ArgumentError Diff3D.output_pass(tone_mapping=:filmic)
    @test_throws ArgumentError Diff3D.output_pass(output_color_space=:display_p3)
    @test_throws ArgumentError Diff3D.output_pass(exposure=NaN)
end
