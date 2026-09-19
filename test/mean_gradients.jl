using Diff3D, ForwardDiff, Test

mean_three_values(v)=Diff3D._mean3_scaled(v[1],v[2],v[3])

@testset "Zero means retain all input derivatives" begin
    for values in ([0.0,0.0,0.0],[-0.0,-0.0,-0.0],[1.0,2.0,3.0],[-1.0,0.0,1.0])
        @test ForwardDiff.gradient(mean_three_values,values) ≈ fill(1/3,3)
        @test reverse_gradient(mean_three_values,values) ≈ fill(1/3,3)
    end
    for axis in 1:3, vertex in 1:3
        function centroid(value)
            points=ntuple(v->Vec3(ntuple(i->i==axis && v==vertex ? value : zero(value),3)...),3)
            return getfield(triangle_centroid(Triangle(points...)),axis)
        end
        @test ForwardDiff.derivative(centroid,0.0) ≈ 1/3
        @test reverse_gradient(q->centroid(q[1]),[0.0]) ≈ [1/3]
    end
    @test Diff3D._mean3_scaled(floatmax(Float64),floatmax(Float64),floatmax(Float64))==floatmax(Float64)
    @test Diff3D._mean3_scaled(nextfloat(0.0),nextfloat(0.0),nextfloat(0.0))==nextfloat(0.0)
    @test isnan(Diff3D._mean3_scaled(NaN,0.0,0.0))
    identical=x->Diff3D._mean3_scaled(x,x,x)
    @test ForwardDiff.derivative(identical,0.0)==1.0
    @test reverse_gradient(q->identical(q[1]),[0.0])==[1.0]
    @test ForwardDiff.derivative(x->ForwardDiff.derivative(identical,x),0.0)==0.0
end

function scalar_mean_allocation(values)
    Diff3D._mean3_scaled(values...)
    return @allocated Diff3D._mean3_scaled(values...)
end

@testset "Scalar mean allocations" begin
    if Base.JLOptions().opt_level > 0
        for values in ((0.0,0.0,0.0),(1.0,2.0,3.0),
                       (ForwardDiff.Dual(0.0,1.0),ForwardDiff.Dual(0.0,0.0),ForwardDiff.Dual(0.0,0.0)))
            scalar_mean_allocation(values)
            @test scalar_mean_allocation(values)<=64
        end
    end
end
