using Test, Diff3D

function manual_lod_allocations(lod, distance)
    lod_update!(lod, distance)
    return @allocated lod_update!(lod, distance)
end

@testset "Manual LOD updates reset camera state without boxed IDs" begin
    for Object in (Object3D, Group), count in (1, 100)
        lod = LOD()
        for index in 1:count
            object = Object()
            # Exercise IDs beyond the small values seen at process startup.
            object.id = typemax(Int) - index
            add_lod_level!(lod, index - 1, object; hysteresis=0.25)
        end
        first = lod.levels[1].object
        last = lod.levels[end].object
        @test lod_update!(lod, 0.0) === first
        @test lod._manual_level == first.id
        @test first.visible
        if Base.JLOptions().opt_level > 0
            manual_lod_allocations(lod, 0.0)
            @test manual_lod_allocations(lod, 0.0) == 0
        end
        camera = PerspectiveCamera()
        camera.position = Vec3(0.0, 0.0, 2.0count)
        @test lod_update!(lod, camera) === last
        previous = copy(lod._camera_levels)
        @test_throws ArgumentError lod_update!(lod, NaN)
        @test lod._camera_levels == previous
        count > 1 && @test !isempty(lod._camera_levels)
        @test lod_update!(lod, 0.0) === first
        @test isempty(lod._camera_levels)
        @test lod._manual_level == first.id
        @test all(level -> level.object.visible == (level.object === first), lod.levels)
    end
    empty_lod = LOD()
    @test lod_update!(empty_lod, 1.0) === nothing
    @test empty_lod._manual_level == 0
    if Base.JLOptions().opt_level > 0
        manual_lod_allocations(empty_lod, 1.0)
        @test manual_lod_allocations(empty_lod, 1.0) == 0
    end
end
