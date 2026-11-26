using Test, Diff3D, Base64, SHA

# Regression tests for the loaders-mesh audit (STL/OBJ/PLY/XYZ loaders, image
# writers, and the JPEG decoder). JPEG reference digests are SHA-256 over the
# H x W x 3 UInt8 RGB bytes (row-major, channel-interleaved) produced by
# libjpeg-turbo 3.2.0 `djpeg -pnm` with JSIMD_FORCENONE=1 (the portable C
# path that src/jpeg.jl mirrors). Fixtures were encoded with cjpeg/jpegtran
# 3.2.0 from a synthetic gradient source.

_audit3_jpeg_digest(img) =
    bytes2hex(sha256([img[y, x, c] for y in 1:size(img, 1)
                      for x in 1:size(img, 2) for c in 1:3]))

function _audit3_file(bytes, ext)
    path = tempname() * ext
    write(path, bytes)
    return path
end

# 24x8 grayscale progressive JPEG holding only a DC scan (jpegtran script
# "0: 0 0 0 0;"), so libjpeg's block smoothing interpolates every AC term and
# the DC itself from the 5x5 DC window.
const _AUDIT3_JPEG_DC_ONLY = base64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoM" *
    "DAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wgALCAAIABgBAREA/8QAFQAB" *
    "AQAAAAAAAAAAAAAAAAAABgf/2gAIAQEAAAAAn7Zv/9k=")

@testset "JPEG block smoothing slides each DC window row separately" begin
    # jdcoefct.c decompress_smooth_data "Advance for next column" shifts
    # DC01..DC04 <- DC02..DC05 (and likewise per row); DC05/DC10/... keep
    # their value at the right edge. Shifting the flattened 25-entry window
    # pulled the next row's first DC into the last two block columns.
    img = Diff3D._jpeg_decode_rgb8(_AUDIT3_JPEG_DC_ONLY)
    @test size(img) == (8, 24, 3)
    @test _audit3_jpeg_digest(img) ==
          "0490e1ff73079e04aadf16aab216a251d04eae001fa95354f758bff2fcc1aeeb"
end

# JPEG segment walker for the marker tests: (marker, offset of its 0xFF,
# length field). Entropy data after SOS is skipped to the next non-RST marker.
function _audit3_jpeg_segments(b)
    out = Tuple{UInt8,Int,Int}[]
    p = 3
    while p < length(b) && b[p] == 0xFF && b[p + 1] != 0xD9
        m = b[p + 1]
        len = (Int(b[p + 2]) << 8) | b[p + 3]
        push!(out, (m, p, len))
        p += 2 + len
        if m == 0xDA
            while p < length(b) && !(b[p] == 0xFF && b[p + 1] != 0x00 &&
                                     !(0xD0 <= b[p + 1] <= 0xD7))
                p += 1
            end
        end
    end
    return out
end

# 16x8 4:2:0 baseline JPEG (cjpeg -quality 75) with its DHT segments removed,
# as Motion-JPEG frames are stored. cjpeg's unoptimized tables are the
# T.81 Annex K.3 tables, so the file decodes identically to the original.
const _AUDIT3_JPEG_NO_DHT = base64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof" *
    "Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwh" *
    "MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAAR" *
    "CAAIABADASIAAhEBAxEB/9oADAMBAAIRAxEAPwDHtfEe2BE38sf0/wA4robbxH/qoxJ7kfy/" *
    "rRRXXjcJSvONtuSPy0l+b+49fIsDR93Q/9k=")

# 16x8 grayscale progressive JPEG (cjpeg -quality 90 -grayscale -progressive):
# DC first/refine and AC first/refine scans.
const _AUDIT3_JPEG_PROG_GRAY = base64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoM" *
    "DAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wgALCAAIABABAREA/8QAFAAB" *
    "AAAAAAAAAAAAAAAAAAAABv/aAAgBAQAAAAE8t//EABcQAAMBAAAAAAAAAAAAAAAAAAADBRH/" *
    "2gAIAQEAAQUCRaxabR//xAAaEAACAgMAAAAAAAAAAAAAAAAAAQIREjFh/9oACAEBAAY/Akr2" *
    "Qjl0/8QAGRAAAgMBAAAAAAAAAAAAAAAAAAFBgaHw/9oACAEBAAE/IZ7ubQus/9oACAEBAAAA" *
    "EP8A/8QAGhABAAIDAQAAAAAAAAAAAAAAAQARITGR8P/aAAgBAQABPxAhjQKV0ZXtdmk9ANx/" *
    "/9k=")

