using Test, Diff3D

# Index buffers below were printed by three.js r186 (`Array.from(geometry.index.array)`)
# and are zero-based; `.+ 1` converts them to Diff3D's one-based faces.
_audit3_indices(geo) = geo.indices[1:3geo.n_faces]
_audit3_close(a::Vec3, b::Vec3; atol=1e-12) =
    abs(a.x - b.x) <= atol && abs(a.y - b.y) <= atol && abs(a.z - b.z) <= atol

@testset "audit3 primitive triangulation matches three.js" begin
    # PlaneGeometry.js:85-95 emits (a, b, d), (b, c, d): each cell is split along
    # its (ix, iy+1)-(ix+1, iy) diagonal. The previous (a, d, b), (a, c, d)
    # split used the other diagonal, which changes a displaced plane's surface.
    # new THREE.PlaneGeometry(1, 1, 2, 1).index
    @test _audit3_indices(PlaneGeometry(width=1, height=1, width_segments=2,
                                        height_segments=1)) ==
          [0, 3, 1, 3, 4, 1, 1, 4, 2, 4, 5, 2] .+ 1

    # RingGeometry.js:108-124, new THREE.RingGeometry(0.5, 1, 3, 2).index
    @test _audit3_indices(RingGeometry(inner_radius=0.5, outer_radius=1.0,
                                       theta_segments=3, phi_segments=2)) ==
          [0, 4, 1, 4, 5, 1, 1, 5, 2, 5, 6, 2, 2, 6, 3, 6, 7, 3,
           4, 8, 5, 8, 9, 5, 5, 9, 6, 9, 10, 6, 6, 10, 7, 10, 11, 7] .+ 1

    # CylinderGeometry.js:156-178 (columns outermost, (a, b, d), (b, c, d)),
    # new THREE.CylinderGeometry(1, 1, 1, 3, 2).index[0:36]
    cyl = CylinderGeometry(radius_top=1.0, radius_bottom=1.0, height=1.0,
                           radial_segments=3, height_segments=2)
    @test _audit3_indices(cyl)[1:36] ==
          [0, 4, 1, 4, 5, 1, 4, 8, 5, 8, 9, 5, 1, 5, 2, 5, 6, 2,
           5, 9, 6, 9, 10, 6, 2, 6, 3, 6, 7, 3, 6, 10, 7, 10, 11, 7] .+ 1
    # CylinderGeometry.js:272-287 caps: (i, i + 1, c) on top and (i + 1, i, c)
    # at the bottom. Diff3D shares one center per cap (documented in
    # compatibility.md), so the top center is vertex 12 and its ring 13:16.
    @test _audit3_indices(cyl)[37:54] ==
          [13, 14, 12, 14, 15, 12, 15, 16, 12,
           19, 18, 17, 20, 19, 17, 21, 20, 17] .+ 1

    # new THREE.ConeGeometry(1, 1, 3, 2, true).index: the apex row keeps only
    # (b, c, d) (CylinderGeometry.js:169-176).
    @test _audit3_indices(ConeGeometry(radius=1.0, height=1.0, radial_segments=3,
                                       height_segments=2, open_ended=true)) ==
          [4, 5, 1, 4, 8, 5, 8, 9, 5, 5, 6, 2, 5, 9, 6, 9, 10, 6,
           6, 7, 3, 6, 10, 7, 10, 11, 7] .+ 1

    # SphereGeometry.js:134-140, new THREE.SphereGeometry(1, 3, 3).index
    @test _audit3_indices(SphereGeometry(radius=1.0, width_segments=3,
                                         height_segments=3)) ==
          [0, 4, 5, 1, 5, 6, 2, 6, 7, 5, 4, 9, 4, 8, 9, 6, 5, 10, 5, 9, 10,
           7, 6, 11, 6, 10, 11, 9, 8, 13, 10, 9, 14, 11, 10, 15] .+ 1

    # TorusGeometry.js:113-121, new THREE.TorusGeometry(1, 0.4, 2, 3).index
    @test _audit3_indices(TorusGeometry(radius=1.0, tube=0.4, radial_segments=2,
                                        tubular_segments=3)) ==
          [4, 0, 5, 0, 1, 5, 5, 1, 6, 1, 2, 6, 6, 2, 7, 2, 3, 7,
           8, 4, 9, 4, 5, 9, 9, 5, 10, 5, 6, 10, 10, 6, 11, 6, 7, 11] .+ 1

    # CircleGeometry.js:101-103, new THREE.CircleGeometry(1, 3).index
    @test _audit3_indices(CircleGeometry(radius=1.0, segments=3)) ==
          [1, 2, 0, 2, 3, 0, 3, 4, 0] .+ 1
