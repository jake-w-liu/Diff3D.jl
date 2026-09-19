using Diff3D, ForwardDiff, Test

function line_projection_allocation(line,point)
    line3_closest_point_parameter(line,point;clamp_to_segment=false)
    return @allocated line3_closest_point_parameter(line,point;clamp_to_segment=false)
end

@testset "Line projections retain gradients at zero parameters" begin
    for scale in (1e-308,1.0,1e308), offset in (0.0,1e-308,0.5,1e308)
        line=Line3(Vec3(),Vec3(scale,0.0,0.0))
        f=x->line3_closest_point_parameter(line,Vec3(x,offset,0.0);clamp_to_segment=false)
        @test f(0.0)==0.0
        @test ForwardDiff.value(f(ForwardDiff.Dual(0.0,1.0)))==0.0
        @test ForwardDiff.derivative(f,0.0) ≈ 1/scale rtol=1e-12
        @test reverse_gradient(q->f(q[1]),[0.0])[1] ≈ 1/scale rtol=1e-12
    end

    # Moving a line endpoint towards an orthogonal query point changes its
    # projection parameter even while that parameter's primal value is zero.
    for scale in (1e-100,1.0,1e100,1e308)
        f=y->line3_closest_point_parameter(
            Line3(Vec3(zero(y),zero(y),zero(y)),Vec3(scale,y,zero(y))),
            Vec3(0.0,scale,0.0);clamp_to_segment=false)
        @test ForwardDiff.derivative(f,0.0) ≈ 1/scale rtol=1e-12
        @test reverse_gradient(q->f(q[1]),[0.0])[1] ≈ 1/scale rtol=1e-12
    end

    line=Line3(Vec3(),Vec3(2.0,0.0,0.0))
    for x in (-1.0,0.5,3.0), bounded in (false,true)
        f=q->line3_closest_point_parameter(line,Vec3(q,0.0,0.0);clamp_to_segment=bounded)
        expected=bounded && !(0<x<2) ? 0.0 : 0.5
        @test ForwardDiff.derivative(f,x)==expected
        @test reverse_gradient(q->f(q[1]),[x])[1]==expected
    end
    degenerate=Line3(Vec3(),Vec3())
    f=q->line3_closest_point_parameter(degenerate,Vec3(q,0.0,0.0))
    @test ForwardDiff.derivative(f,0.0)==0.0
    @test reverse_gradient(q->f(q[1]),[0.0])==[0.0]
end

@testset "AD line projection allocation" begin
    if Base.JLOptions().opt_level > 0
        for (scale,offset) in ((1.0,1.0),(1e308,1e308),(1e-308,1e308))
            line=Line3(Vec3(),Vec3(scale,0.0,0.0))
            point=Vec3(ForwardDiff.Dual(0.0,1.0),offset,0.0)
            line_projection_allocation(line,point)
            @test line_projection_allocation(line,point) <= 64
        end
    end
end

@testset "Line projection Jacobians match high-precision oracles" begin
    function parameter(values)
        line=Line3(Vec3(values[1:3]...),Vec3(values[4:6]...))
        return line3_closest_point_parameter(line,Vec3(values[7:9]...);clamp_to_segment=false)
    end
    for scale in (1e-100,1.0,1e100,1e308), t in (0.0,0.25)
        start=[-0.5scale,0.0,0.0]
        finish=[0.5scale,0.5scale,0.0]
        point=start+[scale*(0.125+t),scale*(-0.25+0.5t),0.0]
        values=[start;finish;point]
        expected,gradient=setprecision(BigFloat,256) do
            a=BigFloat.(start);b=BigFloat.(finish);p=BigFloat.(point)
            direction=b-a;offset=p-a
            denominator=sum(abs2,direction)
            value=sum(offset.*direction)/denominator
            dp=direction/denominator
            db=(offset-2value*direction)/denominator
            da=-dp-db
            Float64(value),Float64.([da;db;dp])
        end
        @test ForwardDiff.value(parameter(ForwardDiff.Dual.(values,1.0))) ≈ expected atol=1e-15
        @test ForwardDiff.gradient(parameter,values) ≈ gradient rtol=1e-12
        @test reverse_gradient(parameter,values) ≈ gradient rtol=1e-12
    end
end
