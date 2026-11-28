using Test, Diff3D, SHA

# Round 3 fonts/triangulation work package. Oracle values come from three.js
# r186 (0.186.0) under node: src/extras/lib/earcut.js, ShapeGeometry.js,
# ExtrudeGeometry.js and examples/jsm/geometries/TextGeometry.js.

_f32_sha(values) = bytes2hex(sha256(reinterpret(UInt8, Float32.(values))))
_i32_sha(values) = bytes2hex(sha256(reinterpret(UInt8, Int32.(values))))
_earcut0(data, holes=Int[]; dim=2) = Diff3D.earcut_triangulate(data, holes; dim=dim) .- 1

const _SYNTH_FONT_JSON = """{"familyName":"Synth","resolution":1000,"ascender":800,"descender":-200,
"boundingBox":{"yMin":-200,"yMax":800,"xMin":0,"xMax":900},"underlineThickness":50,
"glyphs":{
"O":{"ha":800,"x_min":0,"x_max":800,"o":"m 400 0 q 0 0 0 400 q 0 800 400 800 q 800 800 800 400 q 800 0 400 0 m 400 150 q 650 150 650 400 q 650 650 400 650 q 150 650 150 400 q 150 150 400 150 "},
"A":{"ha":700,"x_min":0,"x_max":700,"o":"m 0 0 l 300 700 l 400 700 l 700 0 l 560 0 l 480 200 l 220 200 l 140 0 l 0 0 m 270 320 l 430 320 l 350 540 l 270 320 "},
"B":{"ha":650,"x_min":0,"x_max":650,"o":"m 0 0 l 0 700 l 300 700 b 600 600 600 700 600 650 b 450 380 600 520 550 400 b 600 100 550 360 600 300 b 320 0 600 40 450 0 l 0 0 m 120 120 l 300 120 b 450 200 400 120 450 150 b 300 320 450 280 400 320 l 120 320 l 120 120 m 120 420 l 300 420 b 430 510 400 420 430 460 b 300 590 430 560 400 590 l 120 590 l 120 420 "},
"8":{"ha":600,"x_min":0,"x_max":600,"o":"m 300 0 q 50 0 50 200 q 50 330 200 380 q 80 430 80 560 q 80 720 300 720 q 520 720 520 560 q 520 430 400 380 q 550 330 550 200 q 550 0 300 0 m 300 100 q 430 100 430 200 q 430 320 300 320 q 170 320 170 200 q 170 100 300 100 m 300 440 q 400 440 400 560 q 400 620 300 620 q 200 620 200 560 q 200 440 300 440 "},
"?":{"ha":500,"x_min":0,"x_max":500,"o":"m 0 0 l 400 0 l 400 400 l 0 400 "}
}}"""

function _synth_font()
    path = tempname() * ".json"
    write(path, _SYNTH_FONT_JSON)
    try
        return load_font(path)
    finally
        rm(path; force=true)
    end
end

@testset "Earcut port matches three.js earcut.js" begin
    # Expected arrays: earcut(data, holes) from src/extras/lib/earcut.js (0-based).
    @test _earcut0([0, 0, 10, 0, 10, 10, 0, 10, 2, 2, 2, 4, 4, 4, 4, 2], [5]) ==
          [0, 4, 5, 7, 4, 0, 1, 2, 3, 3, 0, 5, 7, 0, 1, 3, 5, 6, 6, 7, 1, 1, 3, 6]
    # collinear and duplicate points are filtered (earcut.js:65-87)
    @test _earcut0([0, 0, 5, 0, 10, 0, 10, 5, 10, 10, 0, 10]) == [4, 5, 0, 1, 2, 3, 3, 4, 0, 0, 1, 3]
    @test _earcut0([0, 0, 10, 0, 10, 0, 10, 10, 0, 10, 0, 0]) == [2, 3, 4, 2, 4, 0]
    @test isempty(_earcut0([0, 0, 1, 1, 2, 2]))
    # self-touching contour and a bow tie (cureLocalIntersections / splitEarcut)
    @test _earcut0([0, 0, 4, 0, 2, 2, 4, 4, 0, 4, 2, 2]) == [5, 0, 1, 2, 3, 4]
    @test _earcut0([0, 0, 4, 4, 4, 0, 0, 4]) == [3, 2, 1]
    # holes touching each other and the outer ring at a vertex, a one-point hole
    @test _earcut0([0, 0, 10, 0, 10, 10, 0, 10, 2, 2, 5, 2, 5, 5, 2, 5, 5, 5, 8, 5, 8, 8, 5, 8], [5, 9]) ==
          [7, 8, 11, 9, 6, 5, 5, 4, 0, 3, 0, 4, 5, 0, 1, 3, 4, 7, 9, 5, 1, 3, 7, 11, 10, 9, 1, 2, 3, 11, 10, 1, 2, 2, 11, 10]
    @test _earcut0([0, 0, 10, 0, 10, 10, 0, 10, 0, 0, 3, 2, 2, 3], [5]) ==
          [3, 4, 6, 5, 0, 1, 1, 2, 3, 3, 6, 5, 5, 1, 3]
    @test _earcut0([0, 0, 10, 0, 10, 10, 0, 10, 5, 5], [5]) == [4, 0, 1, 3, 0, 4, 4, 1, 2, 2, 3, 4]
    @test _earcut0([0, 0, 9, 10, 0, 9, 10, 10, 9, 0, 10, 9]; dim=3) == [2, 3, 0, 0, 1, 2]
    # More than 80 vertices switches to the z-order hash (earcut.js:18-38,
    # 166-213); integer coordinates make the tie-breaking matter.
    data = [100, 0, 97, 5, 92, 10, 99, 16, 94, 20, 89, 24, 95, 31, 89, 34, 83, 37, 89, 45, 81, 47, 75, 49, 81, 59, 72, 59, 74, 67, 71, 71, 62, 68, 62, 77, 59, 81, 50, 76, 49, 85, 45, 89, 37, 82, 35, 91, 31, 95, 26, 97, 20, 94, 16, 99, 10, 98, 5, 95, 0, 100, -5, 98, -10, 93, -16, 99, -20, 95, -24, 90, -31, 95, -34, 90, -37, 84, -45, 89, -47, 82, -50, 76, -59, 81, -59, 73, -60, 67, -71, 71, -69, 62, -78, 63, -81, 59, -77, 50, -86, 49, -89, 45, -83, 37, -91, 35, -95, 31, -87, 23, -95, 20, -99, 16, -99, 10, -96, 5, -100, 0, -99, -5, -94, -10, -99, -16, -96, -20, -91, -24, -95, -31, -91, -35, -85, -38, -89, -45, -83, -48, -77, -50, -81, -59, -74, -60, -68, -61, -71, -71, -63, -70, -57, -70, -59, -81, -51, -78, -50, -87, -45, -89, -37, -84, -35, -92, -31, -95, -24, -88, -20, -96, -16, -99, -9, -90, -5, -97, 0, -100, 5, -100, 10, -95, 16, -99, 21, -97, 25, -92, 31, -95, 35, -91, 38, -86, 45, -89, 49, -84, 51, -78, 59, -81, 60, -75, 62, -68, 71, -71, 71, -64, 71, -57, 81, -59, 79, -51, 78, -45, 89, -45, 85, -38, 93, -36, 95, -31, 89, -24, 97, -21, 99, -16, 91, -10, 98, -5, -25, 0, -26, -6, -29, -11, -34, -14, -40, -15, -46, -14, -51, -11, -54, -6, -55, 0, -54, 6, -51, 11, -46, 14, -40, 15, -34, 14, -29, 11, -26, 6, 55, 0, 54, -6, 51, -11, 46, -14, 40, -15, 34, -14, 29, -11, 26, -6, 25, 0, 26, 6, 29, 11, 34, 14, 40, 15, 46, 14, 51, 11, 54, 6]
    tri = _earcut0(data, [121, 137])
    @test length(tri) == 3 * 154
    @test tri[1:12] == [120, 144, 145, 143, 144, 120, 127, 128, 60, 60, 61, 62]
    @test _i32_sha(tri) == "e6dda20203e5e3bb8a076cacf36915ddcdda09b5a0256863255848aac282ce59"

    @test_throws ArgumentError Diff3D.earcut_triangulate([0.0, 0, 1, 0, 1], Int[])
    @test_throws ArgumentError Diff3D.earcut_triangulate([0.0, 0, 1, 0, 1, 1, 0, 1], [1])
    @test_throws ArgumentError Diff3D.earcut_triangulate([0.0, 0, 1, 0, 1, 1, 0, 1], [3, 3])
    @test_throws ArgumentError Diff3D.earcut_triangulate([0.0, 0, NaN, 0, 1, 1])
end