@testset "JPEG sequential frames default to the T.81 Annex K Huffman tables" begin
    # jdhuff.c jinit_huff_decoder -> jstdhuff.c std_huff_tables: slots 0/1
    # left undefined by the first scan get the standard tables.
    @test isempty(filter(s -> s[1] == 0xC4,
                         _audit3_jpeg_segments(_AUDIT3_JPEG_NO_DHT)))
    img = Diff3D._jpeg_decode_rgb8(_AUDIT3_JPEG_NO_DHT)
    @test size(img) == (8, 16, 3)
    # djpeg 3.2.0 output for this exact file.
    @test _audit3_jpeg_digest(img) ==
          "17463a6df1dc1f1738a0bf4ebd904c63c7acb225568465be16bad49c29198774"
    @test load_jpeg(_audit3_file(_AUDIT3_JPEG_NO_DHT, ".jpg")) ==
          Float64.(img) ./ 255
    # Progressive decoding has no default tables (jinit_phuff_decoder).
    prog = copy(_AUDIT3_JPEG_PROG_GRAY)
    m, p, len = first(filter(s -> s[1] == 0xC4, _audit3_jpeg_segments(prog)))
    stripped = vcat(prog[1:p-1], prog[p+2+len:end])
    @test_throws "missing DC Huffman table" Diff3D._jpeg_decode_rgb8(stripped)
end

@testset "JPEG marker parameters libjpeg rejects are errors" begin
    @test _audit3_jpeg_digest(Diff3D._jpeg_decode_rgb8(_AUDIT3_JPEG_PROG_GRAY)) ==
          "05915536155144b45a653d28e02688b66d80d4628388cf4510f7b1136f0b9261"
    # get_dht (jdmarker.c): Tc/Th 0x20 is "Bogus DHT index 32", not slot 0.
    bad = copy(_AUDIT3_JPEG_PROG_GRAY)
    _, p, _ = first(filter(s -> s[1] == 0xC4, _audit3_jpeg_segments(bad)))
    @test bad[p + 4] == 0x00
    bad[p + 4] = 0x20
    @test_throws "DHT index 32 is out of range" Diff3D._jpeg_decode_rgb8(bad)

    # start_pass_phuff_decoder (jdphuff.c): a progressive DC scan needs Se=0.
    bad = copy(_AUDIT3_JPEG_PROG_GRAY)
    _, p, _ = first(filter(s -> s[1] == 0xDA, _audit3_jpeg_segments(bad)))
    se = p + 5 + 2 * bad[p + 4] + 1
    @test bad[se - 1] == 0x00 && bad[se] == 0x00
    bad[se] = 0x05
    @test_throws "progressive scan parameters (Ss=0 Se=5" Diff3D._jpeg_decode_rgb8(bad)

    # decode_mcu_AC_refine (jdphuff.c): a newly nonzero coefficient has size
    # 1; relabel the refinement table's size-1 symbols as size 2.
    bad = copy(_AUDIT3_JPEG_PROG_GRAY)
    segs = _audit3_jpeg_segments(bad)
    k = findfirst(s -> s[1] == 0xDA && bad[s[2] + 5 + 2 * bad[s[2] + 4]] != 0 &&
                       bad[s[2] + 7 + 2 * bad[s[2] + 4]] >> 4 != 0, segs)
    @test k !== nothing
    _, dp, _ = segs[findlast(i -> segs[i][1] == 0xC4, 1:k-1)]
    count = sum(Int(bad[dp + 5 + i]) for i in 0:15)
    relabelled = 0
    for i in 0:count-1
        v = bad[dp + 21 + i]
        if v & 0x0f == 0x01
            bad[dp + 21 + i] = (v & 0xf0) | 0x02
            relabelled += 1
        end
    end
    @test relabelled > 0
    @test_throws "bad Huffman code in AC refinement" Diff3D._jpeg_decode_rgb8(bad)
end

