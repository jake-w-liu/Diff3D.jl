using Test, Diff3D

const _A3B_DIR = mktempdir()
_a3b_counter = Ref(0)

function _a3b_file(content, ext::String)
    _a3b_counter[] += 1
    path = joinpath(_A3B_DIR, "f$(_a3b_counter[])$ext")
    write(path, content)
    return path
end

_a3b_srgb_to_linear(c) = c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)^2.4

# In-memory glTF builder (as in test/audit3_loaders_gltf.jl): every accessor
# gets its own buffer view in buffer 0, and documents go through the internal
# entry points load_gltf uses after reading the buffers.
mutable struct A3BGLTF
    bin::Vector{UInt8}
    views::Vector{Any}
    accessors::Vector{Any}
end
A3BGLTF() = A3BGLTF(UInt8[], Any[], Any[])

const _A3B_CTYPES = Dict(Float32 => 5126, Int8 => 5120, UInt8 => 5121,
                         Int16 => 5122, UInt16 => 5123, UInt32 => 5125)
const _A3B_NCOMP = Dict("SCALAR" => 1, "VEC2" => 2, "VEC3" => 3, "VEC4" => 4, "MAT4" => 16)

function _a3b_accessor!(b::A3BGLTF, data::Vector{T}, type::String;
                        minmax::Bool=false) where {T}
    while length(b.bin) % 4 != 0
        push!(b.bin, 0x00)
    end
    push!(b.views, Dict{String,Any}("buffer" => 0, "byteOffset" => length(b.bin),
                                    "byteLength" => sizeof(data)))
    append!(b.bin, reinterpret(UInt8, data))
    n = _A3B_NCOMP[type]
    acc = Dict{String,Any}("bufferView" => length(b.views) - 1,
                           "componentType" => _A3B_CTYPES[T],
                           "count" => length(data) ÷ n, "type" => type)
    if minmax
        acc["min"] = [Float64(minimum(data[k:n:end])) for k in 1:n]
        acc["max"] = [Float64(maximum(data[k:n:end])) for k in 1:n]
    end
    push!(b.accessors, acc)
    return length(b.accessors) - 1
end

function _a3b_doc(b::A3BGLTF, doc::Dict{String,Any})
    doc["asset"] = Dict{String,Any}("version" => "2.0")
    doc["accessors"] = b.accessors
    doc["bufferViews"] = b.views
    doc["buffers"] = [Dict{String,Any}("byteLength" => length(b.bin))]
    Diff3D._gltf_validate_document(doc)
    return doc, [copy(b.bin)]
end

function _a3b_objects(root)
    out = Any[]
    traverse(root, o -> push!(out, o))
    return out
end

_a3b_meshes(root) = filter(o -> o isa Mesh, _a3b_objects(root))

# One OBJ exercising every record load_obj and load_obj_groups share: a
# backslash continuation, `v x y z r g b` colours, an inline `#` comment after
# a coloured vertex, a face with normals and a face without them.
const _A3B_MIXED_OBJ = """
# mixed features
v 0 0 0 1 0.5 0
v 1 0 0 0 1 0.25
v 0 1 0 0.2 0.4 1 # trailing comment
v 1 1 0.5 0.9 0.1 0.3
vt 0 0
vt 1 0
vt 0 1
vn 0 0.6 0.8
usemtl a
f 1/1/1 2/2/1 \\
3/3/1
usemtl b
f 2/2 4/1 3/3
"""

