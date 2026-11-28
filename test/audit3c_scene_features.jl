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

# Renders in progress that armed `light`'s per-frame world matrix.
light_cache_depth(light) = @atomic light._world_cache.depth

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
        # With every order 0 the page is the 2.0 page byte for byte: the viewer
        # keeps its sort functions without the render-order keys.
        @test !occursin("renderOrderCompare", html)
        @test occursin("function painterSortStable(a,b){ if(a.renderProgramId!==b.renderProgramId)", html)
        @test occursin("function reversePainterSortStable(a,b){ if(a.renderZ!==b.renderZ)", html)
        a.render_order = 2
        group.render_order = -3
        b.render_order = -Inf
        save_webgl_html(path, [WebGLExportCase("a", "A", "", scene)])
        html = read(path, String)
        # The viewer sorts by group order, then renderOrder (WebGLRenderLists.js:1-51).
        @test occursin("function painterSortStable(a,b){ const order=renderOrderCompare(a,b); if(order!==0) return order; if(a.renderProgramId!==b.renderProgramId)", html)
        @test occursin("function reversePainterSortStable(a,b){ const order=renderOrderCompare(a,b); if(order!==0) return order; if(a.renderZ!==b.renderZ)", html)
        @test count("function renderOrderCompare(a,b)", html) == 1
        # A non-zero order on a node that is not drawn (here only a group)
        # also selects the render-order sort.
        a.render_order = 0
        b.render_order = 0
        save_webgl_html(path, [WebGLExportCase("a", "A", "", scene)])
        @test occursin("renderOrderCompare", read(path, String))
        a.render_order = 2
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

# ---------------------------------------------------------------------------
# (c) Per-frame world matrices of parented lights; cameras under any node
# ---------------------------------------------------------------------------

function parented_light_scene(parent)
    scene = Scene()
    mesh = Mesh(SphereGeometry(radius=1.0, width_segments=12, height_segments=8),
                MeshStandardMaterial(color=Color3(0.8, 0.6, 0.4), roughness=0.4))
    mesh.flat_shading = false
    add!(scene, mesh)
    add!(scene, parent)
    light = PointLight(intensity=20.0)
    light.position = Vec3(2.0, 2.0, 3.0)
    add!(parent, light)
    camera = PerspectiveCamera()
    camera.position = Vec3(0.0, 0.0, 4.0)
    return scene, camera, light
end

@testset "parented lights use one world matrix per frame" begin
    parent = LOD()
    parent.rotation = Euler(0.1, 0.0, 0.0)
    scene, camera, light = parented_light_scene(parent)
    target = RenderTarget(24, 24)
    render!(target, scene, camera; shading=:smooth)
    first_image = copy(target.color)
    # The cache only lives while a render is in progress.
    @test light_cache_depth(light) == 0
    # Moving the parent between frames moves the light.
    parent.position = Vec3(0.0, -3.0, 0.0)
    render!(target, scene, camera; shading=:smooth)
    @test target.color != first_image
    parent.position = Vec3(0.0, 0.0, 0.0)
    render!(target, scene, camera; shading=:smooth)
    @test target.color == first_image
    # The frame's matrix is the one compute_world_matrix gives, so the image
    # matches the same light computed per query (disarmed renders are the old
    # path: lights whose transform chain is not finite are never armed).
    Diff3D._arm_light_world_cache!([light])
    @test light_cache_depth(light) == 1
    @test Diff3D._light_world_matrix(light) === compute_world_matrix(light)
    Diff3D._disarm_light_world_cache!([light])
    @test light_cache_depth(light) == 0
    # An error during the frame still disarms the lights.
    bad = Mesh(BufferGeometry([0.0, 0.0, 0.0], Float64[], Float64[], [1, 2, 3], 1, 1),
               MeshBasicMaterial())
    add!(scene, bad)
    @test_throws Exception render!(target, scene, camera; shading=:smooth)
    @test light_cache_depth(light) == 0
    remove!(scene, bad)
    # A non-finite parent transform still raises from the shading query.
    parent.position = Vec3(NaN, 0.0, 0.0)
    @test_throws ArgumentError render!(target, scene, camera; shading=:smooth)
    @test light_cache_depth(light) == 0
    parent.position = Vec3(0.0, 0.0, 0.0)
    # Cached, pooled and tiled frames agree.
    cache = RenderCache()
    render!(target, scene, camera; shading=:smooth, cache=cache)
    @test target.color == first_image
    flat = RenderTarget(24, 24)
    render!(flat, scene, camera)
    reference = copy(flat.color)
    render_pooled!(flat, scene, camera, RenderCache())
    @test flat.color == reference
    render_tiled!(flat, scene, camera; tiles=2, cache=[RenderCache(), RenderCache()])
    @test flat.color == reference
    @test light_cache_depth(light) == 0
    if Base.JLOptions().opt_level > 0
        # Before, every shaded fragment walked the LOD parent with a dynamic
        # compute_world_matrix call that allocated; now the frame computes the
        # light's world matrix once.
        render!(target, scene, camera; shading=:smooth, cache=cache)
        parented = @allocated render!(target, scene, camera; shading=:smooth, cache=cache)
        root_scene, root_camera, _ = parented_light_scene(Group())
        root_cache = RenderCache()
        render!(target, root_scene, root_camera; shading=:smooth, cache=root_cache)
        rooted = @allocated render!(target, root_scene, root_camera; shading=:smooth,
                                    cache=root_cache)
        @test parented <= rooted + 1024
    end
end

@testset "light clones get their own world-matrix cache" begin
    light = SpotLight()
    copy = Diff3D.clone(light)
    @test copy._world_cache !== light._world_cache
    @test light_cache_depth(copy) == 0
end

