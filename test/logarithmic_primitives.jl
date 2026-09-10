using Test, Diff3D

function log_depth_primitive(kind,z,opacity)
    red=Color3(1.0,0.0,0.0)
    material_options=(color=red,opacity=opacity,transparent=opacity<1.0,depth_write=opacity==1.0)
    object=if kind===:sprite
        Sprite(SpriteMaterial(;material_options...))
    elseif kind===:point || kind===:instanced_point
        geo=BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0)
        material=PointsMaterial(size=8.0,size_attenuation=false;material_options...)
        kind===:point ? PointsObject(geo,material) : InstancedMesh(geo,material,1;draw_mode=:points)
    elseif kind===:wireframe || kind===:instanced_wireframe
        geo=PlaneGeometry(width=2.0,height=2.0)
        material=MeshBasicMaterial(wireframe=true;material_options...)
        kind===:wireframe ? Mesh(geo,material) : InstancedMesh(geo,material,1)
    else
        geo=BufferGeometry([-1.0,0.0,0.0,1.0,0.0,0.0],Float64[],Float64[],Int[],2,0)
        material=LineBasicMaterial(linewidth=3.0,color=red,opacity=opacity,depth_write=opacity==1.0)
        kind===:line ? LineSegments(geo,material) : InstancedMesh(geo,material,1;draw_mode=:lines)
    end
    object.position=Vec3(0.0,0.0,z)
    return object
end

@testset "Logarithmic depth preserves mixed primitive occlusion" begin
    camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=100.0)
    camera.position=Vec3(0.0,0.0,5.0)
    for kind in (:sprite,:point,:instanced_point,:line,:instanced_line,:wireframe,:instanced_wireframe),
        z in (-1.0,1.0),opacity in (0.5,1.0),reverse_order in (false,true)
        scene=Scene()
        mesh=Mesh(PlaneGeometry(width=4.0,height=4.0),MeshBasicMaterial(color=Color3(0.0,0.0,1.0)))
        object=log_depth_primitive(kind,z,opacity)
        for drawable in (reverse_order ? (object,mesh) : (mesh,object))
            add!(scene,drawable)
        end
        normal=RenderTarget(32,32);encoded=RenderTarget(32,32)
        render!(normal,scene,camera)
        @test render!(encoded,scene,camera;logarithmic_depth=true)===encoded
        @test encoded.color≈normal.color atol=1e-12
        if z>0
            @test count(>(0.0),normal.color[:,:,1])>4
        end
    end
end

@testset "Logarithmic depth values and sequential passes" begin
    perspective=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=100.0)
    infinite_camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=Inf)
    orthographic=OrthographicCamera(left=-2.0,right=2.0,bottom=-2.0,top=2.0,near=0.1,far=100.0)
    for camera in (perspective,infinite_camera,orthographic)
        camera.position=Vec3(0.0,0.0,5.0)
        for kind in (:sprite,:point,:instanced_point,:line,:instanced_line,:wireframe,:instanced_wireframe)
            scene=Scene();add!(scene,log_depth_primitive(kind,1.0,1.0))
            normal=RenderTarget(32,32);encoded=RenderTarget(32,32);cache=RenderCache()
            render!(normal,scene,camera)
            render!(encoded,scene,camera;logarithmic_depth=true,cache=cache)
            @test encoded.color==normal.color
            mask=isfinite.(encoded.depth)
            @test count(mask)>4
            if camera isa PerspectiveCamera
                far=isinf(camera.far) ? floatmax(Float64) : camera.far
                expected=log2(5.0)/log2(far+1)
                @test all(isapprox.(encoded.depth[mask],expected;atol=1e-12))
            else
                @test encoded.depth==normal.depth
            end
            @test encoded.view_state===nothing
            render!(encoded,scene,camera;cache=cache)
            @test encoded.depth==normal.depth
        end
    end

    for (kind,pass) in ((:sprite,render_sprites!),(:point,render_points!),
                        (:instanced_point,render_points!),(:line,render_lines!),
                        (:instanced_line,render_lines!)),opacity in (0.5,1.0)
        fog=FogExp2(color=Color3(0.0,1.0,0.0),density=0.1)
        scene=Scene(fog=fog);mesh_scene=Scene(fog=fog)
        for root in (scene,mesh_scene)
            add!(root,Mesh(PlaneGeometry(width=4.0,height=4.0),MeshBasicMaterial(color=Color3(0.0,0.0,1.0))))
        end
        primitive=log_depth_primitive(kind,1.0,opacity);add!(scene,primitive)
        combined=RenderTarget(32,32);sequential=RenderTarget(32,32)
        render!(combined,scene,perspective;logarithmic_depth=true)
        render!(sequential,mesh_scene,perspective;logarithmic_depth=true)
        @test pass(sequential,primitive,perspective;logarithmic_depth=true)===sequential
        @test sequential.color≈combined.color atol=1e-12
        @test sequential.depth==combined.depth
    end
