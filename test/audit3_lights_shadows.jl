using Test, Diff3D, ForwardDiff

const _AUDIT3_IES_PROFILE = IESProfile([0.0, 30.0, 60.0, 90.0],
                                       [100.0, 80.0, 40.0, 0.0])

@testset "IES lookups carry derivatives of the vertical angle" begin
    profile = _AUDIT3_IES_PROFILE
    # Plain reals keep the documented Float64 result.
    @test ies_candela(profile, 45) === 60.0
    @test ies_candela(profile, 45.0f0) === 60.0
    @test ies_intensity(profile, 45.0) === 0.6
    # Interior slope on [30, 60]: (40 - 80) / 30 candela per degree.
    slope = (40.0 - 80.0) / 30.0
    @test ForwardDiff.derivative(t -> ies_candela(profile, t), 45.0) ≈ slope
    @test ForwardDiff.derivative(t -> ies_intensity(profile, t), 45.0) ≈ slope / 100
    @test reverse_gradient(v -> ies_intensity(profile, v[1]), [45.0])[1] ≈ slope / 100
    # Clamped endpoints keep the differentiable type with a zero derivative.
    @test ForwardDiff.derivative(t -> ies_intensity(profile, t), 120.0) == 0.0
    @test reverse_gradient(v -> ies_intensity(profile, v[1]), [-5.0])[1] == 0.0

    # The spot/point IES factor is part of the differentiable light response:
    # compare against a central finite difference of the Float64 primal.
    spot = SpotLight(position=Vec3(0.0, 2.0, 0.0), target=Vec3(0.0, 0.0, 0.0),
                     angle=1.2, ies_profile=profile)
    point = PointLight(position=Vec3(0.0, 2.0, 0.0), ies_profile=profile)
    for light in (spot, point)
        f(x) = light_contribution(light, Vec3(x, 0.0, 0.0))[2]
        h = 1e-6
        fd = (f(0.7 + h) - f(0.7 - h)) / (2h)
        @test ForwardDiff.derivative(f, 0.7) ≈ fd rtol = 1e-6
        @test reverse_gradient(v -> f(v[1]), [0.7])[1] ≈ fd rtol = 1e-6
        # On the luminaire axis acosd(1) has an infinite partial. The angle sits
        # on the profile's first knot, so the clamped branch (zero IES slope)
        # applies in both modes; ForwardDiff's partial-aware comparison used to
        # pick the interpolating branch and return NaN (x = 0) or -Inf (x = 1e-9,
        # where the cosine rounds to 1). f is even in x, so 0 is exact at x = 0.
        for x0 in (0.0, 1e-9)
            forward = ForwardDiff.derivative(f, x0)
            @test isfinite(forward)
            @test forward ≈ reverse_gradient(v -> f(v[1]), [x0])[1] atol = 1e-12
        end
        @test ForwardDiff.derivative(f, 0.0) == 0.0
    end
    # A dual angle exactly on a tabulated endpoint takes the clamped branch,
    # whatever the sign of its partial (as ADVar comparisons do).
    for partial in (1.0, -1.0, Inf)
        d = ForwardDiff.Dual{Nothing}(0.0, partial)
        @test ForwardDiff.partials(ies_candela(profile, d))[1] == 0.0
        @test ForwardDiff.value(ies_candela(profile, d)) == 100.0
    end
end

