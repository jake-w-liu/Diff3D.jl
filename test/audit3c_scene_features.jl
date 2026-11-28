using Test, Diff3D

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function render_order_plane(color, z; depth_test=true, name="plane",
                            Material=MeshBasicMaterial, kwargs...)
    mesh = Mesh(PlaneGeometry(width=2.0, height=2.0),
                Material(; color=color, depth_test=depth_test, kwargs...); name=name)
    mesh.position = Vec3(0.0, 0.0, z)
    return mesh
end

function render_order_camera()
    camera = PerspectiveCamera(fov=π / 3)
    camera.position = Vec3(0.0, 0.0, 5.0)
    return camera
end

center_color(target) = Tuple(target.color[8, 8, :])

function cached_frame_allocations(target, scene, camera, cache; kwargs...)
    render!(target, scene, camera; cache, kwargs...)
    return @allocated render!(target, scene, camera; cache, kwargs...)
end

# ---------------------------------------------------------------------------
# (a) Object3D.renderOrder
# ---------------------------------------------------------------------------

@testset "render_order defaults to 0 on every node type and keeps old constructors" begin
    geometry = BoxGeometry()
    material = MeshBasicMaterial()
    bone = Bone()
    skeleton = Skeleton([bone])
    nodes = Any[Object3D(), Scene(), Group(), Mesh(geometry, material),
                LineObject(geometry, LineBasicMaterial()),
                PointsObject(geometry, PointsMaterial()),
                InstancedMesh(geometry, material, 2),
                LineSegments(geometry, LineBasicMaterial()),
                LineLoop(geometry, LineBasicMaterial()), Sprite(SpriteMaterial()),
                LOD(), bone,
                SkinnedMesh(geometry, material, skeleton,
                            fill((1, 1, 1, 1), geometry.n_vertices),
                            fill((1.0, 0.0, 0.0, 0.0), geometry.n_vertices)),
                AmbientLight(), DirectionalLight(), PointLight(), SpotLight(),
                HemisphereLight(), RectAreaLight(), LightProbe(),
                PerspectiveCamera(), OrthographicCamera()]
    for node in nodes
        # three.js Object3D.js: `this.renderOrder = 0`.
        @test node.render_order === 0.0
        node.render_order = 3
        @test node.render_order === 3.0
    end
    # Positional layouts from before the field existed still construct.
    mesh = Mesh(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0), nothing, AbstractObject3D[],
                true, "m", 7, geometry, material, nothing, false, false,
                Float64[], String[])
    @test mesh.render_order === 0.0 && mesh.id == 7
    group = Group(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0), nothing, AbstractObject3D[],
                  true, "g", 8)
    @test group.render_order === 0.0
    instanced = InstancedMesh(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0), nothing,
                              AbstractObject3D[], true, "i", 9, geometry, material,
                              false, false, [Mat4{Float64}()])
    @test instanced.render_order === 0.0
    camera = PerspectiveCamera(Vec3(), Euler(), Vec3(1.0, 1.0, 1.0), nothing,
                               AbstractObject3D[], true, "c", 10, π / 4, 1.0, 0.1,
                               100.0, Vec3(0.0, 0.0, -1.0), Vec3(0.0, 1.0, 0.0))
    @test camera.render_order === 0.0
end

