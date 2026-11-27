using Test, Diff3D, ForwardDiff

# Round-2 regression tests for the reverse-mode engine and the soft rasterizer.
# None of these paths has a three.js counterpart; the expectations come from
# analytic derivatives, ForwardDiff (DiffRules formulas), central finite
# differences, and agreement between the AD modes.

const AUDIT3B_ADVar = Diff3D.ADVar

audit3b_reverse_derivative(f, x::Float64) = reverse_gradient(
    v -> (y = f(v[1]); y isa AUDIT3B_ADVar ? y : AUDIT3B_ADVar(y)), [x])[1]

audit3b_central(f, x, h) = (f(x + h) - f(x - h)) / (2h)

# Central differences at several step sizes; the best one must match.
function audit3b_fd_agrees(f, x, derivative; rtol=1e-6)
    errors = [abs(audit3b_central(f, x, h) - derivative) for h in (1e-4, 1e-5, 1e-6)]
    return minimum(errors) <= rtol * max(1.0, abs(derivative))
end

@testset "Reverse ADVar covers the remaining Base math functions" begin
    # Each function previously raised a MethodError on ADVar (or, for fma,
    # Base's "fma not defined for ADVar"). Derivative rules: DiffRules
    # src/rules.jl (sinpi, cospi, asinh, acosh, atanh, sinc, ldexp, rem2pi)
    # and the product rule for fma.
    cases = (
        (sinpi, (0.3, -1.7, 2.0, 0.5)),
        (cospi, (0.3, -1.7, 2.0, 0.5)),
        (x -> sum(sincospi(x) .* (1.0, 2.0)), (0.3, -1.25)),
        (sinc, (0.3, -2.5, 1e-3, 1e-9, 7.0)),
        (cosc, (0.3, -2.5, 1e-3, 1e-9, 7.0)),
        (asinh, (0.7, -3.0, 1e-8, 40.0)),
        (acosh, (1.7, 1.01, 40.0)),
        (atanh, (0.3, -0.99, 1e-8)),
        (x -> ldexp(x, 3), (0.7, -2.5)),
        (x -> ldexp(x, -5), (0.7,)),
        (mod2pi, (-1.0, 7.0, 20.0)),
        (x -> rem2pi(x, RoundNearest), (7.0, -4.0)),
        (x -> rem2pi(x, RoundDown), (7.0, -4.0)),
        (x -> rem2pi(x, RoundUp), (7.0, -4.0)),
        (x -> rem2pi(x, RoundToZero), (7.0, -4.0)),
        (x -> fma(x, 2x, 3.0), (0.7, -1.3)),
        (x -> fma(x, x, x), (0.7, -1.3)),
        (x -> fma(2.0, 3.0, x), (0.7,)),
        (x -> fma(x, 1.5f0, 2), (0.7,)),
        (x -> asech(x), (0.3,)),
        (x -> acsch(x), (0.7,)),
        (x -> acoth(x), (1.7,)),
    )
    for (f, points) in cases, x in points
        reverse = audit3b_reverse_derivative(f, x)
        forward = ForwardDiff.derivative(f, x)
        @test isapprox(reverse, forward; rtol=1e-12, atol=1e-300)
        @test audit3b_fd_agrees(f, x, reverse)
    end
    # ForwardDiff has no tanpi rule; d/dx tanpi(x) = π / cospi(x)^2.
    for x in (0.3, -0.2, 1.1)
        reverse = audit3b_reverse_derivative(tanpi, x)
        @test isapprox(reverse, π / cospi(x)^2; rtol=1e-14)
        @test audit3b_fd_agrees(tanpi, x, reverse)
    end
    # Function values are those of Base's Float64 methods.
    for x in (0.3, -1.7, 2.0)
        @test sinpi(AUDIT3B_ADVar(x)).val === sinpi(x)
        @test cospi(AUDIT3B_ADVar(x)).val === cospi(x)
        @test fma(AUDIT3B_ADVar(x), AUDIT3B_ADVar(0.1), AUDIT3B_ADVar(-x / 10)).val ===
              fma(x, 0.1, -x / 10)
    end
    # Exact derivative at integer points: d/dx sinpi = π cospi, cospi(2) == 1.
    @test audit3b_reverse_derivative(sinpi, 2.0) == Float64(π)
    @test audit3b_reverse_derivative(cospi, 2.0) == 0.0
    # fma's three partials through the two-parent tape (product rule).
    @test reverse_gradient(v -> fma(v[1], v[2], v[3]), [0.5, -3.0, 2.0]) == [-3.0, 0.5, 1.0]
end

