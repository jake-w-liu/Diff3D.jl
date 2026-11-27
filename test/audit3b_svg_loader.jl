using Test, Diff3D

function _audit3b_svg(text::AbstractString; kwargs...)
    path = tempname() * ".svg"
    write(path, text)
    try
        return load_svg(path; kwargs...)
    finally
        rm(path; force=true)
    end
end

function _audit3b_area(geo)
    area = 0.0
    for f in 1:geo.n_faces
        i, j, k = get_face(geo, f)
        p, q, r = get_vertex(geo, i), get_vertex(geo, j), get_vertex(geo, k)
        area += abs((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)) / 2
    end
    return area
end

_audit3b_rgb(c) = (c.r, c.g, c.b)

@testset "SVG paint is stored in the linear working color space" begin
    # three.js SVGLoader.js:23 (COLOR_SPACE_SVG = SRGBColorSpace), :245
    # (path.color.setStyle(fill, SRGBColorSpace)) and :2228 (stroke material):
    # Color.setStyle converts the sRGB CSS value to the linear working space.
    # Oracle path.color from node (three r186 + xmldom) for each fill below.
    doc = _audit3b_svg("""
        <svg width="10" height="10">
          <rect width="1" height="1" fill="#808080" stroke="rgb(10, 200, 30)"/>
          <rect width="1" height="1" fill="#abc"/>
          <rect width="1" height="1" fill="rgb(10%, 50%, 90%)"/>
          <rect width="1" height="1" fill="hsl(120, 50%, 25%)"/>
          <rect width="1" height="1" fill="cornflowerblue"/>
          <rect width="1" height="1" fill="#000001"/>
        </svg>""")
    oracle = [(0.21586050010324417, 0.21586050010324417, 0.21586050010324417),
              (0.4019777798219466, 0.4969329950515914, 0.6038273388475408),
              (0.01002282557165656, 0.2140411404715882, 0.7874122893910657),
              (0.014349874702952042, 0.11601613422345775, 0.01434987470295201),
              (0.12743768042608497, 0.3005437944049895, 0.8468732315065057),
              (0.0, 0.0, 0.00030352698352941176)]
    @test [_audit3b_rgb(p.style.fill) for p in doc.paths] == oracle
    # createStrokeMaterial color: setStyle("rgb(10, 200, 30)", SRGBColorSpace).
    stroke_oracle = (0.0030352698352941175, 0.5775804404214573, 0.012983032338510335)
    @test _audit3b_rgb(doc.paths[1].style.stroke) == stroke_oracle
    # The mesh builders hand the linear color to the materials unchanged, so
    # an sRGB output transform reproduces the authored #808080.
    fills = svg_meshes(doc)
    @test _audit3b_rgb(fills[1].material.color) == oracle[1]
    @test _audit3b_rgb(svg_stroke_meshes(doc)[1].material.color) == stroke_oracle
    @test _audit3b_rgb(svg_strokes(doc)[1].material.color) == stroke_oracle
    @test linear_to_srgb(fills[1].material.color.r) ≈ 128 / 255 rtol = 1e-9
    # Luminance masks keep evaluating luminance on the sRGB values (CSS
    # Masking 1 section 7.2 with the sRGB initial color-interpolation): a #808080
    # mask scales opacity by 128/255.
    masked = _audit3b_svg("""
        <svg width="10" height="10">
          <mask id="m"><rect width="10" height="10" fill="#808080"/></mask>
          <rect width="4" height="4" mask="url(#m)"/>
        </svg>""")
    @test masked.paths[1].style.opacity ≈ 128 / 255 rtol = 1e-9
end