@testset "render_order and group order lead the opaque draw order in every CPU path" begin
    # A far plane without depth testing overwrites whatever was drawn before it.
    # three.js painterSortStable (WebGLRenderLists.js:1-29) draws near first by
    # default, so the far plane lands on top; renderOrder -1 draws it first and
    # the near plane then wins the depth test.
    scene = Scene()
    near = render_order_plane(Color3(1.0, 0.0, 0.0), 1.0; name="near")
    far = render_order_plane(Color3(0.0, 0.0, 1.0), 0.0; depth_test=false, name="far")
    add!(scene, near)
    add!(scene, far)
    camera = render_order_camera()
    target = RenderTarget(16, 16)
    blue = (0.0, 0.0, 1.0)
    red = (1.0, 0.0, 0.0)
    render!(target, scene, camera)
    @test center_color(target) == blue
    default_color = copy(target.color)

    far.render_order = -1
    render!(target, scene, camera)
    @test center_color(target) == red
    reference = copy(target.color)
    render!(target, scene, camera; cache=RenderCache())
    @test target.color == reference
    render_pooled!(target, scene, camera, RenderCache())
    @test target.color == reference
    for tiles in (1, 3)
        render_tiled!(target, scene, camera; tiles=tiles,
                      cache=[RenderCache() for _ in 1:tiles])
        @test target.color == reference
    end
    msaa = RenderTarget(16, 16)
    render_msaa!(msaa, scene, camera; samples=4)
    @test center_color(msaa) == red
    # WebGLRenderer.js:1714: without sortObjects the lists are not sorted, so
    # renderOrder has no effect.
    render!(target, scene, camera; sort_objects=false)
    @test target.color == default_color

    # projectObject (WebGLRenderer.js:1868-1871) gives a Group's descendants its
    # renderOrder as groupOrder, which outranks their own renderOrder.
    far.render_order = 5
    render!(target, scene, camera)
    @test center_color(target) == blue
    group = Group()
    group.render_order = -2
    add!(scene, group)
    add!(group, far)
    render!(target, scene, camera)
    @test center_color(target) == red
    render_pooled!(target, scene, camera, RenderCache())
    @test center_color(target) == red
    # The nearest Group ancestor decides; other node types pass it through.
    inner = Object3D()
    add!(group, inner)
    add!(inner, far)
    @test Diff3D._render_order_key(far) == (-2.0, 5.0)
    nested = Group()
    nested.render_order = 4
    add!(inner, nested)
    add!(nested, far)
    @test Diff3D._render_order_key(far) == (4.0, 5.0)
    render!(target, scene, camera)
    @test center_color(target) == blue

    far.render_order = NaN
    @test_throws ArgumentError render!(target, scene, camera)
    # Equal keys draw as one bucket; -0.0 and 0.0 are one key.
    far.render_order = -0.0
    nested.render_order = 0.0
    @test Diff3D._render_order_buckets(nothing, [near, far], InstancedMesh[])[1] == 1
end

@testset "render_order orders smooth meshes, instances and primitives across passes" begin
    camera = render_order_camera()
    target = RenderTarget(16, 16)
    # Smooth-shaded opaque meshes take the per-mesh path when keys differ.
    scene = Scene()
    add!(scene, AmbientLight(intensity=1.0))
    near = render_order_plane(Color3(1.0, 0.0, 0.0), 1.0; Material=MeshLambertMaterial)
    far = render_order_plane(Color3(0.0, 0.0, 1.0), 0.0; depth_test=false,
                             Material=MeshLambertMaterial)
    near.flat_shading = false
    far.flat_shading = false
    add!(scene, near)
    add!(scene, far)
    # Ambient light on a Lambert surface gives color / π (three.js
    # BRDF_Lambert, lights_lambert_pars_fragment.glsl.js).
    render!(target, scene, camera; shading=:smooth)
    @test target.color[8, 8, 3] ≈ 1 / π && target.color[8, 8, 1] == 0.0
    far.render_order = -1
    render!(target, scene, camera; shading=:smooth)
    @test target.color[8, 8, 1] ≈ 1 / π && target.color[8, 8, 3] == 0.0
    smooth_reference = copy(target.color)
    render!(target, scene, camera; shading=:smooth, cache=RenderCache())
    @test target.color == smooth_reference
    render_pooled!(target, scene, camera, RenderCache())
    @test target.color == smooth_reference

    # An instanced far plane without depth testing.
    scene = Scene()
    near = render_order_plane(Color3(1.0, 0.0, 0.0), 1.0)
    instances = InstancedMesh(PlaneGeometry(width=2.0, height=2.0),
                              MeshBasicMaterial(color=Color3(0.0, 0.0, 1.0),
                                                depth_test=false), 1)
    add!(scene, instances)
    add!(scene, near)
    render!(target, scene, camera)
    @test center_color(target) == (0.0, 0.0, 1.0)
    instances.render_order = -1
    for cache in (nothing, RenderCache())
        render!(target, scene, camera; cache=cache)
        @test center_color(target) == (1.0, 0.0, 0.0)
    end
    render_tiled!(target, scene, camera; tiles=2, cache=[RenderCache(), RenderCache()])
    @test center_color(target) == (1.0, 0.0, 0.0)

    # Primitives are drawn after meshes by default; a higher mesh renderOrder
    # draws a depth-test-free mesh over an opaque line in front of it.
    scene = Scene()
    line_geometry = BufferGeometry([-1.0, 0.0, 2.0, 1.0, 0.0, 2.0], Float64[],
                                   Float64[], Int[], 2, 0)
    line = LineSegments(line_geometry, LineBasicMaterial(color=Color3(0.0, 1.0, 0.0)))
    mesh = render_order_plane(Color3(1.0, 0.0, 0.0), 0.0; depth_test=false)
    add!(scene, line)
    add!(scene, mesh)
    render!(target, scene, camera)
    row = findfirst(y -> target.color[y, 8, 2] == 1.0, 1:16)
    @test row !== nothing
    mesh.render_order = 1
    render!(target, scene, camera)
    @test target.color[row, 8, :] == [1.0, 0.0, 0.0]
