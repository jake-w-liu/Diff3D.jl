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

function _loaders_audit_gltf(; material="{}", textures=nothing, images=nothing,
                             samplers=nothing, extra="")
    bin = reinterpret(UInt8, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1])
    png_path = tempname() * ".png"
    save_png(png_path, fill(0.5, 2, 2, 3))
    png_uri = "data:image/png;base64," * base64encode(read(png_path))
    images === nothing && (images = "[{\"uri\":\"$png_uri\"}]")
    textures === nothing && (textures = "[{\"source\":0$(samplers === nothing ? "" : ",\"sampler\":0")}]")
    doc = """{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
      "nodes":[{"mesh":0}],
      "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"material":0}]}],
      "materials":[$material],
      "textures":$textures,"images":$images,
      $(samplers === nothing ? "" : "\"samplers\":$samplers,")
      "buffers":[{"byteLength":$(length(bin)),"uri":"data:application/octet-stream;base64,$(base64encode(bin))"}],
      "bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":24}],
      "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]},
                   {"bufferView":1,"componentType":5126,"count":3,"type":"VEC2"}]$extra}"""
    return _loaders_audit_file(doc, ".gltf")
end

_loaders_audit_first_mesh(scene) = only(collect_meshes(scene))

const _LOADERS_AUDIT_TEXTURED = """{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}"""

@testset "glTF sampler filter defaults follow three.js" begin
    for (samplers, minf, magf, filt, mips) in (
            (nothing, :linear_mipmap_linear, :linear, :bilinear, true),
            ("[{}]", :linear_mipmap_linear, :linear, :bilinear, true),
            ("[{\"magFilter\":9728}]", :linear_mipmap_linear, :nearest, :nearest, true),
            ("[{\"minFilter\":9728}]", :nearest, :linear, :bilinear, false),
            ("[{\"minFilter\":9729,\"magFilter\":9728}]", :linear, :nearest, :nearest, false))
        scene = load_gltf(_loaders_audit_gltf(; material=_LOADERS_AUDIT_TEXTURED,
                                              samplers=samplers))
        tex = _loaders_audit_first_mesh(scene).material.map
        @test tex.min_filter === minf
        @test tex.mag_filter === magf
        @test tex.filter === filt
        @test !isempty(tex.mipmaps) == mips
    end
end

@testset "glTF material alphaMode must be a glTF enum value" begin
    for mode in ("BOGUS", "blend", "Opaque")
        @test_throws "glTF material alphaMode must be OPAQUE, MASK, or BLEND" load_gltf(
            _loaders_audit_gltf(; material="{\"alphaMode\":\"$mode\"}"))
    end
    @test_throws "glTF material alphaMode must be OPAQUE, MASK, or BLEND" load_gltf(
        _loaders_audit_gltf(; material="{\"alphaMode\":1}"))
    mat = _loaders_audit_first_mesh(load_gltf(_loaders_audit_gltf(;
        material="{\"alphaMode\":\"BLEND\",\"pbrMetallicRoughness\":{\"baseColorFactor\":[1,1,1,0.25]}}"))).material
    @test mat.transparent && mat.opacity == 0.25
end

@testset "glTF textures without a usable image source are errors" begin
    @test_throws "glTF image is missing uri and bufferView" load_gltf(
        _loaders_audit_gltf(; material=_LOADERS_AUDIT_TEXTURED,
                            images="[{\"mimeType\":\"image/png\"}]"))
    @test_throws "glTF texture 0 has no supported image source" load_gltf(
        _loaders_audit_gltf(; material=_LOADERS_AUDIT_TEXTURED, textures="[{}]"))
    path = _loaders_audit_gltf(; material=_LOADERS_AUDIT_TEXTURED)
    text = replace(read(path, String), r"\"textures\":\[[^\]]*\],\"images\":\[[^\]]*\]," => "")
    @test !occursin("\"textures\"", text)
    @test_throws "glTF texture index 0 out of bounds" load_gltf(
        _loaders_audit_file(text, ".gltf"))