@testset "SVG open subpaths are filled as if closed" begin
    # SVG 1.1 section 11.3 ("the fill operation fills open subpaths by
    # performing the fill operation as if an additional closepath command
    # were added"); three.js ShapePath.toShapes fills every subpath. Oracle
    # (SVGLoader.parse + toShapes + ShapeUtils.triangulateShape): area 100 for
    # the open square; the polyline triangle has area 50.
    doc = _audit3b_svg("""
        <svg width="100" height="100">
          <path d="M0 0 L10 0 L10 10 L0 10" fill="#808080" stroke="red"/>
          <polyline points="20,0 30,0 30,10" fill="blue"/>
          <polyline points="40,0 50,0 50,10" fill="none" stroke="red"/>
        </svg>""")
    @test [p.closed for p in doc.paths] == [false, false, false]
    fills = svg_meshes(doc)
    @test length(fills) == 2
    @test _audit3b_area(fills[1].geometry) ≈ 100.0
    @test _audit3b_area(fills[2].geometry) ≈ 50.0
    # A stroke-only polyline adds nothing to the fill geometry.
    @test _audit3b_area(svg_geometry(doc)) ≈ 150.0
    # The stroke of the open path is still open (butt ends, no closing edge).
    strokes = svg_strokes(doc)
    @test length(strokes) == 2
    @test all(s -> !(s isa LineLoop), strokes)

    # Clipping an open filled path clips the implicitly closed fill area and
    # the open stroke separately: the clip x <= 5 keeps half of the square's
    # area and a stroke made of the clipped top edge only (the left edge is
    # not part of the open path).
    clipped = _audit3b_svg("""
        <svg width="100" height="100">
          <clipPath id="c"><rect x="-1" y="-1" width="6" height="20"/></clipPath>
          <path d="M0 0 L10 0 L10 10 L0 10" fill="#808080" stroke="red"
                clip-path="url(#c)"/>
        </svg>""")
    @test _audit3b_area(svg_geometry(clipped)) ≈ 50.0
    stroke_paths = [p for p in clipped.paths if p.style.stroke !== nothing]
    @test all(p -> !p.closed && p.style.fill === nothing, stroke_paths)
    @test sort([(first(p.points), last(p.points)) for p in stroke_paths]; by=string) ==
          sort([(Vec2(0.0, 0.0), Vec2(5.0, 0.0)), (Vec2(5.0, 10.0), Vec2(0.0, 10.0))]; by=string)
    @test all(p -> p.style.stroke === nothing,
              [p for p in clipped.paths if p.style.fill !== nothing])

    # Clip and mask content contributes its fill area, so an open child path
    # clips like its closed triangle instead of raising an error.
    open_clip = _audit3b_svg("""
        <svg width="100" height="100">
          <clipPath id="t"><path d="M0 0 L10 0 L0 10"/><line x1="0" y1="0" x2="9" y2="9"/></clipPath>
          <mask id="m"><polyline points="0,0 10,0 0,10" fill="white"/></mask>
          <rect width="10" height="10" clip-path="url(#t)"/>
          <rect x="0" y="0" width="10" height="10" mask="url(#m)"/>
        </svg>""")
    meshes = svg_meshes(open_clip)
    @test length(meshes) == 2
    @test _audit3b_area(meshes[1].geometry) ≈ 50.0
    @test _audit3b_area(meshes[2].geometry) ≈ 50.0
end

function _audit3b_bbox(paths)
    xs = [p.x for path in paths for p in path.points]
    ys = [p.y for path in paths for p in path.points]
    return (minimum(xs), minimum(ys), maximum(xs), maximum(ys))
end

_audit3b_close(a, b; atol=1e-9) = all(isapprox.(a, b; atol=atol))

