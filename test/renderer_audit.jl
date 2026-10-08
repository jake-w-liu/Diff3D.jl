using Test
using Diff3D

function renderer_audit_ortho()
    camera = OrthographicCamera(left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                                near=0.1, far=10.0)
    camera.position = Vec3(0.0, 0.0, 2.0)
    return camera
end

function renderer_audit_center(object; draw=render!, background=Color3(0.0, 0.0, 1.0))
    scene = Scene(background=background)
    add!(scene, object)
    target = RenderTarget(32, 32)
    clear!(target, background)
    draw(target, scene, renderer_audit_ortho())
    return target.color[16, 16, :]
end

function renderer_audit_points(positions...)
    geometry = BufferGeometry()
    geometry.positions = Float64[p for v in positions for p in v]
    geometry.n_vertices = length(positions)
    return geometry
end

@testset "Primitives blend only when their material is transparent" begin
    red = Color3(1.0, 0.0, 0.0)
    rgba = zeros(1, 1, 4); rgba[:, :, 1] .= 1.0; rgba[:, :, 4] .= 0.5
    half_alpha = Texture(rgba; filter=:nearest, colorspace=:linear)
    mask = ones(1, 1, 3); mask[:, :, 2] .= 0.5
    half_mask = Texture(mask; filter=:nearest, colorspace=:linear)
    point_geo = renderer_audit_points((0.0, 0.0, 0.0))
    builders = (
        transparent -> PointsObject(point_geo, PointsMaterial(
            color=red, size=5.0, opacity=0.5, transparent=transparent)),
        transparent -> PointsObject(point_geo, PointsMaterial(
            size=5.0, map=half_alpha, transparent=transparent)),
        transparent -> PointsObject(point_geo, PointsMaterial(
            color=red, size=5.0, alpha_map=half_mask, transparent=transparent)),
        transparent -> InstancedMesh(point_geo, PointsMaterial(
            color=red, size=5.0, opacity=0.5, transparent=transparent), 1;
            draw_mode=:points),
        transparent -> Sprite(SpriteMaterial(
            color=red, opacity=0.5, transparent=transparent)),
        transparent -> Sprite(SpriteMaterial(map=half_alpha, transparent=transparent)),
        transparent -> Sprite(SpriteMaterial(
            color=red, alpha_map=half_mask, transparent=transparent)),
        transparent -> Mesh(PlaneGeometry(width=1.5, height=1.5), MeshBasicMaterial(
            color=red, wireframe=true, opacity=0.5, transparent=transparent)),
        transparent -> InstancedMesh(PlaneGeometry(width=1.5, height=1.5),
            MeshBasicMaterial(color=red, wireframe=true, opacity=0.5,
                              transparent=transparent), 1),
    )
    # WebGLRenderLists.push sends only `material.transparent === true` items to
    # the blended list; WebGLState.setMaterial selects NoBlending otherwise.
    function red_pixels(object, draw)
        scene = Scene(background=Color3(0.0, 0.0, 1.0)); add!(scene, object)
        target = RenderTarget(32, 32); clear!(target, Color3(0.0, 0.0, 1.0))
        draw(target, scene, renderer_audit_ortho())
        return [(target.color[i, j, 1], target.color[i, j, 3])
                for i in 1:32, j in 1:32 if target.color[i, j, 1] > 0.0]
    end
    for build in builders
        object = build(false)
        direct = object isa Sprite ? render_sprites! :
                 object isa PointsObject || (object isa InstancedMesh &&
                     !material_wireframe(object.material)) ? render_points! : nothing
        for draw in (direct === nothing ? (render!,) : (render!, direct))
            reds = red_pixels(object, draw)
            @test !isempty(reds)
            @test all(==((1.0, 0.0)), reds)
        end
        reds = red_pixels(build(true), render!)
        @test all(c -> c[2] > 0.0, reds)
        @test any(c -> c[1] ≈ 0.5 && c[2] ≈ 0.5, reds)
    end
    # alphaTest still discards opaque primitives using opacity × texture alpha.
    tested = PointsObject(point_geo, PointsMaterial(
        size=5.0, map=half_alpha, alpha_test=0.75))
    @test renderer_audit_center(tested) == [0.0, 0.0, 1.0]
    tested_sprite = Sprite(SpriteMaterial(color=red, opacity=0.4, alpha_test=0.5))
    @test renderer_audit_center(tested_sprite) == [0.0, 0.0, 1.0]
    kept_sprite = Sprite(SpriteMaterial(color=red, opacity=0.6, alpha_test=0.5))
    @test renderer_audit_center(kept_sprite) == [1.0, 0.0, 0.0]
    @test !Diff3D._render_primitive_blends(Sprite(SpriteMaterial(map=half_alpha)))
    @test Diff3D._render_primitive_blends(Sprite(SpriteMaterial(map=half_alpha,
                                                                transparent=true)))
    # Line materials expose no `transparent` flag; opacity keeps selecting blending.
    line = LineObject(renderer_audit_points((-0.75, 0.0, 0.0), (0.75, 0.0, 0.0)),
                      LineBasicMaterial(color=red, linewidth=3.0, opacity=0.5))
    @test renderer_audit_center(line) ≈ [0.5, 0.0, 0.5]
end

@testset "Opaque mesh alphaTest uses material opacity" begin
    red = Color3(1.0, 0.0, 0.0)
    blue = [0.0, 0.0, 1.0]
    rgba = ones(1, 1, 4); rgba[:, :, 2:3] .= 0.0; rgba[:, :, 4] .= 0.5
    half_alpha = Texture(rgba; filter=:nearest, colorspace=:linear)
    function center_with(material; mode=:flat, instanced=false)
        geometry = PlaneGeometry(width=1.5, height=1.5)
        object = instanced ? InstancedMesh(geometry, material, 1) : Mesh(geometry, material)
        scene = Scene(background=Color3(0.0, 0.0, 1.0)); add!(scene, object)
        target = RenderTarget(32, 32)
        camera = renderer_audit_ortho()
        if mode === :pooled
            render_pooled!(target, scene, camera, RenderCache())
        elseif mode === :tiled
            render_tiled!(target, scene, camera; tiles=2)
        else
            render!(target, scene, camera; shading=mode)
        end
        return target.color[16, 16, :]
    end
    # three.js: diffuseColor.a = opacity · map.a · alphaMap; discard if below alphaTest.
    for mode in (:flat, :smooth, :pooled, :tiled), instanced in (false, true)
        @test center_with(MeshBasicMaterial(color=red, opacity=0.3, alpha_test=0.5);
                          mode, instanced) == blue
        @test center_with(MeshBasicMaterial(color=red, opacity=0.6, alpha_test=0.5);
                          mode, instanced) == [1.0, 0.0, 0.0]
        @test center_with(MeshBasicMaterial(map=half_alpha, opacity=0.9);
                          mode, instanced) == [1.0, 0.0, 0.0]
        @test center_with(MeshBasicMaterial(map=half_alpha, opacity=0.9, alpha_test=0.5);
                          mode, instanced) == blue
        @test center_with(MeshBasicMaterial(map=half_alpha, alpha_test=0.4);
                          mode, instanced) == [1.0, 0.0, 0.0]
    end
end
