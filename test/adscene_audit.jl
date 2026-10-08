using Test, Diff3D, ForwardDiff

function adscene_soft_objective(face_count, width; gamma=0.3)
    vertices = [Vec3(-0.8 + 1.6 * mod(0.37 * k, 1.0),
                     -0.8 + 1.6 * mod(0.61 * k, 1.0),
                     0.5 * mod(0.23 * k, 1.0)) for k in 1:3face_count]
    faces = [(3i - 2, 3i - 1, 3i) for i in 1:face_count]
    colors = [Color3(mod(0.3i, 1.0), mod(0.7i, 1.0), mod(0.9i, 1.0))
              for i in 1:face_count]
    params = Float64[]
    for v in vertices
        push!(params, v.x, v.y, v.z)
    end
    for c in colors
        push!(params, c.r, c.g, c.b)
    end
    view_proj = mat4_perspective(0.9, 1.0, 0.1, 10.0) *
                mat4_look_at(Vec3(0.0, 0.0, 3.0), Vec3(), Vec3(0.0, 1.0, 0.0))
    config = SoftRasterizerConfig(sigma=0.8, gamma=gamma,
                                  bg_color=Color3(0.1, 0.2, 0.3))
    objective = function (p)
        T = eltype(p)
        verts = Vec3{T}[Vec3(p[3i - 2], p[3i - 1], p[3i]) for i in 1:3face_count]
        offset = 9face_count
        cols = Color3{T}[Color3(p[offset + 3i - 2], p[offset + 3i - 1], p[offset + 3i])
                         for i in 1:face_count]
        image = soft_render(verts, faces, cols, view_proj, width, width, config)
        total = zero(T)
        for value in image
            total += value * value
        end
        return total
    end
    return objective, params
end

@noinline function adscene_tape_probe(p, captured)
    node = p[1] * p[2]
    captured[] = WeakRef(node)
    return node + p[1]
end

@testset "adscene: reverse tapes release graphs and reuse storage" begin
    captured = Ref(WeakRef(nothing))
    f = p -> adscene_tape_probe(p, captured)
    @test reverse_gradient(f, [2.0, 3.0]) == [4.0, 2.0]
    GC.gc(true); GC.gc(true)
    @test captured[].value === nothing
    @test reverse_gradient(f, [2.0, 3.0]) == [4.0, 2.0]

    inner(y) = reverse_gradient(z -> z[1] * z[1] * y, [3.0])[1]
    outer = p -> p[1] * p[1] + inner(Float64(p[1]))
    @test reverse_gradient(outer, [2.0]) == [4.0]
    @test reverse_gradient(outer, [2.0]) == [4.0]

    squares = p -> sum(x -> x * x, p)
    params = collect(range(-1.0, 1.0; length=64))
    reverse_gradient(squares, params)
    @test reverse_gradient(squares, params) == 2 .* params
    # One fixed-size heap object per recorded operation.
    @test_opt_alloc 16_384 reverse_gradient(squares, params)
end

@testset "adscene: ADVar min/max keep Base primal semantics" begin
    cases = ((NaN, 1.0), (1.0, NaN), (NaN, NaN), (-0.0, 0.0), (0.0, -0.0),
             (2.0, 1.0), (1.0, 2.0), (1.5, 1.5))
    for op in (max, min), (x, y) in cases
        expected = op(x, y)
        @test isequal(reverse_value_gradient(p -> op(p[1], p[2]), [x, y])[1], expected)
        @test isequal(reverse_value_gradient(p -> op(p[1], y), [x])[1], expected)
        @test isequal(reverse_value_gradient(p -> op(x, p[1]), [y])[1], expected)
    end
    relu = reverse_value_gradient(p -> max(p[1], 0.0), [NaN])
    @test isnan(relu[1])
    @test isnan(reverse_value_gradient(p -> 2 * min(0.5, p[1]), [NaN])[1])
    @test reverse_gradient(p -> max(p[1], p[2]), [2.0, 1.0]) == [1.0, 0.0]
    @test reverse_gradient(p -> max(p[1], p[2]), [1.0, 2.0]) == [0.0, 1.0]
    @test reverse_gradient(p -> min(p[1], p[2]), [2.0, 1.0]) == [0.0, 1.0]
    @test reverse_gradient(p -> min(p[1], 3.0) + max(-1.0, p[1]), [2.0]) == [2.0]
    @test reverse_gradient(p -> min(p[1], 1.0) + max(5.0, p[1]), [2.0]) == [0.0]
