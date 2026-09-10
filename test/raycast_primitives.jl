using Diff3D, Test

@testset "Picking instanced primitives identifies each instance" begin
    for mode in (:triangles,:points,:lines,:line_strip,:line_loop)
        geometry=mode===:triangles ? PlaneGeometry(width=0.3,height=0.3) :
            BufferGeometry([-0.15,-0.15,0.0,0.15,-0.15,0.0,0.15,0.15,0.0],
                           Float64[],Float64[],Int[],3,0)
        material=MeshBasicMaterial(side=:double)
        instances=InstancedMesh(geometry,material,2;draw_mode=mode)
        parent=Group();parent.position=Vec3(0.125,-0.25,0.0);add!(parent,instances)
        for (instance_index,x) in enumerate((-0.5,0.5))
            set_instance_matrix!(instances,instance_index,mat4_translation(x,0.0,0.0))
        end
        for (instance_index,x) in enumerate((-0.5,0.5))
            reference=if mode===:triangles
                Mesh(geometry,material)
            elseif mode===:points
                PointsObject(geometry,PointsMaterial())
            elseif mode===:lines
                LineSegments(geometry,LineBasicMaterial())
            elseif mode===:line_loop
                LineLoop(geometry,LineBasicMaterial())
            else
                LineObject(geometry,LineBasicMaterial())
            end
            reference.position=Vec3(x+0.125,-0.25,0.0)
            offset=mode===:triangles ? Vec3(0.03,0.01,0.0) :
                   mode===:points ? Vec3(0.15,0.15,0.0) : Vec3(0.0,-0.15,0.0)
            ray=Raycaster(reference.position+offset+Vec3(0.0,0.0,3.0),Vec3(0.0,0.0,-1.0);
                          point_threshold=0.01,line_threshold=0.01)
            expected=raycast(ray,reference)
            actual=raycast(ray,instances)
            @test !isempty(expected)
            @test length(actual)==length(expected)
            @test all(hit->hit.object===instances,actual)
            @test [(hit.distance,hit.point,hit.face_index) for hit in actual]==
                  [(hit.distance,hit.point,hit.face_index) for hit in expected]
            for hit in actual
                @test hasproperty(hit,:instance_id)
                hasproperty(hit,:instance_id) && @test hit.instance_id==instance_index
            end
            ray.far=2.0
            @test isempty(raycast(ray,instances))
        end
    end
end

@testset "Instanced picking preserves ranges, loop closure and world thresholds" begin
    path=BufferGeometry([0.0,0.0,0.0,1.0,0.0,0.0,1.0,1.0,0.0],
                        Float64[],Float64[],Int[],3,0)
    loop=InstancedMesh(path,LineBasicMaterial(),1;draw_mode=:line_loop)
    picker=Raycaster(Vec3(0.5,0.5,3.0),Vec3(0.0,0.0,-1.0);line_threshold=0.01)
    closing_hit=only(raycast(picker,loop))
    @test closing_hit.face_index==3 && closing_hit.instance_id==1
    loop.draw_mode=:line_strip
    @test isempty(raycast(picker,loop))
    loop.draw_mode=:line_loop
    set_draw_range!(path,1,2)
    @test isempty(raycast(picker,loop))
    path.indices=[3,1,2];set_draw_range!(path,2,2)
    set_instance_matrix!(loop,1,mat4_translation(-1.0,0.25,0.0)*mat4_scaling(2.0,0.5,1.0))
    picker.ray=Ray(Vec3(0.0,0.258,3.0),Vec3(0.0,0.0,-1.0))
    nearby=only(raycast(picker,loop))
    @test nearby.face_index==1 && nearby.instance_id==1
    @test nearby.point.y≈0.25 atol=1e-15
    picker.ray=Ray(Vec3(0.0,0.262,3.0),Vec3(0.0,0.0,-1.0))
    @test isempty(raycast(picker,loop))
    picker.ray=Ray(Vec3(0.0,0.258,3.0),Vec3(0.0,0.0,-1.0))
    layers_set!(object_layers(loop),1);layers_set!(picker.layers,0)
    @test isempty(raycast(picker,loop))
    layers_enable!(picker.layers,1)
    @test length(raycast(picker,loop))==1
    set_instance_matrix!(loop,1,mat4_translation(2.0,0.25,0.0))
    @test isempty(raycast(picker,loop))
    empty!(loop.instance_matrices);empty!(loop.instance_colors)
    @test isempty(raycast(picker,loop))
end

