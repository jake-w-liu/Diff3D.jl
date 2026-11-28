using Test, Diff3D

# Oracle: three.js r186. Files written by Diff3D.save_gltf/save_glb were parsed
# with examples/jsm/loaders/GLTFLoader.js under Node (createImageBitmap
# polyfilled with an 8-bit PNG decoder); the numbers marked "three.js" below
# are what that loader reported. GLTFExporter.js (examples/jsm/exporters) was
# run on the equivalent three.js scene for the morph track merge.

_a3c_px(k) = k / 255

function _a3c_image(C)
    img = Array{Float64}(undef, 2, 3, 4)
    for i in 1:2, j in 1:3, c in 1:4
        img[i, j, c] = _a3c_px(mod(17 * i + 31 * j + 7 * c, 256))
    end
    return img[:, :, 1:C]
end

function _a3c_find(root, name)
    found = Any[]
    traverse(root, o -> o.name == name && push!(found, o))
    return only(found)
end

_a3c_vec(v) = [v.x, v.y, v.z]

function _a3c_all(root, T)
    found = Any[]
    traverse(root, o -> o isa T && push!(found, o))
    return found
end

# The scene the three.js oracle numbers were taken from.
function _a3c_scene()
    tex_map = Texture(_a3c_image(4); wrap_s=:clamp, wrap_t=:mirror, filter=:nearest,
                      min_filter=:nearest_mipmap_linear, offset=Vec2(0.25, 0.5),
                      repeat=Vec2(2.0, 2.0), rotation=0.5)
    tex_mr = Texture(_a3c_image(3); colorspace=:linear)
    tex_n = Texture(_a3c_image(3); colorspace=:linear, tex_coord=1)
    tex_ao = Texture(_a3c_image(1); colorspace=:linear)
    tex_e = Texture(_a3c_image(3))
    tex_cc = Texture(_a3c_image(1); colorspace=:linear, repeat=Vec2(3.0, 1.5))
    phys = MeshPhysicalMaterial(color=Color3(0.5, 0.25, 1.0), metalness=0.3, roughness=0.7,
        map=tex_map, normal_map=tex_n, normal_scale=0.5, roughness_map=tex_mr,
        metalness_map=tex_mr, ao_map=tex_ao, ao_map_intensity=0.75,
        emissive=Color3(0.1, 0.2, 0.3), emissive_map=tex_e, emissive_intensity=2.0,
        clearcoat=0.6, clearcoat_roughness=0.2, clearcoat_map=tex_cc,
        clearcoat_normal_map=tex_n, clearcoat_normal_scale=0.8, transmission=0.4,
        thickness=1.5, attenuation_distance=2.5, attenuation_color=Color3(0.9, 0.8, 0.7),
        ior=1.7, sheen=0.5, sheen_color=Color3(1.0, 0.5, 0.25), sheen_roughness=0.3,
        iridescence=0.9, iridescence_ior=1.4, iridescence_thickness=500.0,
        iridescence_thickness_min=120.0, specular_intensity=0.6,
        specular_color=Color3(1.0, 0.9, 0.8), dispersion=0.25, anisotropy=0.35,
        anisotropy_rotation=0.75, side=:double)
    scene = Scene()
    geo = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0],
                         [0.0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
                         [0.0, 0, 1, 0, 0, 1, 1, 1], [1, 2, 3, 2, 4, 3], 4, 2)
    set_attribute!(geo, :uv2, [0.0, 0, 1, 0, 0, 1, 1, 1], 2)
    set_attribute!(geo, :temperature, [1.0, 2.0, 3.0, 4.0], 1)
    set_attribute!(geo, :morphPosition0, repeat([0.0, 0, 1], 4), 3)
    set_attribute!(geo, :morphPosition1, repeat([0.0, 1, 0], 4), 3)
    quad = Mesh(geo, phys; name="quad", morph_target_influences=[0.0, 0.0],
                morph_target_names=["up", "side"])
    add!(scene, quad)
    g2 = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 2, 0, 0, 2, 1, 0],
                        Float64[], Float64[], [1, 2, 3, 2, 4, 3, 2, 5, 4, 5, 6, 4], 6, 4)
    set_draw_range!(g2, 4, 6)
    ranged = Mesh(g2, MeshStandardMaterial(); name="ranged")
    ranged.position = Vec3(0.0, 3.0, 0.0)
    add!(scene, ranged)
    cam = PerspectiveCamera(fov=0.8, aspect=1.5, near=0.2, far=50.0, zoom=2.0, name="cam")
    cam.position = Vec3(1.0, 2.0, 3.0)
    cam.target = Vec3(0.0, 0.0, 0.0)
    add!(scene, cam)
    ortho = OrthographicCamera(left=-2.0, right=2.0, bottom=-1.0, top=1.0, near=0.5,
                               far=20.0, name="ortho", rotation_driven=true)
    ortho.rotation = Euler(0.1, 0.2, 0.0, :XYZ)
    add!(scene, ortho)
    sun = DirectionalLight(color=Color3(1.0, 0.9, 0.8), intensity=3.0, name="sun")
    sun.position = Vec3(0.0, 5.0, 5.0)
    add!(scene, sun)
    bulb = PointLight(color=Color3(0.2, 0.4, 0.6), intensity=5.0, distance=10.0, name="bulb")
    bulb.position = Vec3(1.0, 1.0, 1.0)
    add!(scene, bulb)
    spot = SpotLight(intensity=7.0, distance=0.0, angle=0.6, penumbra=0.25, name="spot",
                     target=Vec3(1.0, 0.0, 0.0))
    spot.position = Vec3(0.0, 4.0, 0.0)
    add!(scene, spot)
    root = Bone(name="root"); tip = Bone(name="tip")
    tip.position = Vec3(0.0, 1.0, 0.0)
    add!(root, tip)
    rig = Group(name="rig")
    add!(rig, root)
    sgeo = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0], Float64[], Float64[],
                          [1, 2, 3, 2, 4, 3], 4, 2)
    compute_vertex_normals!(sgeo)
    sm = SkinnedMesh(sgeo, MeshStandardMaterial(color=Color3(0.8, 0.8, 0.8)),
                     Skeleton([root, tip]),
                     [(1, 2, 1, 1), (1, 2, 1, 1), (2, 1, 1, 1), (2, 1, 1, 1)],
                     [(1.0, 0.0, 0.0, 0.0), (0.75, 0.25, 0.0, 0.0), (0.5, 0.5, 0.0, 0.0),
                      (0.0, 1.0, 0.0, 0.0)]; name="skinned")
    add!(rig, sm)
    add!(scene, rig)
    tip.rotation = Euler(0.0, 0.0, 0.3, :XYZ)
    mats = [mat4_translation(Float64(i), 0.0, 0.0) *
            quat_to_mat4(quat_from_euler(0.0, 0.1i, 0.0; order=:XYZ)) *
            mat4_scaling(1.0, 2.0, 1.0) for i in 1:3]
    inst = InstancedMesh(BoxGeometry(), MeshStandardMaterial(), mats; name="inst")
    set_instance_color!(inst, 2, Color3(1.0, 0.0, 0.0))
    inst.position = Vec3(0.0, -3.0, 0.0)
    add!(scene, inst)
    clip = AnimationClip("anim", Diff3D.AbstractKeyframeTrack[
        NumberKeyframeTrack(quad, :morph_target_influences, 1, [0.0, 1.0], [0.0, 1.0], :linear),
        NumberKeyframeTrack(quad, :morph_target_influences, 2, [0.5, 2.0], [1.0, 0.0], :linear),
        QuaternionKeyframeTrack(tip, :rotation, [0.0, 1.0],
                                [Quaternion(0.0, 0, 0, 1),
                                 Quaternion(0.0, 0, 0.7071067811865476, 0.7071067811865476)])])
    return (; scene, clip, tex_map, tex_mr, tex_n, tex_ao, tex_cc, mats)
