using Test, Diff3D

function collect_all_drawables!(cache, root)
    Diff3D._collect_render_drawables_worlds_into!(
        cache.meshes, cache.mesh_worlds, cache.instanced, cache.instanced_worlds,
        root, cache.primitive_flags, cache.primitives, cache.primitive_worlds)
    return nothing
end

function collection_allocations(cache, root)
    collect_all_drawables!(cache, root)
    return @allocated collect_all_drawables!(cache, root)
end

function collection_object(kind, geometry)
    kind === :mesh && return Mesh(geometry, MeshBasicMaterial())
    kind === :line && return LineObject(geometry, LineBasicMaterial())
    kind === :segments && return LineSegments(geometry, LineBasicMaterial())
    kind === :loop && return LineLoop(geometry, LineBasicMaterial())
    kind === :points && return PointsObject(geometry, PointsMaterial())
    kind === :sprite && return Sprite(SpriteMaterial())
    kind === :instance_lines && return InstancedMesh(geometry, LineBasicMaterial(), 1; draw_mode=:lines)
    kind === :instance_points && return InstancedMesh(geometry, PointsMaterial(), 1; draw_mode=:points)
    error("Unknown collection fixture: $kind")
end

@testset "One scene traversal collects every drawable without per-object boxes" begin
    geometry = PlaneGeometry()
    for kind in (:mesh, :line, :segments, :loop, :points, :sprite,
                 :instance_lines, :instance_points), count in (1, 100)
        parent = Group()
        parent.position = Vec3(1.0, 2.0, 3.0)
        parent.scale = Vec3(2.0, 1.0, 0.5)
        root = Scene()
        add!(parent, root)
        group = Group()
        group.position = Vec3(0.0, 1.0, 0.0)
        add!(root, group)
        objects = [collection_object(kind, geometry) for _ in 1:count]
        for (index, object) in pairs(objects)
            object.position = Vec3(Float64(index), 0.0, 0.0)
            add!(group, object)
        end
        hidden = Group()
        hidden.visible = false
        add!(hidden, collection_object(kind, geometry))
        add!(root, hidden)
        cache = RenderCache()
        collect_all_drawables!(cache, root)
        actual, worlds = kind === :mesh ? (cache.meshes, cache.mesh_worlds) :
                                         (cache.primitives, cache.primitive_worlds)
        @test length(actual) == count
        @test all(actual[index] === objects[index] for index in eachindex(objects))
        @test all(worlds[index].e == compute_world_matrix(objects[index]).e for index in eachindex(objects))
        @test length(cache.instanced) == (kind in (:instance_lines, :instance_points) ? count : 0)
        @test cache.primitive_flags.lines == (kind in (:line, :segments, :loop, :instance_lines))
        @test cache.primitive_flags.points == (kind in (:points, :instance_points))
        @test cache.primitive_flags.sprites == (kind === :sprite)
        if Base.JLOptions().opt_level > 0
            collection_allocations(cache, root)
            @test collection_allocations(cache, root) <= 256
        end
        collect_all_drawables!(cache, Scene())
        @test isempty(cache.meshes) && isempty(cache.instanced) && isempty(cache.primitives)
        @test !cache.primitive_flags.lines && !cache.primitive_flags.points && !cache.primitive_flags.sprites
    end
end

@testset "Primitive children of meshes remain in traversal order" begin
    root = Scene()
    mesh = Mesh(PlaneGeometry(), MeshBasicMaterial())
    first = Sprite(SpriteMaterial())
    second = PointsObject(PlaneGeometry(), PointsMaterial())
    add!(mesh, first)
    add!(root, mesh)
    add!(root, second)
    cache = RenderCache()
    collect_all_drawables!(cache, root)
    @test cache.meshes == [mesh]
    @test cache.primitives == [first, second]
end
