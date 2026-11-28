using Test, Diff3D

@testset "RoundedBoxGeometry UVs span the flat strip of every side" begin
    # three.js RoundedBoxGeometry.js getUv: along a side of length L with corner
    # radius r, the flat strip runs from arcUv to 1 - arcUv, where
    # arcUv = (π r / 4) / (π r / 2 + L - 2r). On the two grid lines bounding
    # the strip the branch used to be chosen from rounding noise, so both
    # lines got the same coordinate and the strip had no UV extent.
    width, height, depth, radius = 2.0, 1.5, 1.0, 0.3
    arc_uv(side) = (π * radius / 4) / (π * radius / 2 + side - 2radius)
    for segments in (1, 2, 3, 5)
        g = RoundedBoxGeometry(; width, height, depth, segments, radius)
        per_side = g.n_vertices ÷ 6
        # side => (constant axis, its value, axis along u, axis along v)
        sides = ((1, width / 2, 3, 2), (1, -width / 2, 3, 2), (2, height / 2, 1, 3),
                 (2, -height / 2, 1, 3), (3, depth / 2, 1, 2), (3, -depth / 2, 1, 2))
        lengths = (width, height, depth)
        for (side, (axis, plane, u_axis, v_axis)) in enumerate(sides)
            u_values = Set{Float64}()
            v_values = Set{Float64}()
            for v in ((side - 1) * per_side + 1):(side * per_side)
                position = (g.positions[3v - 2], g.positions[3v - 1], g.positions[3v])
                abs(position[axis] - plane) < 1e-9 || continue     # flat part only
                push!(u_values, round(g.uvs[2v - 1]; digits=9))
                push!(v_values, round(g.uvs[2v]; digits=9))
            end
            u_low = arc_uv(lengths[u_axis])
            v_low = arc_uv(lengths[v_axis])
            @test sort!(collect(u_values)) ≈ [u_low, 1 - u_low] atol=1e-9
            @test sort!(collect(v_values)) ≈ [v_low, 1 - v_low] atol=1e-9
        end
    end
    # Front (+z) side: three.js r186 under node prints u = 0.125916 at x = -0.7
    # and 0.874084 at x = +0.7 for segments 1, 2 and 3 (Float32 attributes).
    g = RoundedBoxGeometry(; width, height, depth, segments=2, radius)
    per_side = g.n_vertices ÷ 6
    for v in (4per_side + 1):(5per_side)
        abs(g.positions[3v] - depth / 2) < 1e-9 || continue
        expected = g.positions[3v - 2] < 0 ? 0.125916 : 0.874084
        @test g.uvs[2v - 1] ≈ expected atol=1e-6
    end
end

@testset "CatmullRomCurve with a repeated control point follows three.js" begin
    # CatmullRomCurve3.js:230-237 replaces a zero middle interval by 1 and a
    # zero outer interval by the middle one. Oracle: three.js r186 under node,
    # points (0,0,0), (1,0,0), (1,0,0), (2,1,0), getPoint at 0.2, 0.5, 0.8.
    points = [Vec3(0.0, 0, 0), Vec3(1.0, 0, 0), Vec3(1.0, 0, 0), Vec3(2.0, 1, 0)]
    oracle = (
        centripetal=((0.6720000000000002, 0.0, 0.0),
                     (1.0144862459854176, -0.04801375401458243, 0.0),
                     (1.3280000000000005, 0.32800000000000035, 0.0)),
        chordal=((0.6720000000000002, 0.0, 0.0),
                 (1.0258883476483185, -0.036611652351681546, 0.0),
                 (1.3280000000000005, 0.32800000000000035, 0.0)),
        catmullrom=((0.6720000000000002, 0.0, 0.0), (1.0, -0.0625, 0.0),
                    (1.3280000000000005, 0.32800000000000035, 0.0)),
    )
    for curve_type in (:centripetal, :chordal, :catmullrom)
        curve = CatmullRomCurve(points; curve_type)
        for (t, expected) in zip((0.2, 0.5, 0.8), oracle[curve_type])
            p = get_point(curve, t)
            @test p.x ≈ expected[1] atol=1e-12
            @test p.y ≈ expected[2] atol=1e-12
            @test p.z ≈ expected[3] atol=1e-12
        end
    end
    # Repeated first and last points (zero outer intervals) stay finite and
    # pass through the control points.
    doubled = [Vec3(0.0, 0, 0), Vec3(0.0, 0, 0), Vec3(1.0, 2, 0), Vec3(3.0, 2, 1),
               Vec3(3.0, 2, 1)]
    for curve_type in (:centripetal, :chordal)
        curve = CatmullRomCurve(doubled; curve_type)
        samples = [get_point(curve, t) for t in range(0.0, 1.0; length=41)]
        @test all(p -> isfinite(p.x) && isfinite(p.y) && isfinite(p.z), samples)
        @test samples[1] == doubled[1]
        @test samples[end] == doubled[end]
    end
    # Distinct points are unaffected by the repeated-point rule: scaling the
    # control points scales the curve (the documented scale-relative rule).
    base = [Vec3(0.0, 0, 0), Vec3(1.0, 0.5, 0), Vec3(2.0, -0.5, 1), Vec3(3.0, 0, 0)]
    for curve_type in (:centripetal, :chordal)
        unit = get_point(CatmullRomCurve(base; curve_type), 0.37)
        tiny = get_point(CatmullRomCurve([p * 1e-9 for p in base]; curve_type), 0.37)
        @test tiny.x ≈ unit.x * 1e-9 rtol=1e-9
        @test tiny.y ≈ unit.y * 1e-9 rtol=1e-9
        @test tiny.z ≈ unit.z * 1e-9 rtol=1e-9
    end
end

@testset "line3_center keeps the element type" begin
    single = Line3(Vec3(1.0f0, 2.0f0, 3.0f0), Vec3(4.0f0, 6.0f0, 9.0f0))
    @test line3_center(single) === Vec3(2.5f0, 4.0f0, 6.0f0)
    @test @inferred(line3_center(single)) isa Vec3{Float32}
    @test line3_center(Line3(Vec3(1.0, 2.0, 3.0), Vec3(4.0, 6.0, 9.0))) === Vec3(2.5, 4.0, 6.0)
    @test line3_center(Line3(Vec3(1, 2, 3), Vec3(4, 6, 9))) === Vec3(2.5, 4.0, 6.0)
    big_line = Line3(Vec3(big(1.0), big(2.0), big(3.0)), Vec3(big(4.0), big(6.0), big(9.0)))
    @test line3_center(big_line) isa Vec3{BigFloat}
    # The midpoint of two huge values must not overflow.
    huge = Line3(Vec3(floatmax(), 0.0, 0.0), Vec3(floatmax(), 2.0, 0.0))
    @test line3_center(huge) === Vec3(floatmax(), 1.0, 0.0)
end