end

@testset "glTF normalized integer animation outputs" begin
    times = reinterpret(UInt8, Float32[0, 1])
    q = Int16[0, 0, 0, 32767, 0, 32767, 0, 0]
    w = UInt8[255, 0, 0, 255]
    t = Int16[0, 0, 0, 0, 0, 0]
    bin = vcat(times, reinterpret(UInt8, q), w, reinterpret(UInt8, t))
    base = """{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
      "nodes":[{"mesh":0}],
      "meshes":[{"primitives":[{"attributes":{"POSITION":0},
                 "targets":[{"POSITION":0},{"POSITION":0}]}],"weights":[0,0]}],
      "buffers":[{"byteLength":$(length(bin)),"uri":"data:application/octet-stream;base64,$(base64encode(bin))"}],
      "bufferViews":[{"buffer":0,"byteLength":8},{"buffer":0,"byteOffset":8,"byteLength":16},
                     {"buffer":0,"byteOffset":24,"byteLength":4},{"buffer":0,"byteOffset":28,"byteLength":12}],
      "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"SCALAR","min":[0],"max":[1]},
                   {"bufferView":1,"componentType":5122,"normalized":true,"count":2,"type":"VEC4"},
                   {"bufferView":2,"componentType":5121,"normalized":true,"count":4,"type":"SCALAR"},
                   {"bufferView":3,"componentType":5122,"normalized":true,"count":2,"type":"VEC3"}],
      "animations":[{"samplers":[{"input":0,"output":1},{"input":0,"output":2},{"input":0,"output":3}],
                     "channels":[CHANNELS]}]}"""
    pos = Float32[0, 0, 0, 1, 0, 0, 0, 1, 0]
    doc = replace(base, "\"accessors\":[" =>
        "\"accessors\":[{\"bufferView\":4,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\",\"min\":[0,0,0],\"max\":[1,1,0]},")
    # Shift every authored accessor index by one for the prepended POSITION accessor.
    bin2 = vcat(bin, reinterpret(UInt8, pos))
    doc = replace(doc,
        "\"input\":0,\"output\":1" => "\"input\":1,\"output\":2",
        "\"input\":0,\"output\":2" => "\"input\":1,\"output\":3",
        "\"input\":0,\"output\":3" => "\"input\":1,\"output\":4",
        "\"byteLength\":12}]," => "\"byteLength\":12},{\"buffer\":0,\"byteOffset\":40,\"byteLength\":36}],",
        "\"byteLength\":$(length(bin)),\"uri\":\"data:application/octet-stream;base64,$(base64encode(bin))\"" =>
            "\"byteLength\":$(length(bin2)),\"uri\":\"data:application/octet-stream;base64,$(base64encode(bin2))\"")
    channels = """{"sampler":0,"target":{"node":0,"path":"rotation"}},
                  {"sampler":1,"target":{"node":0,"path":"weights"}}"""
    asset = load_gltf_asset(_loaders_audit_file(replace(doc, "CHANNELS" => channels), ".gltf"))
    tracks = only(asset.animations).tracks
    rot = only(t for t in tracks if t isa QuaternionKeyframeTrack)
    @test rot.values[1] == Quaternion(0.0, 0.0, 0.0, 1.0)
    @test rot.values[2] == Quaternion(0.0, 1.0, 0.0, 0.0)
    wts = only(t for t in tracks if t isa MorphWeightsKeyframeTrack)
    @test wts.values == [[1.0, 0.0], [0.0, 1.0]]
    bad = """{"sampler":2,"target":{"node":0,"path":"translation"}}"""
    @test_throws "glTF animation output accessor componentType/normalized combination is invalid" load_gltf_asset(
        _loaders_audit_file(replace(doc, "CHANNELS" => bad), ".gltf"))
end