@testset "parse_ies reads TILT=INCLUDE tables by value count" begin
    # LM-63 lets the tilt angle and factor vectors wrap across lines. three.js
    # IESLoader `readTilt`/`readArray` (examples/jsm/loaders/IESLoader.js:223-259, called at :305)
    # reads them by count; node r186 parses this file into vertical angles
    # [0, 45, 90] with candela [100, 50, 10] (its texture holds the normalised
    # squares 1, 0.25, 0.01 at phi = 0, 45, 90).
    text = "IESNA:LM-63-2002\n[TEST] wrapped tilt\nTILT=INCLUDE\n1\n7\n" *
           "0 15 30 45\n60 75 90\n1.0 0.95 0.9 0.85\n0.8 0.75 0.7\n" *
           "1 1000 1 3 1 1 2 0 0 0\n1 1 100\n0 45 90\n0\n100 50 10\n"
    profile = parse_ies(text)
    @test profile.angles == [0.0, 45.0, 90.0]
    @test profile.candela == [100.0, 50.0, 10.0]
    # The same table on the conventional four lines parses identically.
    compact = "IESNA:LM-63-2002\nTILT=INCLUDE\n1\n2\n0 90\n1 0.5\n" *
              "1 1000 1 3 1 1 2 0 0 0\n1 1 100\n0 45 90\n0\n100 50 10\n"
    @test parse_ies(compact).candela == [100.0, 50.0, 10.0]
    # An empty tilt table (N = 0) has no angle or factor lines.
    empty_tilt = "IESNA:LM-63-2002\nTILT=INCLUDE\n1\n0\n" *
                 "1 1000 1 3 1 1 2 0 0 0\n1 1 100\n0 45 90\n0\n100 50 10\n"
    @test parse_ies(empty_tilt).angles == [0.0, 45.0, 90.0]
    @test_throws "tilt-angle count must be a non-negative integer" parse_ies(
        "TILT=INCLUDE\n1\n2.5\n0 90\n1 1\n1 1000 1 1 1 1 2 0 0 0\n1 1 1\n0\n0\n1\n")
    @test_throws "truncated TILT=INCLUDE data" parse_ies("TILT=INCLUDE\n1\n3\n0 45\n")
    # 2^62 angles would overflow the 2N skipped values.
    @test_throws "tilt-angle count must be a non-negative integer" parse_ies(
        "TILT=INCLUDE\n1\n4611686018427387904\n0 1\n")
    # The detailed docstring documents the public function itself.
    @test occursin("TILT=INCLUDE", string(@doc parse_ies))
end

# A light-space ray test for an axis-aligned square occluder in the plane x = x0
# (centre (x0, cy, cz), half-size h): the analytic truth for the shadow tests.
function _audit3_square_occludes(light::Vec3, p::Vec3, x0, cy, cz, h)
    (p.x - light.x) == 0 && return false
    t = (x0 - light.x) / (p.x - light.x)
    0 < t < 1 || return false
    y = light.y + t * (p.y - light.y)
    z = light.z + t * (p.z - light.z)
    return abs(y - cy) <= h && abs(z - cz) <= h
end

@testset "Spot shadow planes keep off-axis casters near the light" begin
    # The spot aims along +x while the scene's bounding sphere lies along the
    # 42 degree diagonal, so the nearest caster has view depth 1.0 but radial
    # distance 1.35. Fitting near = |centre - light| - radius (1.26) clipped
    # it away; the view-depth slab keeps it. three.js renders every caster in
    # the shadow camera frustum (WebGLShadowMap.js renderObject).
    scene = Scene()
    occluder = Mesh(PlaneGeometry(width=0.1, height=0.1), MeshStandardMaterial();
                    cast_shadow=true)
    occluder.position = Vec3(1.0, 0.9, 0.0)
    occluder.rotation = Euler(0.0, -π / 2, 0.0)
    add!(scene, occluder)
    receiver = Mesh(BoxGeometry(width=2.0, height=2.0, depth=2.0),
                    MeshStandardMaterial(); receive_shadow=true)
    receiver.position = Vec3(14.87, 13.38, 0.0)
    add!(scene, receiver)
    spot = SpotLight(position=Vec3(0.0, 0.0, 0.0), target=Vec3(10.0, 0.0, 0.0),
                     angle=π / 3, cast_shadow=true)
    add!(scene, spot)
    sm = compute_shadow_map(scene, spot; resolution=512)
    light = Vec3(0.0, 0.0, 0.0)
    for p in (Vec3(13.87, 12.483, 0.0), Vec3(13.87, 12.2, 0.3),
              Vec3(13.87, 13.9, 0.0), Vec3(13.87, 12.483, 0.9))
        expected = _audit3_square_occludes(light, p, 1.0, 0.9, 0.0, 0.05) ? 0.0 : 1.0
        @test shadow_visibility(sm, p) == expected
    end
    @test count(isfinite, sm.depth) > 0
