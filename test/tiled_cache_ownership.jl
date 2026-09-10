using Test, Diff3D

@testset "Tiled rendering validates exclusive scratch ownership" begin
    scene=Scene();camera=PerspectiveCamera();target=RenderTarget(12,12)
    clear!(target,Color3(0.2,0.3,0.4))
    original_color=copy(target.color);original_depth=copy(target.depth)
    @test_throws ArgumentError render_tiled!(target,scene,camera;cache=RenderCache[],tiles=2)
    @test target.color==original_color
    @test target.depth==original_depth
    if Threads.nthreads()>1
        shared=RenderCache()
        @test_throws ArgumentError render_tiled!(target,scene,camera;cache=fill(shared,Threads.nthreads()),tiles=2)
        @test target.color==original_color
        @test target.depth==original_depth
    end
    # Slots outside the active prefix are never used and need not be unique.
    one=RenderCache()
    @test render_tiled!(target,scene,camera;cache=[one,one],tiles=1)===target
    @test all(iszero,target.color)
end

function yielding_tile_color(normal,view_dir,position,uniforms)
    # Alter scheduling only; color remains independent of task or worker identity.
    for _ in 1:(1+Int(mod(hash(current_task()),UInt(5))))
        yield()
    end
    return uniforms["color"]
end

@testset "Tiled scratch follows work through shader yields" begin
    scene=Scene()
    camera=OrthographicCamera(left=-3.0,right=3.0,bottom=-3.0,top=3.0,near=0.1,far=100.0)
    camera.position=Vec3(0.0,0.0,5.0)
    for index in 1:9
        material=ShaderMaterial(program=yielding_tile_color,
            uniforms=Dict{String,Any}("color"=>Color3(index/10,0.4,1-index/10)))
        mesh=Mesh(PlaneGeometry(width=2.3,height=2.3),material)
        mesh.position=Vec3(2.0*((index-1)%3-1),2.0*((index-1)÷3-1),-0.05index)
        add!(scene,mesh)
    end
    reference=RenderTarget(32,32)
    render_tiled!(reference,scene,camera;tiles=1,cache=[RenderCache()])
    @test maximum(reference.color)>0.5
    for tiles in unique([2,Threads.nthreads(),Threads.nthreads()+1,3 * Threads.nthreads()+1,97])
        caches=[RenderCache() for _ in 1:min(tiles,32,Threads.nthreads())]
        target=RenderTarget(32,32)
        for iteration in 1:4
            result=if isodd(iteration)
                render_tiled!(target,scene,camera;tiles=tiles,cache=caches)
            else
                fetch(Threads.@spawn render_tiled!(target,scene,camera;tiles=tiles,cache=caches))
            end
            @test result===target
            @test maximum(abs.(target.color-reference.color))<=1e-12
            @test all(isfinite.(target.depth).==isfinite.(reference.depth))
            mask=isfinite.(reference.depth)
            @test maximum(abs.(target.depth[mask]-reference.depth[mask]))<=1e-12
        end
    end
end