@testset "load_obj_groups produces load_obj's geometry (three.js OBJLoader)" begin
    path = _a3b_file(_A3B_MIXED_OBJ, ".obj")
    geo = load_obj(path)
    grouped, face_mtl, mats = load_obj_groups(path)
    @test grouped.positions == geo.positions
    @test grouped.normals == geo.normals
    @test grouped.uvs == geo.uvs
    @test grouped.indices == geo.indices
    @test get_attribute(grouped, :color).data == get_attribute(geo, :color).data
    @test face_mtl == ["a", "b"]
    @test isempty(mats)
    # three.js r186 OBJLoader.parse of the same text (Float32 attributes):
    # one mesh, normal from `vn` on face 1 and addFaceNormal on face 2,
    # colours setRGB(..., SRGBColorSpace) (OBJLoader.js:520-535).
    @test geo.positions == [0.0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0.5, 0, 1, 0]
    @test isapprox(geo.normals,
                   [0, 0.6000000238418579, 0.800000011920929,
                    0, 0.6000000238418579, 0.800000011920929,
                    0, 0.6000000238418579, 0.800000011920929,
                    -0.40824830532073975, -0.40824830532073975, 0.8164966106414795,
                    -0.40824830532073975, -0.40824830532073975, 0.8164966106414795,
                    -0.40824830532073975, -0.40824830532073975, 0.8164966106414795];
                   atol=1e-7)
    @test isapprox(get_attribute(grouped, :color).data,
                   [1, 0.21404114365577698, 0, 0, 1, 0.05087608844041824,
                    0.03310476616024971, 0.13286831974983215, 1,
                    0, 1, 0.05087608844041824,
                    0.7874122858047485, 0.010022825561463833, 0.07323895394802094,
                    0.03310476616024971, 0.13286831974983215, 1]; atol=1e-7)
    @test geo.uvs == [0.0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1]

    # A continuation that previously split the face record in load_obj_groups.
    cont = _a3b_file("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 \\\n3\n", ".obj")
    @test load_obj_groups(cont)[1].indices == load_obj(cont).indices == [1, 2, 3]
    # A coloured vertex followed by an inline comment keeps its colour.
    @test has_attribute(load_obj_groups(_a3b_file(
        "v 0 0 0 1 0 0\nv 1 0 0 0 1 0\nv 0 1 0 0 0 1 # c\nf 1 2 3\n", ".obj"))[1], :color)
    # Malformed input raises the same errors from both entry points.
    for (text, msg) in ("v 0 0 0\nv 1 0 0\nf 1 2 \\\n" => "OBJ face requires at least 3 vertices",
                        "v 0 0 0 1 x 0\n" => "OBJ v green must be a number",
                        "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 9\n" =>
                            "OBJ vertex index 9 out of bounds for 3 vertices")
        p = _a3b_file(text, ".obj")
        @test_throws msg load_obj(p)
        @test_throws msg load_obj_groups(p)
    end
end

@testset "PLY colours are sRGB and stored linear (three.js PLYLoader)" begin
    header = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\n" *
             "property float y\nproperty float z\n"
    face = "element face 1\nproperty list uchar int vertex_indices\nend_header\n"
    # Float channels: PLYLoader.js:629-643 setRGB(..., SRGBColorSpace) and
    # keeps the linear float. three.js r186 output (Float32):
    floats = load_ply(_a3b_file(header * "property float red\nproperty float green\n" *
                                "property float blue\n" * face *
                                "0 0 0 0.5 0.25 1\n1 0 0 0.1 0.04 0.9\n" *
                                "0 1 0 0.75 0 0.3\n3 0 1 2\n", ".ply"))
    @test isapprox(get_attribute(floats, :color).data,
                   [0.21404114365577698, 0.05087608844041824, 1,
                    0.010022825561463833, 0.0030959751456975937, 0.7874122858047485,
                    0.5225215554237366, 0, 0.07323895394802094]; atol=1e-7)
    # uchar channels: c/255 read as sRGB. three.js stores the result back in a
    # normalized Uint8 attribute (Math.round(linear * 255)); Diff3D keeps the
    # unrounded linear value, within half a step of three.js r186's output.
    bytes = load_ply(_a3b_file(header * "property uchar red\nproperty uchar green\n" *
                               "property uchar blue\n" * face *
                               "0 0 0 128 64 255\n1 0 0 26 10 230\n" *
                               "0 1 0 191 0 77\n3 0 1 2\n", ".ply"))
    col = get_attribute(bytes, :color).data
    @test col == _a3b_srgb_to_linear.([128, 64, 255, 26, 10, 230, 191, 0, 77] ./ 255)
    @test maximum(abs.(col .- [0.21568627450980393, 0.050980392156862744, 1,
                               0.011764705882352941, 0.00392156862745098, 0.792156862745098,
                               0.5215686274509804, 0, 0.07450980392156863])) <= 0.5 / 255
    # save_ply writes sRGB like PLYExporter, so colours now round-trip.
    box = BoxGeometry()
    set_attribute!(box, :color, [mod(0.37i, 1.0) for i in 1:3box.n_vertices], 3)
    for kw in ((;), (binary=true,), (binary=true, little_endian=true))
        back = load_ply(Diff3D.save_ply(_a3b_file("", ".ply"), box; kw...))
        @test isapprox(get_attribute(back, :color).data,
                       get_attribute(box, :color).data; atol=1e-14)
    end
