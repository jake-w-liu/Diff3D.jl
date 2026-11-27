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
          [Color3(1.0, 0.0, 0.0), Color3(0.0, 0.21586050010324417, 0.0),
           Color3(1.0, 0.0, 0.0), Color3(0.0, 0.0, 1.0), Color3(0.0, 0.0, 0.0)]
    # green is #008000; its linear value 0.21586050010324417 is the oracle
    # path.color (Color.setStyle with SRGBColorSpace, SVGLoader.js:245).
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

@testset "SVG use moves the referenced content's clip path and mask with it" begin
    # A userSpaceOnUse clip path or mask on the referenced element lives in that
    # element's user space, so the instance at x=20 is clipped to x 20..25, the
    # same shape as the original moved by the use offset.
    for attr in ("clip-path=\"url(#c)\"", "mask=\"url(#m)\"")
        doc = _audit3_svg_document("""
            <svg width="40" height="10">
              <clipPath id="c"><rect width="5" height="5"/></clipPath>
              <mask id="m"><rect width="5" height="5" fill="white"/></mask>
              <rect id="t" width="10" height="10" $attr/>
              <use href="#t" x="20"/>
              <g id="g"><rect width="10" height="10" $attr/></g>
              <use href="#g" transform="translate(0,20)"/>
            </svg>
            """)
        @test length(doc.paths) == 4
        @test [extrema(p.x for p in path.points) for path in doc.paths] ==
              [(0.0, 5.0), (20.0, 25.0), (0.0, 5.0), (0.0, 5.0)]
        @test [extrema(p.y for p in path.points) for path in doc.paths] ==
              [(0.0, 5.0), (0.0, 5.0), (0.0, 5.0), (20.0, 25.0)]
    end
end

@testset "SVG stroke lengths follow the element transform" begin
    # three.js SVGLoader.js:254: strokeWidth * getTransformScale(m), with
    # getTransformScale = sqrt(|det m|) (SVGLoader.js:2040-2046). Oracle:
    # scale(2) -> 6 for stroke-width 3; translate/rotate/skewX(20)/scale(1.5,0.5)
    # -> 0.8660254037844386 for the default width 1.
    doc = _audit3_svg_document("""
        <svg width="100" height="100">
          <g transform="scale(2)">
            <path d="M10 10 L 30 10" stroke="red" stroke-width="3"
                  stroke-dasharray="4 2" stroke-dashoffset="1" fill="none"/>
          </g>
          <g transform="translate(5,6) rotate(30 10 10) skewX(20) scale(1.5,0.5)">
            <rect x="1" y="2" width="10" height="5" stroke="red"/>
          </g>
          <path d="M0 0 L 1 0" stroke="red" transform="scale(-4, 1)"/>
        </svg>
        """)
    @test doc.paths[1].style.stroke_width == 6.0
    @test doc.paths[1].style.stroke_dasharray == [8.0, 4.0]
    @test doc.paths[1].style.stroke_dashoffset == 2.0
    @test doc.paths[2].style.stroke_width ≈ 0.8660254037844386 rtol=1e-15
    @test doc.paths[3].style.stroke_width == 2.0
    # The stroke mesh of the scaled line spans the scaled width: the 40-unit
    # line from (20,20) to (60,20) is offset by +-3 in y.
    meshes = svg_stroke_meshes(doc)
    ys = [get_vertex(meshes[1].geometry, i).y for i in 1:meshes[1].geometry.n_vertices]
    @test minimum(ys) == 17.0
    @test maximum(ys) == 23.0
end

