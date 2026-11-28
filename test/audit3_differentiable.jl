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
    # sign is piecewise constant: zero derivative everywhere, including at 0.
    # Base's generic sign returns x itself at zero. ForwardDiff 1.x has the
    # same rule; ForwardDiff 0.10 differentiates the generic method and
    # reports slope 1 at zero, so it is compared away from zero only.
    for x in (-2.0, -0.0, 0.0, 3.0)
        @test reverse_gradient(v -> sign(v[1]) + 2v[1], [x]) == [2.0]
        if !iszero(x) || pkgversion(ForwardDiff) >= v"1"
            @test ForwardDiff.gradient(v -> sign(v[1]) + 2v[1], [x]) == [2.0]
        end
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
    value, _ = reverse_value_gradient(q -> sum(audit3_render(q, count, width, height;
                                                             workspace)), p)
    @test value ≈ sum(audit3_render(p, count, width, height)) rtol=1e-12
    @test workspace.image isa Array{ADVar,3}
    # A reverse pass nested in another records onto its own tape.
    single(q) = sum(audit3_render(q, count, width, height) .* weights)
    nested(q) = single(q) + 0.0 * sum(reverse_gradient(single, [x.val for x in q]))
    @test normwise(reverse_gradient(nested, p), ForwardDiff.gradient(single, p)) < 1e-9
    # Outside a reverse pass ADVar renders evaluate without recording.
    @test map(x -> x.val, audit3_render(ADVar.(p), count, width, height)) ≈
          audit3_render(p, count, width, height) rtol=1e-12 atol=1e-14
end

const AUDIT3_GENERIC_LOSS = Tuple{Array{T,3} where T, Array{S,3} where S}

@testset "Fused reverse MSE and L1 match the recorded compensated sums" begin
    H, W, C = 5, 4, 3
    x = [sin(1.3i) * (i % 4 == 0 ? 0.0 : 1.0) for i in 1:H * W * C]
    target = reshape([cos(0.7i) for i in 1:H * W * C], H, W, C)
    target[1] = x[1]   # an exactly zero difference takes the +1 branch of abs
    for loss in (loss_mse, loss_l1)
        generic(a, b) = invoke(loss, AUDIT3_GENERIC_LOSS, a, b)
        fused_value, fused_grad = reverse_value_gradient(p -> loss(reshape(p, H, W, C), target), x)
        value, grad = reverse_value_gradient(p -> generic(reshape(p, H, W, C), target), x)
        @test fused_value == value
        @test fused_grad == grad
        @test fused_value == loss(reshape(x, H, W, C), target)
        both = vcat(x, vec(target))
        split(p) = (reshape(p[1:end ÷ 2], H, W, C), reshape(p[end ÷ 2 + 1:end], H, W, C))
        @test reverse_gradient(p -> loss(split(p)...), both) ==
              reverse_gradient(p -> generic(split(p)...), both)
        @test reverse_gradient(p -> loss(reshape(x, H, W, C), reshape(p, H, W, C)), vec(target)) ==
              reverse_gradient(p -> generic(reshape(x, H, W, C), reshape(p, H, W, C)), vec(target))
        # Analytic: d MSE/dx_i = 2 (x_i - y_i) / n, d L1/dx_i = sign(x_i - y_i) / n.
        n = H * W * C
        expected = loss === loss_mse ? 2 .* (x .- vec(target)) ./ n :
            [d < 0 ? -1 / n : 1 / n for d in x .- vec(target)]
        @test fused_grad ≈ expected rtol=1e-14
        recorded = Ref(0)
        reverse_gradient(x) do p
            image = reshape(p, H, W, C)
            before = length(Diff3D._ad_tape_stack()[end])
            result = loss(image, target)
            recorded[] = length(Diff3D._ad_tape_stack()[end]) - before
            result
        end
        @test recorded[] == 1
        @test_throws ArgumentError reverse_gradient(p -> loss(reshape(p, H, W, C), zeros(H, W, 2)), x)
    end
end