end

# Face texcoord lists and face colours, PLYLoader.js:660-710 and 545-563.
const _A3B_FACE_PLY = """
ply
format ascii 1.0
element vertex 4
property float x
property float y
property float z
property float diffuse_red
property float diffuse_green
property float diffuse_blue
property float quality
property float conf
element face 2
property list uchar int vertex_indices
property list uchar float texcoord
property uchar red
property uchar green
property uchar blue
end_header
0 0 0 0.5 0.25 1 7 8
1 0 0 0.1 0.2 0.3 9 10
0 1 0 1 0 0.04 11 12
1 1 0 0.9 0.8 0.7 13 14
3 0 1 2 6 0 0 1 0 0 1 200 100 50
3 1 3 2 6 1 0 1 1 0 1 10 128 255
"""

@testset "PLY face texcoords, face colours and property mappings (PLYLoader)" begin
    geo = load_ply(_a3b_file(_A3B_FACE_PLY, ".ply"))
    # three.js r186 PLYLoader.parse: toNonIndexed geometry, uv from texcoord,
    # colour from the face (replacing the vertex colours).
    @test geo.indices == 1:6 && geo.n_vertices == 6 && geo.n_faces == 2
    @test geo.positions == [0.0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]
    @test geo.uvs == [0.0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1]
    # three.js truncates linear * 255 into a Uint8 attribute
    # ([147, 32, 8] and [0, 55, 255] / 255); Diff3D keeps the float.
    face1 = _a3b_srgb_to_linear.([200, 100, 50] ./ 255)
    face2 = _a3b_srgb_to_linear.([10, 128, 255] ./ 255)
    @test get_attribute(geo, :color).data == vcat(face1, face1, face1, face2, face2, face2)
    @test maximum(abs.(vcat(face1, face2) .- [147, 32, 8, 0, 55, 255] ./ 255)) < 1 / 255
    # Smooth normals are computed on the indexed mesh before de-indexing.
    @test geo.normals == repeat([0.0, 0, 1], 6)

    # setPropertyNameMapping renames file properties; setCustomPropertyNameMapping
    # adds attributes. three.js r186 output for the qc values: [7,8, 9,10, ...];
    # here the custom attribute is also expanded with the corners.
    mapped = load_ply(_a3b_file(replace(_A3B_FACE_PLY, "texcoord" => "tc"), ".ply");
                      property_name_mapping=Dict("diffuse_red" => "r0"),
                      custom_property_mapping=Dict(:qc => ["quality", "conf"]))
    qc = get_attribute(mapped, :qc)
    @test qc.item_size == 2
    @test qc.data == [7.0, 8, 9, 10, 11, 12, 9, 10, 13, 14, 11, 12]
    # Without the texcoord list only the face colours de-index the mesh.
    @test isempty(mapped.uvs)
    # Mapping diffuse_red away leaves the vertex colour incomplete; with no
    # face colours there is then no colour attribute at all.
    nofacecol = replace(_A3B_FACE_PLY, "property uchar red\nproperty uchar green\n" *
                        "property uchar blue\n" => "",
                        " 200 100 50" => "", " 10 128 255" => "")
    plain = load_ply(_a3b_file(nofacecol, ".ply"))
    # The texcoord list still de-indexes the mesh: corners (0,1,2), (1,3,2)
    # carry the Float32 vertex colours, read as sRGB.
    vcol = _a3b_srgb_to_linear.(Float64.(Float32[0.5, 0.25, 1, 0.1, 0.2, 0.3,
                                                 1, 0, 0.04, 0.9, 0.8, 0.7]))
    @test plain.indices == 1:6
    @test get_attribute(plain, :color).data == vcol[vcat(1:3, 4:6, 7:9, 4:6, 10:12, 7:9)]
    renamed = load_ply(_a3b_file(nofacecol, ".ply");
                       property_name_mapping=Dict("diffuse_red" => "r0"))
    @test !has_attribute(renamed, :color)
    rerouted = load_ply(_a3b_file(replace(nofacecol, "diffuse_red" => "weird"), ".ply");
                        property_name_mapping=Dict("weird" => "red"))
    @test has_attribute(rerouted, :color)

    # Quads and larger polygons carry their texcoords through the split.
    quad = """
    ply
    format ascii 1.0
    element vertex 5
    property float x
    property float y
    property float z
    element face 1
    property list uchar int vertex_indices
    property list uchar float texcoord
    end_header
    0 0 0
    1 0 0
    1 1 0
    0 1 0
    -1 0.5 0
    5 0 1 2 3 4 10 0 0 1 0 1 1 0 1 -1 0.5
    """
    g = load_ply(_a3b_file(quad, ".ply"))
    @test g.n_faces == 3
    @test g.uvs == [0.0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1, -1, 0.5]

    # Binary little-endian with the same face data.
    io = IOBuffer()
    write(io, "ply\nformat binary_little_endian 1.0\nelement vertex 3\n" *
              "property float x\nproperty float y\nproperty float z\n" *
              "element face 1\nproperty list uchar int vertex_indices\n" *
              "property list uchar float texcoord\nproperty float red\n" *
              "property float green\nproperty float blue\nend_header\n")
    foreach(x -> write(io, htol(Float32(x))), (0, 0, 0, 1, 0, 0, 0, 1, 0))
    write(io, UInt8(3), htol.(Int32[0, 1, 2])...)
    write(io, UInt8(6), htol.(Float32[0, 0, 1, 0, 0, 1])...)
    write(io, htol.(Float32[0.5, 0.25, 1])...)
    bin = load_ply(_a3b_file(take!(io), ".ply"))
    @test bin.uvs == [0.0, 0, 1, 0, 0, 1]
    @test get_attribute(bin, :color).data == repeat(_a3b_srgb_to_linear.([0.5, 0.25, 1]), 3)