end

# Per-side normals of a one-segment box in Diff3D's side order
# (+Z, -Z, +Y, -Y, +X, -X; four vertices each).
_audit3_box_side_normals(geo) =
    [Tuple(geo.normals[3(4side - 3) - 2:3(4side - 3)]) for side in 1:6]

@testset "audit3 BoxGeometry signed-size normals match three.js" begin
    # BoxGeometry.js:131 sets each side's normal to `depth > 0 ? 1 : -1`, where
    # `depth` is the signed offset passed to buildPlane (BoxGeometry.js:76-81:
    # width for px, -width for nx, and so on). Printed by three.js r186:
    # new THREE.BoxGeometry(-1, 2, 3).attributes.normal per side is
    # px (-1,0,0), nx (1,0,0), py (0,1,0), ny (0,-1,0), pz (0,0,1), nz (0,0,-1):
    # the mirrored x sides keep pointing away from the center.
    @test _audit3_box_side_normals(BoxGeometry(width=-1.0, height=2.0, depth=3.0)) ==
          [(0, 0, 1), (0, 0, -1), (0, 1, 0), (0, -1, 0), (-1, 0, 0), (1, 0, 0)]
    @test _audit3_box_side_normals(BoxGeometry(width=1.0, height=-2.0, depth=-3.0)) ==
          [(0, 0, -1), (0, 0, 1), (0, -1, 0), (0, 1, 0), (1, 0, 0), (-1, 0, 0)]
    # new THREE.BoxGeometry(1, 1, 0).attributes.normal: pz and nz are both
    # (0, 0, -1) because neither 0 nor -0 is > 0.
    @test _audit3_box_side_normals(BoxGeometry(width=1.0, height=1.0, depth=0.0)) ==
          [(0, 0, -1), (0, 0, -1), (0, 1, 0), (0, -1, 0), (1, 0, 0), (-1, 0, 0)]
    # Subdivided sides use the same rule. The +X side follows 2 * 12 (z sides)
    # and 2 * 9 (y sides) vertices and has 3 * 4 vertices of its own.
    seg = BoxGeometry(width=-2.0, height=1.0, depth=1.0, width_segments=2,
                      height_segments=3, depth_segments=2)
    plus_x = 43:54
    @test all(vi -> get_normal(seg, vi) == Vec3(-1.0, 0.0, 0.0), plus_x)
    @test all(vi -> get_vertex(seg, vi).x == -1.0, plus_x)

    # Edge vertices of subdivided sides land exactly on +/- half of each
    # dimension (BoxGeometry.js:111-115 places iy = gridY at
    # gridY * segmentHeight - heightHalf), so neighbouring sides share their
    # edges without sub-ulp cracks.
    sub = BoxGeometry(width=0.3, height=0.7, depth=1.1, width_segments=3,
                      height_segments=7, depth_segments=11)
    for (axis, half) in ((1, 0.15), (2, 0.35), (3, 0.55))
        coords = sub.positions[axis:3:end]
        @test all(c -> abs(abs(c) - half) > 1e-9 || abs(c) == half, coords)
    end
end

