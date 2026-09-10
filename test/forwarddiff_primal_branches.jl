using Diff3D, ForwardDiff, Test
@testset "ForwardDiff predicate migration" begin
@testset "Dual inputs preserve defined degenerate math values" begin
    d=ForwardDiff.Dual(0.0,1.0);z=zero(d);o=one(d)
    @test ForwardDiff.value(norm(Vec3(d,z,z)))==0.0
    n=normalize(Vec3(d,z,z))
    @test all(iszero,(ForwardDiff.value(n.x),ForwardDiff.value(n.y),ForwardDiff.value(n.z)))
    q=quat_normalize(Quaternion(d,z,z,z))
    @test (ForwardDiff.value(q.x),ForwardDiff.value(q.y),ForwardDiff.value(q.z),ForwardDiff.value(q.w))==(0.0,0.0,0.0,1.0)
    m=Mat4((o+d,o,z,z,o,o,z,z,z,z,o,z,z,z,z,o))
    @test all(x->iszero(ForwardDiff.value(x)),mat4_inverse(m).e)
end

@testset "AD view and coordinate branches preserve primal values" begin
    d=ForwardDiff.Dual(0.0,1.0);z=zero(d)
    @test ForwardDiff.value(Diff3D._mat4_linear_max_scale(mat4_scaling(d,z,z)))==0.0
    spherical=cartesian_to_spherical(Vec3(d,z,z))
    @test (ForwardDiff.value(spherical.radius),ForwardDiff.value(spherical.phi),ForwardDiff.value(spherical.theta))==(0.0,0.0,0.0)
    for partial in (-1.0,1.0), up in (Vec3(0.0,1.0,0.0),Vec3(1.0,0.0,0.0)), x in (0.0,1e-6)
        y=x==0.0 ? 0.0 : sqrt(1-x*x)
        eye=Vec3(ForwardDiff.Dual(x,partial),y,0.0)
        expected=mat4_look_at(Vec3(x,y,0.0),Vec3(),up)
        actual=mat4_look_at(eye,Vec3(),up)
        @test maximum(abs.(ForwardDiff.value.(collect(actual.e)).-collect(expected.e)))<=1e-12
    end
end

@testset "Loss and interpolation parameter domains" begin
    image=zeros(3,3,1)
    d=ForwardDiff.Dual(0.0,1.0)
    @test_throws ArgumentError loss_ssim(image,image;window_size=3,C1=d)
    @test_throws ArgumentError loss_ssim(image,image;window_size=3,C2=d)
    @test_throws ArgumentError interpolate_linear([zero(d),d],[0.0,1.0],0.5)
    @test Diff3D._checked_silhouette_threshold(ForwardDiff.Dual(0.0,-1.0)) isa ForwardDiff.Dual
    @test Diff3D._checked_silhouette_threshold(ForwardDiff.Dual(1.0,1.0)) isa ForwardDiff.Dual
    for threshold in (ForwardDiff.Dual(0.0,-1.0),ForwardDiff.Dual(1.0,1.0))
        @test isfinite(loss_silhouette_iou(fill(one(threshold),1,1,1),zeros(1,1,1);threshold=threshold))
    end
end
end

@testset "Primal guards retain derivatives away from singularities" begin
    point=[1.0,2.0,3.0]
    jacobian=ForwardDiff.jacobian(point) do p
        result=normalize(Vec3(p...))
        [result.x,result.y,result.z]
    end
    squared_length=sum(abs2,point)
    expected=[((i==j ? 1.0 : 0.0)-point[i]*point[j]/squared_length)/sqrt(squared_length) for i in 1:3,j in 1:3]
    @test jacobian≈expected atol=1e-12 rtol=1e-12
    function inverse_entry(x)
        z=zero(x);o=one(x)
        mat4_inverse(Mat4((o+x,o,z,z,o,o,z,z,z,z,o,z,z,z,z,o))).e[1]
    end
    @test ForwardDiff.derivative(inverse_entry,0.5)≈-4.0
    @test reverse_gradient(p->inverse_entry(p[1]),[0.5])≈[-4.0]
end
