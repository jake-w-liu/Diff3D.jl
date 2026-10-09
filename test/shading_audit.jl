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

@testset "MeshNormalMaterial encodes view-space normals" begin
    geo = PlaneGeometry(width=2.0, height=2.0)
    function center_color(cam_pos)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, Mesh(geo, MeshNormalMaterial(side=:double)))
        cam = PerspectiveCamera(fov=π / 4, aspect=1.0, near=0.1, far=100.0)
        cam.position = cam_pos
        cam.target = Vec3()
        colors = Vector{Float64}[]
        for shading in (:flat, :smooth)
            rt = RenderTarget(16, 16)
            render!(rt, scene, cam; shading=shading)
            push!(colors, rt.color[8, 8, :])
        end
        return colors
    end
    # Facing the camera, the view-space normal is +Z regardless of the orbit.
    for cam_pos in (Vec3(0.0, 0.0, 3.0), Vec3(2.0, 0.0, 2.0), Vec3(0.0, 2.0, 2.5))
        for c in center_color(cam_pos)
            @test c[3] > 0.6
        end
    end
    head_on = center_color(Vec3(0.0, 0.0, 3.0))
    @test head_on[1] ≈ [0.5, 0.5, 1.0] atol=1e-9
    @test head_on[2] ≈ [0.5, 0.5, 1.0] atol=1e-9
    # Orbiting to 45 degrees tilts the view-space normal toward screen left.
    for c in center_color(Vec3(2.0, 0.0, 2.0))
        @test c[1] ≈ 0.5 - 0.5 * sqrt(0.5) atol=1e-9
    end
    view = mat4_rotation_y(-π / 2)
    c = shade_face(Vec3(0.0, 0.0, 1.0), Vec3(0.0, 0.0, 1.0), Vec3(), MeshNormalMaterial(),
                   AbstractLight[]; camera_view=view)
    @test [c.r, c.g, c.b] ≈ [0.0, 0.5, 0.5] atol=1e-12
    @test shade_face(Vec3(0.0, 0.0, 1.0), Vec3(0.0, 0.0, 1.0), Vec3(), MeshNormalMaterial(),
                     AbstractLight[]) == Color3(0.5, 0.5, 1.0)
end

@testset "Light power follows three.js lumen conversions" begin
    point = PointLight(intensity=2.0)
    @test point.power ≈ 8π
    point.power = 100.0
    @test point.intensity ≈ 100 / (4π)
    spot = SpotLight(intensity=3.0)
    @test spot.power ≈ 3π
    spot.power = 10.0
    @test spot.intensity ≈ 10 / π
    rect = RectAreaLight(intensity=2.0, width=2.0, height=3.0)
    @test rect.power ≈ 2.0 * 6.0 * π
    rect.power = 6π
    @test rect.intensity ≈ 1.0
    for light in (point, spot, rect)
        @test :power in propertynames(light)
        @test hasproperty(light, :power)
        @test_throws ArgumentError (light.power = NaN)
        @test_throws ArgumentError (light.power = Inf)
    end
    zero_area = RectAreaLight(width=0.0, height=1.0)
    @test zero_area.power == 0.0
    @test_throws ArgumentError (zero_area.power = 1.0)
    @test zero_area.intensity == 1.0
    @test !hasproperty(DirectionalLight(), :power)
    @test_throws MethodError (point.ies_profile = 42)
    point.intensity = 1.5
    @test point.intensity == 1.5
end

@testset "Diffuse responses use three.js BRDF_Lambert (1/pi)" begin
    n = Vec3(0.0, 0.0, 1.0)
    v = Vec3(0.0, 0.0, 1.0)
    dir = DirectionalLight(position=Vec3(0.0, 0.0, 1.0), intensity=2.0)
    amb = AmbientLight(intensity=0.5)
    hemi = HemisphereLight(color=Color3(1.0, 1.0, 1.0), ground_color=Color3(0.0, 0.0, 0.0),
                           position=Vec3(0.0, 0.0, 1.0))
    rgb(c) = [c.r, c.g, c.b]
    albedo = Color3(0.4, 0.6, 0.8)
    for m in (MeshLambertMaterial(color=albedo), MeshToonMaterial(color=albedo),
              MeshPhongMaterial(color=albedo, specular=Color3(0.0, 0.0, 0.0)))
        # Phong keeps a tiny Schlick f90 highlight even with a black specular colour.
        atol = m isa MeshPhongMaterial ? 1e-3 : 1e-12
        @test rgb(shade_face(n, v, Vec3(), m, [dir])) ≈ rgb(albedo) .* (2 / π) atol=atol
        @test rgb(shade_face(n, v, Vec3(), m, [amb])) ≈ rgb(albedo) .* (0.5 / π) atol=1e-12
        @test rgb(shade_face(n, v, Vec3(), m, [hemi])) ≈ rgb(albedo) ./ π atol=1e-12
    end
    # Lambert and a rough dielectric Standard surface share the same radiometric
    # units (they previously differed by a factor of π).
    lambert = shade_face(n, v, Vec3(), MeshLambertMaterial(color=albedo), [dir])
    standard = shade_face(n, v, Vec3(), MeshStandardMaterial(color=albedo, roughness=1.0), [dir])
    @test 0.9 < standard.r / lambert.r < 1.1
    # A vertex-coloured face follows the same 1/π scaling.
    geo = PlaneGeometry(width=1.0, height=1.0)
    set_attribute!(geo, :color, repeat([0.5, 1.0, 1.0], geo.n_vertices), 3)
    colors = shade_mesh_faces(geo, Mat4(), MeshLambertMaterial(vertex_colors=true),
                              AbstractLight[amb], Vec3(0.0, 0.0, 5.0))
    @test all(c -> isapprox(c.r, 0.5 * 0.5 / π; atol=1e-12), colors)
end

@testset "Phong specular follows three.js BRDF_BlinnPhong" begin
    n = Vec3(0.0, 0.0, 1.0)
    l = normalize(Vec3(0.3, 0.0, 1.0))
    v = normalize(Vec3(-0.2, 0.1, 1.0))
    spec = Color3(0.2, 0.3, 0.4)
    shininess = 40.0
    c = shade_phong(n, l, v, Color3(1.0, 1.0, 1.0), 1.5, Color3(0.0, 0.0, 0.0), spec, shininess)
    h = normalize(l + v)
    dotnl = dot(n, l); dotnh = dot(n, h); dotvh = dot(v, h)
    fresnel = exp2((-5.55473 * dotvh - 6.98316) * dotvh)
    expected(f0) = 1.5 * dotnl * (f0 * (1 - fresnel) + fresnel) * 0.25 *
                   (shininess / 2 + 1) / π * dotnh^shininess
    @test [c.r, c.g, c.b] ≈ expected.([spec.r, spec.g, spec.b]) rtol=1e-12
    # Specular rolls off with N·L instead of switching off at the terminator.
    grazing = normalize(Vec3(1.0, 0.0, 1e-3))
    g = shade_phong(n, grazing, grazing, Color3(1.0, 1.0, 1.0), 1.0,
                    Color3(0.0, 0.0, 0.0), Color3(1.0, 1.0, 1.0), 1.0)
    @test 0.0 < g.r < 1e-3
end