@testset "ShapeGeometry triangulation=:earcut matches three.js" begin
    outer = [Vec2(0.0, 0.0), Vec2(10.0, 0.0), Vec2(10.0, 10.0), Vec2(0.0, 10.0)]
    hole = [Vec2(2.0, 2.0), Vec2(4.0, 2.0), Vec2(4.0, 4.0), Vec2(2.0, 4.0)]
    g = ShapeGeometry(outer; holes=[hole], triangulation=:earcut)
    # three.js ShapeGeometry.js:85-140: outline clockwise, holes counterclockwise.
    @test g.positions == Float64[0, 10, 0, 10, 10, 0, 10, 0, 0, 0, 0, 0, 2, 2, 0, 4, 2, 0, 4, 4, 0, 2, 4, 0]
    @test g.indices .- 1 == [3, 4, 7, 5, 4, 3, 2, 1, 0, 0, 3, 7, 5, 3, 2, 0, 7, 6, 6, 5, 2, 2, 0, 6]
    @test g.uvs == g.positions[setdiff(1:24, 3:3:24)]
    @test all(g.normals[3:3:end] .== 1.0)
    # The Shape method passes the keyword on and samples curves as three.js does.
    s = Shape(outer)
    push!(s.holes, Path(hole))
    gs = ShapeGeometry(s; triangulation=:earcut)
    @test gs.positions == g.positions && gs.indices == g.indices
    # The default ear clipper is unchanged (counterclockwise outline first).
    d = ShapeGeometry(outer; holes=[hole])
    @test d.positions[1:12] == Float64[0, 0, 0, 10, 0, 0, 10, 10, 0, 0, 10, 0]
    # Degenerate input follows Earcut rather than raising.
    @test ShapeGeometry([Vec2(0.0, 0.0), Vec2(1.0, 1.0), Vec2(2.0, 2.0)]; triangulation=:earcut).n_faces == 0
    @test_throws ArgumentError ShapeGeometry([Vec2(0.0, 0.0), Vec2(1.0, 1.0), Vec2(2.0, 2.0)])
    @test_throws ArgumentError ShapeGeometry(outer; triangulation=:fast)
    # a one-point hole makes an empty three.js Path, which earcut cannot take
    @test_throws ArgumentError ShapeGeometry(outer; holes=[[Vec2(5.0, 5.0)]], triangulation=:earcut)
    # Repeated points are dropped by value as Vector2.equals compares them,
    # so -0.0 equals 0.0. node: three.js ShapeGeometry of the same shapes.
    sz = ShapeGeometry([Vec2(0.0, 0.0), Vec2(4.0, 0.0), Vec2(4.0, 4.0), Vec2(0.0, 4.0), Vec2(-0.0, 4.0), Vec2(-0.0, 2.0)];
                       holes=[[Vec2(1.0, 1.0), Vec2(-0.0, 1.0), Vec2(1.0, 1.0), Vec2(1.0, 2.0), Vec2(2.0, 2.0)]],
                       triangulation=:earcut)
    @test sz.n_vertices == 10
    @test sz.indices .- 1 == [9, 8, 4, 9, 4, 3, 1, 8, 7, 5, 9, 3, 1, 7, 6, 5, 3, 2, 2, 1, 6, 6, 5, 2]
    @test sz.positions == Float64[0, 2, 0, 0, 4, 0, 4, 4, 0, 4, 0, 0, 0, 0, 0, 2, 2, 0, 1, 2, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0]
    # ... and a last point equal to the first by value closes the outline
    closing = ShapeGeometry([Vec2(-0.0, 0.0), Vec2(4.0, 0.0), Vec2(4.0, 4.0), Vec2(0.0, -0.0)]; triangulation=:earcut)
    @test closing.n_vertices == 3
    @test closing.indices .- 1 == [1, 0, 2]
    @test closing.positions == Float64[0, 0, 0, 4, 4, 0, 4, 0, 0]
end

@testset "ExtrudeGeometry triangulation=:earcut matches three.js" begin
    # new ExtrudeGeometry(new Shape([(0,0),(2,0),(0,1)]), {depth:1, bevelEnabled:false})
    g = ExtrudeGeometry([Vec2(0.0, 0.0), Vec2(2.0, 0.0), Vec2(0.0, 1.0)];
                        depth=1.0, triangulation=:earcut)
    @test g.n_vertices == 24 && g.n_faces == 8 && g.indices == collect(1:24)
    @test g.positions == Float64[0, 0, 0, 0, 1, 0, 2, 0, 0, 2, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 1, 2, 0, 0, 2, 0, 1, 0, 0, 1, 2, 0, 0, 0, 1, 0, 2, 0, 1, 0, 1, 0, 0, 1, 1, 2, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1]
    @test g.uvs == Float64[0, 0, 0, 1, 2, 0, 2, 0, 0, 1, 0, 0, 0, 1, 2, 1, 0, 0, 2, 1, 2, 0, 0, 0, 2, 1, 0, 1, 2, 0, 0, 1, 0, 0, 2, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0]
    expected_normals = Float64[0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0.4472135901451111, 0.8944271802902222, 0, 0.4472135901451111, 0.8944271802902222, 0, 0.4472135901451111, 0.8944271802902222, 0, 0.4472135901451111, 0.8944271802902222, 0, 0.4472135901451111, 0.8944271802902222, 0, 0.4472135901451111, 0.8944271802902222, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0, -1, 0, 0]
    @test isapprox(g.normals, expected_normals; atol=1e-7)   # three.js stores Float32
    @test isempty(g.groups)   # three.js's two draw groups are not added

    # Bevel, steps and offset with a hole; Float32 hashes of three.js's buffers.
    outer = [Vec2(0.0, 0.0), Vec2(10.0, 0.0), Vec2(10.0, 10.0), Vec2(0.0, 10.0)]
    hole = [Vec2(2.0, 2.0), Vec2(4.0, 2.0), Vec2(4.0, 4.0), Vec2(2.0, 4.0)]
    b = ExtrudeGeometry(outer; holes=[hole], depth=2.0, steps=2, bevel_enabled=true,
                        bevel_segments=2, bevel_thickness=0.5, bevel_size=0.4,
                        bevel_offset=0.1, triangulation=:earcut)
    @test b.n_vertices == 336
    @test Float32.(b.positions[1:9]) == Float32[2.1, 3.9, -0.5, 2.1, 2.1, -0.5, -0.1, -0.1, -0.5]
    @test _f32_sha(b.positions) == "7edffc129d712c9d1971bbac5e0770cb83addad50b4e76eb753d4038176b8407"
    @test _f32_sha(b.uvs) == "42a03ac8ff167544fba1977546380e15e2ccd8286ef1664657a60a8023227958"

    # extrudePath: getSpacedPoints(steps) and computeFrenetFrames (ExtrudeGeometry.js:148-160)
    curve = CatmullRomCurve([Vec3(0.0, 0, 0), Vec3(5.0, 2, 1), Vec3(10.0, 0, 3), Vec3(12.0, 6, 2)])
    p = ExtrudeGeometry([Vec2(0.0, 0.0), Vec2(1.0, 0.0), Vec2(1.0, 1.0), Vec2(0.0, 1.0)];
                        steps=4, extrude_path=curve, triangulation=:earcut)
    @test p.n_vertices == 108
    @test isapprox(p.positions[1:18], [0, 0, 0, -0.37148332595825195, 0.9284396171569824, 1.3877787807814457e-17, -0.20200444757938385, 0.9962508082389832, -0.9831981062889099, -0.20200444757938385, 0.9962508082389832, -0.9831981062889099, 0.1694788634777069, 0.06781116127967834, -0.9831981062889099, 0, 0, 0]; atol=1e-6)
    @test isapprox(p.positions[end-8:end], [11.016790390014648, 1.7089251279830933, 2.846693515777588, 12, 6, 2, 11.051194190979004, 6.31585693359375, 1.9984049797058105]; atol=1e-5)
    @test_throws ArgumentError ExtrudeGeometry(outer; extrude_path=[Vec3(0.0, 0, 0), Vec3(0.0, 0, 1)],
                                               triangulation=:earcut)

    # The Shape method forwards the keyword.
    s = Shape(outer)
    push!(s.holes, Path(hole))
    bs = ExtrudeGeometry(s; depth=2.0, steps=2, bevel_enabled=true, bevel_segments=2,
                         bevel_thickness=0.5, bevel_size=0.4, bevel_offset=0.1,
                         triangulation=:earcut)
    @test bs.positions == b.positions
    # Default output is unchanged: indexed, two shared cap rings.
    d = ExtrudeGeometry(outer; holes=[hole], depth=2.0)
    @test d.n_vertices == 2 * 8 + 4 * 8 && d.indices != collect(1:length(d.indices))
end

@testset "TextGeometry triangulation=:earcut matches three.js TextGeometry" begin
    font = _synth_font()
    g = TextGeometry(font, "OA8"; size=1.0, depth=0.2, curve_segments=4, bevel_enabled=true,
                     bevel_size=0.02, bevel_thickness=0.03, bevel_segments=2,
                     triangulation=:earcut)
    # new TextGeometry("OA8", {font, size:1, depth:0.2, curveSegments:4,
    #   bevelEnabled:true, bevelSize:0.02, bevelThickness:0.03, bevelSegments:2})
    @test g.n_vertices == 3972
    @test _f32_sha(g.positions) == "ef875ba7c33b65d1320a4516a87cad83ac7edf3ed67a0237b537d83348ad3bca"
    @test _f32_sha(g.uvs) == "929bbd9adfc8f18024875537047bc35d3560c32900b5a9965936329804c8b6cc"
    @test_throws ArgumentError TextGeometry(font, "O"; triangulation=:other)
end

@testset "Earcut triangulates large polygons with holes quickly" begin
    # 10k-vertex outline with three 100-vertex holes: the ear clipper takes
    # about 2 s, Earcut a few milliseconds (min of 5 runs, Apple M-series).
    n = 10_000
    outer = [Vec2((10 + 0.25 * (1 + sin(7k))) * cos(2π * k / n),
                  (10 + 0.25 * (1 + sin(7k))) * sin(2π * k / n)) for k in 0:n-1]
    holes = [[Vec2(c + 1.5cos(-2π * k / 100), 1.5sin(-2π * k / 100)) for k in 0:99]
             for c in (-5.0, 0.0, 5.0)]
    g = ShapeGeometry(outer; holes=holes, triangulation=:earcut)
    @test g.n_faces == n + 300 + 2 * 3 - 2
    area = 0.0
    for f in 1:g.n_faces
        a, b, c = (g.indices[3f - 2], g.indices[3f - 1], g.indices[3f])
        ax, ay = g.positions[3a - 2], g.positions[3a - 1]
        bx, by = g.positions[3b - 2], g.positions[3b - 1]
        cx, cy = g.positions[3c - 2], g.positions[3c - 1]
        area += ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) / 2
    end
    shoelace(p) = sum(p[i].x * p[mod1(i + 1, length(p))].y - p[mod1(i + 1, length(p))].x * p[i].y
                      for i in eachindex(p)) / 2
    @test area ≈ shoelace(outer) + sum(shoelace, holes) rtol=1e-12
    @test (@elapsed ShapeGeometry(outer; holes=holes, triangulation=:earcut)) < 1.0
