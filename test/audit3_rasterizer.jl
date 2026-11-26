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