function _audit3_cap_area(geometry)
    area = 0.0
    for face in 1:geometry.n_faces
        a, b, c = get_face(geometry, face)
        p, q, r = get_vertex(geometry, a), get_vertex(geometry, b), get_vertex(geometry, c)
        area += abs((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) / 2
    end
    return area
end

_audit3_square(x0, y0, x1, y1) = "m $x0 $y0 l $x1 $y0 l $x1 $y1 l $x0 $y1"

@testset "Glyph contours fill by the nonzero rule like ShapePath.toShapes" begin
    # three.js r186 Font.generateShapes -> ShapePath.toShapes (nonzero,
    # src/extras/core/ShapePath.js:217-366). Oracle areas (node, curveSegments 4):
    # same-winding nested squares 100 (inner contours excluded), alternating
    # windings 56, partly overlapping squares 164 (two outers), and an island
    # inside a hole 68.
    ccw(x0, y0, x1, y1) = _audit3_square(x0, y0, x1, y1)
    cw(x0, y0, x1, y1) = "m $x0 $y0 l $x0 $y1 l $x1 $y1 l $x1 $y0"
    glyphs = Dict(
        "I" => join([ccw(0, 0, 10, 10), ccw(1, 1, 9, 9), ccw(2, 2, 8, 8), ccw(3, 3, 7, 7)], " "),
        "J" => join([cw(0, 0, 10, 10), ccw(1, 1, 9, 9), cw(2, 2, 8, 8), ccw(3, 3, 7, 7)], " "),
        "L" => join([ccw(0, 0, 10, 10), ccw(5, 5, 13, 13)], " "),
        "M" => join([cw(0, 0, 10, 10), ccw(5, 5, 13, 13)], " "),
        "N" => join([ccw(0, 0, 10, 10), cw(2, 2, 8, 8), cw(4, 4, 6, 6)], " "))
    font = Diff3D._font_data(Dict("resolution" => 1, "glyphs" => Dict(
        key => Dict("ha" => 12, "o" => outline) for (key, outline) in glyphs)))
    for (char, expected, outers) in (("I", 100.0, 1), ("J", 56.0, 2), ("L", 164.0, 2),
                                      ("M", 164.0, 2), ("N", 68.0, 2))
        groups = Diff3D._font_text_shape_groups(font, char; curve_segments=4)
        @test length(groups) == outers
        @test _audit3_cap_area(TextGeometry(font, char; curve_segments=4)) ≈ expected
    end
end

@testset "SVG fill classification matches ShapePath.toShapes" begin
    # SVGLoader.createShapes is ShapePath.toShapes in r186 (SVGLoader.js:2244-2250).
    # A triangle whose first vertex lies inside a larger rectangle but which
    # extends past it is a separate outer, not a hole: oracle fill area 787.5
    # (three outers, no holes). The second path previously failed to
    # triangulate; its oracle area is 880 (544.5 + 195.5 + 140, three outers).
    doc = _audit3_svg_document("""
        <svg width="100" height="100">
          <path fill-rule="nonzero" d="M26 1 L36 37 L18 17 Z M10 17 L29 17 L29 38 L10 38 Z M24 15 L33 38 L43 27 Z"/>
          <path fill-rule="evenodd" d="M49 25 L20 38 L21 0 Z M36 36 L11 47 L5 34 Z M33 22 L61 22 L61 27 L33 27 Z"/>
        </svg>
        """)
    first_element = [p for p in doc.paths if p.element_id == doc.paths[1].element_id]
    second_element = [p for p in doc.paths if p.element_id != doc.paths[1].element_id]
    # These loops cross each other, where ShapePath.toShapes + Earcut emit
    # overlapping triangles (oracle triangle-area sums 787.5 and 880.0, the
    # previous expectations). The audit3b round fills crossing loops exactly
    # under the fill rule (SVG 1.1 section 11.3) as disjoint pieces; the
    # areas are the exact rational fill areas 216377841863/367853490 and
    # 6376182959/8839675 from an independent Venn-cell inclusion-exclusion
    # over the convex loops (audit3b_svg_loader.jl).
    first_geos = Diff3D._svg_fill_geometries(first_element)
    @test sum(_audit3_cap_area, first_geos) ≈ 588.2174500043482
    second_geos = Diff3D._svg_fill_geometries(second_element)
    @test sum(_audit3_cap_area, second_geos) ≈ 721.3141839490705
end

@testset "TextGeometry bevel follows ExtrudeGeometry's layer schedule" begin
    # three.js TextGeometry is ExtrudeGeometry over the glyph shapes
    # (examples/jsm/geometries/TextGeometry.js:47-75). Its bevel layers
    # (src/geometries/ExtrudeGeometry.js:380-470) put the lids on the glyph
    # outline at z = -thickness and depth + thickness and grow the outline by
    # size*sin(t*pi/2) at z = -thickness*cos(t*pi/2). Oracle for a unit square
    # glyph, size 0.1, thickness 0.05, depth 0.4: 28 triangles; x range
    # [-0.1, 1.1] for bevel_segments=1 and 2; z range [-0.05, 0.45].
    font = Diff3D._font_data(Dict("resolution" => 1000, "glyphs" => Dict(
        "A" => Dict("ha" => 1200, "o" => "m 0 0 l 1000 0 l 1000 1000 l 0 1000"),
        "O" => Dict("ha" => 1200, "o" => "m 0 0 l 1000 0 l 1000 1000 l 0 1000 " *
                                         "m 250 250 l 250 750 l 750 750 l 750 250"))))
    function x_extent_by_z(geometry)
        out = Dict{Float64,Tuple{Float64,Float64}}()
        for i in 1:geometry.n_vertices
            v = get_vertex(geometry, i)
            lo, hi = get(out, v.z, (Inf, -Inf))
            out[v.z] = (min(lo, v.x), max(hi, v.x))
        end
        return out
    end
    for segments in (1, 2)
        geometry = TextGeometry(font, "A"; depth=0.4, bevel_enabled=true, bevel_size=0.1,
                                bevel_thickness=0.05, bevel_segments=segments)
        @test geometry.n_faces == 2 * 2 + 2 * 4 * (2 * segments + 1)
        extents = x_extent_by_z(geometry)
        @test extents[-0.05] == (0.0, 1.0)
        @test extents[maximum(keys(extents))] == (0.0, 1.0)
        @test extents[0.0] == (-0.1, 1.1)
        @test extents[0.4] == (-0.1, 1.1)
        if segments == 2
            # t = 1/2: z = -0.05 cos(pi/4), offset 0.1 sin(pi/4) per axis.
            z = -0.05 * cos(π / 4)
            lo, hi = extents[z]
            @test lo ≈ -0.1 * sin(π / 4) atol=1e-15
            @test hi ≈ 1 + 0.1 * sin(π / 4) atol=1e-15
        end
        # Side normals of the lower bevel face outward and down.
        for face in 1:geometry.n_faces
            a, b, c = get_face(geometry, face)
            p, q, r = get_vertex(geometry, a), get_vertex(geometry, b), get_vertex(geometry, c)
            maximum((p.z, q.z, r.z)) <= 0.0 && minimum((p.z, q.z, r.z)) < 0.0 || continue
            n = cross(q - p, r - p)
            centroid = (p + q + r) / 3
            outward = Vec3(centroid.x - 0.5, centroid.y - 0.5, 0.0)
            @test dot(n, outward) > 0 || n.z < 0
        end
    end
    # The solid also grows into the counter, so the hole body ring shrinks
    # from 0.25..0.75 to 0.3..0.7 (oracle; outer x range [-0.05, 1.05]).
    hole = TextGeometry(font, "O"; depth=0.4, bevel_enabled=true, bevel_size=0.05,
                        bevel_thickness=0.05, bevel_segments=1)
    @test hole.n_faces == 66
    box = compute_bounding_box(hole)
    @test (box.min.x, box.max.x) == (-0.05, 1.05)
    @test box.min.z == -0.05
    @test box.max.z ≈ 0.45
    inner_body = [get_vertex(hole, i) for i in 1:hole.n_vertices
                  if get_vertex(hole, i).z == 0.0 && 0.1 < get_vertex(hole, i).x < 0.9]
    @test extrema(v.x for v in inner_body) == (0.3, 0.7)
    # Zero depth still produces the two bevel bands.
    thin = TextGeometry(font, "A"; depth=0.0, bevel_enabled=true, bevel_size=0.1,
                        bevel_thickness=0.05, bevel_segments=1)
    @test all(isfinite, thin.normals)
    @test thin.n_faces == 2 * 2 + 2 * 4 * 2
end

@testset "Text layout breaks lines and falls back to the ? glyph" begin
    # three.js FontLoader.js createPaths: "\n" resets x and lowers y by
    # (boundingBox.yMax - yMin + underlineThickness) * scale; a character
    # without a glyph uses glyphs["?"]. Oracle: Font.generateShapes(text, 1)
    # first loop points for this font.
    font = Diff3D._font_data(Dict(
        "resolution" => 1000,
        "boundingBox" => Dict("yMin" => -100, "yMax" => 900),
        "underlineThickness" => 50,
        "glyphs" => Dict(
            "A" => Dict("ha" => 1200, "o" => "m 0 0 l 1000 0 l 1000 1000 l 0 1000"),
            "?" => Dict("ha" => 700, "o" => "m 100 0 l 600 0 l 600 500 l 100 500"))))
    @test font.line_height == 1050.0
    starts(text) = [(loop[1].x, loop[1].y) for loop in font_text_shapes(font, text)]
    # "A\nA" -> [[0,0],...], [[0,-1.05],...]
    lines = starts("A\nA")
    @test length(lines) == 2
    @test lines[1] == (0.0, 0.0)
    @test lines[2][1] == 0.0 && lines[2][2] ≈ -1.05
    # "\n\nA" -> [[0,-2.1],...]
    @test only(starts("\n\nA"))[2] ≈ -2.1
    # "AzA" -> A at 0, "?" at 1.2 (first point 1.3), A at 1.9.
    fallback = starts("AzA")
    @test length(fallback) == 3
    @test fallback[2][1] ≈ 1.3 && fallback[2][2] == 0.0
    @test fallback[3][1] ≈ 1.9
    geometry = TextGeometry(font, "A\nA")
    box = compute_bounding_box(geometry)
    @test box.min.y ≈ -1.05 && box.max.y == 1.0
    # Without the line-height fields a line break cannot be placed.
    bare = Diff3D._font_data(Dict("glyphs" => Dict("A" => Dict("ha" => 1200,
        "o" => "m 0 0 l 1000 0 l 1000 1000 l 0 1000"))))
    @test isnan(bare.line_height)
    @test_throws ErrorException font_text_shapes(bare, "A\nA")
    @test length(font_text_shapes(bare, "AzA")) == 2
end

@testset "SVG paint accepts every CSS keyword, hsl() and rgba()" begin
    # three.js Color.setStyle (src/math/Color.js:6-30 keywords, 296-440
    # parsing, 248-272 setHSL) with SRGBColorSpace as SVGLoader calls it
    # (SVGLoader.js:23, 245): the result is in the linear working space.
    # Oracle values `new Color().setStyle(s, SRGBColorSpace)` in node; the
    # expectations were sRGB before the round-2 audit made SVG paint linear
    # (audit3b_svg_loader.jl).
    oracle = [
        "orange" => (1.0, 0.37626212298046485, 0.0),
        "rebeccapurple" => (0.13286832154414627, 0.033104766565152086, 0.31854677811435356),
        "navy" => (0.0, 0.0, 0.21586050010324417),
        "lightgoldenrodyellow" => (0.9559733532482866, 0.9559733532482866, 0.6444796819634361),
        "hsl(120,50%,50%)" => (0.05087608816465111, 0.5225215539594343, 0.050876088164650994),
        "hsl(30, 100%, 25%)" => (0.2140411404715882, 0.0508760881646509, 0.0),
        "hsla(300,40%,80%,0.5)" => (0.7484141034940689, 0.4769997845570289, 0.7484141034940685),
        "hsl(0,0%,40%)" => (0.13286832154414627, 0.13286832154414627, 0.13286832154414627),
        "hsl(390,100%,50%)" => (1.0, 0.2140411404715878, 0.0),
        "hsl(200,60%,70%)" => (0.23302199929070042, 0.5382355235922686, 0.7484141034940685),
        "rgba(255,128,0,0.25)" => (1.0, 0.21586050010324417, 0.0),
        "rgb(10%,50%,100%)" => (0.01002282557165656, 0.2140411404715882, 1.0),
        "#abc" => (0.4019777798219466, 0.4969329950515914, 0.6038273388475408),
        "gray" => (0.21586050010324417, 0.21586050010324417, 0.21586050010324417),
    ]
    for (style, (r, g, b)) in oracle
        @test Diff3D._svg_color(style) == Color3(r, g, b)
    end
    # The keyword table has all 148 entries of Color.NAMES.
    @test length(Diff3D._SVG_COLOR_KEYWORDS) == 148
    doc = _audit3_svg_document("""<svg><rect width="1" height="1" fill="Orange" stroke="hsl(240, 100%, 50%)"/></svg>""")
    @test doc.paths[1].style.fill == Color3(1.0, 0.37626212298046485, 0.0)
    # Oracle: hsl(240, 100%, 50%) -> (0, 5.155834479353416e-17, 1).
    @test doc.paths[1].style.stroke == Color3(0.0, 5.155834479353416e-17, 1.0)
    @test_throws "unsupported SVG color" Diff3D._svg_color("hsl(120,50,50)")
    @test_throws "alpha must be between 0 and 1" Diff3D._svg_color("rgba(1,2,3,2)")
    @test_throws "three channels" Diff3D._svg_color("rgb(1,2)")
end

@testset "SVG lengths accept absolute units at 90 DPI" begin
    # three.js SVGLoader.js:83 (defaultDPI 90) and 1527-1622
    # (parseFloatWithUnits). Oracle rect x=3mm y=4pt width=1in height=2cm,
    # stroke-width 2mm: corners (10.629921259842519, 5) and
    # (100.62992125984252, 75.86614173228345), strokeWidth 7.086614173228346;
    # circle cx=1pc r=0.5cm: first point (32.71653543307086, 10).
    doc = _audit3_svg_document("""
        <svg>
          <rect x="3mm" y="4pt" width="1in" height="2cm" stroke="black" stroke-width="2mm"/>
          <circle cx="1pc" cy="10" r="0.5cm"/>
        </svg>"""; circle_segments=8)
    rect = doc.paths[1]
    @test rect.points[1] == Vec2(10.629921259842519, 5.0)
    @test rect.points[3] == Vec2(100.62992125984252, 75.86614173228345)
    @test rect.style.stroke_width == 7.086614173228346
    @test doc.paths[2].points[1] == Vec2(32.71653543307086, 10.0)
    @test_throws "unsupported SVG length" _audit3_svg_document("""<svg><rect width="1em" height="1"/></svg>""")
end