@testset "SVG clip paths and masks live in the referencing element's user space" begin
    # SVG 1.1 section 14.3.5: clipPathUnits="userSpaceOnUse" is "the current
    # user coordinate system in place at the time when the clipPath element is
    # referenced (i.e., the user coordinate system for the element referencing
    # the clipPath element via the clip-path property)"; the clipPath's own
    # ancestors do not matter, its own transform does. Expected boxes are that
    # derivation (three.js SVGLoader has no clip-path support).
    doc = _audit3b_svg("""
        <svg width="200" height="100">
          <defs><clipPath id="c"><rect width="5" height="5"/></clipPath></defs>
          <g transform="translate(100,0)">
            <clipPath id="far"><rect width="5" height="5"/></clipPath>
          </g>
          <clipPath id="moved" transform="translate(2,0)"><rect width="5" height="5"/></clipPath>
          <g transform="translate(20,0)"><rect width="10" height="10" clip-path="url(#c)"/></g>
          <rect x="40" width="10" height="10" transform="scale(2)" clip-path="url(#c)"/>
          <rect width="10" height="10" clip-path="url(#far)"/>
          <g transform="translate(0,40)" clip-path="url(#moved)"><rect width="10" height="10"/></g>
        </svg>""")
    groups = Diff3D._svg_element_path_groups(doc.paths)
    # The element's own scale(2) scales the clip too: user 40..50 x 0..10 is
    # clipped to user 0..5, which misses it entirely, leaving three elements.
    @test length(groups) == 3
    # Group translate(20,0): the clip moves with the group.
    @test _audit3b_close(_audit3b_bbox(groups[1]), (20.0, 0.0, 25.0, 5.0))
    # The translate(100,0) around clipPath #far does not apply.
    @test _audit3b_close(_audit3b_bbox(groups[2]), (0.0, 0.0, 5.0, 5.0))
    # clipPath #moved's own transform does.
    @test _audit3b_close(_audit3b_bbox(groups[3]), (2.0, 40.0, 7.0, 45.0))
    scaled = _audit3b_svg("""
        <svg width="200" height="100">
          <clipPath id="c"><rect width="5" height="5"/></clipPath>
          <rect width="10" height="10" transform="scale(2)" clip-path="url(#c)"/>
        </svg>""")
    @test _audit3b_close(_audit3b_bbox(scaled.paths), (0.0, 0.0, 10.0, 10.0))

    # objectBoundingBox: the box is the element's bounding box in its own user
    # space (SVG 1.1 section 7.11), so under rotate(30) the clip x <= 0.25
    # keeps the user-space strip 0 <= x <= 2.5 of the 10x10 square (area 25).
    rotated = _audit3b_svg("""
        <svg width="100" height="100">
          <clipPath id="bb" clipPathUnits="objectBoundingBox"><rect width="0.25" height="1"/></clipPath>
          <rect width="10" height="10" transform="translate(50,10) rotate(30)" clip-path="url(#bb)"/>
        </svg>""")
    θ = 30 * π / 180
    inv(p) = Vec2(cos(θ) * (p.x - 50) + sin(θ) * (p.y - 10),
                  -sin(θ) * (p.x - 50) + cos(θ) * (p.y - 10))
    user = [inv(p) for path in rotated.paths for p in path.points]
    @test all(p -> -1e-9 <= p.x <= 2.5 + 1e-9 && -1e-9 <= p.y <= 10 + 1e-9, user)
    @test sum(path -> abs(Diff3D._font_polygon_area(path.points)), rotated.paths) ≈ 25.0

    # Basic-shape lengths are user-space lengths too (CSS Masking 1 section
    # 5.1): inset(0 5px 0 0) on a 10x10 rect under scale(2) keeps user x <= 5,
    # i.e. root x <= 10.
    inset = _audit3b_svg("""
        <svg width="100" height="100">
          <rect width="10" height="10" transform="scale(2)" style="clip-path: inset(0 5px 0 0)"/>
        </svg>""")
    @test _audit3b_close(_audit3b_bbox(inset.paths), (0.0, 0.0, 10.0, 20.0))

    # Masks follow the same rule (SVG 1.1 section 14.4, maskContentUnits
    # userSpaceOnUse), including through a mirrored transform.
    masked = _audit3b_svg("""
        <svg width="100" height="100">
          <mask id="m"><rect width="5" height="5" fill="white"/></mask>
          <g transform="translate(20,0)"><rect width="10" height="10" mask="url(#m)"/></g>
          <g transform="translate(60,0) scale(-1,1)"><rect width="10" height="10" mask="url(#m)"/></g>
        </svg>""")
    mgroups = Diff3D._svg_element_path_groups(masked.paths)
    @test _audit3b_close(_audit3b_bbox(mgroups[1]), (20.0, 0.0, 25.0, 5.0))
    @test _audit3b_close(_audit3b_bbox(mgroups[2]), (55.0, 0.0, 60.0, 5.0))

    # The x/y of `use` belong to its user space (SVG 1.1 section 5.6: an
    # additional translate(x,y) on the generated group).
    used = _audit3b_svg("""
        <svg width="100" height="100">
          <clipPath id="c"><rect width="5" height="5"/></clipPath>
          <defs><rect id="r" width="10" height="10"/></defs>
          <use href="#r" x="30" clip-path="url(#c)"/>
        </svg>""")
    @test _audit3b_close(_audit3b_bbox(used.paths), (30.0, 0.0, 35.0, 5.0))