end

@testset "PLY face data and mappings reject malformed input" begin
    base = "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\n" *
           "property float y\nproperty float z\nelement face 1\n" *
           "property list uchar int vertex_indices\n"
    verts = "0 0 0\n1 0 0\n0 1 0\n"
    @test_throws "PLY face row 1 texcoord has 4 values; expected 6" load_ply(_a3b_file(
        base * "property list uchar float texcoord\nend_header\n" * verts *
        "3 0 1 2 4 0 0 1 0\n", ".ply"))
    @test_throws "PLY face row 1 property texcoord item 2 must be a number" load_ply(_a3b_file(
        base * "property list uchar float texcoord\nend_header\n" * verts *
        "3 0 1 2 6 0 x 1 0 0 1\n", ".ply"))
    @test_throws "PLY face row 1 color channel red is outside the non-negative i8 range" load_ply(
        _a3b_file(base * "property char red\nproperty uchar green\nproperty uchar blue\n" *
                  "end_header\n" * verts * "3 0 1 2 -1 0 0\n", ".ply"))
    # A binary NaN face colour is an error rather than a NaN attribute.
    io = IOBuffer()
    write(io, replace(base, "ascii" => "binary_little_endian") *
              "property float red\nproperty float green\nproperty float blue\nend_header\n")
    foreach(x -> write(io, htol(Float32(x))), (0, 0, 0, 1, 0, 0, 0, 1, 0))
    write(io, UInt8(3), htol.(Int32[0, 1, 2])..., htol.(Float32[NaN, 0, 0])...)
    @test_throws "PLY face row 1 color channel red must be finite" load_ply(
        _a3b_file(take!(io), ".ply"))
    # A truncated binary texcoord list is reported, not read past the end.
    io = IOBuffer()
    write(io, replace(base, "ascii" => "binary_little_endian") *
              "property list uint float texcoord\nend_header\n")
    foreach(x -> write(io, htol(Float32(x))), (0, 0, 0, 1, 0, 0, 0, 1, 0))
    write(io, UInt8(3), htol.(Int32[0, 1, 2])..., htol(UInt32(1_000_000_000)))
    @test_throws "PLY binary element data is truncated" load_ply(_a3b_file(take!(io), ".ply"))

    plain = _a3b_file(base * "end_header\n" * verts * "3 0 1 2\n", ".ply")
    @test_throws "PLY vertex element has no property q for custom attribute a" load_ply(
        plain; custom_property_mapping=Dict(:a => ["q"]))
    @test_throws "cannot replace the position attribute" load_ply(
        plain; custom_property_mapping=Dict(:position => ["x"]))
    @test_throws "non-empty list of property names" load_ply(
        plain; custom_property_mapping=Dict(:a => String[]))
    @test_throws "must map property names to property names" load_ply(
        plain; property_name_mapping=Dict("x" => 1))
    @test_throws "PLY vertex property idx must be scalar" load_ply(_a3b_file(
        "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\n" *
        "property float z\nproperty list uchar int idx\nend_header\n0 0 0 1 5\n", ".ply");
        custom_property_mapping=Dict(:a => ["idx"]))
