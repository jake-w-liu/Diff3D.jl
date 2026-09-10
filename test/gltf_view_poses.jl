using Diff3D, Test
include("fixtures/animated_view_nodes.jl")

@testset "glTF view poses follow animated TRS" begin
    mktempdir() do directory
        for interpolation in (:linear,:step,:cubicspline),kind in (:perspective,:orthographic),parent_scale in ((2.0,3.0,4.0),(-2.0,3.0,4.0))
            asset=animated_view_fixture(directory;interpolation=interpolation,camera_kind=kind,parent_scale=parent_scale)
            rig=only(get_children(asset.scene))
            camera,directional,spot=get_children(rig)
            @test camera.rotation_driven && camera.ignore_parent_scale
            @test directional.rotation_driven && spot.rotation_driven
            for track in only(asset.animations).tracks
                if track isa Union{QuaternionKeyframeTrack,CubicSplineQuaternionKeyframeTrack}
                    @test Diff3D._web_track_property_name(track)=="quaternion"
                end
            end
            mixer=AnimationMixer(only(asset.animations);loop=:once,clamp_when_finished=true)
            parent_matrix=mat4_translation(10.0,3.0,0.0)*mat4_rotation_z(pi/2)*mat4_scaling(parent_scale...)
            for time in (0.0,0.25,0.5,1.0)
                mixer_set_time!(mixer,time)
                amount=interpolation===:step ? (time<1 ? 0.0 : 1.0) :
                       interpolation===:cubicspline ? time*time*(3-2time) : time
                angle=interpolation===:cubicspline ? 2atan(amount*sin(pi/4),1-amount+amount*cos(pi/4)) : amount*pi/2
                expected_position=mat4_transform_point(parent_matrix,Vec3(3+2amount,2amount,2+amount))
                rotation=mat4_rotation_z(pi/2)*mat4_rotation_y(angle)
                forward=mat4_transform_direction(rotation,Vec3(0.0,0.0,-1.0))
                up=mat4_transform_direction(rotation,Vec3(0.0,1.0,0.0))
                position,target,actual_up=Diff3D._camera_world_pose(camera)
                @test norm(position-expected_position)<1e-7
                @test norm(normalize(target-position)-forward)<1e-7
                @test norm(actual_up-up)<1e-7
                expected_view=mat4_look_at(expected_position,expected_position+forward,up)
                @test maximum(abs.(collect(view_matrix(camera).e).-collect(expected_view.e)))<1e-6
                emitted=normalize(mat4_transform_direction(parent_matrix*mat4_rotation_y(angle),Vec3(0.0,0.0,-1.0)))
                _,_,incoming=light_contribution(directional,Vec3())
                @test norm(incoming+emitted)<1e-7
                spot_position=Diff3D._light_world_position(spot)
                _,intensity,_=light_contribution(spot,spot_position+2emitted)
                @test intensity>0.0
            end
        end
    end
end

@testset "Rotation mode and legacy pose constructors" begin
    for camera in (PerspectiveCamera(),OrthographicCamera())
        @test !camera.rotation_driven
        values=ntuple(i->getfield(camera,i),fieldcount(typeof(camera))-1)
        @test !typeof(camera)(values...).rotation_driven
    end
    for light in (DirectionalLight(),SpotLight())
        @test !light.rotation_driven
        values=ntuple(i->getfield(light,i),fieldcount(typeof(light))-1)
        @test !typeof(light)(values...).rotation_driven
    end
    camera=PerspectiveCamera(rotation_driven=true)
    camera.rotation=Euler(0.3,0.4,0.5)
    initial=view_matrix(camera)
    camera.target=Vec3(2.0,3.0,4.0)
    @test view_matrix(camera).e==initial.e
    controls=OrbitControls(camera)
    orbit_set!(controls;azimuth=0.4,polar=1.2,radius=3.0)
    expected=mat4_look_at(camera.position,camera.target,camera.up)
    @test maximum(abs.(collect(view_matrix(camera).e).-collect(expected.e)))<1e-12
    trackball=TrackballControls(camera)
    trackball_rotate!(trackball,0.1,0.2)
    expected=mat4_look_at(camera.position,camera.target,camera.up)
    @test maximum(abs.(collect(view_matrix(camera).e).-collect(expected.e)))<1e-12
end

@testset "Rotated light shadows and helpers use world poses" begin
    asset=mktempdir() do directory
        animated_view_fixture(directory)
    end
    rig=only(get_children(asset.scene))
    camera,directional,spot=get_children(rig)
    mixer_set_time!(AnimationMixer(only(asset.animations)),0.5)
    for light in (directional,spot)
        position=Diff3D._light_world_position(light)
        direction=normalize(mat4_transform_direction(compute_world_matrix(light),Vec3(0.0,0.0,-1.0)))
        reference=light isa DirectionalLight ? DirectionalLight(position=position) :
            SpotLight(position=position,angle=light.angle,penumbra=light.penumbra)
        reference.target=position+direction
        center=position+4direction
        actual_matrix=Diff3D._light_view_proj(light,center,1.0)
        reference_matrix=Diff3D._light_view_proj(reference,center,1.0)
        @test maximum(abs.(collect(actual_matrix.e).-collect(reference_matrix.e)))<1e-11
        helper=light isa DirectionalLight ? DirectionalLightHelper(light) : SpotLightHelper(light)
        # Directional helper stores position as vertex 1; spot helper stores
        # apex among spoke endpoints (vertex 1 is base ring). Assert presence.
        @test minimum(norm(get_vertex(helper.geometry,i)-position) for i in 1:helper.geometry.n_vertices)<1e-12
        light.cast_shadow=true
    end
    ids=Diff3D._web_dynamic_directional_shadow_light_ids(asset.scene,asset.animations)
    @test directional.id in ids
    @test spot.id in Diff3D._web_dynamic_spot_shadow_light_ids(asset.scene,asset.animations)
    parent_clip=AnimationClip("light rig translation",[
        KeyframeTrack(rig,:position,[0.0,1.0],[rig.position,rig.position+Vec3(1.0,0.0,0.0)])])
    @test directional.id in Diff3D._web_dynamic_directional_shadow_light_ids(asset.scene,[parent_clip])
    @test spot.id in Diff3D._web_dynamic_spot_shadow_light_ids(asset.scene,[parent_clip])

    point=PointLight(position=Vec3(1.0,0.0,0.0),cast_shadow=true)
    add!(rig,point)
    @test point.id in Diff3D._web_dynamic_point_shadow_light_ids(asset.scene,[parent_clip])
    helper=PointLightHelper(point)
    center=sum(get_vertex(helper.geometry,i) for i in 1:helper.geometry.n_vertices)/helper.geometry.n_vertices
    @test norm(center-Diff3D._light_world_position(point))<1e-12
end
