using Test, Diff3D

# Expected values come from three.js r186 (build/three.module.js) run in node on
# the same scenes; three.js indices are 0-based, Diff3D's are 1-based.

audit3_box_mesh(side) =
    Mesh(BoxGeometry(width=1.0, height=1.0, depth=1.0), MeshBasicMaterial(side=side))

@testset "Raycast culls mirrored meshes in local space" begin
    # three.js Mesh.raycast tests triangles against the ray transformed into
    # local space (src/objects/Mesh.js:267-268, checkIntersection
    # src/objects/Mesh.js:421-433), so a negative-determinant world matrix does
    # not swap which side is culled. Oracle: BoxGeometry(1,1,1), scale (-1,1,1),
    # ray (0.1,0.2,5) -> -Z gives FrontSide [4.5 @ z=0.5], BackSide
    # [5.5 @ z=-0.5], DoubleSide both.
    expected = Dict(:front => [4.5], :back => [5.5], :double => [4.5, 5.5])
    for side in (:front, :back, :double)
        mesh = audit3_box_mesh(side)
        mesh.scale = Vec3(-1.0, 1.0, 1.0)
        rc = Raycaster(Vec3(0.1, 0.2, 5.0), Vec3(0.0, 0.0, -1.0))
        hits = raycast(rc, mesh)
        @test [hit.distance for hit in hits] ≈ expected[side] atol = 1e-12
        @test all(hit -> abs(hit.point.z) ≈ 0.5, hits)

        # A mirroring parent and a mirroring instance matrix behave the same
        # (InstancedMesh.raycast composes matrixWorld * instanceMatrix,
        # src/objects/InstancedMesh.js:283-291).
        parent = Group()
        parent.scale = Vec3(1.0, -1.0, 1.0)
        child = audit3_box_mesh(side)
        add!(parent, child)
        @test [hit.distance for hit in raycast(rc, parent)] ≈ expected[side] atol = 1e-12

        instances = InstancedMesh(BoxGeometry(width=1.0, height=1.0, depth=1.0),
                                  MeshBasicMaterial(side=side),
                                  [mat4_scaling(1.0, 1.0, -1.0)])
        instance_hits = raycast(rc, instances)
        @test [hit.distance for hit in instance_hits] ≈ expected[side] atol = 1e-12
        @test all(hit -> hit.instance_id == 1, instance_hits)
    end
end

function audit3_single_bone_box(side)
    geometry = BoxGeometry(width=1.0, height=1.0, depth=1.0)
    n = geometry.n_vertices
    bone = Bone()
    skin = SkinnedMesh(geometry, MeshBasicMaterial(side=side), Skeleton([bone]),
                       fill((1, 1, 1, 1), n), fill((1.0, 0.0, 0.0, 0.0), n))
    add!(skin, bone)
    return skin, bone
end

@testset "Raycast culls mirrored skinned meshes in local space" begin
    # three.js SkinnedMesh.raycast also tests in the mesh's local space
    # (src/objects/SkinnedMesh.js:196-209). Oracle: box skinned to one bone,
    # mesh scale (-1,1,1), bind(), bone moved to (0.25,0,0); ray (0.1,0.2,5)
    # -> -Z: FrontSide [4.5], BackSide [5.5], DoubleSide [4.5, 5.5].
    expected = Dict(:front => [4.5], :back => [5.5], :double => [4.5, 5.5])
    for side in (:front, :back, :double), mode in (:attached, :detached)
        skin, bone = audit3_single_bone_box(side)
        skin.scale = Vec3(-1.0, 1.0, 1.0)
        bind_skeleton!(skin, skin.skeleton; bind_mode=mode)
        bone.position = Vec3(0.25, 0.0, 0.0)
        rc = Raycaster(Vec3(0.1, 0.2, 5.0), Vec3(0.0, 0.0, -1.0))
        @test [hit.distance for hit in raycast(rc, skin)] ≈ expected[side] atol = 1e-12
    end
