using Test, Diff3D
using Diff3D: Vec2, Vec3

function _geometry_audit_degenerate_faces(geo)
    count = 0
    for f in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, f)
        a, b, c = get_vertex(geo, i1), get_vertex(geo, i2), get_vertex(geo, i3)
        norm(cross(b - a, c - a)) < 1e-12 && (count += 1)
    end
    return count
end

_geometry_audit_close(a, b; atol=1e-12) = norm(a - b) <= atol

@testset "geometry audit: cylinder/cone zero-radius poles" begin
    # three.js CylinderGeometry.js:169/176 skips torso triangles on a zero radius.
    cone = ConeGeometry(radius=1.0, height=2.0, radial_segments=8)
    @test cone.n_faces == 16
    @test _geometry_audit_degenerate_faces(cone) == 0
    @test all(1 <= i <= cone.n_vertices for i in cone.indices)
    tall = ConeGeometry(radius=1.0, height=2.0, radial_segments=6, height_segments=3)
    @test tall.n_faces == 2 * 6 * 3 - 6 + 6
    @test _geometry_audit_degenerate_faces(tall) == 0
    open_cone = ConeGeometry(radius=1.0, radial_segments=5, open_ended=true)
    @test open_cone.n_faces == 5
    inverted = CylinderGeometry(radius_top=1.0, radius_bottom=0.0, radial_segments=7,
                                height_segments=2)
    @test inverted.n_faces == 2 * 7 * 2 - 7 + 7
    @test _geometry_audit_degenerate_faces(inverted) == 0
    spindle = CylinderGeometry(radius_top=0.0, radius_bottom=0.0, radial_segments=4,
                               height_segments=2)
    @test spindle.n_faces == 2 * 4 * 2 - 8
    @test length(spindle.indices) == 3 * spindle.n_faces
end

@testset "geometry audit: cylinder cap uvs" begin
    rs = 4
    cyl = CylinderGeometry(radius_top=1.0, radius_bottom=1.0, height=1.0,
                           radial_segments=rs)
    side = 2 * (rs + 1)
    for (cap, sign) in ((0, 1.0), (1, -1.0))
        base = side + cap * (rs + 2) + 1          # cap center
        @test cyl.uvs[2base - 1] == 0.5 && cyl.uvs[2base] == 0.5
        for x in 0:rs
            vi = base + 1 + x
            θ = x / rs * 2π
            p = get_vertex(cyl, vi)
            @test p.x ≈ sin(θ) atol=1e-12
            @test p.z ≈ cos(θ) atol=1e-12
            # three.js CylinderGeometry.js:260-261
            @test cyl.uvs[2vi - 1] ≈ cos(θ) * 0.5 + 0.5 atol=1e-12
            @test cyl.uvs[2vi] ≈ sin(θ) * 0.5 * sign + 0.5 atol=1e-12
        end
    end
end

@testset "geometry audit: sphere pole uv offset" begin
    ws, hs = 8, 4
    g = SphereGeometry(radius=1.0, width_segments=ws, height_segments=hs)
    row = ws + 1
    for i in 0:ws
        top = i + 1
        bottom = hs * row + i + 1
        mid = 2 * row + i + 1
        @test g.uvs[2top - 1] ≈ (i + 0.5) / ws        # SphereGeometry.js:88-96
        @test g.uvs[2bottom - 1] ≈ (i - 0.5) / ws
        @test g.uvs[2mid - 1] ≈ i / ws
    end
end

