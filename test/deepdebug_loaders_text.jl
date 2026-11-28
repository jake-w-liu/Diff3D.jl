using Test, Diff3D

# Regression tests for loader defects found by the deep-debug audit of v2.0.0;
# the comment above each testset names its finding. three.js r186 behaviour
# quoted below was observed by running its loaders under Node on the same files.

const _DDLT_BOM = UInt8[0xef, 0xbb, 0xbf]

function _ddlt_pair(dir, name, ext, bytes::Vector{UInt8})
    plain = joinpath(dir, name * ext)
    bom = joinpath(dir, name * "_bom" * ext)
    write(plain, bytes)
    write(bom, vcat(_DDLT_BOM, bytes))
    return plain, bom
end
_ddlt_pair(dir, name, ext, text::String) = _ddlt_pair(dir, name, ext, Vector{UInt8}(codeunits(text)))

_ddlt_geo(g) = (g.positions, g.normals, g.uvs, g.indices, g.n_vertices, g.n_faces)

# LH-6: PLY allows elements in any order; three.js PLYLoader loads a face
# element declared before the vertex element (positions [0,0,0,1,0,0,0,1,0],
# index [0,1,2]).
@testset "PLY face element before the vertex element" begin
    face_first = "ply\nformat ascii 1.0\nelement face 1\nproperty list uchar int vertex_indices\n" *
                 "element vertex 3\nproperty float x\nproperty float y\nproperty float z\n" *
                 "end_header\n3 0 1 2\n0 0 0\n1 0 0\n0 1 0\n"
    mktempdir() do dir
        p = joinpath(dir, "f.ply"); write(p, face_first)
        g = load_ply(p)
        @test g.positions == [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        @test g.indices == [1, 2, 3] && g.n_faces == 1
        hdr = "ply\nformat binary_little_endian 1.0\nelement face 1\n" *
              "property list uchar int vertex_indices\nelement vertex 3\nproperty float x\n" *
              "property float y\nproperty float z\nend_header\n"
        body = vcat(UInt8[3], reinterpret(UInt8, htol.(Int32[0, 1, 2])),
                    reinterpret(UInt8, htol.(Float32[0, 0, 0, 1, 0, 0, 0, 1, 0])))
        p = joinpath(dir, "fb.ply"); write(p, vcat(Vector{UInt8}(codeunits(hdr)), body))
        @test _ddlt_geo(load_ply(p)) == _ddlt_geo(g)
        # Indices are still checked against the final vertex count.
        p = joinpath(dir, "bad.ply"); write(p, replace(face_first, "3 0 1 2" => "3 0 1 3"))
        @test_throws "PLY face vertex index 3 is outside 0:2" load_ply(p)
        p = joinpath(dir, "neg.ply"); write(p, replace(face_first, "3 0 1 2" => "3 0 -1 2"))
        @test_throws "PLY face vertex index -1.0 is negative" load_ply(p)
    end
end