end

@testset "Sprites scale before rotating, like three.js" begin
    # three.js Sprite.raycast transformVertex (src/objects/Sprite.js:233-239)
    # and the sprite vertex shader scale the centered corner by the world scale
    # and then rotate it. Oracle: PerspectiveCamera(90, 1, 0.1, 30) at the
    # origin looking down -Z, Sprite scale (0.8,0.3,1), rotation pi/2 at
    # (0,0,-4); rays from the origin toward (x, y, -4).
    camera = PerspectiveCamera(fov=pi / 2, aspect=1.0, near=0.1, far=30.0)
    camera.position = Vec3()
    camera.target = Vec3(0.0, 0.0, -1.0)
    sprite = Sprite(SpriteMaterial(rotation=pi / 2))
    sprite.scale = Vec3(0.8, 0.3, 1.0)
    sprite.position = Vec3(0.0, 0.0, -4.0)
    oracle = ((0.3, 0.0, nothing), (0.0, 0.3, 4.011234224026316),
              (0.1, 0.35, 4.016528351698765), (0.35, 0.1, nothing))
    for (x, y, distance) in oracle
        hits = raycast(Raycaster(Vec3(), Vec3(x, y, -4.0); camera=camera), sprite)
        if distance === nothing
            @test isempty(hits)
        else
            @test only(hits).distance ≈ distance rtol = 1e-14
            @test norm(only(hits).point - Vec3(x, y, -4.0)) < 1e-12
        end
    end

    # The rasterizer draws the same quad: tall (0.8) and narrow (0.3).
    view = OrthographicCamera(left=-1.0, right=1.0, bottom=-1.0, top=1.0,
                              near=0.1, far=10.0)
    view.position = Vec3()
    view.target = Vec3(0.0, 0.0, -1.0)
    scene = Scene()
    add!(scene, sprite)
    target = RenderTarget(40, 40)
    render!(target, scene, view)
    covered = [sum(target.color[i, j, :]) > 0 for i in 1:40, j in 1:40]
    rows = findall(vec(any(covered; dims=2)))
    cols = findall(vec(any(covered; dims=1)))
    @test length(rows) == 16   # 0.8 of a 2.0-unit, 40-pixel frustum
    @test length(cols) == 6    # 0.3 of a 2.0-unit, 40-pixel frustum
end

# Brute-force reference: every drawn face against the world-space triangle with
# the public Möller–Trumbore test (no bounding or lateral rejection).
function audit3_bruteforce_hits(mesh::Mesh, rc::Raycaster)
    geometry = mesh.geometry
    world = compute_world_matrix(mesh)
    hits = Tuple{Float64,Int}[]
    for face in 1:geometry.n_faces
        a, b, c = (mat4_transform_point(world, get_vertex(geometry, index))
                   for index in Diff3D.get_face(geometry, face))
        t = ray_triangle_intersect(rc.ray.origin, rc.ray.direction, a, b, c; side=:double)
        t === nothing || push!(hits, (t, face))
    end
    return sort!(hits; by=first)
end

