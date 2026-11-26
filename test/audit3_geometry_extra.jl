using Test, Diff3D

# Regression tests for the geometry-extra audit (src/geometries_extra.jl and
# src/csg.jl). Expected values come from three.js r186 run under node, or from
# the derivation cited next to each expectation.

function _audit3_segments(geometry)
    p = geometry.positions
    segments = NTuple{2,NTuple{3,Float64}}[]
    for i in 1:6:length(p)
        a = (p[i], p[i + 1], p[i + 2])
        b = (p[i + 3], p[i + 4], p[i + 5])
        push!(segments, a <= b ? (a, b) : (b, a))
    end
    return sort!(segments)
end

function _audit3_winding_matches_normals(geometry)
    for face in 1:geometry.n_faces
        i1, i2, i3 = geometry.indices[3face - 2], geometry.indices[3face - 1],
                     geometry.indices[3face]
        a = get_vertex(geometry, i1)
        b = get_vertex(geometry, i2)
        c = get_vertex(geometry, i3)
        winding = cross(b - a, c - a)
        for index in (i1, i2, i3)
            stored = Vec3(geometry.normals[3index - 2], geometry.normals[3index - 1],
                          geometry.normals[3index])
            dot(winding, stored) > 0 || return false
        end
    end
    return true
end

@testset "edges_geometry skips triangles with welded corners" begin
    # Unit quad split along its diagonal plus a zero-area triangle (1, 3, 3)
    # lying on that diagonal. three.js EdgesGeometry.js:96-100 skips triangles
    # whose corner hashes coincide, so node prints only the four boundary
    # edges: [0,0,0,1,0,0, 1,0,0,1,1,0, 1,1,0,0,1,0, 0,1,0,0,0,0].
    quad = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0],
                          Float64[], Float64[], [1, 2, 3, 1, 3, 4, 1, 3, 3], 4, 3)
    edges = edges_geometry(quad; threshold_angle=deg2rad(20))
    @test _audit3_segments(edges) == [
        ((0.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
        ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0)),
        ((0.0, 1.0, 0.0), (1.0, 1.0, 0.0)),
        ((1.0, 0.0, 0.0), (1.0, 1.0, 0.0)),
    ]

    # A lone triangle with two coincident corners contributes nothing; the
    # well-formed triangle keeps its three boundary edges (node prints 3).
    lone = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                           1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
                          Float64[], Float64[], collect(1:6), 6, 2)
    @test edges_geometry(lone; threshold_angle=deg2rad(20)).n_vertices == 6
end

@testset "edges_geometry keeps edges at exactly the threshold" begin
    # three.js EdgesGeometry.js:120 emits an edge when
    # dot(n1, n2) <= cos(threshold). With a zero threshold every shared edge of
    # coplanar faces qualifies: node prints 18 segments for BoxGeometry(1,1,1)
    # with thresholdAngle 0 (12 cube edges + 6 face diagonals) and 12 at 90°.
    @test edges_geometry(BoxGeometry(); threshold_angle=0.0).n_vertices ÷ 2 == 18
    @test edges_geometry(BoxGeometry(); threshold_angle=π / 2).n_vertices ÷ 2 == 12
    @test edges_geometry(BoxGeometry()).n_vertices ÷ 2 == 12
end

@testset "ExtrudeGeometry wall normals follow the winding for negative depth" begin
    # three.js ExtrudeGeometry.js calls computeVertexNormals, so every stored
    # normal agrees with its triangle's winding. With depth = -1 node prints
    # the y = 0 wall of the unit square with normal (0, 1, 0).
    square = [Vec2(0.0, 0.0), Vec2(1.0, 0.0), Vec2(1.0, 1.0), Vec2(0.0, 1.0)]
    for depth in (-1.0, 1.0), steps in (1, 3)
        geometry = ExtrudeGeometry(square; depth=depth, steps=steps)
        @test _audit3_winding_matches_normals(geometry)
    end
    geometry = ExtrudeGeometry(square; depth=-1.0)
    for i in 1:geometry.n_vertices
        y = geometry.positions[3i - 1]
        n = geometry.normals[3i - 2:3i]
        abs(n[3]) == 1.0 && continue
        if y == 0.0 && n[1] == 0.0
            @test n == [0.0, 1.0, 0.0]
        end
    end
end