end

# Ray/axis-aligned-box occlusion between a light and a receiver point (slab test).
function _audit3_ray_hits_box(o::Vec3, p::Vec3, bmin::Vec3, bmax::Vec3)
    d = p - o
    t0, t1 = 0.0, 1.0
    for (oa, da, lo, hi) in ((o.x, d.x, bmin.x, bmax.x), (o.y, d.y, bmin.y, bmax.y),
                             (o.z, d.z, bmin.z, bmax.z))
        if abs(da) < 1e-15
            (oa < lo || oa > hi) && return false
        else
            ta = (lo - oa) / da
            tb = (hi - oa) / da
            ta > tb && ((ta, tb) = (tb, ta))
            t0 = max(t0, ta)
            t1 = min(t1, tb)
            t0 > t1 && return false
        end
    end
    return t0 < 0.999
end

function _audit3_point_shadow_scene()
    scene = Scene()
    ground = Mesh(PlaneGeometry(width=12.0, height=12.0), MeshStandardMaterial();
                  receive_shadow=true)
    ground.rotation = Euler(-π / 2, 0.0, 0.0)
    add!(scene, ground)
    boxes = Tuple{Vec3{Float64},Vec3{Float64}}[]
    for (x, z, s, h) in ((2.0, 0.3, 0.8, 1.5), (-2.2, -0.5, 0.6, 2.5),
                         (0.4, 2.5, 1.0, 1.0), (-0.7, -2.4, 0.5, 3.0))
        box = Mesh(BoxGeometry(width=s, height=h, depth=s), MeshStandardMaterial();
                   cast_shadow=true)
        box.position = Vec3(x, h / 2, z)
        add!(scene, box)
        push!(boxes, (Vec3(x - s / 2, 0.0, z - s / 2), Vec3(x + s / 2, h, z + s / 2)))
    end
    return scene, boxes
end

