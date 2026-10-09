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

@testset "mathapi: quat_slerp switches to nlerp at dot == 0.9995" begin
    # three.js Quaternion.slerp: `if ( dot < 0.9995 )` slerps, otherwise nlerp.
    a = Quaternion(0.0, 0.0, 0.0, 1.0)
    b = Quaternion(sqrt(1 - 0.9995^2), 0.0, 0.0, 0.9995)
    @test quat_dot(a, b) == 0.9995
    t = 0.5
    expected = quat_normalize(Quaternion(a.x * (1 - t) + b.x * t, a.y * (1 - t) + b.y * t,
                                         a.z * (1 - t) + b.z * t, a.w * (1 - t) + b.w * t))
    q = quat_slerp(a, b, t)
    @test abs(q.x - expected.x) <= eps() / 8 && abs(q.w - expected.w) <= eps() / 8
end

function _mathapi_raycast_allocations(rc, scene)
    raycast(rc, scene)
    return @allocated raycast(rc, scene)
end

@testset "mathapi: raycast traversal and bounding-sphere rejection" begin
    scene = Scene()
    geometry = BoxGeometry()
    for i in 1:200
        group = Group(); group.position = Vec3(0.1i, 0.0, -0.3)
        mesh = Mesh(geometry, MeshBasicMaterial())
        mesh.position = Vec3(0.5i, 0.0, -5.0); mesh.scale = Vec3(1.0, 2.0, 0.5)
        add!(group, mesh); add!(scene, group)
    end
    rc = Raycaster(Vec3(0.6, 0.3, 10.0), Vec3(0.0, 0.0, -1.0))
    hits = raycast(rc, scene)
    @test length(hits) == 1 && hits[1].distance ≈ 15.05
    if Base.JLOptions().opt_level > 0
        # One traversal stack and the result vector; no per-object boxing.
        @test _mathapi_raycast_allocations(rc, scene) <= 1024
    end
    # A grazing ray through a box corner stays a hit after the sphere test.
    corner = Mesh(BoxGeometry(), MeshBasicMaterial(side=:double))
    corner.position = Vec3(1.0e6, -2.0e6, 3.0)
    corner_point = Vec3(1.0e6 + 0.5, -2.0e6 + 0.5, 3.5)
    graze = Raycaster(corner_point + Vec3(-3.0, 0.0, 4.0), Vec3(3.0, 0.0, -4.0))
    @test !isempty(raycast(graze, corner))
    # Projective instance matrices bypass the affine-only shortcut.
    projective = InstancedMesh(PlaneGeometry(width=2.0, height=2.0),
                               MeshBasicMaterial(side=:double),
                               [Mat4((1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
                                      0.0, 0.0, 1.0, 0.25, 0.0, 0.0, 0.0, 1.0))])
    @test length(raycast(Raycaster(Vec3(0.1, 0.2, 5.0), Vec3(0.0, 0.0, -1.0)), projective)) == 1
    # Morphed positions feed the bounds, so a morph-moved mesh is still found.
    plane = PlaneGeometry(width=1.0, height=1.0)
    set_attribute!(plane, :morphPosition0, repeat([10.0, 0.0, 0.0], plane.n_vertices), 3)
    morphed = Mesh(plane, MeshBasicMaterial(); morph_target_influences=[1.0])
    @test length(raycast(Raycaster(Vec3(10.1, 0.2, 5.0), Vec3(0.0, 0.0, -1.0)), morphed)) == 1
    @test isempty(raycast(Raycaster(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, -1.0)), morphed))
end

@testset "mathapi: mat4 compose/decompose/determinant round-trip" begin
    pos = Vec3(1.5, -2.0, 3.25)
    q = quat_normalize(Quaternion(0.3, -0.4, 0.5, 0.7))
    scl = Vec3(2.0, 0.5, 3.0)
    m = mat4_compose(pos, q, scl)
    @test m == mat4_translation(pos.x, pos.y, pos.z) * quat_to_mat4(q) *
              mat4_scaling(scl.x, scl.y, scl.z)
    @test mat4_determinant(m) ≈ scl.x * scl.y * scl.z
    @test mat4_determinant(Mat4{Float64}()) == 1.0
    @test mat4_determinant(mat4_inverse(m)) ≈ 1 / mat4_determinant(m)

    p2, q2, s2 = mat4_decompose(m)
    @test p2 == pos
    @test s2.x ≈ scl.x && s2.y ≈ scl.y && s2.z ≈ scl.z
    same_rotation(a, b) = all(getfield(a, f) ≈ getfield(b, f) for f in (:x, :y, :z, :w))
    @test same_rotation(q2, q) ||
          same_rotation(q2, Quaternion(-q.x, -q.y, -q.z, -q.w))
    @test all(quat_to_mat4(q2).e .≈ quat_to_mat4(q).e)
    @test quat_from_rotation_matrix(quat_to_mat4(q)) |> r ->
        same_rotation(r, q) || same_rotation(r, Quaternion(-q.x, -q.y, -q.z, -q.w))

    # A negative determinant negates the x scale, matching three.js, and the
    # decompose -> compose round-trip rebuilds the matrix.
    neg = mat4_compose(pos, q, Vec3(-scl.x, scl.y, scl.z))
    pn, qn, sn = mat4_decompose(neg)
    @test sn.x ≈ -scl.x && sn.y ≈ scl.y && sn.z ≈ scl.z
    @test all(mat4_compose(pn, qn, sn).e .≈ neg.e)

    # Singular linear parts degrade to identity rotation and unit scale.
    sing = mat4_compose(pos, q, Vec3(0.0, 1.0, 1.0))
    @test mat4_decompose(sing) == (pos, Quaternion(), Vec3(1.0, 1.0, 1.0))
end
