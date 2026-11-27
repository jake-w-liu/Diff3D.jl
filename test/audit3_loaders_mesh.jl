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
    for name in ("my facet", "my facet normal", "facet normal 1 2")
        named = load_stl(_audit3_file(replace(base, "solid s\n" => "solid $name\n"), ".stl"))
        @test named.positions == ref.positions
    end
    # STLLoader.js matches facets anywhere in the solid text, so a file written
    # on one line loads; three.js r186 gives these positions and normals.
    oneline = "solid x facet normal 0 0 1 outer loop vertex 0 0 0 vertex 1 0 0 " *
              "vertex 0 1 0 endloop endfacet facet normal 0 0 -1 outer loop " *
              "vertex 0 0 0 vertex 0 1 0 vertex 1 0 0 endloop endfacet endsolid x"
    geo = load_stl(_audit3_file(oneline, ".stl"))
    @test geo.n_faces == 2
    @test geo.positions == [0.0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0]
    @test geo.normals == vcat(repeat([0.0, 0, 1], 3), repeat([0.0, 0, -1], 3))
    @test_throws "ASCII STL facet must be followed by normal" load_stl(
        _audit3_file(replace(base, "facet normal" => "facet"), ".stl"))
    @test_throws "ASCII STL vertex requires 3 coordinates" load_stl(
        _audit3_file(replace(base, "vertex 0 1 0" => "vertex 0 1"), ".stl"))
end

@testset "OBJ vertex colours follow three.js OBJLoader" begin
    # OBJLoader.js parse, case 'v': data.length >= 7 gives
    # _color.setRGB(r, g, b, SRGBColorSpace). Expected values: three.js r186
    # OBJLoader.parse color attribute (Float32) for this text.
    text = "v 0 0 0 1 0.5 0\nv 1 0 0 0.2 1 0\nv 0 1 0 0 0 1\nf 1 2 3\n"
    geo = load_obj(_audit3_file(text, ".obj"))
    @test has_attribute(geo, :color)
    @test isapprox(get_attribute(geo, :color).data,
                   [1, 0.21404114365577698, 0, 0.03310476616024971, 1, 0, 0, 0, 1];
                   atol=1e-7)
    # Corners take the colour of the vertex they reference.
    geo = load_obj(_audit3_file(replace(text, "f 1 2 3" => "f 3 1 2"), ".obj"))
    @test isapprox(get_attribute(geo, :color).data,
                   [0, 0, 1, 1, 0.21404114365577698, 0, 0.03310476616024971, 1, 0];
                   atol=1e-7)
    # `v x y z w` is a weight, not a colour; and colours are dropped unless
    # every vertex has one.
    @test !has_attribute(load_obj(_audit3_file(
        "v 0 0 0 1\nv 1 0 0 1\nv 0 1 0 1\nf 1 2 3\n", ".obj")), :color)
    @test !has_attribute(load_obj(_audit3_file(
        replace(text, "v 0 1 0 0 0 1" => "v 0 1 0"), ".obj")), :color)
end

@testset "OBJ backslash continues a line" begin
    # OBJLoader.js parse: CRLF -> LF, then text.replace(/\\\n/g, '').
    # three.js r186 positions for this text: one quad fanned into 2 faces.
    text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\nf 1 2 \\\n3 \\\r\n 4\n"
    geo = load_obj(_audit3_file(text, ".obj"))
    @test geo.n_faces == 2
    @test geo.positions == [0.0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0]
    # A continuation on the last line joins with nothing.
    geo = load_obj(_audit3_file("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 \\\n3 \\", ".obj"))
    @test geo.n_faces == 1
end

@testset "OBJ keeps file normals when another face lacks vn" begin
    # OBJLoader.js addFace: a face with vn indices uses addNormal; one without
    # uses addFaceNormal (cross(C - B, A - B), normalized). Expected values:
    # three.js r186 normal attribute for this text; face 2 spans (0,0,0),
    # (1,1,0), (0,0,1), whose normal is (1,-1,0)/sqrt(2).
    text = "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 0 0 1\nvn 0 1 0\n" *
           "f 1//1 2//1 3//1\nf 1 3 5\n"
    geo = load_obj(_audit3_file(text, ".obj"))
    s = 0.7071067690849304
    @test isapprox(geo.normals, [0, 1, 0, 0, 1, 0, 0, 1, 0, s, -s, 0, s, -s, 0, s, -s, 0];
                   atol=1e-7)
    # A zero vn is replaced by the face normal only at that corner.
    geo = load_obj(_audit3_file(replace(text, "f 1 3 5" => "vn 0 0 0\nf 1//2 3//2 5//1"), ".obj"))
    @test isapprox(geo.normals, [0, 1, 0, 0, 1, 0, 0, 1, 0, s, -s, 0, s, -s, 0, 0, 1, 0];
                   atol=1e-7)