@testset "audit3 SphereGeometry ring radius is never negative (three.js)" begin
    # SphereGeometry.js:81-82: y = radius * cos(theta) and
    # ringRadius = sqrt(radius^2 - y^2) >= 0; SphereGeometry.js:113 normalizes
    # the vertex for its normal. Expected values come from that Float64 vertex
    # math evaluated in node for three.js r186 (the module itself stores Float32).
    # A sweep starting above the north pole folds back onto the sphere instead of
    # mirroring through the y axis.
    a = SphereGeometry(radius=1.0, width_segments=4, height_segments=2,
                       theta_start=-0.5, theta_length=1.5)
    # first vertex of each ring (ix = 0, phi = 0) and ix = 1 (phi = pi/2)
    @test _audit3_close(get_vertex(a, 1), Vec3(-0.47942553860420295, 0.8775825618903728, 0.0))
    @test _audit3_close(get_vertex(a, 2), Vec3(0.0, 0.8775825618903728, 0.47942553860420295))
    @test _audit3_close(get_vertex(a, 6), Vec3(-0.2474039592545231, 0.9689124217106447, 0.0))
    @test _audit3_close(get_vertex(a, 11), Vec3(-0.8414709848078964, 0.5403023058681398, 0.0))
    @test _audit3_close(get_normal(a, 1), Vec3(-0.47942553860420295, 0.8775825618903728, 0.0))

    # A negative radius mirrors only y; normals still point from the center to
    # the vertex: new SphereGeometry(-2, 4, 2) ring 1 is (-2, 0, 0), (0, 0, 2), ...
    b = SphereGeometry(radius=-2.0, width_segments=4, height_segments=2)
    @test _audit3_close(get_vertex(b, 1), Vec3(0.0, -2.0, 0.0))
    @test _audit3_close(get_vertex(b, 6), Vec3(-2.0, 0.0, 0.0))
    @test _audit3_close(get_vertex(b, 7), Vec3(0.0, 0.0, 2.0))
    @test _audit3_close(get_vertex(b, 15), Vec3(0.0, 2.0, 0.0))
    @test _audit3_close(get_normal(b, 1), Vec3(0.0, -1.0, 0.0))
    @test _audit3_close(get_normal(b, 6), Vec3(-1.0, 0.0, 0.0))
    for vi in 1:b.n_vertices
        @test _audit3_close(get_normal(b, vi), get_vertex(b, vi) / 2)
    end

    # new THREE.SphereGeometry(0, 3, 2).attributes.normal is all zeros:
    # normalizing a zero vertex leaves it zero (Vector3.normalize divides by
    # `length() || 1`).
    @test all(iszero, SphereGeometry(radius=0.0, width_segments=3, height_segments=2).normals)
end

@testset "audit3 TorusKnotGeometry uses three.js's secant tube frame" begin
    # TorusKnotGeometry.js:87-100: T = P2 - P1, N = P2 + P1 with P2 at u + 0.01,
    # B = T x N, N = B x T. Expected (vertex, normal) pairs are three.js r186's
    # vertex math evaluated in Float64 in node (the module stores Float32).
    function check(geo, expected)
        for (vi, pos, nrm) in expected
            @test _audit3_close(get_vertex(geo, vi), Vec3(pos...))
            @test _audit3_close(get_normal(geo, vi), Vec3(nrm...))
        end
    end
    # new TorusKnotGeometry(1, 0.4, 32, 6), vertices 0, 1, 9, 100
    check(TorusKnotGeometry(radius=1.0, tube=0.4, tubular_segments=32, radial_segments=6), [
        (1, (1.1000122498441418, -0.0027999514172262416, -0.0013999990414200576),
            (-0.9999693753896455, -0.006999878543065604, -0.003499997603550144)),
        (2, (1.300006124922071, 0.15352142370971414, -0.3105376344236816),
            (-0.49998468769482274, 0.38380355927428533, -0.776344086059204)),
        (10, (1.4672143894224339, 0.8092237583836515, 0.02656087205890395),
             (0.3981149463885975, 0.6686137586173936, -0.628060611127243)),
        (101, (0.900341108040821, -0.654069285265329, 0.24910443666257887),
              (0.8213333797270571, -0.2056538227883267, -0.5320883239826611))])
    # A negative p walks u backwards, which reverses the secant and mirrors the
    # tube: new TorusKnotGeometry(1, 0.4, 16, 4, -2, 3), vertices 0, 1, 7, 40.
    check(TorusKnotGeometry(radius=1.0, tube=0.4, tubular_segments=16, radial_segments=4,
                            p_val=-2, q_val=3), [
        (1, (1.1000122498441418, -0.0027999514172262416, 0.0013999990414200576),
            (-0.9999693753896455, -0.006999878543065604, 0.003499997603550144)),
        (2, (1.5, -0.17888782331480954, -0.35776968383261526),
            (0.0, -0.44721955828702387, -0.8944242095815381)),
        (8, (0.9732159415413203, -1.1692077031930521, 0.6519114184431913),
            (0.32702533829555874, -0.8170047424248885, 0.4749291304688699)),
        (41, (0.1000024032446894, 0.0007692043665694896, 0.0011536527287093195),
             (-0.9999939918882763, 0.0019230109164234174, 0.002884131821772839))])
    # A negative radius negates the curve: new TorusKnotGeometry(-1.5, 0.4, 12, 5),
    # vertices 0, 2, 20.
    check(TorusKnotGeometry(radius=-1.5, tube=0.4, tubular_segments=12, radial_segments=5), [
        (1, (-1.8500122498441418, 0.002799951417224663, 0.0013999990414192685),
            (0.9999693753896455, 0.0069998785430616575, 0.003499997603548171)),
        (3, (-2.5735968874178896, 0.10288241607918774, -0.211424366890769),
            (-0.8089922185447241, 0.2572060401979694, -0.5285609172269226)),
        (21, (1.8207755333558806, -0.23733725595501112, 0.7221776324516422),
             (0.8019388333897017, -0.5933431398875271, -0.06955591887089438))])
    # A zero radius collapses every vertex onto the origin with zero normals.
    zero = TorusKnotGeometry(radius=0.0, tube=0.4, tubular_segments=8, radial_segments=4)
    @test all(iszero, zero.positions)
    @test all(iszero, zero.normals)
    # Where three.js's secant is not finite (q / p overflows) the analytic frame
    # keeps the tube finite and unit-normal.
    tiny_p = TorusKnotGeometry(p_val=nextfloat(0.0), q_val=1.0, tubular_segments=8,
                               radial_segments=3)
    @test all(isfinite, tiny_p.positions)
    @test all(vi -> abs(norm(get_normal(tiny_p, vi)) - 1) < 1e-12, 1:tiny_p.n_vertices)
