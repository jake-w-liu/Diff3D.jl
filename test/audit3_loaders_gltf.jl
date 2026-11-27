using Test, Diff3D, Base64

# In-memory glTF builder: every accessor gets its own tightly packed buffer
# view in buffer 0. Documents are loaded through the same internal entry points
# that `load_gltf`/`load_glb` use after the buffers have been read.
mutable struct Audit3GLTFBuilder
    bin::Vector{UInt8}
    views::Vector{Any}
    accessors::Vector{Any}
end
Audit3GLTFBuilder() = Audit3GLTFBuilder(UInt8[], Any[], Any[])

const AUDIT3_COMPONENT_TYPES = Dict(Float32 => 5126, Int8 => 5120, UInt8 => 5121,
                                    Int16 => 5122, UInt16 => 5123, UInt32 => 5125)
const AUDIT3_COMPONENTS = Dict("SCALAR" => 1, "VEC2" => 2, "VEC3" => 3,
                               "VEC4" => 4, "MAT4" => 16)

function audit3_view!(b::Audit3GLTFBuilder, bytes::Vector{UInt8}; stride=nothing)
    while length(b.bin) % 4 != 0
        push!(b.bin, 0x00)
    end
    view = Dict{String,Any}("buffer" => 0, "byteOffset" => length(b.bin),
                            "byteLength" => length(bytes))
    stride === nothing || (view["byteStride"] = stride)
    append!(b.bin, bytes)
    push!(b.views, view)
    return length(b.views) - 1
end

function audit3_accessor!(b::Audit3GLTFBuilder, data::Vector{T}, type::String;
                          normalized::Bool=false, stride=nothing) where {T}
    view = audit3_view!(b, collect(reinterpret(UInt8, data)); stride=stride)
    ncomp = AUDIT3_COMPONENTS[type]
    acc = Dict{String,Any}("bufferView" => view,
                           "componentType" => AUDIT3_COMPONENT_TYPES[T],
                           "count" => length(data) ÷ ncomp, "type" => type)
    normalized && (acc["normalized"] = true)
    push!(b.accessors, acc)
    return length(b.accessors) - 1
end

function audit3_document(b::Audit3GLTFBuilder, doc::Dict{String,Any})
    doc["asset"] = Dict{String,Any}("version" => "2.0")
    doc["accessors"] = b.accessors
    doc["bufferViews"] = b.views
    doc["buffers"] = [Dict{String,Any}("byteLength" => length(b.bin))]
    Diff3D._gltf_validate_document(doc)
    return doc, [copy(b.bin)]
end

audit3_scene(doc, buffers) = Diff3D._gltf_build_scene(doc, buffers)
audit3_asset(doc, buffers) = Diff3D._gltf_build_asset(doc, buffers)

function audit3_triangle_doc(materials; extra_prims=Any[])
    b = Audit3GLTFBuilder()
    pos = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    nrm = audit3_accessor!(b, Float32[0, 0, 1, 0, 0, 1, 0, 0, 1], "VEC3")
    prims = Any[Dict{String,Any}("attributes" => Dict("POSITION" => pos, "NORMAL" => nrm),
                                 "material" => i - 1) for i in eachindex(materials)]
    for prim in extra_prims
        push!(prims, prim(pos))
    end
    return audit3_document(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0])],
        "nodes" => [Dict("mesh" => 0)],
        "meshes" => [Dict("primitives" => prims)],
        "materials" => materials))
end