@testset "Raycast pruning keeps every exact hit" begin
    # Faces are skipped only when all vertices lie beyond one plane through
    # the ray; rays aimed exactly at shared vertices and edges, on grids and at
    # extreme magnitudes, must still report every face the exact test accepts.
    for magnitude in (1.0, 1.0e-150, 1.0e150), trial in 1:40
        n = 9
        positions = Float64[]
        for i in 0:2, j in 0:2
            append!(positions, (i * magnitude, j * magnitude, ((i + j) % 2) * magnitude))
        end
        indices = Int[]
        for i in 0:1, j in 0:1
            v = 3i + j + 1
            append!(indices, (v, v + 3, v + 1, v + 1, v + 3, v + 4))
        end
        geometry = BufferGeometry(positions, Float64[], Float64[], indices, n, 8)
        mesh = Mesh(geometry, MeshBasicMaterial(side=:double))
        mesh.rotation = Euler(0.1 * trial, -0.05 * trial, 0.3)
        mesh.scale = Vec3(1.0, -2.0, 0.5)
        world = compute_world_matrix(mesh)
        # Aim at a vertex (trial odd) or an edge midpoint (trial even).
        a = get_vertex(geometry, 1 + trial % n)
        b = get_vertex(geometry, 1 + (trial * 7) % n)
        aim = mat4_transform_point(world, isodd(trial) ? a : (a + b) * 0.5)
        direction = Vec3(sin(trial), cos(2trial), -1.0)
        rc = Raycaster(aim - direction * (4magnitude), direction)
        actual = raycast(rc, mesh)   # validates (renormalizes) rc.ray first
        expected = audit3_bruteforce_hits(mesh, rc)
        @test [(hit.distance, hit.face_index) for hit in actual] == expected
    end
end

@testset "Raycast scratch buffers are reused across casts" begin
    geometry = SphereGeometry(radius=1.0, width_segments=128, height_segments=64)
    mesh = Mesh(geometry, MeshBasicMaterial())
    rc = Raycaster(Vec3(0.1, 0.2, 5.0), Vec3(0.0, 0.0, -1.0))
    raycast(rc, mesh)
    if Base.JLOptions().opt_level > 0
        # Only the returned single-hit vector is allocated, at its exact size:
        # the per-vertex pruning codes (8385 vertices would need 8 KB) and the
        # hit scratch live in the raycaster. Growing a fresh vector by push!
        # reserved several 256-byte Intersections (848 B on 1.13, 2240 B on
        # 1.10, over the suite's 1024 B raycast budget).
        @test (@allocated raycast(rc, mesh)) < 512
    end
    @test length(rc.vertex_codes) >= geometry.n_vertices
    # The pruning is active: nearly every face of the sphere lies beside the ray.
    codes = Diff3D._ray_lateral_codes!(rc, geometry, nothing, compute_world_matrix(mesh), 0.0)
    rejected = count(f -> Diff3D._ray_lateral_rejects(codes, Diff3D.get_face(geometry, f)...),
                     1:geometry.n_faces)
    @test rejected > 0.95 * geometry.n_faces
    # The scratch does not keep hit objects alive after the cast.
    @test isempty(rc.hits)
end

@testset "Point and line pruning keeps hits at the pick radius" begin
    # Points and segment endpoints sit exactly at (and just inside or outside)
    # the threshold from the ray, after a rotated, mirrored, non-uniform world
    # transform; the pre-filter must keep every hit of the exact test.
    for magnitude in (1.0, 1.0e-120, 1.0e120), trial in 1:30
        threshold = 0.25 * magnitude
        offsets = (threshold, nextfloat(threshold), prevfloat(threshold), 0.5threshold, 3threshold)
        positions = Float64[]
        for (k, offset) in enumerate(offsets), sign in (-1.0, 1.0)
            angle = 0.37 * trial + k
            append!(positions, (sign * offset * cos(angle), sign * offset * sin(angle),
                                (k - 3) * magnitude))
        end
        n = length(positions) ÷ 3
        geometry = BufferGeometry(positions, Float64[], Float64[], Int[], n, 0)
        parent = Group()
        parent.rotation = Euler(0.2trial, -0.1trial, 0.05trial)
        parent.scale = Vec3(-1.0, 1.0, 1.0)
        objects = (PointsObject(geometry, PointsMaterial()),
                   LineObject(geometry, LineBasicMaterial()),
                   LineSegments(geometry, LineBasicMaterial()),
                   LineLoop(geometry, LineBasicMaterial()))
        for object in objects
            add!(parent, object)
        end
        world = compute_world_matrix(parent)
        origin = mat4_transform_point(world, Vec3(0.0, 0.0, 10magnitude))
        target = mat4_transform_point(world, Vec3(0.0, 0.0, 0.0))
        rc = Raycaster(origin, target - origin; point_threshold=threshold,
                       line_threshold=threshold)
        hits = raycast(rc, parent)
        o, d = rc.ray.origin, rc.ray.direction
        world_vertex(i) = mat4_transform_point(world, get_vertex(geometry, i))
        expected = Tuple{Float64,Int,String}[]
        for i in 1:n
            t, distance = Diff3D._ray_point_distance(o, d, world_vertex(i))
            distance < threshold && push!(expected, (t, i, "Points"))
        end
        segments = Dict("Line" => [(i, i + 1) for i in 1:n-1],
                        "LineSegments" => [(i, i + 1) for i in 1:2:n-1],
                        "LineLoop" => [[(i, i + 1) for i in 1:n-1]; (n, 1)])
        for (name, pairs) in segments, (i, j) in pairs
            t, distance, _ = Diff3D._ray_segment_distance(o, d, world_vertex(i), world_vertex(j))
            distance <= threshold && push!(expected, (t, i, name))
        end
        actual = sort!([(hit.distance, hit.face_index, hit.object.name) for hit in hits])
        @test actual == sort!(expected)
        @test !isempty(actual)
    end
