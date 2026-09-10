using Test
using Diff3D

@testset "SVG closepath state" begin
    origin = Vec2(1.0, 2.0)
    for close in ("Z", "z")
        prefix = "M1 2 L2 2 L2 3 $close"
        for (continuation, endpoint) in (
            ("L4 5", Vec2(4.0, 5.0)),
            ("l3 3", Vec2(4.0, 5.0)),
            ("H4", Vec2(4.0, 2.0)),
            ("v3", Vec2(1.0, 5.0)),
            ("C2 2 3 4 4 5", Vec2(4.0, 5.0)),
            ("s2 2 3 3", Vec2(4.0, 5.0)),
            ("Q2 4 4 5", Vec2(4.0, 5.0)),
            ("t3 3", Vec2(4.0, 5.0)),
            ("A2 2 0 0 1 4 5", Vec2(4.0, 5.0)),
        )
            paths = Diff3D._svg_path_points("$prefix $continuation", 4)
            @test length(paths) == 2
            if length(paths) == 2
                @test paths[1].closed
                @test !paths[2].closed
                @test first(paths[2].points) == origin
                @test last(paths[2].points) == endpoint
            end
        end
        moved = Diff3D._svg_path_points("$prefix M7 8 l2 0", 4)
        @test length(moved) == 2
        @test moved[2].points == [Vec2(7.0, 8.0), Vec2(9.0, 8.0)]
        closed_again = Diff3D._svg_path_points("$prefix L4 5 L1 5 Z", 4)
        @test length(closed_again) == 2
        @test closed_again[2].closed
        @test closed_again[2].points == [origin, Vec2(4.0, 5.0), Vec2(1.0, 5.0)]
        @test length(Diff3D._svg_path_points("$prefix Z z", 4)) == 1
        for suffix in ("4 0", "-1.5,2", ".5 1", "1e2 2e1")
            @test_throws ErrorException Diff3D._svg_path_points("$prefix $suffix", 4)
        end
    end

    mktempdir() do directory
        path = joinpath(directory, "continued.svg")
        write(path, """
            <svg width="10" height="10">
              <path fill="none" stroke="red" d="M1 2L2 2L2 3Z L4 5"/>
            </svg>
            """)
        document = load_svg(path)
        @test length(document.paths) == 2
        strokes = svg_strokes(document)
        @test length(strokes) == 2
        @test strokes[1] isa LineLoop
        @test strokes[2] isa LineObject
        @test get_vertex(strokes[2].geometry, 1) == Vec3(1.0, 2.0, 0.0)
        @test get_vertex(strokes[2].geometry, 2) == Vec3(4.0, 5.0, 0.0)
    end
end
