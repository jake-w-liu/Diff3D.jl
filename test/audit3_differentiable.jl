using Test, Diff3D, ForwardDiff

# Regression tests for the differentiable subsystem (soft rasterizer, reverse
# tape, losses, optimizers). The image model has no three.js counterpart; the
# expectations below are derived from the Soft Rasterizer formulation
# (Liu et al. 2019), finite differences, and ForwardDiff/reverse agreement.

# Pixel (4, 4) sees three faces in index order. The first lies far behind the
# nearest face (depth logit gap 720 at gamma=0.001), so its weight value
# underflows to zero while its derivative is a nonzero subnormal; the second
# has an exactly zero weight. Dividing by that zero-valued Dual total produced
# NaN partials although the image value is finite.
function audit3_underflow_pixel(p)
    T = eltype(p)
    zb = p[1]
    vertices = Vec3{T}[Vec3(0.25, -0.9, zb), Vec3(0.875, -0.9, zb), Vec3(0.25, 0.9, zb),
                       Vec3(0.25, -0.9, 0.9), Vec3(0.875, -0.9, 0.9), Vec3(0.25, 0.9, 0.9),
                       Vec3(-1.0, -1.0, -0.5), Vec3(3.0, -1.0, -0.5), Vec3(-1.0, 3.0, -0.5)]
    colors = [Color3(T(0.9), T(0.1), T(0.1)), Color3(T(0.1), T(0.9), T(0.1)),
              Color3(T(0.2), T(0.3), T(0.8))]
    config = SoftRasterizerConfig(sigma=T(0.05), gamma=T(0.001))
    image = soft_render(vertices, [(1, 2, 3), (4, 5, 6), (7, 8, 9)], colors,
                        Mat4{T}(), 8, 8, config)
    return image[4, 4, 1]
end

# gamma below 1/floatmax selects the relative-depth weights. Equal depths with
# different partials, and a depth gap whose weight underflows while its
# derivative is 0 * Inf, must not produce NaN gradients.
function audit3_relative_depth_sum(p)
    T = eltype(p)
    vertices = Vec3{T}[Vec3(-0.8, -0.8, p[1]), Vec3(0.8, -0.8, p[1]), Vec3(0.0, 0.8, p[1]),
                       Vec3(-0.6, -0.6, p[2]), Vec3(0.9, -0.5, p[2]), Vec3(0.1, 0.9, p[2])]
    colors = [Color3(T(0.9), T(0.1), T(0.1)), Color3(T(0.1), T(0.9), T(0.1))]
    config = SoftRasterizerConfig(sigma=T(1.0), gamma=T(1e-310))
    return sum(soft_render(vertices, [(1, 2, 3), (4, 5, 6)], colors, Mat4{T}(), 6, 6, config))
end

@testset "Soft render ForwardDiff gradients stay finite when weights underflow" begin
    value = audit3_underflow_pixel([0.22])
    @test isfinite(value)
    forward = ForwardDiff.gradient(audit3_underflow_pixel, [0.22])
    @test all(isfinite, forward)
    # The underflowed face has weight below floatmin, so its exact derivative
    # contribution is far below Float64 resolution of the pixel: both AD modes
    # agree on zero.
    @test forward == reverse_gradient(audit3_underflow_pixel, [0.22])
    for p in ([0.3, 0.3], [0.3, 0.31], [0.31, 0.3], [0.1, 0.3])
        forward = ForwardDiff.gradient(audit3_relative_depth_sum, p)
        @test all(isfinite, forward)
        @test forward == reverse_gradient(audit3_relative_depth_sum, p)
    end
end

@testset "Reverse rem and sign derivatives follow the primal branch" begin
    # rem(a, b) = a - b * div(a, b), so d/db = -div(a, b). In Float64,
    # div(1.0, 0.1) == 9 (0.1 is slightly above 1/10) while 1.0 / 0.1 rounds
    # to 10.0; the derivative must use the quotient the remainder used.
    @test rem(1.0, 0.1) ≈ 1.0 - 9 * 0.1
    @test reverse_gradient(x -> rem(x[1], x[2]), [1.0, 0.1]) == [1.0, -9.0]
    @test reverse_gradient(x -> rem(1.0, x[1]), [0.1]) == [-9.0]
    @test reverse_gradient(x -> rem(x[1], x[2]), [-1.0, 0.1]) == [1.0, 9.0]
    # b = 0.1 sits just above the quotient-10 boundary (b < 0.1 gives
    # quotient 10), so the branch the primal uses is the one to its right.
    h = 1e-7
    @test (rem(1.0, 0.1 + h) - rem(1.0, 0.1)) / h ≈ -9.0 rtol=1e-6
    # sign is piecewise constant: zero derivative everywhere, including at 0
    # (ForwardDiff agrees). Base's generic sign returns x itself at zero.
    for x in (-2.0, -0.0, 0.0, 3.0)
        @test reverse_gradient(v -> sign(v[1]) + 2v[1], [x]) == [2.0]
        @test ForwardDiff.gradient(v -> sign(v[1]) + 2v[1], [x]) == [2.0]
    end
end

# Deterministic scene: `count` triangles scattered across the view, some
# crossing the near plane (z close to the camera) and some back-facing.
function audit3_scene_params(count)
    p = Float64[]
    for i in 1:count
        cx = 0.9 * sin(1.7i)
        cy = 0.8 * cos(2.3i)
        cz = 0.6 * sin(0.9i) - 0.1
        r = 0.25 + 0.2 * abs(sin(3.1i))
        for k in 0:2
            a = 2pi * k / 3 + 0.4i
            # every fourth triangle reaches through the near plane
            z = i % 4 == 0 && k == 0 ? 1.2 : cz + 0.1 * cos(a)
            push!(p, cx + r * cos(a), cy + r * sin(a), z)
        end
    end
    for i in 1:count
        push!(p, 0.5 + 0.4 * sin(i), 0.5 + 0.4 * cos(1.3i), 0.5 + 0.4 * sin(2.1i))
    end
    return p
