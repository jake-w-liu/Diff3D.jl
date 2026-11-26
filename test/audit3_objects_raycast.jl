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