@testset "Reverse ADVar inverse hyperbolics stay accurate in the tails" begin
    # asinh'(x) = 1/sqrt(1+x^2): at 1e200 the naive square overflows to Inf and
    # returns 0; the exact value is 1e-200 (to within one ulp).
    @test isapprox(audit3b_reverse_derivative(asinh, 1e200), 1e-200; rtol=1e-15)
    # acosh'(x) = 1/(sqrt(x-1) sqrt(x+1)): at 1e200 the product form is finite.
    @test isapprox(audit3b_reverse_derivative(acosh, 1e200), 1e-200; rtol=1e-15)
    # atanh'(x) = 1/((1-x)(1+x)), exact factors near |x| = 1.
    x = 1 - 2.0^-30
    @test audit3b_reverse_derivative(atanh, x) == inv((1 - x) * (1 + x))
    @test audit3b_reverse_derivative(acosh, 1.0) == Inf
end

@testset "Reverse ADVar cosc derivative near zero" begin
    # cosc = sinc', so cosc'(x) = sinc''(x) = -(π² sinc(x) + 2 cosc(x)/x),
    # with limit -π²/3 at zero (Taylor series of sinc). Reference values are
    # evaluated in 4096-bit BigFloat (enough to resolve x^2 at x = 1e-300).
    reference(x) = setprecision(BigFloat, 4096) do
        b = BigFloat(x)
        iszero(b) && return Float64(-big(π)^2 / 3)
        s = sinpi(b) / (big(π) * b)
        c = (cospi(b) - s) / b
        Float64(-(big(π)^2 * s + 2c / b))
    end
    for x in (0.0, 1e-300, 1e-12, 5e-5, 1.5e-4, 1e-3, 0.3, -2.5)
        @test isapprox(audit3b_reverse_derivative(cosc, x), reference(x); rtol=1e-13)
    end
    # sinc'(x) = cosc(x); the generic sinpi(x)/(πx) chain rule cancels badly
    # at 1e-9 (true value -π²·1e-9/3).
    @test isapprox(audit3b_reverse_derivative(sinc, 1e-9), cosc(1e-9); rtol=1e-14)
end

@testset "Reverse ADVar degree trigonometry uses exact Base values" begin
    # Base.sind reduces in degrees, so sind(180) == 0 and cosd(90) == 0 exactly;
    # sin(deg2rad(180)) == 1.22e-16. The derivative d/dx sind = (π/180) cosd(x)
    # (DiffRules) is exactly zero at 90 degrees.
    @test sind(AUDIT3B_ADVar(180.0)).val === 0.0
    @test cosd(AUDIT3B_ADVar(90.0)).val === 0.0
    @test tand(AUDIT3B_ADVar(45.0)).val === 1.0
    @test audit3b_reverse_derivative(sind, 90.0) == 0.0
    @test audit3b_reverse_derivative(cosd, 180.0) == 0.0
    for f in (sind, cosd, tand, x -> sum(sincosd(x))), x in (30.0, -75.0, 123.0)
        @test isapprox(audit3b_reverse_derivative(f, x), ForwardDiff.derivative(f, x); rtol=1e-14)
    end
end

@testset "Reverse ADVar promotion, traits and integer division" begin
    # Mixed scalar types promote into the tape (promote_rule ADVar <: Real).
    f(x) = 3 * x + 1.5f0 * x^2 + π * x + true * x - ℯ
    g = reverse_gradient(v -> f(v[1]), [0.7])[1]
    @test isapprox(g, ForwardDiff.derivative(f, 0.7); rtol=1e-15)
    @test promote_type(AUDIT3B_ADVar, Float32) === AUDIT3B_ADVar
    @test promote_type(AUDIT3B_ADVar, Bool) === AUDIT3B_ADVar
    @test promote_type(AUDIT3B_ADVar, Irrational{:π}) === AUDIT3B_ADVar
    # Traits of the Float64 primal, as ForwardDiff reports for Dual{T,Float64}.
    @test typemax(AUDIT3B_ADVar) === Inf
    @test typemin(AUDIT3B_ADVar) === -Inf
    @test eps(AUDIT3B_ADVar) === eps(Float64)
    @test floatmax(AUDIT3B_ADVar) === floatmax(Float64)
    @test floatmin(AUDIT3B_ADVar) === floatmin(Float64)
    @test maxintfloat(AUDIT3B_ADVar) === maxintfloat(Float64)
    @test precision(AUDIT3B_ADVar) == 53
    @test precision(AUDIT3B_ADVar(1.0)) == 53
    # fld/cld between two ADVars raised Base's MethodError; they are discrete.
    @test fld(AUDIT3B_ADVar(7.0), AUDIT3B_ADVar(2.0)) === 3.0
    @test cld(AUDIT3B_ADVar(7.0), AUDIT3B_ADVar(2.0)) === 4.0
    @test cld(AUDIT3B_ADVar(-7.0), AUDIT3B_ADVar(2.0)) === -3.0