end

@testset "LatheGeometry last profile point normal follows three.js's direction" begin
    # three.js LatheGeometry.js:97-100 pushes the last point's normal without
    # normalizing it (|n| = last segment length, here 0.7071); its direction is
    # (dy, -dx) of the last segment, which Diff3D stores as a unit vector.
    g = LatheGeometry([Vec2(0.0, -0.5), Vec2(0.5, 0.0), Vec2(0.0, 0.5)];
                      segments=5, phi_start=0.3, phi_length=4.0)
    for (vertex, js) in ((3, [0.14776010811328888, 0.5, 0.47766825556755066]),
                         (9, [0.4731500446796417, 0.5, -0.16164478659629822]))
        n = g.normals[3vertex - 2:3vertex]
        @test isapprox(n, js ./ sqrt(sum(abs2, js)); atol=1e-7)
        @test sqrt(sum(abs2, n)) ≈ 1.0
    end
end

# ---- TTFLoader ----
# Fonts are built in memory (no font files are committed). Expected values are
# three.js r186 examples/jsm/loaders/TTFLoader.js output under node with
# opentype.js 1.3.4 for the same bytes written to a scratch file.

_tf_rd32(v::Vector{UInt8}, i::Int) = foldl((a, b) -> (a << 8) | Int(b), v[i + 1:i + 4]; init=0)

_tf_be16(x::Integer) = (u = Int(x) & 0xFFFF; UInt8[u >> 8, u & 0xFF])
_tf_be32(x::Integer) = (u = Int(x) & 0xFFFFFFFF; UInt8[(u >> 24) & 0xFF, (u >> 16) & 0xFF, (u >> 8) & 0xFF, u & 0xFF])
_tf_pad4!(v::Vector{UInt8}) = (while length(v) % 4 != 0; push!(v, 0x00); end; v)

function _tf_sfnt(sig::Vector{UInt8}, tables::Vector{Pair{String,Vector{UInt8}}})
    n = length(tables)
    out = vcat(sig, _tf_be16(n), _tf_be16(0), _tf_be16(0), _tf_be16(0))
    body = UInt8[]
    for (tag, bytes) in tables
        append!(out, codeunits(tag), _tf_be32(0), _tf_be32(12 + 16n + length(body)), _tf_be32(length(bytes)))
        append!(body, bytes)
        _tf_pad4!(body)
    end
    return vcat(out, body)
end

# A simple glyph from contours of (x, y, on_curve); flags use the short,
# same and repeat encodings wherever they apply.
function _tf_glyf_simple(contours)
    pts = reduce(vcat, contours)
    xs = [p[1] for p in pts]; ys = [p[2] for p in pts]
    out = vcat(_tf_be16(length(contours)), _tf_be16(minimum(xs)), _tf_be16(minimum(ys)),
               _tf_be16(maximum(xs)), _tf_be16(maximum(ys)))
    e = -1
    for c in contours
        e += length(c)
        append!(out, _tf_be16(e))
    end
    append!(out, _tf_be16(0))
    flags = Int[]; xb = UInt8[]; yb = UInt8[]
    px = py = 0
    for (x, y, on) in pts
        f = on ? 1 : 0
        for (d, short, same, buf) in ((x - px, 2, 16, xb), (y - py, 4, 32, yb))
            if d == 0
                f |= same
            elseif abs(d) < 256
                f |= short
                d > 0 && (f |= same)
                push!(buf, UInt8(abs(d)))
            else
                append!(buf, _tf_be16(d))
            end
        end
        push!(flags, f)
        px, py = x, y
    end
    i = 1
    while i <= length(flags)
        j = i
        while j < length(flags) && flags[j + 1] == flags[i]
            j += 1
        end
        j > i ? append!(out, UInt8[flags[i] | 8, j - i]) : push!(out, UInt8(flags[i]))
        i = j + 1
    end
    append!(out, xb, yb)
    isodd(length(out)) && push!(out, 0x00)
    return out
end

# Composite: glyph 1 scaled 0.5 and moved by 16-bit (600, -50); glyph 1 under a
# 2x2 matrix moved by 8-bit (10, -20); glyph 0 placed by matched points.
function _tf_glyf_composite()
    out = vcat(_tf_be16(-1), _tf_be16(0), _tf_be16(-700), _tf_be16(1300), _tf_be16(700))
    append!(out, _tf_be16(1 | 2 | 8 | 32), _tf_be16(1), _tf_be16(600), _tf_be16(-50), _tf_be16(8192))
    append!(out, _tf_be16(2 | 128 | 32), _tf_be16(1), UInt8[10, reinterpret(UInt8, Int8(-20))],
            _tf_be16(16384), _tf_be16(4096), _tf_be16(0), _tf_be16(-16384))
    append!(out, _tf_be16(0), _tf_be16(0), UInt8[3, 0])
    return out
end

const _tf_SYNTH_GLYPHS = [
    [[(0, 0, true), (400, 0, true), (400, 600, true), (0, 600, true)]],
    [[(0, 0, true), (500, 0, true), (500, 700, false), (0, 700, true)],
     [(100, 100, false), (300, 100, true), (300, 300, false), (100, 300, false)]],
]

function _tf_synth_cmap(format::Symbol)
    f4 = begin
        ends = [0x20, 0x42, 0x45, 0xFFFF]; starts = [0x20, 0x41, 0x43, 0xFFFF]
        deltas = [3 - 0x20, 1 - 0x41, 0, 1]; ranges = [0, 0, 4, 0]
        seg = length(ends)
        body = vcat(_tf_be16(2seg), _tf_be16(4), _tf_be16(1), _tf_be16(0))
        foreach(v -> append!(body, _tf_be16(v)), ends); append!(body, _tf_be16(0))
        foreach(v -> append!(body, _tf_be16(v)), starts)
        foreach(v -> append!(body, _tf_be16(v)), deltas)
        foreach(v -> append!(body, _tf_be16(v)), ranges)
        foreach(v -> append!(body, _tf_be16(v)), [2, 0, 1])   # 'C' -> 2, 'D' -> 0, 'E' -> 1
        vcat(_tf_be16(4), _tf_be16(6 + length(body)), _tf_be16(0), body)
    end
    f12 = begin
        groups = [(0x41, 0x42, 1), (0x1F600, 0x1F600, 2), (0x20, 0x20, 3)]
        body = vcat(_tf_be32(length(groups)))
        for (a, b, g) in groups
            append!(body, _tf_be32(a), _tf_be32(b), _tf_be32(g))
        end
        vcat(_tf_be16(12), _tf_be16(0), _tf_be32(12 + length(body)), _tf_be32(0), body)
    end
    subs = format == :format4 ? [(3, 1, f4)] : [(3, 1, f4), (3, 10, f12)]
    out = vcat(_tf_be16(0), _tf_be16(length(subs)))
    off = 4 + 8 * length(subs)
    for (p, e, s) in subs
        append!(out, _tf_be16(p), _tf_be16(e), _tf_be32(off))
        off += length(s)
    end
    for (_, _, s) in subs
        append!(out, s)
    end
    return out
end

function _tf_synth_name()
    win = transcode(UInt16, "Synth Sans")
    winb = reduce(vcat, [_tf_be16(u) for u in win])
    mac = UInt8[codeunits("Synth Mac ")..., 0x8E]          # 0x8E is e-acute in Mac Roman
    recs = [(3, 1, 0x0409, winb), (1, 0, 0, mac)]           # the later English record wins
    out = vcat(_tf_be16(0), _tf_be16(length(recs)), _tf_be16(6 + 12 * length(recs)))
    strings = UInt8[]
    for (p, e, l, s) in recs
        append!(out, _tf_be16(p), _tf_be16(e), _tf_be16(l), _tf_be16(4), _tf_be16(length(s)), _tf_be16(length(strings)))
        append!(strings, s)
    end
    return vcat(out, strings)
end

function _tf_synth_common(num_glyphs::Int, loca_long::Bool)
    head = vcat(_tf_be32(0x00010000), _tf_be32(0x00010000), _tf_be32(0), _tf_be32(0x5F0F3CF5), _tf_be16(0),
                _tf_be16(1000), zeros(UInt8, 16), _tf_be16(-50), _tf_be16(-200), _tf_be16(1200), _tf_be16(900),
                _tf_be16(0), _tf_be16(8), _tf_be16(2), _tf_be16(loca_long ? 1 : 0), _tf_be16(0))
    hhea = vcat(_tf_be32(0x00010000), _tf_be16(800), _tf_be16(-200), _tf_be16(0), _tf_be16(1300),
                zeros(UInt8, 22), _tf_be16(3))
    maxp = vcat(_tf_be32(0x00005000), _tf_be16(num_glyphs))
    hmtx = vcat(_tf_be16(600), _tf_be16(0), _tf_be16(700), _tf_be16(0), _tf_be16(1300), _tf_be16(0), _tf_be16(0))
    post = vcat(_tf_be32(0x00030000), _tf_be32(0), _tf_be16(-100), _tf_be16(50), zeros(UInt8, 20))
    return head, hhea, maxp, hmtx, post
end