end

@testset "adscene: soft_render reverse gradients match ForwardDiff" begin
    for (faces, width, gamma) in ((2, 12, 0.3), (20, 20, 0.3), (3, 10, 1.0e-310))
        objective, params = adscene_soft_objective(faces, width; gamma=gamma)
        reverse = reverse_gradient(objective, params)
        forward = ForwardDiff.gradient(objective, params)
        @test all(isfinite, reverse)
        @test all(isfinite, forward)
        @test isapprox(reverse, forward; rtol=1.0e-12)
    end
    for gamma in (1.0e-200, 1.0e-310), faces in (3, 12)
        objective, params = adscene_soft_objective(faces, 10; gamma=gamma)
        forward = ForwardDiff.gradient(objective, params)
        @test all(isfinite, forward)
        @test isapprox(forward, reverse_gradient(objective, params);
                       rtol=1.0e-10, atol=1.0e-12)
    end
    tiny_sigma = SoftRasterizerConfig(sigma=1.0e-200, gamma=0.3)
    sigma_objective = function (p)
        T = eltype(p)
        vertices = [Vec3(p[1], T(-0.5), T(0.0)), Vec3(T(0.5), T(-0.4), T(0.0)),
                    Vec3(T(0.1), T(0.6), T(0.0))]
        return sum(soft_render(vertices, [(1, 2, 3)], [Color3(0.8, 0.2, 0.1)],
                               Mat4(), 6, 6, tiny_sigma))
    end
    @test all(isfinite, ForwardDiff.gradient(sigma_objective, [-0.6]))

    faces = [(1, 2, 3), (2, 4, 3)]
    view_proj = mat4_perspective(0.9, 1.0, 0.1, 10.0) *
                mat4_look_at(Vec3(0.0, 0.0, 3.0), Vec3(), Vec3(0.0, 1.0, 0.0))
    corners = [-0.5, -0.5, 0.0, 0.45, -0.5, 0.0, -0.5, 0.45, 0.1, 0.5, 0.5, 0.1]
    colors = [Color3(0.8, 0.2, 0.2), Color3(0.2, 0.8, 0.2)]
    for gamma in (0.3, 1.0e-200)
        vertex_fn = vertex_render_fn(faces, colors, view_proj, 10, 10;
                                     sigma=0.8, gamma=gamma)
        vertex_loss = p -> sum(abs2, vertex_fn(p))
        forward = ForwardDiff.gradient(vertex_loss, corners)
        @test all(isfinite, forward)
        @test isapprox(forward, reverse_gradient(vertex_loss, corners); rtol=1.0e-10)
        vertices = [Vec3(corners[3i - 2], corners[3i - 1], corners[3i]) for i in 1:4]
        color_fn = color_render_fn(vertices, faces, view_proj, 10, 10;
                                   sigma=0.8, gamma=gamma)
        color_loss = p -> sum(abs2, color_fn(p))
        color_params = [0.8, 0.2, 0.2, 0.2, 0.8, 0.2]
        forward = ForwardDiff.gradient(color_loss, color_params)
        @test all(isfinite, forward)
        @test isapprox(forward, reverse_gradient(color_loss, color_params); rtol=1.0e-10)
        @test eltype(vertex_fn(Float32.(corners))) == Float64
    end

    objective, params = adscene_soft_objective(2, 16)
    reverse_gradient(objective, params)
    # Pixel centres and per-pixel seeds stay off the tape.
    @test_opt_alloc 3_300_000 reverse_gradient(objective, params)
end