end

@testset "MTL colours are sRGB and the last map statement wins (MTLLoader)" begin
    dir = mktempdir()
    save_png(joinpath(dir, "second.png"), fill(0.75, 1, 1, 3))
    write(joinpath(dir, "m.mtl"),
          "newmtl a\nKd 0.5 0.25 1\nKs 0.2 0.04 0.9\nKe 0.1 0.6 0.0\nNs 12\n" *
          "map_Kd -s 2 3 first_missing.png\nmap_Kd second.png\nd 0.4\n" *
          "norm missing_normal.png\nnorm second.png\nnewmtl e\nd 1.5\nTr -0.5\n")
    mats = load_mtl(joinpath(dir, "m.mtl"))
    a = mats["a"]
    # three.js r186 MTLLoader.parse(...).create("a"), MTLLoader.js:395-409.
    @test isapprox(collect((a.color.r, a.color.g, a.color.b)),
                   [0.2140411404715882, 0.050876088164650994, 1]; rtol=1e-9)
    @test isapprox(collect((a.specular.r, a.specular.g, a.specular.b)),
                   [0.033104766565152086, 0.003095975232, 0.7874122893910657]; rtol=1e-9)
    @test isapprox(collect((a.emissive.r, a.emissive.g, a.emissive.b)),
                   [0.01002282557165656, 0.31854677811435356, 0]; rtol=1e-9)
    @test a.shininess == 12 && a.opacity == 0.4 && a.transparent
    # MTLLoader.js:150 `info[key] = value`: only the last map_Kd / norm is
    # used, so the missing first files are never opened.
    @test sample_texture(a.map, 0.5, 0.5).r ≈ 0.75 atol=1/255
    @test a.map.repeat == Vec2(1.0, 1.0)
    @test a.normal_map isa Texture
    # Without Ks the MeshPhongMaterial default specular is kept unchanged.
    e = mats["e"]
    @test e.specular == MeshPhongMaterial().specular
    # d above 1 and Tr below 0 are ignored, as in MTLLoader (opacity 1, opaque).
    @test e.opacity == 1.0 && !e.transparent
    # A malformed earlier map statement is still reported.
    @test_throws "MTL map_Kd requires a texture path" load_mtl(_a3b_file(
        "newmtl x\nmap_Kd -s 1 1\nmap_Kd second.png\n", ".mtl"))
    # MTLLoader would produce a negative opacity; Diff3D raises instead.
    @test_throws "MTL material b: Tr 1.5 gives a negative opacity" load_mtl(
        _a3b_file("newmtl b\nTr 1.5\n", ".mtl"))
    @test_throws "MTL material c: d -0.5 gives a negative opacity" load_mtl(
        _a3b_file("newmtl c\nd -0.5\n", ".mtl"))
end

