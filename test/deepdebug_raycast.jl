using Test, Diff3D

@testset "ray parallel to a line segment reports the three.js hit" begin
    # three.js Ray.distanceSqToSegment (Ray.js:274-277): for a ray parallel to
    # the segment every overlapping point is equally close, and the segment end
    # farthest along the ray is reported. r186 under node gives distance 3 and
    # point (0.05, 0, -3) for all three layouts.
    for points in (((0.05, 0.0, -1.0), (0.05, 0.0, -3.0)),      # along the ray
                   ((0.05, 0.0, -3.0), (0.05, 0.0, -1.0)),      # against it
                   ((0.05, 0.0, 1.0), (0.05, 0.0, -3.0)))       # origin beside the segment
        positions = Float64[]
        foreach(p -> append!(positions, p), points)
        line = LineObject(BufferGeometry(positions, Float64[], Float64[], Int[], 2, 0),
                          LineBasicMaterial())
        raycaster = Raycaster(Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, -1.0); line_threshold=0.1)
        hits = raycast(raycaster, line)
        @test length(hits) == 1
        @test hits[1].distance ≈ 3.0 atol=1e-12
        @test hits[1].point.x ≈ 0.05 atol=1e-12
        @test hits[1].point.z ≈ -3.0 atol=1e-12
    end
    # A segment wholly behind the origin is still a miss, and the generic
    # (non-Float64) method makes the same choice.
    behind = LineObject(BufferGeometry([0.05, 0.0, 1.0, 0.05, 0.0, 3.0], Float64[], Float64[],
                                       Int[], 2, 0), LineBasicMaterial())
    raycaster = Raycaster(Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, -1.0); line_threshold=0.1)
    @test isempty(raycast(raycaster, behind))
    t, distance, point = Diff3D._ray_segment_distance(
        Vec3(big(0.0), big(0.0), big(0.0)), Vec3(big(0.0), big(0.0), big(-1.0)),
        Vec3(big(0.05), big(0.0), big(-1.0)), Vec3(big(0.05), big(0.0), big(-3.0)))
    @test t == 3 && point.z == -3 && distance ≈ 0.05
    # Non-parallel segments are unaffected: closest approach of a crossing line.
    crossing = LineObject(BufferGeometry([-1.0, 0.02, -2.0, 1.0, 0.02, -2.0], Float64[],
                                         Float64[], Int[], 2, 0), LineBasicMaterial())
    hits = raycast(raycaster, crossing)
    @test length(hits) == 1
    @test hits[1].distance ≈ 2.0 atol=1e-12
end