end

@testset "PLY property names, uvs and quads follow three.js PLYLoader" begin
    # PLYLoader.js getAttributeDescriptor: x <- x|px|posx, s <- s|u|texture_u|tx,
    # t <- t|v|texture_v|ty, red <- red|diffuse_red|r|diffuse_r. handleElement
    # splits a 4-index face as (0,1,3), (1,2,3). Expected values: three.js r186
    # PLYLoader.parse of this text (position, uv, index + 1).
    header = "ply\nformat ascii 1.0\nelement vertex 4\nproperty float px\n" *
             "property float py\nproperty float pz\nproperty float texture_u\n" *
             "property float texture_v\nproperty uchar diffuse_red\n" *
             "property uchar diffuse_green\nproperty uchar diffuse_blue\n" *
             "element face 1\nproperty list uchar int vertex_indices\nend_header\n"
    rows = "0 0 0 0 0 255 0 0\n1 0 0 1 0 0 255 0\n1 1 1 0.75 1 0 0 255\n" *
           "0 1 0 0 0.5 255 255 255\n4 0 1 2 3\n"
    geo = load_ply(_audit3_file(header * rows, ".ply"))
    @test geo.positions == [0.0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0]
    @test geo.uvs == [0.0, 0, 1, 0, 0.75, 1, 0, 0.5]
    @test geo.indices == [1, 2, 4, 2, 3, 4]
    # Channels of 0 and 255 are unchanged by any sRGB transfer.
    @test get_attribute(geo, :color).data == [1.0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1]

    # The same rows as binary_little_endian.
    io = IOBuffer()
    write(io, replace(header, "ascii" => "binary_little_endian"))
    for r in ((0, 0, 0, 0, 0, 255, 0, 0), (1, 0, 0, 1, 0, 0, 255, 0),
              (1, 1, 1, 0.75, 1, 0, 0, 255), (0, 1, 0, 0, 0.5, 255, 255, 255))
        foreach(x -> write(io, htol(Float32(x))), r[1:5])
        foreach(x -> write(io, UInt8(x)), r[6:8])
    end
    write(io, UInt8(4), htol.(Int32[0, 1, 2, 3])...)
    bin = load_ply(_audit3_file(take!(io), ".ply"))
    @test bin.positions == geo.positions
    @test bin.uvs == geo.uvs
    @test bin.indices == geo.indices
    @test get_attribute(bin, :color).data == get_attribute(geo, :color).data
end

# One triangle with uvs and (unnormalized) vertex normals.
_audit3_export_tri() = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0],
                                      [0.0, 0, 2, 0, 0, 1, 0, 0, 1],
                                      [0.0, 0, 1, 0, 0, 1], [1, 2, 3], 3, 1)