@testset "glTF BLEND materials disable depth writes" begin
    # three.js GLTFLoader.js:3672-3677: alphaMode BLEND sets transparent=true
    # and depthWrite=false; OPAQUE and MASK keep depthWrite=true. Lines and
    # points copy the mesh material (GLTFLoader.js:3505-3539).
    blend = Dict("alphaMode" => "BLEND",
                 "pbrMetallicRoughness" => Dict("baseColorFactor" => [0.2, 0.3, 0.4, 0.5]))
    materials = Any[
        blend,
        Dict("alphaMode" => "MASK", "alphaCutoff" => 0.25),
        Dict("alphaMode" => "OPAQUE"),
        Dict("alphaMode" => "BLEND", "extensions" => Dict("KHR_materials_unlit" => Dict())),
        Dict("alphaMode" => "BLEND", "extensions" => Dict("KHR_materials_ior" => Dict("ior" => 1.4))),
        Dict("alphaMode" => "BLEND", "extensions" => Dict("KHR_materials_pbrSpecularGlossiness" => Dict())),
    ]
    extra = Any[pos -> Dict{String,Any}("attributes" => Dict("POSITION" => pos), "material" => 0, "mode" => 0),
                pos -> Dict{String,Any}("attributes" => Dict("POSITION" => pos), "material" => 0, "mode" => 3)]
    scene = audit3_scene(audit3_triangle_doc(materials; extra_prims=extra)...)
    objects = only(get_children(scene)).children
    @test objects[1].material isa MeshStandardMaterial
    @test objects[1].material.transparent && !objects[1].material.depth_write
    @test objects[2].material.depth_write && objects[2].material.alpha_test == 0.25
    @test objects[3].material.depth_write
    @test objects[4].material isa MeshBasicMaterial && !objects[4].material.depth_write
    @test objects[5].material isa MeshPhysicalMaterial && !objects[5].material.depth_write
    @test objects[6].material isa MeshPhongMaterial && !objects[6].material.depth_write
    @test objects[7] isa PointsObject && !objects[7].material.depth_write
    @test objects[8] isa LineObject && !objects[8].material.depth_write
end

@testset "glTF points use one-pixel unattenuated size" begin
    # three.js GLTFLoader.js:3514: pointsMaterial.sizeAttenuation = false
    # ("glTF spec says points should be 1px"); PointsMaterial.size defaults to 1.
    extra = Any[pos -> Dict{String,Any}("attributes" => Dict("POSITION" => pos), "mode" => 0)]
    scene = audit3_scene(audit3_triangle_doc(Any[]; extra_prims=extra)...)
    points = only(only(get_children(scene)).children)
    @test points isa PointsObject
    @test points.material.size == 1.0
    @test !points.material.size_attenuation
end

@testset "glTF all-zero skin weights bind to the first joint" begin
    # three.js GLTFLoader.js:3928 normalizes skin weights; SkinnedMesh.js:274-280
    # replaces an all-zero weight vector with (1,0,0,0). Expected skinned
    # positions are three.js r186 SkinnedMesh.applyBoneTransform output.
    b = Audit3GLTFBuilder()
    pos = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    joints = audit3_accessor!(b, UInt8[0, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0], "VEC4")
    weights = audit3_accessor!(b, Float32[0.5, 0.5, 0, 0, 0, 0, 0, 0, 2, 6, 0, 0], "VEC4")
    ibm = audit3_accessor!(b, Float32[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
                                      1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0, 0, 1], "MAT4")
    doc, buffers = audit3_document(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0, 1])],
        "nodes" => [Dict("mesh" => 0, "skin" => 0),
                    Dict("children" => [2], "rotation" => [0, 0, 0.3826834323650898, 0.9238795325112867]),
                    Dict("translation" => [1, 0, 0])],
        "skins" => [Dict("joints" => [1, 2], "inverseBindMatrices" => ibm)],
        "meshes" => [Dict("primitives" => [Dict("attributes" => Dict(
            "POSITION" => pos, "JOINTS_0" => joints, "WEIGHTS_0" => weights))])]))
    mesh = only(get_children(audit3_scene(doc, buffers))[1].children)
    @test mesh isa SkinnedMesh
    @test mesh.skin_weights == [(0.5, 0.5, 0.0, 0.0), (1.0, 0.0, 0.0, 0.0), (0.25, 0.75, 0.0, 0.0)]
    expected = [(0.0, 0.0, 0.0), (0.7071067811865475, 0.7071067811865476, 0.0),
                (-0.7071067811865476, 0.7071067811865475, 0.0)]
    skinned = apply_skinning(mesh)
    for (p, e) in zip(skinned, expected)
        @test [p.x, p.y, p.z] ≈ collect(e) atol=1e-12
    end
end

