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