@testset "glTF primitives without NORMAL are flat-shaded (GLTFLoader)" begin
    # A folded pair of triangles sharing the edge (0,1). glTF 2.0 §3.7.2.1
    # asks for flat normals; three.js r186 keeps the index and sets
    # material.flatShading = true (GLTFLoader.js:3559, oracle: flatShading
    # true, index [0,1,2,1,0,3]), so each fragment uses its face normal.
    # Diff3D gives every triangle its own corners and face normal, which all
    # its renderers and the browser export draw flat.
    b = A3BGLTF()
    pos = _a3b_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1e-4], "VEC3")
    idx = _a3b_accessor!(b, UInt16[0, 1, 2, 1, 0, 3], "SCALAR")
    doc, bufs = _a3b_doc(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0])], "nodes" => [Dict("mesh" => 0)],
        "meshes" => [Dict("primitives" => [Dict("attributes" => Dict("POSITION" => pos),
                                                "indices" => idx)])]))
    mesh = only(_a3b_meshes(Diff3D._gltf_build_scene(doc, bufs)))
    geo = mesh.geometry
    @test geo.indices == 1:6 && geo.n_faces == 2
    @test geo.positions == Float64.(Float32[0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1e-4])
    # Face normals: cross(b - a, c - a) normalised.
    z = Float64(1f-4)
    n2 = [0.0, z, -1.0] ./ hypot(z, 1.0)
    @test geo.normals[1:9] == repeat([0.0, 0, 1], 3)
    @test isapprox(geo.normals[10:18], repeat(n2, 3); atol=1e-15)

    # A skinned primitive without NORMAL keeps its joints per corner.
    b = A3BGLTF()
    pos = _a3b_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0], "VEC3")
    idx = _a3b_accessor!(b, UInt16[0, 1, 2, 1, 3, 2], "SCALAR")
    joints = _a3b_accessor!(b, UInt8[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "VEC4")
    weights = _a3b_accessor!(b, Float32[1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], "VEC4")
    doc, bufs = _a3b_doc(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0, 1])],
        "nodes" => [Dict("mesh" => 0, "skin" => 0), Dict("name" => "joint")],
        "skins" => [Dict("joints" => [1])],
        "meshes" => [Dict("primitives" => [Dict(
            "attributes" => Dict("POSITION" => pos, "JOINTS_0" => joints,
                                 "WEIGHTS_0" => weights), "indices" => idx)])]))
    skinned = only(filter(o -> o isa SkinnedMesh, _a3b_objects(Diff3D._gltf_build_scene(doc, bufs))))
    @test skinned.geometry.n_vertices == 6
    @test skinned.geometry.normals == repeat([0.0, 0, 1], 6)
end

@testset "glTF weights channels need morph targets; KHR_materials_ior 0" begin
    # three.js gives only meshes with morph attributes morphTargetInfluences
    # and so creates no track for a weights channel on a mesh without targets
    # (oracle: zero tracks). glTF requires such a mesh to have targets; Diff3D
    # reports the channel instead of writing influences the mesh cannot use.
    b = A3BGLTF()
    pos = _a3b_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    t = _a3b_accessor!(b, Float32[0, 1], "SCALAR"; minmax=true)
    w = _a3b_accessor!(b, Float32[0, 1], "SCALAR")
    doc, bufs = _a3b_doc(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0])], "nodes" => [Dict("mesh" => 0)],
        "meshes" => [Dict("primitives" => [Dict("attributes" => Dict("POSITION" => pos))])],
        "animations" => [Dict("samplers" => [Dict("input" => t, "output" => w)],
                              "channels" => [Dict("sampler" => 0,
                                                  "target" => Dict("node" => 0, "path" => "weights"))])]))
    @test_throws "glTF weights animation targets node 0, which has no morph-target primitives" Diff3D._gltf_build_asset(doc, bufs)

    # KHR_materials_ior: ior 0 is the spec's infinite index of refraction;
    # three.js GLTFLoader.js:1277 stores it as 1000 (oracle: ior 1000).
    function ior_material(ior)
        b = A3BGLTF()
        pos = _a3b_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
        nrm = _a3b_accessor!(b, Float32[0, 0, 1, 0, 0, 1, 0, 0, 1], "VEC3")
        doc, bufs = _a3b_doc(b, Dict{String,Any}(
            "scene" => 0, "scenes" => [Dict("nodes" => [0])], "nodes" => [Dict("mesh" => 0)],
            "materials" => [Dict("extensions" => Dict("KHR_materials_ior" => Dict("ior" => ior)))],
            "meshes" => [Dict("primitives" => [Dict("attributes" => Dict("POSITION" => pos, "NORMAL" => nrm),
                                                    "material" => 0)])]))
        return only(_a3b_meshes(Diff3D._gltf_build_scene(doc, bufs))).material
    end
    @test ior_material(0.0).ior == 1000.0
    @test ior_material(1.7).ior == 1.7
    @test_throws "glTF KHR_materials_ior ior must be 0 or at least 1" ior_material(0.5)

    # A texture on TEXCOORD_2 or TEXCOORD_3 (three.js uv2/uv3) is reported by
    # the loader rather than as a generic Texture argument error.
    @test_throws "glTF texture texCoord 2 is not supported" Diff3D._gltf_texture_transform(
        Dict{String,Any}("index" => 0, "texCoord" => 2))