function audit3_sphere(eye)
    geo = SphereGeometry(radius=1.0, width_segments=16, height_segments=8)
    faces = [get_face(geo, i) for i in 1:geo.n_faces]
    colors = [Color3(0.5, 0.2 + 0.003i, 0.3) for i in eachindex(faces)]
    p = Float64[]
    for i in 1:geo.n_vertices
        v = get_vertex(geo, i)
        push!(p, v.x, v.y, v.z)
    end
    vp = projection_matrix_from_params(pi / 4, 1.0, 0.1, 100.0) *
         view_matrix_from_params(eye..., 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    return p, faces, colors, vp
end

@testset "Reverse soft render projects shared vertices once" begin
    width = height = 24
    # The second eye leaves one vertex behind the near plane, so its faces are
    # clipped into interpolated vertices that must not reuse cached ones.
    for eye in ((0.4, 0.6, 3.0), (0.1, 0.1, 1.05))
        p, faces, colors, vp = audit3_sphere(eye)
        # The exact sphere puts vertices on min/max ties (kinks of the image
        # model), where each AD mode may return a different one-sided
        # derivative. A 1e-9 generic offset keeps the scene and leaves the kinks.
        p .+= 1e-9 .* sin.(1.7 .* eachindex(p))
        render = vertex_render_fn(faces, colors, vp, width, height)
        weights = audit3_weights(height, width)
        objective(q) = sum(render(q) .* weights)
        # Reverse and forward mode differentiate the same primal program.
        @test normwise(reverse_gradient(objective, p), ForwardDiff.gradient(objective, p)) < 1e-9
        recorded = Ref(0)
        reverse_gradient(p) do q
            before = length(Diff3D._ad_tape_stack()[end])
            image = render(q)
            recorded[] = length(Diff3D._ad_tape_stack()[end]) - before
            sum(image)
        end
        # Each of the 153 vertices is transformed and projected once and clip
        # and bounding-box decisions read primal values, leaving about fifty
        # nodes per face for edges and depth; per-face projection of all
        # three vertices recorded about two hundred.
        eye[3] == 3.0 && @test recorded[] <= 3 * width * height + 80 * length(faces)
    end
end

@testset "Fused reverse rules under adversarial objectives" begin
    width, height = 12, 10
    p, faces, colors, vp = audit3_sphere((0.4, 0.6, 3.0))
    render = vertex_render_fn(faces, colors, vp, width, height; sigma=0.7, gamma=0.2)
    # The objective is a fused output leaf itself, and image elements are
    # reused by later nonlinear operations.
    pixel(q) = render(q)[5, 6, 2]
    @test normwise(reverse_gradient(pixel, p), ForwardDiff.gradient(pixel, p)) < 1e-9
    reuse(q) = (image = render(q);
                sum(abs2, image) + image[1, 1, 1] * image[10, 12, 3] + sum(sqrt.(image .+ 1)))
    @test normwise(reverse_gradient(reuse, p), ForwardDiff.gradient(reuse, p)) < 1e-9
    # Fused losses against Float32 and Int targets keep the generic promotion.
    target = render(p .* 1.01)
    for loss in (loss_mse, loss_l1), converted in (Float32.(target), round.(Int, 4 .* target))
        objective(q) = loss(render(q), converted)
        value, gradient = reverse_value_gradient(objective, p)
        @test value == loss(render(p), converted)
        @test normwise(gradient, ForwardDiff.gradient(objective, p)) < 1e-9
    end
    # An error after a fused render releases its pullbacks with the tape.
    @test_throws ErrorException reverse_gradient(q -> (sum(render(q)); error("stop")), p)
    state = Diff3D._ad_tape_state()
    @test isempty(state.stack) && isempty(state.pullbacks)
    @test normwise(reverse_gradient(pixel, p), ForwardDiff.gradient(pixel, p)) < 1e-9
    # Relative-depth mode with gamma and sigma as parameters.
    function relative(q)
        T = eltype(q)
        n = length(q) - 2
        vertices = [Vec3(q[3i - 2], q[3i - 1], q[3i]) for i in 1:(n ÷ 3)]
        config = SoftRasterizerConfig(sigma=q[end - 1], gamma=q[end], eps=T(1e-6))
        face_colors = [Color3(T(c.r), T(c.g), T(c.b)) for c in colors]
        sum(soft_render(vertices, faces, face_colors, Mat4{T}(vp.e), 11, 9, config) .^ 2)
    end
    for gamma in (1e-310, 1e-4)
        q = vcat(p, 0.6, gamma)
        forward = ForwardDiff.gradient(relative, q)
        reverse = reverse_gradient(relative, q)
        @test all(isfinite, forward) && all(isfinite, reverse)
        @test normwise(reverse, forward) < 1e-9
    end
    # Concurrent passes keep task-local tapes and pullback lists apart.
    scales = 1 .+ 0.01 .* (1:8)
    serial = [reverse_gradient(q -> sum(render(q)), p .* s) for s in scales]
    concurrent = Vector{Vector{Float64}}(undef, length(scales))
    Threads.@threads for k in eachindex(scales)
        concurrent[k] = reverse_gradient(q -> sum(render(q)), p .* scales[k])
    end
    @test concurrent == serial
end