@testset "concurrent renders of one scene leave no light armed" begin
    # Several tasks render the same scene (distinct targets and caches); arming
    # and disarming are serialized and atomic, so every light ends unarmed and
    # a later render sees a moved parent.
    scene = Scene()
    add!(scene, Mesh(PlaneGeometry(width=4.0, height=4.0),
                     MeshLambertMaterial(color=Color3(0.8, 0.8, 0.8))))
    rig = Group()
    add!(scene, rig)
    lights = [PointLight(intensity=5.0, position=Vec3(0.5 * index - 1.0, 0.3, 1.0))
              for index in 1:6]
    foreach(light -> add!(rig, light), lights)
    camera = PerspectiveCamera()
    camera.position = Vec3(0.0, 0.0, 3.0)
    @sync for task_index in 1:max(4, 2 * Threads.nthreads())
        Threads.@spawn begin
            target = RenderTarget(4, 4)
            cache = RenderCache()
            for frame in 1:60
                if isodd(frame + task_index)
                    render!(target, scene, camera; cache=cache, shading=:smooth)
                else
                    render_pooled!(target, scene, camera, cache)
                end
            end
        end
    end
    @test all(light -> light_cache_depth(light) == 0, lights)
    rig.position = Vec3(0.0, 0.0, -0.8)
    moved = RenderTarget(16, 16)
    render!(moved, scene, camera; shading=:smooth)
    for light in lights
        light.position += rig.position
    end
    rig.position = Vec3(0.0, 0.0, 0.0)
    baked = RenderTarget(16, 16)
    render!(baked, scene, camera; shading=:smooth)
    @test moved.color == baked.color
    # A cached frame that fails before it collects its lights does not disarm
    # the lights of the cache's previous frame, which another render may hold.
    light = lights[1]
    cache = RenderCache()
    render!(RenderTarget(4, 4), scene, camera; cache=cache)
    Diff3D._arm_light_world_cache!([light])
    @test_throws ArgumentError render!(RenderTarget(4, 4), scene, camera; cache=cache,
                                       shading=:bogus)
    @test light_cache_depth(light) == 1
    Diff3D._disarm_light_world_cache!([light])
    @test light_cache_depth(light) == 0
end

@testset "view_matrix of a camera under a light, LOD, sprite or line does not allocate" begin
    for make_parent in (() -> PointLight(), () -> DirectionalLight(), () -> SpotLight(),
                        () -> LOD(), () -> Sprite(SpriteMaterial()),
                        () -> LineSegments(BoxGeometry(), LineBasicMaterial()),
                        () -> LineLoop(BoxGeometry(), LineBasicMaterial()))
        parent = make_parent()
        parent.position = Vec3(1.0, 0.0, 0.0)
        camera = PerspectiveCamera()
        add!(parent, camera)
        @test all(isapprox.(view_matrix(camera).e,
                            (mat4_translation(-1.0, 0.0, 0.0) * view_matrix(PerspectiveCamera())).e;
                            atol=1e-15))
        if Base.JLOptions().opt_level > 0
            view_matrix(camera)
            @test (@allocated view_matrix(camera)) == 0
        end
    end
end

# ---------------------------------------------------------------------------
# (d) three.js Color API
# ---------------------------------------------------------------------------

# Oracle values: node with three.js r186 build/three.module.js (Color.js,
# ColorManagement.js); the script is d/color_oracle.mjs in the audit scratch.
color_tuple(c) = (c.r, c.g, c.b)

@testset "Color hex, sRGB conversion and equality follow three.js" begin
    # Color.setHex (Color.js:204-216) reads sRGB by default.
    @test color_tuple(Diff3D.color_from_hex(0x336699)) ==
          (0.033104766565152086, 0.13286832154414627, 0.31854677811435356)
    @test color_tuple(Diff3D.color_from_hex(0x336699; colorspace=:linear)) ==
          (0.2, 0.4, 0.6)
    # `Math.floor(hex)` then `hex >> 16 & 255`: bits above 24 are dropped.
    @test Diff3D.color_from_hex(0x12336699) == Diff3D.color_from_hex(0x336699)
    @test Diff3D.color_from_hex(0xf000000000336699) == Diff3D.color_from_hex(0x336699)
    @test Diff3D.color_from_hex(big(2)^80 + 0x336699) == Diff3D.color_from_hex(0x336699)
    # Color.getHex (Color.js:539-551): sRGB, clamped, Math.round.
    @test Diff3D.color_hex(Color3(0.2, 0.4, 0.6)) == 8170187
    @test Diff3D.color_hex(Color3(0.2, 0.4, 0.6); colorspace=:linear) == 3368601
    @test Diff3D.color_hex(Color3(-0.5, 0.5, 2.0)) == 48383
    @test Diff3D.color_hex_string(Color3(0.001, 0.0, 1.5)) == "0300ff"
    @test all(isapprox.(color_tuple(Diff3D.color_from_hex(Diff3D.color_hex(Color3(0.25, 0.5, 0.75)))),
                        (0.25, 0.5, 0.75); atol=0.01))
    # ColorManagement.js:205-215 constants.
    @test color_tuple(Diff3D.color_convert_srgb_to_linear(Color3(0.2, 0.04045, 0.9))) ==
          (0.033104766565152086, 0.0031308072813303342, 0.78741228939106567)
    @test color_tuple(Diff3D.color_convert_linear_to_srgb(Color3(0.2, 0.0031308, 0.9))) ==
          (0.48453499343780709, 0.040453576944652785, 0.95468788109385583)
    # Color.equals uses === per channel (Color.js:875-879).
    @test Diff3D.color_equals(Color3(0.0, 0.0, 0.0), Color3(-0.0, 0.0, 0.0))
    @test !Diff3D.color_equals(Color3(NaN, 0.0, 0.0), Color3(NaN, 0.0, 0.0))
    @test_throws ArgumentError Diff3D.color_from_hex(0xffffff; colorspace=:display_p3)
end

