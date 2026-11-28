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