function audit3_morph_doc(; channel_node=0, interpolation="LINEAR")
    b = Audit3GLTFBuilder()
    pos = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    target = audit3_accessor!(b, Float32[0, 0, 1, 0, 0, 0, 0, 0, 0], "VEC3")
    times = audit3_accessor!(b, Float32[0, 1], "SCALAR")
    weights = interpolation == "CUBICSPLINE" ?
        audit3_accessor!(b, Float32[0, 0, 0, 0, 1, 0], "SCALAR") :
        audit3_accessor!(b, Float32[0, 1], "SCALAR")
    prim = Dict("attributes" => Dict("POSITION" => pos), "targets" => [Dict("POSITION" => target)])
    return audit3_document(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0])],
        "nodes" => [Dict("name" => "a", "mesh" => 0, "children" => [1]),
                    Dict("name" => "b", "children" => [2]),
                    Dict("name" => "c", "mesh" => 1)],
        "meshes" => [Dict("primitives" => [prim, prim]),
                     Dict("primitives" => [prim], "weights" => [0.25])],
        "animations" => [Dict("samplers" => [Dict("input" => times, "output" => weights,
                                                  "interpolation" => interpolation)],
                              "channels" => [Dict("sampler" => 0, "target" => Dict(
                                  "node" => channel_node, "path" => "weights"))])]))
end

@testset "glTF weights channels drive only the target node's primitives" begin
    # three.js GLTFLoader.js:4586-4607 binds a weights channel to the node and
    # the direct primitive meshes of a multi-primitive node, never to meshes of
    # descendant nodes. three.js r186 AnimationMixer.setTime(0.5) leaves node c
    # at its mesh default weight 0.25 while node a's primitives reach 0.5.
    for interpolation in ("LINEAR", "CUBICSPLINE")
        asset = audit3_asset(audit3_morph_doc(; interpolation)...)
        a = only(get_children(asset.scene))
        prims = [child for child in a.children if child isa Mesh]
        c = only(only(only(filter(child -> child isa Group, a.children)).children).children)
        @test length(prims) == 2 && c isa Mesh
        clip = only(asset.animations)
        @test length(clip.tracks) == 2
        @test all(track -> any(p -> p === track.target, prims), clip.tracks)
        mixer = AnimationMixer(clip)
        mixer_set_time!(mixer, 0.5)
        # LINEAR: 0 -> 1 halfway; CUBICSPLINE with zero tangents: Hermite h01(0.5) = 0.5.
        @test all(p -> p.morph_target_influences ≈ [0.5], prims)
        @test c.morph_target_influences == [0.25]
    end
    # A weights channel on a node without morph-target primitives is malformed
    # (glTF 2.0 animation.channel.target: weights require a mesh with targets).
    @test_throws "has no morph-target primitives" audit3_asset(audit3_morph_doc(; channel_node=1)...)
end

function audit3_face_normals(geo)
    return [Tuple(geo.normals[3i-2:3i]) for i in 1:geo.n_vertices]
end

