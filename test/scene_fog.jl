using Diff3D, Test

@testset "Scene fog affects each fragment before compositing" begin
    camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=30.0)
    camera.position=Vec3(0.0,0.0,5.0)
    orthographic=OrthographicCamera(left=-2.0,right=2.0,bottom=-2.0,top=2.0,near=0.1,far=30.0)
    orthographic.position=camera.position
    geometry=PlaneGeometry(width=3.0,height=3.0)
    material=MeshBasicMaterial(color=Color3(1.0,0.0,0.0))
    function image_for(object,fog,view_camera; backend=:main,shading=:flat)
        fog_scene=Scene(fog=fog);add!(fog_scene,object)
        fog_target=RenderTarget(24,24)
        returned=if backend===:pooled
            render_pooled!(fog_target,fog_scene,view_camera,RenderCache())
        elseif backend===:tiled
            render_tiled!(fog_target,fog_scene,view_camera;tiles=2)
        elseif backend===:lines
            render_lines!(fog_target,fog_scene,view_camera)
        elseif backend===:points
            render_points!(fog_target,fog_scene,view_camera)
        elseif backend===:sprites
            render_sprites!(fog_target,fog_scene,view_camera)
        else
            render!(fog_target,fog_scene,view_camera;shading=shading,cache=RenderCache())
        end
        @test returned===fog_target
        return fog_target
    end
    for view_camera in (camera,orthographic),fog in (Fog(color=Color3(0.0,0.0,1.0),near=2.0,far=8.0),
                                                   FogExp2(color=Color3(0.0,0.0,1.0),density=0.2))
        amount=fog isa Fog ? 0.5 : 1-exp(-1.0)
        expected=[1-amount,0.0,amount]
        for backend in (:main,:pooled,:tiled),shading in (backend===:main ? (:flat,:smooth) : (:flat,))
            target=image_for(Mesh(geometry,material),fog,view_camera;backend=backend,shading=shading)
            @test target.color[12,13,:]≈expected atol=1e-12
        end
        for kind in (:instances,:skin)
            object=if kind===:instances
                InstancedMesh(geometry,material,1)
            else
                SkinnedMesh(geometry,material,Skeleton([Bone()],[Mat4()]),
                    fill((1,1,1,1),geometry.n_vertices),fill((1.0,0.0,0.0,0.0),geometry.n_vertices))
            end
            @test image_for(object,fog,view_camera).color[12,13,:]≈expected atol=1e-12
        end
        for backend in (:lines,:points,:sprites)
            object=if backend===:lines
                LineSegments(BufferGeometry([-1.0,0.0,0.0,1.0,0.0,0.0],Float64[],Float64[],Int[],2,0),
                    LineBasicMaterial(color=Color3(1.0,0.0,0.0)))
            elseif backend===:points
                PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),
                    PointsMaterial(color=Color3(1.0,0.0,0.0),size=5.0,size_attenuation=false))
            else
                Sprite(SpriteMaterial(color=Color3(1.0,0.0,0.0)))
            end
            target=image_for(object,fog,view_camera;backend=backend)
            @test target.color[12,12,:]≈expected atol=1e-12
        end
    end
    fog=Fog(color=Color3(0.0,0.0,1.0),near=2.0,far=8.0)
    scene=Scene(fog=fog)
    add!(scene,Mesh(geometry,MeshBasicMaterial(color=Color3(0.0,1.0,0.0))))
    front=Mesh(geometry,MeshBasicMaterial(color=Color3(1.0,0.0,0.0),transparent=true,opacity=0.5,depth_write=false))
    front.position=Vec3(0.0,0.0,1.0);add!(scene,front)
    target=RenderTarget(24,24);render!(target,scene,camera)
    front_fog=(1/3)^2*(3-2/3)
    expected=[0.5*(1-front_fog),0.25,0.5*front_fog+0.25]
    @test target.color[12,13,:]≈expected atol=1e-12
end