end

@testset "render_order leads the transparent draw order" begin
    # Oracle: three.js r186 WebGLRenderList.push/sort (WebGLRenderLists.js:
    # 31-51, 165-171) on items (id, renderOrder, groupOrder, clip z) =
    # (20,0,0,.5), (21,-1,0,.1), (22,0,0,.9), (23,3,-1,.3) sorts to
    # [23, 21, 22, 20]. Diff3D items carry view-space z (= -clip z order).
    items = [Diff3D._TransparentRenderItem(-0.5, 0x00, 1, 0, 20, 0.0, 0.0),
             Diff3D._TransparentRenderItem(-0.1, 0x00, 2, 0, 21, 0.0, -1.0),
             Diff3D._TransparentRenderItem(-0.9, 0x00, 3, 0, 22, 0.0, 0.0),
             Diff3D._TransparentRenderItem(-0.3, 0x00, 4, 0, 23, -1.0, 3.0)]
    Diff3D._sort_transparent_items!(items)
    @test [item.id for item in items] == [23, 21, 22, 20]

    # Blending order on screen: far (blue) then near (red) by default.
    scene = Scene()
    near = render_order_plane(Color3(1.0, 0.0, 0.0), 1.0; transparent=true,
                              opacity=0.5, depth_write=false)
    far = render_order_plane(Color3(0.0, 0.0, 1.0), 0.0; transparent=true,
                             opacity=0.5, depth_write=false)
    add!(scene, near)
    add!(scene, far)
    camera = render_order_camera()
    target = RenderTarget(16, 16)
    render!(target, scene, camera)
    # 0.5 red over (0.5 blue over black).
    @test all(center_color(target) .≈ (0.5, 0.0, 0.25))
    near.render_order = -1
    render!(target, scene, camera)
    @test all(center_color(target) .≈ (0.25, 0.0, 0.5))
    reference = copy(target.color)
    render!(target, scene, camera; cache=RenderCache())
    @test target.color == reference
    render!(target, scene, camera; sort_objects=false)
    @test all(center_color(target) .≈ (0.5, 0.0, 0.25))
end

@testset "render proxies keep their source's render order" begin
    group = Group()
    group.render_order = 2
    geometry = BoxGeometry()
    bone = Bone()
    add!(group, bone)
    skinned = SkinnedMesh(geometry, MeshBasicMaterial(), Skeleton([bone]),
                          fill((1, 1, 1, 1), geometry.n_vertices),
                          fill((1.0, 0.0, 0.0, 0.0), geometry.n_vertices))
    skinned.render_order = -4
    add!(group, skinned)
    proxy = Diff3D._skinned_render_mesh(skinned)
    @test proxy.parent === nothing
    @test Diff3D._render_order_key(proxy) == (2.0, -4.0)
    group.render_order = 7
    Diff3D._update_skinned_render_mesh!(proxy, skinned)
    @test Diff3D._render_order_key(proxy) == (7.0, -4.0)

    morph_geometry = BoxGeometry()
    morph_geometry.attributes[:morph_position_0] =
        BufferAttribute(copy(morph_geometry.positions), 3)
    mesh = Mesh(morph_geometry, MeshBasicMaterial(); morph_target_influences=[0.5])
    mesh.render_order = 3
    add!(group, mesh)
    morphed = [mesh]
    Diff3D._prepare_morph_render_meshes!(morphed)
    @test morphed[1] !== mesh
    @test Diff3D._render_order_key(morphed[1]) == (7.0, 3.0)