@testset "Sprites are pickable and orthographic size is depth independent" begin
    orthographic=OrthographicCamera(left=-1.0,right=1.0,bottom=-1.0,top=1.0,near=0.1,far=10.0)
    orthographic.position=Vec3();orthographic.target=Vec3(0.0,0.0,-1.0)
    sprite=Sprite(SpriteMaterial(color=Color3(1.0,1.0,1.0),size_attenuation=false))
    sprite.scale=Vec3(0.25,0.375,1.0);sprite.position=Vec3(0.0,0.0,-2.0)
    scene=Scene();add!(scene,sprite)
    near_image=RenderTarget(32,32);render!(near_image,scene,orthographic)
    sprite.position=Vec3(0.0,0.0,-4.0)
    far_image=RenderTarget(32,32);render!(far_image,scene,orthographic)
    @test maximum(near_image.color)==1.0
    @test near_image.color==far_image.color
    for camera in (orthographic,PerspectiveCamera())
        ray=Raycaster(Vec3(),Vec3(0.0,0.0,-1.0))
        set_from_camera!(ray,camera,0.0,0.0)
        hits=raycast(ray,sprite)
        @test length(hits)==1
        if !isempty(hits)
            @test hits[1].object===sprite
            @test norm(hits[1].point-sprite.position)<1e-12
        end
    end

    camera_ray=Raycaster(Vec3(),Vec3(0.0,0.0,-1.0))
    @test_throws "Sprite picking requires a camera" raycast(camera_ray,sprite)
    sprite.visible=false
    @test isempty(raycast(camera_ray,sprite))
    sprite.visible=true;layers_disable_all!(camera_ray.layers)
    @test isempty(raycast(camera_ray,sprite))
    @test Intersection(1,Vec3(),sprite,0).instance_id===nothing
    matrices=Mat4{Float64}[];morphs=Vec3{Float64}[]
    legacy=Raycaster(camera_ray.ray,0,Inf,Layers(),1,1,matrices,morphs)
    @test legacy.skinning_matrices===matrices && legacy.morph_positions===morphs
    @test legacy.camera===nothing
end

@testset "Sprite picking follows the rendered quad" begin
    for perspective in (false,true), attenuate in (false,true), rolled in (false,true)
        view_camera=perspective ? PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=30.0) :
            OrthographicCamera(left=-4.0,right=4.0,bottom=-4.0,top=4.0,near=0.1,far=30.0)
        view_camera.position=Vec3();view_camera.target=Vec3(0.0,0.0,-1.0)
        view_camera.up=rolled ? Vec3(1.0,0.0,0.0) : Vec3(0.0,1.0,0.0)
        right=rolled ? Vec3(0.0,-1.0,0.0) : Vec3(1.0,0.0,0.0)
        up=rolled ? Vec3(1.0,0.0,0.0) : Vec3(0.0,1.0,0.0)
        quad=Sprite(SpriteMaterial(rotation=pi/2,size_attenuation=attenuate);center=Vec2(0.2,0.7))
        quad.scale=Vec3(0.4,0.6,1.0);quad.position=Vec3(0.0,0.0,-4.0)
        quad_parent=Group();quad_parent.position=Vec3(0.4,-0.2,0.0)
        quad_parent.scale=Vec3(2.0,0.5,1.0);add!(quad_parent,quad)
        quad_center=Vec3(0.4,-0.2,-4.0)
        factor=perspective && !attenuate ? 4.0 : 1.0
        for (u,v,inside) in ((0.23,0.76,true),(0.2,0.7,true),(-0.05,0.4,false),(1.05,0.4,false),(0.4,1.05,false))
            # A quarter-turn maps local (x,y) to (-y,x); scale follows rotation.
            target=quad_center+right*(-(v-0.7)*0.8factor)+up*((u-0.2)*0.3factor)
            ndc=mat4_transform_point(projection_matrix(view_camera)*view_matrix(view_camera),target)
            picker=Raycaster(Vec3(),Vec3(0.0,0.0,-1.0))
            set_from_camera!(picker,view_camera,ndc.x,ndc.y)
            @test picker.camera===view_camera
            hits=raycast(picker,quad)
            @test length(hits)==(inside ? 1 : 0)
            if inside && !isempty(hits)
                @test norm(hits[1].point-target)<1e-11
                @test hits[1].face_index==0 && hits[1].instance_id===nothing
                @test hits[1].distance≈norm(target-picker.ray.origin) atol=1e-11
                explicit=Raycaster(picker.ray.origin,picker.ray.direction;camera=view_camera)
                @test only(raycast(explicit,quad)).distance≈hits[1].distance atol=1e-12
                picker.far=hits[1].distance-0.01
                @test isempty(raycast(picker,quad))
                picker.far=Inf;picker.near=hits[1].distance+0.01
                @test isempty(raycast(picker,quad))
            end
        end
        quad.scale=Vec3(0.0,0.6,1.0)
        degenerate=Raycaster(Vec3(0.4,-0.2,0.0),Vec3(0.0,0.0,-1.0);camera=view_camera)
        @test isempty(raycast(degenerate,quad))
    end
end
