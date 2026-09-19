using Test, Diff3D
@noinline function soft_tape_seed!(workspace)
    parameter=ADVar(-0.6)
    vertices=Vec3{ADVar}[Vec3(parameter,-0.5,0.0),Vec3(0.5,-0.4,0.0),Vec3(0.1,0.6,0.0)]
    soft_render(vertices,fill((1,2,3),2),fill(Color3(0.8,0.2,0.1),2),Mat4(),1,1;workspace)
    return WeakRef(parameter)
end
function soft_tape_replace!(workspace,mode)
    vertices=[Vec3(-0.6,-0.5,mode===:clipped ? 2.0 : 0.0),Vec3(0.5,-0.4,mode===:clipped ? 2.0 : 0.0),Vec3(0.1,0.6,mode===:clipped ? 2.0 : 0.0)]
    n=mode===:empty ? 0 : 1
    soft_render(vertices,fill((1,2,3),n),fill(Color3(0.8,0.2,0.1),n),Mat4{ADVar}(),1,1;workspace)
end

@testset "Soft workspaces release inactive differentiation graphs" begin
    for mode in (:empty, :smaller, :clipped)
        workspace = SoftRenderWorkspace{ADVar}()
        reference = soft_tape_seed!(workspace)
        soft_tape_replace!(workspace, mode)
        collected = GC.@preserve workspace begin
            GC.gc(true)
            GC.gc(true)
            reference.value === nothing
        end
        @test collected
        values = map(Diff3D._primal_value, workspace.image)
        @test all(isfinite, values)
        if mode === :smaller
            @test any(>(0.0), values)
        else
            @test all(iszero, values)
        end
    end
end