end

@testset "cached render! keeps its allocation budget with render orders" begin
    scene = Scene()
    for index in 1:6
        mesh = render_order_plane(Color3(0.1 * index, 0.5, 0.2), -0.1 * index)
        mesh.render_order = isodd(index) ? 1 : -1
        add!(scene, mesh)
    end
    camera = render_order_camera()
    target = RenderTarget(16, 16)
    cache = RenderCache()
    if Base.JLOptions().opt_level > 0
        with_orders = cached_frame_allocations(target, scene, camera, cache)
        for child in scene.children
            child.render_order = 0
        end
        without_orders = cached_frame_allocations(target, scene, camera, cache)
        # The bucket keys reuse the cache's depth scratch.
        @test with_orders <= without_orders
    end
end

@testset "WebGL export writes group and render order for the viewer sort" begin
    scene = Scene()
    a = Mesh(BoxGeometry(), MeshBasicMaterial(); name="a")
    group = Group()
    b = Mesh(BoxGeometry(), MeshBasicMaterial(); name="b")
    add!(scene, a)
    add!(scene, group)
    add!(group, b)
    mktempdir() do dir
        path = joinpath(dir, "order.html")
        save_webgl_html(path, [WebGLExportCase("a", "A", "", scene)])
        html = read(path, String)
        @test !occursin("\"groupOrder\":", html)
        @test !occursin("\"renderOrder\":", html)
        # The viewer sorts by group order, then renderOrder (WebGLRenderLists.js:1-51).
        @test occursin("function painterSortStable(a,b){ const order=renderOrderCompare(a,b);", html)
        @test occursin("function reversePainterSortStable(a,b){ const order=renderOrderCompare(a,b);", html)
        a.render_order = 2
        group.render_order = -3
        b.render_order = -Inf
        save_webgl_html(path, [WebGLExportCase("a", "A", "", scene)])
        html = read(path, String)
        @test occursin("\"name\":\"a\",\"mode\":\"triangles\",\"visible\":true,\"layerMask\":1,\"renderOrder\":2,", html)
        # JSON has no infinity; 1e999 parses to it.
        @test occursin("\"name\":\"b\",\"mode\":\"triangles\",\"visible\":true,\"layerMask\":1,\"groupOrder\":-3,\"renderOrder\":-1e999,", html)
    end
end

# ---------------------------------------------------------------------------
# (b) Object3D clone / copy
# ---------------------------------------------------------------------------

