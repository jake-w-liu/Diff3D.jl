using Test, Diff3D

@testset "mathapi: add! moves an existing child to the end" begin
    # three.js Object3D.add always removeFromParent() then push (Object3D.js:767-771).
    parent, a, b = Group(), Object3D(), Object3D()
    add!(parent, a); add!(parent, b)
    @test add!(parent, a) === parent
    @test get_children(parent) == [b, a]
    @test get_parent(a) === parent
    add!(parent, a)
    @test get_children(parent) == [b, a]
    lod = LOD()
    shared = Object3D()
    add_lod_level!(lod, 0.0, shared)
    add_lod_level!(lod, 5.0, shared)
    @test length(lod.levels) == 2
    @test get_children(lod) == [shared]
end

@testset "mathapi: lod_select applies hysteresis to visible levels" begin
    # three.js LOD.getObjectForDistance (LOD.js:188-219).
    lod = LOD()
    near, far = Object3D(), Object3D()
    add_lod_level!(lod, 0, near); add_lod_level!(lod, 10, far; hysteresis=0.5)
    far.visible = true
    @test lod_select(lod, 6) === far
    @test lod_select(lod, 4.9) === near
    far.visible = false
    @test lod_select(lod, 6) === near
    @test lod_select(lod, 10) === far
end

@testset "mathapi: single-level LOD update leaves visibility alone" begin
    # three.js LOD.update only acts when levels.length > 1 (LOD.js:254).
    lod = LOD(); only_level = Object3D()
    add_lod_level!(lod, 0, only_level)
    only_level.visible = false
    @test lod_update!(lod, PerspectiveCamera()) === only_level
    @test !only_level.visible
    @test lod_update!(lod, 3.0) === only_level
    @test !only_level.visible
    scene = Scene(); add!(scene, lod)
    mesh = Mesh(BoxGeometry(), MeshBasicMaterial(color=Color3(1.0, 0.0, 0.0)))
    single = LOD(); add_lod_level!(single, 0.0, mesh); add!(scene, single)
    mesh.visible = false
    target = RenderTarget(8, 8)
    render!(target, scene, PerspectiveCamera())
    @test !mesh.visible
    @test maximum(target.color) == 0.0
end

@testset "mathapi: LOD raycast tests the ray-distance level" begin
    # three.js LOD.raycast (LOD.js:228-242) and Raycaster intersect().
    lod = LOD()
    m1 = Mesh(BoxGeometry(), MeshBasicMaterial())
    m2 = Mesh(BoxGeometry(), MeshBasicMaterial())
    add_lod_level!(lod, 0, m1); add_lod_level!(lod, 10, m2)
    lod_update!(lod, 1.0)
    rc = Raycaster(Vec3(0.0, 0.0, 50.0), Vec3(0.0, 0.0, -1.0))
    single = raycast(rc, lod; recursive=false)
    @test !isempty(single) && all(hit -> hit.object === m2, single)
    @test single[1].distance ≈ 49.5
    hits = raycast(rc, lod)
    @test any(hit -> hit.object === m2, hits) && any(hit -> hit.object === m1, hits)
    @test issorted([hit.distance for hit in hits])
    near_rc = Raycaster(Vec3(0.0, 0.0, 3.0), Vec3(0.0, 0.0, -1.0))
    @test all(hit -> hit.object === m1, raycast(near_rc, lod; recursive=false))
    lod.position = Vec3(0.0, 0.0, -40.0)
    @test all(hit -> hit.object === m2, raycast(near_rc, lod; recursive=false))
    layers_set!(object_layers(lod), 3)
    @test isempty(raycast(near_rc, lod; recursive=false))
    @test isempty(raycast(rc, LOD(); recursive=false))
end

@testset "mathapi: points report the closest ray point; line threshold inclusive" begin
    geo = BufferGeometry([2.0, 0.5, 0.0], Float64[], Float64[], Int[], 1, 0)
    points = PointsObject(geo, PointsMaterial())
    hit = only(raycast(Raycaster(Vec3(), Vec3(1.0, 0.0, 0.0)), points))
    # three.js Points testPoint: point = ray.closestPointToPoint, index = vertex.
    @test hit.point == Vec3(2.0, 0.0, 0.0)
    @test hit.distance == 2.0 && hit.face_index == 1
    behind = BufferGeometry([-0.5, 0.5, 0.0], Float64[], Float64[], Int[], 1, 0)
    hit = only(raycast(Raycaster(Vec3(), Vec3(1.0, 0.0, 0.0)), PointsObject(behind, PointsMaterial())))
    @test hit.point == Vec3() && hit.distance == 0.0
    # three.js Line checkIntersection rejects only distSq > thresholdSq.
    seg = BufferGeometry([1.0, -1.0, 0.5, 1.0, 1.0, 0.5], Float64[], Float64[], Int[], 2, 0)
    line = LineSegments(seg, LineBasicMaterial())
    @test length(raycast(Raycaster(Vec3(), Vec3(1.0, 0.0, 0.0); line_threshold=0.5), line)) == 1
    @test isempty(raycast(Raycaster(Vec3(), Vec3(1.0, 0.0, 0.0); line_threshold=prevfloat(0.5)), line))
    exact = LineObject(BufferGeometry([1.0, -1.0, 0.0, 1.0, 1.0, 0.0], Float64[], Float64[], Int[], 2, 0),
                       LineBasicMaterial())
    @test length(raycast(Raycaster(Vec3(), Vec3(1.0, 0.0, 0.0); line_threshold=0.0), exact)) == 1
end

@testset "mathapi: Raycaster defaults to layer channel 0" begin
    # three.js Raycaster.js:69 `this.layers = new Layers()` (channel 0 only).
    rc = Raycaster(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, -1.0))
    @test rc.layers.mask == UInt32(1)
    box = Mesh(BoxGeometry(), MeshBasicMaterial())
    @test !isempty(raycast(rc, box))
    layers_set!(object_layers(box), 4)
    @test isempty(raycast(rc, box))
    layers_enable!(rc.layers, 4)
    @test !isempty(raycast(rc, box))
end