end

@testset "load_obj_scene builds OBJLoader's objects, lines and points" begin
    text = "v 0 0 0 1 0 0\nv 1 0 0 0 1 0\nv 0 1 0 0 0 1\nv 1 1 0 0.5 0.5 0.5\n" *
           "o tri\nf 1 2 3\no wire\nl 1 2\nl 2 4\no cloud\np 1 3 4\n"
    root = Diff3D.load_obj_scene(_a3b_file(text, ".obj"))
    # three.js r186 OBJLoader.parse of the same text: Mesh "tri",
    # LineSegments "wire", Points "cloud" (OBJLoader.js:812-860).
    @test [typeof(c) for c in root.children] == [Mesh, LineSegments, PointsObject]
    @test [c.name for c in root.children] == ["tri", "wire", "cloud"]
    tri, wire, cloud = root.children
    @test tri.geometry.positions == [0.0, 0, 0, 1, 0, 0, 0, 1, 0]
    @test tri.geometry.normals == [0.0, 0, 1, 0, 0, 1, 0, 0, 1]
    @test get_attribute(tri.geometry, :color).data == [1.0, 0, 0, 0, 1, 0, 0, 0, 1]
    @test tri.material isa MeshPhongMaterial && tri.material.vertex_colors
    @test wire.geometry.positions == [0.0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0]
    @test wire.material isa LineBasicMaterial
    @test cloud.geometry.positions == [0.0, 0, 0, 0, 1, 0, 1, 1, 0]
    @test isapprox(get_attribute(cloud.geometry, :color).data,
                   [1, 0, 0, 0, 0, 1, 0.21404114365577698, 0.21404114365577698,
                    0.21404114365577698]; atol=1e-7)
    @test cloud.material isa PointsMaterial && cloud.material.size == 1.0 &&
          !cloud.material.size_attenuation

    # A polyline is its consecutive segments (three.js would pair the
    # vertices of `l 1 2 3` as 1-2 only); negative indices are relative.
    @test_throws "OBJ uv index 1 out of bounds for 0 texture coordinates" Diff3D.load_obj_scene(
        _a3b_file("v 0 0 0\nv 1 0 0\nl 1/1 2\n", ".obj"))
    poly = Diff3D.load_obj_scene(_a3b_file("v 0 0 0\nv 1 0 0\nv 1 1 0\nl 1 -2 -1\n", ".obj"))
    @test only(poly.children).geometry.positions == [0.0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0]

    # Objects with several materials get one mesh per material; library
    # colours reach lines and points (size 10 with a library material).
    dir = mktempdir()
    write(joinpath(dir, "m.mtl"), "newmtl red\nKd 1 0 0\nnewmtl blue\nKd 0 0 1\n")
    write(joinpath(dir, "s.obj"),
          "mtllib m.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nv 1 1 0\ng part\nusemtl red\n" *
          "f 1 2 3\nusemtl blue\nf 2 4 3\nusemtl red\nf 1 2 4\nl 1 4\np 2\n")
    scene = Diff3D.load_obj_scene(joinpath(dir, "s.obj"))
    flat = load_obj(joinpath(dir, "s.obj"))
    meshes = filter(c -> c isa Mesh, scene.children)
    @test [m.material.color for m in meshes] == [Color3(1.0, 0, 0), Color3(0.0, 0, 1)]
    @test meshes[1].geometry.positions == flat.positions[vcat(1:9, 19:27)]
    @test meshes[2].geometry.normals == flat.normals[10:18]
    @test all(c -> c.name == "part", scene.children)
    line = only(filter(c -> c isa LineSegments, scene.children))
    @test line.material.color == Color3(1.0, 0, 0)
    pts = only(filter(c -> c isa PointsObject, scene.children))
    @test pts.material.color == Color3(1.0, 0, 0) && pts.material.size == 10.0

    # Only vertices: one point cloud (OBJLoader.js:870-890).
    cloud_only = Diff3D.load_obj_scene(_a3b_file("v 0 0 0\nv 1 2 3\n", ".obj"))
    @test only(cloud_only.children) isa PointsObject
    @test only(cloud_only.children).geometry.positions == [0.0, 0, 0, 1, 2, 3]
    @test isempty(Diff3D.load_obj_scene(_a3b_file("# nothing\n", ".obj")).children)

    # Malformed primitive records.
    @test_throws "OBJ line requires at least 2 vertices" Diff3D.load_obj_scene(
        _a3b_file("v 0 0 0\nl 1\n", ".obj"))
    @test_throws "OBJ point requires at least 1 vertex" Diff3D.load_obj_scene(
        _a3b_file("v 0 0 0\np\n", ".obj"))
    @test_throws "OBJ vertex index 5 out of bounds for 1 vertices" Diff3D.load_obj_scene(
        _a3b_file("v 0 0 0\np 5\n", ".obj"))
    @test_throws "OBJ vertex index must be an integer" Diff3D.load_obj_scene(
        _a3b_file("v 0 0 0\nl 1 x\n", ".obj"))
    # load_obj keeps ignoring l and p records.
    @test load_obj(_a3b_file("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\nl 1 9\n", ".obj")).n_faces == 1
