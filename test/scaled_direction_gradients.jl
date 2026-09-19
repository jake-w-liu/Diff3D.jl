using Diff3D, ForwardDiff, Test

scaled_difference_direction(a,b) = normalize(first(Diff3D._difference_direction_and_logscale(a,b)))
point_sample_direction(a,b) = first(Diff3D._light_direction_and_distance(a,b))
area_sample_direction(a,b) = first(Diff3D._rect_area_sample_direction(a,b))

@testset "Scaled vector differences retain zero-component gradients" begin
    samplers=(scaled_difference_direction,Diff3D._direction_between,
              Diff3D._shadow_direction,point_sample_direction,area_sample_direction)
    for scale in (1.0,1e308), axis in 1:3, sign in (-1.0,1.0)
        moving_axis=mod1(axis+1,3)
        to=Vec3(ntuple(i->i==axis ? sign*scale : 0.0,3)...)
        from(y)=Vec3(ntuple(i->i==axis ? -sign*scale : i==moving_axis ? y : zero(y),3)...)
        for sample in samplers
            f(y)=getfield(sample(from(y),to),moving_axis)
            # d(normalize(to-from))/d(from[moving_axis]) = -1/(2scale).
            @test f(0.0)==0.0
            @test ForwardDiff.derivative(f,0.0) ≈ -0.5/scale rtol=1e-12
            @test reverse_gradient(q->f(q[1]),[0.0])[1] ≈ -0.5/scale rtol=1e-12
        end
    end

    # Compare all Jacobian entries at an oblique overflowed displacement with
    # the analytic normalization Jacobian evaluated before Float64 rounding.
    from=[-1e308,0.0,2e307]
    to=Vec3(1e308,8e307,-2e307)
    expected=setprecision(BigFloat,256) do
        displacement=BigFloat.([to.x,to.y,to.z])-BigFloat.(from)
        magnitude=sqrt(sum(abs2,displacement))
        unit=displacement/magnitude
        Float64.([(unit[i]*unit[j]-(i==j))/magnitude for i in 1:3,j in 1:3])
    end
    for sample in samplers
        actual=ForwardDiff.jacobian(from) do p
            v=sample(Vec3(p...),to)
            [v.x,v.y,v.z]
        end
        @test actual ≈ expected rtol=1e-12
        for i in 1:3
            @test reverse_gradient(p->getfield(sample(Vec3(p...),to),i),from) ≈ expected[i,:] rtol=1e-12
        end
    end

    for axis in 1:3
        derivative=ForwardDiff.derivative(0.0) do y
            matrix=mat4_look_at(Vec3(1e308,y,0.0),Vec3(-1e308,0.0,0.0),Vec3(0.0,1.0,0.0))
            mat4_get(matrix,3,axis)
        end
        @test derivative ≈ (axis==2 ? 5e-309 : 0.0) rtol=1e-12
    end
end
