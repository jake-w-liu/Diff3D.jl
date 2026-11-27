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

function _audit3_wire_scene(order)
    scene = Scene(); scene.background = Color3(0.0, 0.0, 0.0)
    wire = Mesh(PlaneGeometry(width=1.5, height=1.5, width_segments=3, height_segments=3),
                MeshBasicMaterial(color=Color3(1.0, 1.0, 0.0), wireframe=true,
                                  transparent=true, opacity=0.5))
    wire.position = Vec3(0.0, 0.0, 1.0)
    opaque_wire = Mesh(PlaneGeometry(width=2.0, height=2.0),
                       MeshBasicMaterial(color=Color3(1.0, 0.0, 1.0), wireframe=true))
    opaque_wire.position = Vec3(0.2, 0.1, -0.5)
    plane = Mesh(PlaneGeometry(width=2.0, height=2.0), MeshBasicMaterial(color=Color3(0.0, 1.0, 0.0)))
    plane.position = Vec3(0.2, 0.1, -0.5)
    back = Mesh(PlaneGeometry(width=3.0, height=3.0), MeshBasicMaterial(color=Color3(0.0, 0.0, 1.0)))
    back.position = Vec3(0.0, 0.0, -1.0)
    instances = InstancedMesh(BoxGeometry(width=0.4, height=0.4, depth=0.4),
                              MeshBasicMaterial(color=Color3(1.0, 0.5, 0.0), wireframe=true,
                                                transparent=true, opacity=0.4), 3)
    for i in 1:3
        set_instance_matrix!(instances, i, mat4_translation(0.5 * (i - 2), -0.3, 1.5 - 0.3i))
        set_instance_color!(instances, i, Color3(1.0, i / 3, 0.2))
    end
    objects = (wire, opaque_wire, plane, back, instances)
    for k in order
        add!(scene, objects[k])
    end
    return scene
end

@testset "render_tiled! draws wireframes in render! order" begin
    # rasterizer.jl render!: opaque wireframes are drawn after the opaque and
    # smooth mesh passes; blended wireframes (mesh and instanced) are drawn in
    # the back-to-front transparent pass. Scene order must not matter.
    camera = PerspectiveCamera(); camera.position = Vec3(0.0, 0.0, 4.0)
    for order in ([1, 2, 3, 4], [5, 1, 2, 3, 4], [2, 1, 4, 3, 5], [4, 3, 2, 1])
        scene = _audit3_wire_scene(order)
        expected = RenderTarget(40, 40); render!(expected, scene, camera)
        for tiles in (1, 3)
            target = RenderTarget(40, 40)
            render_tiled!(target, scene, camera; tiles=tiles,
                          cache=[RenderCache() for _ in 1:min(tiles, Threads.nthreads())])
            @test target.color == expected.color
            @test isequal(target.depth, expected.depth)
        end
    end
end

@testset "render_tiled! culls blended wireframes like render!" begin
    # render! drops offscreen transparent items (frustum_cull=true) before its
    # unstable back-to-front sort. Two overlapping wireframes at equal depth
    # must keep render!'s relative order when offscreen wireframes also exist.
    camera = PerspectiveCamera(); camera.position = Vec3(0.0, 0.0, 4.0)
    scene = Scene(); scene.background = Color3(0.0, 0.0, 0.0)
    for color in (Color3(1.0, 0.0, 0.0), Color3(0.0, 1.0, 0.0))
        add!(scene, Mesh(PlaneGeometry(width=1.5, height=1.5, width_segments=2, height_segments=2),
                         MeshBasicMaterial(color=color, wireframe=true, transparent=true,
                                           opacity=0.5)))
    end
    for (i, z) in ((1, -1.0), (2, 1.0))
        offscreen = Mesh(PlaneGeometry(width=0.5, height=0.5),
                         MeshBasicMaterial(color=Color3(0.0, 0.0, 1.0), wireframe=true,
                                           transparent=true, opacity=0.5))
        offscreen.position = Vec3(100.0 + i, 0.0, z)
        add!(scene, offscreen)
    end
    instances = InstancedMesh(BoxGeometry(width=0.5, height=0.5, depth=0.5),
                              MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), wireframe=true,
                                                transparent=true, opacity=0.5), 4)
    for (i, x) in enumerate((-0.2, 100.0, 0.2, -100.0))
        set_instance_matrix!(instances, i, mat4_translation(x, 0.0, 0.5))
        set_instance_color!(instances, i, Color3(i / 4, 1.0 - i / 4, 0.5))
    end
    add!(scene, instances)
    expected = RenderTarget(32, 32); render!(expected, scene, camera)
    for tiles in (1, 2, 5)
        target = RenderTarget(32, 32)
        render_tiled!(target, scene, camera; tiles=tiles)
        @test target.color == expected.color
        @test isequal(target.depth, expected.depth)
    end