@testset "Point-light shadows cover every direction (cube map)" begin
    # three.js renders point-light shadows into a six-face cube
    # (WebGLShadowMap.js:246-249 WebGLCubeRenderTarget, faces from
    # `_cubeDirections`/`_cubeUps` at :21-29). A single 90-degree frustum aimed
    # at the scene centre left casters on the other sides unshadowed: with the
    # light at the centre, every ray-cast shadowed ground point read as lit.
    scene, boxes = _audit3_point_shadow_scene()
    for light_position in (Vec3(0.0, 1.2, 0.0), Vec3(1.0, 0.6, 1.0))
        light = PointLight(position=light_position, cast_shadow=true)
        sm = compute_shadow_map(scene, light; resolution=512)
        @test size(sm.depth) == (512, 6 * 512)
        shadowed = 0
        mismatches = 0
        total = 0
        for i in 0:59, j in 0:59
            p = Vec3(-5.95 + 0.2 * i, 0.0, -5.95 + 0.2 * j)
            any(b -> b[1].x <= p.x <= b[2].x && b[1].z <= p.z <= b[2].z, boxes) &&
                continue
            truth = any(b -> _audit3_ray_hits_box(light_position, p, b[1], b[2]),
                        boxes) ? 0.0 : 1.0
            total += 1
            shadowed += truth == 0.0
            mismatches += shadow_visibility(sm, p) != truth
        end
        @test shadowed > total ÷ 10
        # Only texels straddling a shadow edge may disagree with the ray cast.
        @test mismatches <= total ÷ 200
    end

    # The renderer's shadow query (render!(...; shadows=true)) builds the same
    # cube, sizing reused cache scratch to res × 6res for a point light.
    point = PointLight(position=Vec3(0.0, 1.2, 0.0), cast_shadow=true)
    directional = DirectionalLight(position=Vec3(1.0, 4.0, 2.0), cast_shadow=true)
    meshes = collect_meshes(scene)
    maps = IdDict{Diff3D.AbstractLight,ShadowMap}()
    depths = Matrix{Float64}[]
    for lights in ([directional], [point], [point])
        query = Diff3D._build_shadow_query_from_drawables!(
            maps, depths, lights, meshes, InstancedMesh[]; resolution=64)
        light = only(lights)
        @test size(only(depths)) == (64, light isa PointLight ? 6 * 64 : 64)
        @test query(light, Vec3(5.5, 0.0, 5.5)) ==
              shadow_visibility(compute_shadow_map(scene, light; resolution=64),
                                Vec3(5.5, 0.0, 5.5))
    end
    query = Diff3D._build_shadow_query_from_drawables!(
        maps, depths, [point], meshes, InstancedMesh[]; resolution=128)
    # Ground behind the +x and -x boxes (opposite cube faces) is shadowed.
    for p in (Vec3(3.5, 0.0, 0.3), Vec3(-3.5, 0.0, -0.6))
        @test _audit3_ray_hits_box(point.position, p, boxes[p.x > 0 ? 1 : 2]...)
        @test query(point, p) == 0.0
    end
    @test query(point, Vec3(0.0, 0.0, -4.5)) == 1.0

    # The WebGL export draws all six faces in the browser (one atlas texture per light).
    json = Diff3D._web_shadow_json(scene, point)
    @test occursin("\"type\":\"pointDynamic\",\"size\":64,", json)
end

@testset "Cube faces fit near planes to the frustum, not only the depth slab" begin
    # A point light outside a small scene. Its -X and -Y faces see the scene
    # off-axis, so the slab bound zc - radius alone put their near planes at
    # 0.1 and 0.03 (the old single frustum used d - radius = 0.85). The fixed
    # NDC bias then spans a large world distance and shadows detach from their
    # casters: 131 of 38024 ground samples disagreed with a ray cast, 114 of
    # them falsely lit. Every scene point inside a 90-degree face also has view
    # depth >= (d - radius) / sqrt(3) (the corner-ray bound), which restores
    # the precision without clipping.
    scene = Scene()
    ground = Mesh(PlaneGeometry(width=4.0, height=4.0), MeshStandardMaterial();
                  receive_shadow=true)
    ground.rotation = Euler(-π / 2, 0.0, 0.0)
    add!(scene, ground)
    boxes = Tuple{Vec3{Float64},Vec3{Float64}}[]
    for (x, z, s, h) in ((0.8, 0.3, 0.5, 1.0), (-0.9, -0.5, 0.4, 1.5), (0.2, -1.0, 0.6, 0.6))
        box = Mesh(BoxGeometry(width=s, height=h, depth=s), MeshStandardMaterial();
                   cast_shadow=true)
        box.position = Vec3(x, h / 2, z)
        add!(scene, box)
        push!(boxes, (Vec3(x - s / 2, 0.0, z - s / 2), Vec3(x + s / 2, h, z + s / 2)))
    end
    light_position = Vec3(3.0, 3.0, 0.0)
    sm = compute_shadow_map(scene, PointLight(position=light_position, cast_shadow=true);
                            resolution=1024)
    total = 0
    mismatches = 0
    for i in 0:199, j in 0:199
        p = Vec3(-1.99 + 0.02 * i, 0.0, -1.99 + 0.02 * j)
        any(b -> b[1].x <= p.x <= b[2].x && b[1].z <= p.z <= b[2].z, boxes) && continue
        truth = any(b -> _audit3_ray_hits_box(light_position, p, b[1], b[2]), boxes) ?
                0.0 : 1.0
        total += 1
        mismatches += shadow_visibility(sm, p) != truth
    end
    @test total == 38024
    @test mismatches <= total ÷ 500