end

@testset "SVG clip-path, mask and use references may precede their definitions" begin
    # SVG 1.1 section 5.3.1: IRI references resolve against the whole
    # document; an element may reference a definition that appears later.
    doc = _audit3b_svg("""
        <svg width="100" height="100">
          <rect width="10" height="10" clip-path="url(#c)"/>
          <rect x="20" width="10" height="10" mask="url(#m)"/>
          <g clip-path="url(#c)"><rect width="3" height="3"/></g>
          <use href="#later" x="50"/>
          <defs>
            <clipPath id="c"><rect width="5" height="5"/></clipPath>
            <mask id="m"><rect x="20" width="4" height="4" fill="white"/></mask>
            <rect id="later" width="2" height="2"/>
          </defs>
        </svg>""")
    groups = Diff3D._svg_element_path_groups(doc.paths)
    @test length(groups) == 4
    @test _audit3b_close(_audit3b_bbox(groups[1]), (0.0, 0.0, 5.0, 5.0))
    @test _audit3b_close(_audit3b_bbox(groups[2]), (20.0, 0.0, 24.0, 4.0))
    @test _audit3b_close(_audit3b_bbox(groups[3]), (0.0, 0.0, 3.0, 3.0))
    @test _audit3b_close(_audit3b_bbox(groups[4]), (50.0, 0.0, 52.0, 2.0))
    # Inheritance inside a forward clip definition comes from its own
    # ancestors: the clip-rule on the enclosing group makes the inner square a
    # hole.
    holed = _audit3b_svg("""
        <svg width="100" height="100">
          <rect width="10" height="10" clip-path="url(#h)"/>
          <g style="clip-rule: evenodd" fill-rule="evenodd">
            <clipPath id="h"><path d="M0 0 H10 V10 H0 Z M2 2 H8 V8 H2 Z"/></clipPath>
          </g>
        </svg>""")
    @test _audit3b_area(svg_geometry(holed)) ≈ 64.0
    # Cycles through clip-path references are rejected, not recursed forever.
    @test_throws "circular reference" _audit3b_svg("""
        <svg><clipPath id="a"><rect width="5" height="5" clip-path="url(#a)"/></clipPath>
        <rect width="10" height="10" clip-path="url(#a)"/></svg>""")
    @test_throws "circular reference" _audit3b_svg("""
        <svg><mask id="a"><rect width="5" height="5" fill="white" mask="url(#b)"/></mask>
        <mask id="b"><rect width="5" height="5" fill="white" mask="url(#a)"/></mask>
        <rect width="10" height="10" mask="url(#a)"/></svg>""")
    @test_throws "SVG clip-path references unknown id" _audit3b_svg("""
        <svg><rect id="notclip" width="5" height="5"/>
        <rect width="10" height="10" clip-path="url(#notclip)"/></svg>""")
end

