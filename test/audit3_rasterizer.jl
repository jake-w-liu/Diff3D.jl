using Test, Diff3D

function audit3_mirror_camera()
    camera = PerspectiveCamera()
    camera.position = Vec3(0.0, 0.0, 4.0)
    return camera
end

function audit3_same_surface(a, b)
    isinf.(a.depth) == isinf.(b.depth) || return false
    finite = isfinite.(a.depth)
    any(finite) || return false
    return maximum(abs.(a.depth[finite] .- b.depth[finite])) <= 1e-12
end

@testset "Mirrored world matrices keep three.js front faces" begin
    # three.js WebGLRenderer.js:1200 sets frontFaceCW when
    # matrixWorld.determinantAffine() < 0 and WebGLState.js:761 flips the
    # front face, so a mirrored box still shows its near (outer) faces. The
    # unmirrored box is the reference: mirroring a box about x is the same set
    # of world-space faces, so coverage must match and depth may differ only by
    # rounding of the mirrored vertex coordinates.
    camera = audit3_mirror_camera()
    for shading in (:flat, :smooth)
        scene = Scene()
        box = Mesh(BoxGeometry(), MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0)))
        add!(scene, box)
        reference = RenderTarget(32, 32)
        render!(reference, scene, camera; shading=shading)
        box.scale = Vec3(-1.0, 1.0, 1.0)
        mirrored = RenderTarget(32, 32)
        render!(mirrored, scene, camera; shading=shading)
        @test audit3_same_surface(mirrored, reference)
    end
    scene = Scene()
    box = Mesh(BoxGeometry(), MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0)))
    add!(scene, box)
    reference = RenderTarget(32, 32)
    render_pooled!(reference, scene, camera, RenderCache())
    box.scale = Vec3(-1.0, 1.0, 1.0)
    pooled = RenderTarget(32, 32)
    render_pooled!(pooled, scene, camera, RenderCache())
    @test audit3_same_surface(pooled, reference)
    tiled = RenderTarget(32, 32)
    render_tiled!(tiled, scene, camera)
    @test audit3_same_surface(tiled, reference)
end

function audit3_reflected_triangle_scene(side; instanced)
    geometry = BufferGeometry([-0.8, -0.8, 0.0, 0.8, -0.8, 0.0, 0.0, 0.8, 0.0],
                              repeat([0.0, 0.0, 1.0], 3), Float64[], [1, 2, 3], 3, 1)
    material = MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), side=side)
    scene = Scene()
    if instanced
        object = InstancedMesh(geometry, material, 1)
        set_instance_matrix!(object, 1, mat4_scaling(-1.0, 1.0, 1.0))
    else
        object = Mesh(geometry, material)
        object.scale = Vec3(-1.0, 1.0, 1.0)
    end
    add!(scene, object)
    return scene
end

@testset "Mirror culling uses the object matrix, not instance matrices" begin
    # WebGLRenderer.js:1200 tests object.matrixWorld.determinantAffine() only.
    # A mirrored Mesh therefore keeps its camera-facing triangle front-facing
    # (drawn with side=:front, culled with :back), while a mirror applied by an
    # InstancedMesh instance matrix flips the screen winding without flipping
    # frontFace (culled with :front, drawn with :back).
    perspective = PerspectiveCamera(fov=pi / 3, aspect=1.0, near=0.1, far=10.0)
    perspective.position = Vec3(0.0, 0.0, 3.0)
    orthographic = OrthographicCamera(left=-1.0, right=1.0, bottom=-1.0,
                                      top=1.0, near=0.1, far=10.0)
    orthographic.position = Vec3(0.0, 0.0, 3.0)
    drawn(target) = sum(target.color) > 0
    for camera in (perspective, orthographic), shading in (:flat, :smooth),
        side in (:front, :back), instanced in (false, true)
        target = RenderTarget(24, 24)
        render!(target, audit3_reflected_triangle_scene(side; instanced=instanced),
                camera; shading=shading, frustum_cull=false)
        @test drawn(target) == ((side === :front) != instanced)
    end
    for side in (:front, :back), instanced in (false, true)
        scene = audit3_reflected_triangle_scene(side; instanced=instanced)
        pooled = RenderTarget(24, 24)
        render_pooled!(pooled, scene, orthographic, RenderCache())
        @test drawn(pooled) == ((side === :front) != instanced)
        tiled = RenderTarget(24, 24)
        render_tiled!(tiled, scene, orthographic; tiles=1, cache=[RenderCache()])
        @test drawn(tiled) == ((side === :front) != instanced)
    end
