using Test, Diff3D

function deepdebug_dashed_svg(length, dasharray; offset="0")
    path = tempname() * ".svg"
    write(path, """<svg xmlns="http://www.w3.org/2000/svg"><path d="M 0 0 L $length 0" fill="none" stroke="red" stroke-width="0.5" stroke-dasharray="$dasharray" stroke-dashoffset="$offset"/></svg>""")
    return load_svg(path)
end

@testset "SVG dash patterns terminate and are bounded" begin
    # Recomputing the dash phase with mod from the accumulated distance landed a
    # few ulps short of a dash boundary for these ordinary patterns, and the
    # loop then pushed the same interval forever.
    for (dasharray, period, visible) in (("0.1 0.2", 0.3, 0.1), ("0.3 0.3", 0.6, 0.3),
                                         ("1 2", 3.0, 1.0), ("0.7", 1.4, 0.7))
        entries = parse.(Float64, split(dasharray))
        # An odd list repeats to an even one (SVG 1.1 section 11.4).
        isodd(length(entries)) && (entries = vcat(entries, entries))
        intervals = Diff3D._svg_dash_intervals(10.0, entries, 0.0)
        @test length(intervals) == ceil(Int, 10.0 / period - 1e-9)
        @test first(intervals)[1] == 0.0
        @test all(i -> i[2] > i[1], intervals)
        @test all(k -> intervals[k + 1][1] >= intervals[k][2], 1:(length(intervals) - 1))
        covered = sum(i -> i[2] - i[1], intervals)
        full = floor(10.0 / period + 1e-9)
        @test covered ≈ full * visible + min(visible, 10.0 - full * period) atol=1e-9
    end
    @test length(svg_strokes(deepdebug_dashed_svg(10, "0.1 0.2"))) == 34
    @test length(svg_strokes(deepdebug_dashed_svg(10, "0.3 0.3"))) == 17
    @test length(svg_strokes(deepdebug_dashed_svg(10, "1 2"))) == 4
    # The path starts `stroke-dashoffset` into the pattern (SVG 1.1 section
    # 11.4): half a period swaps dashes and gaps, and -0.5 is 1.5 modulo 2.
    shifted = Diff3D._svg_dash_intervals(4.0, [1.0, 1.0], 1.0)
    @test shifted == [(1.0, 2.0), (3.0, 4.0)]
    @test Diff3D._svg_dash_intervals(4.0, [1.0, 1.0], -0.5) == [(0.5, 1.5), (2.5, 3.5)]
    @test Diff3D._svg_dash_intervals(4.0, [1.0, 1.0], 0.5) ==
          [(0.0, 0.5), (1.5, 2.5), (3.5, 4.0)]
    # Zero-length entries are skipped, and an all-gap pattern draws nothing.
    @test Diff3D._svg_dash_intervals(3.0, [0.0, 1.0], 0.0) == Tuple{Float64,Float64}[]
    @test Diff3D._svg_dash_intervals(3.0, [1.0, 0.0], 0.0) == [(0.0, 1.0), (1.0, 2.0), (2.0, 3.0)]
    # The number of dashes is the path length over the period, not the file
    # size: a 130-byte document must not ask for millions of them.
    @test_throws ArgumentError svg_strokes(deepdebug_dashed_svg("1e9", "1 2"))
    @test_throws ArgumentError svg_strokes(deepdebug_dashed_svg("1e300", "0 1"))
    @test length(Diff3D._svg_dash_intervals(1.0e5, [1.0, 1.0], 0.0)) == 50_000
end

@testset "SVG use instantiation is bounded" begin
    # Each level uses the previous one twice, so n levels ask for 2^n
    # rectangles from a few hundred bytes.
    function doubling(levels)
        io = IOBuffer()
        print(io, """<svg xmlns="http://www.w3.org/2000/svg"><defs><rect id="l0" width="1" height="1"/>""")
        for i in 1:levels
            print(io, "<g id=\"l$i\"><use href=\"#l$(i - 1)\"/><use href=\"#l$(i - 1)\"/></g>")
        end
        print(io, "</defs><use href=\"#l$levels\"/></svg>")
        path = tempname() * ".svg"
        write(path, take!(io))
        return path
    end
    @test length(svg_shapes(load_svg(doubling(6)))) == 64
    @test length(svg_shapes(load_svg(doubling(11)))) == 2048
    @test_throws ArgumentError load_svg(doubling(24))
    allocated = @allocated try
        load_svg(doubling(40))
    catch
    end
    @test allocated < 300_000_000
    # One `use` per marker is ordinary: the limit grows with the document.
    io = IOBuffer()
    print(io, """<svg xmlns="http://www.w3.org/2000/svg"><defs><rect id="m" width="1" height="1"/></defs>""")
    for i in 1:6000
        print(io, "<use href=\"#m\" x=\"$i\"/>")
    end
    print(io, "</svg>")
    markers = tempname() * ".svg"
    write(markers, take!(io))
    @test length(svg_shapes(load_svg(markers))) == 6000
end

@testset "parse_ies reads headers that are not valid UTF-8" begin
    # Manufacturers' files are often Latin-1; 0xB0 is the degree sign there.
    body = "C\nTILT=NONE\n1 1000 1 3 1 1 1 0.5 0.5 0\n1 1 100\n0 45 90\n0\n100 80 60\n"
    latin1 = String(vcat(Vector{UInt8}("IESNA:LM-63-2002\n[TEST] 25"), UInt8[0xb0],
                         Vector{UInt8}(body)))
    ascii = "IESNA:LM-63-2002\n[TEST] 25 " * body
    @test parse_ies(latin1).candela == parse_ies(ascii).candela == [100.0, 80.0, 60.0]
    @test parse_ies(replace(ascii, "TILT=NONE" => "tilt=none")).candela == [100.0, 80.0, 60.0]
    @test_throws ArgumentError parse_ies(replace(ascii, "TILT=NONE\n" => ""))
end

@testset "base64_decode skips bytes that are not valid UTF-8" begin
    @test base64_decode(String(UInt8[0xff, UInt8('Q'), UInt8('Q'), UInt8('='), UInt8('=')])) == UInt8[0x41]
    @test base64_decode("☃QQ==") == UInt8[0x41]
    @test base64_decode("SGVsbG8s\nIHdvcmxk IQ==") == Vector{UInt8}("Hello, world!")
    @test base64_decode(SubString("xxSGk=yy", 3, 6)) == Vector{UInt8}("Hi")
end

@testset "save_pdf writes page sizes without exponents" begin
    # PDF numbers are plain decimals (ISO 32000-1 section 7.3.3); Julia prints
    # 1.0e6 and above with an exponent.
    @test Diff3D._pdf_number(1000008.0) == "1000008.00"
    @test Diff3D._pdf_number(72.0) == "72.0"
    @test Diff3D._pdf_number(123456.78) == "123456.78"
    path = tempname() * ".pdf"
    save_pdf(path, zeros(1, 13889, 3); dpi=1)
    text = String(read(path))
    @test occursin("/MediaBox [0 0 1000008.00 72.0]", text)
    @test !occursin(r"MediaBox \[[^\]]*e", text)
    save_pdf(path, zeros(4, 8, 3))
    @test occursin("/MediaBox [0 0 4.0 2.0]", String(read(path)))
end
