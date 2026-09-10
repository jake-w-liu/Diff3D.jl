using Test
using Diff3D

@testset "LOD selects complete level subtrees during rendering" begin
    lod=LOD()
    near=Group()
    for x in (-0.45,0.45)
        member=Mesh(PlaneGeometry(width=0.6,height=0.6),MeshBasicMaterial(color=Color3(1.0,0.0,0.0)))
        member.position=Vec3(x,0.0,0.0)
        add!(near,member)
    end
    far=Mesh(PlaneGeometry(width=1.5,height=0.6),MeshBasicMaterial(color=Color3(0.0,0.0,1.0)))
    add_lod_level!(lod,0.0,near)
    add_lod_level!(lod,5.0,far;hysteresis=0.2)
    scene=Scene();add!(scene,lod)
    camera=PerspectiveCamera()
    cache=RenderCache()
    function render_at(distance; zoom=1.0, method=:main)
        camera.position=Vec3(0.0,0.0,distance)
        camera.zoom=zoom
        render_target=RenderTarget(16,16)
        if method===:pooled
            render_pooled!(render_target,scene,camera,cache)
        elseif method===:tiled
            render_tiled!(render_target,scene,camera;tiles=1,cache=[cache])
        else
            render!(render_target,scene,camera;cache=cache)
        end
        return render_target.color
    end
    for method in (:main,:pooled,:tiled)
        close=render_at(3.0;method=method)
        @test near.visible && !far.visible
        @test maximum(close[:,:,1])>0.0 && maximum(close[:,:,3])==0.0
        distant=render_at(6.0;method=method)
        @test !near.visible && far.visible
        @test maximum(distant[:,:,3])>0.0 && maximum(distant[:,:,1])==0.0
        render_at(4.5;method=method)
        @test far.visible
        render_at(3.5;method=method)
        @test near.visible
        render_at(6.0;zoom=2.0,method=method)
        @test near.visible && !far.visible
    end
    lod.auto_update=false
    lod_update!(lod,0.0)
    render_at(8.0)
    @test near.visible && !far.visible
    lod.auto_update=true
    camera.position=Vec3(0.0,0.0,6.0);camera.zoom=1.0
    @test lod_update!(lod,camera) === far

    container=Group();container.position=Vec3(0.0,0.0,3.0)
    add!(container,lod);add!(scene,container)
    render_at(6.0)
    @test near.visible
    container.position=Vec3()
    image=soft_render_scene(scene,camera,4,4)
    @test far.visible && !near.visible
    @test maximum(image[:,:,3])>0.0 && maximum(image[:,:,1])==0.0

    exported=Diff3D._json_parse.(Diff3D._web_collect_drawables(scene))
    @test length(exported)==3
    @test count(object->object["lodPath"]==[[lod.id,near.id]],exported)==2
    @test count(object->object["lodPath"]==[[lod.id,far.id]],exported)==1
    lod_nodes=Diff3D._json_parse.(Diff3D._web_collect_transform_nodes(scene))
    policy=only(filter(node->node["id"]==lod.id,lod_nodes))
    @test policy["lodAutoUpdate"]
    @test [level["object"] for level in policy["lodLevels"]]==[near.id,far.id]
    @test policy["lodLevels"][2]["hysteresis"]==0.2
    lod.auto_update=false
    manual_export=Diff3D._json_parse.(Diff3D._web_collect_drawables(scene))
    @test length(manual_export)==1
    @test isempty(only(manual_export)["lodPath"])
    lod.auto_update=true

    repeated=LOD()
    shared=Mesh(PlaneGeometry(),MeshBasicMaterial())
    add_lod_level!(repeated,0.0,shared);add_lod_level!(repeated,5.0,shared)
    repeated_scene=Scene();add!(repeated_scene,repeated)
    @test length(Diff3D._web_collect_drawables(repeated_scene))==1

    # Layer masks select drawables; a container's mask does not disable LOD
    # management for matching descendants.
    layers_set!(object_layers(lod),7)
    render_at(3.0)
    @test near.visible && !far.visible
    render_at(6.0)
    @test far.visible && !near.visible
    camera_near=PerspectiveCamera();camera_near.position=Vec3(0.0,0.0,4.5)
    camera_far=PerspectiveCamera();camera_far.position=Vec3(0.0,0.0,8.0)
    lod_update!(lod,0.0)
    for _ in 1:2
        render!(RenderTarget(8,8),scene,camera_near)
        @test near.visible && !far.visible
        render!(RenderTarget(8,8),scene,camera_far)
        @test far.visible && !near.visible
    end
    function ephemeral_camera_state(container)
        discardable=PerspectiveCamera()
        discardable.position=Vec3(0.0,0.0,8.0)
        lod_update!(container,discardable)
        return WeakRef(discardable)
    end
    weak_camera=ephemeral_camera_state(lod)
    GC.gc()
    @test weak_camera.value===nothing

    scaled_lod=LOD()
    close_level=Group();distant_level=Group()
    add_lod_level!(scaled_lod,0.0,close_level);add_lod_level!(scaled_lod,5.0,distant_level)
    scaled_camera=PerspectiveCamera()
    for scale in (1e-300,1.0,1e308)
        scaled_lod.position=Vec3(0.0,0.0,-scale)
        scaled_camera.position=Vec3(0.0,0.0,scale)
        scaled_camera.zoom=scale
        @test lod_update!(scaled_lod,scaled_camera) === close_level
    end
    scaled_camera.zoom=1e-300
    @test lod_update!(scaled_lod,scaled_camera) === distant_level

    for (near_primitive,far_primitive,draw) in (
        (Sprite(SpriteMaterial(color=Color3(1.0,0.0,0.0))),Sprite(SpriteMaterial(color=Color3(0.0,0.0,1.0))),render_sprites!),
        (PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),PointsMaterial(size=3.0,color=Color3(1.0,0.0,0.0))),
         PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),PointsMaterial(size=3.0,color=Color3(0.0,0.0,1.0))),render_points!),
        (LineSegments(BufferGeometry([-0.5,0.0,0.0,0.5,0.0,0.0],Float64[],Float64[],Int[],2,0),LineBasicMaterial(color=Color3(1.0,0.0,0.0))),
         LineSegments(BufferGeometry([-0.5,0.0,0.0,0.5,0.0,0.0],Float64[],Float64[],Int[],2,0),LineBasicMaterial(color=Color3(0.0,0.0,1.0))),render_lines!),
    )
        primitive_lod=LOD();add_lod_level!(primitive_lod,0.0,near_primitive);add_lod_level!(primitive_lod,5.0,far_primitive)
        primitive_scene=Scene();add!(primitive_scene,primitive_lod)
        primitive_target=RenderTarget(16,16)
        draw(primitive_target,primitive_scene,camera;cache=cache)
        @test far_primitive.visible && !near_primitive.visible
        @test maximum(primitive_target.color[:,:,3])>0.0 && maximum(primitive_target.color[:,:,1])==0.0
    end
end