function _tf_synth_ttf(; cmap::Symbol=:format4, loca_long::Bool=false, cmap_bytes=_tf_synth_cmap(cmap),
                    glyphs=[_tf_glyf_simple(_tf_SYNTH_GLYPHS[1]), _tf_glyf_simple(_tf_SYNTH_GLYPHS[2]),
                            _tf_glyf_composite(), UInt8[]])
    glyf = UInt8[]; offsets = Int[]
    for g in glyphs
        push!(offsets, length(glyf)); append!(glyf, g)
    end
    push!(offsets, length(glyf))
    loca = reduce(vcat, [loca_long ? _tf_be32(o) : _tf_be16(o ÷ 2) for o in offsets])
    head, hhea, maxp, hmtx, post = _tf_synth_common(length(glyphs), loca_long)
    return _tf_sfnt(UInt8[0, 1, 0, 0], ["cmap" => cmap_bytes, "glyf" => glyf, "head" => head,
                                     "hhea" => hhea, "hmtx" => hmtx, "loca" => loca, "maxp" => maxp,
                                     "name" => _tf_synth_name(), "post" => post])
end

# ---- CFF ----
function _tf_cs_num(v)
    if isinteger(v) && -107 <= v <= 107
        return UInt8[Int(v) + 139]
    elseif isinteger(v) && 108 <= v <= 1131
        w = Int(v) - 108
        return UInt8[247 + (w >> 8), w & 0xFF]
    elseif isinteger(v) && -1131 <= v <= -108
        w = -Int(v) - 108
        return UInt8[251 + (w >> 8), w & 0xFF]
    elseif isinteger(v)
        return vcat(UInt8[28], _tf_be16(Int(v)))
    end
    return vcat(UInt8[255], _tf_be32(round(Int, v * 65536)))
end
const _tf_CS_OPS = Dict(:hstem => [1], :vstem => [3], :vmoveto => [4], :rlineto => [5], :hlineto => [6],
    :vlineto => [7], :rrcurveto => [8], :callsubr => [10], :return => [11], :endchar => [14],
    :hstemhm => [18], :hintmask => [19], :rmoveto => [21], :hmoveto => [22], :vstemhm => [23],
    :rcurveline => [24], :rlinecurve => [25], :vvcurveto => [26], :hhcurveto => [27],
    :callgsubr => [29], :vhcurveto => [30], :hvcurveto => [31], :reserved2 => [2],
    :dotsection => [12, 0], :hflex => [12, 34], :flex => [12, 35], :hflex1 => [12, 36], :flex1 => [12, 37])
_tf_cs(prog...) = reduce(vcat, [x isa Symbol ? UInt8.(_tf_CS_OPS[x]) : x isa Vector{UInt8} ? x : _tf_cs_num(x)
                              for x in prog])

function _tf_cff_index(objs::Vector{Vector{UInt8}})
    isempty(objs) && return _tf_be16(0)
    out = vcat(_tf_be16(length(objs)), UInt8[4])
    off = 1
    append!(out, _tf_be32(off))
    for o in objs
        off += length(o); append!(out, _tf_be32(off))
    end
    return vcat(out, objs...)
end
_tf_dict_int(v) = vcat(UInt8[29], _tf_be32(v))

_tf_synth_charstrings() = [
        _tf_cs(:endchar),
        _tf_cs(50, 10, 20, :hstemhm, 30, 40, :vstemhm, :hintmask, UInt8[0xC0],
            0, 0, :rmoveto, 500, :hlineto, 700, :vlineto, -500, 0, :rlineto, -107, :callsubr,
            100, -400, :rmoveto, 50, 0, 50, 50, 0, 50, :rrcurveto, 10, 20, 30, 40, 50, :hhcurveto,
            5, 10, 20, 30, 40, :vvcurveto, 10, 20, 30, 40, :hvcurveto, 10, 20, 30, 40, 50, :vhcurveto,
            10, 20, 30, 40, 50, 60, 70, 80, :rcurveline, 10, 20, 30, 40, 50, 60, 70, 80, :rlinecurve,
            -107, :callgsubr, :endchar),
        _tf_cs(70, 100, :hmoveto, 1.5, :vlineto, 300, :hlineto, -300, :vlineto, 2000, 0, :rlineto,
            100, :reserved2, 0, :rlineto, 5, :dotsection,
            10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 50, :flex,
            10, 20, 30, 40, 50, 60, 70, :hflex, 10, 20, 30, 40, 50, 60, 70, 80, 90, :hflex1,
            10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, :flex1, :endchar),
        _tf_cs(:endchar),
    ]

function _tf_synth_cff_table(; gsubrs=[_tf_cs(0, 100, :rlineto, :return)],
                          subrs=[_tf_cs(100, 0, :rlineto, :return)], charstrings=_tf_synth_charstrings())
    header = UInt8[1, 0, 4, 4]
    name = _tf_cff_index([Vector{UInt8}(codeunits("Synth"))])
    strings = _tf_cff_index(Vector{UInt8}[])
    gsubr_index = _tf_cff_index(gsubrs)
    cs_index = _tf_cff_index(charstrings)
    # Offsets use the fixed 5-byte operand so the Top DICT size (17 bytes,
    # INDEX 28 bytes) does not depend on their values.
    private_len = 18
    charstrings_at = length(header) + length(name) + 28 + length(strings) + length(gsubr_index)
    private_at = charstrings_at + length(cs_index)
    private = vcat(_tf_dict_int(500), UInt8[20], _tf_dict_int(600), UInt8[21], _tf_dict_int(private_len), UInt8[19])
    top = vcat(_tf_dict_int(charstrings_at), UInt8[17], _tf_dict_int(private_len), _tf_dict_int(private_at), UInt8[18])
    top_index = _tf_cff_index([top])
    @assert length(top_index) == 28 && length(private) == private_len
    return vcat(header, name, top_index, strings, gsubr_index, cs_index, private, _tf_cff_index(subrs))
end

function _tf_synth_otf(; kwargs...)
    head, hhea, maxp, hmtx, post = _tf_synth_common(4, false)
    return _tf_sfnt(Vector{UInt8}(codeunits("OTTO")),
                 ["CFF " => _tf_synth_cff_table(; kwargs...), "cmap" => _tf_synth_cmap(:format4), "head" => head,
                  "hhea" => hhea, "hmtx" => hmtx, "maxp" => maxp, "name" => _tf_synth_name(), "post" => post])
end

# ---- WOFF: tables zlib-compressed with fixed-Huffman runs (distance 1) ----
mutable struct _tf_Bits
    out::Vector{UInt8}
    acc::UInt32
    n::Int
end
function _tf_putbits!(b::_tf_Bits, v::Integer, n::Integer)        # LSB first
    for k in 0:(n - 1)
        b.acc |= UInt32((v >> k) & 1) << b.n
        b.n += 1
        b.n == 8 && (push!(b.out, UInt8(b.acc)); b.acc = 0; b.n = 0)
    end
end
_tf_putrev!(b::_tf_Bits, code::Integer, n::Integer) = _tf_putbits!(b, bitreverse(UInt32(code)) >> (32 - n), n)
function _tf_fixed_symbol!(b::_tf_Bits, s::Int)
    s <= 143 ? _tf_putrev!(b, 0x30 + s, 8) : s <= 255 ? _tf_putrev!(b, 0x190 + s - 144, 9) :
    s <= 279 ? _tf_putrev!(b, s - 256, 7) : _tf_putrev!(b, 0xC0 + s - 280, 8)
end
const _tf_LEN_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
const _tf_LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
function _tf_zlib_runs(data::Vector{UInt8})
    b = _tf_Bits(UInt8[0x78, 0x01], 0, 0)
    _tf_putbits!(b, 1, 1); _tf_putbits!(b, 1, 2)                   # final fixed-Huffman block
    i = 1
    while i <= length(data)
        _tf_fixed_symbol!(b, Int(data[i]))
        run = 0
        while i + run + 1 <= length(data) && data[i + run + 1] == data[i] && run < 258
            run += 1
        end
        if run >= 3
            k = findlast(<=(run), _tf_LEN_BASE)
            _tf_fixed_symbol!(b, 256 + k)
            _tf_putbits!(b, run - _tf_LEN_BASE[k], _tf_LEN_EXTRA[k])
            _tf_putrev!(b, 0, 5)                                # distance code 0: distance 1
            i += 1 + _tf_LEN_BASE[k] + (run - _tf_LEN_BASE[k])
        else
            i += 1
        end
    end
    _tf_fixed_symbol!(b, 256)
    b.n > 0 && push!(b.out, UInt8(b.acc))
    return vcat(b.out, zeros(UInt8, 4))                     # Adler-32 is not checked by opentype.js
end

function _tf_woff(sfnt::Vector{UInt8})
    n = Int(sfnt[5]) << 8 | sfnt[6]
    entries = []
    for i in 0:(n - 1)
        rec = 12 + 16i
        tag = sfnt[rec + 1:rec + 4]
        off = _tf_rd32(sfnt, rec + 8)
        len = _tf_rd32(sfnt, rec + 12)
        raw = sfnt[off + 1:off + len]
        z = _tf_zlib_runs(raw)
        push!(entries, (tag, length(z) < len ? z : raw, len))
    end
    out_dir = UInt8[]
    body = UInt8[]
    data_at = 44 + 20n
    for (tag, bytes, len) in entries
        append!(out_dir, tag, _tf_be32(data_at + length(body)), _tf_be32(length(bytes)), _tf_be32(len), _tf_be32(0))
        append!(body, bytes); _tf_pad4!(body)
    end
    total = 44 + length(out_dir) + length(body)
    header = vcat(Vector{UInt8}(codeunits("wOFF")), sfnt[1:4], _tf_be32(total), _tf_be16(n), _tf_be16(0),
                  _tf_be32(length(sfnt)), _tf_be16(1), _tf_be16(0), _tf_be32(0), _tf_be32(0), _tf_be32(0), _tf_be32(0), _tf_be32(0))
    return vcat(header, out_dir, body)
end


