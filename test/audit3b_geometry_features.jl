using Test, Diff3D

# Round-2 geometry features and fixes. Expected values are printed by three.js
# r186 under node (BufferGeometry attributes built as Float64Array so the
# oracle keeps double precision), unless a comment gives a derivation.

_segments(g) = [Tuple(g.positions[6k-5:6k]) for k in 1:(length(g.positions) ÷ 6)]
_approx(a, b; atol=1e-12) = length(a) == length(b) && all(isapprox.(a, b; atol=atol))
_xyz(p::Vec2) = [p.x, p.y]
_xyz(p::Vec3) = [p.x, p.y, p.z]

# Four vertices with hand-set normals and tangents, used by the transform tests.
function _audit3b_quad()
    g = BufferGeometry([0.0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 3],
                       [0.0, 0, 1, 1, 1, 0, 0, 0, 0, 0.6, 0, 0.8],
                       Float64[], [1, 2, 3, 1, 3, 4], 4, 2)
    set_attribute!(g, :tangent, [1.0, 0, 0, 1, 0, 1, 0, -1, 0, 0, 0, 1, 0.6, 0.8, 0, 1], 4)
    return g
end

@testset "edges_geometry welds to four decimals like three.js" begin
    # EdgesGeometry.js:33-34, 79-81: corners hash as Math.round(x * 1e4), so a
    # smooth capsule has no feature edge at 90 degrees. node prints 136, 104,
    # 6 and 0 edges for CapsuleGeometry(1, 1, 4, 8) at 1, 20, 45 and 90 degrees;
    # 45 degrees is the exact dihedral of some cap faces, so the normals must be
    # formed as Triangle.js:66-81 getNormal does to agree there.
    capsule = CapsuleGeometry(radius=1.0, length=1.0, cap_segments=4, radial_segments=8)
    for (degrees, expected) in ((1, 136), (20, 104), (45, 6), (90, 0))
        @test edges_geometry(capsule; threshold_angle=deg2rad(degrees)).n_vertices ÷ 2 == expected
    end
    # The default threshold is three.js's 1 degree (EdgesGeometry.js:24).
    @test edges_geometry(capsule).n_vertices ÷ 2 == 136
    @test Diff3D._edges_hash_component(0.00004999) == 0.0
    @test Diff3D._edges_hash_component(0.00005) == 1.0    # Math.round(0.5) == 1
    @test Diff3D._edges_hash_component(-0.00005) === 0.0  # Math.round(-0.5) == -0
    @test Diff3D._edges_hash_component(-0.00015) == -1.0  # Math.round(-1.5) == -1
end

@testset "edges_geometry emits segments in three.js order and direction" begin
    # EdgesGeometry.js:103-152: matched sharp edges in the later triangle's
    # direction, then unmatched edges in first-recorded order. node prints the
    # six boundary edges of PlaneGeometry(2, 1, 2, 1) in this order.
    plane = edges_geometry(PlaneGeometry(width=2.0, height=1.0, width_segments=2))
    @test plane.positions == [-1.0, 0.5, 0.0, -1.0, -0.5, 0.0, 0.0, 0.5, 0.0, -1.0, 0.5, 0.0,
                              -1.0, -0.5, 0.0, 0.0, -0.5, 0.0, 1.0, 0.5, 0.0, 0.0, 0.5, 0.0,
                              0.0, -0.5, 0.0, 1.0, -0.5, 0.0, 1.0, -0.5, 0.0, 1.0, 0.5, 0.0]
    # Four triangles on edge 1-2: (1,2,3), (2,1,4), (1,2,5), (2,1,3). The first
    # pair matches and is emitted (perpendicular faces), the third records 1→2
    # again, the fourth pairs with it (coplanar with the first, not emitted).
    # node prints these eight segments.
    nonmanifold = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 2, 0, 0, 0, 1],
                                 Float64[], Float64[], [1, 2, 3, 2, 1, 4, 1, 2, 5, 2, 1, 3], 5, 4)
    @test edges_geometry(nonmanifold; threshold_angle=deg2rad(20)).positions ==
          [1.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 2, 0,
           0, 2, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0]
end

@testset "wireframe_geometry keeps face direction and visits draw groups" begin
    # WireframeGeometry.js:66-82: each triangle (a, b, c) adds a→b, b→c, c→a.
    @test wireframe_geometry(PlaneGeometry()).positions ==
          [-0.5, 0.5, 0.0, -0.5, -0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 0.5, 0.0, 0.5, 0.5, 0.0,
           -0.5, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, -0.5, 0.0, 0.5, -0.5, 0.0, 0.5, 0.5, 0.0]
    # WireframeGeometry.js:51-57: with groups, faces are visited group by group.
    # three.js groups (6, 6, 0), (0, 6, 1) are faces 3:4 then 1:2 here.
    plane = PlaneGeometry(width_segments=2)
    add_group!(plane, 3, 2, 0)
    add_group!(plane, 1, 2, 1)
    @test wireframe_geometry(plane).positions ==
          [0.0, 0.5, 0.0, 0.0, -0.5, 0.0, 0.0, -0.5, 0.0, 0.5, 0.5, 0.0, 0.5, 0.5, 0.0,
           0.0, 0.5, 0.0, 0.0, -0.5, 0.0, 0.5, -0.5, 0.0, 0.5, -0.5, 0.0, 0.5, 0.5, 0.0,
           -0.5, 0.5, 0.0, -0.5, -0.5, 0.0, -0.5, -0.5, 0.0, 0.0, 0.5, 0.0, 0.0, 0.5, 0.0,
           -0.5, 0.5, 0.0, -0.5, -0.5, 0.0, 0.0, -0.5, 0.0]
    add_group!(plane, 9, 1, 0)
    @test_throws ArgumentError wireframe_geometry(plane)
end