@testset "geometry audit: capsule matches three.js r186 layout" begin
    cap = CapsuleGeometry()
    @test cap.n_vertices == (8 + 1) * (2 * 4 + 1 + 1)
    @test cap.n_faces == 2 * 8 * (2 * 4 + 1)
    r, len, cs, rs, hs = 0.5, 2.0, 3, 6, 2
    g = CapsuleGeometry(radius=r, length=len, cap_segments=cs, radial_segments=rs,
                        height_segments=hs)
    rows = 2cs + hs
    row = rs + 1
    @test g.n_vertices == row * (rows + 1)
    total = 2 * (π / 2) * r + len
    for iy in 0:rows
        arc = iy <= cs ? iy / cs * (π / 2) * r :
              iy <= cs + hs ? (π / 2) * r + (iy - cs) / hs * len :
              (π / 2) * r + len + (iy - cs - hs) / cs * (π / 2) * r
        off = iy == 0 ? 0.5 / rs : iy == rows ? -0.5 / rs : 0.0
        for ix in 0:rs
            vi = iy * row + ix + 1
            @test g.uvs[2vi] ≈ arc / total atol=1e-12
            @test g.uvs[2vi - 1] ≈ ix / rs + off atol=1e-12
            p = get_vertex(g, vi)
            θ = ix / rs * 2π
            ρ = hypot(p.x, p.z)
            ρ > 1e-9 && @test p.x ≈ -ρ * cos(θ) atol=1e-9
        end
    end
    @test get_vertex(g, 1).y ≈ -(len / 2 + r)
    @test get_vertex(g, g.n_vertices).y ≈ len / 2 + r
    outward = 0
    for f in 1:g.n_faces
        i1, i2, i3 = get_face(g, f)
        a, b, c = get_vertex(g, i1), get_vertex(g, i2), get_vertex(g, i3)
        fn = cross(b - a, c - a)
        norm(fn) < 1e-12 && continue
        @test dot(fn, get_normal(g, i1) + get_normal(g, i2) + get_normal(g, i3)) > 0
        outward += 1
    end
    @test outward == g.n_faces - 2rs
end

@testset "geometry audit: polyhedron normals and uvs" begin
    # three.js PolyhedronGeometry.js:66-74: detail 0 is flat shaded.
    for geo in (TetrahedronGeometry(), OctahedronGeometry(), IcosahedronGeometry(),
                DodecahedronGeometry(radius=2.0))
        for f in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, f)
            fn = normalize(compute_face_normal(geo, f))
            for i in (i1, i2, i3)
                @test _geometry_audit_close(get_normal(geo, i), fn)
            end
        end
    end
    smooth = IcosahedronGeometry(radius=2.0, detail=1)
    for vi in 1:smooth.n_vertices
        @test _geometry_audit_close(get_normal(smooth, vi), normalize(get_vertex(smooth, vi)))
    end
    # Azimuth atan2(z, -x) (PolyhedronGeometry.js:308) and seam correction.
    octa = OctahedronGeometry()
    for f in 1:octa.n_faces
        ids = get_face(octa, f)
        us = [octa.uvs[2i - 1] for i in ids]
        @test maximum(us) - minimum(us) <= 0.5 + 1e-12
        for i in ids
            p = get_vertex(octa, i)
            @test octa.uvs[2i] ≈ asin(p.y) / π + 0.5 atol=1e-12
            if !(p.x == 0 && p.z == 0)
                u = atan(p.z, -p.x) / 2 / π + 0.5
                @test any(isapprox(octa.uvs[2i - 1], u + k; atol=1e-12) for k in (-1, 0, 1))
            end
        end
    end
    # Octahedron vertex (0,0,1): azimuth atan2(1, -0) = π/2 -> u = 0.75.
    found = false
    for vi in 1:octa.n_vertices
        p = get_vertex(octa, vi)
        if _geometry_audit_close(p, Vec3(0.0, 0.0, 1.0))
            @test octa.uvs[2vi - 1] ≈ 0.75
            found = true
        end
    end
    @test found
    # Pole vertices take the face centroid azimuth (correctUV).
    for f in 1:octa.n_faces
        ids = get_face(octa, f)
        c = sum(get_vertex(octa, i) for i in ids)
        for i in ids
            p = get_vertex(octa, i)
            if p.x == 0 && p.z == 0
                u = atan(c.z, -c.x) / 2 / π + 0.5
                @test octa.uvs[2i - 1] ≈ u || octa.uvs[2i - 1] ≈ u + 1
            end
        end
    end
    @test all(isfinite, OctahedronGeometry(radius=0.0).normals)
    @test all(isfinite, TetrahedronGeometry(radius=-1.0).uvs)
end