end

# (JSON document, BIN bytes) of a .gltf or .glb file, checking the GLB
# container layout (glTF 2.0 §4.4): header, 4-byte aligned chunks, JSON padded
# with spaces, BIN with zeros.
function _a3c_read(path)
    bytes = read(path)
    if endswith(path, ".glb")
        u32(o) = Int(ltoh(reinterpret(UInt32, bytes[o + 1:o + 4])[1]))
        @test u32(0) == 0x46546C67 && u32(4) == 2 && u32(8) == length(bytes)
        jlen = u32(12)
        @test u32(16) == 0x4E4F534A && jlen % 4 == 0
        json = bytes[21:20 + jlen]
        @test all(b -> b != 0x00, json)
        bin = UInt8[]
        if 20 + jlen < length(bytes)
            blen = u32(20 + jlen)
            @test u32(24 + jlen) == 0x004E4942 && blen % 4 == 0
            @test 28 + jlen + blen == length(bytes)
            bin = bytes[29 + jlen:28 + jlen + blen]
        end
        doc = Diff3D._json_parse(json)
        return doc, bin
    end
    doc = Diff3D._json_parse(String(bytes))
    uri = doc["buffers"][1]["uri"]
    prefix = "data:application/octet-stream;base64,"
    @test startswith(uri, prefix)
    return doc, Diff3D.base64_decode(uri[length(prefix) + 1:end])
end

# Structural checks a glTF validator makes on what save_gltf writes:
# accessor/bufferView bounds and alignment, component types, targets, the
# required POSITION and animation-input min/max, and index references.
function _a3c_validate(doc, bin)
    @test doc["asset"]["version"] == "2.0"
    @test doc["buffers"][1]["byteLength"] == length(bin)
    @test length(bin) % 4 == 0
    views = doc["bufferViews"]
    for v in views
        @test v["buffer"] == 0
        @test v["byteOffset"] % 4 == 0
        @test v["byteOffset"] + v["byteLength"] <= length(bin)
    end
    sizes = Dict(5120 => 1, 5121 => 1, 5122 => 2, 5123 => 2, 5125 => 4, 5126 => 4)
    ncomp = Dict("SCALAR" => 1, "VEC2" => 2, "VEC3" => 3, "VEC4" => 4, "MAT4" => 16)
    accs = doc["accessors"]
    for a in accs
        @test haskey(sizes, a["componentType"])
        v = views[Int(a["bufferView"]) + 1]
        @test get(a, "byteOffset", 0) + a["count"] * ncomp[a["type"]] * sizes[a["componentType"]] <=
              v["byteLength"]
    end
    target(i) = get(views[Int(accs[Int(i) + 1]["bufferView"]) + 1], "target", nothing)
    for mesh in doc["meshes"], prim in mesh["primitives"]
        for (name, i) in prim["attributes"]
            @test target(i) == 34962
            name == "POSITION" && @test haskey(accs[Int(i) + 1], "min") && haskey(accs[Int(i) + 1], "max")
            name == "JOINTS_0" && @test accs[Int(i) + 1]["componentType"] in (5121, 5123)
            name == "WEIGHTS_0" && @test accs[Int(i) + 1]["componentType"] == 5126
        end
        if haskey(prim, "indices")
            @test target(prim["indices"]) == 34963
            @test accs[Int(prim["indices"]) + 1]["componentType"] in (5121, 5123, 5125)
        end
        for t in get(prim, "targets", Any[]), (name, i) in t
            name == "POSITION" && @test haskey(accs[Int(i) + 1], "min")
        end
        @test prim["material"] < length(doc["materials"])
    end
    for anim in get(doc, "animations", Any[]), s in anim["samplers"]
        @test haskey(accs[Int(s["input"]) + 1], "min") && haskey(accs[Int(s["input"]) + 1], "max")
        @test target(s["input"]) === nothing && target(s["output"]) === nothing
    end
    for skin in get(doc, "skins", Any[])
        a = accs[Int(skin["inverseBindMatrices"]) + 1]
        @test a["type"] == "MAT4" && a["count"] == length(skin["joints"])
        @test target(skin["inverseBindMatrices"]) === nothing
    end
    for img in get(doc, "images", Any[])
        @test img["mimeType"] == "image/png"
        haskey(img, "bufferView") && @test !haskey(views[Int(img["bufferView"]) + 1], "target")
    end
    for t in get(doc, "textures", Any[])
        @test t["source"] < length(doc["images"]) && t["sampler"] < length(doc["samplers"])
    end
    for name in get(doc, "extensionsRequired", Any[])
        @test name in doc["extensionsUsed"]
    end
    return doc
end

