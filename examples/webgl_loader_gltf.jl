# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_loader_gltf

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function append_little_endian_f32!(bytes::Vector{UInt8}, values)
    while length(bytes) % 4 != 0
        push!(bytes, 0x00)
    end
    offset = length(bytes)
    for value in Float32.(values)
        bits = reinterpret(UInt32, value)
        push!(bytes, UInt8(bits & 0x000000ff))
        push!(bytes, UInt8((bits >> 8) & 0x000000ff))
        push!(bytes, UInt8((bits >> 16) & 0x000000ff))
        push!(bytes, UInt8((bits >> 24) & 0x000000ff))
    end
    return offset, length(bytes) - offset
end

function append_little_endian_u16!(bytes::Vector{UInt8}, values)
    while length(bytes) % 4 != 0
        push!(bytes, 0x00)
    end
    offset = length(bytes)
    for value in UInt16.(values)
        push!(bytes, UInt8(value & 0x00ff))
        push!(bytes, UInt8(value >> 8))
    end
    while length(bytes) % 4 != 0
        push!(bytes, 0x00)
    end
    return offset, length(values) * 2
end

function texture_data(; n::Int=32)
    data = ones(Float64, n, n, 4)
    for y in 1:n, x in 1:n
        u = (x - 1) / (n - 1)
        v = (y - 1) / (n - 1)
        band = (fld(x - 1, 4) + fld(y - 1, 4)) % 2 == 0
        data[y, x, 1] = band ? 0.95 : 0.18 + 0.36u
        data[y, x, 2] = band ? 0.74 : 0.22 + 0.46v
        data[y, x, 3] = band ? 0.18 : 0.82
        data[y, x, 4] = 1.0
    end
    return data
end

function generated_mesh_buffers()
    positions = Float32[]
    normals = Float32[]
    uvs = Float32[]
    indices = UInt16[]

    function add_face!(corners, normal)
        base = UInt16(length(positions) ÷ 3)
        face_uvs = ((0.0f0, 0.0f0), (1.0f0, 0.0f0), (1.0f0, 1.0f0), (0.0f0, 1.0f0))
        for (p, uv) in zip(corners, face_uvs)
            append!(positions, Float32[p[1], p[2], p[3]])
            append!(normals, Float32[normal[1], normal[2], normal[3]])
            append!(uvs, Float32[uv[1], uv[2]])
        end
        append!(indices, UInt16[base, base + 1, base + 2, base, base + 2, base + 3])
    end

    sx, sy, sz = 0.78f0, 0.52f0, 0.72f0
    add_face!(((-sx, -sy,  sz), ( sx, -sy,  sz), ( sx,  sy,  sz), (-sx,  sy,  sz)), (0.0f0, 0.0f0, 1.0f0))
    add_face!((( sx, -sy, -sz), (-sx, -sy, -sz), (-sx,  sy, -sz), ( sx,  sy, -sz)), (0.0f0, 0.0f0, -1.0f0))
    add_face!((( sx, -sy,  sz), ( sx, -sy, -sz), ( sx,  sy, -sz), ( sx,  sy,  sz)), (1.0f0, 0.0f0, 0.0f0))
    add_face!(((-sx, -sy, -sz), (-sx, -sy,  sz), (-sx,  sy,  sz), (-sx,  sy, -sz)), (-1.0f0, 0.0f0, 0.0f0))
    add_face!(((-sx,  sy,  sz), ( sx,  sy,  sz), ( sx,  sy, -sz), (-sx,  sy, -sz)), (0.0f0, 1.0f0, 0.0f0))
    add_face!(((-sx, -sy, -sz), ( sx, -sy, -sz), ( sx, -sy,  sz), (-sx, -sy,  sz)), (0.0f0, -1.0f0, 0.0f0))

    return positions, normals, uvs, indices
end