end

@testset "Logarithmic depth clips before interpolation" begin
    camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=1.0,far=100.0)
    camera.position=Vec3();camera.target=Vec3(0.0,0.0,-1.0)
    for reverse_order in (false,true)
        vertices=reverse_order ? [1.0,0.0,-4.0,-1.0,0.0,-0.5] : [-1.0,0.0,-0.5,1.0,0.0,-4.0]
        geometry=BufferGeometry(vertices,Float64[],Float64[],Int[],2,0)
        scene=Scene();add!(scene,LineSegments(geometry,LineBasicMaterial()))
        target=RenderTarget(32,32);render!(target,scene,camera;logarithmic_depth=true)
        # Near clipping creates x=-5/7 at depth 1; the far endpoint has x=1, depth 4.
        ax=(1-5/7)*16;bx=(1+1/4)*16;t=(12-ax)/(bx-ax)
        expected=((1-t)*log2(2.0)+t*log2(5.0))/log2(101.0)
        @test target.depth[16,12]≈expected atol=1e-12
    end
    camera.near=0.1;camera.position=Vec3(0.0,0.0,5.0);camera.target=Vec3()
    for kind in (:sprite,:point,:instanced_point,:line,:instanced_line,:wireframe,:instanced_wireframe),z in (4.95,6.0,-196.0)
        scene=Scene();add!(scene,log_depth_primitive(kind,z,1.0))
        target=RenderTarget(32,32)
        render!(target,scene,camera;logarithmic_depth=true,frustum_cull=false)
        @test all(isinf,target.depth)
        @test all(iszero,target.color)
    end
end

@testset "Logarithmic depth in cached, tiled and antialiased rendering" begin
    camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=100.0)
    camera.position=Vec3(0.0,0.0,5.0)
    for fog in (nothing,Fog(color=Color3(0.0,1.0,0.0),near=1.0,far=10.0)),mapped in (false,true)
        scene=Scene(fog=fog)
        map=mapped ? Texture(ones(1,1,4);colorspace=:linear) : nothing
        material=MeshBasicMaterial(color=Color3(1.0,0.0,0.0),map=map,alpha_test=mapped ? 0.5 : 0.0)
        add!(scene,Mesh(PlaneGeometry(width=3.0,height=3.0),material))
        reference=RenderTarget(24,24);render!(reference,scene,camera;logarithmic_depth=true)
        for backend in (:pooled,:tiled,:smooth)
            target=RenderTarget(24,24)
            result=if backend===:pooled
                render_pooled!(target,scene,camera,RenderCache();logarithmic_depth=true)
            elseif backend===:tiled
                render_tiled!(target,scene,camera;tiles=2,logarithmic_depth=true)
            else
                render!(target,scene,camera;shading=:smooth,logarithmic_depth=true)
            end
            @test result===target
            @test target.color≈reference.color atol=1e-12
            @test target.depth==reference.depth
        end
    end
    scene=Scene();add!(scene,Mesh(PlaneGeometry(width=4.0,height=4.0),MeshBasicMaterial(color=Color3(0.0,0.0,1.0))))
    add!(scene,log_depth_primitive(:sprite,1.0,0.5))
    normal=render_aa(scene,camera,24,24)
    @test render_aa(scene,camera,24,24;logarithmic_depth=true)≈normal atol=1e-12
    for samples in (1,4)
        reference=RenderTarget(24,24);encoded=RenderTarget(24,24);cache=RenderCache()
        render_msaa!(reference,scene,camera;samples=samples)
        @test render_msaa!(encoded,scene,camera;samples=samples,logarithmic_depth=true,cache=cache)===encoded
        @test encoded.color≈reference.color atol=1e-12
        render_msaa!(encoded,scene,camera;samples=samples,cache=cache)
        @test encoded.depth==reference.depth
    end
end
