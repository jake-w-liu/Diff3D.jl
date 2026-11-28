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

# LH-3: three.js decodes text with the WHATWG UTF-8 decoder, which drops a
# leading byte-order mark, so a BOM file loads exactly like the plain one.
@testset "UTF-8 byte-order mark is skipped by the text loaders" begin
    mktempdir() do dir
        obj = "v 9 9 9\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf -3 -2 -1\nf 1 2 3\n"
        a, b = _ddlt_pair(dir, "m", ".obj", obj)
        @test _ddlt_geo(load_obj(b)) == _ddlt_geo(load_obj(a))
        # The first `v` line used to be dropped, shifting every index.
        @test load_obj(b).positions[10:12] == [9.0, 9.0, 9.0]
        ga, gb = load_obj_groups(a), load_obj_groups(b)
        @test _ddlt_geo(ga[1]) == _ddlt_geo(gb[1]) && ga[2] == gb[2]
        sa, sb = load_obj_scene(a), load_obj_scene(b)
        @test length(sa.children) == length(sb.children) == 1
        @test _ddlt_geo(sa.children[1].geometry) == _ddlt_geo(sb.children[1].geometry)

        mtl = "newmtl red\nKd 1 0 0\n"
        a, b = _ddlt_pair(dir, "m", ".mtl", mtl)
        @test sort(collect(keys(load_mtl(b)))) == ["red"]
        @test load_mtl(b)["red"].color == load_mtl(a)["red"].color

        a, b = _ddlt_pair(dir, "p", ".xyz", "1 2 3\n4 5 6\n")
        @test load_xyz(b).positions == load_xyz(a).positions == [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]

        stl = "solid t\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\n" *
              "vertex 0 1 0\nendloop\nendfacet\nendsolid t\n"
        a, b = _ddlt_pair(dir, "s", ".stl", stl)
        @test _ddlt_geo(load_stl(b)) == _ddlt_geo(load_stl(a))

        ply = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\n" *
              "property float z\nelement face 1\nproperty list uchar int vertex_indices\n" *
              "end_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n"
        a, b = _ddlt_pair(dir, "a", ".ply", ply)
        @test _ddlt_geo(load_ply(b)) == _ddlt_geo(load_ply(a))
        hdr = "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty float x\n" *
              "property float y\nproperty float z\nend_header\n"
        bin = vcat(Vector{UInt8}(codeunits(hdr)), reinterpret(UInt8, htol.(Float32[1, 2, 3])))
        a, b = _ddlt_pair(dir, "b", ".ply", bin)
        @test load_ply(b).positions == load_ply(a).positions == [1.0, 2.0, 3.0]

        gltf = """{"asset":{"version":"2.0"},"scenes":[{"nodes":[0]}],"scene":0,"nodes":[{"name":"n"}]}"""
        a, b = _ddlt_pair(dir, "g", ".gltf", gltf)
        @test [c.name for c in load_gltf(b).children] == ["n"]
        @test length(load_gltf_asset(b).scene.children) == 1
        # GLB JSON chunk with a BOM (GLTFLoader decodes it with TextDecoder).
        json = vcat(_DDLT_BOM, Vector{UInt8}(codeunits(gltf)))
        while length(json) % 4 != 0
            push!(json, UInt8(' '))
        end
        glb = vcat(Vector{UInt8}(codeunits("glTF")), reinterpret(UInt8, htol.(UInt32[2, 20 + length(json)])),
                   reinterpret(UInt8, htol.(UInt32[length(json), 0x4E4F534A])), json)
        p = joinpath(dir, "g.glb"); write(p, glb)
        @test [c.name for c in load_glb(p).children] == ["n"]
        # A BOM is skipped only at the start of the file.
        p = joinpath(dir, "mid.xyz"); write(p, vcat(Vector{UInt8}(codeunits("1 2 3\n")), _DDLT_BOM,
                                                     Vector{UInt8}(codeunits("4 5 6\n"))))
        @test_throws ArgumentError load_xyz(p)
    end
end

const _DDLT_B64 = "AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA"   # 3 x vec3 float
_ddlt_doc(; acc="""{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}""",
          view="""{"buffer":0,"byteLength":36}""",
          mesh="""{"primitives":[{"attributes":{"POSITION":0}}]}""", extra="") =
    """{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
       "meshes":[$mesh],"accessors":[$acc],"bufferViews":[$view],
       "buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,$_DDLT_B64"}]$extra}"""

function _ddlt_load(text)
    p = tempname() * ".gltf"
    write(p, text)
    return load_gltf_asset(p)
end

