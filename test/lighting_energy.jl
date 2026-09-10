using Diff3D, Test

@testset "Lit materials require incident or emitted light" begin
    normal=Vec3(0.0,0.0,1.0);view=Vec3(0.0,0.0,1.0)
    for material in (MeshLambertMaterial(),MeshPhongMaterial(),MeshStandardMaterial(),MeshPhysicalMaterial())
        color=shade_face(normal,view,Vec3(),material,AbstractLight[])
        @test color==Color3(0.0,0.0,0.0)
    end
    color=shade_face(normal,view,Vec3(),MeshLambertMaterial(color=Color3(0.4,0.6,0.8)),[AmbientLight(intensity=0.5)])
    @test [color.r,color.g,color.b]≈[0.2,0.3,0.4] atol=1e-15
    emissive=shade_face(normal,view,Vec3(),MeshLambertMaterial(color=Color3(0.0,0.0,0.0),emissive=Color3(0.2,0.1,0.05)),AbstractLight[])
    @test [emissive.r,emissive.g,emissive.b]≈[0.2,0.1,0.05] atol=1e-15
    for light in (DirectionalLight(position=Vec3(1.0,0.0,-0.5),intensity=3.0),
                  PointLight(position=Vec3(1.0,0.0,-0.5),intensity=3.0),
                  SpotLight(position=Vec3(1.0,0.0,-0.5),target=Vec3(),intensity=3.0))
        color=shade_face(normal,view,Vec3(),MeshPhongMaterial(color=Color3(0.0,0.0,0.0),shininess=4.0),[light])
        @test color==Color3(0.0,0.0,0.0)
    end
end