function write_gltf_assets!(dir::String)
    texture_path = joinpath(dir, "diff3d_loader_gltf_base.png")
    save_png(texture_path, texture_data())

    positions, normals, uvs, indices = generated_mesh_buffers()
    times = Float32[0.0, 1.5, 3.0]
    rotations = Float32[0, 0, 0, 1,
                        0, sin(Float32(pi / 2)), 0, cos(Float32(pi / 2)),
                        0, sin(Float32(pi)), 0, cos(Float32(pi))]
    translations = Float32[0, 0, 0,
                           0, 0.28, 0,
                           0, 0, 0]
    scales = Float32[1, 1, 1,
                     1.18, 1.18, 1.18,
                     1, 1, 1]

    bytes = UInt8[]
    pos_off, pos_len = append_little_endian_f32!(bytes, positions)
    nrm_off, nrm_len = append_little_endian_f32!(bytes, normals)
    uv_off, uv_len = append_little_endian_f32!(bytes, uvs)
    idx_off, idx_len = append_little_endian_u16!(bytes, indices)
    time_off, time_len = append_little_endian_f32!(bytes, times)
    rot_off, rot_len = append_little_endian_f32!(bytes, rotations)
    trans_off, trans_len = append_little_endian_f32!(bytes, translations)
    scale_off, scale_len = append_little_endian_f32!(bytes, scales)

    bin_path = joinpath(dir, "diff3d_loader_gltf.bin")
    write(bin_path, bytes)

    gltf = """
{
  "asset": { "version": "2.0", "generator": "Diff3D.jl webgl_loader_gltf parity example" },
  "scene": 0,
  "scenes": [{ "nodes": [0, 1] }],
  "nodes": [
    { "name": "animated_gltf_model", "mesh": 0, "translation": [0.0, 0.25, 0.0] },
    {
      "name": "gltf_key_light",
      "translation": [2.0, 3.2, 2.8],
      "extensions": { "KHR_lights_punctual": { "light": 0 } }
    }
  ],
  "extensionsUsed": ["KHR_lights_punctual"],
  "extensions": {
    "KHR_lights_punctual": {
      "lights": [
        { "type": "point", "color": [1.0, 0.86, 0.62], "intensity": 7.0, "range": 8.0 }
      ]
    }
  },
  "meshes": [{
    "name": "diff3d_box_model",
    "primitives": [{
      "attributes": { "POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2 },
      "indices": 3,
      "material": 0
    }]
  }],
  "materials": [{
    "name": "textured_pbr",
    "doubleSided": true,
    "pbrMetallicRoughness": {
      "baseColorFactor": [1.0, 1.0, 1.0, 1.0],
      "metallicFactor": 0.08,
      "roughnessFactor": 0.42,
      "baseColorTexture": { "index": 0 }
    }
  }],
  "images": [{ "uri": "diff3d_loader_gltf_base.png" }],
  "textures": [{ "source": 0, "sampler": 0 }],
  "samplers": [{ "wrapS": 10497, "wrapT": 10497, "magFilter": 9729, "minFilter": 9729 }],
  "buffers": [{ "byteLength": $(length(bytes)), "uri": "diff3d_loader_gltf.bin" }],
  "bufferViews": [
    { "buffer": 0, "byteOffset": $pos_off, "byteLength": $pos_len },
    { "buffer": 0, "byteOffset": $nrm_off, "byteLength": $nrm_len },
    { "buffer": 0, "byteOffset": $uv_off, "byteLength": $uv_len },
    { "buffer": 0, "byteOffset": $idx_off, "byteLength": $idx_len },
    { "buffer": 0, "byteOffset": $time_off, "byteLength": $time_len },
    { "buffer": 0, "byteOffset": $rot_off, "byteLength": $rot_len },
    { "buffer": 0, "byteOffset": $trans_off, "byteLength": $trans_len },
    { "buffer": 0, "byteOffset": $scale_off, "byteLength": $scale_len }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": $(length(positions) ÷ 3), "type": "VEC3", "min": [-0.78, -0.52, -0.72], "max": [0.78, 0.52, 0.72] },
    { "bufferView": 1, "componentType": 5126, "count": $(length(normals) ÷ 3), "type": "VEC3" },
    { "bufferView": 2, "componentType": 5126, "count": $(length(uvs) ÷ 2), "type": "VEC2" },
    { "bufferView": 3, "componentType": 5123, "count": $(length(indices)), "type": "SCALAR" },
    { "bufferView": 4, "componentType": 5126, "count": $(length(times)), "type": "SCALAR", "min": [$(minimum(times))], "max": [$(maximum(times))] },
    { "bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 6, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 7, "componentType": 5126, "count": 3, "type": "VEC3" }
  ],
  "animations": [{
    "name": "gltf_loader_turntable",
    "samplers": [
      { "input": 4, "output": 5, "interpolation": "LINEAR" },
      { "input": 4, "output": 6, "interpolation": "LINEAR" },
      { "input": 4, "output": 7, "interpolation": "STEP" }
    ],
    "channels": [
      { "sampler": 0, "target": { "node": 0, "path": "rotation" } },
      { "sampler": 1, "target": { "node": 0, "path": "translation" } },
      { "sampler": 2, "target": { "node": 0, "path": "scale" } }
    ]
  }]
}
"""
    gltf_path = joinpath(dir, "diff3d_loader_gltf.gltf")
    write(gltf_path, gltf)
    return gltf_path
end

function loaded_gltf_asset()
    mktempdir() do dir
        gltf_path = write_gltf_assets!(dir)
        asset = load_gltf_asset(gltf_path)
        return asset
    end
end

function build_case()
    asset = loaded_gltf_asset()
    scene = asset.scene
    scene.background = Color3(0.014, 0.018, 0.026)
    scene.fog = FogExp2(color=Color3(0.014, 0.018, 0.026), density=0.035)
    add!(scene, AmbientLight(color=Color3(0.34, 0.36, 0.44), intensity=0.48))
    add!(scene, HemisphereLight(color=Color3(0.58, 0.70, 0.92),
                                ground_color=Color3(0.15, 0.13, 0.10),
                                intensity=0.46))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.94, 0.82), intensity=1.25,
                                 position=Vec3(-3.2, 4.8, 3.1), cast_shadow=true))

    floor = Mesh(PlaneGeometry(width=6.5, height=6.5, width_segments=4, height_segments=4),
                 MeshStandardMaterial(color=Color3(0.22, 0.24, 0.28), roughness=0.86);
                 name="gltf_loader_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    floor.position = Vec3(0.0, -0.55, 0.0)
    add!(scene, floor)
    add!(scene, GridHelper(6.5, 13; color=Color3(0.11, 0.14, 0.19)))

    WebGLExportCase("loader-gltf", "GLTF Loader",
                    "Generated glTF asset loaded through Diff3D.jl load_gltf_asset, including texture, punctual light, and animation clips.",
                    scene; target=Vec3(0.0, 0.25, 0.0), radius=5.8, height=2.0,
                    fov=pi / 4.2, animations=asset.animations,
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_loader_gltf.html"), [build_case()])
    println("WEBGL_LOADER_GLTF_OK $html")
end

main()