end

function _audit3_shadow_query_allocations(maps, depths, light, meshes)
    Diff3D._build_shadow_query_from_drawables!(maps, depths, [light], meshes,
                                               InstancedMesh[]; resolution=32)
    return @allocated Diff3D._build_shadow_query_from_drawables!(
        maps, depths, [light], meshes, InstancedMesh[]; resolution=32)
end

function _audit3_lookup_allocations(query, light, points)
    total = 0.0
    for p in points
        total += query(light, p)
    end
    return @allocated for p in points
        total += query(light, p)
    end
end

@testset "Cached shadow passes keep per-mesh allocation independent of cube faces" begin
    scene = Scene()
    for index in 1:12
        sphere = Mesh(SphereGeometry(radius=0.4, width_segments=8, height_segments=6),
                      MeshStandardMaterial(); cast_shadow=true)
        sphere.position = Vec3(3cos(index), 0.5, 3sin(index))
        add!(scene, sphere)
    end
    meshes = collect_meshes(scene)
    point = PointLight(position=Vec3(0.0, 1.0, 0.0), cast_shadow=true)
    directional = DirectionalLight(position=Vec3(1.0, 4.0, 2.0), cast_shadow=true)
    points = [Vec3(0.3i - 3.0, 0.2, 0.1i - 1.0) for i in 1:50]
    if Base.JLOptions().opt_level > 0
        maps = IdDict{Diff3D.AbstractLight,ShadowMap}()
        depths = Matrix{Float64}[]
        directional_bytes = _audit3_shadow_query_allocations(maps, depths, directional,
                                                             meshes)
        point_bytes = _audit3_shadow_query_allocations(maps, depths, point, meshes)
        # One dynamic dispatch per mesh renders all six faces; dispatching once
        # per mesh and face allocated about 6x the directional pass (>35 kB).
        @test point_bytes <= directional_bytes + 2048
        @test directional_bytes <= 8192
        query = Diff3D._build_shadow_query_from_drawables!(maps, depths, [point], meshes,
                                                           InstancedMesh[]; resolution=32)
        @test _audit3_lookup_allocations(query, point, points) == 0
    end
end

@testset "parse_ies rejects unsatisfiable angle counts with ArgumentError" begin
    # A header count can never exceed the number of values the text holds; the
    # old parser raised InexactError (count 2^63) or tried to allocate the
    # buffer and died with OutOfMemoryError (count 1e15).
    header(n) = "TILT=NONE\n1 1000 1 $n 1 1 2 0 0 0\n1 1 1\n0\n0\n1\n"
    @test_throws "vertical-angle count must be a positive integer" parse_ies(
        header("9223372036854775807"))
    @test_throws "vertical-angle count 1000000000000000 exceeds the photometric data" parse_ies(
        header("1e15"))
    @test_throws "horizontal-angle count 100000 exceeds the photometric data" parse_ies(
        "TILT=NONE\n1 1000 1 1 1e5 1 2 0 0 0\n1 1 1\n0\n0\n1\n")
    @test parse_ies(header("1")).candela == [1.0]
    # The documented error type, not only the message.
    for n in ("9223372036854775807", "1e15", "NaN", "Inf", "-3", "2.5")
        @test_throws ArgumentError parse_ies(header(n))
    end
    @test_throws ArgumentError parse_ies("TILT=INCLUDE\n1\n4611686018427387904\n0 1\n")
end

@testset "Shadow-map docstrings document the public names" begin
    # The detailed compute_shadow_map docstring was attached to an internal
    # helper, so `?compute_shadow_map` showed only the generic one-liner.
    @test occursin("pcf_radius", string(@doc compute_shadow_map))
    @test occursin("PointLight", string(@doc compute_shadow_map))
    @test occursin("cube map", string(@doc ShadowMap))
end
