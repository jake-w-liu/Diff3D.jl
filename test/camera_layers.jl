using Test
using Diff3D

@testset "Camera layers select scene drawables and lights" begin
    camera = PerspectiveCamera()
    scene = Scene()
    parent = Group()
    layers_set!(object_layers(parent), 7)
    mesh = Mesh(PlaneGeometry(width=1.5,height=1.5), MeshBasicMaterial())
    add!(parent,mesh)
    add!(scene,parent)
    cache = RenderCache()
    for channel in (0,1,31)
        layers_set!(object_layers(mesh),channel)
        for camera_channel in (0,1,31)
            layers_set!(object_layers(camera),camera_channel)
            target=RenderTarget(8,8)
            render!(target,scene,camera;cache=cache)
            @test any(>(0.0),target.color) == (channel==camera_channel)
            pooled=RenderTarget(8,8)
            render_pooled!(pooled,scene,camera,cache)
            @test pooled.color == target.color
            tiled=RenderTarget(8,8)
            render_tiled!(tiled,scene,camera;tiles=1,cache=[cache])
            @test tiled.color == target.color
        end
    end
    layers_enable_all!(object_layers(camera))
    layers_disable_all!(object_layers(mesh))
    target=RenderTarget(8,8)
    render!(target,scene,camera)
    @test all(iszero,target.color)
    layers_set!(object_layers(mesh),1)
    layers_disable_all!(object_layers(camera))
    render!(target,scene,camera)
    @test all(iszero,target.color)

    layers_set!(object_layers(camera),0)
    @test all(iszero,soft_render_scene(scene,camera,4,4))
    layers_set!(object_layers(camera),1)
    @test any(>(0.0),soft_render_scene(scene,camera,4,4))
    workspace=SoftRenderSceneWorkspace()
    @test soft_render_scene(scene,camera,4,4;workspace=workspace) ≈ soft_render_scene(scene,camera,4,4)

    # Layer selection must happen before constructing render-only pose proxies.
    set_attribute!(mesh.geometry,:morphPosition0,repeat([0.1,0.0,0.0],mesh.geometry.n_vertices),3)
    mesh.morph_target_influences=[0.5]
    render!(target,scene,camera;cache=cache)
    @test any(>(0.0),target.color)
    layers_set!(object_layers(camera),0)
    render!(target,scene,camera;cache=cache)
    @test all(iszero,target.color)
    mesh.morph_target_influences[1]=NaN
    @test render!(target,scene,camera;cache=cache) === target

    skin_geometry=PlaneGeometry()
    skin=SkinnedMesh(skin_geometry,MeshBasicMaterial(),Skeleton([Bone()]),
                     fill((1,1,1,1),skin_geometry.n_vertices),
                     fill((1.0,0.0,0.0,0.0),skin_geometry.n_vertices))
    layers_set!(object_layers(skin),1)
    skin_scene=Scene();add!(skin_scene,skin)
    render!(target,skin_scene,camera;cache=cache)
    @test all(iszero,target.color)
    layers_set!(object_layers(camera),1)
    render!(target,skin_scene,camera;cache=cache)
    @test any(>(0.0),target.color)

    for (make_object,draw) in (
        (() -> LineSegments(BufferGeometry([-0.5,0.0,0.0,0.5,0.0,0.0],Float64[],Float64[],Int[],2,0),LineBasicMaterial()),render_lines!),
        (() -> PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),PointsMaterial(size=3.0)),render_points!),
        (() -> Sprite(SpriteMaterial()),render_sprites!),
        (() -> InstancedMesh(PlaneGeometry(),MeshBasicMaterial(),1),nothing),
    )
        primitive=make_object()
        primitive_scene=Scene();add!(primitive_scene,primitive)
        layers_set!(object_layers(primitive),1)
        for selected in (false,true), scratch in (nothing,cache)
            layers_set!(object_layers(camera),selected ? 1 : 0)
            result=RenderTarget(8,8)
            render!(result,primitive_scene,camera;cache=scratch)
            @test any(>(0.0),result.color)==selected
            if draw!==nothing
                standalone=RenderTarget(8,8)
                draw(standalone,primitive_scene,camera;cache=scratch)
                @test any(>(0.0),standalone.color)==selected
            end
        end
    end

    lit_scene=Scene()
    lit_mesh=Mesh(PlaneGeometry(),MeshLambertMaterial())
    layers_enable_all!(object_layers(lit_mesh))
    add!(lit_scene,lit_mesh)
    red=AmbientLight(color=Color3(1.0,0.0,0.0),intensity=0.5)
    blue=AmbientLight(color=Color3(0.0,0.0,1.0),intensity=0.5)
    layers_set!(object_layers(red),0);layers_set!(object_layers(blue),1)
    add!(lit_scene,red);add!(lit_scene,blue)
    for channel in (0,1)
        layers_set!(object_layers(camera),channel)
        render!(target,lit_scene,camera;cache=cache)
        @test maximum(target.color[:,:,channel==0 ? 1 : 3]) > 0.1
        @test maximum(target.color[:,:,channel==0 ? 3 : 1]) == 0.0
    end
    blue.intensity=NaN
    layers_set!(object_layers(camera),0)
    @test render!(target,lit_scene,camera;cache=cache) === target
    layers_set!(object_layers(camera),1)
    @test_throws ArgumentError render!(target,lit_scene,camera;cache=cache)

    shadow_scene=Scene()
    sun=DirectionalLight(position=Vec3(0.0,3.0,4.0))
    sun.cast_shadow=true
    layers_enable_all!(object_layers(sun))
    add!(shadow_scene,sun)
    for channel in (0,1)
        caster=Mesh(BoxGeometry(),MeshBasicMaterial();cast_shadow=true)
        caster.position=Vec3(channel==0 ? -1.0 : 1.0,0.0,0.0)
        layers_set!(object_layers(caster),channel)
        add!(shadow_scene,caster)
    end
    for channel in (0,1)
        layers_set!(object_layers(camera),channel)
        render!(target,shadow_scene,camera;cache=cache,shadows=true,shadow_resolution=8)
        reference_scene=Scene()
        reference_caster=Mesh(BoxGeometry(),MeshBasicMaterial();cast_shadow=true)
        reference_caster.position=Vec3(channel==0 ? -1.0 : 1.0,0.0,0.0)
        add!(reference_scene,reference_caster)
        reference_light=DirectionalLight(position=Vec3(0.0,3.0,4.0))
        reference_shadow=compute_shadow_map(reference_scene,reference_light;resolution=8)
        actual_shadow=cache.shadow_maps[sun]
        @test collect(actual_shadow.light_vp.e) ≈ collect(reference_shadow.light_vp.e)
        @test actual_shadow.depth == reference_shadow.depth
    end
    export_scene=Scene()
    export_mesh=Mesh(PlaneGeometry(),MeshBasicMaterial(wireframe=true))
    layers_set!(object_layers(export_mesh),31)
    add!(export_scene,export_mesh)
    export_light=AmbientLight()
    layers_disable_all!(object_layers(export_light))
    add!(export_scene,export_light)
    layers_set!(object_layers(camera),31)
    @test Diff3D._json_parse(only(Diff3D._web_collect_drawables(export_scene)))["layerMask"] == 2^31
    @test Diff3D._json_parse(Diff3D._web_camera_json(camera))["layerMask"] == 2^31
    @test only(Diff3D._json_parse(Diff3D._web_lights_json(export_scene)))["layerMask"] == 0
end