@testset "ASCII STL and OBJ exporters follow three.js layouts" begin
    tri = _audit3_export_tri()
    # STLExporter.js (binary: false): 'solid exported\n', per face
    # '\tfacet normal ...\n\t\touter loop\n', three '\t\t\tvertex ...\n',
    # '\t\tendloop\n\tendfacet\n', then 'endsolid exported\n'. The normal is
    # (C - B) x (A - B) normalized: (0, 0, 1) here.
    path = Diff3D.save_stl_ascii(tempname() * ".stl", tri)
    @test read(path, String) ==
          "solid exported\n\tfacet normal 0.0 0.0 1.0\n\t\touter loop\n" *
          "\t\t\tvertex 0.0 0.0 0.0\n\t\t\tvertex 1.0 0.0 0.0\n" *
          "\t\t\tvertex 0.0 1.0 0.0\n\t\tendloop\n\tendfacet\nendsolid exported\n"
    box = BoxGeometry(width=1.0, height=2.0, depth=3.0)
    back = load_stl(Diff3D.save_stl_ascii(tempname() * ".stl", box))
    @test back.n_faces == box.n_faces
    @test back.positions == [box.positions[3(i - 1) + k] for i in box.indices for k in 1:3]

    # OBJExporter.js parseMesh: 'o name', v, vt, vn (normalized), then
    # 'f a/b/c' with the vt or vn part left empty when that attribute is absent.
    path = Diff3D.save_obj(tempname() * ".obj", tri; name="tri")
    @test read(path, String) ==
          "o tri\nv 0.0 0.0 0.0\nv 1.0 0.0 0.0\nv 0.0 1.0 0.0\nvt 0.0 0.0\n" *
          "vt 1.0 0.0\nvt 0.0 1.0\nvn 0.0 0.0 1.0\nvn 0.0 0.0 1.0\n" *
          "vn 0.0 0.0 1.0\nf 1/1/1 2/2/2 3/3/3\n"
    nouv = BufferGeometry(tri.positions, tri.normals, Float64[], [1, 2, 3], 3, 1)
    @test endswith(read(Diff3D.save_obj(tempname() * ".obj", nouv), String),
                   "\nf 1//1 2//2 3//3\n")
    nonrm = BufferGeometry(tri.positions, Float64[], tri.uvs, [1, 2, 3], 3, 1)
    @test endswith(read(Diff3D.save_obj(tempname() * ".obj", nonrm), String),
                   "\nf 1/1 2/2 3/3\n")
    back = load_obj(Diff3D.save_obj(tempname() * ".obj", box))
    @test back.positions == [box.positions[3(i - 1) + k] for i in box.indices for k in 1:3]
    @test back.uvs == [box.uvs[2(i - 1) + k] for i in box.indices for k in 1:2]
    @test_throws "save_obj name must not contain a line break" Diff3D.save_obj(
        tempname() * ".obj", tri; name="a\nb")
    @test_throws "save_obj positions must be finite" Diff3D.save_obj(
        tempname() * ".obj", BufferGeometry([NaN, 0, 0, 1, 0, 0, 0, 1, 0], Float64[],
                                            Float64[], [1, 2, 3], 3, 1))
end

@testset "PLY exporter matches three.js PLYExporter" begin
    # three.js r186 PLYExporter.parse(mesh, null, {binary: true, littleEndian})
    # of the BoxGeometry(width=1, height=2, depth=3) position/normal/uv/index
    # buffers (Float64Array attributes, so every property is `double`).
    box = BoxGeometry(width=1.0, height=2.0, depth=3.0)
    le = read(Diff3D.save_ply(tempname() * ".ply", box; binary=true, little_endian=true))
    be = read(Diff3D.save_ply(tempname() * ".ply", box; binary=true))
    @test bytes2hex(sha256(le)) ==
          "cc312e4406ac8f4cbb8151d189eb88eea4149ebbc78143d5ee9cb36ca8f298ae"
    @test bytes2hex(sha256(be)) ==
          "2629d8e5f5cc315285aaf93991e9e251fe1fcd65c0ff6866884565900ceec068"

    # ASCII layout (PLYExporter.js): header, one row per vertex, '3 a b c'
    # per face, then a final '\n'.
    path = Diff3D.save_ply(tempname() * ".ply", _audit3_export_tri())
    @test read(path, String) ==
          "ply\nformat ascii 1.0\nelement vertex 3\nproperty double x\n" *
          "property double y\nproperty double z\nproperty double nx\n" *
          "property double ny\nproperty double nz\nproperty double s\n" *
          "property double t\nelement face 1\n" *
          "property list uchar int vertex_index\nend_header\n" *
          "0.0 0.0 0.0 0.0 0.0 1.0 0.0 0.0\n1.0 0.0 0.0 0.0 0.0 1.0 1.0 0.0\n" *
          "0.0 1.0 0.0 0.0 0.0 1.0 0.0 1.0\n3 0 1 2\n\n"
    for kw in ((;), (binary=true,), (binary=true, little_endian=true))
        back = load_ply(Diff3D.save_ply(tempname() * ".ply", box; kw...))
        @test back.positions == box.positions
        @test back.uvs == box.uvs
        @test back.indices == box.indices
    end
    # Colours are written as sRGB (ColorManagement.workingToColorSpace).
    col = _audit3_export_tri()
    set_attribute!(col, :color, [0.0, 0.5, 1.0, 0.25, 0.0, 0.0, 1.0, 1.0, 1.0], 3)
    text = read(Diff3D.save_ply(tempname() * ".ply", col), String)
    @test occursin("property double red\nproperty double green\nproperty double blue\n", text)
    # 1.055 * 1 - 0.055 rounds to 0.9999999999999999 in Float64, in three.js
    # LinearToSRGB as here.
    @test occursin(" 0.0 0.7353569830524495 0.9999999999999999\n", text)
    @test linear_to_srgb(0.5) == 0.7353569830524495
end