end

@testset "Repeated raycasts with one raycaster agree" begin
    # raycast revalidates rc.ray each call; renormalizing a unit direction
    # used to move it by an ulp, so a second identical cast could differ.
    # Reproducer: direction (0.3sin(4), 0.3cos(6.8), -1.4) at a unit sphere.
    mesh = Mesh(SphereGeometry(radius=1.0), MeshBasicMaterial(side=:double))
    for i in 1:200
        rc = Raycaster(Vec3(0.0, 0.0, 3.0),
                       Vec3(0.3sin(i), 0.3cos(1.7i), -1.0 - 0.1 * (i % 7)))
        direction = rc.ray.direction
        first_hits = [hit.distance for hit in raycast(rc, mesh)]
        @test rc.ray.direction === direction
        @test [hit.distance for hit in raycast(rc, mesh)] == first_hits
    end
    # Unnormalized directions assigned later are still normalized.
    rc = Raycaster(Vec3(0.0, 0.0, 3.0), Vec3(0.0, 0.0, -1.0))
    rc.ray = Ray(Vec3(0.1, 0.3, 3.0), Vec3(0.0, 0.0, -2.0))
    @test only(raycast(rc, Mesh(PlaneGeometry(), MeshBasicMaterial()))).distance == 3.0
    @test rc.ray.direction == Vec3(0.0, 0.0, -1.0)
end

audit3_close(a::Vec3, b) = maximum(abs, (a.x - b[1], a.y - b[2], a.z - b[3]))
audit3_close(a::Vec2, b) = maximum(abs, (a.x - b[1], a.y - b[2]))

