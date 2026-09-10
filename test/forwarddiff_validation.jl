using Diff3D, ForwardDiff, Test
@testset "Dual partials cannot change parameter validity" begin
    positive_zero=ForwardDiff.Dual(0.0,1.0)
    for property in (:sigma,:gamma,:eps)
        @test_throws ArgumentError SoftRasterizerConfig(;NamedTuple{(property,)}((positive_zero,))...)
    end
    @test_throws ArgumentError mat4_perspective(positive_zero,1.0,0.1,10.0)
    @test_throws ArgumentError mat4_perspective(1.0,positive_zero,0.1,10.0)
    @test_throws ArgumentError mat4_perspective(1.0,1.0,positive_zero,10.0)
    @test_throws ArgumentError mat4_perspective(1.0,1.0,0.1,ForwardDiff.Dual(0.1,1.0))
    @test_throws ArgumentError mat4_perspective(ForwardDiff.Dual(Float64(pi),-1.0),1.0,0.1,10.0)
    @test_throws ArgumentError mat4_orthographic(ForwardDiff.Dual(1.0,-1.0),1.0,-1.0,1.0,0.0,10.0)
    @test_throws ArgumentError mat4_orthographic(-1.0,1.0,ForwardDiff.Dual(1.0,-1.0),1.0,0.0,10.0)
    @test_throws ArgumentError mat4_orthographic(-1.0,1.0,-1.0,1.0,0.1,ForwardDiff.Dual(0.1,1.0))
end

@testset "AD validation preserves values and derivatives" begin
    for property in (:sigma,:gamma,:eps), partial in (-1.0,0.0,1.0), value in (0.0,-0.1,Inf,NaN)
        parameter=ForwardDiff.Dual(value,partial)
        @test_throws "SoftRasterizerConfig $property must be finite and positive" SoftRasterizerConfig(;
            NamedTuple{(property,)}((parameter,))...)
    end
    for property in (:sigma,:gamma,:eps)
        derivative=ForwardDiff.derivative(1.5) do value
            config=SoftRasterizerConfig(;NamedTuple{(property,)}((value,))...)
            getproperty(config,property)
        end
        @test derivative==1.0
        zero_parameter=ForwardDiff.Dual(0.0,1.0)
        constant=one(zero_parameter)
        config=SoftRasterizerConfig(
            property===:sigma ? zero_parameter : constant,
            property===:gamma ? zero_parameter : constant,
            Color3(zero(zero_parameter),zero(zero_parameter),zero(zero_parameter)),
            property===:eps ? zero_parameter : constant)
        @test_throws "SoftRasterizerConfig $property must be finite and positive" soft_render(
            Vec3{Float64}[],NTuple{3,Int}[],Color3{Float64}[],Mat4(),1,1,config)
    end
    @test_throws ArgumentError ForwardDiff.derivative(0.0) do x
        ForwardDiff.derivative(y->SoftRasterizerConfig(sigma=x*y).sigma,1.0)
    end
    nested_derivative=ForwardDiff.derivative(3.0) do x
        ForwardDiff.derivative(y->SoftRasterizerConfig(sigma=x*y).sigma,2.0)
    end
    @test nested_derivative==1.0
    mixed=ForwardDiff.Dual(ADVar(0.0),ADVar(1.0))
    @test_throws ArgumentError SoftRasterizerConfig(sigma=mixed)
    @test reverse_gradient(x->SoftRasterizerConfig(sigma=x[1]^2).sigma,[1.5])==[3.0]

    for partial in (-1.0,0.0,1.0)
        d(x)=ForwardDiff.Dual(x,partial)
        @test_throws "mat4_perspective fov must" mat4_perspective(d(0.0),1.0,0.1,10.0)
        @test_throws "mat4_perspective fov must" mat4_perspective(d(Float64(pi)),1.0,0.1,10.0)
        @test_throws "mat4_perspective aspect must" mat4_perspective(1.0,d(0.0),0.1,10.0)
        @test_throws "mat4_perspective near must" mat4_perspective(1.0,1.0,d(0.0),10.0)
        @test_throws "mat4_perspective far must" mat4_perspective(1.0,1.0,0.1,d(0.1))
        @test_throws "mat4_orthographic left and right must differ" mat4_orthographic(d(1.0),1.0,-1.0,1.0,0.0,10.0)
        @test_throws "mat4_orthographic bottom and top must differ" mat4_orthographic(-1.0,1.0,d(1.0),1.0,0.0,10.0)
        @test_throws "mat4_orthographic near and far must differ" mat4_orthographic(-1.0,1.0,-1.0,1.0,0.1,d(0.1))
    end
    fov=0.7;aspect=1.3
    @test ForwardDiff.derivative(x->mat4_perspective(x,aspect,0.1,10.0).e[6],fov)≈-0.5/sin(fov/2)^2
    @test ForwardDiff.derivative(x->mat4_perspective(fov,x,0.1,10.0).e[1],aspect)≈-1/(tan(fov/2)*aspect^2)
    @test ForwardDiff.derivative(x->mat4_orthographic(x,1.0,-1.0,1.0,0.0,10.0).e[1],-1.0)≈0.5
    @test ForwardDiff.derivative(x->mat4_orthographic(1.0,x,1.0,-1.0,10.0,0.0).e[1],-1.0)≈-0.5
    @test ForwardDiff.derivative(x->projection_matrix_from_params(fov,aspect,x,Inf).e[15],0.1)==-2.0
end
