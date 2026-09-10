using Test
using Diff3D

@testset "Font triangulation preserves collinear boundary area" begin
    function triangle_area(points, triangles)
        sum(abs((points[b].x-points[a].x)*(points[c].y-points[a].y) -
                (points[b].y-points[a].y)*(points[c].x-points[a].x))/2
            for (a, b, c) in triangles; init=0.0)
    end
    boundary = [Vec2(0.0, 0.0), Vec2(1.0, 0.0), Vec2(1.0, 0.5),
                Vec2(1.0, 0.4), Vec2(1.0, 1.0), Vec2(0.0, 1.0)]
    notch = [Vec2(0.0, 0.0), Vec2(3.0, 0.0), Vec2(3.0, 1.5),
             Vec2(3.0, 1.4), Vec2(3.0, 3.0), Vec2(2.0, 3.0),
             Vec2(2.0, 1.0), Vec2(1.0, 1.0), Vec2(1.0, 3.0), Vec2(0.0, 3.0)]
    for (polygon, expected) in ((boundary, 1.0), (notch, 7.0)), reverse_winding in (false, true)
        source = reverse_winding ? reverse(polygon) : polygon
        points, triangles = Diff3D._font_triangulate_simple(source)
        @test triangle_area(points, triangles) ≈ expected atol=1e-12
        @test length(points) == length(polygon)
    end

    font = load_font(joinpath(@__DIR__, "..", "examples", "assets", "fonts", "optimer_bold.typeface.json"))
    # Independent three.js Earcut3.0.2 outputs were checked against signed
    # contour areas; these glyphs have collinear reversals and no proper crossings.
    for (char, expected) in (("¹", 0.0856735), ("½", 0.277322375))
        groups = Diff3D._font_text_shape_groups(font, char; curve_segments=4)
        actual = 0.0
        for group in groups
            points, triangles = Diff3D._font_triangulate_group(group.outer, group.holes)
            actual += triangle_area(points, triangles)
        end
        @test actual ≈ expected atol=1e-12
    end
end