# Binary STL, 2 facets. Header bytes 0-9 hold "COLOR=" ff 80 00 ff and bytes
# 10-19 hold "COLOR=" 10 20 40 c8. Facet 1 has attribute 0x8000 (use the
# header colour), facet 2 has 0x168a (r=10, g=20, b=5 in 5-bit fields).
const _AUDIT3_STL_COLOR = base64decode(
    "Q09MT1I9/4AA/0NPTE9SPRAgQMgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" *
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAACAPwAAgD8AAABAAACAPwAAgD8AAIA/" *
    "AAAAQAAAgD8AAIA/AACAPwAAAEAAAIA/AIAAAABAAAAAQAAAQEAAAABAAAAAQAAAAEAAAEBA" *
    "AAAAQAAAAEAAAABAAABAQAAAAECKFg==")

@testset "binary STL COLOR= header and per-facet colours" begin
    geo = load_stl(_audit3_file(_AUDIT3_STL_COLOR, ".stl"))
    @test geo.n_faces == 2
    # Facet k stores normal (k, k, k+1) and vertices (k, k, k), (k+1, k, k),
    # (k, k+1, k): the pattern 0,0,1 | 0,0,0 | 1,0,0 | 0,1,0 plus k.
    @test geo.normals[1:3] == [1.0, 1.0, 2.0]
    @test geo.positions[1:3] == [1.0, 1.0, 1.0]
    @test has_attribute(geo, :color)
    color = get_attribute(geo, :color)
    @test color.item_size == 3
    # three.js r186 STLLoader.parse of the same bytes (Float32 color
    # attribute). STLLoader.js parseBinary scans header offsets 0..69 and
    # keeps the last "COLOR=" match, so facet 1 takes (16, 32, 64)/255; facet
    # 2 takes (10, 20, 5)/31. Both go through setRGB(..., SRGBColorSpace).
    face1 = [0.005181516520678997, 0.014443843625485897, 0.05126945674419403]
    face2 = [0.0849214568734169, 0.3738260269165039, 0.02229888364672661]
    @test isapprox(color.data, vcat(face1, face1, face1, face2, face2, face2); atol=1e-7)
    # Without a COLOR= header the attribute word is ignored (STLLoader.js
    # hasColors stays false).
    plain = copy(_AUDIT3_STL_COLOR)
    plain[1:20] .= 0x00
    @test !has_attribute(load_stl(_audit3_file(plain, ".stl")), :color)
end

@testset "ASCII STL tokens accept any whitespace" begin
    # STLLoader.js parseASCII matches /normal[\s]+.../ and /vertex[\s]+.../
    # inside /facet([\s\S]*?)endfacet/, so CR-only line ends, tabs, repeated
    # spaces and a normal continued on the next line all parse.
    facet = "facet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\n" *
            "vertex 0 1 0\nendloop\nendfacet\n"
    base = "solid s\n" * facet * "endsolid s\n"
    ref = load_stl(_audit3_file(base, ".stl"))
    @test ref.n_faces == 1
    @test ref.positions == [0.0, 0, 0, 1, 0, 0, 0, 1, 0]
    @test ref.normals == repeat([0.0, 0, 1], 3)
    for text in (replace(base, "\n" => "\r"),
                 replace(base, "facet normal" => "facet  normal"),
                 replace(replace(base, "facet normal" => "facet\tnormal"),
                         "vertex 1 0 0" => "vertex\t1\t0 0"),
                 replace(base, "facet normal 0 0 1" => "facet normal\n 0 0 1"),
                 "﻿" * replace(base, "\n" => "\r\n"))
        geo = load_stl(_audit3_file(text, ".stl"))
        @test geo.n_faces == 1
        @test geo.positions == ref.positions
        @test geo.normals == ref.normals
    end
    # The solid name runs to the end of its line, even when it is a keyword.
    named = load_stl(_audit3_file(replace(base, "solid s\n" => "solid vertex 1 2\n"), ".stl"))
    @test named.positions == ref.positions
    @test_throws "ASCII STL facet must be followed by normal" load_stl(
        _audit3_file(replace(base, "facet normal" => "facet"), ".stl"))
    @test_throws "ASCII STL vertex requires 3 coordinates" load_stl(
        _audit3_file(replace(base, "vertex 0 1 0" => "vertex 0 1"), ".stl"))
end