@testset "Color HSL helpers follow three.js" begin
    # Color.setHSL (Color.js:248-276) in the working space by default.
    @test color_tuple(Diff3D.color_from_hsl(0.3, 0.6, 0.4)) ==
          (0.25599999999999995, 0.64000000000000012, 0.15999999999999992)
    @test color_tuple(Diff3D.color_from_hsl(0.3, 0.6, 0.4; colorspace=:srgb)) ==
          (0.053311270235764138, 0.36724646819968193, 0.021980947075146660)
    # Hue wraps with euclideanModulo; s and l are clamped.
    @test color_tuple(Diff3D.color_from_hsl(-0.7, 1.5, 0.8)) ==
          (0.68000000000000005, 1.0, 0.60000000000000009)
    @test color_tuple(Diff3D.color_from_hsl(0.5, 0.0, 0.25)) == (0.25, 0.25, 0.25)
    # Color.getHSL (Color.js:567-617).
    @test Tuple(Diff3D.color_hsl(Color3(0.2, 0.4, 0.6))) ==
          (0.58333333333333337, 0.49999999999999994, 0.40000000000000002)
    @test Tuple(Diff3D.color_hsl(Color3(0.9, 0.1, 0.3); colorspace=:srgb)) ==
          (0.93541329249901206, 0.86981440356333906, 0.65194214915941351)
    @test Tuple(Diff3D.color_hsl(Color3(0.5, 0.5, 0.5))) == (0.0, 0.0, 0.5)
    @test Tuple(Diff3D.color_hsl(Color3(0.1, 0.8, 0.3))) ==
          (0.38095238095238093, 0.77777777777777779, 0.45000000000000001)
    @test Tuple(Diff3D.color_hsl(Color3(0.1, 0.2, 0.8))) ==
          (0.64285714285714290, 0.77777777777777779, 0.45000000000000001)
    # Color.offsetHSL, Color.lerp and Color.lerpHSL (Color.js:664-676, 778-796, 819-834).
    @test color_tuple(Diff3D.color_offset_hsl(Color3(0.2, 0.4, 0.6), 0.1, -0.2, 0.05)) ==
          (0.34199999999999997, 0.31500000000000006, 0.58499999999999996)
    @test color_tuple(Diff3D.color_lerp(Color3(0.2, 0.4, 0.6), Color3(1.0, 0.0, 0.5), 0.25)) ==
          (0.40000000000000002, 0.30000000000000004, 0.57499999999999996)
    @test color_tuple(Diff3D.color_lerp_hsl(Color3(0.2, 0.4, 0.6), Color3(0.9, 0.1, 0.3), 0.3)) ==
          (0.26509499999999964, 0.17630000000000001, 0.68369999999999986)
end

@testset "Color CSS styles and names follow three.js" begin
    # Color.setStyle (Color.js:286-423, 425-445).
    @test color_tuple(Diff3D.color_from_style("rgb(255, 0, 128)")) ==
          (1.0, 0.0, 0.21586050010324417)
    @test color_tuple(Diff3D.color_from_style("rgba(10,20,300,0.5)")) ==
          (0.0030352698352941175, 0.0069954101845983935, 1.0)
    @test color_tuple(Diff3D.color_from_style("rgb(10%, 50%, 120%)")) ==
          (0.010022825571656560, 0.21404114047158820, 1.0)
    @test color_tuple(Diff3D.color_from_style("hsl(120, 50%, 25%)")) ==
          (0.014349874702952042, 0.11601613422345775, 0.014349874702952009)
    @test color_tuple(Diff3D.color_from_style("hsla(400, 50.5%, 75%, 0.2)")) ==
          (0.74123033174332065, 0.59049581703412979, 0.34697462822369790)
    @test color_tuple(Diff3D.color_from_style("#f80")) == (1.0, 0.24620132669705552, 0.0)
    @test color_tuple(Diff3D.color_from_style("#FF8000")) == (1.0, 0.21586050010324417, 0.0)
    @test color_tuple(Diff3D.color_from_style("SkyBlue")) ==
          (0.24228112245478564, 0.61720656241206351, 0.83076987677097147)
    @test color_tuple(Diff3D.color_from_style("rgb(255, 0, 128)"; colorspace=:linear)) ==
          (1.0, 0.0, 0.50196078431372548)
    @test color_tuple(Diff3D.color_from_name("rebeccapurple")) ==
          (0.13286832154414627, 0.033104766565152086, 0.31854677811435356)
    # three.js warns and keeps the old color; Diff3D raises instead.
    for bad in ("", "#ff", "cmyk(1,2,3,4)", "rgb(1,2)", "hsl(1,2,3)", "notacolor")
        @test_throws ArgumentError Diff3D.color_from_style(bad)
    end
    @test_throws ArgumentError Diff3D.color_from_name("notacolor")
    # Color.getStyle (Color.js:637-662).
    @test Diff3D.color_style(Color3(0.2, 0.4, 0.6)) == "rgb(124,170,203)"
    @test Diff3D.color_style(Color3(0.2, 0.4, 0.6); colorspace=:linear) ==
          "color(srgb-linear 0.200 0.400 0.600)"
    @test Diff3D.color_style(Color3(0.0005, 1.0625, -0.0125); colorspace=:linear) ==
          "color(srgb-linear 0.001 1.063 -0.013)"
    @test Diff3D.color_style(Color3(1.5, -0.2, 0.5)) == "rgb(305,-659,188)"
    # three.js would print NaN or Infinity; Diff3D raises.
    @test_throws ArgumentError Diff3D.color_style(Color3(NaN, 0.0, 0.0))
    @test_throws ArgumentError Diff3D.color_hex(Color3(0.0, NaN, 0.0))
end

# ---------------------------------------------------------------------------
# (e) Math gaps: Frustum, Box3, Triangle, Matrix4, Quaternion, MathUtils
# ---------------------------------------------------------------------------
# Oracle values: node with three.js r186 build/three.module.js; the script is
# e/e_oracle.mjs in the audit scratch.

oracle_mat4(values...) = Mat4(Float64.(values))
plane_tuple(plane) = (plane.normal.x, plane.normal.y, plane.normal.z, plane.constant)

