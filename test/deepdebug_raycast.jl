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

function deepdebug_raycast_allocations(raycaster, object)
    raycast(raycaster, object)
    raycast(raycaster, object)
    return @allocated raycast(raycaster, object)
end

@testset "sprite and LOD raycasts do not box matrices" begin
    camera = PerspectiveCamera(fov=pi / 3, aspect=1.0, near=0.1, far=50.0)
    camera.position = Vec3(0.0, 0.0, 5.0)
    raycaster = Raycaster(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, -1.0); camera)
    sprite = Sprite(SpriteMaterial(color=Color3(1.0, 0.8, 0.3)))
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial())
    lod = LOD()
    far_level = Mesh(BoxGeometry(), MeshBasicMaterial())
    far_level.position = Vec3(40.0, 0.0, 0.0)       # the ray misses it
    add_lod_level!(lod, 0.0, far_level)
    nested = LOD()
    add_lod_level!(nested, 0.0, lod)
    hits = raycast(raycaster, sprite)
    @test length(hits) == 1
    @test hits[1].distance ≈ 5.0 atol=1e-12
    @test hits[1].uv.x ≈ 0.5 atol=1e-12
    @test isempty(raycast(raycaster, lod))
    @test isempty(raycast(raycaster, nested))
    # The matrix stack is balanced after hits, misses and errors.
    @test isempty(raycaster.worlds) || all(isfinite, raycaster.worlds[end].e)
    depth = length(raycaster.worlds)
    raycast(raycaster, sprite); raycast(raycaster, nested)
    @test length(raycaster.worlds) == depth
    no_camera = Raycaster(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, -1.0))
    @test_throws ArgumentError raycast(no_camera, sprite)
    @test isempty(no_camera.worlds)
    # A sprite under a moved parent is still hit where it is drawn.
    group = Group(); group.position = Vec3(0.0, 0.25, 0.0)
    child = Sprite(SpriteMaterial()); add!(group, child)
    moved = raycast(raycaster, group)
    @test length(moved) == 1 && moved[1].object === child
    if Base.JLOptions().opt_level > 0
        # One result vector with one Intersection, as for a mesh hit; a miss
        # allocates only the empty result. Boxed matrices used to add 700 B.
        mesh_hit = deepdebug_raycast_allocations(raycaster, mesh)
        @test deepdebug_raycast_allocations(raycaster, sprite) <= mesh_hit
        @test deepdebug_raycast_allocations(raycaster, lod) <= 64
        @test deepdebug_raycast_allocations(raycaster, nested) <= 64
    end
end

@testset "layer masks are read without the global lock until layers are used" begin
    # Objects that never had layers assigned share the default mask.
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial())
    @test Diff3D._object_layer_mask(mesh) == Diff3D._DEFAULT_OBJECT_LAYER_MASK
    layered = Mesh(BoxGeometry(), MeshBasicMaterial())
    layers_set!(object_layers(layered), 3)
    @test Diff3D._OBJECT_LAYER_STORE_USED[]
    @test Diff3D._object_layer_mask(layered) == UInt32(1) << 3
    @test Diff3D._object_layer_mask(mesh) == Diff3D._DEFAULT_OBJECT_LAYER_MASK
    # Off the face diagonal, so exactly one triangle is hit.
    raycaster = Raycaster(Vec3(0.1, 0.2, 5.0), Vec3(0.0, 0.0, -1.0))
    @test length(raycast(raycaster, mesh)) == 1
    @test isempty(raycast(raycaster, layered))            # channel 3 is not watched
    layers_set!(raycaster.layers, 3)
    @test length(raycast(raycaster, layered)) == 1
    # Lookups from many tasks agree with the serial answer.
    objects = [Mesh(BoxGeometry(), MeshBasicMaterial()) for _ in 1:64]
    foreach(i -> layers_set!(object_layers(objects[i]), i % 5), 1:2:64)
    expected = [Diff3D._object_layer_mask(o) for o in objects]
    results = fetch.([Threads.@spawn [Diff3D._object_layer_mask(o) for o in objects] for _ in 1:8])
    @test all(==(expected), results)
end
