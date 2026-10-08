using Diff3D, Test

@testset "Punctual distance attenuation follows three.js getDistanceAttenuation" begin
    attenuation(d, cutoff, decay) =
        1 / max(d^decay, 0.01) * clamp(1 - (d / cutoff)^4, 0.0, 1.0)^2
    point = PointLight(distance=10.0, decay=2.0)
    _, li, _ = light_contribution(point, Vec3(5.0, 0.0, 0.0))
    @test li ≈ attenuation(5.0, 10.0, 2.0) rtol=1e-12
    @test li ≈ 0.9375^2 / 25 rtol=1e-12
    _, li, _ = light_contribution(point, Vec3(12.0, 0.0, 0.0))
    @test li == 0.0
    # The inverse-power falloff is capped at 100x near the emitter.
    _, li, _ = light_contribution(PointLight(decay=2.0), Vec3(0.01, 0.0, 0.0))
    @test li ≈ 100.0 rtol=1e-12
    _, li, _ = light_contribution(PointLight(decay=2.0), Vec3(3.0, 0.0, 0.0))
    @test li ≈ 1 / 9 rtol=1e-12

    spot = SpotLight(intensity=1.0, distance=5.0, decay=2.0, position=Vec3(0.0, 0.0, 0.0),
                     target=Vec3(0.0, 0.0, -1.0))
    _, li, _ = light_contribution(spot, Vec3(0.0, 0.0, -3.0))
    @test li ≈ attenuation(3.0, 5.0, 2.0) rtol=1e-12
end

@testset "Spot penumbra uses three.js smoothstep" begin
    angle, penumbra = 0.5, 0.5
    spot = SpotLight(angle=angle, penumbra=penumbra, decay=0.0,
                     position=Vec3(0.0, 0.0, 0.0), target=Vec3(0.0, 0.0, -1.0))
    cos_outer = cos(angle)
    cos_inner = cos(angle * (1 - penumbra))
    for t in (0.0, 0.25, 0.5, 0.75, 1.0)
        c = cos_outer + t * (cos_inner - cos_outer)
        s = sqrt(1 - c^2)
        _, li, _ = light_contribution(spot, Vec3(s, 0.0, -c))
        @test li ≈ t * t * (3 - 2t) atol=1e-9
    end
end

@testset "HemisphereLight aims along its world position" begin
    hemi = HemisphereLight(color=Color3(1.0, 1.0, 1.0), ground_color=Color3(0.0, 0.0, 0.0))
    @test hemi.position == Vec3(0.0, 1.0, 0.0)
    @test Diff3D._fill_color(Vec3(0.0, 1.0, 0.0), hemi) == Color3(1.0, 1.0, 1.0)
    hemi.position = Vec3(0.0, -2.0, 0.0)
    @test Diff3D._fill_color(Vec3(0.0, -1.0, 0.0), hemi) == Color3(1.0, 1.0, 1.0)
    @test Diff3D._fill_color(Vec3(0.0, 1.0, 0.0), hemi) == Color3(0.0, 0.0, 0.0)
    # Own rotation does not move the light's world position.
    hemi.position = Vec3(1.0, 0.0, 0.0)
    hemi.rotation = Euler(0.0, 0.0, pi / 2)
    @test Diff3D._fill_color(Vec3(1.0, 0.0, 0.0), hemi) == Color3(1.0, 1.0, 1.0)
    # A light at the origin has no direction: both hemispheres weigh 0.5.
    origin = HemisphereLight(position=Vec3(), color=Color3(1.0, 1.0, 1.0),
                             ground_color=Color3(0.0, 0.0, 0.0))
    @test Diff3D._fill_color(Vec3(0.0, 1.0, 0.0), origin) == Color3(0.5, 0.5, 0.5)
    parent = Group(); parent.position = Vec3(0.0, -5.0, 0.0)
    child = HemisphereLight(color=Color3(1.0, 1.0, 1.0), ground_color=Color3(0.0, 0.0, 0.0))
    add!(parent, child)
    @test Diff3D._fill_color(Vec3(0.0, -1.0, 0.0), child) == Color3(1.0, 1.0, 1.0)
    @test_throws ArgumentError HemisphereLight(position=Vec3(NaN, 0.0, 0.0))
end

@testset "MeshToonMaterial honours vertex colors" begin
    geo = PlaneGeometry(width=2.0, height=2.0)
    set_attribute!(geo, :color, repeat([1.0, 0.0, 0.0], geo.n_vertices), 3)
    light = DirectionalLight(position=Vec3(0.0, 0.0, 1.0), intensity=1.0)
    tinted = shade_mesh_faces(geo, Mat4(), MeshToonMaterial(vertex_colors=true),
                              AbstractLight[light], Vec3(0.0, 0.0, 5.0))
    plain = shade_mesh_faces(geo, Mat4(), MeshToonMaterial(),
                             AbstractLight[light], Vec3(0.0, 0.0, 5.0))
    @test all(c -> c.r > 0.0 && c.g == 0.0 && c.b == 0.0, tinted)
    @test all(c -> c.g > 0.0, plain)
    @test [c.r for c in tinted] == [c.r for c in plain]
    @test MeshToonMaterial().vertex_colors == false
    scene = Scene(background=Color3(0.0, 0.0, 0.0))
    add!(scene, light)
    add!(scene, Mesh(geo, MeshToonMaterial(vertex_colors=true)))
    cam = PerspectiveCamera(fov=π / 4, aspect=1.0, near=0.1, far=100.0)
    cam.position = Vec3(0.0, 0.0, 3.0)
    for shading in (:flat, :smooth)
        rt = RenderTarget(16, 16)
        render!(rt, scene, cam; shading=shading)
        @test rt.color[8, 8, 1] > 0.0 && rt.color[8, 8, 2] == 0.0 &&
              rt.color[8, 8, 3] == 0.0
    end
end
