using Diff3D, ForwardDiff, Test

@testset "Triangle normals retain derivatives of planar coordinates" begin
    for scale in (1e-100,1e-6,1.0,1e6,1e100), sign in (-1.0,1.0)
        triangle=z->Triangle(Vec3(0.0,0.0,z),
            Vec3(sign*scale,zero(z),zero(z)),Vec3(zero(z),scale,zero(z)))
        for axis in 1:3
            f=z->getfield(triangle_normal(triangle(z)),axis)
            expected=axis==1 ? 1/scale : axis==2 ? sign/scale : 0.0
            @test ForwardDiff.value(f(ForwardDiff.Dual(0.0,1.0)))==(axis==3 ? sign : 0.0)
            @test ForwardDiff.derivative(f,0.0) ≈ expected rtol=1e-12
            @test reverse_gradient(q->f(q[1]),[0.0])[1] ≈ expected rtol=1e-12
        end
        area=z->triangle_area(triangle(z))
        @test ForwardDiff.value(area(ForwardDiff.Dual(0.0,1.0))) ≈ scale^2/2 rtol=1e-12
        @test ForwardDiff.derivative(area,0.0)==0.0
        @test reverse_gradient(q->area(q[1]),[0.0])==[0.0]
    end
end

function triangle_from_coordinates(v)
    return Triangle(Vec3(v[1],v[2],v[3]),Vec3(v[4],v[5],v[6]),Vec3(v[7],v[8],v[9]))
end

function triangle_coordinate_oracle(values)
    return setprecision(BigFloat,256) do
        a,b,c=BigFloat.(values[1:3]),BigFloat.(values[4:6]),BigFloat.(values[7:9])
        cross_product(x,y)=[x[2]*y[3]-x[3]*y[2],x[3]*y[1]-x[1]*y[3],x[1]*y[2]-x[2]*y[1]]
        ab,ac=b-a,c-a
        normal=cross_product(ab,ac)
        magnitude=sqrt(sum(abs2,normal))
        unit=normal/magnitude
        jacobian=Matrix{BigFloat}(undef,3,9)
        area_gradient=Vector{BigFloat}(undef,9)
        for vertex in 1:3, axis in 1:3
            basis=BigFloat[i==axis for i in 1:3]
            change=vertex==1 ? -cross_product(basis,ac)-cross_product(ab,basis) :
                   vertex==2 ? cross_product(basis,ac) : cross_product(ab,basis)
            radial=sum(unit.*change)
            column=3*(vertex-1)+axis
            jacobian[:,column]=(change-unit*radial)/magnitude
            area_gradient[column]=radial/2
        end
        Float64.(unit),Float64(magnitude/2),Float64.(jacobian),Float64.(area_gradient)
    end
end

@testset "Triangle coordinate Jacobians match analytic oracles" begin
    normal=v->begin
        n=triangle_normal(triangle_from_coordinates(v))
        [n.x,n.y,n.z]
    end
    area=v->triangle_area(triangle_from_coordinates(v))
    for scale in (1e-100,1.0,1e100), height in (0.0,0.75)
        translation=[2.0,-3.0,5.0]
        values=scale*[translation+[0.25,-0.5,0.0];
                      translation+[1.0,0.5,0.0];
                      translation+[-0.5,1.0,height]]
        unit,surface,jacobian,gradient=triangle_coordinate_oracle(values)
        dual_values=ForwardDiff.Dual.(values,1.0)
        @test ForwardDiff.value.(normal(dual_values)) ≈ unit rtol=1e-12
        @test ForwardDiff.value(area(dual_values)) ≈ surface rtol=1e-12
        @test ForwardDiff.jacobian(normal,values) ≈ jacobian rtol=1e-12
        for axis in 1:3
            @test reverse_gradient(v->normal(v)[axis],values) ≈ jacobian[axis,:] rtol=1e-12
        end
        @test ForwardDiff.gradient(area,values) ≈ gradient rtol=1e-12
        @test reverse_gradient(area,values) ≈ gradient rtol=1e-12
    end
end

slope_triangle(z)=Triangle(Vec3(0.0,0.0,z),Vec3(one(z),zero(z),zero(z)),Vec3(zero(z),one(z),zero(z)))

function triangle_operation_allocation(operation,triangle)
    operation(triangle)
    return @allocated operation(triangle)
end

@testset "Triangle gradient boundaries and allocation" begin
    for (operation,expected) in ((t->triangle_normal(t).x,0.0),
                                 (t->triangle_normal(t).z,-2.0),(triangle_area,1.0))
        @test ForwardDiff.derivative(z->ForwardDiff.derivative(y->operation(slope_triangle(y)),z),0.0) ≈ expected
    end
    # A normalized component can be representable even when its scale factor
    # alone exceeds Float64. Compare that boundary with a high-precision product.
    for minor in (-nextfloat(0.0),0.0,nextfloat(0.0))
        logscale=log(1e-15)
        expected=setprecision(BigFloat,256) do
            Float64(BigFloat(minor)*BigFloat(1e308)/exp(BigFloat(logscale)))
        end
        @test Diff3D._triangle_rescale_minor(minor,1e308,1.0,logscale) ≈ expected rtol=1e-12
    end
    if Base.JLOptions().opt_level > 0
        triangle=slope_triangle(ForwardDiff.Dual(0.0,1.0))
        for operation in (triangle_normal,triangle_area)
            triangle_operation_allocation(operation,triangle)
            @test triangle_operation_allocation(operation,triangle) <= 64
        end
    end
end