# A format 4 cmap with one segment per (code point, glyph) pair.
function _tf_cmap4(pairs)
    segs = Tuple{Int,Int}[(c, g - c) for (c, g) in pairs]
    push!(segs, (0xFFFF, 1))
    n = length(segs)
    body = vcat(_tf_be16(2n), _tf_be16(0), _tf_be16(0), _tf_be16(0))
    foreach(s -> append!(body, _tf_be16(s[1])), segs); append!(body, _tf_be16(0))
    foreach(s -> append!(body, _tf_be16(s[1])), segs)
    foreach(s -> append!(body, _tf_be16(s[2])), segs)
    foreach(_ -> append!(body, _tf_be16(0)), segs)
    sub = vcat(_tf_be16(4), _tf_be16(6 + length(body)), _tf_be16(0), body)
    return vcat(_tf_be16(0), _tf_be16(1), _tf_be16(3), _tf_be16(1), _tf_be32(12), sub)
end

# A composite glyph placing each listed glyph at (0, 0) with 16-bit offsets.
function _tf_glyf_refs(ids)
    out = vcat(_tf_be16(-1), zeros(UInt8, 8))
    for (k, id) in enumerate(ids)
        append!(out, _tf_be16(1 | 2 | (k < length(ids) ? 32 : 0)), _tf_be16(id), _tf_be16(0), _tf_be16(0))
    end
    return out
end

const _TF_SYNTH_TTF_A = "m 0 972 l 0 0 l 694 0 q 0 972 694 972 l 0 972 z m 139 278 q 417 139 139 139 l 417 139 q 278 417 417 417 q 139 278 139 417 z "
const _TF_SYNTH_TTF_B = "m 833 417 l 833 -69 l 1181 -69 q 833 417 1181 417 l 833 417 z m 903 69 q 1042 0 903 0 l 1042 0 q 972 139 1042 139 q 903 69 903 139 z m 257 -1000 l 14 -28 l 708 -28 q 257 -1000 951 -1000 l 257 -1000 z m 222 -306 q 465 -167 188 -167 l 465 -167 q 396 -444 535 -444 q 222 -306 257 -444 z m 833 1250 l 833 417 l 1389 417 l 1389 1250 l 833 1250 z "
const _TF_SYNTH_TTF_D = "m 0 833 l 0 0 l 556 0 l 556 833 l 0 833 z "
const _TF_SYNTH_OTF_A = "m 0 0 l 694 0 l 694 972 l 0 972 l 139 972 z m 278 417 b 417 556 347 417 417 486 b 556 625 444 569 486 625 b 590 736 563 639 590 681 b 632 833 604 736 632 778 b 715 958 632 847 660 889 b 840 1125 729 986 771 1042 l 938 1236 l 951 1264 b 1160 1514 993 1319 1063 1403 l 1160 1653 z "
const _TF_SYNTH_OTF_B = "m 139 0 l 139 2 l 556 2 l 556 -415 l 3333 -415 l 3472 -415 b 3597 -248 3486 -387 3528 -331 b 3972 169 3694 -137 3819 2 b 4069 210 3986 169 4014 210 b 4319 169 4139 210 4222 169 b 4444 252 4333 197 4375 252 b 4750 169 4528 252 4625 363 b 4875 335 4764 197 4806 252 b 4750 738 4972 447 5097 585 z "

_tf_cmds(commands) = [(c.kind, c.points) for c in commands]

function _tf_check_font(f, expected)
    @test f.family_name == "Synth Mac é"      # Mac Roman 0x8E, the later English record
    @test (f.resolution, f.ascender, f.descender) == (1000.0, 1111.0, -278.0)
    @test f.line_height == 1150.0                  # head yMax - yMin + post underlineThickness
    @test isempty(f.kernings)
    @test Set(keys(f.glyphs)) == Set(keys(expected))
    for (ch, (ha, xmin, xmax, o)) in expected
        g = f.glyphs[ch]
        @test (g.advance_width, g.x_min, g.x_max, g.outline) == (ha, xmin, xmax, o)
        # the parsed commands are those FontLoader reads from the outline
        @test _tf_cmds(g.commands) == _tf_cmds(Diff3D._font_parse_outline(o, ch))
    end
end

@testset "TTFLoader matches three.js TTFLoader on synthetic TrueType fonts" begin
    # synth4: cmap format 4 (idDelta and idRangeOffset segments, 'D' -> glyph 0),
    # short loca, flag repeats, short/same coordinates, an all-off-curve contour,
    # a composite (scale, 2x2 matrix, byte and word offsets, matched points)
    # and an empty glyph whose advance comes from the last hmtx metric.
    plain = Dict(" " => (1806.0, 0.0, 0.0, ""), "A" => (972.0, 0.0, 694.0, _TF_SYNTH_TTF_A),
                 "E" => (972.0, 0.0, 694.0, _TF_SYNTH_TTF_A), "B" => (1806.0, 0.0, 1806.0, _TF_SYNTH_TTF_B),
                 "C" => (1806.0, 0.0, 1806.0, _TF_SYNTH_TTF_B), "D" => (833.0, 0.0, 556.0, _TF_SYNTH_TTF_D))
    _tf_check_font(Diff3D.load_ttf(_tf_synth_ttf()), plain)
    # reversed: TTFLoader reverses once per code point; glyphs reached from two
    # code points ('A'/'E', 'B'/'C') come back in order without their `z`.
    rev = Dict(k => (v[1], v[2], v[3], replace(v[4], "z " => "")) for (k, v) in plain)
    rev["D"] = (833.0, 0.0, 556.0, "m 0 833 l 556 833 l 556 0 l 0 0 l 0 833 ")
    _tf_check_font(Diff3D.load_ttf(_tf_synth_ttf(); reversed=true), rev)
    # synth12: the later format 12 subtable wins over format 4; long loca.
    f12 = Dict(" " => plain[" "], "A" => plain["A"], "B" => plain["B"], "\U1F600" => plain["B"])
    _tf_check_font(Diff3D.load_ttf(_tf_synth_ttf(cmap=:format12, loca_long=true)), f12)
    # WOFF 1.0 with zlib-compressed tables gives the same font.
    woff = _tf_woff(_tf_synth_ttf())
    ntables = (Int(woff[13]) << 8) | woff[14]
    @test any(_tf_rd32(woff, 44 + 20i + 8) < _tf_rd32(woff, 44 + 20i + 12) for i in 0:(ntables - 1))
    _tf_check_font(Diff3D.load_ttf(woff), plain)
    # a path argument and the TTFLoader alias
    path = tempname() * ".ttf"
    try
        write(path, _tf_synth_ttf())
        _tf_check_font(Diff3D.load_ttf(path), plain)
        _tf_check_font(Diff3D.TTFLoader(path), plain)
    finally
        rm(path; force=true)
    end
end

@testset "TTFLoader matches three.js TTFLoader on a synthetic CFF font" begin
    # Type 2 charstrings: width from hstemhm/hmoveto, hintmask, every line and
    # curve operator, flex/hflex/hflex1/flex1, local and global subroutines,
    # shortint and 16.16 operands, an ignored reserved operator (stack kept)
    # and an ignored escape (stack cleared). Glyphs reached from two code
    # points take the charstring width (three.js reads advanceWidth before
    # and after the path is built); CFF glyphs have no x bounds.
    plain = Dict(" " => (1806.0, 0.0, 0.0, ""), "A" => (903.0, 0.0, 0.0, _TF_SYNTH_OTF_A),
                 "E" => (903.0, 0.0, 0.0, _TF_SYNTH_OTF_A), "B" => (931.0, 0.0, 0.0, _TF_SYNTH_OTF_B),
                 "C" => (931.0, 0.0, 0.0, _TF_SYNTH_OTF_B), "D" => (833.0, 0.0, 0.0, ""))
    _tf_check_font(Diff3D.load_ttf(_tf_synth_otf()), plain)
    rev = Dict(k => (v[1], v[2], v[3], replace(v[4], "z " => "")) for (k, v) in plain)
    _tf_check_font(Diff3D.load_ttf(_tf_synth_otf(); reversed=true), rev)
    _tf_check_font(Diff3D.load_ttf(_tf_woff(_tf_synth_otf())), plain)
end

@testset "TTFLoader fonts drive FontLoader text and TextGeometry" begin
    # Typeface outlines from TTFLoader contain `z`, which FontLoader.js ignores.
    json = """{"familyName":"Z","resolution":1000,"ascender":800,"descender":-200,
    "boundingBox":{"yMin":-200,"yMax":800,"xMin":0,"xMax":900},"underlineThickness":50,
    "glyphs":{"Z":{"ha":600,"x_min":0,"x_max":500,"o":"m 0 0 l 500 0 l 500 500 z m 100 100 l 200 100 l 200 200 z "},
              "Y":{"ha":600,"x_min":0,"x_max":500,"o":"m 0 0 l 500 0 l 500 500 m 100 100 l 200 100 l 200 200 "}}}"""
    path = tempname() * ".json"
    font = try
        write(path, json)
        load_font(path)
    finally
        rm(path; force=true)
    end
    @test _tf_cmds(font.glyphs["Z"].commands) == _tf_cmds(font.glyphs["Y"].commands)
    @test length(font.glyphs["Z"].commands) == 6
    ttf = Diff3D.load_ttf(_tf_synth_ttf())
    for triangulation in (:ear_clip, :earcut)
        g = TextGeometry(ttf, "AB D"; size=1.0, depth=0.1, curve_segments=3, triangulation=triangulation)
        @test g.n_faces > 0
        @test all(isfinite, g.positions)
    end
    otf = Diff3D.load_ttf(_tf_synth_otf())
    @test TextGeometry(otf, "AB"; size=1.0, depth=0.1, triangulation=:earcut).n_faces > 0
end