@testset "SVG symbol renders only through use, as a nested viewport" begin
    # SVG 1.1 section 5.5: "'symbol' elements are never rendered directly";
    # SVG 2 sections 5.5/5.6.2 and 8.2: the use instantiates the symbol as a
    # viewport sized by the use width/height (else the symbol's, else 100%),
    # mapped from the symbol viewBox with preserveAspectRatio, and clipped by
    # the UA style sheet's overflow: hidden. Expected boxes follow the 8.2
    # viewBox-to-viewport algorithm. (three.js SVGLoader has no symbol case,
    # so it would render symbol children in place and ignore the viewBox.)
    doc = _audit3b_svg("""
        <svg width="100" height="100">
          <symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10" stroke="red"/></symbol>
          <symbol id="slice" viewBox="0 0 10 10" preserveAspectRatio="xMinYMin slice">
            <rect width="10" height="10"/>
          </symbol>
          <symbol id="none" viewBox="0 0 10 10" preserveAspectRatio="none">
            <rect width="10" height="10"/>
          </symbol>
          <use href="#s" width="20" height="20"/>
          <use href="#s" x="50" width="40" height="20"/>
          <use href="#slice" y="50" width="40" height="20"/>
          <use href="#none" y="80" width="40" height="20"/>
        </svg>""")
    groups = Diff3D._svg_element_path_groups(doc.paths)
    @test length(groups) == 4
    @test _audit3b_close(_audit3b_bbox(groups[1]), (0.0, 0.0, 20.0, 20.0))
    # Stroke widths scale with the viewBox transform like any user length.
    @test groups[1][1].style.stroke_width ≈ 2.0
    # xMidYMid meet: scale 2, centered horizontally in 40 -> offset 10.
    @test _audit3b_close(_audit3b_bbox(groups[2]), (60.0, 0.0, 80.0, 20.0))
    # slice: scale 4, content 0..40 x 0..40 clipped to the 40x20 viewport.
    @test _audit3b_close(_audit3b_bbox(groups[3]), (0.0, 50.0, 40.0, 70.0))
    # none: non-uniform scale (4, 2).
    @test _audit3b_close(_audit3b_bbox(groups[4]), (0.0, 80.0, 40.0, 100.0))

    defaults = _audit3b_svg("""
        <svg width="100" height="50">
          <symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol>
          <symbol id="t" x="5" y="6" width="4" height="4" overflow="visible">
            <rect width="10" height="2"/>
          </symbol>
          <symbol id="z"><rect width="10" height="2"/></symbol>
          <use href="#s"/>
          <use href="#t" x="1" y="1"/>
          <use href="#z" width="0"/>
        </svg>""")
    dgroups = Diff3D._svg_element_path_groups(defaults.paths)
    @test length(dgroups) == 2
    # 100% x 100% of the 100x50 root viewport, meet -> scale 5, centered.
    @test _audit3b_close(_audit3b_bbox(dgroups[1]), (25.0, 0.0, 75.0, 50.0))
    # No viewBox: translate by symbol x/y and use x/y; overflow visible keeps
    # the content outside the 4x4 viewport.
    @test _audit3b_close(_audit3b_bbox(dgroups[2]), (6.0, 7.0, 16.0, 9.0))
    @test_throws "preserveAspectRatio" _audit3b_svg("""
        <svg width="10" height="10"><symbol id="s" viewBox="0 0 1 1" preserveAspectRatio="center"/>
        <use href="#s"/></svg>""")
end

@testset "SVG percentage lengths resolve against the root viewport" begin
    # SVG 1.1 section 7.10: percentages of x-lengths refer to the viewport
    # width, y-lengths to its height, others to sqrt((w^2 + h^2) / 2); the
    # viewport of the root user space is the viewBox when one is given.
    doc = _audit3b_svg("""
        <svg width="100%" height="50%" viewBox="0 0 200 100">
          <rect x="10%" y="10%" width="50%" height="50%" stroke-width="1%" stroke="red"/>
          <circle cx="50%" cy="50%" r="10%"/>
        </svg>"""; circle_segments=4)
    # A root percentage is a fraction of the viewBox size.
    @test (doc.width, doc.height) == (200.0, 50.0)
    @test _audit3b_close(_audit3b_bbox(doc.paths[1:1]), (20.0, 10.0, 120.0, 60.0))
    diag = sqrt((200.0^2 + 100.0^2) / 2)
    @test doc.paths[1].style.stroke_width ≈ 0.01 * diag
    @test _audit3b_close(_audit3b_bbox(doc.paths[2:2]),
                         (100.0 - 0.1 * diag, 50.0 - 0.1 * diag,
                          100.0 + 0.1 * diag, 50.0 + 0.1 * diag))
    # Without a viewBox the root viewport is width x height.
    sized = _audit3b_svg("""<svg width="40" height="20"><rect width="50%" height="50%"/></svg>""")
    @test _audit3b_close(_audit3b_bbox(sized.paths), (0.0, 0.0, 20.0, 10.0))
    # A percentage root size without a viewBox is unknown, like an absent one.
    @test _audit3b_svg("""<svg width="100%" height="100%"/>""").width == 0.0
    @test_throws "needs a root viewport size" _audit3b_svg(
        """<svg width="100%"><rect width="50%" height="1"/></svg>""")
