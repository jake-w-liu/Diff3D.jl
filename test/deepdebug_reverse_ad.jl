using Test, Diff3D, ForwardDiff, LinearAlgebra

@testset "ADVar zero and one predicates keep dependent values on the tape" begin
    A = [1.0 2.0; 3.0 4.0]
    B = [0.5, -1.0]
    C0 = [0.3, 0.7]
    # s(α, β) = sum(α A B + β C0): ∂s/∂α = sum(A B) = -4 and ∂s/∂β = sum(C0) = 1
    # for every α and β. LinearAlgebra's mul! skips the scaling when
    # isone(α) and the accumulation when iszero(β).
    scaled(z) = (T = eltype(z); C = T.(C0); mul!(C, A, T.(B), z[1], z[2]); sum(C))
    @test reverse_gradient(scaled, [1.0, 0.0]) ≈ [-4.0, 1.0] atol=1e-12
    @test reverse_gradient(scaled, [1.5, 0.5]) ≈ [-4.0, 1.0] atol=1e-12
    # u(s, v) = sum(s v): ∂u/∂s = sum(v); lmul! returns early when isone(s).
    scale_vector(z) = (v = collect(z[2:3]); lmul!(z[1], v); sum(v))
    @test reverse_gradient(scale_vector, [1.0, 2.0, 3.0]) ≈ [5.0, 1.0, 1.0] atol=1e-12
    # ∂(x / |x|)₃/∂x at the unit vector e₃ is zero in every component.
    unit_z(z) = LinearAlgebra.normalize(z)[3]
    @test reverse_gradient(unit_z, [0.0, 0.0, 1.0]) ≈ [0.0, 0.0, 0.0] atol=1e-12
    @test reverse_gradient(unit_z, [0.0, 0.6, 0.8]) ≈
          ForwardDiff.gradient(unit_z, [0.0, 0.6, 0.8]) atol=1e-12
    seen = Bool[]
    reverse_gradient([1.0, 0.0]) do z
        push!(seen, isone(z[1]), iszero(z[2]), isone(z[1] * 1.0), iszero(z[2] + 0.0))
        z[1] + z[2]
    end
    @test seen == [false, false, false, false]
    # Constants keep the value-based answer, inside and outside a gradient pass.
    @test iszero(zero(ADVar)) && isone(one(ADVar))
    @test iszero(ADVar(0.0)) && isone(ADVar(1.0)) && !iszero(ADVar(2.0))
    constants = Bool[]
    reverse_gradient([3.0]) do z
        c = convert(ADVar, 2.0) - 2.0
        push!(constants, iszero(c), isone(c + 1.0), iszero(zero(z[1])), isone(one(z[1])))
        z[1]
    end
    @test constants == [true, true, true, true]
    # A fused soft-render output depends on the vertices it was rendered from.
    vp = mat4_orthographic(-1.0, 1.0, -1.0, 1.0, 0.1, 10.0)
    flags = Bool[]
    reverse_gradient([-0.5, -0.5, 0.5, -0.5, 0.0, 0.5]) do p
        verts = [Vec3{ADVar}(p[1], p[2], -1.0), Vec3{ADVar}(p[3], p[4], -1.0),
                 Vec3{ADVar}(p[5], p[6], -1.0)]
        image = soft_render(verts, [(1, 2, 3)], [Color3{ADVar}(1.0, 0.0, 0.0)], vp, 4, 4,
                            SoftRasterizerConfig(sigma=1.0))
        push!(flags, any(iszero, image), any(isone, image))
        sum(image)
    end
    @test flags == [false, false]
end

@testset "ADVar promotes with BigFloat" begin
    # Base's promote_rule(BigFloat, <:Real) = BigFloat used to disagree with
    # promote_rule(ADVar, <:Real) = ADVar and recurse until the stack overflowed.
    @test promote_type(ADVar, BigFloat) === ADVar
    @test promote_type(BigFloat, ADVar) === ADVar
    # d/dy atan(y, 1.5) = 1.5 / (y² + 1.5²) = 0.6 at y = 0.5.
    @test reverse_gradient(x -> atan(x[1], big(1.5)), [0.5]) ≈ [0.6] rtol=1e-14
    @test reverse_gradient(x -> clamp(x[1], big(0.0), big(1.0)), [0.5]) == [1.0]
    @test reverse_gradient(x -> x[1] * big(2.0) + big(1.0), [0.5]) == [2.0]
    @test reverse_gradient(x -> x[1]^big(3.0), [2.0]) ≈ [12.0] rtol=1e-14
    @test reverse_gradient(x -> big(2.0)^x[1], [3.0]) ≈ [8 * log(2.0)] rtol=1e-14
end