@testset "TTFLoader matches three.js TTFLoader on system fonts (skipped when absent)" begin
    # sha256 of the font file, then of the canonical FontData (metadata,
    # outline strings and parsed commands) that three.js TTFLoader (node)
    # produced for it, read back through load_font.
    cases = [("/System/Library/Fonts/Supplemental/Arial.ttf", false,
              "525979822591a3447cfc49d943d6f7683508e25543407871c0ed8fed05fd2bd9",
              "6aeef0ec258c988cda9612e1d3ce77bf1c292d2400cfe14d6b39a06bef495123"),
             ("/System/Library/Fonts/Supplemental/STIXGeneral.otf", false,
              "5add3f3f2bd7fd897d2fa5ccbe468607c52111dc44cdfaaf2d851a574f5357a7",
              "00b0b5caa983ce07606e4826f0e9c1c9f9829235544b397ff09f6bc575510512"),
             ("/System/Library/Fonts/Supplemental/NotoSansJavanese-Regular.otf", true,
              "18254c5855aa9ec145cbcbf3c2db69daf52f323e3ac2b049d137b6ec85c50a28",
              "0de9d37c1027f9bc5b39578df9a4a6d88732f19bc3d63ed773a900f9766b3b57"),
             ("/System/Library/Fonts/Keyboard.ttf", true,
              "8f28913b1a93088199ea084ca5be75e8a9e2927f97e67381967d12a229279d13",
              "5465f704544da368e5ce6e82598ba8603be84130eda9317c2f7f3825e8f08aaa")]
    function canonical(f)
        io = IOBuffer()
        print(io, f.family_name, '|', f.resolution, '|', f.ascender, '|', f.descender, '|', f.line_height, '\n')
        for k in sort!(collect(keys(f.glyphs)))
            g = f.glyphs[k]
            print(io, repr(k), ' ', g.advance_width, ' ', g.x_min, ' ', g.x_max, ' ', g.outline, '\n')
            for c in g.commands
                print(io, c.kind, [(q.x, q.y) for q in c.points], '\n')
            end
        end
        return bytes2hex(sha256(take!(io)))
    end
    for (path, reversed, file_sha, expected) in cases
        if isfile(path) && bytes2hex(open(sha256, path)) == file_sha
            @test canonical(Diff3D.load_ttf(path; reversed=reversed)) == expected
        else
            @test_skip basename(path)
        end
    end
end

@testset "TTFLoader rejects malformed fonts with bounded work" begin
    reject(bytes, needle) = try
        Diff3D.load_ttf(bytes)
        false
    catch err
        err isa ArgumentError && occursin(needle, err.msg)
    end
    ttf = _tf_synth_ttf()
    @test reject(UInt8[], "too short")
    @test reject(vcat(Vector{UInt8}(codeunits("wOF2")), ttf[5:end]), "unsupported OpenType signature")
    @test reject(vcat(Vector{UInt8}(codeunits("ttcf")), ttf[5:end]), "collections")
    bad_magic = copy(ttf)
    head_at = _tf_rd32(ttf, 12 + 16 * 2 + 8)        # third table record is head
    bad_magic[head_at + 13] = 0x00
    @test reject(bad_magic, "magic number")
    format6 = vcat(_tf_be16(0), _tf_be16(1), _tf_be16(3), _tf_be16(1), _tf_be32(12),
                   _tf_be16(6), _tf_be16(10), _tf_be16(0), _tf_be16(0x41), _tf_be16(0))
    @test reject(_tf_synth_ttf(cmap_bytes=format6), "format 4 and 12")
    @test reject(_tf_synth_ttf(cmap_bytes=_tf_cmap4([(0x41, 9)])), "missing glyph 9")
    # composite cycles and point blow-up (glyph k = two copies of glyph k - 1)
    square = _tf_glyf_simple(_tf_SYNTH_GLYPHS[1])
    @test reject(_tf_synth_ttf(cmap_bytes=_tf_cmap4([(0x41, 1)]), glyphs=[square, _tf_glyf_refs([1])]),
                 "component cycle")
    doubling = vcat([square], [_tf_glyf_refs([k - 1, k - 1]) for k in 1:20])
    t = @elapsed @test reject(_tf_synth_ttf(cmap_bytes=_tf_cmap4([(0x41, 20)]), glyphs=doubling), "too many points")
    @test t < 30
    # charstring recursion and exponential subroutine fan-out
    glyph = _tf_cs(0, 0, :rmoveto, -107, :callsubr, :endchar)
    charstrings = [_tf_cs(:endchar), glyph, _tf_cs(:endchar), _tf_cs(:endchar)]
    @test reject(_tf_synth_otf(subrs=[_tf_cs(-107, :callsubr, :return)], charstrings=charstrings), "nest too deeply")
    fan = [i < 39 ? _tf_cs(i - 106, :callsubr, i - 106, :callsubr, :return) : _tf_cs(1, 1, :rlineto, :return)
           for i in 0:39]
    t = @elapsed @test reject(_tf_synth_otf(subrs=fan, charstrings=charstrings), "too many operations")
    @test t < 30
    @test reject(_tf_synth_otf(charstrings=[_tf_cs(:endchar), _tf_cs(5, :rlineto), _tf_cs(:endchar), _tf_cs(:endchar)]),
                 "stack underflow")

    # Every truncation, and seeded byte corruption, either loads or raises an
    # ArgumentError, within bounded time and allocation.
    state = Ref(UInt64(0x2545F4914F6CDD1D))
    next() = (state[] = state[] * 6364136223846793005 + 1442695040888963407; Int(state[] >> 33))
    outcomes = Dict{String,Int}()
    worst_time = 0.0
    worst_bytes = 0
    for font in (ttf, _tf_synth_otf(), _tf_woff(ttf))
        inputs = [font[1:n] for n in 0:(length(font) - 1)]
        for _ in 1:400
            b = copy(font)
            for _ in 1:(1 + next() % 6)
                b[1 + next() % length(b)] = UInt8(next() % 256)
            end
            push!(inputs, b)
        end
        for (k, bytes) in enumerate(inputs)
            r = @timed try
                Diff3D.load_ttf(bytes; reversed=isodd(k))
                "loaded"
            catch err
                err isa ArgumentError ? "ArgumentError" : string(typeof(err))
            end
            outcomes[r.value] = get(outcomes, r.value, 0) + 1
            worst_time = max(worst_time, r.time)
            worst_bytes = max(worst_bytes, r.bytes)
        end
    end
    @test issubset(keys(outcomes), ("loaded", "ArgumentError"))
    @test get(outcomes, "ArgumentError", 0) > 1000
    @test worst_bytes < 256 * 2^20
    @test worst_time < 30
end

@testset "TTFLoader WOFF decompresses only the tables it reads, up to 256 MiB" begin
    # opentype.js parseBuffer inflates only the tables it parses, so a WOFF
    # whose unread table holds a corrupt (or huge) zlib stream still loads.
    ttf = _tf_synth_ttf()
    n = (Int(ttf[5]) << 8) | ttf[6]
    tables = Pair{String,Vector{UInt8}}[]
    for i in 0:(n - 1)
        rec = 12 + 16i
        off = _tf_rd32(ttf, rec + 8)
        push!(tables, String(ttf[rec + 1:rec + 4]) => ttf[off + 1:off + _tf_rd32(ttf, rec + 12)])
    end
    push!(tables, "zzzz" => zeros(UInt8, 4096))
    woff = _tf_woff(_tf_sfnt(UInt8[0, 1, 0, 0], tables))
    m = (Int(woff[13]) << 8) | woff[14]
    record(tag) = 44 + 20 * only(i for i in 0:(m - 1) if woff[44 + 20i + 1:44 + 20i + 4] == codeunits(tag))
    rec = record("zzzz")
    off = _tf_rd32(woff, rec + 4)
    comp = _tf_rd32(woff, rec + 8)
    @test comp < _tf_rd32(woff, rec + 12)          # stored compressed
    corrupt = copy(woff)
    corrupt[off + 1:off + comp] .= 0xff
    summary(f) = Dict(k => (g.advance_width, g.x_min, g.x_max, g.outline) for (k, g) in f.glyphs)
    expected = summary(Diff3D.load_ttf(ttf))
    @test summary(Diff3D.load_ttf(corrupt)) == expected
    # A table that is read may not claim more than 256 MiB once inflated:
    # the cap is checked before any inflation.
    oversized = copy(woff)
    post = record("post")
    oversized[post + 13:post + 16] = _tf_be32(2^28 + 1)
    err = try
        Diff3D.load_ttf(oversized)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError && occursin("more than 268435456 bytes", err.msg)
end

# --- (b) curves, curve extrude paths and computeMorphedAttributes -----------
# Oracle values from three.js r186 under node: examples/jsm/curves/NURBSCurve.js
# (getPoint/getTangent/getLength), Curve.getSpacedPoints/computeFrenetFrames,
# TubeGeometry, CatmullRomCurve3, and examples/jsm/utils/BufferGeometryUtils.js
# computeMorphedAttributes (Float32 attributes, hence the 1e-6 tolerances).

