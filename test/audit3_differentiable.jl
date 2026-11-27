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