end

@testset "Reverse ADVar kinks select a one-sided derivative" begin
    # At nonsmooth points the reverse engine returns one of the one-sided
    # derivatives (docs/src/compatibility.md: a selected branch derivative).
    # ForwardDiff chooses differently at some of these points (it returns NaN
    # for mod/rem/hypot kinks), so compare against one-sided differences.
    h = 1e-7
    one_sided(f, x) = ((f(x + h) - f(x)) / h, (f(x) - f(x - h)) / h)
    for (f, x) in ((abs, 0.0), (x -> max(x, 0.5), 0.5), (x -> min(x, 0.5), 0.5),
                   (x -> clamp(x, 0.0, 0.5), 0.5), (x -> mod(x, 1.0), 1.0),
                   (x -> rem(x, 1.0), 1.0), (x -> rem2pi(x, RoundDown), 2π),
                   (x -> hypot(x, 0.0, 0.0), 0.0), (floor, 2.0), (round, 2.5))
        d = audit3b_reverse_derivative(f, x)
        right, left = one_sided(f, x)
        @test isapprox(d, right; atol=1e-6) || isapprox(d, left; atol=1e-6)
    end
    # Integer powers of negative bases and 0^0 (x^0 == 1 for every x).
    @test audit3b_reverse_derivative(x -> x^3, -2.0) == 12.0
    @test audit3b_reverse_derivative(x -> x^-2, -2.0) == 0.25
    @test audit3b_reverse_derivative(x -> x^0, 0.0) == 0.0
    @test audit3b_reverse_derivative(x -> x^2.0, -2.0) == -4.0
end

# One instanced double-sided plane facing the camera, lit from the front.
function audit3b_mirrored_instance_scene(; base_mirror::Bool, instance_mirror::Bool)
    scene = Scene(background=Color3(0.1, 0.2, 0.3))
    material = MeshLambertMaterial(color=Color3(0.8, 0.6, 0.4), side=:double)
    instances = InstancedMesh(PlaneGeometry(width=2.0, height=2.0), material, 1)
    set_instance_matrix!(instances, 1,
                         instance_mirror ? mat4_scaling(-1.0, 1.0, 1.0) : Mat4())
    base_mirror && (instances.scale = Vec3(1.0, -1.0, 1.0))
    add!(scene, instances)
    light = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=1.0)
    light.position = Vec3(0.0, 0.0, 5.0)
    add!(scene, light)
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.2))
    camera = PerspectiveCamera(fov=0.9, aspect=1.0, near=0.1, far=100.0)
    camera.position = Vec3(0.0, 0.0, 4.0)
    return scene, camera
end

@testset "soft_render_scene flips instanced front faces by the object matrix only" begin
    # three.js flips the front face for a mirrored object matrixWorld only
    # (WebGLRenderer.js `frontFaceCW`, WebGLState.js setFlipSided); a mirrored
    # instance matrix reverses the triangle winding without flipping, so a
    # double-sided face shows its back (normal negated, gl_FrontFacing false).
    # render! follows that; at small sigma/gamma the soft image's interior
    # pixel must carry the same face colour.
    for (base_mirror, instance_mirror) in ((false, true), (true, true),
                                           (true, false), (false, false))
        scene, camera = audit3b_mirrored_instance_scene(
            base_mirror=base_mirror, instance_mirror=instance_mirror)
        target = RenderTarget(16, 16)
        render!(target, scene, camera)
        soft = soft_render_scene(scene, camera, 16, 16; sigma=1e-4, gamma=1e-4)
        @test isapprox(soft[8, 8, :], target.color[8, 8, :]; atol=1e-6)
    end
    # The back face (base unmirrored, instance mirrored) receives only the
    # ambient term, far darker than the directly lit front, so the comparison
    # above discriminates the two shadings.
    scene, camera = audit3b_mirrored_instance_scene(base_mirror=false, instance_mirror=true)
    soft = soft_render_scene(scene, camera, 16, 16; sigma=1e-4, gamma=1e-4)
    lit_scene, lit_camera = audit3b_mirrored_instance_scene(base_mirror=false, instance_mirror=false)
    lit = soft_render_scene(lit_scene, lit_camera, 16, 16; sigma=1e-4, gamma=1e-4)
    @test soft[8, 8, 1] < 0.5 * lit[8, 8, 1]
end
