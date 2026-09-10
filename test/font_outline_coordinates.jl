using Test
using Diff3D

@testset "Typeface endpoint-first curve commands" begin
    raw = Dict("resolution" => 1, "glyphs" => Dict(
        "Q" => Dict("ha" => 12, "o" => "m 1 2 q 9 4 3 10 b 2 1 11 12 -2 7"),
        "A" => Dict("ha" => 12, "o" => "m 0 0 q 10 0 5 10 l 0 0"),
        "B" => Dict("ha" => 12, "o" => "m 0 0 b 10 0 0 10 10 10 l 0 0")))
    font = Diff3D._font_data(raw)
    commands = font.glyphs["Q"].commands
    @test commands[2].points == [Vec2(3.0, 10.0), Vec2(9.0, 4.0)]
    @test commands[3].points == [Vec2(11.0, 12.0), Vec2(-2.0, 7.0), Vec2(2.0, 1.0)]
    curve = only(font_glyph_shapes(font, "Q"; curve_segments=2))
    @test curve == [Vec2(1.0, 2.0), Vec2(4.0, 6.5), Vec2(9.0, 4.0),
                    Vec2(4.75, 7.75), Vec2(2.0, 1.0)]

    for glyph in ("A", "B"), segments in (4, 8, 16)
        points = only(font_glyph_shapes(font, glyph; curve_segments=segments))
        area = abs(sum(points[i].x * points[i+1].y - points[i+1].x * points[i].y
                       for i in 1:length(points)-1)) / 2
        @test area > 25.0
        for depth in (0.0, 0.2)
            geometry = TextGeometry(font, glyph; curve_segments=segments, depth=depth)
            cap_area = 0.0
            for face in 1:geometry.n_faces
                a, b, c = get_face(geometry, face)
                p, q, r = get_vertex(geometry, a), get_vertex(geometry, b), get_vertex(geometry, c)
                cap_area += abs((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) / 2
            end
            @test cap_area ≈ area * (iszero(depth) ? 1 : 2)
        end
    end

    # Check the real vendored asset using the raw endpoint convention, without
    # relying on this package's parser to construct the expected points.
    asset = joinpath(@__DIR__, "..", "examples", "assets", "fonts", "optimer_bold.typeface.json")
    optimer = load_font(asset)
    for glyph in values(optimer.glyphs)
        tokens = split(glyph.outline)
        cursor = 1
        for command in glyph.commands
            kind = tokens[cursor]
            count = kind == "q" ? 4 : kind == "b" ? 6 : 2
            endpoint = Vec2(parse(Float64, tokens[cursor+1]), parse(Float64, tokens[cursor+2]))
            @test last(command.points) == endpoint
            cursor += count + 1
        end
        @test cursor == length(tokens) + 1
    end

    @test_throws "command q x must be finite" Diff3D._font_parse_outline("q Inf 0 1 2", "Q")
    @test_throws "command b control 2 y must be a number" Diff3D._font_parse_outline("b 1 2 3 4 5 bad", "B")
end