@testset "Fog follows viewport cameras, parented roots and render reuse" begin
    fog=Fog(color=Color3(0.0,0.0,1.0),near=2.0,far=8.0)
    scene=Scene(fog=fog)
    mesh=Mesh(PlaneGeometry(width=5.0,height=5.0),MeshBasicMaterial(color=Color3(1.0,0.0,0.0)))
    add!(scene,mesh)
    far=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=30.0);far.position=Vec3(0.0,0.0,5.0)
    near=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=30.0);near.position=Vec3(0.0,0.0,2.0)
    target=RenderTarget(24,48)
    render!(target,scene,ArrayCamera([far,near],[(0,0,24,24),(0,24,24,24)]))
    @test target.color[12,13,:]≈[0.5,0.0,0.5] atol=1e-12
    @test target.color[36,13,:]≈[1.0,0.0,0.0] atol=1e-12
    cache=RenderCache();antialias=RenderTarget(24,24)
    @test render_msaa!(antialias,scene,far;samples=4,cache=cache)===antialias
    @test antialias.color[12,13,:]≈[0.5,0.0,0.5] atol=1e-12
    scene.fog=nothing
    render_msaa!(antialias,scene,far;samples=4,cache=cache)
    @test antialias.color[12,13,:]≈[1.0,0.0,0.0] atol=1e-12
    scene.fog=fog
    parent=Group();parent.position=Vec3(0.0,0.0,3.0)
    add!(parent,scene);add!(parent,far)
    parented=RenderTarget(24,24);render!(parented,scene,far)
    @test parented.color[12,13,:]≈[0.5,0.0,0.5] atol=1e-12
    scoped=Group();add!(scene,scoped)
    point=PointsObject(BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0),
        PointsMaterial(color=Color3(1.0,0.0,0.0),size=5.0,size_attenuation=false))
    add!(scoped,point)
    overlay=RenderTarget(24,24);render_points!(overlay,scoped,far)
    @test overlay.color[12,12,:]≈[0.5,0.0,0.5] atol=1e-12
    clipped=RenderTarget(24,24);render!(clipped,scene,far;scissor=(6,6,12,12),scissor_test=true)
    @test clipped.color[12,13,:]≈[0.5,0.0,0.5] atol=1e-12
    @test all(iszero,clipped.color[1:5,:,:])
end

@testset "Fog uses view depth and preserves masks and cache state" begin
    camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=30.0)
    camera.position=Vec3(0.0,0.0,5.0)
    fog=Fog(color=Color3(0.0,0.0,1.0),near=2.0,far=8.0)
    geometry=BufferGeometry([-1.0,-1.0,0.0,1.0,-1.0,2.0,-1.0,1.0,0.0,1.0,1.0,2.0],
        repeat([0.0,0.0,1.0],4),Float64[],[1,2,3,2,4,3],4,2)
    scene=Scene(fog=fog);add!(scene,Mesh(geometry,MeshBasicMaterial(color=Color3(1.0,0.0,0.0),side=:double)))
    cache=RenderCache()
    for shading in (:flat,:smooth),logarithmic in (false,true)
        target=RenderTarget(24,24)
        @test render!(target,scene,camera;shading=shading,logarithmic_depth=logarithmic,cache=cache)===target
        mask=isfinite.(target.depth)
        @test count(mask)>10
        for index in findall(mask)
            y,x=Tuple(index);ndc_x=2*(x-0.5)/24-1
            depth=4/(1+ndc_x) # Intersection of the camera ray with z=x+1.
            t=clamp((depth-2)/6,0,1);f=t*t*(3-2t)
            @test target.color[y,x,:]≈[1-f,0.0,f] atol=2e-12
        end
    end
    scene.fog=FogExp2(color=Color3(0.0,0.0,1.0),density=0.0)
    clear_fog=RenderTarget(24,24);render!(clear_fog,scene,camera;cache=cache)
    scene.fog=nothing
    no_fog=RenderTarget(24,24);render!(no_fog,scene,camera;cache=cache)
    @test clear_fog.color==no_fog.color
    @test no_fog.view_state===nothing
    @test Diff3D._render_fog_factor(FogExp2(density=0.0),Inf)==0.0
    @test Diff3D._render_fog_factor(FogExp2(density=floatmax(Float64)),floatmax(Float64))==1.0

    mapped=Scene(fog=fog)
    texture=Texture(reshape([0.2,0.4,0.6],1,1,3);colorspace=:linear)
    surface=Mesh(PlaneGeometry(width=3.0,height=3.0),MeshBasicMaterial(map=texture))
    add!(mapped,surface)
    for shading in (:flat,:smooth)
        target=RenderTarget(24,24);render!(target,mapped,camera;shading=shading)
        @test target.color[12,13,:]≈[0.1,0.2,0.8] atol=1e-12
    end
    invisible=Texture(reshape([1.0,1.0,1.0,0.0],1,1,4);colorspace=:linear)
    surface.material=MeshBasicMaterial(map=invisible,alpha_test=0.5)
    for shading in (:flat,:smooth)
        target=RenderTarget(24,24);render!(target,mapped,camera;shading=shading)
        @test all(iszero,target.color)
        @test all(isinf,target.depth)
    end
end
