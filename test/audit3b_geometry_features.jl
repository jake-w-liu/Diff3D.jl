using Test, Diff3D

# Round-2 geometry features and fixes. Expected values are printed by three.js
# r186 under node (BufferGeometry attributes built as Float64Array so the
# oracle keeps double precision), unless a comment gives a derivation.

_segments(g) = [Tuple(g.positions[6k-5:6k]) for k in 1:(length(g.positions) ÷ 6)]
_approx(a, b; atol=1e-12) = length(a) == length(b) && all(isapprox.(a, b; atol=atol))

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