@testset "ADVar rules for cotd, acot, acsch and asech" begin
    derivative(f, x) = reverse_gradient(z -> f(z[1]), [x])[1]
    # d/dx cotd(x) = -(π/180)(1 + cotd(x)²); Base's inv(tand(x)) chain gave 0 at 90.
    @test derivative(cotd, 90.0) ≈ -π / 180 rtol=1e-14
    @test derivative(cotd, 30.0) ≈ -(π / 180) * (1 + cotd(30.0)^2) rtol=1e-13
    # d/dx acot(x) = -1/(1 + x²); the atan(1/x) chain underflowed to 0.
    @test derivative(acot, 1e-200) == -1.0
    @test derivative(acot, 2.0) ≈ -0.2 rtol=1e-14
    @test derivative(acot, 1e200) ≈ -1e-400 atol=0.0     # underflows to -0.0, finite
    @test isfinite(derivative(acot, 1e200))
    # d/dx acsch(x) = -1/(|x| sqrt(1 + x²)) and d/dx asech(x) = -1/(x sqrt(1 - x²)).
    @test derivative(acsch, 1e-200) ≈ -1e200 rtol=1e-14
    @test derivative(acsch, -2.0) ≈ -1 / (2 * sqrt(5.0)) rtol=1e-14
    @test derivative(asech, 1e-200) ≈ -1e200 rtol=1e-14
    @test derivative(asech, 0.5) ≈ -1 / (0.5 * sqrt(0.75)) rtol=1e-14
    for (f, points) in ((cotd, (12.5, -77.0, 200.0)), (acot, (0.3, -4.0)),
                        (acsch, (0.3, -4.0)), (asech, (0.2, 0.9)))
        for x in points
            @test derivative(f, x) ≈ ForwardDiff.derivative(f, x) rtol=1e-12
            @test reverse_value_gradient(z -> f(z[1]), [x])[1] == f(x)
        end
    end
end

@testset "ADVar isequal agrees with its hash" begin
    @test !isequal(ADVar(0.0), ADVar(-0.0))
    @test hash(ADVar(0.0)) != hash(ADVar(-0.0))
    @test isequal(ADVar(NaN), ADVar(NaN))
    @test hash(ADVar(NaN)) == hash(ADVar(NaN))
    @test isequal(ADVar(1.5), 1.5) && isequal(1.5, ADVar(1.5))
    @test !isequal(ADVar(0.0), -0.0) && !isequal(-0.0, ADVar(0.0))
    @test length(unique([ADVar(2.0), ADVar(2.0), ADVar(NaN), ADVar(NaN)])) == 2
    @test ADVar(0.0) == ADVar(-0.0)          # == stays value-based
end

@testset "soft render gradient on a triangle edge is the interior derivative" begin
    # An odd width puts world x = 0 on the centres of pixel column 5, so the
    # edge a-c (x = p) passes exactly through pixel centres at p = 0.
    width, height = 9, 8
    vp = mat4_orthographic(-1.0, 1.0, -1.0, 1.0, 0.1, 10.0)
    function coverage(p, counterclockwise)
        T = eltype(p)
        a = Vec3{T}(p[1], 0.0, -1.0)
        b = Vec3{T}(1.0, 0.0, -1.0)
        c = Vec3{T}(p[2], 1.0, -1.0)
        verts = counterclockwise ? [a, b, c] : [a, c, b]
        image = soft_render(verts, [(1, 2, 3)], [Color3{T}(1.0, 0.0, 0.0)], vp,
                            width, height, SoftRasterizerConfig(sigma=1.0))
        return sum(image)
    end
    total(g) = g[1] + g[2]
    for counterclockwise in (true, false)
        f = p -> coverage(p, counterclockwise)
        @test f([0.0, 0.0]) == coverage([0.0, 0.0], !counterclockwise)
        # Just left of zero the on-edge pixels are strictly inside the triangle.
        interior = total(reverse_gradient(f, [-1e-12, -1e-12]))
        exterior = total(reverse_gradient(f, [1e-12, 1e-12]))
        @test abs(interior - exterior) > 1.0          # a real kink
        on_edge = total(reverse_gradient(f, [0.0, 0.0]))
        @test on_edge ≈ interior rtol=1e-9
    end
    # The helper returns the same value as point_line_distance for both
    # orientations and every sign of the edge function.
    for (px, area) in ((0.25, 1.0), (0.25, -1.0), (-0.25, 1.0), (-0.25, -1.0),
                       (0.0, 1.0), (0.0, -1.0))
        d = ForwardDiff.Dual(px, 1.0)
        got = Diff3D._soft_inside_line_distance(d, 0.5, 0.0, 0.0, 0.0, 1.0, area)
        @test ForwardDiff.value(got) == point_line_distance(px, 0.5, 0.0, 0.0, 0.0, 1.0)
        @test !signbit(ForwardDiff.value(got))
    end
end
