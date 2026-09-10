using Diff3D, Test

@testset "Point footprints use pixel centers and authored size" begin
    width,height=40,32
    camera=OrthographicCamera(left=-1.0,right=1.0,bottom=-1.0,top=1.0,near=0.1,far=10.0)
    camera.position=Vec3(0.0,0.0,4.0)
    color=Color3(0.2,0.4,0.6)
    for point_size in (0.0,0.5,1.0,2.0,3.0,4.0,5.0,15.5,16.0),
        (center_x,center_y) in ((20.0,16.0),(20.25,16.25),(-0.25,1.25))
        position=Vec3(2center_x/width-1,1-2center_y/height,0.0)
        geometry=BufferGeometry([position.x,position.y,position.z],Float64[],Float64[],Int[],1,0)
        material=PointsMaterial(color=color,size=point_size,size_attenuation=false)
        scene=Scene();add!(scene,PointsObject(geometry,material))
        target=RenderTarget(width,height);render_points!(target,scene,camera)
        projected=mat4_transform_point(projection_matrix(camera)*view_matrix(camera),position)
        px=(projected.x+1)*width/2;py=(1-projected.y)*height/2
        half=max(point_size,1.0)/2
        left,right=BigFloat(px)-half,BigFloat(px)+half
        top,bottom=BigFloat(py)-half,BigFloat(py)+half
        expected=[left<=x-0.5<right && top<=y-0.5<bottom for y in 1:height,x in 1:width]
        @test (target.color[:,:,1].>0)==expected
        for channel in 1:3
            component=(color.r,color.g,color.b)[channel]
            @test all(==(component),target.color[:,:,channel][expected])
        end
        clipped=RenderTarget(width,height)
        render_points!(clipped,scene,camera;xlo=11,xhi=24,ylo=9,yhi=22)
        expected_clip=copy(expected)
        for y in 1:height,x in 1:width
            (11<=x<=24 && 9<=y<=22) || (expected_clip[y,x]=false)
        end
        @test (clipped.color[:,:,1].>0)==expected_clip
    end
end

@testset "Point textures and clipping reach scene rendering" begin
    camera=OrthographicCamera(left=-1.0,right=1.0,bottom=-1.0,top=1.0,near=0.1,far=10.0)
    camera.position=Vec3(0.0,0.0,4.0)
    data=zeros(2,2,4)
    data[1,1,:].=[1.0,0.0,0.0,1.0];data[1,2,:].=[0.0,1.0,0.0,1.0]
    data[2,1,:].=[0.0,0.0,1.0,1.0];data[2,2,:].=[1.0,1.0,0.0,0.0]
    texture=Texture(data;filter=:nearest,colorspace=:linear)
    position=Vec3(2*16.25/32-1,1-2*16.25/32,0.0)
    geometry=BufferGeometry([position.x,position.y,position.z],Float64[],Float64[],Int[],1,0)
    material=PointsMaterial(size=10.5,size_attenuation=false,color=Color3(0.5,0.75,1.0),
                            map=texture,opacity=0.5,transparent=true,alpha_test=0.1)
    for instanced in (false,true)
        object=instanced ? InstancedMesh(geometry,material,1;draw_mode=:points) : PointsObject(geometry,material)
        tint=instanced ? Color3(0.5,1.0,0.25) : Color3(1.0,1.0,1.0)
        instanced && set_instance_color!(object,1,tint)
        scene=Scene();add!(scene,object)
        expected=zeros(32,32,3)
        for y in 1:32,x in 1:32
            dx,dy=x-0.5-16.25,y-0.5-16.25
            (-5.25<=dx<5.25 && -5.25<=dy<5.25) || continue
            row=dy<0 ? 1 : 2;column=dx<0 ? 1 : 2
            for channel in 1:3
                expected[y,x,channel]=data[row,column,channel]*data[row,column,4]*0.5*
                    (material.color.r,material.color.g,material.color.b)[channel]*(tint.r,tint.g,tint.b)[channel]
            end
        end
        cache=RenderCache()
        for backend in (:standalone,:main,:cached)
            target=RenderTarget(32,32)
            if backend===:standalone
                render_points!(target,scene,camera;cache=cache)
            else
                render!(target,scene,camera;cache=backend===:cached ? cache : nothing)
            end
            @testset "instanced=$instanced backend=$backend" begin
                @test target.color≈expected atol=1e-12
            end
        end
        crop=RenderTarget(32,32)
        render_points!(crop,scene,camera;cache=cache,xlo=14,xhi=21,ylo=8,yhi=20)
        @test crop.color[8:20,14:21,:]≈expected[8:20,14:21,:] atol=1e-12
    end
end

@testset "Point coverage boundary arithmetic" begin
    setprecision(BigFloat,2048) do
        for center in (-nextfloat(0.0),nextfloat(0.0),-0.25,nextfloat(-0.25),prevfloat(-0.25),
                       0.0,0.25,0.5,1.0,32.0,1e18,1e18+128.0,-1e18),
            half in (0.5,1.0,7.75,16.0,1e18)
            left=BigFloat(center)-BigFloat(half);right=BigFloat(center)+BigFloat(half)
            expected=[x for x in 1:64 if left<=BigFloat(x)-BigFloat(0.5)<right]
            @test collect(Diff3D._point_pixel_range(center,half,1,64))==expected
        end
    end
end

@testset "Point attenuation precedes the minimum size" begin
    camera=PerspectiveCamera(fov=pi/2,aspect=1.0,near=0.1,far=200.0)
    camera.position=Vec3(0.0,0.0,4.0)
    geometry=BufferGeometry([0.0,0.0,0.0],Float64[],Float64[],Int[],1,0)
    for size in (0.0,0.5,2.0,16.0),distance in (2.0,4.0,80.0),instanced in (false,true)
        material=PointsMaterial(size=size,size_attenuation=true)
        object=instanced ? InstancedMesh(geometry,material,1;draw_mode=:points) : PointsObject(geometry,material)
        object.position=Vec3(0.0,0.0,4.0-distance)
        scene=Scene();add!(scene,object)
        target=RenderTarget(40,40);render!(target,scene,camera)
        half=max(size*4.0/distance,1.0)/2
        expected=[-half<=x-0.5-20.0<half && -half<=y-0.5-20.0<half for y in 1:40,x in 1:40]
        @test (target.color[:,:,1].>0)==expected
    end
end