end

@testset "audit3 low segment counts are kept as in three.js" begin
    # CylinderGeometry.js, TorusGeometry.js and TorusKnotGeometry.js only
    # Math.floor their segment counts, so 1 and 2 are valid; only 0 (0/0 = NaN in
    # three.js) is raised to 1. Counts below from three.js r186 in node.
    # new THREE.TorusGeometry(1, 0.4, 1, 2): 6 vertices, 4 triangles.
    t = TorusGeometry(radius=1.0, tube=0.4, radial_segments=1, tubular_segments=2)
    @test (t.n_vertices, t.n_faces) == (6, 4)
    @test _audit3_close(get_vertex(t, 2), Vec3(-1.4, 1.4 * sin(π), 0.0))   # TorusGeometry.js:83-85
    # new THREE.TorusGeometry(1, 0.4, 3, 2): 12 vertices, 12 triangles.
    t32 = TorusGeometry(radius=1.0, tube=0.4, radial_segments=3, tubular_segments=2)
    @test (t32.n_vertices, t32.n_faces) == (12, 12)
    # new THREE.TorusKnotGeometry(1, 0.4, 2, 2): 9 vertices, 8 triangles.
    k = TorusKnotGeometry(radius=1.0, tube=0.4, tubular_segments=2, radial_segments=2)
    @test (k.n_vertices, k.n_faces) == (9, 8)
    @test (TorusKnotGeometry(tubular_segments=1, radial_segments=1).n_faces) == 2
    # new THREE.CylinderGeometry(1, 1, 1, 1): 4 side vertices + 2 caps of one
    # segment (three.js: 3 vertices each, Diff3D: the same since one center).
    c = CylinderGeometry(radial_segments=1)
    @test (c.n_vertices, c.n_faces) == (10, 4)
    # new THREE.CylinderGeometry(1, 0.5, 1, 2, 2): 12 triangles; Diff3D shares one
    # cap center, so 17 vertices instead of three.js's 19.
    c2 = CylinderGeometry(radius_top=1.0, radius_bottom=0.5, radial_segments=2,
                          height_segments=2)
    @test (c2.n_vertices, c2.n_faces) == (17, 12)
    # new THREE.ConeGeometry(1, 1, 2): 4 triangles.
    @test ConeGeometry(radius=1.0, height=1.0, radial_segments=2).n_faces == 4
    # Zero still clamps to one segment rather than producing NaN geometry.
    @test TorusGeometry(radial_segments=0).n_faces == 2 * 48
    @test !any(isnan, CylinderGeometry(radial_segments=0).positions)
end

function _audit3_tangent_fixture()
    # Mirrored UVs on face 1 (handedness -1), a zero-area UV face (3, 3, 5),
    # an unreferenced vertex 6, and non-unit normals.
    return BufferGeometry([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0.2, 2, 0.5, 0.3, 5, 5, 5.0],
                          [0, 0, 1, 0, 0.1, 2, 0.1, 0, 1, 0, 0, 1, -0.2, 0, 1, 0, 1, 0.0],
                          [1, 0, 0, 0, 0, 1, 1, 1, 0.5, 0.5, 0.3, 0.3],
                          [0, 1, 2, 1, 4, 2, 0, 2, 3, 2, 2, 4] .+ 1, 6, 4)
