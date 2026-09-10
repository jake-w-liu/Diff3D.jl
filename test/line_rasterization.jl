using Test
using Diff3D

@testset "Line coverage and depth are independent of scissor" begin
    color = Color3(0.8, 0.4, 0.2)
    function reference(width, height, endpoints, line_width, alpha)
        target = RenderTarget(width, height)
        setprecision(BigFloat, 256) do
            x0, y0, z0, x1, y1, z1 = BigFloat.(endpoints)
            dx, dy = x1 - x0, y1 - y0
            length_squared = dx * dx + dy * dy
            radius = max(BigFloat(0.5), BigFloat(line_width) / 2)
            for y in 1:height, x in 1:width
                t = iszero(length_squared) ? BigFloat(0) :
                    clamp(((x - x0) * dx + (y - y0) * dy) / length_squared, 0, 1)
                distance_squared = (x - (x0 + dx * t))^2 + (y - (y0 + dy * t))^2
                if distance_squared <= radius^2
                    depth = iszero(length_squared) ? min(z0, z1) : z0 * (1 - t) + z1 * t
                    target.depth[y, x] = Float64(depth)
                    target.color[y, x, :] .= (color.r * alpha, color.g * alpha, color.b * alpha)
                end
            end
        end
        return target
    end

    cases = ((1.2, 3.7, 0.1, 30.8, 21.2, 0.9),
             (4.2, 2.3, 0.9, 8.8, 23.0, 0.2),
             (-5.0, 8.0, 0.2, 40.0, 8.0, 0.8),
             (7.0, -5.0, 0.2, 7.0, 40.0, 0.8),
             (12.0, 13.0, 0.6, 12.0, 13.0, 0.2))
    for endpoints in cases, line_width in (1.0, 3.0), alpha in (1.0, 0.4)
        expected = reference(32, 24, endpoints, line_width, alpha)
        for reverse in (false, true), scissor in ((1, 32, 1, 24), (8, 25, 6, 20))
            coordinates = reverse ? (endpoints[4:6]..., endpoints[1:3]...) : endpoints
            actual = RenderTarget(32, 24)
            Diff3D._draw_line!(actual, coordinates..., color, line_width,
                               scissor..., true, true, alpha)
            xlo, xhi, ylo, yhi = scissor
            @test actual.color[ylo:yhi, xlo:xhi, :] ≈ expected.color[ylo:yhi, xlo:xhi, :]
            @test isinf.(actual.depth[ylo:yhi, xlo:xhi]) == isinf.(expected.depth[ylo:yhi, xlo:xhi])
            mask = isfinite.(expected.depth[ylo:yhi, xlo:xhi])
            @test actual.depth[ylo:yhi, xlo:xhi][mask] ≈ expected.depth[ylo:yhi, xlo:xhi][mask] atol=1e-12
        end
    end

    for line_width in (1.0, 1e12)
        target = RenderTarget(8, 8)
        Diff3D._draw_line!(target, -1e308, -1e308, 0.0, 1e308, 1e308, 0.8,
                           color, line_width)
        @test all(isfinite(target.depth[i, i]) for i in 1:8)
        @test all(target.depth[i, i] ≈ 0.4 for i in 1:8)
        line_width > 8 && @test all(isfinite, target.depth)
    end
end