end

# Parameters: vertices, colors, then sigma, gamma, eps, bg rgb, camera shift.
function audit3_render(p, count, width, height; gamma_mode=:param, workspace=nothing)
    T = eltype(p)
    vertices = [Vec3(p[3i - 2], p[3i - 1], p[3i]) for i in 1:3count]
    offset = 9count
    colors = [Color3(p[offset + 3i - 2], p[offset + 3i - 1], p[offset + 3i]) for i in 1:count]
    offset += 3count
    gamma = gamma_mode === :relative ? T(1e-310) : p[offset + 2]
    config = SoftRasterizerConfig(sigma=p[offset + 1], gamma=gamma, eps=p[offset + 3],
                                  bg_color=Color3(p[offset + 4], p[offset + 5], p[offset + 6]))
    view_projection = mat4_translation(p[offset + 7], p[offset + 8], zero(T)) *
        projection_matrix_from_params(T(pi / 3), T(width / height), T(0.1), T(6)) *
        view_matrix_from_params(T(0.2), T(0.1), T(2.0), zero(T), zero(T), zero(T),
                                zero(T), one(T), zero(T))
    faces = [(3i - 2, 3i - 1, 3i) for i in 1:count]
    return soft_render(vertices, faces, colors, view_projection, width, height, config;
                       workspace)
end

audit3_full_params(count, sigma, gamma) =
    vcat(audit3_scene_params(count), [sigma, gamma, 1e-3, 0.1, 0.2, 0.3, 0.05, -0.03])

audit3_weights(height, width) =
    [sin(0.37i + 0.11j + 0.7c) for i in 1:height, j in 1:width, c in 1:3]

normwise(a, b) = maximum(abs, a .- b) / maximum(abs, b)

@testset "Fused reverse soft render matches ForwardDiff" begin
    # The reverse rule must reproduce the derivative of the recorded image
    # model for every input kind; ForwardDiff differentiates the generic path.
    for (count, width, height) in ((3, 9, 7), (14, 23, 19)),
        sigma in (0.3, 1.5), gamma in (0.05, 1.0), gamma_mode in (:param, :relative)
        p = audit3_full_params(count, sigma, gamma)
        weights = audit3_weights(height, width)
        objective(q) = sum(audit3_render(q, count, width, height; gamma_mode) .* weights)
        forward = ForwardDiff.gradient(objective, p)
        reverse = reverse_gradient(objective, p)
        @test all(isfinite, reverse)
        @test normwise(reverse, forward) < 1e-9
        target = audit3_render(p .* 0.97, count, width, height; gamma_mode)
        loss(q) = loss_mse(audit3_render(q, count, width, height; gamma_mode), target)
        @test normwise(reverse_gradient(loss, p), ForwardDiff.gradient(loss, p)) < 1e-9
        # Image values are those of the Float64 renderer up to the rounding of
        # the ADVar camera matrix (generic rather than Float64 math methods).
        values = Ref{Array{Float64,3}}()
        reverse_gradient(p) do q
            image = audit3_render(q, count, width, height; gamma_mode)
            values[] = map(x -> x.val, image)
            sum(image)
        end
        @test values[] ≈ audit3_render(p, count, width, height; gamma_mode) rtol=1e-12 atol=1e-14
    end
end

@testset "Fused reverse soft render tape stays proportional to inputs" begin
    count, width, height = 14, 40, 36
    p = audit3_full_params(count, 1.0, 1.0)
    recorded = Ref(0)
    reverse_gradient(p) do q
        before = length(Diff3D._ad_tape_stack()[end])
        image = audit3_render(q, count, width, height)
        recorded[] = length(Diff3D._ad_tape_stack()[end]) - before
        sum(image)
    end
    # One leaf per image channel plus a bounded number of nodes per face for
    # projection, clipping and depth logits; recording the pixel stage
    # operation by operation took about a hundred nodes per face-pixel pair.
    @test recorded[] <= 3 * width * height + 400 * count
end

@testset "Fused reverse soft render with workspaces and nesting" begin
    count, width, height = 14, 17, 15
    p = audit3_full_params(count, 0.8, 0.5)
    weights = audit3_weights(height, width)
    workspace = SoftRenderWorkspace{ADVar}()
    # Two renders through one workspace: the first image is consumed before
    # the second overwrites the workspace storage.
    function twice(q; workspace=nothing)
        first = sum(audit3_render(q, count, width, height; workspace) .* weights)
        second = sum(audit3_render(q .* 1.01, count, width, height; workspace) .* weights)
        return first + 2second
    end
    expected = ForwardDiff.gradient(twice, p)
    @test normwise(reverse_gradient(q -> twice(q; workspace), p), expected) < 1e-9
    image = reverse_value_gradient(q -> sum(audit3_render(q, count, width, height;
                                                          workspace)), p)
    @test workspace.image isa Array{ADVar,3}
    # A reverse pass nested in another records onto its own tape.
    single(q) = sum(audit3_render(q, count, width, height) .* weights)
    nested(q) = single(q) + 0.0 * sum(reverse_gradient(single, [x.val for x in q]))
    @test normwise(reverse_gradient(nested, p), ForwardDiff.gradient(single, p)) < 1e-9
    # Outside a reverse pass ADVar renders evaluate without recording.
    @test map(x -> x.val, audit3_render(ADVar.(p), count, width, height)) ≈
          audit3_render(p, count, width, height) rtol=1e-12 atol=1e-14
end