@testset "SphereGeometry pole vertices coincide as in three.js" begin
    # SphereGeometry.js:81-82: ringRadius = sqrt(radius^2 - y^2) is exactly 0
    # at y = -radius, so node prints the bottom ring of SphereGeometry(1, 7, 5)
    # as (±0, -1, ±0) and 89 wireframe / 7 edges (45 degrees) segments.
    sphere = SphereGeometry(radius=1.0, width_segments=7, height_segments=5)
    bottom = sphere.positions[end-23:end]
    @test all(iszero, bottom[1:3:end]) && all(==(-1.0), bottom[2:3:end]) &&
          all(iszero, bottom[3:3:end])
    @test wireframe_geometry(sphere).n_vertices ÷ 2 == 89
    @test edges_geometry(sphere; threshold_angle=deg2rad(45)).n_vertices ÷ 2 == 7
    @test sphere.normals[end-23:end] == bottom
    # A radius whose square overflows keeps a finite sphere.
    huge = SphereGeometry(radius=1e200, width_segments=3, height_segments=2)
    @test all(isfinite, huge.positions) && all(isfinite, huge.normals)
    @test huge.positions[3 * 5 - 2] ≈ -1e200 rtol=1e-15     # equator vertex, phi = 0
    # A radius whose square underflows keeps the sphere's shape too (three.js
    # gets radius^2 - y^2 == 0 there and collapses every ring onto the y axis).
    unit = SphereGeometry(radius=1.0, width_segments=8, height_segments=6)
    for radius in (1e-300, 1e-170, 1e-160)
        tiny = SphereGeometry(radius=radius, width_segments=8, height_segments=6)
        @test _approx(tiny.positions ./ radius, unit.positions; atol=1e-15)
        @test _approx(tiny.normals, unit.normals; atol=1e-15)
    end
end

@testset "apply_matrix4! matches BufferGeometry.applyMatrix4" begin
    # BufferGeometry.js:204-246 with a sheared affine matrix: positions as
    # points, normals by the normal matrix, tangents by transformDirection
    # (w kept), winding unchanged.
    m = Mat4((1.2, 0.3, -0.4, 0.0, -0.2, 0.9, 0.5, 0.0, 0.1, -0.6, 1.4, 0.0, 0.5, -1.5, 2.0, 1.0))
    g = _audit3b_quad()
    @test Diff3D.apply_matrix4!(g, m) === g
    @test _approx(g.positions, [0.5, -1.5, 2.0, 2.9, -0.9, 1.2, 0.3, -0.6, 2.5, 0.8, -3.3, 6.199999999999999])
    @test _approx(g.normals, [0.3769925479847023, -0.3843845587295004, 0.8426892249069816,
                              0.5325328179371636, 0.7910813599791199, 0.30099681013839685,
                              0.0, 0.0, 0.0, 0.8151055174127856, -0.1322120556517763, 0.5640239071383115])
    @test _approx(get_attribute(g, :tangent).data,
                  [0.9230769230769229, 0.23076923076923073, -0.3076923076923077, 1.0,
                   -0.19069251784911845, 0.8581163303210331, 0.4767312946227961, -1.0,
                   0.0, 0.0, 0.0, 1.0, 0.5223844231551786, 0.8395463943565373, 0.1492526923300511, 1.0])
    @test g.indices == [1, 2, 3, 1, 3, 4]
    # A projective matrix divides by w (Vector3.applyMatrix4).
    p = Diff3D.apply_matrix4!(_audit3b_quad(),
                              Mat4((1.0, 0.2, 0.0, 0.1, 0.0, 1.0, 0.0, 0.05, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)))
    @test _approx(p.positions, [0.0, 0.0, 0.0, 1.6666666666666667, 0.33333333333333337, 0.0,
                                0.0, 0.9523809523809523, 0.0, 0.0, 0.0, 3.0])
    # Invalid input leaves the geometry unchanged.
    bad = _audit3b_quad()
    before = copy(bad.positions)
    @test_throws ArgumentError Diff3D.apply_matrix4!(bad, Mat4(ntuple(i -> i == 1 ? NaN : 0.0, 16)))
    @test bad.positions == before
end

@testset "rotate/translate/scale/look_at/center match three.js" begin
    q = _audit3b_quad
    @test _approx(Diff3D.rotate_geometry_x!(q(), 0.7).positions,
                  [0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 0.7648421872844885, 0.644217687237691,
                   0.0, -1.932653061713073, 2.2945265618534654])
    @test _approx(Diff3D.rotate_geometry_y!(q(), -1.1).normals,
                  [-0.8912073600614354, 0.0, 0.4535961214255773, 0.3207408933799423,
                   0.7071067811865475, 0.630178767742802, 0.0, 0.0, 0.0,
                   -0.44080821519380203, 0.0, 0.8976013131773232])
    @test _approx(Diff3D.rotate_geometry_z!(q(), 2.5).positions,
                  [0.0, 0.0, 0.0, -1.6022872310938674, 1.1969442882079129, 0.0,
                   -0.5984721441039564, -0.8011436155469337, 0.0, 0.0, 0.0, 3.0])
    @test Diff3D.translate_geometry!(q(), 1, -2, 0.5).positions ==
          [1.0, -2.0, 0.5, 3.0, -2.0, 0.5, 1.0, -1.0, 0.5, 1.0, -2.0, 3.5]
    # A negative scale keeps the winding (three.js panorama idiom), and the
    # normal matrix flips the normals.
    s = Diff3D.scale_geometry!(q(), -1, 2, 0.5)
    @test s.indices == [1, 2, 3, 1, 3, 4]
    @test _approx(s.normals, [0.0, 0.0, 1.0, -0.8944271909999159, 0.4472135954999579, 0.0,
                              0.0, 0.0, 0.0, -0.35112344158839165, 0.0, 0.9363291775690444])
    look = Diff3D.look_at_geometry!(q(), Vec3(1.0, 2.0, 3.0))
    @test _approx(look.positions, [0.0, 0.0, 0.0, 1.8973665961010275, 5.551115123125783e-17,
                                   -0.6324555320336757, -0.16903085094570328, 0.8451542547285166,
                                   -0.50709255283711, 0.8017837257372731, 1.6035674514745464,
                                   2.4053511772118195])
    @test _approx(look.normals, [0.26726124191242434, 0.5345224838248488, 0.8017837257372733,
                                 0.5512975323164975, 0.5976143046671968, -0.5821753805502969,
                                 0.0, 0.0, 0.0, 0.783018972360248, 0.4276179870598791,
                                 0.4516903209797159])
    @test Diff3D.center_geometry!(q()).positions ==
          [-1.0, -0.5, -1.5, 1.0, -0.5, -1.5, -1.0, 0.5, -1.5, -1.0, -0.5, 1.5]
    @test Diff3D.center_geometry!(BufferGeometry()).n_vertices == 0
    rot = quat_normalize(Quaternion(0.1, 0.7, -0.3, 0.6))
    @test _approx(Diff3D.apply_quaternion!(q(), rot).positions,
                  [0.0, 0.0, 0.0, -0.4421052631578952, -0.46315789473684216, -1.8947368421052633,
                   0.5263157894736843, 0.7894736842105263, -0.3157894736842105, 2.4631578947368427,
                   -1.7052631578947373, -0.15789473684210575])