@testset "clone gives a fresh, detached copy of every node type" begin
    geometry = BoxGeometry()
    material = MeshLambertMaterial(color=Color3(0.2, 0.4, 0.6))
    bone = Bone()
    skeleton = Skeleton([bone])
    nodes = Any[Object3D(), Scene(background=Color3(0.1, 0.2, 0.3)), Group(),
                Mesh(geometry, material; morph_target_influences=[0.25],
                     morph_target_names=["a"], cast_shadow=true),
                LineObject(geometry, LineBasicMaterial()),
                PointsObject(geometry, PointsMaterial()),
                InstancedMesh(geometry, material, 2),
                LineSegments(geometry, LineBasicMaterial()),
                LineLoop(geometry, LineBasicMaterial()),
                Sprite(SpriteMaterial(); center=Vec2(0.25, 0.75)), LOD(), bone,
                SkinnedMesh(geometry, material, skeleton,
                            fill((1, 1, 1, 1), geometry.n_vertices),
                            fill((1.0, 0.0, 0.0, 0.0), geometry.n_vertices)),
                AmbientLight(intensity=0.3),
                DirectionalLight(cast_shadow=true, shadow_bias=0.01,
                                 shadow_pcf_radius=2, shadow_intensity=0.5),
                PointLight(distance=4.0, decay=1.0), SpotLight(angle=0.4, penumbra=0.2),
                HemisphereLight(ground_color=Color3(0.5, 0.25, 0.0)),
                RectAreaLight(width=3.0, height=2.0), LightProbe(Color3(0.1, 0.1, 0.1)),
                PerspectiveCamera(fov=0.7, aspect=1.5, near=0.5, far=50.0, zoom=2.0),
                OrthographicCamera(left=-2.0, right=3.0, zoom=1.5)]
    for node in nodes
        node.name = "source"
        node.position = Vec3(1.0, -2.0, 3.0)
        node.rotation = Euler(0.1, 0.2, 0.3, :ZXY)
        node.scale = Vec3(2.0, 1.0, 0.5)
        node.visible = false
        node.render_order = 4
        layers_set!(object_layers(node), 3)
        parent = Group()
        add!(parent, node)
        child = Object3D()
        add!(node, child)

        copy = Diff3D.clone(node)
        @test typeof(copy) === typeof(node)
        @test copy !== node && copy.id != node.id
        @test copy.parent === nothing && get_parent(node) === parent
        @test copy.name == "source" && copy.visible == false
        @test copy.position === node.position && copy.rotation === node.rotation &&
              copy.scale === node.scale
        @test copy.render_order === 4.0
        @test object_layers(copy).mask == UInt32(1) << 3
        object_layers(copy).mask = UInt32(1)
        @test object_layers(node).mask == UInt32(1) << 3
        if node isa LOD
            # LOD.copy (LOD.js:87-105) clones levels only.
            @test isempty(copy.children)
        else
            @test length(copy.children) == 1
            @test copy.children[1] !== child && copy.children[1].parent === copy
            @test copy.children[1].id != child.id
        end
        shallow = Diff3D.clone(node; recursive=false)
        @test isempty(shallow.children)
        # Every remaining field matches, by value or by shared reference.
        for name in fieldnames(typeof(node))
            name in (:parent, :children, :id, :levels, :_camera_levels,
                     :_world_cache) && continue
            @test isequal(getfield(copy, name), getfield(node, name))
        end
    end
end

@testset "clone shares geometry, materials and skeletons like three.js" begin
    geometry = BoxGeometry()
    material = MeshBasicMaterial()
    mesh = Mesh(geometry, material; morph_target_influences=[0.5])
    copy = Diff3D.clone(mesh)
    # Mesh.js:126-127: same geometry and material objects.
    @test copy.geometry === geometry && copy.material === material
    # Mesh.js:116: morphTargetInfluences are sliced, not shared.
    @test copy.morph_target_influences == [0.5]
    @test copy.morph_target_influences !== mesh.morph_target_influences

    instances = InstancedMesh(geometry, material, 2)
    set_instance_matrix!(instances, 1, mat4_translation(1.0, 0.0, 0.0))
    copy = Diff3D.clone(instances)
    # InstancedMesh.js:186-189 copies the instance matrix and colour buffers.
    @test copy.instance_matrices == instances.instance_matrices
    @test copy.instance_matrices !== instances.instance_matrices
    @test copy.instance_colors !== instances.instance_colors
    set_instance_matrix!(copy, 1, mat4_translation(5.0, 0.0, 0.0))
    @test get_instance_matrix(instances, 1) == mat4_translation(1.0, 0.0, 0.0)

    # SkinnedMesh.js:165-169: bind mode and matrices copied, skeleton shared,
    # so a cloned rig is still posed by the original bones.
    root = Group()
    bone = Bone()
    add!(root, bone)
    skeleton = Skeleton([bone])
    skinned = SkinnedMesh(geometry, material, skeleton,
                          fill((1, 1, 1, 1), geometry.n_vertices),
                          fill((1.0, 0.0, 0.0, 0.0), geometry.n_vertices);
                          bind_mode=:detached)
    add!(root, skinned)
    rig = Diff3D.clone(root)
    cloned_skin = rig.children[2]
    @test cloned_skin.skeleton === skeleton
    @test cloned_skin.bind_mode === :detached
    @test cloned_skin.bind_matrix == skinned.bind_matrix
    @test rig.children[1] !== bone
end