@testset "save_gltf completes GLTFExporter.js coverage" begin
    mktempdir() do dir
        s = _a3c_scene()
        gltf_path = save_gltf(joinpath(dir, "demo.gltf"), s.scene; animations=[s.clip])
        glb_path = Diff3D.save_glb(joinpath(dir, "demo.glb"), s.scene; animations=[s.clip])
        @test glb_path == joinpath(dir, "demo.glb")
        doc_gltf = _a3c_validate(_a3c_read(gltf_path)...)
        doc_glb = _a3c_validate(_a3c_read(glb_path)...)
        @test !haskey(doc_gltf["images"][1], "bufferView") &&
              startswith(doc_gltf["images"][1]["uri"], "data:image/png;base64,")
        @test haskey(doc_glb["images"][1], "bufferView")
        @test doc_glb["extensionsRequired"] == ["EXT_mesh_gpu_instancing"]
        @test Set(doc_glb["extensionsUsed"]) == Set([
            "KHR_texture_transform", "KHR_materials_emissive_strength",
            "KHR_materials_clearcoat", "KHR_materials_dispersion", "KHR_materials_iridescence",
            "KHR_materials_transmission", "KHR_materials_volume", "KHR_materials_ior",
            "KHR_materials_specular", "KHR_materials_sheen", "KHR_materials_anisotropy",
            "KHR_lights_punctual", "EXT_mesh_gpu_instancing"])
        # glTF xmag/ymag are half extents (GLTFLoader.js loadCamera builds
        # left = -xmag); GLTFExporter.js:2268 writes right * 2 = 4 instead.
        ortho_def = only(c for c in doc_glb["cameras"] if c["type"] == "orthographic")
        @test ortho_def["orthographic"]["xmag"] == 2.0 && ortho_def["orthographic"]["ymag"] == 1.0

        for path in (gltf_path, glb_path)
            a = endswith(path, ".glb") ? load_glb_asset(path; custom_attributes=true) :
                load_gltf_asset(path; custom_attributes=true)
            scene = a.scene
            quad = only(_a3c_find(scene, "quad").children)
            m = quad.material
            @test m isa MeshPhysicalMaterial
            # three.js: sheenColor [0.5, 0.25, 0.125] with sheen 1, i.e. the
            # rendered sheen_color * sheen of the source material.
            @test m.sheen == 1.0 && m.sheen_color == Color3(0.5, 0.25, 0.125)
            @test (m.clearcoat, m.clearcoat_roughness, m.transmission, m.thickness) ==
                  (0.6, 0.2, 0.4, 1.5)
            @test (m.attenuation_distance, m.ior, m.sheen_roughness, m.dispersion) ==
                  (2.5, 1.7, 0.3, 0.25)
            @test (m.iridescence, m.iridescence_ior, m.iridescence_thickness_min,
                   m.iridescence_thickness) == (0.9, 1.4, 120.0, 500.0)
            @test (m.specular_intensity, m.specular_color) == (0.6, Color3(1.0, 0.9, 0.8))
            @test (m.anisotropy, m.anisotropy_rotation) == (0.35, 0.75)
            @test (m.emissive_intensity, m.ao_map_intensity, m.normal_scale,
                   m.clearcoat_normal_scale, m.side) == (2.0, 0.75, 0.5, 0.8, :double)
            # Texels survive exactly (k/255), rows in Diff3D order; three.js
            # reported the first PNG pixel of map as [72, 79, 86, 93], which is
            # Diff3D row 2 (the bottom row, UV v = 0).
            @test m.map.data == s.tex_map.data
            @test round.(Int, m.map.data[2, 1, :] .* 255) == [72, 79, 86, 93]
            @test m.ao_map.data == s.tex_ao.data && m.normal_map.data == s.tex_n.data
            @test m.roughness_map === m.metalness_map && m.roughness_map.data == s.tex_mr.data
            @test m.clearcoat_map.data == s.tex_cc.data
            # three.js: wrapS 1001 (clamp), wrapT 1002 (mirror), magFilter
            # 1003 (nearest), minFilter 1005 (nearest-mipmap-linear); offset
            # [0.25, 0.5], repeat [2, 2], rotation 0.5; normalMap channel 1.
            @test (m.map.wrap_s, m.map.wrap_t, m.map.filter, m.map.min_filter) ==
                  (:clamp, :mirror, :nearest, :nearest_mipmap_linear)
            @test m.map.matrix == s.tex_map.matrix
            @test m.normal_map.tex_coord == 1 && m.clearcoat_normal_map.tex_coord == 1
            @test m.clearcoat_map.matrix == s.tex_cc.matrix
            @test m.map.colorspace === :srgb && m.emissive_map.colorspace === :srgb
            # Custom attribute: three.js geometry.attributes._temperature = [1, 2, 3, 4].
            @test get_attribute(quad.geometry, :_temperature).data == [1.0, 2.0, 3.0, 4.0]
            @test get_attribute(quad.geometry, :uv2).data == [0.0, 0, 1, 0, 0, 1, 1, 1]
            # Draw range 4:9 of the index buffer: three.js index [1, 3, 2, 1, 4, 3].
            ranged = only(_a3c_find(scene, "ranged").children)
            # Without normals the loader de-indexes the triangles (flat normals).
            @test ranged.geometry.positions ==
                  [1.0, 0, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 2, 0, 0, 1, 1, 0]
            # Camera: three.js fov 23.87279510333686° (zoom 2 folded in) and
            # quaternion [-0.27465674831720593, 0.15385645171776968,
            # 0.04457065446637164, 0.9481061752931873].
            cam = _a3c_find(scene, "cam")
            @test rad2deg(cam.fov) ≈ 23.87279510333686 atol = 1e-10
            q = quat_from_euler(cam.rotation.x, cam.rotation.y, cam.rotation.z;
                                order=cam.rotation.order)
            @test [q.x, q.y, q.z, q.w] ≈ [-0.27465674831720593, 0.15385645171776968,
                                          0.04457065446637164, 0.9481061752931873] atol = 1e-7
            ortho = _a3c_find(scene, "ortho")
            @test (ortho.left, ortho.right, ortho.bottom, ortho.top) == (-2.0, 2.0, -1.0, 1.0)
            # Lights: three.js world directions.
            @test _a3c_vec(Diff3D._light_emission_direction(_a3c_find(scene, "sun"))) ≈
                  [0.0, -0.7071067811865476, -0.7071067811865476] atol = 1e-7
            spot = _a3c_find(scene, "spot")
            @test _a3c_vec(Diff3D._light_emission_direction(spot)) ≈
                  [0.24253562503633297, -0.9701425001453319, 0.0] atol = 1e-7
            @test (spot.angle, spot.penumbra, spot.intensity, spot.distance) ==
                  (0.6, 0.25, 7.0, 0.0)
            bulb = _a3c_find(scene, "bulb")
            @test (bulb.color, bulb.intensity, bulb.distance, bulb.decay) ==
                  (Color3(0.2, 0.4, 0.6), 5.0, 10.0, 2.0)
            # Skin: three.js bones [root, tip], boneInverses[2] translation
            # (0, -1, 0), skinIndex [0, 1, 0, 0, ...], skinWeight [1, 0, 0, 0, 0.75, ...].
            sm = only(_a3c_all(scene, SkinnedMesh))
            @test [b.name for b in sm.skeleton.bones] == ["root", "tip"]
            @test collect(sm.skeleton.bind_inverses[2].e[13:15]) == [0.0, -1.0, 0.0]
            @test sm.skin_indices[1] == (1, 2, 1, 1) && sm.skin_weights[2] == (0.75, 0.25, 0.0, 0.0)
            # Instances: three.js instanceMatrix of instance 1 is
            # [0.9950041770935059, 0, -0.0998334139585495, 0, 0, 2, 0, 0,
            #  0.0998334139585495, 0, 0.9950041770935059, 0, 1, 0, 0, 1];
            # instanceColor [1, 1, 1, 1, 0, 0, 1, 1, 1].
            inst = only(_a3c_all(scene, InstancedMesh))
            @test collect(inst.instance_matrices[1].e) ≈
                  [0.9950041770935059, 0, -0.0998334139585495, 0, 0, 2, 0, 0,
                   0.0998334139585495, 0, 0.9950041770935059, 0, 1, 0, 0, 1] atol = 1e-7
            for i in 1:3
                @test maximum(abs.(inst.instance_matrices[i].e .- s.mats[i].e)) < 1e-7
            end
            @test inst.instance_colors == [Color3(1.0, 1.0, 1.0), Color3(1.0, 0.0, 0.0),
                                           Color3(1.0, 1.0, 1.0)]
            # Morph tracks merged as GLTFExporter.js mergeMorphTargetTracks:
            # three.js times [0, 0.5, 1, 2], values
            # [0, 1, 0.5, 1, 1, 0.6666666865348816, 1, 0] (also what the
            # three.js exporter itself wrote for the same tracks).
            tracks = a.animations[1].tracks
            mw = only(t for t in tracks if t isa MorphWeightsKeyframeTrack)
            @test mw.times == [0.0, 0.5, 1.0, 2.0]
            @test reduce(vcat, mw.values) ≈ [0, 1, 0.5, 1, 1, 0.6666666865348816, 1, 0] atol = 1e-7
            @test any(t -> t isa QuaternionKeyframeTrack && t.target.name == "tip", tracks)
        end
        # Custom attributes stay opt-in: the default load ignores them as before.
        quad = only(_a3c_find(load_glb(glb_path), "quad").children)
        @test !haskey(quad.geometry.attributes, :_temperature)
    end