@testset "Frustum planes for WebGL, WebGPU and reversed depth" begin
    # Matrix4.makePerspective(-0.3, 0.4, 0.25, -0.2, 0.5, 40, system, reversed)
    # and the inverse world matrix of a camera at (1,2,3) looking at the origin.
    view = oracle_mat4(0.94868329805051410, -0.16903085094570330, 0.26726124191242434, 0.0,
                       -2.7755575615628920e-17, 0.84515425472851680, 0.53452248382484879, 0.0,
                       -0.31622776601683794, -0.50709255283711008, 0.80178372573727330, 0.0,
                       -1.5012955407352220e-16, 3.5108334685767005e-17, -3.7416573867739418, 1.0)
    proj(e11, e15) = oracle_mat4(1.4285714285714286, 0.0, 0.0, 0.0, 0.0, 2.2222222222222223,
                                 0.0, 0.0, 0.14285714285714290, 0.11111111111111108, e11,
                                 -1.0, 0.0, 0.0, e15, 0.0)
    side_planes = [(-0.90775397171312866, -0.33391354845187282, -0.25393792351541195, 2.3373948391631103),
                   (0.67598444226572907, -0.27500954910846331, -0.68367739593601518, 1.9250668437592431),
                   (-0.25619953854067912, 0.58618935892374457, -0.76859861562203757, 1.3896166675593025),
                   (0.031662928270251543, -0.99497466788533317, 0.094988784810754637, 1.6733200530681507)]
    cases = [
        # Frustum.setFromProjectionMatrix (Frustum.js:95-136), WebGL near plane.
        (:webgl, false, proj(-1.0253164556962024, -1.0126582278481013),
         (0.26726124191242484, 0.53452248382484968, 0.80178372573727230, 36.258342613226141),
         (-0.26726124191242434, -0.53452248382484868, -0.80178372573727330, 3.2416573867739413)),
        # WebGPU: near = row 3 alone (Frustum.js:122-124).
        (:webgpu, false, proj(-1.0126582278481013, -0.50632911392405067),
         (0.26726124191242528, 0.53452248382485057, 0.80178372573727152, 36.258342613225871),
         (-0.26726124191242434, -0.53452248382484879, -0.80178372573727330, 3.2416573867739418)),
        # Reversed depth: far = row 3, near = row 4 - row 3 (Frustum.js:109-112).
        (:webgl, true, proj(0.012658227848101266, 0.50632911392405067),
         (0.26726124191242429, 0.53452248382484868, 0.80178372573727308, 36.258342613226056),
         (-0.26726124191242429, -0.53452248382484879, -0.80178372573727330, 3.2416573867739413)),
    ]
    for (system, reversed, projection, far, near) in cases
        frustum = frustum_from_matrix(projection * view; coordinate_system=system,
                                      reversed_depth=reversed)
        expected = [side_planes; far; near]
        for (plane, oracle) in zip(frustum.planes, expected)
            @test all(isapprox.(plane_tuple(plane), oracle; atol=1e-12))
        end
        # containsPoint for (0,0,0), (0,0,3.2), (0,0,2.6), (-30,0,-30).
        @test [frustum_contains_point(frustum, Vec3(p...)) for p in
               ((0.0, 0.0, 0.0), (0.0, 0.0, 3.2), (0.0, 0.0, 2.6), (-30.0, 0.0, -30.0))] ==
              [true, false, false, false]
    end
    # The default stays the WebGL convention.
    vp = proj(-1.0253164556962024, -1.0126582278481013) * view
    @test frustum_from_matrix(vp) == frustum_from_matrix(vp; coordinate_system=:webgl)
    @test_throws ArgumentError frustum_from_matrix(vp; coordinate_system=:vulkan)
end

@testset "Frustum intersectsObject and intersectsSprite" begin
    # Orthographic box x,y in [-1,1] seen from (0,0,-1) (Frustum.js:146-183).
    frustum = frustum_from_matrix(mat4_orthographic(-1.0, 1.0, -1.0, 1.0, 0.1, 10.0) *
                                  mat4_inverse(mat4_translation(0.0, 0.0, -1.0)))
    sprite = Sprite(SpriteMaterial(); center=Vec2(0.0, 0.0))
    sprite.position = Vec3(1.6, 0.0, -2.0)
    @test Diff3D.frustum_intersects_sprite(frustum, sprite)
    sprite.center = Vec2(0.5, 0.5)
    @test Diff3D.frustum_intersects_sprite(frustum, sprite)
    sprite.position = Vec3(1.8, 0.0, -2.0)
    @test !Diff3D.frustum_intersects_sprite(frustum, sprite)
    box = Mesh(BoxGeometry(), MeshBasicMaterial())
    box.position = Vec3(1.4, 0.0, -2.0)
    @test Diff3D.frustum_intersects_object(frustum, box)
    box.position = Vec3(1.9, 0.0, -2.0)
    @test !Diff3D.frustum_intersects_object(frustum, box)
    instances = InstancedMesh(BoxGeometry(), MeshBasicMaterial(), 2)
    set_instance_matrix!(instances, 1, mat4_translation(5.0, 0.0, 0.0))
    set_instance_matrix!(instances, 2, mat4_translation(1.2, 0.0, 0.0))
    instances.position = Vec3(0.0, 0.0, -2.0)
    @test Diff3D.frustum_intersects_object(frustum, instances)
    set_instance_matrix!(instances, 2, mat4_translation(7.0, 0.0, 0.0))
    @test !Diff3D.frustum_intersects_object(frustum, instances)
    @test_throws ArgumentError Diff3D.frustum_intersects_object(frustum, Group())
end

# Scene shared by the Box3.setFromObject and SkinnedMesh frustum oracles
# (rv/part2_oracle.mjs, three.js r186): explicit positions so both sides use
# the same vertices, and dyadic instance matrices because three.js stores
# instance matrices as Float32.
const OBJECT_BOUNDS_POSITIONS = [0.3, -0.2, 0.1, 1.2, 0.4, -0.5, -0.7, 0.9, 0.6,
                                 0.1, 0.2, -1.1, 0.8, -0.6, 0.9]