end

@testset "STL colours and ASCII numbers match STLLoader" begin
    # Binary STL with a Materialise COLOR= header: facet 1 has its own 5-bit
    # colour (bit 15 clear), facet 2 uses the header default. three.js r186
    # STLLoader.parse output (Float32 colours, STLLoader.js:150-215).
    io = IOBuffer()
    head = zeros(UInt8, 80)
    head[1:8] = Vector{UInt8}("xxCOLOR=")
    head[9:12] = [200, 100, 50, 128]
    write(io, head, htol(UInt32(2)))
    for (k, attr) in enumerate((UInt16(31 | (10 << 5) | (3 << 10)), UInt16(0x8000)))
        write(io, htol.(Float32[0, 0, 1])..., htol.(Float32[0, 0, k, 1, 0, k, 0, 1, k])...,
              htol(attr))
    end
    geo = load_stl(_a3b_file(take!(io), ".stl"))
    @test isapprox(get_attribute(geo, :color).data,
                   vcat(repeat([1, 0.0849214568734169, 0.0095294788479805], 3),
                        repeat([0.577580451965332, 0.12743768095970154, 0.03189603239297867], 3));
                   atol=1e-7)
    @test geo.positions == [0.0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 2, 1, 0, 2, 0, 1, 2]
    # Number forms STLLoader's patternFloat accepts.
    ascii = load_stl(_a3b_file("solid t\n facet normal 0 0 +1.\n  outer loop\n" *
                               "   vertex .5 0 0 7\n   vertex 1.e0 0 0\n   vertex 0 1E0 -0\n" *
                               "  endloop\n endfacet\nendsolid t\n", ".stl"))
    @test ascii.positions == [0.5, 0, 0, 1, 0, 0, 0, 1, 0]
    @test ascii.normals == repeat([0.0, 0, 1], 3)
end
