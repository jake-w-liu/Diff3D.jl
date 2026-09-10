using Test, Diff3D

@testset "IES profile storage ownership" begin
    for (a,c) in ((Float64[0,90,180],Float64[3,2,1]),
                  (Float32[0,90,180],Float32[3,2,1]),
                  (view([0.0,90.0,180.0],:),view([3.0,2.0,1.0],:)))
        profile=IESProfile(a,c)
        a[2]=45;c[2]=0
        @test profile.angles==[0.0,90.0,180.0]
        @test profile.candela==[3.0,2.0,1.0]
        @test profile.max_candela==3.0
        profile.angles[2]=30;profile.candela[2]=100
        @test ies_candela(profile,90.0)==2.0
    end
    profile=IESProfile(0:90:180,3:-1:1)
    @test profile.angles==[0.0,90.0,180.0]
    @test profile.candela==[3.0,2.0,1.0]

    # The ownership-transfer path must apply the same validation as public inputs.
    for (a,c) in (([0.0],[1.0,2.0]),(Float64[],Float64[]),
                  ([0.0,NaN],[1.0,0.0]),([0.0,90.0],[1.0,Inf]),
                  ([0.0,90.0],[1.0,-1.0]),([0.0,0.0],[1.0,0.0]))
        @test_throws ArgumentError IESProfile(a,c)
        @test_throws ArgumentError Diff3D._ies_profile_from_owned(a,c)
    end
end