end

@testset "apply_matrix4! carries relative morph targets with the geometry" begin
    # Diff3D extension (three.js leaves morphAttributes untouched): a delta
    # rotates with the base so the morphed shape is the rotated morphed shape.
    g = _audit3b_quad()
    set_attribute!(g, :morphPosition0, [0.0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 0], 3)
    morphed_then_rotated = transform_geometry(
        BufferGeometry(vcat((p -> [p.x, p.y, p.z]).(apply_morph_targets(g, [0.5]))...),
                       Float64[], Float64[], copy(g.indices), 4, 2), mat4_rotation_y(0.4))
    Diff3D.rotate_geometry_y!(g, 0.4)
    @test _approx(vcat((p -> [p.x, p.y, p.z]).(apply_morph_targets(g, [0.5]))...),
                  morphed_then_rotated.positions; atol=1e-14)
    set_attribute!(g, :morphPosition1, zeros(12), 3)
    @test_throws ArgumentError Diff3D.apply_matrix4!(
        g, Mat4((1.0, 0.0, 0.0, 0.5, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0)))
end

@testset "to_non_indexed, normalize_normals!, set_from_points!, delete_attribute!" begin
    # BufferGeometry.js toNonIndexed: attributes gathered through the index,
    # groups copied. node prints these for PlaneGeometry() with group (3, 3, 1).
    plane = PlaneGeometry()
    add_group!(plane, 2, 1, 1)
    set_attribute!(plane, :morphPosition0, collect(1.0:12.0), 3)
    flat = Diff3D.to_non_indexed(plane)
    @test flat.positions == [-0.5, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 0.5, 0.0,
                             -0.5, -0.5, 0.0, 0.5, -0.5, 0.0, 0.5, 0.5, 0.0]
    @test flat.uvs == [0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 1.0]
    @test flat.indices == 1:6 && flat.n_vertices == 6 && flat.n_faces == 2
    @test flat.groups == [(2, 1, 1)]
    # The plane index is (1, 3, 2), (3, 4, 2), so vertex rows gather as such.
    @test get_attribute(flat, :morphPosition0).data ==
          [1.0, 2, 3, 7, 8, 9, 4, 5, 6, 7, 8, 9, 10, 11, 12, 4, 5, 6]
    line = BufferGeometry(zeros(6), Float64[], Float64[], Int[], 2, 0)
    @test Diff3D.to_non_indexed(line) === line    # three.js returns `this`
    short = BufferGeometry(zeros(9), zeros(3), Float64[], [1, 2, 3], 3, 1)
    @test_throws ArgumentError Diff3D.to_non_indexed(short)

    # Vector3.normalize divides by `length() || 1`; node prints [0.6, 0.8, 0]
    # and zero for a zero normal. Diff3D also keeps the direction of a normal
    # whose squared length underflows (three.js leaves it unnormalized).
    nn = BufferGeometry(zeros(9), [3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 1e-200, 1e-200, 0.0],
                        Float64[], [1, 2, 3], 3, 1)
    Diff3D.normalize_normals!(nn)
    @test nn.normals[1:6] == [0.6000000000000001, 0.8, 0.0, 0.0, 0.0, 0.0]
    @test nn.normals[7:9] ≈ [sqrt(0.5), sqrt(0.5), 0.0] atol=1e-15
    @test_throws ArgumentError Diff3D.normalize_normals!(BufferGeometry(zeros(3), Float64[], Float64[], Int[], 1, 0))

    # BufferGeometry.js setFromPoints: Vector2 points get z = 0.
    pts = Diff3D.set_from_points!(BufferGeometry(), [Vec2(1.0, 2.0), Vec2(3.0, 4.0)])
    @test pts.positions == [1.0, 2.0, 0.0, 3.0, 4.0, 0.0] && pts.n_vertices == 2
    Diff3D.set_from_points!(pts, [Vec3(5.0, 6.0, 7.0)])
    @test pts.positions == [5.0, 6.0, 7.0, 3.0, 4.0, 0.0]
    @test_throws ArgumentError Diff3D.set_from_points!(pts, fill(Vec3(0.0, 0.0, 0.0), 3))
    # A non-finite point is rejected before anything is written.
    @test_throws ArgumentError Diff3D.set_from_points!(pts, [Vec3(9.0, 9.0, 9.0), Vec3(NaN, 0.0, 0.0)])
    @test pts.positions == [5.0, 6.0, 7.0, 3.0, 4.0, 0.0]
    empty_geometry = BufferGeometry()
    @test_throws ArgumentError Diff3D.set_from_points!(empty_geometry, [Vec2(1.0, Inf)])
    @test empty_geometry.n_vertices == 0 && isempty(empty_geometry.positions)

    g = PlaneGeometry()
    set_attribute!(g, :color, ones(12), 3)
    @test Diff3D.delete_attribute!(g, :color) === g && !has_attribute(g, :color)
    @test isempty(Diff3D.delete_attribute!(g, :normal).normals)
    @test isempty(Diff3D.delete_attribute!(g, :uv).uvs)
    @test Diff3D.delete_attribute!(g, :missing) === g
    @test_throws ArgumentError Diff3D.delete_attribute!(g, :position)

    # Float64 positions/normals/UVs and Int indices: 4 * (12 + 12 + 8) + 8 * 6.
    @test Diff3D.estimate_bytes_used(PlaneGeometry()) == 8 * 32 + 8 * 6
end

