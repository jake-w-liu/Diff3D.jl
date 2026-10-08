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