end

function _audit3b_covers(geo, p)
    for f in 1:geo.n_faces
        i, j, k = get_face(geo, f)
        a, b, c = get_vertex(geo, i), get_vertex(geo, j), get_vertex(geo, k)
        d1 = (b.x - a.x) * (p[2] - a.y) - (b.y - a.y) * (p[1] - a.x)
        d2 = (c.x - b.x) * (p[2] - b.y) - (c.y - b.y) * (p[1] - b.x)
        d3 = (a.x - c.x) * (p[2] - c.y) - (a.y - c.y) * (p[1] - c.x)
        ((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0)) || return true
    end
    return false
end

@testset "SVG miter joins cover the whole corner of closed rect strokes" begin
    # three.js r186 SVGLoader.parse + pointsToStroke oracle for
    # <rect x="20" y="20" width="10" height="10" stroke-width="2">: the stroke
    # covers the square ring 19..31 minus 21..29, including every corner
    # square (the rect's points end on the start point, so pointsToStroke
    # joins the closing corner too, SVGLoader.js:2366). Diff3D closes the
    # rect and joins all four corners; the miter join used to leave the
    # triangle p-outer1-outer2 of each corner uncovered (sampled coverage
    # mismatch 180 of 14641 grid points against the oracle, 0 after).
    doc = _audit3b_svg("""
        <svg width="100" height="100">
          <rect x="20" y="20" width="10" height="10" fill="none" stroke="red" stroke-width="2"/>
        </svg>""")
    @test doc.paths[1].closed
    geo = svg_stroke_meshes(doc)[1].geometry
    for corner in ((20.0, 20.0), (30.0, 20.0), (30.0, 30.0), (20.0, 30.0))
        sx = corner[1] < 25 ? -1.0 : 1.0
        sy = corner[2] < 25 ? -1.0 : 1.0
        # Points of the corner's outer unit square on both sides of its
        # diagonal, and inside the ring next to the corner.
        for (u, v) in ((0.25, 0.5), (0.5, 0.25), (0.9, 0.9), (0.1, 0.1), (-0.5, 0.5))
            @test _audit3b_covers(geo, (corner[1] + sx * u, corner[2] + sy * v))
        end
    end
    @test !_audit3b_covers(geo, (25.0, 25.0))
    @test !_audit3b_covers(geo, (31.5, 25.0))
    direct = points_to_stroke_geometry([Vec2(0.0, 0.0), Vec2(10.0, 0.0), Vec2(10.0, 10.0)];
                                       stroke_width=2.0)
    @test _audit3b_covers(direct, (10.25, -0.5))
    @test _audit3b_covers(direct, (10.9, -0.9))
end

function _audit3b_path_parse_overhead(d)
    Diff3D._svg_path_points(d, 4)
    Diff3D._svg_lex(d, Diff3D._SVG_PATH_TOKEN_RE, "SVG path data")
    total = @allocated Diff3D._svg_path_points(d, 4)
    lex = @allocated Diff3D._svg_lex(d, Diff3D._SVG_PATH_TOKEN_RE, "SVG path data")
    return total - lex
end

@testset "SVG path data parsing allocates only its tokens and points" begin
    # Beyond lexing, parsing 1000 L commands only builds the point vector
    # (about 44 KB measured on Julia 1.13). Parse state captured and
    # reassigned by closures was boxed and allocated per number (about 260 KB).
    d = "M0 0" * join([" L$(i % 7).5 $(i % 5).25" for i in 1:1000])
    @test length(only(Diff3D._svg_path_points(d, 4)).points) == 1001
    @test _audit3b_path_parse_overhead(d) < 120_000
end