@testset "glTF primitives without NORMAL get flat normals" begin
    # glTF 2.0 §3.7.2.1: "When normals are not specified, client implementations
    # MUST calculate flat normals". three.js GLTFLoader.js:3500 sets
    # material.flatShading for these primitives; like three.js the TANGENT
    # attribute is still loaded. Fold: triangles (0,1,2) and (0,2,3) lie in z=0, (0,3,4) in x=0.
    b = Audit3GLTFBuilder()
    pos = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1], "VEC3")
    tangent = audit3_accessor!(b, Float32[1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1], "VEC4")
    idx = audit3_accessor!(b, UInt16[0, 1, 2, 0, 2, 3, 0, 3, 4], "SCALAR")
    strip_idx = audit3_accessor!(b, UInt8[1, 2, 0, 3], "SCALAR")
    joints = audit3_accessor!(b, UInt8[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "VEC4")
    weights = audit3_accessor!(b, Float32[1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], "VEC4")
    flat3 = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    doc, buffers = audit3_document(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0, 1, 2])],
        "nodes" => [Dict("mesh" => 0), Dict("mesh" => 1, "skin" => 0), Dict("mesh" => 2)],
        "skins" => [Dict("joints" => [2])],
        "meshes" => [
            Dict("primitives" => [
                Dict("attributes" => Dict("POSITION" => pos, "TANGENT" => tangent), "indices" => idx),
                Dict("attributes" => Dict("POSITION" => pos), "indices" => strip_idx, "mode" => 5)]),
            Dict("primitives" => [Dict("attributes" => Dict(
                "POSITION" => pos, "JOINTS_0" => joints, "WEIGHTS_0" => weights), "indices" => idx)]),
            Dict("primitives" => [Dict("attributes" => Dict("POSITION" => flat3))])]))
    roots = get_children(audit3_scene(doc, buffers))
    folded, strip = roots[1].children
    z = (0.0, 0.0, 1.0)
    x = (1.0, 0.0, 0.0)
    @test folded.geometry.n_vertices == 9 && folded.geometry.n_faces == 3
    @test audit3_face_normals(folded.geometry) == [z, z, z, z, z, z, x, x, x]
    @test [folded.geometry.positions[3i-2:3i] for i in 1:9] ==
          [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 0, 0], [1, 1, 0], [0, 1, 0],
           [0, 0, 0], [0, 1, 0], [0, 0, 1]]
    @test get_attribute(folded.geometry, :tangent).data == repeat([1.0, 0.0, 0.0, 1.0], 9)
    # Strip (1,2,0,3) -> triangles (1,2,0), (3,0,2) (GLTFLoader toTrianglesDrawMode).
    @test strip.geometry.n_faces == 2
    @test audit3_face_normals(strip.geometry) == fill(z, 6)
    skinned = only(roots[2].children)
    @test skinned isa SkinnedMesh && skinned.geometry.n_vertices == 9
    @test length(skinned.skin_indices) == 9 && length(skinned.skin_weights) == 9
    @test audit3_face_normals(skinned.geometry)[7:9] == [x, x, x]
    # Non-indexed triangles already have unshared vertices; their layout is kept.
    plain = only(roots[3].children)
    @test plain.geometry.n_vertices == 3 && plain.geometry.indices == [1, 2, 3]
    @test audit3_face_normals(plain.geometry) == fill(z, 3)
end

@testset "glTF morph influences default to zero per target" begin
    # glTF 2.0 mesh.weights defaults to zeros; three.js GLTFLoader.js:2474-2486
    # (updateMorphTargets) gives every mesh one influence per target. three.js
    # r186 loads [0, 0] without weights, the node weights [0.3, 0.6] over mesh
    # weights, and names the targets from extras.targetNames.
    b = Audit3GLTFBuilder()
    pos = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    up = audit3_accessor!(b, Float32[0, 0, 1, 0, 0, 0, 0, 0, 0], "VEC3")
    side = audit3_accessor!(b, Float32[0, 1, 0, 0, 0, 0, 0, 0, 0], "VEC3")
    prim = Dict("attributes" => Dict("POSITION" => pos),
                "targets" => [Dict("POSITION" => up), Dict("POSITION" => side)])
    doc, buffers = audit3_document(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0, 1])],
        "nodes" => [Dict("mesh" => 0), Dict("mesh" => 1, "weights" => [0.3, 0.6])],
        "meshes" => [Dict("primitives" => [prim, prim], "extras" => Dict("targetNames" => ["up", "side"])),
                     Dict("primitives" => [prim], "weights" => [0.1, 0.2])]))
    first_node, second_node = get_children(audit3_scene(doc, buffers))
    @test all(mesh -> mesh.morph_target_influences == [0.0, 0.0], first_node.children)
    @test all(mesh -> mesh.morph_target_names == ["up", "side"], first_node.children)
    # Each primitive owns its influences, as each three.js Mesh does.
    first_node.children[1].morph_target_influences[1] = 1.0
    @test first_node.children[2].morph_target_influences == [0.0, 0.0]
    @test only(second_node.children).morph_target_influences == [0.3, 0.6]
end