end

@testset "Mirrored double-sided faces keep their lit normal" begin
    # A plane facing the camera mirrored about x still faces +z: the normal
    # matrix maps (0,0,1) to (0,0,1) and gl_FrontFacing is true under the
    # flipped front face, so `normal *= faceDirection` keeps it lit
    # (normal_fragment_begin.glsl.js, DOUBLE_SIDED). Lambert under a unit
    # directional light along the normal gives 1/pi (BRDF_Lambert).
    camera = audit3_mirror_camera()
    for shading in (:flat, :smooth)
        scene = Scene()
        plane = Mesh(PlaneGeometry(),
                     MeshLambertMaterial(color=Color3(1.0, 1.0, 1.0), side=:double))
        plane.scale = Vec3(-1.0, 1.0, 1.0)
        add!(scene, plane)
        light = DirectionalLight(intensity=1.0)
        light.position = Vec3(0.0, 0.0, 5.0)
        add!(scene, light)
        target = RenderTarget(32, 32)
        render!(target, scene, camera; shading=shading)
        @test target.color[16, 16, 1] ≈ 1 / π
    end
end

function audit3_front_camera()
    camera = PerspectiveCamera()
    camera.position = Vec3(0.0, 0.0, 4.0)
    return camera
end

@testset "Transparent order uses the world bounding-sphere centre" begin
    # three.js projectObject sorts by the clip z of
    # geometry.boundingSphere.center transformed by matrixWorld
    # (WebGLRenderer.js:1919-1935), not by the object origin. A's origin is
    # nearer (z=1) but its geometry sits at world z=-2, behind B at z=0, so
    # three.js draws A first (node oracle: transparent order ["A","B"]).
    # Source-over on black: A gives (0.5,0,0); B over it gives (0.25,0.5,0).
    scene = Scene()
    shifted = PlaneGeometry()
    shifted.positions[3:3:end] .-= 3.0
    a = Mesh(shifted, MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0),
                                        transparent=true, opacity=0.5))
    a.position = Vec3(0.0, 0.0, 1.0)
    b = Mesh(PlaneGeometry(), MeshBasicMaterial(color=Color3(0.0, 1.0, 0.0),
                                                transparent=true, opacity=0.5))
    add!(scene, a)
    add!(scene, b)
    for cache in (nothing, RenderCache())
        target = RenderTarget(32, 32)
        render!(target, scene, audit3_front_camera(); cache=cache)
        @test target.color[16, 16, :] ≈ [0.25, 0.5, 0.0] atol=1e-12
    end
end

@testset "Equal-depth transparent objects draw in object id order" begin
    # three.js reversePainterSortStable (WebGLRenderLists.js:31-51) breaks
    # depth ties by ascending id. Node oracle (WebGLRenderLists push/sort with
    # these depths, objects created T1..T12) gives this draw order.
    zs = [0.0, 0.0, -1.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0]
    oracle = [3, 6, 10, 1, 2, 4, 5, 7, 8, 9, 11, 12]
    colors = [Color3(i / 12, 1 - i / 12, (i % 3) / 2) for i in 1:12]
    scene = Scene()
    for (i, z) in enumerate(zs)
        mesh = Mesh(PlaneGeometry(),
                    MeshBasicMaterial(color=colors[i], transparent=true,
                                      opacity=0.5, depth_write=false))
        mesh.position = Vec3(0.0, 0.0, z)
        add!(scene, mesh)
    end
    expected = zeros(3)
    for i in oracle
        expected .= 0.5 .* expected .+ 0.5 .* [colors[i].r, colors[i].g, colors[i].b]
    end
    for cache in (nothing, RenderCache())
        target = RenderTarget(32, 32)
        render!(target, scene, audit3_front_camera(); cache=cache)
        @test target.color[16, 16, :] ≈ expected atol=1e-12
    end