end

# Screen-space corners (x, y) from three.js r186 src/renderers/shaders/ShaderLib/
# sprite.glsl.js (vertex shader: scale the centred quad by the world column
# lengths, then rotate by SpriteMaterial.rotation, then project), evaluated in
# Node for a 64×48 target with the scene built below.
const _SPRITE_ORACLE = Dict(
    (true, true) => [(41.26108908103175, 33.1801883903417), (53.57932759358215, 24.75282800997375),
                     (50.305242508038745, 19.96711111004609), (37.987003995488344, 28.394471490414038)],
    (true, false) => [(35.849890748639005, 65.14236528945254), (110.10477284738369, 14.341867246628695),
                      (90.36844433250836, -14.50664415376656), (16.11356223376367, 36.29385388905729)],
    (false, true) => [(40.67740282368281, 32.60160095246773), (52.2192762163632, 24.705380527315477),
                      (49.151542506246784, 20.22128659652344), (37.6096691135664, 28.1175070216757)])

@testset "Sprite quads scale before rotating like three.js" begin
    W, H = 64, 48
    for ((perspective, attenuation), expected) in _SPRITE_ORACLE
        camera = perspective ?
            PerspectiveCamera(fov=deg2rad(50.0), aspect=W / H, near=0.1, far=100.0) :
            OrthographicCamera(left=-4.0, right=4.0, top=3.0, bottom=-3.0, near=0.1, far=100.0)
        camera.position = Vec3(1.0, 2.0, 6.0); camera.target = Vec3(0.0, 0.0, 0.0)
        parent = Group(); parent.position = Vec3(0.3, -0.2, 0.5)
        parent.rotation = Euler(0.2, -0.4, 0.3); parent.scale = Vec3(1.5, -0.7, 2.0)
        sprite = Sprite(SpriteMaterial(rotation=0.6, size_attenuation=attenuation);
                        center=Vec2(0.3, 0.8))
        sprite.position = Vec3(0.5, 0.4, -0.3); sprite.scale = Vec3(1.2, 0.8, 1.0)
        sprite.rotation = Euler(0.1, 0.2, 0.3)
        add!(parent, sprite)
        view = view_matrix(camera)
        corners = Diff3D._sprite_quad_corners(sprite, sprite.material, camera,
                                              compute_world_matrix(sprite), view)
        vp = projection_matrix(camera) * view
        for (corner, (x, y)) in zip(corners, expected)
            sx, sy = Diff3D._sprite_corner(corner, vp, W, H)[1:2]
            @test sx ≈ x atol=1e-9
            @test sy ≈ y atol=1e-9
        end
    end
end

function _audit3_tiled_wire_allocations(target, scene, camera, tiles, caches)
    render_tiled!(target, scene, camera; tiles=tiles, cache=caches)
    return @allocated render_tiled!(target, scene, camera; tiles=tiles, cache=caches)
end

@testset "Tiled instanced wireframes allocate a bounded amount per frame" begin
    scene = Scene()
    for (count, material) in ((40, MeshBasicMaterial(wireframe=true)),
                              (40, MeshLambertMaterial(wireframe=true)),
                              (30, MeshBasicMaterial(wireframe=true, transparent=true, opacity=0.5)))
        instances = InstancedMesh(BoxGeometry(width=0.2, height=0.2, depth=0.2), material, count)
        for index in 1:count
            set_instance_matrix!(instances, index,
                                 mat4_translation(0.1index - 2.0, 0.05index - 1.0, 0.1))
        end
        add!(scene, instances)
    end
    wire = Mesh(SphereGeometry(radius=0.5), MeshBasicMaterial(wireframe=true))
    add!(scene, wire)
    camera = PerspectiveCamera(); camera.position = Vec3(0.0, 0.0, 6.0)
    expected = RenderTarget(96, 64); render!(expected, scene, camera)
    for tiles in (1, 5)
        caches = [RenderCache() for _ in 1:min(tiles, Threads.nthreads())]
        target = RenderTarget(96, 64)
        render_tiled!(target, scene, camera; tiles=tiles, cache=caches)
        @test target.color == expected.color
        @test isequal(target.depth, expected.depth)
        if Base.JLOptions().opt_level > 0
            # Previously every instance dispatched on an abstract material and
            # allocated per instance and band (130 instances: > 40 KiB/frame).
            # The remaining bound covers Threads.@threads task setup.
            @test _audit3_tiled_wire_allocations(target, scene, camera, tiles, caches) <=
                  (Threads.nthreads() > 1 && tiles > 1 ? 8192 : 1024)
        end
    end
end