end

@testset "save_gltf texture details" begin
    mktempdir() do dir
        tri() = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0], [0.0, 0, 1, 0, 0, 1, 0, 0, 1],
                               [0.0, 0, 1, 0, 0, 1], Int[], 3, 1)
        out = joinpath(dir, "t.glb")
        # Different roughness and metalness maps are merged as GLTFExporter.js
        # buildMetalRoughTextureAsync: R = 0, G = roughness, B = metalness.
        rough = Texture(_a3c_image(1); colorspace=:linear)
        metal = Texture(_a3c_image(1)[end:-1:1, :, :]; colorspace=:linear)
        save_gltf(out, Mesh(tri(), MeshStandardMaterial(roughness_map=rough, metalness_map=metal)))
        m = only(only(load_glb(out).children).children).material
        @test m.roughness_map === m.metalness_map
        @test m.roughness_map.data[:, :, 1] == zeros(2, 3)
        @test m.roughness_map.data[:, :, 2] == rough.data[:, :, 1]
        @test m.roughness_map.data[:, :, 3] == metal.data[:, :, 1]
        save_gltf(out, Mesh(tri(), MeshStandardMaterial(metalness_map=metal)))
        m = only(only(load_glb(out).children).children).material
        @test m.roughness_map.data[:, :, 2] == ones(2, 3)
        @test m.metalness_map.data[:, :, 3] == metal.data[:, :, 1]
        @test_throws "must have the same size" save_gltf(out, Mesh(tri(), MeshStandardMaterial(
            roughness_map=rough, metalness_map=Texture(ones(3, 3, 1); colorspace=:linear))))

        # A manual UV matrix in glTF's offset * rotation * scale form is
        # decomposed exactly; a centred automatic transform likewise.
        θ, sx, sy = 0.3, 2.0, 0.5
        M = Mat3((sx * cos(θ), sy * sin(θ), 0.1, -sx * sin(θ), sy * cos(θ), 0.2, 0.0, 0.0, 1.0))
        manual = Texture(_a3c_image(3); matrix=M, matrix_auto_update=false)
        centred = Texture(_a3c_image(3); repeat=Vec2(2.0, 3.0), center=Vec2(0.5, 0.5))
        for tex in (manual, centred)
            save_gltf(out, Mesh(tri(), MeshBasicMaterial(map=tex)))
            m = only(only(load_glb(out).children).children).material
            @test m isa MeshBasicMaterial
            @test collect(m.map.matrix.e) ≈ collect(tex.matrix.e) atol = 1e-12
        end
        # Unequal repeats under rotation (three.js S * R) have no
        # KHR_texture_transform form (rotation * scale); GLTFExporter.js writes
        # the raw fields, which glTF readers apply in the other order.
        skew = Texture(_a3c_image(3); repeat=Vec2(2.0, 1.0), rotation=0.4, center=Vec2(0.5, 0.0))
        @test_throws "sheared UV matrix" save_gltf(out, Mesh(tri(), MeshBasicMaterial(map=skew)))
        @test_throws "must use colorspace :srgb" save_gltf(out, Mesh(tri(), MeshBasicMaterial(
            map=Texture(_a3c_image(3); colorspace=:linear))))
        @test_throws "cannot be stored as an 8-bit PNG" save_gltf(out, Mesh(tri(),
            MeshBasicMaterial(map=Texture(fill(2.0, 2, 2, 3)))))
        @test_throws "glTF stores one magnification filter" save_gltf(out, Mesh(tri(),
            MeshBasicMaterial(map=Texture(_a3c_image(3); filter=:nearest, mag_filter=:linear))))
        # One image per pixel array, one texture per Texture.
        shared = Texture(_a3c_image(3))
        save_gltf(out, Mesh(tri(), MeshStandardMaterial(map=shared, emissive_map=shared,
                                                        emissive=Color3(1.0, 1.0, 1.0))))
        doc, _ = _a3c_read(out)
        @test length(doc["images"]) == 1 && length(doc["textures"]) == 1
    end