@testset "copy! copies state into an existing node" begin
    source = PerspectiveCamera(fov=0.9, aspect=2.0, near=1.0, far=10.0)
    source.position = Vec3(0.0, 1.0, 2.0)
    source.target = Vec3(1.0, 1.0, 0.0)
    set_view_offset!(source, 100.0, 100.0, 10.0, 20.0, 50.0, 50.0)
    child = Object3D()
    add!(source, child)
    dest = PerspectiveCamera()
    keep = Object3D()
    add!(dest, keep)
    parent = Group()
    add!(parent, dest)
    id = dest.id
    @test copy!(dest, source) === dest
    # Object3D.copy keeps the id, parent and existing children (Object3D.js:1605-1652).
    @test dest.id == id && dest.parent === parent
    @test dest.children[1] === keep && length(dest.children) == 2
    @test dest.children[2] !== child
    @test projection_matrix(dest) == projection_matrix(source)
    # `parent` has the identity transform, so the copied aim gives the same view.
    @test view_matrix(dest) == view_matrix(source)
    copy!(dest, source; recursive=false)
    @test length(dest.children) == 2
    # Copying a node into itself does not recurse into the children it adds.
    group = Group()
    add!(group, Object3D())
    copy!(group, group)
    @test length(group.children) == 2

    lod = LOD()
    near = Mesh(BoxGeometry(), MeshBasicMaterial())
    far = Mesh(BoxGeometry(), MeshBasicMaterial())
    add_lod_level!(lod, 0.0, near)
    add_lod_level!(lod, 10.0, far; hysteresis=0.1)
    add!(lod, Object3D())
    lod.auto_update = false
    copied = Diff3D.clone(lod)
    @test length(copied.levels) == 2 && length(copied.children) == 2
    @test copied.levels[2].distance == 10.0 && copied.levels[2].hysteresis == 0.1
    @test copied.levels[1].object !== near && copied.levels[1].object.parent === copied
    @test copied.auto_update == false
    @test lod_select(copied, 20.0) === copied.levels[2].object
end

@testset "clone of geometries and materials" begin
    geometry = BoxGeometry()
    geometry.attributes[:color] = BufferAttribute(fill(0.5, 3 * geometry.n_vertices), 3)
    geometry.groups = [(1, 2, 0)]
    geometry.draw_range = (1, 6)
    copy = Diff3D.clone(geometry)
    # BufferGeometry.copy (BufferGeometry.js:1357-1462) clones every attribute array.
    @test copy !== geometry
    for name in (:positions, :normals, :uvs, :indices, :groups)
        @test getfield(copy, name) == getfield(geometry, name)
        @test getfield(copy, name) !== getfield(geometry, name)
    end
    @test copy.draw_range == (1, 6)
    @test copy.attributes[:color].data == geometry.attributes[:color].data
    @test copy.attributes[:color].data !== geometry.attributes[:color].data
    target = BufferGeometry()
    @test copy!(target, geometry) === target
    @test target.positions == geometry.positions && target.positions !== geometry.positions

    texture = Texture(fill(0.5, 2, 2, 3))
    material = MeshBasicMaterial(map=texture, clipping_planes=[Plane(Vec3(1.0, 0.0, 0.0), 0.0)])
    copy = Diff3D.clone(material)
    @test typeof(copy) === typeof(material)
    for name in fieldnames(MeshBasicMaterial)
        @test isequal(getfield(copy, name), getfield(material, name))
    end
    # Material.copy (Material.js:1119-1168) shares textures and copies the
    # clipping-plane list.
    @test copy.map === texture
    @test copy.clipping_planes == material.clipping_planes
    @test copy.clipping_planes !== material.clipping_planes
    for original in (MeshLambertMaterial(), MeshPhongMaterial(), MeshStandardMaterial(),
                     MeshPhysicalMaterial(), MeshToonMaterial(), MeshMatcapMaterial(),
                     MeshDepthMaterial(), MeshNormalMaterial(), LineBasicMaterial(),
                     LineDashedMaterial(), PointsMaterial(), SpriteMaterial())
        cloned = Diff3D.clone(original)
        @test typeof(cloned) === typeof(original)
        @test all(isequal(getfield(cloned, name), getfield(original, name))
                  for name in fieldnames(typeof(original)))
    end
    # ShaderMaterial.copy clones the uniforms (UniformsUtils.cloneUniforms
    # slices arrays).
    shader = ShaderMaterial(uniforms=Dict{String,Any}("weights" => [1.0, 2.0], "k" => 3.0))
    cloned = Diff3D.clone(shader)
    @test cloned.uniforms == shader.uniforms && cloned.uniforms !== shader.uniforms
    @test cloned.uniforms["weights"] !== shader.uniforms["weights"]
end
