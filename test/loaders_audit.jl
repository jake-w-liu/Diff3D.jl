using Test, Diff3D, Base64

function _loaders_audit_file(text, ext)
    path = tempname() * ext
    write(path, text)
    return path
end

const _LOADERS_AUDIT_PLY_HEADER =
    "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\n" *
    "property float y\nproperty float z\nelement face 1\n" *
    "property list uchar int vertex_indices\nend_header\n"

@testset "PLY ASCII body is one whitespace token stream" begin
    hdr = _LOADERS_AUDIT_PLY_HEADER
    expected = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    for body in ("0 0 0 1 0 0\n0 1 0 3 0 1 2\n",
                 "0 0\n0\n1 0 0\n0 1 0\n3 0\n1 2\n",
                 "0\v0\f0\n1 0 0\n0 1 0\n3 0 1 2\n",
                 "0 0 0 1 0 0 0 1 0 3 0 1 2")
        geo = load_ply(_loaders_audit_file(hdr * body, ".ply"))
        @test geo.positions == expected
        @test geo.indices == [1, 2, 3]
    end
    extra = replace(hdr, "element face 1" =>
        "element extra 1\nproperty list uchar float w\nelement face 1")
    geo = load_ply(_loaders_audit_file(
        extra * "0 0 0\n1 0 0\n0 1 0\n2\n5 6\n3 0 1 2\n", ".ply"))
    @test geo.positions == expected
    @test geo.indices == [1, 2, 3]
    @test_throws "PLY extra row 1 property w item 2 must be a number" load_ply(
        _loaders_audit_file(extra * "0 0 0\n1 0 0\n0 1 0\n2 5 x\n3 0 1 2\n", ".ply"))
    tagged = replace(hdr, "element face 1" => "element tag 5\nelement face 1")
    geo = load_ply(_loaders_audit_file(
        tagged * "0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n", ".ply"))
    @test geo.indices == [1, 2, 3]
    @test_throws "PLY face row 1 is missing property vertex_indices" load_ply(
        _loaders_audit_file(hdr * "0 0 0 1 0 0 0 1 0 3 0 1", ".ply"))
end

@testset "PLY header accepts bare CR line endings" begin
    text = replace(_LOADERS_AUDIT_PLY_HEADER, "\n" => "\r") *
           "0 0 0\r1 0 0\r0 1 0\r3 0 1 2\r"
    geo = load_ply(_loaders_audit_file(text, ".ply"))
    @test geo.positions == [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
    @test geo.indices == [1, 2, 3]
    header = "ply\rformat binary_little_endian 1.0\relement vertex 3\r" *
             "property float x\rproperty float y\rproperty float z\rend_header\r"
    path = tempname() * ".ply"
    open(path, "w") do io
        write(io, codeunits(header))
        for value in Float32[10, 0, 0, 0, 1, 0, 0, 0, 1]
            write(io, value)
        end
    end
    @test load_ply(path).positions == [10.0, 0, 0, 0, 1, 0, 0, 0, 1]
end

const _LOADERS_AUDIT_JPEG = base64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/wAALCAAMABABAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/ADSPEtt9iHzjpWFrPiW2+0/fHWuG0h3+xD526etYWsu/2n77dfWv/9k=")

@testset "JPEG sniffing tolerates bytes after EOI" begin
    clean = load_image(_loaders_audit_file(_LOADERS_AUDIT_JPEG, ".jpg"))
    padded = vcat(_LOADERS_AUDIT_JPEG, UInt8[0x00, 0x00, 0x0a])
    @test load_image(_loaders_audit_file(padded, ".jpg")) == clean
    tex = TextureLoader(_loaders_audit_file(padded, ".jpg"))
    @test size(tex.data) == size(clean)
    @test_throws "unsupported image format" load_image(
        _loaders_audit_file(UInt8[0xff, 0xd8, 0x00, 0x00], ".jpg"))
end