function object_bounds_scene()
    geometry(values) = BufferGeometry(copy(values), Float64[], Float64[], Int[],
                                      length(values) ÷ 3, 0)
    P = OBJECT_BOUNDS_POSITIONS
    material = MeshBasicMaterial()
    root = Group()
    root.position = Vec3(0.5, -1.0, 2.0); root.rotation = Euler(0.3, -0.7, 0.2)
    root.scale = Vec3(1.5, 0.8, 1.2)
    mesh = Mesh(geometry(P), material)
    mesh.position = Vec3(-1.0, 0.5, 0.25); mesh.rotation = Euler(1.1, 0.2, -0.4)
    add!(root, mesh)
    neg = Mesh(geometry(P), material)
    neg.scale = Vec3(-0.5, 2.0, 1.0); neg.position = Vec3(0.0, 2.0, 0.0)
    add!(mesh, neg)
    morph_geometry = geometry(P)
    morph_geometry.attributes[:morphPosition0] =
        BufferAttribute([(i % 3 == 0 ? 0.5 : -0.25) * (1 + i / 10) for i in 0:14], 3)
    morph = Mesh(morph_geometry, material; morph_target_influences=[0.6])
    morph.position = Vec3(2.0, 0.0, -1.0)
    add!(root, morph)
    points = PointsObject(geometry(P), PointsMaterial())
    points.position = Vec3(0.0, -2.0, 0.0); points.rotation = Euler(0.0, 0.0, 0.9)
    add!(root, points)
    line = LineSegments(geometry(P[1:12]), LineBasicMaterial())
    line.scale = Vec3(2.0, 2.0, 2.0)
    add!(root, line)
    sprite = Sprite(SpriteMaterial())
    sprite.position = Vec3(-2.0, 1.0, 0.5); sprite.scale = Vec3(0.7, 1.3, 1.0)
    add!(root, sprite)
    instances = InstancedMesh(geometry(P), material, 3)
    set_instance_matrix!(instances, 1, mat4_translation(3.0, 0.0, 0.0))
    set_instance_matrix!(instances, 2, Mat4((0.5, 0.25, -0.75, 0.0, -0.25, 1.5, 0.125, 0.0,
                                             0.75, 0.0, 0.5, 0.0, 1.0, -2.0, 0.5, 1.0)))
    set_instance_matrix!(instances, 3,
                         mat4_translation(0.0, 1.0, -2.0) * mat4_scaling(0.5, 1.5, 1.0))
    instances.position = Vec3(0.0, 0.0, 3.0)
    add!(root, instances)
    holder = Group()
    holder.position = Vec3(1.0, 1.0, 1.0); holder.rotation = Euler(0.0, 0.5, 0.0)
    add!(root, holder)
    bone1 = Bone(); bone2 = Bone()
    bone2.position = Vec3(0.0, 1.0, 0.0)
    add!(bone1, bone2); add!(holder, bone1)
    skinned = SkinnedMesh(geometry(P), material, Skeleton([bone1, bone2]),
                          [(1, 1, 1, 1), (2, 1, 1, 1), (1, 1, 1, 1), (2, 1, 1, 1), (2, 1, 1, 1)],
                          [(1.0, 0.0, 0.0, 0.0) for _ in 1:5])
    skinned.position = Vec3(0.2, 0.0, -0.3)
    add!(holder, skinned)
    # SkinnedMesh.bind(skeleton): the bind matrix is the mesh's world matrix.
    bind = compute_world_matrix(skinned)
    skinned.bind_matrix = bind
    skinned.bind_matrix_inverse = mat4_inverse(bind)
    bone2.rotation = Euler(0.0, 0.0, 0.9)
    bone1.position = Vec3(0.3, -0.2, 0.0)
    return (; root, mesh, neg, morph, points, line, sprite, instances, skinned, holder)
end

box_vector(box) = [box.min.x, box.min.y, box.min.z, box.max.x, box.max.y, box.max.z]
bounds_close(actual, expected) =
    all(abs.(actual .- expected) .<= 8 * eps(1.0) .* max.(abs.(expected), 1.0))

@testset "frustum_intersects_object bounds a SkinnedMesh by its posed vertices" begin
    objects = object_bounds_scene()
    skinned = objects.skinned
    # SkinnedMesh.computeBoundingSphere: center and radius in local space.
    sphere = Diff3D._skinned_bounding_sphere(skinned)
    @test bounds_close([sphere.center.x, sphere.center.y, sphere.center.z, sphere.radius],
                       [0.850058500266877, 0.58504331727922, -0.013233831478703807, 1.448914238658236])
    world = sphere_apply_matrix4(sphere, compute_world_matrix(skinned))
    @test bounds_close([world.center.x, world.center.y, world.center.z, world.radius],
                       [2.127629552189309, 0.18361764665544522, 4.165238987379781, 2.081511644511354])
    # Frustum.intersectsObject for cameras (fov 30°) looking down -z at the
    # posed sphere, offset sideways by 0, 4.70 and 4.95, and one looking away.
    c = world.center
    for (eye, target, hit) in (
            (c + Vec3(0.0, 0.0, 10.0), c, true),
            (c + Vec3(10.0, 0.0, 10.0), c + Vec3(20.0, 0.0, 10.0), false),
            (c + Vec3(4.95, 0.0, 10.0), c + Vec3(4.95, 0.0, 0.0), false),
            (c + Vec3(4.70, 0.0, 10.0), c + Vec3(4.70, 0.0, 0.0), true))
        camera = PerspectiveCamera(fov=π / 6, aspect=1.0, near=0.1, far=100.0)
        camera.position = eye
        camera.target = target
        frustum = frustum_from_matrix(projection_matrix(camera) * view_matrix(camera))
        @test Diff3D.frustum_intersects_object(frustum, skinned) == hit
    end
    # The unposed geometry sphere would miss at offset 4.70: the pose matters.
    camera = PerspectiveCamera(fov=π / 6, aspect=1.0, near=0.1, far=100.0)
    camera.position = c + Vec3(4.70, 0.0, 10.0)
    camera.target = c + Vec3(4.70, 0.0, 0.0)
    frustum = frustum_from_matrix(projection_matrix(camera) * view_matrix(camera))
    rest = sphere_apply_matrix4(compute_bounding_sphere(skinned.geometry),
                                compute_world_matrix(skinned))
    @test !frustum_intersects_sphere(frustum, rest)
end