end

@testset "save_gltf reports what glTF cannot hold" begin
    mktempdir() do dir
        out = joinpath(dir, "x.gltf")
        tri() = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0], Float64[], Float64[], Int[], 3, 1)
        scene() = Scene()
        @test_throws "light decay 1.0 cannot be exported" save_gltf(out, PointLight(decay=1.0))
        @test_throws "outside glTF's (0, π/2]" save_gltf(out, SpotLight(angle=2.0))
        @test_throws "film_offset cannot be exported" save_gltf(
            out, PerspectiveCamera(film_offset=0.5, rotation_driven=true))
        @test_throws "must be symmetric" save_gltf(out, OrthographicCamera(
            left=-1.0, right=2.0, rotation_driven=true))
        b1 = Bone(name="a"); b2 = Bone(name="b")
        add!(b1, b2)
        g = Group()
        add!(g, b1)
        sm = SkinnedMesh(tri(), MeshStandardMaterial(), Skeleton([b1, b2]),
                         fill((1, 1, 1, 1), 3), fill((1.0, 0.0, 0.0, 0.0), 3); bind_mode=:detached)
        add!(g, sm)
        @test_throws "detached skinned meshes cannot be exported" save_gltf(out, g)
        sm2 = SkinnedMesh(tri(), MeshStandardMaterial(), Skeleton([b1, b2]),
                          fill((1, 1, 1, 1), 3), fill((1.0, 0.0, 0.0, 0.0), 3))
        @test_throws "is not exported" save_gltf(out, sm2)
        shear = Mat4((1.0, 0.0, 0.0, 0.0, 0.5, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0))
        @test_throws "sheared axes" save_gltf(out, InstancedMesh(BoxGeometry(),
                                                                 MeshStandardMaterial(), [shear]))
        q = Mesh(tri(), MeshStandardMaterial())
        @test_throws "smooth (:cubic) morph influence tracks" save_gltf(out, q; animations=[
            AnimationClip("c", Diff3D.AbstractKeyframeTrack[
                NumberKeyframeTrack(q, :morph_target_influences, 1, [0.0, 1.0], [0.0, 1.0], :cubic)])])
        @test_throws "NumberKeyframeTrack property :opacity cannot be exported" save_gltf(
            out, q; animations=[AnimationClip("c", Diff3D.AbstractKeyframeTrack[
                NumberKeyframeTrack(q, :opacity, 1, [0.0, 1.0], [0.0, 1.0], :linear)])])
        @test_throws "animates the translation of one object twice" save_gltf(out, q; animations=[
            AnimationClip("c", Diff3D.AbstractKeyframeTrack[
                KeyframeTrack(q, :position, [0.0, 1.0], [Vec3(0.0, 0, 0), Vec3(1.0, 0, 0)]),
                KeyframeTrack(q, :position, [0.0, 1.0], [Vec3(0.0, 0, 0), Vec3(2.0, 0, 0)])])])
        g2 = tri()
        set_attribute!(g2, :joints_1, zeros(12), 4)
        @test_throws "glTF semantic JOINTS_1" save_gltf(out, Mesh(g2, MeshStandardMaterial()))
        g3 = tri()
        set_draw_range!(g3, 2, 1)
        @test_throws "draw range selects nothing" save_gltf(out, Mesh(g3, MeshStandardMaterial()))
        @test !isfile(out)
    end
end

# A KTX2 file with one RGBA8 (vkFormat 37) level, as test/suite.jl builds
# them, whose level data is `payload` with supercompression `scheme`.
function _a3c_ktx2(width, height, payload, uncompressed_len; scheme=0, vkformat=37)
    le32(x) = UInt8[x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff]
    le64(x) = vcat(le32(x & 0xffffffff), le32((x >> 32) & 0xffffffff))
    buf = UInt8[0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]
    for v in (vkformat, 1, width, height, 0, 0, 1, 1, scheme)
        append!(buf, le32(v))
    end
    for v in (0, 0, 0, 0)                      # dfd and kvd offset/length
        append!(buf, le32(v))
    end
    append!(buf, le64(0)); append!(buf, le64(0))
    append!(buf, le64(104)); append!(buf, le64(length(payload))); append!(buf, le64(uncompressed_len))
    return append!(buf, payload)
end