function audit3_quantized_doc(; declare::Bool=true)
    b = Audit3GLTFBuilder()
    # Quantized elements are padded to 4-byte strides (KHR_mesh_quantization README).
    pos_view = audit3_view!(b, collect(reinterpret(UInt8,
        Int16[0, 0, 0, 0, 32767, 0, 0, 0, 0, -32767, 0, 0, 1000, 2000, -3000, 0])); stride=8)
    push!(b.accessors, Dict{String,Any}("bufferView" => pos_view, "componentType" => 5122,
                                        "normalized" => true, "count" => 4, "type" => "VEC3"))
    normal_view = audit3_view!(b, collect(reinterpret(UInt8,
        Int8[0, 0, 127, 0, 0, 0, -127, 0, 127, 0, 0, 0, -128, 0, 0, 0])); stride=4)
    push!(b.accessors, Dict{String,Any}("bufferView" => normal_view, "componentType" => 5120,
                                        "normalized" => true, "count" => 4, "type" => "VEC3"))
    uv = audit3_accessor!(b, UInt16[0, 1, 2, 3, 65535, 7, 9, 10], "VEC2")
    uv1 = audit3_accessor!(b, Int8[-128, 1, 127, 3, 5, -7, 9, 10], "VEC2"; normalized=true)
    tangent = audit3_accessor!(b, Int16[32767, 0, 0, 32767, 0, 32767, 0, -32767,
                                        0, 0, 32767, 32767, 32767, 0, 0, 32767], "VEC4"; normalized=true)
    morph_view = audit3_view!(b, collect(reinterpret(UInt8,
        Int8[1, 2, 3, 0, -4, 5, 6, 0, 7, 8, -9, 0, 10, 11, 12, 0])); stride=4)
    push!(b.accessors, Dict{String,Any}("bufferView" => morph_view, "componentType" => 5120,
                                        "count" => 4, "type" => "VEC3"))
    idx = audit3_accessor!(b, UInt8[0, 1, 2, 0, 2, 3], "SCALAR")
    doc = Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0])], "nodes" => [Dict("mesh" => 0)],
        "meshes" => [Dict("primitives" => [Dict(
            "attributes" => Dict("POSITION" => 0, "NORMAL" => 1, "TEXCOORD_0" => uv,
                                 "TEXCOORD_1" => uv1, "TANGENT" => tangent),
            "indices" => idx, "targets" => [Dict("POSITION" => 5)])])])
    if declare
        doc["extensionsUsed"] = ["KHR_mesh_quantization"]
        doc["extensionsRequired"] = ["KHR_mesh_quantization"]
    end
    return audit3_document(b, doc)
end

@testset "glTF KHR_mesh_quantization attributes" begin
    @test "KHR_mesh_quantization" in Diff3D._GLTF_SUPPORTED_EXTENSIONS
    mesh = only(only(get_children(audit3_scene(audit3_quantized_doc()...))).children)
    geo = mesh.geometry
    # Expected arrays are three.js r186 GLTFLoader BufferAttribute.getComponent
    # output (normalized SHORT/BYTE: max(c / 32767, -1) and max(c / 127, -1)).
    @test geo.positions == [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, -1.0, 0.0,
                            0.030518509475997192, 0.061037018951994385, -0.09155552842799158]
    @test geo.normals == [0.0, 0.0, 1.0, 0.0, 0.0, -1.0, 1.0, 0.0, 0.0, -1.0, 0.0, 0.0]
    @test geo.uvs == [0.0, 1.0, 2.0, 3.0, 65535.0, 7.0, 9.0, 10.0]
    @test get_attribute(geo, :uv2).data ==
          [-1.0, 0.007874015748031496, 1.0, 0.023622047244094488,
           0.03937007874015748, -0.05511811023622047, 0.07086614173228346, 0.07874015748031496]
    @test get_attribute(geo, :tangent).data ==
          [1.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 1.0, 1.0, 1.0, 0.0, 0.0, 1.0]
    @test get_attribute(geo, Diff3D._morph_position_symbol(1)).data ==
          [1.0, 2.0, 3.0, -4.0, 5.0, 6.0, 7.0, 8.0, -9.0, 10.0, 11.0, 12.0]
    # Without the extension the core attribute table still applies (glTF 2.0 §3.7.2.1).
    @test_throws "POSITION accessor componentType/normalized combination is invalid" audit3_scene(
        audit3_quantized_doc(; declare=false)...)
end

