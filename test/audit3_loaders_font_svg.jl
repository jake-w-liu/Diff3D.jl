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

@testset "SVG use renders referenced content as a child of use" begin
    # SVG 1.1 section 5.6 and three.js SVGLoader.js:218-226 (parseStyle on the
    # use node, then parseNode(usedNode, style) under the use transform): the
    # referenced element keeps its own transform and presentation attributes,
    # inherits everything else from `use`, and ignores its original ancestors.
    doc = _audit3_svg_document("""
        <svg xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100">
          <g transform="translate(100,0)" fill="green" stroke="black">
            <rect id="r" x="1" y="2" width="10" height="5" fill="red"/>
            <rect id="s" x="1" y="2" width="10" height="5"/>
          </g>
          <use xlink:href="#r" x="5" fill="blue" stroke="yellow"/>
          <use xlink:href="#s" x="5" y="1" fill="blue"/>
          <g transform="scale(3)"><use xlink:href="#s" transform="translate(1,1)"/></g>
        </svg>
        """)
    @test length(doc.paths) == 5
    # Oracle (three.js r186, xmldom): first points [101,2], [101,2], [6,2],
    # [6,3], [6,9]; fills red, green, red, blue, #000; strokes black, black,
    # yellow, none, none.
    @test [first(p.points) for p in doc.paths] ==
          [Vec2(101.0, 2.0), Vec2(101.0, 2.0), Vec2(6.0, 2.0), Vec2(6.0, 3.0),
           Vec2(6.0, 9.0)]
    @test [p.style.fill for p in doc.paths] ==
          [Color3(1.0, 0.0, 0.0), Color3(0.0, 128 / 255, 0.0), Color3(1.0, 0.0, 0.0),
           Color3(0.0, 0.0, 1.0), Color3(0.0, 0.0, 0.0)]
    @test [p.style.stroke for p in doc.paths] ==
          [Color3(0.0, 0.0, 0.0), Color3(0.0, 0.0, 0.0), Color3(1.0, 1.0, 0.0),
           nothing, nothing]
end

@testset "SVG use keeps referenced elements separate and rejects cycles" begin
    # Each referenced element stays its own fill element, so a small rect
    # drawn over a large one in a used group is not cut out as a hole
    # (three.js creates one ShapePath per element, SVGLoader.js:241-256).
    doc = _audit3_svg_document("""
        <svg width="20" height="20">
          <use href="#pair" x="1"/>
          <defs><g id="pair">
            <rect width="10" height="10"/><rect x="2" y="2" width="2" height="2"/>
          </g></defs>
        </svg>
        """)
    @test length(doc.paths) == 2
    @test doc.paths[1].element_id != doc.paths[2].element_id
    @test first(doc.paths[1].points) == Vec2(1.0, 0.0)
    area = 0.0
    geometry = svg_geometry(doc)
    for face in 1:geometry.n_faces
        a, b, c = get_face(geometry, face)
        p, q, r = get_vertex(geometry, a), get_vertex(geometry, b), get_vertex(geometry, c)
        area += abs((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) / 2
    end
    @test area ≈ 104.0
    @test_throws "circular reference" _audit3_svg_document(
        """<svg><g id="a"><use href="#a"/></g></svg>""")
    @test_throws "circular reference" _audit3_svg_document(
        """<svg><g id="a"><use href="#b"/></g><g id="b"><use href="#a"/></g></svg>""")
    @test_throws "SVG use references unknown id" _audit3_svg_document(
        """<svg><use href="#missing"/></svg>""")
end