@testset "KTX2 ZLIB supercompression" begin
    # KTX 2.0 supercompressionScheme 3 is ZLIB (RFC 1950). The stream is
    # zlib.compress(bytes(0:23 mapped by (17i + 5) % 256), 9) from CPython.
    raw = UInt8[(17i + 5) % 256 for i in 0:23]
    z = UInt8[120, 218, 99, 21, 83, 183, 240, 140, 202, 174, 233, 157, 183, 254, 192, 197, 71,
              159, 89, 68, 213, 204, 61, 34, 179, 170, 123, 0, 113, 176, 9, 205]
    plain = Diff3D._decode_ktx2(_a3c_ktx2(3, 2, raw, 24))
    packed = Diff3D._decode_ktx2(_a3c_ktx2(3, 2, z, 24; scheme=3))
    @test packed == plain
    @test size(packed) == (2, 3, 4)
    @test round.(Int, packed[1, 1, :] .* 255) == [5, 22, 39, 56]
    @test round.(Int, packed[2, 3, :] .* 255) == [89, 106, 123, 140]
    mktempdir() do dir
        path = joinpath(dir, "z.ktx2")
        write(path, _a3c_ktx2(3, 2, z, 24; scheme=3))
        @test load_ktx2(path) == plain
    end
    bad = copy(z); bad[end] ⊻= 0x01
    @test_throws "KTX2 ZLIB level 0 data is invalid: zlib Adler-32 checksum mismatch" Diff3D._decode_ktx2(
        _a3c_ktx2(3, 2, bad, 24; scheme=3))
    @test_throws "uncompressedByteLength 20 does not match" Diff3D._decode_ktx2(
        _a3c_ktx2(3, 2, z, 20; scheme=3))
    @test_throws "KTX2 ZLIB level 0 data is invalid" Diff3D._decode_ktx2(
        _a3c_ktx2(3, 2, z[1:20], 24; scheme=3))
    # A stream that inflates past the declared size is cut off, not allocated.
    @test_throws "KTX2 ZLIB level 0 data is invalid" Diff3D._decode_ktx2(
        _a3c_ktx2(2, 2, z, 16; scheme=3))
    # Dimensions beyond DEFLATE's 1032:1 expansion of the file are rejected
    # before any allocation.
    @test_throws "exceed the" Diff3D._decode_ktx2(_a3c_ktx2(60000, 60000, z, 0; scheme=3))
    @test_throws "scheme 2 (Zstandard) is not supported" Diff3D._decode_ktx2(
        _a3c_ktx2(3, 2, z, 24; scheme=2))
    @test_throws "scheme 1 (BasisLZ) is not supported" Diff3D._decode_ktx2(
        _a3c_ktx2(3, 2, z, 24; scheme=1))
    @test_throws "scheme 7 is not supported" Diff3D._decode_ktx2(_a3c_ktx2(3, 2, z, 24; scheme=7))
    # Random corruptions of the ZLIB file fail with an error, never a crash.
    good = _a3c_ktx2(3, 2, z, 24; scheme=3)
    rng_state = UInt32(12345)
    for trial in 1:300
        f = copy(good)
        for _ in 1:3
            rng_state = rng_state * UInt32(1664525) + UInt32(1013904223)
            k = 105 + Int(rng_state % UInt32(length(z)))
            f[k] = UInt8((rng_state >> 16) & 0xff)
        end
        result = try
            Diff3D._decode_ktx2(f)
        catch err
            err
        end
        @test result isa Array{Float64,3} || result isa ErrorException
    end
end
# TGA files and the RGBA bytes three.js TGALoader.parse returned for them
# (TGALoader.js; `data` is row-major RGBA with the image top first).
const _A3C_TGA = Dict(
    "rgb24_bl" => (UInt8[2, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 2, 0, 24, 0, 7, 9, 10, 20,
                         30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160, 170, 180],
                   3, 2, [120, 110, 100, 255, 150, 140, 130, 255, 180, 170, 160, 255, 30, 20, 10,
                          255, 60, 50, 40, 255, 90, 80, 70, 255]),
    "rgba32_tl" => (UInt8[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 32, 40, 1, 2, 3, 4, 5,
                          6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 255],
                    2, 2, [3, 2, 1, 4, 7, 6, 5, 8, 11, 10, 9, 12, 15, 14, 13, 255]),
    "rle24_tr" => (UInt8[0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 2, 0, 24, 48, 130, 1, 2, 3,
                         2, 10, 11, 12, 20, 21, 22, 30, 31, 32, 129, 200, 201, 202],
                   4, 2, [12, 11, 10, 255, 3, 2, 1, 255, 3, 2, 1, 255, 3, 2, 1, 255, 202, 201,
                          200, 255, 202, 201, 200, 255, 32, 31, 30, 255, 22, 21, 20, 255]),
    "pal_br" => (UInt8[0, 1, 1, 0, 0, 3, 0, 24, 0, 0, 0, 0, 2, 0, 2, 0, 8, 16, 0, 0, 255, 0,
                       255, 0, 255, 0, 0, 0, 1, 2, 1],
                 2, 2, [0, 255, 0, 255, 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255]),
    "rlepal_bl" => (UInt8[0, 1, 9, 0, 0, 3, 0, 24, 0, 0, 0, 0, 3, 0, 1, 0, 8, 0, 0, 0, 255, 0,
                          255, 0, 255, 0, 0, 129, 2, 0, 0],
                    3, 1, [0, 0, 255, 255, 0, 0, 255, 255, 255, 0, 0, 255]),
    "grey8_tl" => (UInt8[0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 8, 32, 0, 85, 170, 255],
                   2, 2, [0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 255, 255, 255, 255, 255]),
    "rlegrey16_tl" => (UInt8[0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 1, 0, 16, 32, 129, 50,
                             128, 0, 7, 9],
                       3, 1, [50, 50, 50, 128, 50, 50, 50, 128, 7, 7, 7, 9]),
    "rgb16_tl" => (UInt8[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 16, 32, 31, 124, 224, 131],
                   2, 1, [248, 0, 248, 255, 0, 248, 0, 0]))

function _a3c_rgba_rows(data, w, h)
    img = Array{Float64}(undef, h, w, 4)
    for y in 1:h, x in 1:w, c in 1:4
        img[y, x, c] = data[((y - 1) * w + (x - 1)) * 4 + c] / 255
    end
    return img
end

