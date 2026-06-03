using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Three

function add_box!(scene, name, size::Vec3, position::Vec3, color::Color3; metalness=0.05, roughness=0.55)
    mesh = Mesh(BoxGeometry(width=size.x, height=size.y, depth=size.z),
                MeshStandardMaterial(color=color, metalness=metalness, roughness=roughness);
                name=name)
    mesh.position = position
    add!(scene, mesh)
    return mesh
end

q(x, y, z) = quat_from_euler(x, y, z)

function keyframe_scene()
    scene = Scene(background=Color3(0.025, 0.030, 0.040),
                  fog=FogExp2(color=Color3(0.025, 0.030, 0.040), density=0.035))
    add!(scene, AmbientLight(color=Color3(0.45, 0.50, 0.58), intensity=0.55))
    add!(scene, HemisphereLight(color=Color3(0.42, 0.62, 0.95),
                                ground_color=Color3(0.20, 0.17, 0.12),
                                intensity=0.45))
    key = DirectionalLight(color=Color3(1.0, 0.92, 0.78), intensity=2.4,
                           position=Vec3(4.0, 7.0, 5.0))
    key.target = Vec3(0.0, 1.2, 0.0)
    add!(scene, key)
    rim = SpotLight(color=Color3(0.2, 0.55, 1.0), intensity=8.0,
                    distance=12.0, angle=pi/5, penumbra=0.45,
                    position=Vec3(-3.0, 4.0, 3.0))
    rim.target = Vec3(0.0, 1.0, 0.0)
    add!(scene, rim)

    floor = Mesh(PlaneGeometry(width=12.0, height=12.0),
                 MeshStandardMaterial(color=Color3(0.18, 0.19, 0.21), roughness=0.92);
                 name="keyframes_floor")
    floor.rotation = Euler(-pi/2, 0.0, 0.0)
    floor.position = Vec3(0.0, -0.05, 0.0)
    add!(scene, floor)

    body = add_box!(scene, "keyframes_body", Vec3(0.75, 1.25, 0.42), Vec3(0.0, 1.35, 0.0),
                    Color3(0.23, 0.55, 0.88), metalness=0.25, roughness=0.38)
    head = add_box!(scene, "keyframes_head", Vec3(0.48, 0.48, 0.48), Vec3(0.0, 2.25, 0.0),
                    Color3(0.95, 0.74, 0.46), roughness=0.42)
    left_arm = add_box!(scene, "keyframes_left_arm", Vec3(0.26, 0.92, 0.26), Vec3(-0.63, 1.35, 0.0),
                        Color3(0.95, 0.38, 0.30), roughness=0.48)
    right_arm = add_box!(scene, "keyframes_right_arm", Vec3(0.26, 0.92, 0.26), Vec3(0.63, 1.35, 0.0),
                         Color3(0.95, 0.38, 0.30), roughness=0.48)
    left_leg = add_box!(scene, "keyframes_left_leg", Vec3(0.28, 0.95, 0.28), Vec3(-0.23, 0.42, 0.0),
                        Color3(0.18, 0.23, 0.42), roughness=0.62)
    right_leg = add_box!(scene, "keyframes_right_leg", Vec3(0.28, 0.95, 0.28), Vec3(0.23, 0.42, 0.0),
                         Color3(0.18, 0.23, 0.42), roughness=0.62)

    for i in -4:4
        strip = Mesh(BoxGeometry(width=0.035, height=0.018, depth=8.5),
                     MeshBasicMaterial(color=Color3(0.16, 0.22, 0.30), depth_write=false);
                     name="keyframes_floor_line_$i")
        strip.position = Vec3(i * 0.75, 0.005, 0.0)
        add!(scene, strip)
    end

    times = [0.0, 0.35, 0.7, 1.05, 1.4]
    bounce = [Vec3(0.0, 1.35, 0.0), Vec3(0.0, 1.52, 0.0), Vec3(0.0, 1.35, 0.0),
              Vec3(0.0, 1.50, 0.0), Vec3(0.0, 1.35, 0.0)]
    tracks = AbstractKeyframeTrack[
        KeyframeTrack(body, :position, times, bounce; interpolation=:cubic),
        KeyframeTrack(head, :position, times,
                      [Vec3(0.0, 2.25, 0.0), Vec3(0.0, 2.46, 0.0), Vec3(0.0, 2.25, 0.0),
                       Vec3(0.0, 2.43, 0.0), Vec3(0.0, 2.25, 0.0)];
                      interpolation=:cubic),
        QuaternionKeyframeTrack(body, :rotation, times,
                                [q(0.0, 0.0, 0.0), q(0.0, 0.0, 0.09), q(0.0, 0.0, 0.0),
                                 q(0.0, 0.0, -0.09), q(0.0, 0.0, 0.0)]),
        QuaternionKeyframeTrack(head, :rotation, times,
                                [q(0.0, -0.18, 0.0), q(0.08, 0.22, 0.04), q(0.0, -0.18, 0.0),
                                 q(0.08, 0.22, -0.04), q(0.0, -0.18, 0.0)]),
        QuaternionKeyframeTrack(left_arm, :rotation, times,
                                [q(0.75, 0.0, -0.25), q(-0.65, 0.0, -0.55), q(0.75, 0.0, -0.25),
                                 q(-0.65, 0.0, -0.55), q(0.75, 0.0, -0.25)]),
        QuaternionKeyframeTrack(right_arm, :rotation, times,
                                [q(-0.65, 0.0, 0.55), q(0.75, 0.0, 0.25), q(-0.65, 0.0, 0.55),
                                 q(0.75, 0.0, 0.25), q(-0.65, 0.0, 0.55)]),
        QuaternionKeyframeTrack(left_leg, :rotation, times,
                                [q(-0.55, 0.0, 0.0), q(0.55, 0.0, 0.0), q(-0.55, 0.0, 0.0),
                                 q(0.55, 0.0, 0.0), q(-0.55, 0.0, 0.0)]),
        QuaternionKeyframeTrack(right_leg, :rotation, times,
                                [q(0.55, 0.0, 0.0), q(-0.55, 0.0, 0.0), q(0.55, 0.0, 0.0),
                                 q(-0.55, 0.0, 0.0), q(0.55, 0.0, 0.0)]),
        KeyframeTrack(left_arm, :scale, times,
                      [Vec3(1.0, 1.0, 1.0), Vec3(1.0, 1.12, 1.0), Vec3(1.0, 1.0, 1.0),
                       Vec3(1.0, 1.12, 1.0), Vec3(1.0, 1.0, 1.0)]),
        KeyframeTrack(right_arm, :scale, times,
                      [Vec3(1.0, 1.12, 1.0), Vec3(1.0, 1.0, 1.0), Vec3(1.0, 1.12, 1.0),
                       Vec3(1.0, 1.0, 1.0), Vec3(1.0, 1.12, 1.0)])
    ]
    clip = AnimationClip("robot-keyframes", tracks)
    return scene, clip
end

scene, clip = keyframe_scene()
outdir = joinpath(@__DIR__, "output")
mkpath(outdir)
path = joinpath(outdir, "webgl_animation_keyframes.html")
save_webgl_html(path, [WebGLExportCase("animation-keyframes", "Animation Keyframes",
                                       "Quaternion, vector, and scale tracks generated by Three.jl",
                                       scene; target=Vec3(0.0, 1.1, 0.0),
                                       radius=7.0, animations=[clip])];
                title="Three.jl webgl_animation_keyframes")
println("WEBGL_ANIMATION_KEYFRAMES_OK $path")
