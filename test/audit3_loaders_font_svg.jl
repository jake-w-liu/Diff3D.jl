using Test, Diff3D

function _audit3_svg_document(source::AbstractString; kwargs...)
    return mktempdir() do directory
        path = joinpath(directory, "doc.svg")
        write(path, source)
        load_svg(path; kwargs...)
    end
end

@testset "SVG arc flags may run into the next number" begin
    # SVG path grammar: a flag is the single character 0 or 1, so
    # "0110 10" reads large-arc=0, sweep=1, endpoint (10, 10). three.js
    # SVGLoader.js:504/696 parses arcs with parseFloats(data, [3, 4], 7) for
    # the same reason; its oracle ends this arc at (10, 10).
    compact = Diff3D._svg_path_points("M0 0a10 10 0 0110 10", 4)
    spaced = Diff3D._svg_path_points("M0 0a10 10 0 0 1 10 10", 4)
    @test length(compact) == 1
    @test compact[1].points == spaced[1].points
    @test last(compact[1].points) == Vec2(10.0, 10.0)
    # Both flags glued to a fractional coordinate, then an implicit repeat.
    glued = Diff3D._svg_path_points("M0 0A5 5 0 11.5 2 5 5 0 0 0 3 3", 4)
    reference = Diff3D._svg_path_points("M0 0A5 5 0 1 1 .5 2 5 5 0 0 0 3 3", 4)
    @test glued[1].points == reference[1].points
    @test last(glued[1].points) == Vec2(3.0, 3.0)
    # A flag must still be exactly 0 or 1.
    @test_throws "large-arc flag" Diff3D._svg_path_points("M0 0A5 5 0 2 1 3 3", 4)
    @test_throws "sweep flag" Diff3D._svg_path_points("M0 0A5 5 0 1 .5 3 3", 4)
    @test_throws "large-arc flag" Diff3D._svg_path_points("M0 0A5 5 0 1e2 3 3", 4)
    @test_throws "missing numbers" Diff3D._svg_path_points("M0 0A5 5 0 1", 4)
end
