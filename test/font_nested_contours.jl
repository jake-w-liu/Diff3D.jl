using Test
using Diff3D

@testset "Font contours retain islands within holes" begin
    function cap_area(geometry)
        area = 0.0
        for face in 1:geometry.n_faces
            a, b, c = get_face(geometry, face)
            p, q, r = get_vertex(geometry, a), get_vertex(geometry, b), get_vertex(geometry, c)
            area += abs((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) / 2
        end
        return area
    end
    loops = [[Vec2(low, low), Vec2(high, low), Vec2(high, high), Vec2(low, high)]
             for (low, high) in ((0.0, 10.0), (1.0, 9.0), (2.0, 8.0), (3.0, 7.0))]
    for order in ((1, 2, 3, 4), (4, 2, 1, 3)), reverse_winding in (false, true)
        ordered = [reverse_winding ? reverse(loops[i]) : loops[i] for i in order]
        outline = join((join(("$(j == 1 ? "m" : "l") $(p.x) $(p.y)"
                               for (j, p) in enumerate(loop)), " ") for loop in ordered), " ")
        font = Diff3D._font_data(Dict("resolution" => 1, "glyphs" => Dict(
            "I" => Dict("ha" => 12, "o" => outline))))
        groups = Diff3D._font_text_shape_groups(font, "I")
        @test length(groups) == 2
        @test all(group -> length(group.holes) == 1, groups)
        @test length(font_text_shapes(font, "I")) == 4
        @test cap_area(TextGeometry(font, "I")) ≈ 56.0
        @test cap_area(TextGeometry(font, "I"; depth=0.3)) ≈ 112.0
    end

    font = load_font(joinpath(@__DIR__, "..", "examples", "assets", "fonts", "optimer_bold.typeface.json"))
    for char in ("©", "®")
        loops = font_glyph_shapes(font, char; curve_segments=4)
        expected = abs(sum(sum(loop[i].x * loop[mod1(i+1, length(loop))].y -
                               loop[mod1(i+1, length(loop))].x * loop[i].y
                               for i in eachindex(loop)) / 2 for loop in loops))
        @test cap_area(TextGeometry(font, char; curve_segments=4)) ≈ expected atol=1e-12
    end
    # This glyph's central contour crosses itself at coarse curve sampling.
    # Verify the nesting independently of its separate tessellation behavior.
    theta_loops = font_glyph_shapes(font, "Θ"; curve_segments=4)
    theta_groups = Diff3D._font_text_shape_groups(font, "Θ"; curve_segments=4)
    island_points = Set((p.x, p.y) for p in theta_loops[3])
    @test length(theta_groups) == 2
    @test any(group -> Set((p.x, p.y) for p in group.outer) == island_points, theta_groups)
end