@testset "to_creased_normals matches BufferGeometryUtils.toCreasedNormals" begin
    # node prints these normals for an open three-sided CylinderGeometry: at
    # 0.5 rad every side is flat, at 2.5 rad the sides are smoothed.
    prism = CylinderGeometry(radius_top=1.0, radius_bottom=1.0, height=1.0,
                             radial_segments=3, open_ended=true)
    flat_sides = [0.8660254037844386, 0.0, 0.5000000000000001, 3.8459253727671286e-16, 0.0, -1.0,
                  -0.8660254037844389, 0.0, 0.4999999999999998]
    creased = Diff3D.to_creased_normals(prism; crease_angle=0.5)
    @test creased.n_vertices == 18
    @test _approx(creased.normals, vcat((repeat(flat_sides[3k-2:3k], 6) for k in 1:3)...))
    smooth = Diff3D.to_creased_normals(prism; crease_angle=2.5)
    @test _approx(smooth.normals,
                  [-0.5000000000000001, 0.0, 0.8660254037844385, 0.5, 0.0, 0.8660254037844388,
                   1.0, 0.0, 1.281975124255709e-16, 0.5, 0.0, 0.8660254037844388,
                   0.5000000000000002, 0.0, -0.8660254037844384, 1.0, 0.0, 1.281975124255709e-16,
                   1.0, 0.0, 1.281975124255709e-16, 0.5000000000000002, 0.0, -0.8660254037844384,
                   -0.49999999999999967, 0.0, -0.866025403784439, 0.5000000000000002, 0.0,
                   -0.8660254037844384, -1.0, 0.0, -3.8459253727671286e-16, -0.49999999999999967,
                   0.0, -0.866025403784439, -0.49999999999999967, 0.0, -0.866025403784439,
                   -1.0, 0.0, -3.8459253727671286e-16, -0.5000000000000001, 0.0,
                   0.8660254037844385, -1.0, 0.0, -3.8459253727671286e-16, 0.5, 0.0,
                   0.8660254037844388, -0.5000000000000001, 0.0, 0.8660254037844385])
    @test prism.n_vertices == 8          # the input is not modified
    @test Diff3D.to_creased_normals(BufferGeometry()).n_vertices == 0
end

@testset "merge_groups! and to_triangles_draw_mode! match BufferGeometryUtils" begin
    # three.js groups (6,6,2), (0,6,1), (12,6,1), (3,3,2) on PlaneGeometry(1,1,3,1)
    # are faces (3,2,2), (1,2,1), (5,2,1), (2,1,2). node prints the index
    # [0,4,1,4,5,1,2,6,3,6,7,3,4,5,1,1,5,2,5,6,2] and groups (0,12,1), (12,9,2).
    plane = PlaneGeometry(width_segments=3)
    for group in ((3, 2, 2), (1, 2, 1), (5, 2, 1), (2, 1, 2))
        add_group!(plane, group...)
    end
    @test Diff3D.merge_groups!(plane) === plane
    @test plane.indices == [0, 4, 1, 4, 5, 1, 2, 6, 3, 6, 7, 3, 4, 5, 1, 1, 5, 2, 5, 6, 2] .+ 1
    @test plane.n_faces == 7
    @test plane.groups == [(1, 4, 1), (5, 3, 2)]
    untouched = PlaneGeometry()
    @test Diff3D.merge_groups!(untouched).indices == PlaneGeometry().indices
    # node prints strip [0,2,1,5,1,2,1,5,4,3,4,5] and fan [0,2,1,0,1,5,0,5,4,0,4,3]
    # for the order [0,2,1,5,4,3].
    for (mode, expected) in ((:triangle_strip, [0, 2, 1, 5, 1, 2, 1, 5, 4, 3, 4, 5]),
                             (:triangle_fan, [0, 2, 1, 0, 1, 5, 0, 5, 4, 0, 4, 3]))
        g = BufferGeometry(zeros(18), Float64[], Float64[], [1, 3, 2, 6, 5, 4], 6, 0)
        add_group!(g, 1, 1, 0)
        @test Diff3D.to_triangles_draw_mode!(g, mode) === g
        @test g.indices == expected .+ 1 && g.n_faces == 4 && isempty(g.groups)
        unindexed = Diff3D.to_triangles_draw_mode!(
            BufferGeometry(zeros(12), Float64[], Float64[], Int[], 4, 0), mode)
        @test unindexed.n_faces == 2
    end
    tri = PlaneGeometry()
    @test Diff3D.to_triangles_draw_mode!(tri, :triangles).indices == PlaneGeometry().indices
    @test_throws ArgumentError Diff3D.to_triangles_draw_mode!(tri, :points)
    @test_throws ArgumentError Diff3D.to_triangles_draw_mode!(
        BufferGeometry(zeros(6), Float64[], Float64[], Int[], 2, 0), :triangle_strip)
end

@testset "BoxGeometry, PolyhedronGeometry and LatheGeometry use three.js order" begin
    # BoxGeometry.js:76-81 builds px, nx, py, ny, pz, nz; buildPlane
    # (BoxGeometry.js:111-160) emits rows top to bottom with UV
    # (ix / gridX, 1 - iy / gridY) and faces (a, b, d), (b, c, d).
    # new THREE.BoxGeometry(1, 2, 3, 2, 1, 1):
    box = BoxGeometry(width=1.0, height=2.0, depth=3.0, width_segments=2)
    @test box.positions[1:12] == [0.5, 1.0, 1.5, 0.5, 1.0, -1.5, 0.5, -1.0, 1.5, 0.5, -1.0, -1.5]
    @test box.positions[25:36] == [-0.5, 1.0, -1.5, 0.0, 1.0, -1.5, 0.5, 1.0, -1.5, -0.5, 1.0, 1.5]
    @test box.uvs[1:8] == [0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0, 0.0]
    @test box.indices[1:12] == [0, 2, 1, 2, 3, 1, 4, 6, 5, 6, 7, 5] .+ 1
    @test box.normals[1:3] == [1.0, 0.0, 0.0] && box.normals[25:27] == [0.0, 1.0, 0.0]
    # PolyhedronGeometry.js:84-131 subdivides each face into rows from corner a
    # and emits (v[i][k+1], v[i+1][k], v[i][k]) then
    # (v[i][k+1], v[i+1][k+1], v[i+1][k]). new THREE.OctahedronGeometry(1, 1):
    r = 0.7071067811865475
    octa = OctahedronGeometry(radius=1.0, detail=1)
    @test _approx(octa.positions[1:18], [r, r, 0.0, r, 0.0, r, 1.0, 0.0, 0.0,
                                         r, r, 0.0, 0.0, r, r, r, 0.0, r]; atol=1e-15)
    @test _approx(octa.uvs[1:12], [1.0, 0.75, 0.875, 0.5, 1.0, 0.5, 1.0, 0.75, 0.75, 0.75, 0.875, 0.5];
                  atol=1e-15)
    # The icosahedron's last five faces keep the corner order of
    # IcosahedronGeometry.js:44-45; node prints face 16 (vertices 46-48) of
    # new THREE.IcosahedronGeometry(1, 0) as:
    ico = IcosahedronGeometry(radius=1.0, detail=0)
    @test _approx(ico.positions[136:144],
                  [0.85065080835204, 0.0, 0.5257311121191336, 0.0, 0.5257311121191336,
                   0.85065080835204, 0.0, -0.5257311121191336, 0.85065080835204]; atol=1e-15)
    # LatheGeometry.js:176-177 emits (a, b, d), (c, d, b).
    # new THREE.LatheGeometry([(1,0), (2,1), (1,2)], 2).index:
    lathe = LatheGeometry([Vec2(1.0, 0.0), Vec2(2.0, 1.0), Vec2(1.0, 2.0)]; segments=2)
    @test lathe.indices == [0, 3, 1, 4, 1, 3, 1, 4, 2, 5, 2, 4, 3, 6, 4, 7, 4, 6, 4, 7, 5, 8, 5, 7] .+ 1