end

@testset "Opaque depth ties do not depend on the render cache" begin
    # Coplanar opaque meshes tie in depth; the strict depth test keeps the
    # first drawn. Draw order is nearest first with ties in ascending id
    # (three.js painterSortStable, WebGLRenderLists.js:1-29), so mesh 2 (the
    # lowest id at z=0) keeps the pixel with or without a RenderCache.
    for zs in ([-1.0, 0.0, 0.0, 0.0, -1.0], [-1.0, -1.0, 0.0, 0.0, 0.0, -1.0, 0.0])
        scene = Scene()
        for (i, z) in enumerate(zs)
            mesh = Mesh(PlaneGeometry(),
                        MeshBasicMaterial(color=Color3(i / length(zs), 0.0, 0.0)))
            mesh.position = Vec3(0.0, 0.0, z)
            add!(scene, mesh)
        end
        first_near = findfirst(iszero, zs)
        for cache in (nothing, RenderCache())
            target = RenderTarget(8, 8)
            render!(target, scene, audit3_front_camera(); cache=cache)
            @test target.color[4, 4, 1] == first_near / length(zs)
        end
    end
end

# Low-discrepancy sequence in [0, 1) for deterministic sweeps.
audit3_unit(k, step) = mod(k * step, 1.0)

@testset "Shared edges through pixel centres are covered exactly once" begin
    # A sample on an edge shared by two triangles belongs to exactly one of them
    # (WebGL/GLES 2.0 sec. 3.5.1, point sampling of polygons). Grid cells of a
    # subdivided plane are 5 px wide with diagonals through pixel centres; the
    # screen coordinates are inexact binary fractions. A single transparent
    # layer over black must give exactly 0.5 at every interior pixel (a crack
    # leaves 0, a double blend gives 0.75); an opaque layer must give 1.
    camera = OrthographicCamera(left=-1.0, right=1.0, top=1.0, bottom=-1.0,
                                near=0.1, far=10.0)
    camera.position = Vec3(0.0, 0.0, 5.0)
    for transparent in (false, true), offset in (0.05, 0.45), cell in (5, 7)
        segments = 6
        size = segments * cell / 32
        left = (8 + offset) / 32 - 1
        top = 1 - (8 + offset) / 32
        material = transparent ?
            MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), transparent=true,
                              opacity=0.5, depth_write=false) :
            MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0))
        plane = Mesh(PlaneGeometry(width=size, height=size,
                                   width_segments=segments,
                                   height_segments=segments), material)
        plane.position = Vec3(left + size / 2, top - size / 2, 0.0)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, plane)
        target = RenderTarget(64, 64)
        render!(target, scene, camera)
        expected = transparent ? 0.5 : 1.0
        lo = 8 + offset + 1
        hi = 8 + offset + segments * cell - 1
        interior = [target.color[py, px, 1] for px in 1:64, py in 1:64
                    if lo < px - 0.5 < hi && lo < py - 0.5 < hi]
        @test !isempty(interior)
        @test all(==(expected), interior)
    end
end