@testset "TGALoader" begin
    mktempdir() do dir
        for (name, (bytes, w, h, rgba)) in _A3C_TGA
            path = joinpath(dir, name * ".tga")
            write(path, bytes)
            @test Diff3D.load_tga(path) == _a3c_rgba_rows(rgba, w, h)
        end
        path = joinpath(dir, "rgb24_bl.tga")
        tex = Diff3D.TGALoader(path; wrap_s=:clamp)
        @test tex isa Texture && tex.data == Diff3D.load_tga(path) && tex.wrap_s === :clamp
        # TGALoader.js tgaCheckHeader errors, plus truncation three.js misses.
        base = _A3C_TGA["rgb24_bl"][1]
        bad(f) = (b = copy(base); f(b); b)
        @test_throws "TGA file is truncated" Diff3D._decode_tga(base[1:10])
        @test_throws "no image data" Diff3D._decode_tga(bad(b -> b[3] = 0))
        @test_throws "image type 4 is not supported" Diff3D._decode_tga(bad(b -> b[3] = 4))
        @test_throws "cannot have a colour map" Diff3D._decode_tga(bad(b -> b[2] = 1))
        @test_throws "image size 0x2 is invalid" Diff3D._decode_tga(bad(b -> b[13] = 0))
        @test_throws "pixel size 12 is not supported" Diff3D._decode_tga(bad(b -> b[17] = 12))
        # An 8-bit true-colour image has no colour map to index (three.js
        # TGALoader.js:399-400 reads it through the missing palette and
        # throws); reading it as B, G, R bytes would run past the pixel data.
        @test_throws "true-colour images must have 16, 24 or 32-bit pixels" Diff3D._decode_tga(
            UInt8[0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 8, 32, 1, 2, 3, 4])
        @test_throws "true-colour images must have 16, 24 or 32-bit pixels" Diff3D._decode_tga(
            UInt8[0, 0, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 2, 0, 8, 32, 0x83, 9])
        @test_throws "pixel data is truncated" Diff3D._decode_tga(base[1:end - 1])
        rle = _A3C_TGA["rle24_tr"][1]
        @test_throws "run-length data is truncated" Diff3D._decode_tga(rle[1:end - 2])
        @test_throws "runs past the image" Diff3D._decode_tga(
            (b = copy(rle); b[33] = 0x83; b))
        pal = _A3C_TGA["pal_br"][1]
        @test_throws "outside the colour map" Diff3D._decode_tga((b = copy(pal); b[end] = 5; b))
        @test_throws "colour map of at most 256 24-bit entries" Diff3D._decode_tga(
            (b = copy(pal); b[8] = 32; b))
        # Random corruption: an image or an ErrorException, nothing else.
        state = UInt32(7)
        for (_, (bytes, _, _, _)) in _A3C_TGA, trial in 1:150
            f = copy(bytes)
            for _ in 1:2
                state = state * UInt32(1664525) + UInt32(1013904223)
                f[1 + Int(state % UInt32(length(f)))] = UInt8((state >> 16) & 0xff)
            end
            result = try
                Diff3D._decode_tga(f)
            catch err
                err
            end
            @test result isa Array{Float64,3} || result isa ErrorException
            result isa Array && @test size(result, 1) * size(result, 2) <= length(f) * 128
        end
    end
end

_A3C_PCD_HEADER(kind, fields, size, type, count) =
    "# .PCD v0.7\nVERSION 0.7\nFIELDS $fields\nSIZE $size\nTYPE $type\nCOUNT $count\n" *
    "WIDTH 3\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS 3\nDATA $kind\n"

function _a3c_pcd_files()
    ascii = _A3C_PCD_HEADER("ascii", "x y z rgb normal_x normal_y normal_z intensity label",
                            "4 4 4 4 4 4 4 4 4", "F F F F F F F F U", "1 1 1 1 1 1 1 1 1") *
        "0.5 -1.25 2.0 9.90143482e-40 0.0 0.0 1.0 0.75 3\n" *
        "1.5 2.25 -3.0 2.34182309e-38 0.0 1.0 0.0 1.5 7\n" *
        "0.5 -1.25 2.0 9.90143482e-40 1.0 0.0 0.0 2.0 3\n"
    pts = ((0.5f0, -1.25f0, 2.0f0, (10, 200, 30), 0.75, 3),
           (1.5f0, 2.25f0, -3.0f0, (255, 0, 128), 1.5, 7),
           (0.5f0, -1.25f0, 2.0f0, (10, 200, 30), 2.0, 3))
    binary = IOBuffer()
    write(binary, _A3C_PCD_HEADER("binary", "x y z rgb intensity label curv", "4 4 4 4 8 2 4",
                                  "F F F U F I F", "1 1 1 1 1 1 2"))
    for (x, y, z, (r, g, b), it, lb) in pts
        write(binary, htol(x), htol(y), htol(z), UInt8(b), UInt8(g), UInt8(r), 0x00,
              htol(Float64(it)), htol(Int16(-lb)), htol(9.0f0), htol(9.5f0))
    end
    # liblzf-format stream of the 72-byte x/y/z/normal_x/y/z columns.
    lzf = UInt8[6, 0, 0, 0, 63, 0, 0, 192, 32, 3, 64, 7, 5, 160, 191, 0, 0, 16, 64, 128, 7, 0,
                0, 32, 7, 1, 64, 192, 128, 7, 192, 1, 0, 128, 64, 39, 224, 10, 7, 1, 0, 0]
    compressed = IOBuffer()
    write(compressed, _A3C_PCD_HEADER("binary_compressed", "x y z normal_x normal_y normal_z",
                                      "4 4 4 4 4 4", "F F F F F F", "1 1 1 1 1 1"))
    write(compressed, htol(UInt32(length(lzf))), htol(UInt32(72)), lzf)
    return Dict("ascii" => Vector{UInt8}(codeunits(ascii)), "binary" => take!(binary),
                "compressed" => take!(compressed))
end

