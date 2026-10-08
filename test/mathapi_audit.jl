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