function audit3_instanced_doc(colors, type; normalized=true, count_mismatch=false)
    b = Audit3GLTFBuilder()
    pos = audit3_accessor!(b, Float32[0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
    nrm = audit3_accessor!(b, Float32[0, 0, 1, 0, 0, 1, 0, 0, 1], "VEC3")
    translation = audit3_accessor!(b, count_mismatch ? Float32[1, 2, 3] :
                                      Float32[1, 2, 3, -1, 0, 0.5], "VEC3")
    color = audit3_accessor!(b, colors, type; normalized)
    return audit3_document(b, Dict{String,Any}(
        "scene" => 0, "scenes" => [Dict("nodes" => [0])],
        "extensionsUsed" => ["EXT_mesh_gpu_instancing"],
        "nodes" => [Dict("mesh" => 0, "extensions" => Dict("EXT_mesh_gpu_instancing" => Dict(
            "attributes" => Dict("TRANSLATION" => translation, "_COLOR_0" => color))))],
        "meshes" => [Dict("primitives" => [
            Dict("attributes" => Dict("POSITION" => pos, "NORMAL" => nrm)),
            Dict("attributes" => Dict("POSITION" => pos, "NORMAL" => nrm))])]))
end

@testset "glTF EXT_mesh_gpu_instancing _COLOR_0 sets instance colors" begin
    # three.js GLTFLoader.js:1795-1798 copies `_COLOR_0` into
    # InstancedMesh.instanceColor; normalized UNSIGNED_BYTE reads as c / 255.
    scene = audit3_scene(audit3_instanced_doc(UInt8[255, 128, 0, 10, 20, 30], "VEC3")...)
    instanced = only(get_children(scene)).children
    @test length(instanced) == 2 && all(obj -> obj isa InstancedMesh, instanced)
    for inst in instanced
        @test inst.instance_colors == [Color3(1.0, 128 / 255, 0.0), Color3(10 / 255, 20 / 255, 30 / 255)]
        @test inst.instance_matrices[2] == mat4_translation(-1.0, 0.0, 0.5)
    end
    # VEC4 colors use RGB; three.js binds instanceColor as a vec3 attribute.
    rgba = audit3_scene(audit3_instanced_doc(Float32[0.25, 0.5, 0.75, 0.1, 1, 0, 0, 1], "VEC4";
                                             normalized=false)...)
    @test only(get_children(rgba)).children[1].instance_colors ==
          [Color3(0.25, 0.5, 0.75), Color3(1.0, 0.0, 0.0)]
    @test_throws "_COLOR_0 accessor componentType/normalized combination is invalid" audit3_scene(
        audit3_instanced_doc(UInt8[255, 128, 0, 10, 20, 30], "VEC3"; normalized=false)...)
    @test_throws "attribute accessors must have matching counts" audit3_scene(
        audit3_instanced_doc(UInt8[255, 128, 0, 10, 20, 30], "VEC3"; count_mismatch=true)...)
end

function audit3_payload_allocations(out, buf, ctype, stride, normalized)
    Diff3D._gltf_read_accessor_payload!(out, buf, 0, 64, 3, ctype, stride, normalized)
    return @allocated Diff3D._gltf_read_accessor_payload!(out, buf, 0, 64, 3, ctype,
                                                          stride, normalized)
end

@testset "glTF accessor payload decoding" begin
    # glTF 2.0 accessor normalization: unsigned c / (2^b - 1), signed
    # max(c / (2^(b-1) - 1), -1); unnormalized integers convert exactly.
    bytes = UInt8[0x00, 0x80, 0xff, 0x7f, 0x01, 0xfe, 0x00, 0x80]
    for (ctype, T) in ((5120, Int8), (5121, UInt8), (5122, Int16), (5123, UInt16), (5125, UInt32))
        raw = collect(reinterpret(T, bytes))
        for normalized in (false, true)
            expected = normalized ?
                (T <: Signed ? max.(Float64.(raw) ./ typemax(T), -1.0) : Float64.(raw) ./ typemax(T)) :
                Float64.(raw)
            out = zeros(length(raw))
            Diff3D._gltf_read_accessor_payload!(out, bytes, 0, length(raw), 1, ctype,
                                                sizeof(T), normalized)
            @test out == expected
            @test [Diff3D._gltf_read_component(bytes, (i - 1) * sizeof(T), ctype, normalized)
                   for i in eachindex(raw)] == expected
        end
    end
    floats = Float32[1.5, -0.25, 3.0e38, -1.0f-40]
    float_bytes = collect(reinterpret(UInt8, floats))
    out = zeros(4)
    Diff3D._gltf_read_accessor_payload!(out, float_bytes, 0, 4, 1, 5126, 4, false)
    @test out == Float64.(floats)
    # Strided reads with an output offset (the sparse-substitution form).
    out = fill(-7.0, 5)
    Diff3D._gltf_read_accessor_payload!(out, UInt8[1, 2, 9, 3, 4, 9], 0, 2, 2, 5121, 3, false,
                                        nothing, 1)
    @test out == [-7.0, 1.0, 2.0, 3.0, 4.0]
    # Non-finite FLOAT values and out-of-range payloads are rejected.
    inf_bytes = collect(reinterpret(UInt8, Float32[0, Inf32]))
    @test_throws "glTF FLOAT accessor value at byte offset 4 must be finite" Diff3D._gltf_read_accessor_payload!(
        zeros(2), inf_bytes, 0, 2, 1, 5126, 4, false)
    @test_throws "exceeds buffer length 8" Diff3D._gltf_read_accessor_payload!(
        zeros(3), inf_bytes, 0, 3, 1, 5126, 4, false)
    @test_throws BoundsError Diff3D._gltf_read_accessor_payload!(
        zeros(1), inf_bytes, 0, 2, 1, 5126, 4, false)
    @test_throws "byte span is outside the supported integer range" Diff3D._gltf_read_accessor_payload!(
        zeros(3), inf_bytes, 0, 3, 1, 5126, typemax(Int), false)
    if Base.JLOptions().opt_level > 0
        # Decoding into a preallocated output must not allocate per component.
        buffer = rand(UInt8, 64 * 16)
        for (ctype, normalized) in ((5126, false), (5121, true), (5122, true), (5125, false))
            if ctype == 5126
                buffer = collect(reinterpret(UInt8, rand(Float32, 64 * 4)))
            end
            @test audit3_payload_allocations(zeros(192), buffer, ctype, 16, normalized) == 0
        end
    end
end

audit3_byte_vector(n) = Vector{UInt8}(undef, n)
function audit3_byte_vector_allocations(n)
    audit3_byte_vector(n)
    return @allocated audit3_byte_vector(n)
end

function audit3_base64_allocations(text)
    Diff3D._gltf_base64_decode_strict(text)
    return @allocated Diff3D._gltf_base64_decode_strict(text)
end

@testset "glTF data URI base64 decoding" begin
    # RFC 4648 §4 base64: compare against Base64.base64decode, including
    # whitespace that interrupts quads and both padding forms.
    for n in (0, 1, 2, 3, 4, 5, 47, 48, 49, 1000)
        bytes = UInt8[(37 * i + 11) % 256 for i in 1:n]
        text = Base64.base64encode(bytes)
        @test Diff3D._gltf_base64_decode_strict(text) == bytes
        wrapped = join([text[i:min(i + 6, end)] for i in 1:7:length(text)], "\n ")
        @test Diff3D._gltf_base64_decode_strict(wrapped) == bytes
        @test Diff3D._gltf_base64_decode_strict(SubString("x" * text, 2)) == bytes
    end
    @test_throws "base64 contains invalid character" Diff3D._gltf_base64_decode_strict("QUJD*EVG")
    @test_throws "base64 contains invalid character" Diff3D._gltf_base64_decode_strict("QUJDRÉVG")
    @test_throws "base64 has data after padding" Diff3D._gltf_base64_decode_strict("QQ==QUJD")
    @test_throws "base64 has data after padding" Diff3D._gltf_base64_decode_strict("QUE=RUZH")
    @test_throws "base64 has invalid padding" Diff3D._gltf_base64_decode_strict("Q===")
    @test_throws "base64 has non-zero padding bits" Diff3D._gltf_base64_decode_strict("QR==")
    @test_throws "base64 length is not a multiple of 4" Diff3D._gltf_base64_decode_strict("QUJDR")
    if Base.JLOptions().opt_level > 0
        # Only the decoded byte vector is allocated.
        text = Base64.base64encode(UInt8[i % 256 for i in 1:30_000])
        output_bytes = audit3_byte_vector_allocations(30_000)
        @test audit3_base64_allocations(text) <= output_bytes + 256
    end
end