@testset "Box3 constructors, expansion and triangle tests" begin
    lo_hi(box) = (Tuple([box.min.x, box.min.y, box.min.z]), Tuple([box.max.x, box.max.y, box.max.z]))
    # Box3.setFromPoints / setFromArray / setFromCenterAndSize (Box3.js:60-140).
    @test lo_hi(Diff3D.box3_from_points([Vec3(1.0, -2.0, 3.0), Vec3(-4.0, 5.0, 0.5)])) ==
          ((-4.0, -2.0, 0.5), (1.0, 5.0, 3.0))
    @test box3_is_empty(Diff3D.box3_from_points(Vec3{Float64}[]))
    @test lo_hi(Diff3D.box3_from_array([1.0, -2.0, 3.0, -4.0, 5.0, 0.5, 0.0, 0.0, 7.0])) ==
          ((-4.0, -2.0, 0.5), (1.0, 5.0, 7.0))
    @test_throws ArgumentError Diff3D.box3_from_array([1.0, 2.0])
    # Box3.setFromBufferAttribute (Box3.js:86-98); node e/box_attr.mjs.
    @test lo_hi(Diff3D.box3_from_buffer_attribute(BufferAttribute([1.0, 2.0, 0.5, 4.0, -1.0, 3.0], 3))) ==
          ((1.0, -1.0, 0.5), (4.0, 2.0, 3.0))
    # For item size 2 three.js reads z past the item (x and y match node's
    # [-3, 2] .. [1, 4]; its z is NaN); Diff3D uses z = 0 (documented).
    @test lo_hi(Diff3D.box3_from_buffer_attribute(BufferAttribute([1.0, 2.0, -3.0, 4.0], 2))) ==
          ((-3.0, 2.0, 0.0), (1.0, 4.0, 0.0))
    @test lo_hi(Diff3D.box3_from_center_and_size(Vec3(1.0, 2.0, 3.0), Vec3(0.3, 4.0, 5.0))) ==
          ((0.84999999999999998, 0.0, 0.5), (1.1499999999999999, 4.0, 5.5))
    unit = Box3(Vec3(-1.0, -1.0, -1.0), Vec3(1.0, 1.0, 1.0))
    @test lo_hi(Diff3D.box3_expand_by_scalar(unit, 0.25)) ==
          ((-1.25, -1.25, -1.25), (1.25, 1.25, 1.25))
    @test lo_hi(Diff3D.box3_expand_by_vector(unit, Vec3(0.1, 0.2, -0.3))) ==
          ((-1.1000000000000001, -1.2, -0.69999999999999996),
           (1.1000000000000001, 1.2, 0.69999999999999996))
    @test Diff3D.box3_translate(unit, Vec3(1.0, 0.0, -1.0)) ==
          Box3(Vec3(0.0, -1.0, -2.0), Vec3(2.0, 1.0, 0.0))
    @test Diff3D.box3_equals(unit, Box3(Vec3(-1.0, -1.0, -1.0), Vec3(1.0, 1.0, 1.0)))
    @test Diff3D.box3_get_parameter(Box3(Vec3(-1.0, 0.0, 2.0), Vec3(3.0, 0.5, 6.0)),
                                    Vec3(0.3, 0.2, 5.5)) ==
          Vec3(0.32500000000000001, 0.40000000000000002, 0.875)
    @test Diff3D.box3_contains_box(unit, Box3(Vec3(-1.0, 0.0, 0.0), Vec3(1.0, 0.5, 1.0)))
    @test !Diff3D.box3_contains_box(unit, Box3(Vec3(-1.1, 0.0, 0.0), Vec3(1.0, 0.5, 1.0)))
    # Box3.intersectsTriangle (Box3.js:526-576) oracle: [false, true, true, false].
    triangles = [Triangle(Vec3(0.9, 0.9, 2.0), Vec3(2.0, 0.95, 0.0), Vec3(0.95, 2.0, -1.0)),
                 Triangle(Vec3(0.5, 0.5, 3.0), Vec3(0.5, -0.5, 3.0), Vec3(-0.5, 0.0, 0.5)),
                 Triangle(Vec3(2.0, 0.0, 0.0), Vec3(0.0, 2.0, 0.0), Vec3(0.0, 0.0, 2.0)),
                 Triangle(Vec3(1.2, 1.2, 1.2), Vec3(3.0, 0.0, 0.0), Vec3(0.0, 3.0, 0.0))]
    @test [Diff3D.box3_intersects_triangle(unit, t) for t in triangles] == [false, true, true, false]
    @test [Diff3D.triangle_intersects_box(t, unit) for t in triangles] == [false, true, true, false]
    @test !Diff3D.box3_intersects_triangle(Box3(), triangles[3])
end

@testset "Triangle interpolation" begin
    # Triangle.getInterpolation (Triangle.js).
    tri = Triangle(Vec3(0.0, 0.0, 0.0), Vec3(2.0, 0.0, 0.0), Vec3(0.0, 3.0, 0.0))
    value = Diff3D.triangle_interpolation(tri, Vec3(0.5, 1.0, 0.0), Vec3(1.0, 0.0, 0.0),
                                          Vec3(0.0, 1.0, 0.0), Vec3(0.0, 0.0, 1.0))
    @test all(isapprox.((value.x, value.y, value.z),
                        (0.41666666666666674, 0.25, 0.33333333333333331)))
    uv = Diff3D.triangle_interpolation(tri, Vec3(0.5, 1.0, 0.0), Vec2(1.0, 2.0),
                                       Vec2(3.0, 5.0), Vec2(-1.0, 0.0))
    @test all(isapprox.((uv.x, uv.y), (0.83333333333333348, 2.0833333333333335)))
    degenerate = Triangle(Vec3(0.0, 0.0, 0.0), Vec3(1.0, 1.0, 1.0), Vec3(2.0, 2.0, 2.0))
    @test Diff3D.triangle_interpolation(degenerate, Vec3(0.5, 0.5, 0.5), 1.0, 2.0, 3.0) === nothing
end