@testset "SVG fills of crossing loops follow the fill rule exactly" begin
    # SVG 1.1 section 11.3: a point is filled by the winding number of all
    # subpaths around it (nonzero) or its parity (evenodd), however they
    # cross. ShapePath.toShapes + Earcut (three.js r186) assume nested,
    # non-crossing loops: on 300 random overlapping rectangle/triangle paths
    # its triangles disagreed with the fill rule in 112 (and overlapped in
    # 129); Diff3D's toShapes port disagreed in the same 112. Expected areas
    # are exact rationals from an independent Venn-cell inclusion-exclusion
    # over the convex loops.
    doc = _audit3b_svg("""
        <svg width="100" height="100">
          <path fill-rule="nonzero" d="M26 1 L36 37 L18 17 Z M10 17 L29 17 L29 38 L10 38 Z M24 15 L33 38 L43 27 Z"/>
          <path fill-rule="evenodd" d="M49 25 L20 38 L21 0 Z M36 36 L11 47 L5 34 Z M33 22 L61 22 L61 27 L33 27 Z"/>
          <path fill-rule="nonzero" d="M0 60 L20 60 L20 80 L0 80 Z M10 70 L30 70 L30 90 L10 90 Z"/>
          <path fill-rule="evenodd" d="M50 60 L70 60 L70 80 L50 80 Z M60 70 L80 70 L80 90 L60 90 Z"/>
          <path fill-rule="nonzero" d="M0 0 L20 0 L20 20 L0 20 Z M10 10 L10 30 L30 30 L30 10 Z" transform="translate(0 92)"/>
          <path fill-rule="nonzero" d="M80 0 L90 10 L80 10 L90 0 Z"/>
        </svg>""")
    meshes = svg_meshes(doc)
    @test length(meshes) == 6
    # 216377841863/367853490 and 6376182959/8839675.
    @test _audit3b_area(meshes[1].geometry) ≈ 588.2174500043482
    @test _audit3b_area(meshes[2].geometry) ≈ 721.3141839490705
    # Two 20x20 squares with a 10x10 overlap. Same winding, nonzero: the
    # overlap (winding 2) is filled once, 800 - 100.
    @test _audit3b_area(meshes[3].geometry) ≈ 700.0
    @test _audit3b_covers(meshes[3].geometry, (15.0, 75.0))
    # evenodd leaves the overlap empty: 800 - 2 * 100.
    @test _audit3b_area(meshes[4].geometry) ≈ 600.0
    @test !_audit3b_covers(meshes[4].geometry, (65.0, 75.0))
    # Opposite windings cancel under nonzero too: 800 - 2 * 100.
    @test _audit3b_area(meshes[5].geometry) ≈ 600.0
    @test !_audit3b_covers(meshes[5].geometry, (15.0, 107.0))
    # Self-intersecting bow tie (zero net signed area): two triangles of 25.
    @test _audit3b_area(meshes[6].geometry) ≈ 50.0
    # Clip content goes through the same exact fill.
    clipped = _audit3b_svg("""
        <svg width="100" height="100">
          <clipPath id="c"><path d="M0 0 L20 0 L20 20 L0 20 Z M10 10 L30 10 L30 30 L10 30 Z"/></clipPath>
          <rect width="40" height="40" clip-path="url(#c)"/>
        </svg>""")
    @test _audit3b_area(svg_geometry(clipped)) ≈ 700.0
    # Loops that only nest keep the ShapePath.toShapes triangulation: a
    # square with a hole has the oracle area 400 - 100.
    nested = _audit3b_svg("""<svg width="100" height="100">
        <path fill-rule="evenodd" d="M0 0 H20 V20 H0 Z M5 5 H15 V15 H5 Z"/></svg>""")
    @test !Diff3D._svg_loops_touch([p.points for p in nested.paths])
    @test _audit3b_area(svg_geometry(nested)) ≈ 300.0
end

_audit3b_srgb(r, g, b) = Diff3D._svg_color("rgb($r,$g,$b)")
_audit3b_fills(svg) = [p.style.fill for p in _audit3b_svg(svg).paths]