@testset "Intersections carry three.js face, normal, uv and barycoord data" begin
    # three.js checkGeometryIntersection (src/objects/Mesh.js:452-506):
    # face a/b/c, local face normal, local interpolated normal flipped toward
    # the ray, uv/uv1 and barycoord. Oracle: the scene below in three.js r186.
    geometry = BufferGeometry([0.0, 0, 0, 2, 0, 0.5, 0, 1.5, 0, 2, 1.5, 1],
                              [0.0, 0, 1, 0.2, 0, 1, 0, 0.3, 1, 0.1, 0.1, 0.9],
                              [0.0, 0, 1, 0, 0, 1, 1, 1], [1, 2, 3, 3, 2, 4], 4, 2)
    set_attribute!(geometry, :uv2, [0.5, 0.5, 0.75, 0.5, 0.5, 0.25, 0.25, 0.25], 2)
    mesh = Mesh(geometry, MeshBasicMaterial(side=:double))
    parent = Group()
    parent.position = Vec3(0.3, -0.2, 0.1)
    parent.rotation = Euler(0.2, -0.3, 0.4)
    parent.scale = Vec3(-1.5, 0.8, 1.2)
    mesh.position = Vec3(0.1, 0.2, -0.4)
    mesh.rotation = Euler(-0.1, 0.25, 0.05)
    mesh.scale = Vec3(1.0, 1.3, 0.7)
    add!(parent, mesh)
    rc = Raycaster(Vec3(-0.8, 0.9, 4.0), Vec3(0.05, -0.08, -1.0))
    hit = only(raycast(rc, parent))
    @test hit.distance ≈ 4.716591363596191 rtol = 1e-12
    @test audit3_close(hit.point, (-0.5652129199285951, 0.5243406718857528, -0.695741601428093)) < 1e-12
    @test hit.face_index == 1 && hit.face == (1, 2, 3)
    @test audit3_close(hit.face_normal, (-0.24253562503633297, 0.0, 0.9701425001453319)) < 1e-12
    @test audit3_close(hit.normal, (0.04729889621441521, 0.14699650078531093, 1.0)) < 1e-12
    @test audit3_close(hit.uv, (0.23649448107207602, 0.4899883359510364)) < 1e-12
    @test audit3_close(hit.uv1, (0.559123620268019, 0.3775029160122409)) < 1e-12
    @test audit3_close(hit.barycoord, (0.27351718297688754, 0.23649448107207602, 0.4899883359510364)) < 1e-12
    @test hit.distance_to_ray === nothing

    # The same data through an instance matrix and a posed skin (identity
    # bone) equals the plain mesh's.
    instances = InstancedMesh(geometry, MeshBasicMaterial(side=:double),
                              [compute_world_matrix(mesh)])
    instance_hit = only(raycast(rc, instances))
    @test instance_hit.face == hit.face && instance_hit.instance_id == 1
    @test audit3_close(instance_hit.face_normal, (-0.24253562503633297, 0.0, 0.9701425001453319)) < 1e-12
    @test audit3_close(instance_hit.normal, (0.04729889621441521, 0.14699650078531093, 1.0)) < 1e-12
    @test audit3_close(instance_hit.uv, (0.23649448107207602, 0.4899883359510364)) < 1e-12
    bone = Bone()
    skin = SkinnedMesh(geometry, MeshBasicMaterial(side=:double), Skeleton([bone]),
                       fill((1, 1, 1, 1), 4), fill((1.0, 0.0, 0.0, 0.0), 4))
    skin.position, skin.rotation, skin.scale = mesh.position, mesh.rotation, mesh.scale
    remove!(parent, mesh)
    add!(parent, skin)
    add!(skin, bone)
    bind_skeleton!(skin, skin.skeleton)
    skin_hit = only(raycast(rc, parent))
    @test skin_hit.distance ≈ 4.716591363596191 rtol = 1e-12
    @test skin_hit.face == (1, 2, 3)
    @test audit3_close(skin_hit.face_normal, (-0.24253562503633297, 0.0, 0.9701425001453319)) < 1e-12
    @test audit3_close(skin_hit.normal, (0.04729889621441521, 0.14699650078531093, 1.0)) < 1e-12
    @test audit3_close(skin_hit.barycoord, (0.27351718297688754, 0.23649448107207602, 0.4899883359510364)) < 1e-12

    # Points report distanceToRay (src/objects/Points.js:208-238).
    points = PointsObject(BufferGeometry([0.0, 0, 0, 0.05, 0.02, -1], Float64[],
                                         Float64[], Int[], 2, 0), PointsMaterial())
    points.position = Vec3(0.01, 0.0, 0.0)
    point_hits = raycast(Raycaster(Vec3(0.0, 0.0, 5.0), Vec3(0.0, 0.0, -1.0);
                                   point_threshold=0.1), points)
    @test [hit.distance for hit in point_hits] ≈ [5.0, 6.0] atol = 1e-12
    @test [hit.distance_to_ray for hit in point_hits] ≈ [0.01, 0.0632455532033676] atol = 1e-12
    @test all(hit -> hit.face === nothing && hit.uv === nothing, point_hits)

    # Sprites report their quad uv (src/objects/Sprite.js:141-213).
    camera = PerspectiveCamera(fov=pi / 3, aspect=1.0, near=0.1, far=50.0)
    camera.position = Vec3()
    camera.target = Vec3(0.0, 0.0, -1.0)
    sprite = Sprite(SpriteMaterial(rotation=0.3); center=Vec2(0.3, 0.6))
    sprite.scale = Vec3(1.2, 0.7, 1.0)
    sprite.position = Vec3(0.1, -0.1, -3.0)
    for (x, y, distance, uv) in ((0.2, 0.1, 3.0083217912982647, (0.4288647418706904, 0.8307361102271247)),
                                 (-0.2, -0.2, 3.013303834663873, (0.036539193830153575, 0.5901748758369159)),
                                 (0.4, -0.3, 3.0413812651491106, (0.4895807545045115, 0.20039520025210983)))
        sprite_hit = only(raycast(Raycaster(Vec3(), Vec3(x, y, -3.0); camera=camera), sprite))
        @test sprite_hit.distance ≈ distance rtol = 1e-12
        @test audit3_close(sprite_hit.uv, uv) < 1e-12
    end