@testset "Near-clipped shared edges stay watertight" begin
    # Two triangles share an edge that crosses the near plane and projects onto
    # the pixel-centre column x = 20.5 (camera at the origin, fov 90 degrees,
    # near 1). Both clipped polygons must place the crossing vertex at the same
    # point, so every pixel strictly inside the shared segment is blended
    # exactly once (0.5 over black).
    camera = PerspectiveCamera(fov=pi / 2, aspect=1.0, near=1.0, far=100.0)
    camera.position = Vec3(0.0, 0.0, 0.0)
    camera.target = Vec3(0.0, 0.0, -1.0)
    slope = 1 - 20.5 / 32
    checked = 0
    defects = 0
    for k in 1:400
        za = -0.2 - 0.7 * audit3_unit(k, 0.6180339887498949)
        zb = -2.0 - 8.0 * audit3_unit(k, 0.7548776662466927)
        ya = (audit3_unit(k, 0.5698402909980532) - 0.5) * -za
        yb = (audit3_unit(k, 0.8191725133961645) - 0.5) * -zb
        positions = [-slope * -za, ya, za, -slope * -zb, yb, zb,
                     -0.9 * -zb, 0.0, zb, 0.5 * -zb, 0.0, zb]
        geometry = BufferGeometry(positions, Float64[], Float64[],
                                  [1, 2, 3, 2, 1, 4], 4, 2)
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, Mesh(geometry, MeshBasicMaterial(
            color=Color3(1.0, 1.0, 1.0), transparent=true, opacity=0.5,
            depth_write=false, side=:double)))
        target = RenderTarget(64, 64)
        render!(target, scene, camera; frustum_cull=false)
        t = (-1 - za) / (zb - za)
        y_near = (1 - (ya + (yb - ya) * t)) * 32
        y_far = (1 - yb / -zb) * 32
        lo, hi = minmax(y_near, y_far)
        for py in 1:64
            lo + 1 < py - 0.5 < hi - 1 || continue
            checked += 1
            target.color[py, 21, 1] == 0.5 || (defects += 1)
        end
    end
    @test checked > 1000
    @test defects == 0
end

function audit3_cached_frame_allocations(target, scene, camera, cache, shading)
    render!(target, scene, camera; shading=shading, cache=cache)
    return @allocated render!(target, scene, camera; shading=shading, cache=cache)
end

@testset "Cached frames with many meshes do not allocate per mesh" begin
    # Mirror flags, bounding-sphere sort depths and id tie-breaks are computed
    # without per-mesh heap work; a cached frame stays bounded as meshes grow.
    for count in (1, 40), shading in (:flat, :smooth), transparent in (false, true)
        scene = Scene()
        add!(scene, AmbientLight(intensity=0.5))
        light = DirectionalLight(intensity=1.0)
        light.position = Vec3(1.0, 2.0, 3.0)
        add!(scene, light)
        for index in 1:count
            mesh = Mesh(SphereGeometry(radius=0.1, width_segments=8, height_segments=6),
                        MeshLambertMaterial(color=Color3(0.8, 0.5, 0.2),
                                            transparent=transparent, opacity=0.6))
            mesh.position = Vec3(0.3 * (index % 7) - 0.9, 0.3 * (index ÷ 7) - 0.9,
                                 -0.01 * index)
            index % 3 == 0 && (mesh.scale = Vec3(-1.0, 1.0, 1.0))
            add!(scene, mesh)
        end
        camera = audit3_front_camera()
        target = RenderTarget(48, 48)
        cache = RenderCache()
        render!(target, scene, camera; shading=shading, cache=cache)
        @test any(>(0.0), target.color)
        if Base.JLOptions().opt_level > 0
            audit3_cached_frame_allocations(target, scene, camera, cache, shading)
            @test audit3_cached_frame_allocations(
                target, scene, camera, cache, shading) <= 512
        end
    end
end

@testset "Transparent double-sided meshes draw back faces before front faces" begin
    # WebGLRenderer.js:2165-2175 renders a transparent DoubleSide material as a
    # BackSide pass followed by a FrontSide pass. With depth_write=true (the
    # three.js default) the far hemisphere must still be blended first:
    # 0.5 * red over black, then 0.5 * red over that, giving 0.75 inside the
    # silhouette (sphere radius 1 at distance 4 spans ~8.9 px from the centre).
    camera = audit3_front_camera()
    for shading in (:flat, :smooth), depth_write in (true, false), cache in (nothing, RenderCache())
        scene = Scene(background=Color3(0.0, 0.0, 0.0))
        add!(scene, Mesh(SphereGeometry(radius=1.0, width_segments=16, height_segments=12),
                         MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0), transparent=true,
                                           opacity=0.5, side=:double,
                                           depth_write=depth_write)))
        target = RenderTarget(32, 32)
        render!(target, scene, camera; shading=shading, cache=cache)
        core = [target.color[py, px, 1] for px in 1:32, py in 1:32
                if hypot(px - 0.5 - 16, py - 0.5 - 16) < 6]
        @test length(core) > 100
        @test all(≈(0.75; atol=1e-12), core)
    end
end
