using Test
using Diff3D

@testset "Mesh morphs reach all scene consumers" begin
    geometry = PlaneGeometry(width=1.3, height=1.1)
    set_attribute!(geometry, :tangent, repeat([1.0, 0.0, 0.0, 1.0], geometry.n_vertices), 4)
    set_attribute!(geometry, :uv2, copy(geometry.uvs), 2)
    set_attribute!(geometry, :morphPosition0,
                   [1.7, 0.0, 0.2, 1.6, 0.1, -0.1, 1.8, 0.0, 0.1, 1.5, -0.1, 0.3], 3)
    set_attribute!(geometry, :morphPosition1,
                   [0.0, 0.1, 0.0, 0.1, 0.0, 0.0, 0.0, -0.1, 0.1, -0.1, 0.0, 0.0], 3)
    set_attribute!(geometry, :morphNormal0, repeat([0.3, 0.1, -0.1], geometry.n_vertices), 3)
    set_attribute!(geometry, :morphTangent0, repeat([0.0, 0.4, 0.2], geometry.n_vertices), 3)
    original = deepcopy(geometry)

    function baked(source, weights)
        result = deepcopy(source)
        for (slot, weight) in enumerate(weights)
            position_name = Symbol("morphPosition", slot-1)
            normal_name = Symbol("morphNormal", slot-1)
            tangent_name = Symbol("morphTangent", slot-1)
            has_attribute(source, position_name) &&
                (result.positions .+= weight .* get_attribute(source, position_name).data)
            has_attribute(source, normal_name) &&
                (result.normals .+= weight .* get_attribute(source, normal_name).data)
            if has_attribute(source, tangent_name)
                tangent = get_attribute(result, :tangent).data
                delta = get_attribute(source, tangent_name).data
                for i in 1:source.n_vertices, axis in 1:3
                    tangent[4(i-1)+axis] += weight * delta[3(i-1)+axis]
                end
            end
        end
        for i in 1:source.n_vertices
            for (data, stride) in ((result.normals, 3), (get_attribute(result, :tangent).data, 4))
                indices = stride*(i-1) .+ (1:3)
                length = sqrt(sum(abs2, data[indices]))
                iszero(length) || (data[indices] ./= length)
            end
        end
        for name in collect(keys(result.attributes))
            startswith(string(name), "morph") && delete!(result.attributes, name)
        end
        return result
    end

    normal_map = Texture(reshape([0.7, 0.3, 0.9], 1, 1, 3); colorspace=:linear)
    material = MeshPhongMaterial(color=Color3(0.5, 0.3, 0.2), normal_map=normal_map,
                                  shininess=20.0, side=:double)
    camera = PerspectiveCamera()
    function setup(mesh)
        prepared_scene = Scene(background=Color3(0.02, 0.03, 0.04))
        parent = Group()
        parent.position = Vec3(-0.3, 0.1, 0.0)
        mesh.position = Vec3(0.2, 0.0, 0.1)
        mesh.rotation = Euler(0.1, 0.2, 0.0)
        mesh.scale = Vec3(1.1, 0.9, 1.0)
        add!(parent, mesh)
        add!(prepared_scene, parent)
        add!(prepared_scene, AmbientLight(intensity=0.3))
        prepared_light = DirectionalLight(intensity=0.4, position=Vec3(1.0, 2.0, 4.0))
        prepared_light.cast_shadow = true
        add!(prepared_scene, prepared_light)
        return prepared_scene, prepared_light
    end
    mesh = Mesh(geometry, material; name="morphed", cast_shadow=true,
                receive_shadow=true, morph_target_influences=[0.5, -0.2],
                morph_target_names=["lift", "stretch"])
    scene, light = setup(mesh)
    cache = RenderCache()
    tiled_caches = [RenderCache() for _ in 1:Threads.nthreads()]
    soft_workspace = SoftRenderSceneWorkspace()

    for weights in ([0.5, -0.2], [1.0, 0.3], [0.0, 0.0], [0.25, 0.0])
        mesh.morph_target_influences .= weights
        expected_mesh = Mesh(baked(geometry, weights), material;
                             name="baked", cast_shadow=true, receive_shadow=true)
        expected_scene, expected_light = setup(expected_mesh)
        @test only(collect_meshes(scene)) === mesh
        @test only(collect_meshes(expected_scene)) === expected_mesh
        export_before = Diff3D._web_drawable_json(mesh, Mat4())
        for shading in (:flat, :smooth), scratch in (nothing, cache)
            actual, expected = RenderTarget(12, 12), RenderTarget(12, 12)
            render!(actual, scene, camera; shading=shading, cache=scratch)
            render!(expected, expected_scene, camera; shading=shading)
            @test any(>(0.05), expected.color)
            @test actual.color ≈ expected.color atol=1e-12
        end
        expected = RenderTarget(12, 12)
        render!(expected, expected_scene, camera)
        pooled = RenderTarget(12, 12)
        render_pooled!(pooled, scene, camera, cache)
        @test pooled.color ≈ expected.color atol=1e-12
        tiled = RenderTarget(12, 12)
        render_tiled!(tiled, scene, camera; tiles=2, cache=tiled_caches)
        @test tiled.color ≈ expected.color atol=1e-12

        expected_soft = soft_render_scene(expected_scene, camera, 4, 4)
        @test soft_render_scene(scene, camera, 4, 4) ≈ expected_soft atol=1e-12
        @test soft_render_scene(scene, camera, 4, 4; workspace=soft_workspace) ≈ expected_soft atol=1e-12

        shadow = compute_shadow_map(scene, light; resolution=8)
        expected_shadow = compute_shadow_map(expected_scene, expected_light; resolution=8)
        @test collect(shadow.light_vp.e) ≈ collect(expected_shadow.light_vp.e) atol=1e-12
        @test isinf.(shadow.depth) == isinf.(expected_shadow.depth)
        mask = isfinite.(expected_shadow.depth)
        @test shadow.depth[mask] ≈ expected_shadow.depth[mask] atol=1e-12
        render!(pooled, scene, camera; cache=cache, shadows=true, shadow_resolution=8)
        @test collect(cache.shadow_maps[light].light_vp.e) ≈ collect(expected_shadow.light_vp.e) atol=1e-12
        @test Diff3D._web_drawable_json(mesh, Mat4()) == export_before
    end

    # A cache slot must also follow replacement geometry and material metadata.
    replacement = SphereGeometry(width_segments=4, height_segments=2)
    set_attribute!(replacement, :tangent, repeat([1.0, 0.0, 0.0, 1.0], replacement.n_vertices), 4)
    set_attribute!(replacement, :morphPosition0, repeat([0.0, 0.3, 0.0], replacement.n_vertices), 3)
    mesh.geometry = replacement
    mesh.material = MeshBasicMaterial(color=Color3(0.2, 0.6, 0.3))
    mesh.morph_target_influences = [0.8]
    mesh.flat_shading = true
    mesh.cast_shadow = false
    mesh.name = "replacement"
    expected_mesh = Mesh(baked(replacement, [0.8]), mesh.material; flat_shading=true)
    expected_scene, _ = setup(expected_mesh)
    actual, expected = RenderTarget(12, 12), RenderTarget(12, 12)
    render!(actual, scene, camera; cache=cache, shading=:smooth)
    render!(expected, expected_scene, camera; shading=:smooth)
    @test actual.color ≈ expected.color atol=1e-12
    @test cache.meshes[1].id == mesh.id
    @test cache.meshes[1].name == mesh.name
    @test cache.meshes[1].material === mesh.material
    @test cache.meshes[1].flat_shading === true
    @test cache.meshes[1].cast_shadow === false

    # Shared geometry must retain distinct poses, including across cached frames.
    shared_scene = Scene()
    first_mesh = Mesh(geometry, MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0));
                      morph_target_influences=[0.5, 0.0])
    second_mesh = Mesh(geometry, MeshBasicMaterial(color=Color3(0.0, 1.0, 0.0));
                       morph_target_influences=[-0.5, 0.0])
    add!(shared_scene, first_mesh)
    add!(shared_scene, second_mesh)
    expected_shared = Scene()
    add!(expected_shared, Mesh(baked(geometry, [0.5, 0.0]), first_mesh.material))
    add!(expected_shared, Mesh(baked(geometry, [-0.5, 0.0]), second_mesh.material))
    actual, expected = RenderTarget(16, 16), RenderTarget(16, 16)
    render!(actual, shared_scene, camera; cache=cache)
    render!(expected, expected_shared, camera)
    @test actual.color ≈ expected.color atol=1e-12
    @test geometry.positions == original.positions
    @test geometry.normals == original.normals
    for name in keys(original.attributes)
        @test get_attribute(geometry, name).data == get_attribute(original, name).data
    end

    # Picking must use the posed vertices but identify the authored mesh.
    expected_geometry = baked(geometry, first_mesh.morph_target_influences)
    face = get_face(expected_geometry, 1)
    center = sum(get_vertex(expected_geometry, i) for i in face) / 3
    ray = Raycaster(center + Vec3(0.0, 0.0, 3.0), Vec3(0.0, 0.0, -1.0))
    hits = raycast(ray, first_mesh)
    expected_hits = raycast(ray, Mesh(expected_geometry, first_mesh.material))
    @test !isempty(expected_hits)
    @test length(hits) == length(expected_hits)
    if length(hits) == length(expected_hits)
        @test [hit.distance for hit in hits] ≈ [hit.distance for hit in expected_hits]
    end
    @test all(hit -> hit.object === first_mesh, hits)

    first_mesh.morph_target_influences[1] = NaN
    @test_throws ArgumentError render!(actual, shared_scene, camera; cache=cache)
    @test_throws ArgumentError raycast(ray, first_mesh)
    @test_throws ArgumentError soft_render_scene(shared_scene, camera, 4, 4; workspace=soft_workspace)
    first_mesh.visible = false
    @test render!(actual, shared_scene, camera; cache=cache) === actual
end