@testset "geometry audit: merge_vertices" begin
    box = BoxGeometry()
    @test merge_vertices(box).n_vertices == 24
    bare = BufferGeometry(copy(box.positions), Float64[], Float64[], copy(box.indices),
                          box.n_vertices, box.n_faces)
    welded = merge_vertices(bare)
    @test welded.n_vertices == 8
    @test welded.n_faces == 12
    @test isempty(welded.normals) && isempty(welded.uvs)
    for f in 1:box.n_faces
        a = get_face(bare, f); b = get_face(welded, f)
        for k in 1:3
            @test get_vertex(bare, a[k]) == get_vertex(welded, b[k])
        end
    end

    tet = TetrahedronGeometry()
    soup = BufferGeometry(copy(tet.positions), Float64[], Float64[], Int[],
                          tet.n_vertices, 0)
    tet_welded = merge_vertices(soup)
    @test tet_welded.n_vertices == 4
    @test length(tet_welded.indices) == 12

    near = BufferGeometry([0.0, 0, 0, 1e-6, 0, 0, 1, 0, 0], Float64[], Float64[],
                          [1, 2, 3], 3, 1)
    @test merge_vertices(near).n_vertices == 2
    @test merge_vertices(near; tolerance=1e-8).n_vertices == 3
    @test_throws ArgumentError merge_vertices(near; tolerance=NaN)

    colored = BufferGeometry(copy(bare.positions), Float64[], Float64[],
                             copy(bare.indices), bare.n_vertices, bare.n_faces)
    colors = repeat([1.0, 0.0, 0.0], bare.n_vertices)
    colors[1:12] .= 0.5                                  # first face's 4 vertices differ
    set_attribute!(colored, :color, colors, 3)
    set_attribute!(colored, :morphPosition0, collect(1.0:3 * bare.n_vertices), 3)
    add_group!(colored, 1, 6, 0)
    set_draw_range!(colored, 1, 30)
    cw = merge_vertices(colored)
    @test cw.n_vertices == 12
    @test get_attribute(cw, :color).item_size == 3
    @test length(get_attribute(cw, :morphPosition0).data) == 3 * cw.n_vertices
    @test get_groups(cw) == [(1, 6, 0)]
    @test get_draw_range(cw) == (1, 30)
    @test_throws ArgumentError merge_vertices(BufferGeometry([0.0, 0, 0], [0.0], Float64[],
                                                             Int[], 1, 0))
end

@testset "geometry audit: closed TubeGeometry" begin
    square = [Vec3(0.0, 0, 0), Vec3(1.0, 0, 0), Vec3(1.0, 1, 0), Vec3(0.0, 1, 0)]
    open_tube = TubeGeometry(square; radius=0.1, radial_segments=6)
    tube = TubeGeometry(square; radius=0.1, radial_segments=6, closed=true)
    rs1 = 7
    @test open_tube.n_faces == 2 * 3 * 6
    @test tube.n_vertices == 5 * rs1
    @test tube.n_faces == 2 * 4 * 6
    @test TubeGeometry([square; square[1:1]]; radius=0.1, radial_segments=6,
                       closed=true).n_vertices == tube.n_vertices
    @test_throws ArgumentError TubeGeometry(square[1:2]; closed=true)
    # three.js TubeGeometry.js:114 duplicates the first ring with u = 1.
    for j in 1:rs1
        @test get_vertex(tube, j) == get_vertex(tube, 4 * rs1 + j)
        @test get_normal(tube, j) == get_normal(tube, 4 * rs1 + j)
        @test tube.uvs[2(4 * rs1 + j) - 1] == 1.0
    end
    # The closed path uses wrap-around tangents: the first ring is perpendicular to
    # the chord from the last point to the second one.
    t1 = normalize(square[2] - square[4])
    for j in 1:rs1
        @test abs(dot(get_vertex(tube, j) - square[1], t1)) < 1e-12
    end

    # Non-planar loop: twist correction keeps the seam continuous.
    m = 48
    knot = [Vec3((2 + cos(3t)) * cos(2t), (2 + cos(3t)) * sin(2t), sin(3t))
            for t in range(0, 2π; length=m + 1)[1:m]]
    kt = TubeGeometry(knot; radius=0.2, radial_segments=8, closed=true)
    row = 9
    jumps = [acos(clamp(dot(get_normal(kt, (r - 1) * row + 1),
                            get_normal(kt, r * row + 1)), -1.0, 1.0)) for r in 1:m]
    @test maximum(jumps) < 0.6
    @test maximum(jumps) - minimum(jumps) < 0.5
    for f in 1:kt.n_faces
        i1, i2, i3 = get_face(kt, f)
        a, b, c = get_vertex(kt, i1), get_vertex(kt, i2), get_vertex(kt, i3)
        @test dot(cross(b - a, c - a), get_normal(kt, i1) + get_normal(kt, i2) +
                                       get_normal(kt, i3)) > 0
    end
end