@testset "PCDLoader" begin
    # three.js PCDLoader.parse of the same files (Float32 attributes).
    position = [0.5, -1.25, 2, 1.5, 2.25, -3, 0.5, -1.25, 2]
    color = [0.0030352699104696512, 0.577580451965332, 0.012983032502233982, 1, 0,
             0.2158605009317398, 0.0030352699104696512, 0.577580451965332, 0.012983032502233982]
    normal = [0, 0, 1, 0, 1, 0, 1, 0, 0]
    mktempdir() do dir
        files = _a3c_pcd_files()
        for (name, bytes) in files
            write(joinpath(dir, name * ".pcd"), bytes)
        end
        p = Diff3D.load_pcd(joinpath(dir, "ascii.pcd"))
        @test p isa PointsObject && p.material isa PointsMaterial && p.material.size == 0.005
        @test p.geometry.positions == position && p.geometry.normals == normal
        @test get_attribute(p.geometry, :color).data ≈ color atol = 1e-7
        @test get_attribute(p.geometry, :intensity).data == [0.75, 1.5, 2.0]
        @test get_attribute(p.geometry, :label).data == [3, 7, 3]
        b = Diff3D.load_pcd(joinpath(dir, "binary.pcd"))
        @test b.geometry.positions == position && isempty(b.geometry.normals)
        @test get_attribute(b.geometry, :color).data ≈ color atol = 1e-7
        @test get_attribute(b.geometry, :intensity).data == [0.75, 1.5, 2.0]
        @test get_attribute(b.geometry, :label).data == [-3, -7, -3]
        c = Diff3D.load_pcd(joinpath(dir, "compressed.pcd"))
        @test c.geometry.positions == position && c.geometry.normals == normal
        @test !haskey(c.geometry.attributes, :color)
        # LZF: literal runs and overlapping back references (liblzf lzf_d.c).
        @test Diff3D._lzf_decompress(UInt8[2, 1, 2, 3, 0xe0, 3, 2], 15) ==
              UInt8[1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3]
        @test_throws "points before the start" Diff3D._lzf_decompress(UInt8[0x20, 5], 3)
        @test_throws "decompresses past its declared size" Diff3D._lzf_decompress(UInt8[3, 1, 2, 3, 4], 2)
        @test_throws "decompresses to 1 bytes, expected 4" Diff3D._lzf_decompress(UInt8[0, 9], 4)
        bin = files["binary"]
        @test_throws "binary data is truncated" Diff3D._decode_pcd(bin[1:end - 1])
        cmp = files["compressed"]
        @test_throws "binary_compressed data is truncated" Diff3D._decode_pcd(cmp[1:end - 1])
        hdr(s) = Vector{UInt8}(codeunits(s))
        @test_throws "no DATA line" Diff3D._decode_pcd(hdr("FIELDS x y z\n"))
        @test_throws "DATA \"lzma\" is not supported" Diff3D._decode_pcd(hdr(
            replace(String(copy(files["ascii"])), "DATA ascii" => "DATA lzma")))
        @test_throws "has no z field" Diff3D._decode_pcd(hdr(
            "FIELDS x y\nSIZE 4 4\nTYPE F F\nCOUNT 1 1\nPOINTS 1\nDATA ascii\n1 2\n"))
        @test_throws "unsupported TYPE F SIZE 2" Diff3D._decode_pcd(hdr(
            "FIELDS x y z\nSIZE 4 4 2\nTYPE F F F\nPOINTS 1\nDATA ascii\n1 2 3\n"))
        @test_throws "has 2 values, expected 3" Diff3D._decode_pcd(hdr(
            "FIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nPOINTS 1\nDATA ascii\n1 2\n"))
        state = UInt32(99)
        for (_, bytes) in files, trial in 1:150
            f = copy(bytes)
            for _ in 1:2
                state = state * UInt32(1664525) + UInt32(1013904223)
                f[1 + Int(state % UInt32(length(f)))] = UInt8((state >> 16) & 0xff)
            end
            result = try
                Diff3D._decode_pcd(f)
            catch err
                err
            end
            @test result isa NamedTuple || result isa ErrorException
        end
    end
end

function _a3c_dds(w, h, flags, mips, pf_flags, fourcc, bits, masks, caps2, payload)
    io = IOBuffer()
    write(io, b"DDS ", htol.(UInt32[124, flags, h, w, 0, 0, mips])...)
    write(io, zeros(UInt8, 44))
    write(io, htol(UInt32(32)), htol(UInt32(pf_flags)), fourcc,
          htol.(UInt32[bits, masks...])...)
    write(io, htol.(UInt32[0x1000, caps2, 0, 0, 0])...)
    write(io, UInt8.(payload))
    return take!(io)
end

@testset "DDSLoader (uncompressed)" begin
    # three.js DDSLoader.parse(buffer, true).mipmaps[1].data (RGBA, file row order).
    bgra = _a3c_dds(3, 2, 0x2100f, 2, 0x41, b"\0\0\0\0", 32,
                    (0x00ff0000, 0x0000ff00, 0x000000ff, 0xff000000), 0,
                    vcat([(17i) % 256 for i in 0:23], [1, 2, 3, 4, 5, 6, 7, 8]))
    bgr = _a3c_dds(2, 2, 0x100f, 0, 0x40, b"\0\0\0\0", 24,
                   (0x00ff0000, 0x0000ff00, 0x000000ff, 0), 0, [(29i + 3) % 256 for i in 0:11])
    dxt1 = _a3c_dds(4, 4, 0x100f, 0, 0x4, b"DXT1", 0, (0, 0, 0, 0), 0, zeros(Int, 8))
    mktempdir() do dir
        p32 = joinpath(dir, "a.dds"); write(p32, bgra)
        p24 = joinpath(dir, "b.dds"); write(p24, bgr)
        @test Diff3D.load_dds(p32) == _a3c_rgba_rows(
            [34, 17, 0, 51, 102, 85, 68, 119, 170, 153, 136, 187, 238, 221, 204, 255, 50, 33,
             16, 67, 118, 101, 84, 135], 3, 2)
        @test Diff3D.load_dds(p24) == _a3c_rgba_rows(
            [61, 32, 3, 255, 148, 119, 90, 255, 235, 206, 177, 255, 66, 37, 8, 255], 2, 2)
        # CompressedTexture.flipY is false: v = 0 samples the first file row.
        tex = Diff3D.DDSLoader(p32)
        @test tex isa Texture && tex.data == reverse(Diff3D.load_dds(p32); dims=1)
        p = joinpath(dir, "c.dds"); write(p, dxt1)
        @test_throws "DDS \"DXT1\" data is block-compressed" Diff3D.load_dds(p)
        @test_throws "DX10 extended headers are not supported" Diff3D._decode_dds(
            _a3c_dds(4, 4, 0x100f, 0, 0x4, b"DX10", 0, (0, 0, 0, 0), 0, zeros(Int, 32)))
        @test_throws "pixel format (32-bit" Diff3D._decode_dds(_a3c_dds(
            1, 1, 0x100f, 0, 0x40, b"\0\0\0\0", 32, (0x000000ff, 0x0000ff00, 0x00ff0000, 0xff000000),
            0, zeros(Int, 4)))
        @test_throws "cube maps are not supported" Diff3D._decode_dds(_a3c_dds(
            1, 1, 0x100f, 0, 0x40, b"\0\0\0\0", 24, (0x00ff0000, 0x0000ff00, 0x000000ff, 0),
            0xfe00, zeros(Int, 18)))
        @test_throws "pixel data is truncated" Diff3D._decode_dds(bgr[1:end - 1])
        @test_throws "bad magic number" Diff3D._decode_dds((b = copy(bgr); b[1] = 0x00; b))
        @test_throws "DDS file is truncated" Diff3D._decode_dds(bgr[1:100])
        @test_throws "image size 0x2 is invalid" Diff3D._decode_dds((b = copy(bgr); b[17] = 0; b))
        state = UInt32(3)
        for bytes in (bgra, bgr), trial in 1:200
            f = copy(bytes)
            state = state * UInt32(1664525) + UInt32(1013904223)
            f[1 + Int(state % UInt32(length(f)))] = UInt8((state >> 16) & 0xff)
            result = try
                Diff3D._decode_dds(f)
            catch err
                err
            end
            @test result isa Array{Float64,3} || result isa ErrorException
        end
    end
end