const _tf_NURBS_POINTS = [(0.0, 0.0, 0.0), (1.5046040515653774, 1.4727703235990528, 0.3841094448829255), (2.8295739348370925, 1.8496240601503757, 0.9523809523809523), (3.1585800503097072, 1.6006157735847897, 1.1642541691080768), (3.6038781163434903, 1.1966759002770082, 1.3573407202216068), (4.171428571428571, 0.8924369747899159, 1.4302521008403362), (5.749395969075124, 1.1552700870424015, 1.0150868187872721), (7.0, 3.0, 0.0)]
const _tf_NURBS_TANGENTS = [(0.447213595499958, 0.894427190999916, 0.0), (0.8114561700549006, 0.5145477421528156, 0.2770911494892464), (0.8015950295742161, -0.3462890527760613, 0.48736977798112363), (0.652221842649691, -0.6461924121329867, 0.39628529429237447), (0.7824982777701315, -0.5847911188729231, 0.2138125173467003), (0.9476037173448618, -0.31944107213661643, 0.002143899812997512), (0.7192848642407438, 0.5705311908742063, -0.39638799718689083), (0.408248290463863, 0.816496580927726, -0.408248290463863)]
const _tf_NURBS_LENGTH = 9.652167738920612
const _tf_NURBS_TUBE_POS = [1.020306944847107, 1.1065967082977295, 0.53350430727005, 0.8733860850334167, 1.3674094676971436, 0.3470427989959717, 0.9920523762702942, 1.344743013381958, 0.015709906816482544, 1.2123130559921265, 1.0699217319488525, -0.0026035630144178867, 1.2297754287719727, 0.9227391481399536, 0.31741097569465637, 1.020306944847107, 1.1065967082977295, 0.53350430727005]
const _tf_NURBS_TUBE_NRM = [-0.15086601674556732, -0.18561771512031555, 0.970971405506134, -0.6406024098396301, 0.6837580800056458, 0.349433034658432, -0.24504803121089935, 0.6082034707069397, -0.7550099492073059, 0.4891543686389923, -0.3078676760196686, -0.8160548210144043, 0.5473620295524597, -0.7984761595726013, 0.2506603002548218, -0.15086601674556732, -0.18561771512031555, 0.970971405506134]
const _tf_NURBS6_SPACED = [(0.0, 0.0, 0.0), (1.0655667743127217, 1.1622819996405545, 0.24221288724622225), (2.4044740961184936, 1.8781278091758347, 0.732705095765288), (3.622310026683067, 1.183036432918048, 1.3622745249506696), (5.1228925094995335, 0.8442302704943065, 1.280306350899614), (6.272453028993601, 1.7292345538246676, 0.6637136152234558), (7.0, 3.0, 0.0)]
const _tf_NURBS6_NORMALS = [(0.0, 0.0, -1.0000000000000002), (0.1508660118299913, 0.18561772245920524, -0.9709714246998059), (0.3480719874284087, 0.277707106944047, -0.8953907830218077), (0.41910284878220117, 0.26085889893988967, -0.8696582299883746), (-0.3585781832473233, 0.4204500972177452, -0.8334526994668856), (-0.7440271401445797, 0.16493578522653568, -0.6474718538129556), (-0.788772595544187, 0.09038447224488463, -0.6080036510544169)]
const _tf_NURBS6_BINORMALS = [(-0.8944271909999162, 0.4472135954999581, 0.0), (-0.6245498646429974, 0.7792566716979362, 0.05192789412896477), (-0.2717770910372165, 0.9439911706693127, 0.1871306561890112), (0.4488866093909668, 0.7730529095466823, 0.4482075534290909), (-0.06702568383891934, 0.8789254430042146, 0.47222624169540944), (-0.4111890255477148, 0.6507793865790087, 0.6382865933677214), (-0.45953359599905297, 0.5702315148344113, 0.6809294336697694)]
const _tf_CATMULL8_SPACED = [(0.0, 0.0, 0.0), (1.6364512262684419, 0.6828928093826898, -0.07591731236287462), (2.768859962196722, 1.9913119771720524, 0.4372824798409868), (2.6142772591819883, 3.3808278359240944, 1.27569770938317), (1.0023948912179443, 3.973563494706576, 1.8530480980158133), (-0.7083329038710441, 3.6656074761377546, 1.8661808149906771), (-1.8719887186869486, 2.4408340429333557, 1.2276946965698368), (-1.4324195099783497, 0.955958131957384, 0.5109397256911168), (0.0, 0.0, 0.0)]
const _tf_CATMULL8_NORMALS = [(-0.13265781596300977, -0.9907575618090971, 0.028308259960961497), (0.6208054981277243, -0.7837324890245185, -0.019076664850565625), (0.8499862171664982, -0.5218508892584289, 0.07207690342386373), (0.6192366064104283, 0.42674352711666935, 0.6591175823366574), (0.29301693432845727, 0.5558329653456036, 0.7779400946293132), (-0.5090914874851644, 0.39295030290495603, 0.7657779814130494), (-0.7900954295870711, 0.08578985966923809, 0.6069508317183138), (-0.6735197840080347, -0.708807318586854, 0.20967423701419108), (-0.1338768751969956, -0.9905872318322032, 0.028529255484502292)]
const _tf_CATMULL8_BINORMALS = [(-0.20869435921010998, 3.469446951953614e-18, -0.9779809121009886), (0.06860611042530991, 0.07855190673222692, -0.9945465296108782), (0.2673687230301772, 0.30944781020844786, -0.912554666144669), (0.15665210916071923, 0.7554045742144592, -0.6362578454929806), (0.005060217267407324, 0.8127406348242289, -0.582603685799116), (-0.3090982727716934, 0.7468851598019985, -0.5887451195866488), (-0.4525104580481952, 0.5863031347393408, -0.6719247871241497), (-0.37637303524285737, 0.0847227666822277, -0.9225862513325173), (-0.20896270583465276, 7.656231628817498e-05, -0.9779236072968436)]
const _tf_MORPH_FULL = (p=[0.05000000074505806, 0.0, 0.25, 0.5, 0.10000000149011612, 0.0, 1.0, 0.25, 0.15000000596046448, 0.4375, 1.4375, 0.4375, 0.0, 0.0, 0.5, 2.25, 2.25, 2.25],
    n=[0.0, 0.5, 1.0, 0.0, 0.0, 1.0, 0.5, 1.0, 0.0, 1.0, 0.0, 0.5, 0.8500000238418579, 0.800000011920929, 0.0, 0.0, 0.0, -1.0])
const _tf_MORPH_UNALIGNED = (p=[0.05000000074505806, 0.0, 0.25, 0.5, 0.10000000149011612, 0.0, 1.0, 0.25, 0.15000000596046448, 0.4375, 1.4375, 0.4375, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0],
    n=[0.0, 0.5, 1.0, 0.0, 0.0, 1.0, 0.5, 1.0, 0.0, 1.0, 0.0, 0.5, 0.8500000238418579, 0.800000011920929, 0.0, 0.0, 0.0, 0.0])
const _tf_MORPH_NONINDEXED = (p=[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.25, 0.15000000596046448, 0.4375, 1.4375, 0.4375, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0],
    n=[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 1.0, 0.0, 1.0, 0.0, 0.5, 0.8500000238418579, 0.800000011920929, 0.0, 0.0, 0.0, 0.0])
const _tf_MORPH_GROUPS = (p=[0.05000000074505806, 0.0, 0.25, 0.5, 0.10000000149011612, 0.0, 1.0, 0.25, 0.15000000596046448, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.0],
    n=[0.0, 0.5, 1.0, 0.0, 0.0, 1.0, 0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 0.8500000238418579, 0.800000011920929, 0.0, 0.0, 0.0, 0.0])
const _tf_MORPH_SKINNED = (p=[0.05837440863251686, 0.3195899724960327, -1.0, 0.9807576537132263, 0.3773188591003418, -1.0, 0.6955471038818359, 1.0144405364990234, -0.8500000238418579, 0.0701187402009964, 1.344348669052124, -0.5, 0.15760362148284912, 0.48634910583496094, 0.25, 1.355363368988037, 2.2652971744537354, 1.0],
    n=[-0.028007322922348976, 0.8103130459785461, 0.0, 0.01786540448665619, 0.13179191946983337, 0.0, 0.21787884831428528, 0.8666804432868958, -1.0, 0.9910672903060913, 0.05910404026508331, -0.5, 0.6710129976272583, 0.9092839360237122, -1.0, 0.03573080897331238, -0.23641616106033325, -2.0])

const _tf_NURBS_TS = [0, 0.1, 0.25, 0.37, 0.5, 0.6, 0.83, 1]
_tf_xyz(p) = (p.x, p.y, p.z)
_tf_close3(a, b, tol) = all(abs(a[k] - b[k]) <= tol for k in 1:3)
_tf_nurbs() = NURBSCurve(3, [0, 0, 0, 0, 0.25, 0.6, 1, 1, 1, 1],
    [Vec4(0.0, 0, 0, 1), Vec4(1.0, 2, 0, 0.5), Vec4(3.0, 2, 1, 2), Vec4(4.0, 0, 2, 1),
     Vec4(6.0, 1, 1, 1.5), Vec4(7.0, 3, 0, 1)])
_tf_extrude_shape() = [Vec2(-0.2, -0.1), Vec2(0.3, -0.1), Vec2(0.25, 0.2), Vec2(-0.1, 0.25)]

# Ring i, vertex k of a default-mode curve extrusion is
# spaced[i] + normals[i] * x_k + binormals[i] * y_k (three.js ExtrudeGeometry).
function _tf_ring_error(g, shape, rings, spaced, normals, binormals)
    err = 0.0
    for i in 1:rings, (k, pt) in enumerate(shape)
        vi = (i - 1) * length(shape) + k
        for c in 1:3
            expect = spaced[i][c] + normals[i][c] * pt.x + binormals[i][c] * pt.y
            err = max(err, abs(g.positions[3vi - 3 + c] - expect))
        end
    end
    return err
end

@testset "NURBSCurve is a Curve matching three.js NURBSCurve" begin
    c = _tf_nurbs()
    @test c isa Diff3D.Curve{Vec3{Float64}}
    for (t, p, tan) in zip(_tf_NURBS_TS, _tf_NURBS_POINTS, _tf_NURBS_TANGENTS)
        @test _tf_close3(_tf_xyz(get_point(c, t)), p, 1e-12)
        # analytic calcNURBSDerivatives tangent, not a finite difference
        @test _tf_close3(_tf_xyz(get_tangent(c, t)), tan, 1e-12)
    end
    @test isapprox(get_length(c), _tf_NURBS_LENGTH; atol=1e-10)
    frames = compute_frenet_frames(c, 6, false)
    for i in 1:7
        @test _tf_close3(_tf_xyz(frames.normals[i]), _tf_NURBS6_NORMALS[i], 1e-10)
        @test _tf_close3(_tf_xyz(frames.binormals[i]), _tf_NURBS6_BINORMALS[i], 1e-10)
    end
    tube = TubeGeometry(c; tubular_segments=12, radius=0.3, radial_segments=5, closed=false)
    @test tube.n_vertices == 78 && length(tube.indices) == 360
    @test maximum(abs.(tube.positions[37:54] .- _tf_NURBS_TUBE_POS)) < 1e-6
    @test maximum(abs.(tube.normals[37:54] .- _tf_NURBS_TUBE_NRM)) < 1e-6