# LH-4: missing schema-required properties raise an ArgumentError naming the
# object and the property, not a bare KeyError.
@testset "glTF missing required properties" begin
    @test _ddlt_load(_ddlt_doc()) isa GLTFAsset
    cases = [
        (acc="""{"bufferView":0,"componentType":5126,"count":3}""",) => "accessors[0] is missing required property \"type\"",
        (acc="""{"bufferView":0,"count":3,"type":"VEC3"}""",) => "accessors[0] is missing required property \"componentType\"",
        (acc="""{"bufferView":0,"componentType":5126,"type":"VEC3"}""",) => "accessors[0] is missing required property \"count\"",
        (view="""{"byteLength":36}""",) => "bufferViews[0] is missing required property \"buffer\"",
        (view="""{"buffer":0}""",) => "bufferViews[0] is missing required property \"byteLength\"",
        (mesh="{}",) => "meshes[0] is missing required property \"primitives\"",
        (mesh="""{"primitives":[{}]}""",) => "meshes[0].primitives[0] is missing required property \"attributes\"",
        (acc="""{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","sparse":{"count":1,"indices":{"bufferView":0}}}""",) =>
            "accessors[0].sparse is missing required property \"values\"",
        (acc="""{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","sparse":{"count":1,"indices":{"bufferView":0},"values":{"bufferView":0}}}""",) =>
            "accessors[0].sparse.indices is missing required property \"componentType\"",
        (extra=""","animations":[{"channels":[{"target":{"node":0,"path":"translation"},"sampler":0}]}]""",) =>
            "animations[0] is missing required property \"samplers\"",
        (extra=""","animations":[{"channels":[{"target":{"node":0},"sampler":0}],"samplers":[{"input":0,"output":0}]}]""",) =>
            "animations[0] channel target is missing required property \"path\"",
        (extra=""","animations":[{"channels":[{"target":{"node":0,"path":"translation"},"sampler":0}],"samplers":[{"output":0}]}]""",) =>
            "animations[0] sampler is missing required property \"input\"",
    ]
    for (kw, msg) in cases
        err = try
            _ddlt_load(_ddlt_doc(; kw...)); nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err isa ArgumentError && occursin(msg, err.msg)
    end
    cam = """{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"camera":0}],"cameras":[CAM]}"""
    @test_throws "cameras[0] is missing required property \"type\"" _ddlt_load(replace(cam, "CAM" => "{}"))
    @test_throws "cameras[0].perspective is missing required property \"yfov\"" _ddlt_load(
        replace(cam, "CAM" => """{"type":"perspective","perspective":{"znear":0.1}}"""))
    @test_throws "cameras[0].orthographic is missing required property \"zfar\"" _ddlt_load(
        replace(cam, "CAM" => """{"type":"orthographic","orthographic":{"xmag":1,"ymag":1,"znear":0.1}}"""))
    # A primitive without POSITION is valid glTF ("client implementations
    # SHOULD skip" it, glTF 2.0 3.7.2.1); three.js GLTFLoader gives it a Mesh
    # with no vertices. Diff3D skips it and keeps the other primitives.
    nopos = _ddlt_load(_ddlt_doc(mesh="""{"primitives":[{"attributes":{}},{"attributes":{"POSITION":0}}]}"""))
    meshes = Any[]
    traverse(nopos.scene, o -> o isa Mesh && push!(meshes, o))
    @test length(meshes) == 1 && meshes[1].geometry.n_vertices == 3
    empty_node = _ddlt_load(_ddlt_doc(mesh="""{"primitives":[{"attributes":{}}]}"""))
    meshes = Any[]
    traverse(empty_node.scene, o -> o isa Mesh && push!(meshes, o))
    @test isempty(meshes) && length(empty_node.scene.children) == 1
end

# LH-10: an accessor without a bufferView is zeros of its declared count; a
# count no glTF loader could allocate is refused before anything is allocated.
@testset "glTF bufferView-less accessors are bounded" begin
    zero_doc(count; icount=nothing) =
        """{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
           "meshes":[{"primitives":[{"attributes":{"POSITION":0}$(icount === nothing ? "" : ",\"indices\":1")}]}],
           "accessors":[{"componentType":5126,"count":$count,"type":"VEC3","min":[0,0,0],"max":[0,0,0]},
                        {"componentType":5125,"count":$(something(icount, 0)),"type":"SCALAR"}]}"""
    # Zeros of a plausible count still load (three.js allocates them as well).
    small = _ddlt_load(zero_doc(30))
    meshes = Any[]
    traverse(small.scene, o -> o isa Mesh && push!(meshes, o))
    @test only(meshes).geometry.positions == zeros(90)
    # 2^31 vertices (24 GiB as three.js stores them, so within its limit) are
    # not a whole number of triangles: rejected from the declared count,
    # before the 2^31 x 3 Float64 zeros are materialised.
    stats = @timed try
        _ddlt_load(zero_doc(2^31)); nothing
    catch e
        e
    end
    @test stats.value isa ErrorException &&
          occursin("divisible by 3", sprint(showerror, stats.value))
    @test stats.bytes < 50_000_000
    # Counts of 2^35 bytes or more as three.js stores them (the 242-byte
    # repro file declares 2^40 vertices).
    for (count, icount) in ((2^40, nothing), (3 * 2^40, nothing), (3 * 2^33, nothing),
                            (3 * 2^33, 3), (3, 3 * 2^33))
        stats = @timed try
            _ddlt_load(zero_doc(count; icount=icount)); nothing
        catch e
            e
        end
        @test stats.value isa ArgumentError &&
              occursin("beyond the largest typed array", stats.value.msg)
        @test stats.bytes < 50_000_000
    end
    # The limit is exactly 2^35 bytes of the accessor's own component type.
    check = Diff3D._gltf_check_accessor_allocation
    @test check((2^35 - 1) ÷ 12, 3, 4, "POSITION") === nothing
    @test_throws ArgumentError check((2^35 - 1) ÷ 12 + 1, 3, 4, "POSITION")
    @test check(2^35 - 1, 1, 1, "indices") === nothing
    @test_throws ArgumentError check(2^35, 1, 1, "indices")
end