end

@testset "ParametricGeometry follows three.js" begin
    # ParametricGeometry.js:64-118: UV (u, v), faces (a, b, d), (b, c, d) and
    # finite-difference normals. new ParametricGeometry(ParametricFunctions.mobius, 3, 2):
    g = ParametricGeometry(Diff3D.ParametricFunctions.mobius, 3, 2)
    @test g.n_vertices == 12
    @test g.uvs[1:10] == [0.0, 0.0, 1 / 3, 0.0, 2 / 3, 0.0, 1.0, 0.0, 0.0, 0.5]
    @test g.indices[1:12] == [0, 1, 4, 1, 5, 4, 1, 2, 5, 2, 6, 5] .+ 1
    @test _approx(g.positions[13:18], [-2.0, 2.4492935982947064e-16, -0.5, -2.0,
                                       2.4492935982947064e-16, -0.16666666666666669])
    @test _approx(g.normals[1:12], [0.0, 0.16439898735798059, 0.9863939238233731, 0.0,
                                    0.045407660938978696, 0.9989685402093756, 0.0,
                                    -0.03843312212159912, 0.9992611746305297, 0.0,
                                    -0.09950371907933925, 0.995037190204155]; atol=1e-9)
    # Defaults slices = stacks = 8 (ParametricGeometry.js:33): 81 vertices.
    @test ParametricGeometry(Diff3D.ParametricFunctions.plane).n_vertices == 81
    # ParametricFunctions.js values at (0.3, 0.7) (klein also at (0.3, 0.2)).
    P = Diff3D.ParametricFunctions
    @test _approx(_xyz(P.klein(0.3, 0.7)), [0.6681523868762881, -2.196005658736544, 7.608452130361228])
    @test _approx(_xyz(P.klein(0.3, 0.2)), [1.6472543531259733, -1.6082204064440706, -7.111484694069425])
    @test _approx(_xyz(P.mobius(0.3, 0.7)), [-0.6543611151501632, -2.0139164314652964, -0.1618033988749895])
    @test _approx(_xyz(P.mobius3d(0.3, 0.7)), [-0.842818859107538, 2.5939297274961, -0.3946110463437158])
    @test P.plane(0.3, 0.7) == Vec3(0.3, 0.0, 0.7)
    # The three.js NURBS example builds its surface as
    # ParametricGeometry(getSurfacePoint, 20, 20); same faces and UVs here.
    surface = NURBSSurface(1, 1, [0.0, 0.0, 1.0, 1.0], [0.0, 0.0, 1.0, 1.0],
                           [[Vec4(0.0, 0.0, 0.0, 1.0), Vec4(0.0, 1.0, 0.0, 1.0)],
                            [Vec4(1.0, 0.0, 0.0, 1.0), Vec4(1.0, 1.0, 0.0, 1.0)]])
    ns = NURBSSurfaceGeometry(surface; slices=3, stacks=2)
    @test ns.indices == ParametricGeometry((u, v) -> nurbs_point(surface, u, v), 3, 2).indices
    @test ns.uvs == g.uvs
end

@testset "RoundedBoxGeometry, BoxLineGeometry and DecalGeometry match three.js" begin
    # new RoundedBoxGeometry(2, 0.5, 1.5, 3, 0.2) vertices 0, 99, 999 (and UV 1500).
    rb = Diff3D.RoundedBoxGeometry(width=2.0, height=0.5, depth=1.5, segments=3, radius=0.2)
    @test rb.n_vertices == 1764 && rb.indices == collect(1:1764)
    pos(i) = rb.positions[3i + 1:3i + 3]
    nrm(i) = rb.normals[3i + 1:3i + 3]
    uv(i) = rb.uvs[2i + 1:2i + 2]
    @test _approx(pos(0), [0.9154700538379252, 0.16547005383792512, 0.6654700538379252])
    @test _approx(pos(99), [0.9897366596101028, 0.05, 0.6132455532033676])
    @test _approx(pos(999), [0.8632455532033676, -0.23973665961010276, 0.55])
    @test _approx(nrm(0), [0.5773502691896257, 0.5773502691896257, 0.5773502691896257])
    @test _approx(nrm(99), [0.9486832980505139, 6.143958570009227e-17, 0.316227766016838])
    @test _approx(uv(99), [0.06557219124581573, 0.6207265035026119])
    @test _approx(uv(999), [0.9515560050418423, 0.8889236619047887])
    @test _approx(uv(1500), [0.9515560050418422, 1.0])
    # segments = 0 returns the unit box (RoundedBoxGeometry.js:73-77 builds
    # BoxGeometry(1, 1, 1, 1, 1, 1) and returns early).
    @test Diff3D.RoundedBoxGeometry(width=3.0, segments=0).positions == BoxGeometry().positions
    @test_throws ArgumentError Diff3D.RoundedBoxGeometry(width=0.0)
    @test_throws ArgumentError Diff3D.RoundedBoxGeometry(radius=-0.1)

    # new BoxLineGeometry(2, 3, 1, 2, 3, 1): 72 vertices; the first x rectangle
    # and the first y rectangle (BoxLineGeometry.js:43-71).
    bl = Diff3D.BoxLineGeometry(width=2.0, height=3.0, depth=1.0, width_segments=2,
                                height_segments=3, depth_segments=1)
    @test bl.n_vertices == 72 && bl.n_faces == 0 && isempty(bl.indices)
    @test bl.positions[1:24] == [-1.0, -1.5, -0.5, -1.0, 1.5, -0.5, -1.0, 1.5, -0.5, -1.0, 1.5, 0.5,
                                 -1.0, 1.5, 0.5, -1.0, -1.5, 0.5, -1.0, -1.5, 0.5, -1.0, -1.5, -0.5]
    @test bl.positions[73:96] == [-1.0, -1.5, -0.5, 1.0, -1.5, -0.5, 1.0, -1.5, -0.5, 1.0, -1.5, 0.5,
                                  1.0, -1.5, 0.5, -1.0, -1.5, 0.5, -1.0, -1.5, 0.5, -1.0, -1.5, -0.5]

    # DecalGeometry.js:55-311 on a transformed torus; node prints 315 vertices
    # and these first positions, normals and UVs.
    torus = Mesh(TorusGeometry(radius=1.0, tube=0.4, radial_segments=10, tubular_segments=16),
                 MeshBasicMaterial())
    torus.position = Vec3(0.2, -0.1, 0.3)
    torus.rotation = Euler(0.4, 0.2, -0.3, :YXZ)
    torus.scale = Vec3(1.5, 0.8, 1.2)
    decal = Diff3D.DecalGeometry(torus, Vec3(0.5, 0.6, 0.6), Euler(0.3, -0.5, 0.1, :ZYX),
                                 Vec3(1.2, 0.9, 1.5))
    @test decal.n_vertices == 315 && decal.n_faces == 105
    @test _approx(decal.positions[1:9], [1.3102355038567923, 0.5917529910233622, 0.3733610661724025,
                                         1.3100659483921546, 0.588957844612535, 0.37810780188729404,
                                         1.313621794518319, 0.5892225423444535, 0.37158301488404105])
    @test _approx(decal.normals[1:9], [0.5520193611320522, 0.8004916480987861, 0.2334261044944417,
                                       0.5524499465648909, 0.7954663357664639, 0.24072952214322405,
                                       0.5532786462642874, 0.7995267099486623, 0.23275456782973353])
    @test _approx(decal.uvs[1:6], [0.9984310314733813, 0.2133373360872604, 1.0, 0.2118414239084236,
                                   1.0, 0.2093028633793026])
    @test_throws ArgumentError Diff3D.DecalGeometry(torus, Vec3(0.0, 0.0, 0.0),
                                                    Euler(0.0, 0.0, 0.0, :XYZ), Vec3(1.0, 0.0, 1.0))