end

@testset "Hit details stay finite at extreme magnitudes" begin
    # Barycoords and face normals rescale by exact powers of two, so subnormal
    # and near-overflow triangles still report the plain triangle's weights,
    # uv and normal (three.js overflows or underflows to zero or NaN there).
    for magnitude in (1.0e-310, 1.0e-320, 1.0e-300, 1.0e300)
        geometry = BufferGeometry([0.0, 0, 0, magnitude, 0, 0, 0, magnitude, 0],
                                  [0.0, 0, 1, 0, 0, 1, 0, 0, 1], [0.0, 0, 1, 0, 0, 1],
                                  [1, 2, 3], 3, 1)
        mesh = Mesh(geometry, MeshBasicMaterial(side=:double))
        hit = only(raycast(Raycaster(Vec3(magnitude / 4, magnitude / 4, 1.0),
                                     Vec3(0.0, 0.0, -1.0)), mesh))
        @test audit3_close(hit.barycoord, (0.5, 0.25, 0.25)) < 1e-12
        @test audit3_close(hit.uv, (0.25, 0.25)) < 1e-12
        @test audit3_close(hit.face_normal, (0.0, 0.0, 1.0)) == 0.0
        @test audit3_close(hit.normal, (0.0, 0.0, 1.0)) == 0.0
    end
    # A posed skin pulls its world face normal back through a huge mirrored
    # matrix without overflowing.
    geometry = BufferGeometry([0.0, 0, 0, 1, 0, 0, 0, 1, 0], [0.0, 0, 1, 0, 0, 1, 0, 0, 1],
                              Float64[], [1, 2, 3], 3, 1)
    bone = Bone()
    skin = SkinnedMesh(geometry, MeshBasicMaterial(side=:double), Skeleton([bone]),
                       fill((1, 1, 1, 1), 3), fill((1.0, 0.0, 0.0, 0.0), 3))
    skin.scale = Vec3(1.0e300, -1.0e300, 1.0e300)
    add!(skin, bone)
    bind_skeleton!(skin, skin.skeleton)
    hit = only(raycast(Raycaster(Vec3(0.25e300, -0.25e300, 1.0e300), Vec3(0.0, 0.0, -1.0)), skin))
    @test audit3_close(hit.face_normal, (0.0, 0.0, 1.0)) == 0.0
    @test audit3_close(hit.barycoord, (0.5, 0.25, 0.25)) < 1e-12
end