@testset "SVG stylesheets cascade like a CSS engine" begin
    # Expected fills are Chromium's getComputedStyle(fill) for these exact
    # documents (headless shell, loaded as image/svg+xml). On 3000 random
    # documents mixing compound/complex selectors, :is/:not/:where,
    # structural pseudo-classes, !important, style attributes, presentation
    # attributes and inheritance, the previous loader disagreed with
    # Chromium in 293 and failed to load 211; this one agrees on all but the
    # :empty documents, which it rejects. three.js r186 matches only `.class`
    # and `#id` rule keys (SVGLoader.js:748-779 parseCSSStylesheet).
    W = """xmlns="http://www.w3.org/2000/svg" width="100" height="20\""""
    # Specificity is the tuple (ids, classes, types), not a weighted sum: one
    # id beats eleven classes (Selectors Level 4 section 17).
    @test _audit3b_fills("""<svg $W><style>#p { fill: rgb(255,0,0) }
        .a.a.a.a.a.a.a.a.a.a.a { fill: rgb(0,0,255) }</style>
        <rect id="p" class="a" width="5" height="5"/></svg>""") == [_audit3b_srgb(255, 0, 0)]
    # !important outranks specificity and the normal style attribute, and an
    # important style attribute outranks it (CSS Cascade 4 section 6.4).
    @test _audit3b_fills("""<svg $W><style>rect { fill: rgb(0,128,0) !important }
        #p { fill: rgb(255,0,0) }</style>
        <rect id="p" width="5" height="5" style="fill: rgb(0,0,255)"/>
        <rect x="10" width="5" height="5" style="fill: rgb(255,255,0) !important"/></svg>""") ==
          [_audit3b_srgb(0, 128, 0), _audit3b_srgb(255, 255, 0)]
    # <style> and <title> are elements of the tree: the rect after <style>
    # is not :first-child, and sibling combinators see both.
    @test _audit3b_fills("""<svg $W><style>rect:first-child { fill: rgb(255,0,0) }
        style + rect { fill: rgb(0,0,255) } title ~ circle { fill: rgb(0,128,0) }</style>
        <rect width="5" height="5"/><title>t</title><circle cx="12" cy="2" r="2"/></svg>""") ==
          [_audit3b_srgb(0, 0, 255), _audit3b_srgb(0, 128, 0)]
    # :last-child, :only-of-type, :nth-last-child() and :last-of-type
    # (Selectors Level 4 sections 14.3-14.4).
    @test _audit3b_fills("""<svg $W><style>rect:last-child { fill: rgb(255,0,0) }
        circle:only-of-type { fill: rgb(0,0,255) } :nth-last-child(3) { fill: rgb(0,128,0) }
        g rect:last-of-type { fill: rgb(9,9,9) }</style>
        <rect width="5" height="5"/><circle cx="12" cy="2" r="2"/>
        <rect x="20" width="5" height="5"/><g><rect x="30" width="5" height="5"/></g></svg>""") ==
          [_audit3b_srgb(0, 0, 0), _audit3b_srgb(0, 0, 255), _audit3b_srgb(0, 0, 0),
           _audit3b_srgb(9, 9, 9)]
    # Elements the loader does not render (<a>) are still parents and
    # siblings; a compound may repeat an id; comments are not markup (XML 1.0
    # section 2.5), so the commented-out rect is not drawn.
    @test _audit3b_fills("""<svg $W><style>a > rect { fill: rgb(255,0,0) }
        a rect + rect { fill: rgb(0,0,255) } #q#q { fill: rgb(0,128,0) }</style>
        <a href="#x"><rect width="5" height="5"/><rect x="10" width="5" height="5"/></a>
        <!-- <rect x="40" width="5" height="5"/> -->
        <rect id="q" x="20" width="5" height="5"/>
        <rect id="q2" class="b" x="30" width="5" height="5"/></svg>""") ==
          [_audit3b_srgb(255, 0, 0), _audit3b_srgb(0, 0, 255), _audit3b_srgb(0, 128, 0),
           _audit3b_srgb(0, 0, 0)]
    # Selectors the loader cannot evaluate are rejected instead of being
    # silently dropped (which changed the rendering); pseudo-element rules
    # never apply to shapes and are skipped.
    @test_throws r"SVG <style> selector \"rect:empty\" is not supported" _audit3b_svg(
        """<svg $W><style>rect:empty { fill: red }</style><rect width="5" height="5"/></svg>""")
    @test_throws r"not supported" _audit3b_svg(
        """<svg $W><style>g:has(rect) { fill: red }</style><rect width="5" height="5"/></svg>""")
    @test _audit3b_fills("""<svg $W><style>rect::before { fill: rgb(255,0,0) }</style>
        <rect width="5" height="5"/></svg>""") == [_audit3b_srgb(0, 0, 0)]
end
