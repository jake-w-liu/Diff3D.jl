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