end

@testset "Curve hierarchy matches three.js" begin
    D = Diff3D
    V2(x, y) = Vec2(Float64(x), Float64(y))
    V3(x, y, z) = Vec3(Float64(x), Float64(y), Float64(z))
    flat(points) = reduce(vcat, [_xyz(p) for p in points])
    # Curve.js on new THREE.QuadraticBezierCurve3((-1,-1,0), (-1,1,0), (1,1,0)).
    q = D.QuadraticBezierCurve3(V3(-1, -1, 0), V3(-1, 1, 0), V3(1, 1, 0))
    @test D.get_length(q) ≈ 3.2464421469288975 atol = 1e-12
    @test _approx(D.get_lengths(q, 4), [0.0, 0.8838834764831844, 1.612752463338847,
                                         2.3416214501945096, 3.225504926677694])
    @test D.get_u_to_t_mapping(q, 0.3) ≈ 0.2775757937240636 atol = 1e-12
    @test D.get_u_to_t_mapping(q, 0.0, 1.5) ≈ 0.456489888802106 atol = 1e-12
    @test _approx(_xyz(D.get_point_at(q, 0.3)), [-0.8459033574769123, -0.04379346762683342, 0.0])
    @test _approx(_xyz(D.get_tangent_at(q, 0.3)), [0.35866425671859564, 0.9334666308725219, 0.0])
    @test D.get_points(q, 2) == [V3(-1, -1, 0), V3(-0.5, 0.5, 0), V3(1, 1, 0)]
    frames = D.compute_frenet_frames(q, 4)
    @test all(n -> n == V3(0, 0, -1), frames.normals)
    @test _approx(flat(frames.binormals),
                  [-0.999999998749875, 0.00005000250003618196, 0.0, -0.959838066895765, 0.2805546031306576, 0.0,
                   -0.7071067811864004, 0.7071067811866948, 0.0, -0.2805546031308394, 0.9598380668957118, 0.0,
                   -0.00005000250003619584, 0.999999998749875, 0.0])
    @test all(n -> n == V3(0, 0, -1), D.compute_frenet_frames(q, 4, true).normals)
    # EllipseCurve.js:123-170 sweep handling, ArcCurve and the 2D curves.
    @test _approx(_xyz(D.get_point(D.EllipseCurve(0.5, -0.2, 2, 1, 0.3, 4, false, 0.25), 0.4)),
                  [-0.14445911787776855, 0.6450246390916015])
    @test _approx(_xyz(D.get_point(D.EllipseCurve(0, 0, 1, 1.5, 0.3, 4, true), 0.4)),
                  [0.7429869990346246, -1.0039587732309658])
    @test _approx(_xyz(D.get_point(D.EllipseCurve(0, 0, 1, 1, 0, 4π), 0.25)), [0.0, 1.0])
    @test _approx(_xyz(D.get_point(D.EllipseCurve(0, 0, 1, 1, 1, 1, true), 0.5)),
                  [0.5403023058681398, 0.8414709848078965])
    @test _approx(_xyz(D.get_point(D.ArcCurve(1, 1, 2, 0, π, true), 0.25)),
                  [2.414213562373095, -0.4142135623730949])
    spline = D.SplineCurve([V2(0, 0), V2(1, 1), V2(2, -1), V2(4, 0), V2(5, 2)])
    @test _approx(_xyz(D.get_point(spline, 0.37)), [1.420096, 0.054976000000000025])
    @test D.get_point(spline, 1.0) == V2(5, 2)
    @test _approx(_xyz(D.get_point(D.CubicBezierCurve(V2(0, 0), V2(1, 2), V2(2, -1), V2(3, 0.5)), 0.3)),
                  [0.8999999999999998, 0.7064999999999998])
    @test _approx(_xyz(D.get_point(D.CubicBezierCurve3(V3(0, 0, 0), V3(1, 2, 1), V3(2, -1, 0.5),
                                                                 V3(3, 0.5, -1)), 0.3)),
                  [0.8999999999999998, 0.7064999999999998, 0.5084999999999998])
    @test _approx(_xyz(D.get_point(D.QuadraticBezierCurve(V2(0, 0), V2(1, 2), V2(3, 0.5)), 0.3)),
                  [0.69, 0.885])
    @test D.get_point(D.LineCurve(V2(0, 0), V2(2, 1)), 0.3) == V2(0.6, 0.3)

    # Path / Shape pen commands and CurvePath sampling (CurvePath.js:90-213).
    shape = D.Shape()
    D.move_to!(shape, 0, 0); D.line_to!(shape, 2, 0); D.quadratic_curve_to!(shape, 3, 1, 2, 2)
    D.bezier_curve_to!(shape, 1.5, 3, 0.5, 3, 0, 2)
    D.spline_thru!(shape, [V2(-0.5, 1.5), V2(-0.2, 0.8)])
    D.absarc!(shape, 0.0, 0.3, 0.3, π / 2, 3π / 2, false)
    D.close_path!(shape)
    @test length(shape.curves) == 7
    pts = D.get_points(shape, 2)
    @test length(pts) == 18
    @test pts[1:6] == [V2(0, 0), V2(2, 0), V2(2.5, 1), V2(2, 2), V2(1, 2.75), V2(0, 2)]
    @test _approx(_xyz(pts[7]), [-0.15925925925925927, 1.8777777777777778])
    @test _approx(_xyz(pts[14]), [-0.21213203435596423, 0.5121320343559642])
    @test D.get_length(shape) ≈ 9.647027011181313 atol = 1e-12
    @test _approx(_xyz(D.get_point(shape, 0.43)), [2.1012878879717687, 1.8929861275834372])
    @test _approx(flat(D.get_spaced_points(shape, 4)),
                  [0.0, 0.0, 2.2649849191422264, 0.31441254262089474, 1.6989667379910611, 2.4310578233130364,
                   -0.24265323975047576, 1.814581882183391, -5.510910596163089e-17, 0.0])
    path3 = D.CurvePath([D.LineCurve3(V3(0, 0, 0), V3(1, 0, 0)),
                         D.QuadraticBezierCurve3(V3(1, 0, 0), V3(2, 1, 0), V3(2, 2, 1))]; auto_close=true)
    @test D.get_points(path3, 2) == [V3(0, 0, 0), V3(1, 0, 0), V3(1.75, 1, 0.25), V3(2, 2, 1), V3(0, 0, 0)]
    @test _approx(flat(D.get_spaced_points(path3, 2)),
                  [0.0, 0.0, 0.0, 1.5067766839893522, 0.5954028107522815, 0.08862612676292929,
                   2.0, 2.0, 1.0, 0.0, 0.0, 0.0])
    @test_throws ArgumentError D.add!(path3, D.LineCurve(V2(0, 0), V2(1, 1)))

    # TubeGeometry.js:73-160 along a curve: new THREE.TubeGeometry(q, 3, 0.5, 4).
    tube = TubeGeometry(q; tubular_segments=3, radius=0.5, radial_segments=4)
    @test tube.n_vertices == 20
    @test _approx(tube.positions[16:27], [-0.8040910485164533, 0.05599823831463223, 0.5, -1.2591010983805018,
                                          0.26328030344019054, 3.061616997868383e-17, -0.8040910485164534,
                                          0.05599823831463226, -0.5, -0.3490809986524049,
                                          -0.15128382681092606, -9.184850993605148e-17])
    @test _approx(tube.normals[16:21], [0.0, 0.0, 1.0, -0.9100200997280968, 0.4145641302511166,
                                        6.123233995736766e-17])
    @test tube.indices[1:12] == [0, 5, 1, 5, 6, 1, 1, 6, 2, 6, 7, 2] .+ 1
    closed = TubeGeometry(q; tubular_segments=3, radius=0.5, radial_segments=4, closed=true)
    @test _approx(closed.positions[46:60], [-1.0, -1.0, 0.5, -1.4999999993749376, -0.9999749987499819,
                                            3.061616997868383e-17, -1.0, -1.0, -0.5, -0.5000000006250624,
                                            -1.000025001250018, -9.184850993605148e-17,
                                            -0.9999999999999999, -1.0, 0.5])
    # CatmullRomCurve is a Curve: new THREE.TubeGeometry(CatmullRomCurve3(...), 4, 0.2, 3).
    cr = CatmullRomCurve([V3(0, 0, 0), V3(1, 2, 0.5), V3(3, 1, -1), V3(4, -1, 0)])
    @test _approx(TubeGeometry(cr; tubular_segments=4, radius=0.2, radial_segments=3).positions[25:36],
                  [2.2455101398533306, 1.744597256556591, -0.2373678954290032, 2.06394104972566,
                   1.859029385662986, -0.5092832376559309, 1.9969925006863614, 1.5466349283018648,
                   -0.37538926918989673, 2.2455101398533306, 1.7445972565565908, -0.2373678954290032];
                  atol=1e-9)

    # Shape -> ShapeGeometry / ExtrudeGeometry sample with extract_points.
    sq = D.Shape([V2(0, 0), V2(2, 0), V2(2, 2)])
    D.absarc!(sq, 1.0, 2.0, 0.5, 0.0, π)
    D.line_to!(sq, 0, 2)
    push!(sq.holes, D.Path([V2(0.5, 0.5), V2(1.5, 0.5), V2(1.0, 1.2)]))
    sampled = D.extract_points(sq, 5)
    # node: new THREE.Shape(...).extractPoints(5) has 15 outline and 3 hole points.
    @test length(sampled.shape) == 15 && length(sampled.holes[1]) == 3
    @test ShapeGeometry(sq; curve_segments=5).positions ==
          ShapeGeometry(sampled.shape; holes=sampled.holes).positions
    @test ExtrudeGeometry(sq; curve_segments=5, depth=0.5).positions ==
          ExtrudeGeometry(sampled.shape; holes=sampled.holes, depth=0.5).positions