@testset "CatmullRomCurve extrapolates open-curve end neighbours" begin
    # three.js CatmullRomCurve3.js:203-224 reflects points[1] about points[0]
    # (and points[l-2] about points[l-1]) for an open curve's end segments.
    # Values printed by node for new CatmullRomCurve3(points, false, type, 0.5).
    points = [Vec3(0.0, 0.0, 0.0), Vec3(1.0, 2.0, 0.0), Vec3(3.0, 1.0, 1.0),
              Vec3(4.0, -1.0, 2.0), Vec3(6.0, 0.0, 0.0)]
    expected = Dict(
        :centripetal => ((0.2719609075827775, 0.6909751290423843, -0.029410662775365852),
                         (5.370435501248603, -0.40634676865140107, 0.7028161141719588)),
        :chordal => ((0.2751738966086791, 0.6875760797662971, -0.02744565730978779),
                     (5.373112488283692, -0.41963570759068025, 0.7118410731023294)),
        :catmullrom => ((0.2685, 0.6945, -0.0315),
                        (5.368500000000001, -0.39449999999999963, 0.6944999999999995)),
    )
    for (curve_type, (first_value, last_value)) in expected
        curve = CatmullRomCurve(points; curve_type=curve_type)
        for (t, value) in ((0.075, first_value), (0.925, last_value))
            p = catmull_rom_point(curve, t)
            @test p.x ≈ value[1] atol=1e-12
            @test p.y ≈ value[2] atol=1e-12
            @test p.z ≈ value[3] atol=1e-12
        end
        @test catmull_rom_point(curve, 0.0) == points[1]
        @test catmull_rom_point(curve, 1.0) == points[end]
    end

    # Two points, tension 1.3: node prints 0.6463999999999996 per coordinate
    # at t = 0.8 (both neighbours reflected).
    two = CatmullRomCurve([Vec3(0.0, 0.0, 0.0), Vec3(1.0, 1.0, 1.0)];
                          curve_type=:catmullrom, tension=1.3)
    p = catmull_rom_point(two, 0.8)
    @test all(c -> isapprox(c, 0.6463999999999996; atol=1e-12), (p.x, p.y, p.z))

    # Reflected neighbours of huge points overflow, but the curve is still the
    # finite chord between them (exact: -largest / 2 at the quarter point).
    largest = floatmax(Float64)
    for curve_type in (:catmullrom, :centripetal, :chordal)
        chord = CatmullRomCurve([Vec3(-largest, 0.0, 0.0), Vec3(largest, 0.0, 0.0)];
                                curve_type=curve_type)
        @test catmull_rom_point(chord, 0.25).x ≈ -largest / 2 rtol=1e-12
        @test catmull_rom_point(chord, 0.0).x == -largest
        @test catmull_rom_point(chord, 1.0).x == largest
    end
    uniform_chord = CatmullRomCurve([Vec3(-largest, 0.0, 0.0), Vec3(largest, 0.0, 0.0)];
                                    curve_type=:catmullrom)
    @test catmull_rom_point(uniform_chord, 0.25) == Vec3(-largest / 2, 0.0, 0.0)
    @test catmull_rom_point(uniform_chord, 0.75) == Vec3(largest / 2, 0.0, 0.0)
end

@testset "wireframe_geometry deduplicates edges by position" begin
    # three.js WireframeGeometry.js isUniqueEdge hashes each edge by its end
    # positions, so faces with separate vertices share an edge line. node:
    # BoxGeometry(1,1,1) -> 18 segments; IcosahedronGeometry(1,1) (non-indexed)
    # -> 120; BoxGeometry(2,3,4,2,2,2) -> 72.
    @test wireframe_geometry(BoxGeometry()).n_vertices ÷ 2 == 18
    @test wireframe_geometry(IcosahedronGeometry(radius=1.0, detail=1)).n_vertices ÷ 2 == 120
    @test wireframe_geometry(BoxGeometry(width=2.0, height=3.0, depth=4.0, width_segments=2,
                                         height_segments=2, depth_segments=2)).n_vertices ÷ 2 == 72
    segments = _audit3_segments(wireframe_geometry(BoxGeometry()))
    @test allunique(segments)
    # Signed zeros hash alike in three.js (`${-0}` is "0").
    signed = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0,
                             -0.0, -0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -0.0],
                            Float64[], Float64[], collect(1:6), 6, 2)
    @test wireframe_geometry(signed).n_vertices ÷ 2 == 3
end

function _audit3_fibonacci_sphere(n)
    golden = π * (3 - sqrt(5))
    return [let y = 1 - 2 * (i + 0.5) / n, r = sqrt(1 - y * y), t = golden * i
                Vec3(r * cos(t), y, r * sin(t))
            end for i in 0:(n - 1)]
end

function _audit3_volume_area(geometry)
    volume = 0.0
    area = 0.0
    for face in 1:geometry.n_faces
        a = get_vertex(geometry, geometry.indices[3face - 2])
        b = get_vertex(geometry, geometry.indices[3face - 1])
        c = get_vertex(geometry, geometry.indices[3face])
        volume += dot(a, cross(b, c)) / 6
        area += norm(cross(b - a, c - a)) / 2
    end
    return volume, area
end

@testset "ConvexGeometry wraps large hulls and matches the reference search" begin
    # The gift-wrapping search must report exactly the faces (coplanar sets,
    # outward normals, order) of the exhaustive support-plane enumeration.
    inputs = Vector{Vector{Vec3{Float64}}}()
    push!(inputs, _audit3_fibonacci_sphere(60))
    push!(inputs, [Vec3(Float64(x), Float64(y), Float64(z)) for x in 0:3, y in 0:2, z in 0:1][:])
    push!(inputs, [Vec3(cos(2π * k / 40), sin(2π * k / 40), Float64(k % 3)) for k in 1:40])
    sphere = SphereGeometry(radius=1.0, width_segments=8, height_segments=6)
    push!(inputs, [get_vertex(sphere, i) for i in 1:sphere.n_vertices])
    for points in inputs
        _, normalized, eps = Diff3D._convex_clean_points(points)
        wrapped = Diff3D._convex_wrapped_support_faces(normalized, eps)
        @test wrapped !== nothing
        reference = Diff3D._convex_support_faces(normalized, eps)
        @test length(wrapped) == length(reference)
        @test all(w[1] == r[1] && w[2] === r[2] for (w, r) in zip(wrapped, reference))
    end

    # node: three.js ConvexGeometry of the same 1000-point Fibonacci sphere
    # gives 1996 triangles, volume 4.164674768977892 and area
    # 12.527317847976624 (Float32 positions).
    hull = ConvexGeometry(_audit3_fibonacci_sphere(1000))
    @test hull.n_faces == 1996
    volume, area = _audit3_volume_area(hull)
    @test volume ≈ 4.164674768977892 rtol=1e-7
    @test area ≈ 12.527317847976624 rtol=1e-7
end
