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