end

@testset "ShapePath.to_shapes matches three.js" begin
    # ShapePath.js toShapes: an outer square, a same-winding inner square, a
    # nested bump outline, a separate open curve and a degenerate sub-path.
    D = Diff3D
    function build(rule)
        sp = D.ShapePath(; fill_rule=rule)
        D.move_to!(sp, 0, 0); D.line_to!(sp, 10, 0); D.line_to!(sp, 10, 10); D.line_to!(sp, 0, 10); D.line_to!(sp, 0, 0)
        D.move_to!(sp, 2, 2); D.line_to!(sp, 8, 2); D.line_to!(sp, 8, 8); D.line_to!(sp, 2, 8)
        D.move_to!(sp, 3, 3); D.line_to!(sp, 3, 7); D.quadratic_curve_to!(sp, 5, 9, 7, 7); D.line_to!(sp, 7, 3)
        D.move_to!(sp, 20, 0); D.line_to!(sp, 25, 0); D.bezier_curve_to!(sp, 26, 2, 24, 4, 22, 5)
        D.move_to!(sp, 4, 4); D.line_to!(sp, 4.5, 4)
        return D.to_shapes(sp)
    end
    # node prints 2 shapes without holes for nonzero, and 3 shapes (the first
    # with one hole) for evenodd.
    nonzero = build(:nonzero)
    @test length(nonzero) == 2 && all(s -> isempty(s.holes), nonzero)
    @test D.get_points(nonzero[1], 6)[1:3] == [Vec2(0.0, 0.0), Vec2(10.0, 0.0), Vec2(10.0, 10.0)]
    evenodd = build(:evenodd)
    @test length.(getfield.(evenodd, :holes)) == [1, 0, 0]
    @test D.get_points(evenodd[1].holes[1], 6)[1] == Vec2(2.0, 2.0)
    @test D.get_points(evenodd[2], 6)[1] == Vec2(3.0, 3.0)
    @test_throws ArgumentError D.line_to!(D.ShapePath(), 1, 1)
