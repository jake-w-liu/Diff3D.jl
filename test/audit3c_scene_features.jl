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