end

@testset "ExtrudeGeometry follows a curve extrude_path like three.js" begin
    shape = _tf_extrude_shape()
    g = ExtrudeGeometry(shape; extrude_path=_tf_nurbs(), steps=6)
    @test _tf_ring_error(g, shape, 7, _tf_NURBS6_SPACED, _tf_NURBS6_NORMALS,
                         _tf_NURBS6_BINORMALS) < 1e-12
    @test g.n_vertices == 36 && g.n_faces == 52            # 7 rings + 2 caps
    closed = CatmullRomCurve([Vec3(0.0, 0, 0), Vec3(2.0, 1, 0), Vec3(3.0, 3, 1),
                              Vec3(0.0, 4, 2), Vec3(-2.0, 2, 1)]; closed=true)
    gc = ExtrudeGeometry(shape; extrude_path=closed, steps=8)
    @test _tf_ring_error(gc, shape, 8, _tf_CATMULL8_SPACED, _tf_CATMULL8_NORMALS,
                         _tf_CATMULL8_BINORMALS) < 1e-12
    @test gc.n_vertices == 32 && gc.n_faces == 64          # wrapped walls, no caps
    @test_throws ArgumentError ExtrudeGeometry(shape; extrude_path=closed, steps=2)
    @test_throws ArgumentError ExtrudeGeometry(shape; extrude_path=LineCurve(Vec2(0.0, 0), Vec2(1.0, 0)))
end

@testset "Polyline extrude_path output is unchanged by the curve sweep" begin
    star = [Vec2(cos(k * pi / 5) * (isodd(k) ? 0.4 : 1.0), sin(k * pi / 5) * (isodd(k) ? 0.4 : 1.0)) for k in 0:9]
    helix = [Vec3(cos(t), sin(t), 0.3t) for t in range(0, 4pi; length=40)]
    square = [Vec2(-1.0, -1.0), Vec2(1.0, -1.0), Vec2(1.0, 1.0), Vec2(-1.0, 1.0)]
    hole = [Vec2(-0.3, -0.3), Vec2(-0.3, 0.3), Vec2(0.3, 0.3), Vec2(0.3, -0.3)]
    loop = [Vec3(2cos(t), 2sin(t), 0.2sin(3t)) for t in range(0, 2pi; length=25)]
    zig = [Vec3(0.0, 0, 0), Vec3(1.0, 0, 0), Vec3(1.0, 1, 0), Vec3(1.0, 1, 1), Vec3(0.0, 1, 1)]
    # Counts, index-weighted index sum, and plain and index-weighted sums of
    # positions, normals and uvs: any reordering or value change above ~1e-10
    # shows. The buffers are byte-identical to v2.0.0 on a given Julia, but sin,
    # cos and friends differ by an ulp between Julia 1.10 and 1.13, hence the
    # tolerance instead of a byte hash.
    checksums(g) = (g.n_vertices, g.n_faces, sum(k * i for (k, i) in enumerate(g.indices)),
        [f(v) for v in (g.positions, g.normals, g.uvs)
              for f in (v -> sum(v), v -> sum(k * x for (k, x) in enumerate(v)))]...)
    # v2.0.0 (6b7e848) values, computed on Julia 1.10.12
    expected = [
        (420, 796, 773827205, 821.6813487046278, 648780.9515647277, 3.0718200903607054,
         3005.0056086681757, 379.9999999999998, 180112.19528199025),
        (192, 384, 82772640, -3.4139358007223564e-14, -41006.578399062535, 1.4432899320127035e-15,
         -193.45525928081537, 180.0, 41296.0),
        (70, 96, 1713730, 100.0, 11886.958681254078, -20.0, -3424.810453671209,
         47.50000000000001, 2918.8619486569437)]
    for (g, e) in zip((ExtrudeGeometry(star; extrude_path=helix),
                       ExtrudeGeometry(square; holes=[hole], extrude_path=loop),
                       ExtrudeGeometry(star; extrude_path=zig)), expected)
        c = checksums(g)
        @test c[1:3] == e[1:3]
        @test all(isapprox(c[k], e[k]; rtol=1e-12, atol=1e-9) for k in 4:9)
    end
end

const _tf_MORPH_POS = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0.5, 0.5, 1, 2, 2, 2.0]
const _tf_MORPH_NRM = [0, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0.6, 0.8, 0, 0, 0, -1.0]
const _tf_MORPH_IDX = [0, 1, 2, 0, 2, 3, 1, 4, 2, 3, 2, 5] .+ 1

function _tf_morph_geometry(indexed; second_target=true)
    g = BufferGeometry(copy(_tf_MORPH_POS), copy(_tf_MORPH_NRM), Float64[],
                       indexed ? copy(_tf_MORPH_IDX) : Int[], 6, indexed ? 4 : 2)
    set_attribute!(g, :morphPosition0, [0.1, 0, 0, 0, 0.2, 0, 0, 0, 0.3, 1, 1, 1, -0.5, 0, 0.5, 0, 0, 0], 3)
    second_target && set_attribute!(g, :morphPosition1,
                                    [0, 0, -1, 2, 0, 0, 0, 3, 0, 0.25, 0.25, 0.25, 1, 2, 3, -1, -1, -1.0], 3)
    set_attribute!(g, :morphNormal0, [0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0.5, 0, 0, 0, 0, 0.0], 3)
    return g
end

function _tf_morph_mesh(g; materials=false)
    m = Mesh(g, materials ? [MeshBasicMaterial(), MeshBasicMaterial()] : MeshBasicMaterial())
    m.morph_target_influences = [0.5, -0.25]
    return m
end

_tf_morph_error(r, o) = max(maximum(abs.(r.morphed_position_attribute.data .- o.p)),
                            maximum(abs.(r.morphed_normal_attribute.data .- o.n)))

@testset "compute_morphed_attributes matches three.js computeMorphedAttributes" begin
    r = Diff3D.compute_morphed_attributes(_tf_morph_mesh(_tf_morph_geometry(true)))
    @test _tf_morph_error(r, _tf_MORPH_FULL) < 1e-6
    @test r.position_attribute.data == _tf_MORPH_POS && r.normal_attribute.data == _tf_MORPH_NRM
    g = _tf_morph_geometry(true); set_draw_range!(g, 2, 7)       # three.js setDrawRange(1, 7)
    @test _tf_morph_error(Diff3D.compute_morphed_attributes(_tf_morph_mesh(g)), _tf_MORPH_UNALIGNED) < 1e-6
    g = _tf_morph_geometry(false); set_draw_range!(g, 3, 3)      # setDrawRange(2, 3)
    @test _tf_morph_error(Diff3D.compute_morphed_attributes(_tf_morph_mesh(g)), _tf_MORPH_NONINDEXED) < 1e-6
    g = _tf_morph_geometry(true); set_draw_range!(g, 1, 9)
    add_group!(g, 1, 1, 0); add_group!(g, 3, 2, 1)               # addGroup(0, 3), addGroup(6, 6)
    @test _tf_morph_error(Diff3D.compute_morphed_attributes(_tf_morph_mesh(g; materials=true)),
                          _tf_MORPH_GROUPS) < 1e-6
    # Unbounded counts (three.js setDrawRange(1, Infinity)) saturate instead of
    # overflowing; the triangle at entry 10 reaches vertex 5, so all are written.
    g = _tf_morph_geometry(true); set_draw_range!(g, 2, typemax(Int))
    @test _tf_morph_error(Diff3D.compute_morphed_attributes(_tf_morph_mesh(g)), _tf_MORPH_FULL) < 1e-6
    g = _tf_morph_geometry(true); add_group!(g, 1, typemax(Int), 0)
    @test _tf_morph_error(Diff3D.compute_morphed_attributes(_tf_morph_mesh(g; materials=true)),
                          _tf_MORPH_FULL) < 1e-6

    b0 = Bone(); b1 = Bone(); b1.position = Vec3(1.0, 0, 0)
    skeleton = Skeleton([b0, b1])
    sm = SkinnedMesh(_tf_morph_geometry(true; second_target=false), MeshBasicMaterial(), skeleton,
                     [(1, 2, 1, 1), (1, 2, 1, 1), (2, 1, 1, 1), (2, 1, 1, 1), (1, 2, 1, 1), (2, 1, 1, 1)],
                     [(0.75, 0.25, 0, 0), (0.5, 0.5, 0, 0), (1.0, 0, 0, 0), (1.0, 0, 0, 0),
                      (0.25, 0.75, 0, 0), (1.0, 0, 0, 0)];
                     bind_matrix=mat4_translation(0.2, 0, 0), morph_target_influences=[0.5])
    sm.position = Vec3(0.2, 0, 1)                                 # moved after bind (attached)
    b0.position = Vec3(0, 0.5, 0); b1.rotation = Euler(0.0, 0.0, 0.3)
    @test _tf_morph_error(Diff3D.compute_morphed_attributes(sm), _tf_MORPH_SKINNED) < 1e-6

    no_normals = BufferGeometry(copy(_tf_MORPH_POS), Float64[], Float64[], copy(_tf_MORPH_IDX), 6, 4)
    @test_throws ArgumentError Diff3D.compute_morphed_attributes(Mesh(no_normals, MeshBasicMaterial()))
    bad = _tf_morph_geometry(true); bad.indices[1] = 7
    @test_throws ArgumentError Diff3D.compute_morphed_attributes(_tf_morph_mesh(bad))
end