end

@testset "audit3 compute_tangents! matches three.js computeTangents" begin
    # Expected values: three.js r186 BufferGeometry.computeTangents
    # (BufferGeometry.js:837-994) run in node on the same Float64 attributes,
    # index [0,1,2, 1,4,2, 0,2,3, 2,2,4].
    g = _audit3_tangent_fixture()
    @test Diff3D.compute_tangents!(g) === g
    t = get_attribute(g, :tangent)
    @test t.item_size == 4
    @test t.data == [-1, 0, 0, -1,
                     0.48482034916712063, -0.05817844190005447, -0.8726766285008171, 1,
                     -1, 0, 0, -1, -1, 0, 0, -1,
                     0.9813137496771571, 0, 0.1924144607210112, 1,
                     0, 0, 0, 0]

    # Groups restrict the visited faces (BufferGeometry.js:923-944):
    # addGroup(0, 3) and addGroup(6, 3) cover faces 1 and 3 only.
    grouped = _audit3_tangent_fixture()
    add_group!(grouped, 1, 1, 0)
    add_group!(grouped, 3, 1, 0)
    Diff3D.compute_tangents!(grouped)
    @test get_attribute(grouped, :tangent).data ==
          [-1, 0, 0, -1, -1, 0, 0, -1, -0.9950371902099893, 0, 0.09950371902099893, -1,
           -1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 0, 0]

    # A matching Float64 attribute is updated in place, so vertices no face
    # references keep their previous tangent, as three.js reuses an attribute of
    # the same count.
    reuse = _audit3_tangent_fixture()
    previous = fill(7.0, 24)
    set_attribute!(reuse, :tangent, previous, 4)
    Diff3D.compute_tangents!(reuse)
    @test get_attribute(reuse, :tangent).data === previous
    @test previous[21:24] == [7, 7, 7, 7]
    @test previous[1:20] == get_attribute(g, :tangent).data[1:20]
    # A tangent attribute of another shape is replaced.
    wrong = _audit3_tangent_fixture()
    set_attribute!(wrong, :tangent, ones(18), 3)
    Diff3D.compute_tangents!(wrong)
    @test get_attribute(wrong, :tangent).item_size == 4
    @test get_attribute(wrong, :tangent).data == get_attribute(g, :tangent).data

    # Generated geometry: three.js inputs are Float32, hence the tolerance.
    # new SphereGeometry(1, 6, 4) tangents of vertices 7, 8, 9 (zero-based).
    sphere = Diff3D.compute_tangents!(SphereGeometry(radius=1.0, width_segments=6,
                                                     height_segments=4))
    @test isapprox(get_attribute(sphere, :tangent).data[29:40],
                   [0.26726124558335396, 0.2672612272874291, 0.9258201029347177, 1,
                    0.8986320971091855, 0.07497795298998845, 0.43224837837819413, 1,
                    0.8236541194119749, 0.0749780031163358, -0.5621140370284052, 1];
                   atol=1e-6)
    # new TorusGeometry(1, 0.4, 3, 5) tangents of vertices 6, 7.
    torus = Diff3D.compute_tangents!(TorusGeometry(radius=1.0, tube=0.4, radial_segments=3,
                                                   tubular_segments=5))
    @test isapprox(get_attribute(torus, :tangent).data[25:32],
                   [-0.46120655550920386, 0.8463951126703834, -0.26627772419604456, 1,
                    -0.9300768532855077, 0.3657062793389924, 0.03487067872237613, 1];
                   atol=1e-6)

    # three.js logs and returns without index, normal or uv
    # (BufferGeometry.js:845-855); Diff3D raises instead.
    @test_throws ArgumentError Diff3D.compute_tangents!(BufferGeometry())
    no_uv = _audit3_tangent_fixture(); empty!(no_uv.uvs)
    @test_throws ArgumentError Diff3D.compute_tangents!(no_uv)
    no_normal = _audit3_tangent_fixture(); empty!(no_normal.normals)
    @test_throws ArgumentError Diff3D.compute_tangents!(no_normal)
    bad_group = _audit3_tangent_fixture()
    add_group!(bad_group, 4, 2, 0)
    @test_throws ArgumentError Diff3D.compute_tangents!(bad_group)
    bad_index = _audit3_tangent_fixture(); bad_index.indices[1] = 99
    @test_throws ArgumentError Diff3D.compute_tangents!(bad_index)
end