@testset "Matrix4 rotation builders and scale" begin
    angles = (0.3, -1.1, 2.5)
    oracle = Dict(
        :XYZ => (-0.36339563671695296, 0.78273929734520420, -0.50523539425362540, -0.27146464334680381, -0.60774225010406213, -0.74629505214160707, -0.89120736006143542, -0.13404681954446868, 0.43333692612370311),
        :YXZ => (-0.52101511557489255, 0.57174227698774749, -0.63376179913856201, -0.060467622989347131, -0.76536172896200183, -0.64075353327961693, -0.85140291044399152, -0.29552020666133955, 0.43333692612370311),
        :ZXY => (-0.20577615785901332, 0.48246166370426047, 0.85140291044399152, -0.57174227698774749, -0.76536172896200183, 0.29552020666133955, 0.79420837414475054, -0.42597202595477091, 0.43333692612370311),
        :ZYX => (-0.36339563671695296, 0.27146464334680381, 0.89120736006143542, -0.36074525663029078, -0.92298120781994153, 0.13404681954446868, 0.85895661766693765, -0.27278679847792187, 0.43333692612370311),
        :YZX => (-0.36339563671695296, 0.59847214410395644, -0.71398508664165627, -0.52270986252013252, -0.76536172896200183, -0.37549410576529568, -0.77117962294089726, 0.23675412683184260, 0.59095640498164270),
        :XZY => (-0.36339563671695296, -0.0040297039267918611, 0.93162619794708579, -0.59847214410395644, -0.76536172896200183, -0.23675412683184260, 0.71398508664165627, -0.64358774485423309, 0.27571744726576347))
    for (order, m) in oracle
        # Matrix4.makeRotationFromEuler (Matrix4.js:338-466), entry by entry.
        rotation = Diff3D.mat4_rotation_from_euler(Euler(angles..., order))
        @test rotation == oracle_mat4(m[1], m[2], m[3], 0.0, m[4], m[5], m[6], 0.0,
                                      m[7], m[8], m[9], 0.0, 0.0, 0.0, 0.0, 1.0)
    end
    @test_throws ArgumentError Diff3D.mat4_rotation_from_euler(Euler(0.0, 0.0, 0.0, :XYX))
    # makeRotationFromQuaternion = compose(0, q, 1) (Matrix4.js:468-472).
    q = quat_normalize(Quaternion(0.1, 0.2, 0.3, 0.9))
    @test all(isapprox.(Diff3D.mat4_rotation_from_quaternion(q).e, oracle_mat4(0.72631578947368425, 0.61052631578947358, -0.31578947368421045, 0.0,
                      -0.52631578947368407, 0.78947368421052633, 0.31578947368421045, 0.0,
                      0.44210526315789461, -0.063157894736842080, 0.89473684210526316, 0.0,
                      0.0, 0.0, 0.0, 1.0).e; atol=1e-15))
    # Matrix4.scale (Matrix4.js:794-806) scales the first three columns.
    m = mat4_set_position(Diff3D.mat4_rotation_from_euler(Euler(0.3, -1.1, 2.5, :XYZ)),
                          Vec3(1.0, 2.0, 3.0))
    # Element 7 is 0 * -0.5 = -0.0 in three.js too; JSON prints it as 0, so
    # compare the tuples with ==, which equates the signed zeros.
    @test Diff3D.mat4_scale(m, Vec3(2.0, -0.5, 3.0)).e ==
          oracle_mat4(-0.72679127343390593, 1.5654785946904084, -1.0104707885072508, 0.0,
                      0.13573232167340191, 0.30387112505203107, 0.37314752607080354, 0.0,
                      -2.6736220801843062, -0.40214045863340603, 1.3000107783711092, 0.0,
                      1.0, 2.0, 3.0, 1.0).e
    a = mat4_translation(1.0, 2.0, 3.0)
    @test Diff3D.mat4_premultiply(m, a) == a * m
end

@testset "Quaternion random and proper Euler angles" begin
    # Quaternion.random (Quaternion.js:782-802) with Math.random -> 0.1, 0.7, 0.35.
    draws = Iterators.Stateful([0.1, 0.7, 0.35])
    q = Diff3D.quat_random(random=() -> popfirst!(draws))
    @test (q.x, q.y, q.z, q.w) == (0.47388762046306099, 0.65225035314046242,
                                   -0.56265262286389084, -0.18281691930558350)
    # MathUtils.setQuaternionFromProperEuler(q, 0.4, -0.9, 1.7, order).
    oracle = Dict(:XYX => (0.78106872999954491, -0.34626901463318710, 0.26323522820783213, 0.44803640828869057),
                  :YZY => (0.26323522820783213, 0.78106872999954491, -0.34626901463318710, 0.44803640828869057),
                  :ZXZ => (-0.34626901463318710, 0.26323522820783213, 0.78106872999954491, 0.44803640828869057),
                  :XZX => (0.78106872999954491, -0.26323522820783213, -0.34626901463318710, 0.44803640828869057),
                  :YXY => (-0.34626901463318710, 0.78106872999954491, -0.26323522820783213, 0.44803640828869057),
                  :ZYZ => (-0.26323522820783213, -0.34626901463318710, 0.78106872999954491, 0.44803640828869057))
    for (order, expected) in oracle
        p = Diff3D.quat_from_proper_euler(0.4, -0.9, 1.7, order)
        # V8's Math.sin((a - c) / 2) here is 1 ulp from the correctly rounded
        # value Julia's sin returns (checked against BigFloat), so one
        # component of each order differs from node by 1 ulp.
        @test all(isapprox.((p.x, p.y, p.z, p.w), expected; rtol=2eps()))
    end
    @test_throws ArgumentError Diff3D.quat_from_proper_euler(0.0, 0.0, 0.0, :XYZ)
end