end

@testset "LatheGeometry accepts three.js segment counts" begin
    # LatheGeometry.js:56 only floors the count; 1 and 2 segments give
    # segments + 1 rows (new THREE.LatheGeometry(points, 2): 9 vertices).
    points = [Vec2(1.0, 0.0), Vec2(2.0, 1.0), Vec2(1.0, 2.0)]
    @test LatheGeometry(points; segments=2).n_vertices == 9
    @test LatheGeometry(points; segments=1).n_vertices == 6
end

@testset "CatmullRomCurve stays finite near floatmax" begin
    # node: CatmullRomCurve3 of the unit diamond (-1,0,0), (0,1,0), (1,0,0),
    # (0,-1,0) gives (0.625, 0.625, 0) at 0.5 (centripetal, open) and
    # (0.232, 0.928, 0) at 0.3 (chordal, closed). Scaled by floatmax, three.js
    # prints NaN because the point differences overflow; the non-uniform
    # parameterizations are scale invariant, so Diff3D returns the scaled
    # points.
    L = floatmax(Float64)
    diamond = [Vec3(-1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, -1.0, 0.0)]
    open = catmull_rom_point(CatmullRomCurve(diamond .* L; curve_type=:centripetal), 0.5)
    @test isapprox(open.x / L, 0.625; atol=1e-15) && isapprox(open.y / L, 0.625; atol=1e-15)
    closed = catmull_rom_point(CatmullRomCurve(diamond .* L; curve_type=:chordal, closed=true), 0.3)
    @test isapprox(closed.x / L, 0.23199999999999993; atol=1e-15) &&
          isapprox(closed.y / L, 0.928; atol=1e-15)
    for curve_type in (:centripetal, :chordal), closed in (false, true)
        curve = CatmullRomCurve(diamond .* L; curve_type=curve_type, closed=closed)
        @test all(p -> isfinite(p.x) && isfinite(p.y) && isfinite(p.z),
                  catmull_rom_points(curve; segments=16))
    end
end

@testset "CSG builds back chains in place" begin
    # A convex operand's BSP tree is a chain of back nodes. Building it by
    # copying the remaining polygons at every level allocated about 112 MB
    # (Julia 1.13) / 105 MB (1.10) for this union; compacting each back list
    # in place and building no discarded back fragments while clipping brings
    # it to about 47 MB / 77 MB with the same output (1663 triangles).
    sphere = SphereGeometry(radius=1.0, width_segments=32, height_segments=16)
    box = BoxGeometry(width=2.0, height=2.0, depth=2.0)
    @test csg_union(sphere, box).n_faces == 1663
    probe() = @allocated csg_union(sphere, box)
    probe()
    @test probe() < 90_000_000
end

@testset "CurvePath sampling computes its arc-length tables once per call" begin
    # A tube along a 20-piece CurvePath evaluates get_point_at about 200 times.
    # Rebuilding every piece's arc-length table inside each of the 201 samples
    # of get_lengths took about 1 GB and seconds; three.js caches those tables
    # (Curve.js getLengths), and computing them once per call gives the same
    # values.
    D = Diff3D
    path = D.CurvePath{Vec3{Float64}}()
    for k in 1:20
        D.add!(path, D.CubicBezierCurve3(Vec3(k - 1.0, 0.0, 0.0), Vec3(k - 0.7, 1.0, 0.0),
                                         Vec3(k - 0.3, 1.0, 1.0), Vec3(Float64(k), 0.0, 0.0)))
    end
    tube(p) = TubeGeometry(p; tubular_segments=64)
    tube(path)
    @test (@allocated tube(path)) < 100_000_000
    # The table-based point equals the piece-by-piece definition
    # (CurvePath.js:90-117, lengths accumulated in order as getCurveLengths does).
    lengths = [D.get_length(c) for c in path.curves]
    total = similar(lengths)
    running = 0.0
    for (k, len) in enumerate(lengths)
        running += len
        total[k] = running
    end
    for t in (0.0, 0.123, 0.5, 0.999, 1.0)
        i = findfirst(>=(t * total[end]), total)
        u = 1 - (total[i] - t * total[end]) / lengths[i]
        @test D.get_point(path, t) == D.get_point_at(path.curves[i], u)
    end
end

@testset "EllipseCurve reduces long sweeps without looping forever" begin
    # EllipseCurve.js:131-132 subtracts 2π until the sweep is at most 2π, which
    # never ends once delta - 2π == delta. A sweep of 1e18 radians is the
    # exact remainder rem(1e18, 2π) of a turn.
    D = Diff3D
    delta = rem(1e18, 2π)
    delta < 0 && (delta += 2π)
    long = D.EllipseCurve(0, 0, 1, 1, 0.0, 1e18)
    @test D.get_point(long, 0.5) == Vec2(cos(0.5 * delta), sin(0.5 * delta))
    @test isfinite(D.get_length(long))
    # Shorter sweeps keep three.js's steps: node prints
    # new THREE.EllipseCurve(0, 0, 1, 1, 0, 1000).getPoint(0.5).
    @test D.get_point(D.EllipseCurve(0, 0, 1, 1, 0.0, 1000.0), 0.5) ==
          Vec2(0.8838492734309304, 0.4677718053235107)
    @test_throws ArgumentError D.EllipseCurve(0, 0, 1, 1, -1e308, 1e308)
end