@testset "MathUtils random, modulo, power-of-two and normalization helpers" begin
    # MathUtils.seededRandom (Mulberry32): seededRandom(42), (), (), (7), ().
    @test Diff3D.seeded_random(42) == 0.60110375192016363
    @test Diff3D.seeded_random() == 0.44829055899754167
    @test Diff3D.seeded_random() == 0.85246579349040985
    @test Diff3D.seeded_random(7) == 0.011704753153026104
    @test Diff3D.seeded_random() == 0.061958257574588060
    @test Diff3D.euclidean_modulo(-0.7, 1) == 0.30000000000000004
    @test Diff3D.euclidean_modulo(5.5, -2) == -0.5
    @test Diff3D.euclidean_modulo(-3, 3) == 0 && Diff3D.euclidean_modulo(7, 3) == 1
    @test Diff3D.deg_to_rad(30.0) == 0.52359877559829882
    @test Diff3D.rad_to_deg(1.0) == 57.295779513082323
    @test Diff3D.is_power_of_two(64) && !Diff3D.is_power_of_two(0) &&
          !Diff3D.is_power_of_two(12)
    @test Diff3D.ceil_power_of_two(65) == 128 && Diff3D.ceil_power_of_two(0.3) == 0.5 &&
          Diff3D.ceil_power_of_two(64) == 64
    @test Diff3D.floor_power_of_two(65) == 64 && Diff3D.floor_power_of_two(0.3) == 0.25
    # MathUtils.js:290: integer-valued numbers count, fractions do not
    # (node: isPowerOfTwo(4.0) true, (2**60) true, (0.5) false, (6) false).
    @test Diff3D.is_power_of_two(4.0) && Diff3D.is_power_of_two(2.0^60) &&
          !Diff3D.is_power_of_two(0.5) && !Diff3D.is_power_of_two(6.0)
    # MathUtils.js:302 gives ceilPowerOfTwo(2**29) = 2**30 through
    # Math.log(v) / Math.LN2; Diff3D's exponent is exact (documented).
    @test Diff3D.ceil_power_of_two(2.0^29) == 2.0^29
    @test Diff3D.floor_power_of_two(1000) == 512 && Diff3D.ceil_power_of_two(1000) == 1024
    @test Diff3D.ceil_power_of_two(3e-320) == ldexp(1.0, -1061) &&
          Diff3D.floor_power_of_two(nextfloat(0.0)) == nextfloat(0.0)
    @test_throws DomainError Diff3D.ceil_power_of_two(0.0)
    # randInt(-3,4), randInt(-3,4), randFloat(2,5), randFloatSpread(4) with
    # Math.random -> 0.2, 0.9999, 0.5, 0.0.
    draws = Iterators.Stateful([0.2, 0.9999, 0.5, 0.0])
    random = () -> popfirst!(draws)
    @test Diff3D.rand_int(-3, 4; random) == -2
    @test Diff3D.rand_int(-3, 4; random) == 4
    @test Diff3D.rand_float(2, 5; random) == 3.5
    @test Diff3D.rand_float_spread(4; random) == 2
    draws = Iterators.Stateful([0.123456789, 0.987654321, 0.5, 0.25])
    @test Diff3D.generate_uuid(random=() -> popfirst!(draws)) ==
          "37dd9a1f-dfe9-46fc-bfff-ff7fffffff3f"
    @test occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                   Diff3D.generate_uuid())
    # MathUtils.normalize / denormalize (MathUtils.js:383-470).
    @test Diff3D.normalize_component(0.5, UInt8) == 128
    @test Diff3D.normalize_component(-0.25, Int16) == -8192
    @test Diff3D.normalize_component(0.3, Float32) == 0.3
    @test Diff3D.denormalize_component(200, UInt8) == 0.78431372549019607
    @test Diff3D.denormalize_component(-128, Int8) == -1.0
    @test Diff3D.denormalize_component(1000, UInt16) == 0.015259021896696421
    @test_throws ArgumentError Diff3D.normalize_component(0.5, Int64)
    @test_throws ArgumentError Diff3D.denormalize_component(0.5, Float64)
end

# ---------------------------------------------------------------------------
# (f) StereoCamera aspect multiplier
# ---------------------------------------------------------------------------

@testset "StereoCamera aspect_multiplier is three.js StereoCamera.aspect" begin
    camera = PerspectiveCamera(fov=deg2rad(60), aspect=1.6, near=0.3, far=50.0, zoom=1.5)
    camera.focus = 4.0
    camera.position = Vec3(0.5, 1.0, 6.0)
    camera.target = Vec3(0.5, 1.0, 5.0)
    # Oracle: StereoCamera.update (StereoCamera.js:85-145) with eyeSep 0.1 and
    # aspect 1, 0.5, 2.25 (f/stereo_oracle.mjs): elements 0 and 8 of the eye
    # projections; the other elements are those of the camera.
    oracle = Dict(1.0 => (1.6237976320958225, 0.020297470401197802),
                  0.5 => (3.2475952641916450, 0.040594940802395604),
                  2.25 => (0.72168783648703227, 0.0090210979560878448))
    for (multiplier, (e0, e8)) in oracle
        stereo = StereoCamera(eye_sep=0.1, aspect_multiplier=multiplier)
        @test stereo.aspect_multiplier === multiplier
        stereo_update!(stereo, camera)
        @test stereo.cameraL.aspect == camera.aspect * multiplier
        left = projection_matrix(stereo.cameraL)
        right = projection_matrix(stereo.cameraR)
        @test left.e[1] ≈ e0 && left.e[9] ≈ e8
        @test right.e[1] ≈ e0 && right.e[9] ≈ -e8
        @test left.e[6] ≈ 2.5980762113533165 && left.e[11] ≈ -1.0120724346076457
    end
    # The default multiplier keeps the eyes' projections bit for bit.
    legacy = StereoCamera(0.1, PerspectiveCamera(), PerspectiveCamera())
    @test legacy.aspect_multiplier === 1.0
    fresh = StereoCamera(eye_sep=0.1)
    stereo_update!(legacy, camera)
    stereo_update!(fresh, camera)
    @test projection_matrix(legacy.cameraL) == projection_matrix(fresh.cameraL)
    @test_throws ArgumentError StereoCamera(aspect_multiplier=0.0)
    @test_throws ArgumentError StereoCamera(aspect_multiplier=Inf)
    bad = StereoCamera()
    bad.aspect_multiplier = -1.0
    @test_throws ArgumentError stereo_update!(bad, camera)
end
