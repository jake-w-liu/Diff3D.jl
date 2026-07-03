# Diff3D.jl example gallery.
#
# Run:
#   julia --project=. examples/example_gallery.jl
#
# Open:
#   examples/output/example_gallery.html

import Pkg
if abspath(PROGRAM_FILE) == @__FILE__
    Pkg.activate(joinpath(@__DIR__, ".."))
end

using Diff3D

const OUT = joinpath(@__DIR__, "output")

function make_floor(; width=16.0, depth=16.0, color=Color3(0.34, 0.36, 0.40))
    floor = Mesh(
        PlaneGeometry(width=width, height=depth, width_segments=8, height_segments=8),
        MeshStandardMaterial(color=color, roughness=0.9);
        name="floor",
        receive_shadow=true,
    )
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    return floor
end

function add_studio_lights!(scene)
    add!(scene, AmbientLight(color=Color3(0.30, 0.34, 0.42), intensity=0.55))
    add!(scene, HemisphereLight(color=Color3(0.54, 0.68, 0.86),
                                ground_color=Color3(0.24, 0.20, 0.18),
                                intensity=0.45))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.95, 0.84), intensity=1.25,
                                 position=Vec3(-4.5, 7.5, 4.0)))
    add!(scene, PointLight(color=Color3(0.34, 0.76, 1.0), intensity=9.0,
                           distance=9.5, position=Vec3(3.6, 2.7, -2.5)))
    return scene
end

function make_box_part(name, size::Vec3, color::Color3; position=Vec3(), roughness=0.42, metalness=0.06)
    mesh = Mesh(
        BoxGeometry(width=size.x, height=size.y, depth=size.z),
        MeshStandardMaterial(color=color, roughness=roughness, metalness=metalness);
        name=name,
        cast_shadow=true,
        receive_shadow=true,
    )
    mesh.position = position
    return mesh
end

function make_sphere_part(name, radius, color::Color3; position=Vec3(), roughness=0.36, metalness=0.08)
    mesh = Mesh(
        SphereGeometry(radius=radius, width_segments=32, height_segments=20),
        MeshStandardMaterial(color=color, roughness=roughness, metalness=metalness);
        name=name,
        cast_shadow=true,
        receive_shadow=true,
    )
    mesh.position = position
    return mesh
end

function build_robot_case()
    scene = Scene(background=Color3(0.030, 0.037, 0.050), fog=FogExp2(color=Color3(0.030, 0.037, 0.050), density=0.018))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=18.0, depth=18.0, color=Color3(0.28, 0.30, 0.35)))

    robot = Group(name="tinker_robot")
    robot.position = Vec3(0.0, 0.20, 0.0)
    add!(scene, robot)

    blue = Color3(0.30, 0.68, 0.92)
    yellow = Color3(1.00, 0.78, 0.30)
    coral = Color3(0.95, 0.37, 0.30)
    cream = Color3(0.88, 0.91, 0.86)
    dark = Color3(0.08, 0.10, 0.13)
    glow = Color3(0.42, 0.92, 1.0)

    body = make_box_part("robot_body", Vec3(1.25, 1.55, 0.72), blue; position=Vec3(0.0, 1.45, 0.0), roughness=0.48)
    head = make_box_part("robot_head", Vec3(1.02, 0.72, 0.72), cream; position=Vec3(0.0, 2.62, 0.0), roughness=0.40)
    neck = make_sphere_part("robot_neck", 0.20, yellow; position=Vec3(0.0, 2.10, 0.0))
    add!(robot, body); add!(robot, neck); add!(robot, head)

    eye_mat = MeshBasicMaterial(color=glow)
    for x in (-0.24, 0.24)
        eye = Mesh(SphereGeometry(radius=0.105, width_segments=18, height_segments=10), eye_mat; name="robot_eye")
        eye.position = Vec3(x, 2.68, 0.38)
        add!(robot, eye)
    end

    smile = LineObject(
        BufferGeometry(
            Float64[-0.28, 2.48, 0.385, -0.08, 2.42, 0.405, 0.08, 2.42, 0.405, 0.28, 2.48, 0.385],
            Float64[], Float64[], Int[], 4, 0,
        ),
        LineBasicMaterial(color=dark);
        name="robot_smile",
    )
    add!(robot, smile)

    antenna = Group(name="robot_antenna")
    antenna.position = Vec3(0.0, 3.02, 0.0)
    add!(robot, antenna)
    mast = make_box_part("antenna_mast", Vec3(0.055, 0.46, 0.055), yellow; position=Vec3(0.0, 0.22, 0.0))
    bulb = make_sphere_part("antenna_bulb", 0.13, coral; position=Vec3(0.0, 0.52, 0.0), roughness=0.24)
    add!(antenna, mast); add!(antenna, bulb)

    left_arm = Group(name="left_arm"); left_arm.position = Vec3(-0.82, 1.86, 0.0)
    right_arm = Group(name="right_arm"); right_arm.position = Vec3(0.82, 1.86, 0.0)
    left_leg = Group(name="left_leg"); left_leg.position = Vec3(-0.34, 0.74, 0.0)
    right_leg = Group(name="right_leg"); right_leg.position = Vec3(0.34, 0.74, 0.0)
    add!(robot, left_arm); add!(robot, right_arm); add!(robot, left_leg); add!(robot, right_leg)

    add!(left_arm, make_sphere_part("left_shoulder", 0.20, yellow))
    add!(right_arm, make_sphere_part("right_shoulder", 0.20, yellow))
    la = make_box_part("left_forearm", Vec3(0.30, 0.92, 0.30), coral; position=Vec3(-0.18, -0.48, 0.0))
    ra = make_box_part("right_forearm", Vec3(0.30, 0.92, 0.30), coral; position=Vec3(0.18, -0.48, 0.0))
    la.rotation = Euler(0.0, 0.0, -0.20)
    ra.rotation = Euler(0.0, 0.0, 0.20)
    add!(left_arm, la); add!(right_arm, ra)
    add!(left_arm, make_sphere_part("left_hand", 0.18, cream; position=Vec3(-0.28, -0.98, 0.0)))
    add!(right_arm, make_sphere_part("right_hand", 0.18, cream; position=Vec3(0.28, -0.98, 0.0)))

    add!(left_leg, make_box_part("left_leg_lower", Vec3(0.32, 0.88, 0.34), blue; position=Vec3(0.0, -0.42, 0.0)))
    add!(right_leg, make_box_part("right_leg_lower", Vec3(0.32, 0.88, 0.34), blue; position=Vec3(0.0, -0.42, 0.0)))
    add!(left_leg, make_box_part("left_foot", Vec3(0.52, 0.18, 0.64), yellow; position=Vec3(0.0, -0.92, 0.12)))
    add!(right_leg, make_box_part("right_foot", Vec3(0.52, 0.18, 0.64), yellow; position=Vec3(0.0, -0.92, 0.12)))

    # Workshop props provide scale and visual depth.
    for (i, x) in enumerate(-3.0:1.2:3.0)
        cube = make_box_part("workshop_block_$i", Vec3(0.46, 0.34 + 0.08 * (i % 3), 0.46),
                             isodd(i) ? Color3(0.18, 0.42, 0.66) : Color3(0.70, 0.42, 0.20);
                             position=Vec3(x, 0.18, -2.2 - 0.28 * (i % 2)),
                             roughness=0.62)
        add!(scene, cube)
    end

    rail_pts = [Vec3(2.7*cos(2pi*i/80), 0.035, 2.0*sin(2pi*i/80)) for i in 0:79]
    rail_geo = BufferGeometry(Float64[], Float64[], Float64[], collect(1:length(rail_pts)), length(rail_pts), 0)
    for p in rail_pts
        append!(rail_geo.positions, (p.x, p.y, p.z))
    end
    add!(scene, LineLoop(rail_geo, LineBasicMaterial(color=Color3(0.55, 0.66, 0.76)); name="orbit_rail"))

    times = [0.0, 0.5, 1.0, 1.5, 2.0]
    tracks = AbstractKeyframeTrack[
        KeyframeTrack(robot, :position, times,
            [Vec3(0.0, 0.20, 0.0), Vec3(0.0, 0.32, 0.0), Vec3(0.0, 0.20, 0.0), Vec3(0.0, 0.32, 0.0), Vec3(0.0, 0.20, 0.0)];
            interpolation=:cubic),
        KeyframeTrack(left_arm, :rotation, times,
            [Vec3(0.0, 0.0, 0.45), Vec3(0.0, 0.0, -0.90), Vec3(0.0, 0.0, 0.45), Vec3(0.0, 0.0, -0.90), Vec3(0.0, 0.0, 0.45)]),
        KeyframeTrack(right_arm, :rotation, times,
            [Vec3(0.0, 0.0, -0.45), Vec3(0.0, 0.0, 0.90), Vec3(0.0, 0.0, -0.45), Vec3(0.0, 0.0, 0.90), Vec3(0.0, 0.0, -0.45)]),
        KeyframeTrack(left_leg, :rotation, times,
            [Vec3(0.42, 0.0, 0.0), Vec3(-0.42, 0.0, 0.0), Vec3(0.42, 0.0, 0.0), Vec3(-0.42, 0.0, 0.0), Vec3(0.42, 0.0, 0.0)]),
        KeyframeTrack(right_leg, :rotation, times,
            [Vec3(-0.42, 0.0, 0.0), Vec3(0.42, 0.0, 0.0), Vec3(-0.42, 0.0, 0.0), Vec3(0.42, 0.0, 0.0), Vec3(-0.42, 0.0, 0.0)]),
        KeyframeTrack(antenna, :rotation, [0.0, 0.5, 1.0],
            [Vec3(0.0, 0.0, -0.18), Vec3(0.0, 0.0, 0.18), Vec3(0.0, 0.0, -0.18)]),
        KeyframeTrack(head, :rotation, [0.0, 1.0, 2.0],
            [Vec3(0.0, -0.18, 0.0), Vec3(0.0, 0.18, 0.0), Vec3(0.0, -0.18, 0.0)]),
    ]

    clip = AnimationClip("robot_dance", 2.0, tracks; loop=:repeat)
    return WebGLExportCase(
        "robot",
        "Robot Workshop",
        "A cute keyed robot. Use the playback speed control above to tune the dance.",
        scene;
        target=Vec3(0.0, 1.35, 0.0),
        radius=7.2,
        height=4.8,
        fov=pi / 4.2,
        tone_mapping=:aces,
        tone_exposure=1.08,
        animations=[clip],
    )
end

function build_materials_case()
    scene = Scene(background=Color3(0.025, 0.025, 0.032))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=14.0, depth=14.0, color=Color3(0.20, 0.21, 0.25)))

    mats = [
        MeshPhysicalMaterial(color=Color3(0.95, 0.30, 0.24), metalness=0.0, roughness=0.32, clearcoat=0.8, clearcoat_roughness=0.16),
        MeshStandardMaterial(color=Color3(0.18, 0.68, 0.98), metalness=0.65, roughness=0.26),
        MeshToonMaterial(color=Color3(0.98, 0.78, 0.26), gradient_steps=4),
        MeshMatcapMaterial(color=Color3(0.58, 0.84, 0.46)),
        MeshNormalMaterial(),
    ]
    xs = [-3.2, -1.6, 0.0, 1.6, 3.2]
    tracks = AbstractKeyframeTrack[]
    for (i, x) in enumerate(xs)
        geo = isodd(i) ? TorusKnotGeometry(radius=0.48, tube=0.14, tubular_segments=72, radial_segments=10) :
                         SphereGeometry(radius=0.62, width_segments=36, height_segments=20)
        mesh = Mesh(geo, mats[i]; name="material_sample_$i", cast_shadow=true, receive_shadow=true)
        mesh.position = Vec3(x, 0.85, 0.0)
        add!(scene, mesh)
        push!(tracks, KeyframeTrack(mesh, :rotation, [0.0, 3.0],
            [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 2pi, 0.0)]))
    end
    clip = AnimationClip("material_turntable", 3.0, tracks; loop=:repeat)
    return WebGLExportCase(
        "materials",
        "Material Turntable",
        "Physical, standard, toon, matcap, and normal materials on rotating geometry.",
        scene;
        target=Vec3(0.0, 0.85, 0.0),
        radius=7.8,
        height=3.6,
        fov=pi / 4.4,
        tone_mapping=:aces,
        tone_exposure=1.0,
        animations=[clip],
    )
end

function build_instancing_case()
    scene = Scene(background=Color3(0.014, 0.022, 0.030), fog=FogExp2(color=Color3(0.014, 0.022, 0.030), density=0.016))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=20.0, depth=20.0, color=Color3(0.18, 0.28, 0.25)))

    stem_geo = CylinderGeometry(radius_top=0.035, radius_bottom=0.045, height=0.75, radial_segments=8)
    flower_geo = IcosahedronGeometry(radius=0.22, detail=2)
    stems = InstancedMesh(stem_geo, MeshStandardMaterial(color=Color3(0.22, 0.62, 0.36), roughness=0.72), 121; name="garden_stems")
    flowers = InstancedMesh(flower_geo, MeshStandardMaterial(color=Color3(0.92, 0.44, 0.74), roughness=0.46), 121; name="garden_flowers")
    k = 0
    for ix in -5:5, iz in -5:5
        k += 1
        x = 0.72 * ix
        z = 0.72 * iz
        h = 0.56 + 0.22 * sin(0.8 * ix + 0.55 * iz)
        set_instance_matrix!(stems, k, mat4_translation(x, h / 2, z) * mat4_scaling(1.0, h / 0.75, 1.0))
        set_instance_matrix!(flowers, k, mat4_translation(x, h + 0.12, z) * mat4_rotation_y(0.25 * (ix + iz)) * mat4_scaling(0.9, 0.9, 0.9))
    end
    add!(scene, stems); add!(scene, flowers)

    butterfly = Sprite(MeshBasicMaterial(color=Color3(1.0, 0.84, 0.26), side=:double); name="butterfly")
    butterfly.position = Vec3(0.0, 1.7, 0.0)
    butterfly.scale = Vec3(0.42, 0.42, 0.42)
    add!(scene, butterfly)
    clip = AnimationClip("butterfly_loop", 6.0, AbstractKeyframeTrack[
        KeyframeTrack(butterfly, :position, [0.0, 1.5, 3.0, 4.5, 6.0],
            [Vec3(-2.6, 1.4, -1.8), Vec3(-0.8, 2.1, 1.6), Vec3(1.5, 1.7, 1.8), Vec3(2.5, 2.2, -1.1), Vec3(-2.6, 1.4, -1.8)];
            interpolation=:cubic),
        NumberKeyframeTrack(butterfly, :material_rotation, [0.0, 0.25, 0.5], [0.0, 0.7, 0.0]; interpolation=:cubic),
    ]; loop=:repeat)

    return WebGLExportCase(
        "instancing",
        "Instanced Garden",
        "Hundreds of repeated meshes plus a sprite animated through the flowers.",
        scene;
        target=Vec3(0.0, 0.9, 0.0),
        radius=8.8,
        height=4.4,
        fov=pi / 4.6,
        tone_mapping=:aces,
        animations=[clip],
    )
end

function build_particles_case()
    scene = Scene(background=Color3(0.002, 0.004, 0.011))
    add!(scene, AmbientLight(color=Color3(0.20, 0.24, 0.34), intensity=0.8))
    add!(scene, PointLight(color=Color3(0.42, 0.72, 1.0), intensity=8.0, distance=9.0, position=Vec3(0.0, 2.8, 3.0)))

    pts = Vec3{Float64}[]
    for i in 1:520
        t = 0.21 * i
        r = 0.012 * i
        y = 0.010 * i - 2.6
        push!(pts, Vec3(r * cos(t), y, r * sin(t)))
    end
    positions = Float64[]
    for p in pts
        append!(positions, (p.x, p.y, p.z))
    end
    add!(scene, PointsObject(
        BufferGeometry(positions, Float64[], Float64[], Int[], length(pts), 0),
        PointsMaterial(color=Color3(0.58, 0.82, 1.0), size=3.4);
        name="star_spiral",
    ))

    ring = Mesh(TorusGeometry(radius=2.35, tube=0.018, radial_segments=8, tubular_segments=96),
                MeshBasicMaterial(color=Color3(0.30, 0.48, 0.86), side=:double);
                name="orbit_ring")
    ring.rotation = Euler(pi / 2, 0.0, 0.0)
    add!(scene, ring)

    return WebGLExportCase(
        "particles",
        "Particle Spiral",
        "A dense PointsObject field with a reference torus in live WebGL.",
        scene;
        target=Vec3(0.0, 0.1, 0.0),
        radius=8.0,
        height=2.4,
        fov=pi / 3.1,
        tone_mapping=:reinhard,
        tone_exposure=1.15,
    )
end

function build_shadows_case()
    bg = Color3(0.045, 0.052, 0.068)
    scene = Scene(background=bg, fog=FogExp2(color=bg, density=0.010))

    # Fill lights so shadowed regions read as deep grey rather than pure black.
    add!(scene, AmbientLight(color=Color3(0.30, 0.34, 0.44), intensity=0.42,
                             name="shadows_ambient"))
    add!(scene, HemisphereLight(color=Color3(0.50, 0.62, 0.82),
                                ground_color=Color3(0.20, 0.17, 0.15),
                                intensity=0.30))

    # Key light: crisp directional shadow map onto the floor (per webgl_shadowmap.jl).
    add!(scene, DirectionalLight(color=Color3(1.0, 0.96, 0.88), intensity=2.6,
                                 position=Vec3(6.5, 9.5, 4.5),
                                 cast_shadow=true, shadow_bias=0.0001,
                                 shadow_pcf_radius=2, name="shadows_key"))

    # Cool rim spotlight, also shadow-casting, for a second overlapping shadow.
    add!(scene, SpotLight(color=Color3(0.55, 0.74, 1.0), intensity=55.0,
                          distance=32.0, angle=0.55, penumbra=0.35, decay=1.5,
                          position=Vec3(-6.5, 8.5, -4.5),
                          target=Vec3(0.0, 0.7, 0.0),
                          cast_shadow=true, shadow_bias=0.0002,
                          shadow_pcf_radius=2, name="shadows_spot"))

    # Large receiver floor (make_floor already sets receive_shadow=true).
    add!(scene, make_floor(width=24.0, depth=24.0, color=Color3(0.31, 0.33, 0.38)))

    # Low pedestal that both casts and receives shadows.
    pedestal = Mesh(
        CylinderGeometry(radius_top=1.35, radius_bottom=1.55, height=0.5,
                         radial_segments=48),
        MeshStandardMaterial(color=Color3(0.82, 0.84, 0.80), roughness=0.7,
                             metalness=0.05);
        name="shadows_pedestal", cast_shadow=true, receive_shadow=true,
    )
    pedestal.position = Vec3(0.0, 0.25, 0.0)
    add!(scene, pedestal)

    # Static pillars ring the stage: casters that also receive the moving shadows.
    pillar_colors = (Color3(0.30, 0.55, 0.85), Color3(0.90, 0.52, 0.26),
                     Color3(0.36, 0.78, 0.56), Color3(0.80, 0.36, 0.62))
    for (i, ang) in enumerate(range(pi / 4, stop=2pi + pi / 4, length=5)[1:4])
        h = 1.6 + 0.7 * (i % 3)
        x = 5.6 * cos(ang)
        z = 5.6 * sin(ang)
        add!(scene, make_box_part("shadows_pillar_$i", Vec3(0.8, h, 0.8),
                                  pillar_colors[i];
                                  position=Vec3(x, h / 2, z), roughness=0.55))
    end

    tracks = AbstractKeyframeTrack[]
    duration = 6.0

    # Bouncing sphere over the pedestal: its shadow grows and shrinks on the floor.
    bouncer = make_sphere_part("shadows_bouncer", 0.72, Color3(0.98, 0.55, 0.24);
                               position=Vec3(0.0, 1.3, 0.0), roughness=0.32)
    add!(scene, bouncer)
    push!(tracks, KeyframeTrack(bouncer, :position,
                                [0.0, 1.5, 3.0, 4.5, 6.0],
                                [Vec3(0.0, 1.05, 0.0), Vec3(0.0, 3.4, 0.0),
                                 Vec3(0.0, 1.05, 0.0), Vec3(0.0, 3.4, 0.0),
                                 Vec3(0.0, 1.05, 0.0)]; interpolation=:cubic))

    # Orbiting sphere: a shadow sweeping across the stage.
    orbit_a = Group(name="shadows_orbit_a")
    add!(scene, orbit_a)
    add!(orbit_a, make_sphere_part("shadows_orbit_sphere", 0.55,
                                   Color3(0.95, 0.42, 0.72);
                                   position=Vec3(3.7, 1.15, 0.0), roughness=0.36))
    push!(tracks, KeyframeTrack(orbit_a, :rotation, [0.0, 3.0, 6.0],
                                [Vec3(0.0, 0.0, 0.0), Vec3(0.0, pi, 0.0),
                                 Vec3(0.0, 2pi, 0.0)]))

    # Counter-orbiting tumbling box at a higher radius for a longer cast shadow.
    orbit_b = Group(name="shadows_orbit_b")
    add!(scene, orbit_b)
    box = make_box_part("shadows_orbit_box", Vec3(0.75, 0.75, 0.75),
                        Color3(0.42, 0.82, 0.52); position=Vec3(0.0, 1.7, 3.4),
                        roughness=0.4)
    add!(orbit_b, box)
    push!(tracks, KeyframeTrack(orbit_b, :rotation, [0.0, 3.0, 6.0],
                                [Vec3(0.0, 0.0, 0.0), Vec3(0.0, -pi, 0.0),
                                 Vec3(0.0, -2pi, 0.0)]))
    push!(tracks, KeyframeTrack(box, :rotation, [0.0, 3.0, 6.0],
                                [Vec3(0.0, 0.0, 0.0), Vec3(pi, pi, 0.0),
                                 Vec3(2pi, 2pi, 0.0)]))

    clip = AnimationClip("shadow_play", duration, tracks; loop=:repeat)

    return WebGLExportCase(
        "shadows",
        "Shadow Play",
        "A directional key light and a shadow-casting spotlight drop moving shadow maps from bouncing and orbiting casters onto the receiving floor.",
        scene;
        target=Vec3(0.0, 1.0, 0.0),
        radius=12.5,
        height=6.5,
        fov=pi / 4.2,
        tone_mapping=:aces,
        tone_exposure=1.05,
        animations=[clip],
    )
end

function build_spotlights_case()
    # Feature focus: several colored SpotLights (angle, penumbra, distance, decay)
    # aimed at a central object over a floor, giving overlapping colored pools of
    # light. The whole rig orbits so the pools sweep across the floor.
    scene = Scene(background=Color3(0.020, 0.021, 0.028))

    # Dim, feature-specific ambient/hemisphere fill so the colored spot pools pop.
    add!(scene, AmbientLight(color=Color3(0.11, 0.12, 0.16), intensity=1.0,
                             name="spot_rig_ambient"))
    add!(scene, HemisphereLight(color=Color3(0.14, 0.16, 0.22),
                                ground_color=Color3(0.05, 0.05, 0.06),
                                intensity=0.30, name="spot_rig_hemi"))

    # Dark floor catches the colored pools.
    add!(scene, make_floor(width=22.0, depth=22.0, color=Color3(0.14, 0.15, 0.18)))

    # Central display: a metal pedestal with a levitating faceted gem that catches
    # each spotlight color on a different facet.
    pedestal = Mesh(
        CylinderGeometry(radius_top=0.55, radius_bottom=0.66, height=0.5,
                         radial_segments=40),
        MeshStandardMaterial(color=Color3(0.20, 0.21, 0.25), roughness=0.32, metalness=0.65);
        name="spot_pedestal", cast_shadow=true, receive_shadow=true,
    )
    pedestal.position = Vec3(0.0, 0.25, 0.0)
    add!(scene, pedestal)

    gem_center = Vec3(0.0, 1.5, 0.0)
    gem = Mesh(
        IcosahedronGeometry(radius=0.9, detail=1),
        MeshStandardMaterial(color=Color3(0.88, 0.89, 0.92), roughness=0.26, metalness=0.18);
        name="spot_gem", cast_shadow=true, receive_shadow=true,
    )
    gem.position = gem_center
    add!(scene, gem)

    # Six saturated spotlight colors around the hue wheel.
    colors = [
        Color3(1.00, 0.20, 0.26),   # red-pink
        Color3(1.00, 0.55, 0.12),   # orange
        Color3(0.95, 0.90, 0.20),   # yellow
        Color3(0.24, 1.00, 0.46),   # green
        Color3(0.20, 0.64, 1.00),   # blue
        Color3(0.74, 0.30, 1.00),   # violet
    ]
    n = length(colors)
    orbit_radius = 3.6
    orbit_height = 4.8
    duration = 8.0
    samples = 16

    times = [duration * k / samples for k in 0:samples]
    tracks = AbstractKeyframeTrack[]

    for (i, col) in enumerate(colors)
        base_angle = 2pi * (i - 1) / n
        ring_pos = [Vec3(orbit_radius * cos(base_angle + 2pi * k / samples),
                         orbit_height,
                         orbit_radius * sin(base_angle + 2pi * k / samples))
                    for k in 0:samples]

        spot = SpotLight(color=col, intensity=28.0, distance=60.0, angle=0.36,
                         penumbra=0.40, decay=2.0, position=ring_pos[1],
                         target=gem_center, name="spot_$i")
        add!(scene, spot)

        # A small emissive bulb marks each moving light head.
        bulb = Mesh(
            SphereGeometry(radius=0.11, width_segments=16, height_segments=10),
            MeshBasicMaterial(color=col);
            name="spot_bulb_$i",
        )
        bulb.position = ring_pos[1]
        add!(scene, bulb)

        # Orbit the light and its bulb together; pulse the cone so the pool breathes.
        push!(tracks, KeyframeTrack(spot, :position, times, ring_pos))
        push!(tracks, KeyframeTrack(bulb, :position, times, ring_pos))
        push!(tracks, NumberKeyframeTrack(spot, :angle,
            [0.0, duration / 2, duration],
            [0.36, 0.26 + 0.04 * i, 0.36]; interpolation=:cubic))
        push!(tracks, NumberKeyframeTrack(spot, :penumbra,
            [0.0, duration / 2, duration],
            [0.40, 0.55, 0.40]; interpolation=:cubic))
    end

    # The gem slowly turns and bobs so its facets sweep through the colored beams.
    push!(tracks, KeyframeTrack(gem, :rotation, [0.0, duration],
        [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 2pi, 0.0)]))
    push!(tracks, KeyframeTrack(gem, :position,
        [0.0, duration / 2, duration],
        [Vec3(0.0, 1.5, 0.0), Vec3(0.0, 1.66, 0.0), Vec3(0.0, 1.5, 0.0)];
        interpolation=:cubic))

    clip = AnimationClip("spotlight_rig", duration, tracks; loop=:repeat)

    return WebGLExportCase(
        "spotlights",
        "Spotlight Rig",
        "Six colored spotlights orbit a levitating gem, sweeping overlapping pools of light across the floor.",
        scene;
        target=Vec3(0.0, 1.2, 0.0),
        radius=8.2,
        height=4.6,
        fov=pi / 4.2,
        tone_mapping=:aces,
        tone_exposure=1.02,
        animations=[clip],
    )
end

function _clip_solid(name, geo, color::Color3; position=Vec3(), roughness=0.42,
                     metalness=0.10, emissive=Color3(0.0, 0.0, 0.0),
                     emissive_intensity=1.0)
    mesh = Mesh(
        geo,
        MeshStandardMaterial(color=color, roughness=roughness, metalness=metalness,
                             emissive=emissive, emissive_intensity=emissive_intensity,
                             side=:double);
        name=name,
        cast_shadow=true,
        receive_shadow=true,
    )
    mesh.position = position
    return mesh
end

function build_clipping_case()
    scene = Scene(background=Color3(0.035, 0.040, 0.052),
                  fog=FogExp2(color=Color3(0.035, 0.040, 0.052), density=0.012))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=20.0, depth=15.0, color=Color3(0.22, 0.24, 0.28)))

    # All solids straddle the horizontal slicing plane (below). The plane keeps
    # everything with y < 1.55, so their upper caps are removed to expose the
    # interior while the floor (y == 0) stays whole.
    cut_y = 1.55
    center_y = 1.35

    # Hero "geode": an opaque outer shell with a glowing molten core inside. The
    # cut lifts the lid off the shell and reveals the hidden core.
    geode = Group(name="section_geode")
    geode.position = Vec3(0.0, center_y, 0.0)
    add!(scene, geode)
    add!(geode, _clip_solid("geode_shell",
                            SphereGeometry(radius=1.05, width_segments=40, height_segments=24),
                            Color3(0.60, 0.64, 0.72); roughness=0.55, metalness=0.18))
    add!(geode, _clip_solid("geode_core",
                            SphereGeometry(radius=0.56, width_segments=36, height_segments=20),
                            Color3(1.00, 0.52, 0.16); roughness=0.38, metalness=0.0,
                            emissive=Color3(1.00, 0.42, 0.10), emissive_intensity=1.7))

    # Left and right props: knots that tumble through the same plane so the
    # exposed cross-section keeps changing.
    left = _clip_solid("section_knot_left",
                       TorusKnotGeometry(radius=0.52, tube=0.19, tubular_segments=80, radial_segments=12),
                       Color3(0.20, 0.74, 0.78); position=Vec3(-3.3, center_y, 0.0), roughness=0.34, metalness=0.20)
    right = _clip_solid("section_knot_right",
                        TorusKnotGeometry(radius=0.52, tube=0.19, tubular_segments=80, radial_segments=12),
                        Color3(0.92, 0.36, 0.62); position=Vec3(3.3, center_y, 0.0), roughness=0.34, metalness=0.20)
    add!(scene, left); add!(scene, right)

    # A visible frame marks where the world clipping plane sits. PlaneHelper
    # already bakes its vertices at world height = constant, so no extra
    # position offset is needed; nudge it a hair below the cut so it stays in
    # the kept half-space (y < cut_y) instead of straddling the exact boundary.
    helper = PlaneHelper(Plane(Vec3(0.0, -1.0, 0.0), cut_y - 0.015), 9.6;
                         color=Color3(0.98, 0.80, 0.34))
    add!(scene, helper)

    tracks = AbstractKeyframeTrack[
        KeyframeTrack(geode, :rotation, [0.0, 6.0],
                      [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 4pi, 0.0)]),
        KeyframeTrack(left, :rotation, [0.0, 6.0],
                      [Vec3(0.0, 0.0, 0.0), Vec3(2pi, 0.0, 0.0)]),
        KeyframeTrack(right, :rotation, [0.0, 6.0],
                      [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, -2pi)]),
    ]
    clip = AnimationClip("section_turntable", 6.0, tracks; loop=:repeat)

    return WebGLExportCase(
        "clipping",
        "Section Cut",
        "A world clipping plane slices each solid open, revealing the hidden interior as the shapes rotate through the cut.",
        scene;
        target=Vec3(0.0, 1.15, 0.0),
        radius=8.6,
        height=4.6,
        fov=pi / 4.2,
        tone_mapping=:aces,
        tone_exposure=1.05,
        animations=[clip],
        clipping_planes=[Plane(Vec3(0.0, -1.0, 0.0), cut_y)],
    )
end

function build_csg_case()
    scene = Scene(background=Color3(0.028, 0.033, 0.047),
                  fog=FogExp2(color=Color3(0.028, 0.033, 0.047), density=0.014))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=18.0, depth=18.0, color=Color3(0.19, 0.20, 0.24)))

    # A small stone pedestal each sculpture rests on.
    pedestal_mat = MeshStandardMaterial(color=Color3(0.15, 0.16, 0.19),
                                        roughness=0.86, metalness=0.10)
    make_pedestal(name, x) = begin
        p = Mesh(BoxGeometry(width=1.55, height=0.5, depth=1.55), pedestal_mat;
                 name=name, cast_shadow=true, receive_shadow=true)
        p.position = Vec3(x, 0.25, 0.0)
        p
    end

    # --- Boolean operands (positioned with transform_geometry) -------------
    # Operand tessellation is chosen so the curved boolean results read as
    # smoothly rounded, while staying moderate: CSG output is non-indexed
    # triangle soup, so serialized size scales with the result triangle count.
    # ~24-32 segments looks round without the multi-MB blowup of 48+.

    # 1. Intersection: a cube clipped by a sphere -> a cushioned cube.
    cube = BoxGeometry(width=1.5, height=1.5, depth=1.5)
    ball = SphereGeometry(radius=1.0, width_segments=22, height_segments=14)
    cushion = csg_intersect(cube, ball)

    # 2. Subtraction: a sphere drilled through by a horizontal cylinder.
    sphere = SphereGeometry(radius=0.95, width_segments=22, height_segments=14)
    drill = transform_geometry(
        CylinderGeometry(radius_top=0.4, radius_bottom=0.4, height=2.4,
                         radial_segments=18, height_segments=1),
        mat4_rotation_z(pi / 2))
    bead = csg_subtract(sphere, drill)

    # 3. Union: two crossed cylinders fused into a plus.
    up_bar = CylinderGeometry(radius_top=0.34, radius_bottom=0.34, height=1.7,
                              radial_segments=18, height_segments=1)
    side_bar = transform_geometry(
        CylinderGeometry(radius_top=0.34, radius_bottom=0.34, height=1.7,
                         radial_segments=18, height_segments=1),
        mat4_rotation_z(pi / 2))
    cross = csg_union(up_bar, side_bar)

    cushion_mat = MeshPhysicalMaterial(color=Color3(0.95, 0.42, 0.24),
                                       metalness=0.0, roughness=0.34,
                                       clearcoat=0.7, clearcoat_roughness=0.18,
                                       side=:double)
    bead_mat = MeshStandardMaterial(color=Color3(0.20, 0.72, 0.66),
                                    metalness=0.35, roughness=0.40, side=:double)
    cross_mat = MeshStandardMaterial(color=Color3(0.98, 0.78, 0.26),
                                     metalness=0.25, roughness=0.44, side=:double)

    # column layout: (name, geometry, material, x, half-height, spin direction)
    columns = [
        ("csg_union_cross", cross, cross_mat, -3.0, 0.85, 1.0),
        ("csg_intersect_cushion", cushion, cushion_mat, 0.0, 0.75, -1.0),
        ("csg_subtract_bead", bead, bead_mat, 3.0, 0.95, 1.0),
    ]

    tracks = AbstractKeyframeTrack[]
    for (name, geo, mat, x, half, dir) in columns
        add!(scene, make_pedestal("$(name)_pedestal", x))

        spinner = Group(name="$(name)_spinner")
        spinner.position = Vec3(x, 0.5 + half, 0.0)
        add!(scene, spinner)

        mesh = Mesh(geo, mat; name=name, cast_shadow=true, receive_shadow=true)
        add!(spinner, mesh)

        push!(tracks, KeyframeTrack(spinner, :rotation, [0.0, 12.0],
            [Vec3(0.0, 0.0, 0.0), Vec3(0.0, dir * 2pi, 0.0)]))
    end

    clip = AnimationClip("csg_turntable", 12.0, tracks; loop=:repeat)

    return WebGLExportCase(
        "csg",
        "Boolean Sculpt",
        "Constructive solid geometry: union, subtraction, and intersection carve three sculptures that slowly turn on their pedestals.",
        scene;
        target=Vec3(0.0, 1.1, 0.0),
        radius=9.2,
        height=4.6,
        fov=pi / 4.3,
        tone_mapping=:aces,
        tone_exposure=1.05,
        output_color_space=:srgb,
        animations=[clip],
    )
end

function build_extrude_case()
    # 2D emblem outlines. Grounded on webgl_geometry_extrude_shapes.jl and
    # webgl_geometry_shapes.jl (ExtrudeGeometry / ShapeGeometry from Vec2 shapes).
    # ShapeGeometry/ExtrudeGeometry cap triangulation is a fan from vertex 1, so
    # each outline is authored to be star-shaped from its first vertex:
    #   * stars/gears begin on an inner (valley) vertex,
    #   * the heart begins on its bottom tip and is traced CCW.
    # This makes the fan caps tile crisply (measured overdraw <= ~4%).
    function star_outline(points, inner, outer)
        s = Vec2{Float64}[]
        for i in 0:(2 * points - 1)
            r = iseven(i) ? inner : outer          # vertex 1 = inner valley
            a = pi / 2 + i * pi / points
            push!(s, Vec2(cos(a) * r, sin(a) * r))
        end
        return s
    end
    function gear_outline(teeth, inner, outer)
        s = Vec2{Float64}[]
        m = 2 * teeth
        for i in 0:(m - 1)
            r = iseven(i) ? inner : outer          # vertex 1 = inner root
            a = 2pi * i / m
            push!(s, Vec2(cos(a) * r, sin(a) * r))
        end
        return s
    end
    function heart_outline(scale; n=44)
        pts = Vec2{Float64}[]
        for k in 0:(n - 1)
            t = pi - 2pi * k / n                   # bottom tip first, traced CCW
            x = 16 * sin(t)^3
            y = 13 * cos(t) - 5 * cos(2t) - 2 * cos(3t) - cos(4t)
            push!(pts, Vec2(x * scale, y * scale))
        end
        ymin = minimum(p.y for p in pts)
        ymax = maximum(p.y for p in pts)
        yc = (ymin + ymax) / 2
        return Vec2{Float64}[Vec2(p.x, p.y - yc) for p in pts]  # center vertically
    end
    hex_outline(radius) = Vec2{Float64}[
        Vec2(radius * cos(pi / 6 + 2pi * i / 6), radius * sin(pi / 6 + 2pi * i / 6))
        for i in 0:5]

    scene = Scene(background=Color3(0.028, 0.032, 0.045),
                  fog=FogExp2(color=Color3(0.028, 0.032, 0.045), density=0.016))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=16.0, depth=16.0, color=Color3(0.22, 0.24, 0.30)))

    emblems = Group(name="emblems")
    add!(scene, emblems)

    depth = 0.24
    y_base = 1.35
    # (name, outline, color, metalness, roughness)
    specs = [
        ("hex_emerald", hex_outline(0.55),           Color3(0.20, 0.82, 0.60), 0.55, 0.24),
        ("star_violet", star_outline(6, 0.30, 0.56), Color3(0.60, 0.42, 0.95), 0.60, 0.30),
        ("heart_rose",  heart_outline(0.037),        Color3(0.93, 0.24, 0.38), 0.35, 0.30),
        ("star_gold",   star_outline(5, 0.24, 0.56), Color3(1.00, 0.80, 0.26), 0.85, 0.28),
        ("gear_steel",  gear_outline(9, 0.44, 0.56), Color3(0.70, 0.74, 0.82), 0.90, 0.34),
    ]
    xs = [-3.1, -1.55, 0.0, 1.55, 3.1]

    tracks = AbstractKeyframeTrack[]
    T = 12.0
    n = length(specs)
    for (i, (name, outline, color, metalness, roughness)) in enumerate(specs)
        holder = Group(name="$(name)_holder")
        holder.position = Vec3(xs[i], y_base, 0.0)
        add!(emblems, holder)

        mesh = Mesh(ExtrudeGeometry(outline, depth=depth),
                    MeshStandardMaterial(color=color, metalness=metalness,
                                         roughness=roughness, side=:double);
                    name=name, cast_shadow=true, receive_shadow=true)
        mesh.position = Vec3(0.0, 0.0, -depth / 2)   # center the slab on the pivot
        add!(holder, mesh)

        phase = 2pi * (i - 1) / n                     # staggered turntable spin
        push!(tracks, KeyframeTrack(holder, :rotation, [0.0, T],
            [Vec3(0.0, phase, 0.0), Vec3(0.0, phase + 2pi, 0.0)]))

        bob = 0.14
        bp = pi * (i - 1) / n                          # gentle, phased vertical bob
        push!(tracks, KeyframeTrack(holder, :position,
            [0.0, T / 4, T / 2, 3T / 4, T],
            [Vec3(xs[i], y_base + bob * sin(bp),            0.0),
             Vec3(xs[i], y_base + bob * sin(bp + pi / 2),   0.0),
             Vec3(xs[i], y_base + bob * sin(bp + pi),       0.0),
             Vec3(xs[i], y_base + bob * sin(bp + 3pi / 2),  0.0),
             Vec3(xs[i], y_base + bob * sin(bp + 2pi),      0.0)];
            interpolation=:cubic))
    end

    clip = AnimationClip("emblem_carousel", T, tracks; loop=:repeat)
    return WebGLExportCase(
        "extrude",
        "Extruded Emblems",
        "Star, heart, gear, and hexagon outlines swept into 3D with ExtrudeGeometry, each turning on its own axis.",
        scene;
        target=Vec3(0.0, 1.2, 0.0),
        radius=9.5,
        height=3.4,
        fov=pi / 4.2,
        tone_mapping=:aces,
        tone_exposure=1.05,
        animations=[clip],
    )
end

function build_text_case()
    # Same committed Optimer typeface asset used by webgl_geometry_text.jl.
    # dirname(OUT) is the examples/ directory in both this gallery file and the
    # verification harness, so the font resolves without depending on cwd.
    font_path = joinpath(dirname(OUT), "assets", "fonts", "optimer_bold.typeface.json")
    isfile(font_path) || error("missing vendored Optimer font asset at $font_path")
    font = FontLoader(font_path)

    scene = Scene(background=Color3(0.021, 0.026, 0.038),
                  fog=FogExp2(color=Color3(0.021, 0.026, 0.038), density=0.020))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=18.0, depth=18.0, color=Color3(0.17, 0.19, 0.24)))

    # Extruded 3D text built like webgl_geometry_text.jl. curve_segments is kept
    # at 1 on purpose: the glyph triangulator (_font_bridge_one_hole hole-bridging
    # + _font_triangulate_simple ear-clipping) is not robust to finely tessellated
    # outlines -- at curve_segments >= 2 the bridged glyph polygon self-intersects
    # and the ear-clip stalls, shattering the letter fills (front-cap area collapses
    # from ~54% of the glyph bbox to ~25%). curve_segments=1 gives correct, solid
    # letterforms (slightly faceted curves). Bevel is likewise left off (its offset
    # loop self-intersects at >=2 segments). Bumping this needs a robust triangulator.
    geo = TextGeometry(font, "Diff3D"; size=1.1, depth=0.34, curve_segments=1,
                       bevel_enabled=false)
    geo.n_vertices > 0 || error("TextGeometry produced no vertices")
    bbox = compute_bounding_box(geo)
    center_offset = -0.5 * (bbox.max.x - bbox.min.x) - bbox.min.x

    material = MeshStandardMaterial(color=Color3(0.96, 0.63, 0.19),
                                    metalness=0.40, roughness=0.30)
    text_mesh = Mesh(geo, material; name="hello_diff3d_text",
                     cast_shadow=true, receive_shadow=false)
    text_mesh.position = Vec3(center_offset, 0.0, 0.0)

    # A turntable group so the centered word spins in place over the floor.
    turntable = Group(name="hello_diff3d_turntable")
    turntable.position = Vec3(0.0, 0.95, 0.0)
    add!(turntable, text_mesh)
    add!(scene, turntable)

    clip = AnimationClip("hello_spin", AbstractKeyframeTrack[
        KeyframeTrack(turntable, :rotation, [0.0, 6.0],
                      [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 2pi, 0.0)]),
    ]; loop=:repeat)

    return WebGLExportCase(
        "text",
        "Hello Diff3D",
        "Beveled, extruded TextGeometry from the Optimer typeface spinning on a turntable under studio lights.",
        scene;
        target=Vec3(0.0, 1.35, 0.0),
        radius=7.6,
        height=3.4,
        fov=pi / 4.4,
        tone_mapping=:aces,
        tone_exposure=1.05,
        output_color_space=:srgb,
        animations=[clip],
    )
end

function build_terrain_case()
    # ---- Height field for a small rolling island (plane-space u,v in [0,1]) ----
    segments = 72
    ncols = segments + 1

    # Smooth rolling relief with a radial edge fade so the island falls to the
    # waterline at its border (never negative -> clean colour ramp domain).
    terrain_h(u, v) = begin
        base = 0.55 +
               0.45 * sin(2.2pi * u + 0.4) * cos(1.8pi * v - 0.3) +
               0.28 * sin(3.6pi * u - 1.0) * cos(3.1pi * v + 0.6) +
               0.13 * sin(6.4pi * u + 2.0pi * v)
        r = 2.0 * max(abs(u - 0.5), abs(v - 0.5))          # 0 at centre .. 1 at edge
        fade = 0.5 * (1.0 + cos(pi * clamp(r, 0.0, 1.0)))  # 1 at centre -> 0 at edge
        return fade * max(base, 0.0)
    end

    # Height-based terrain colour ramp (t in [0,1]): beach -> meadow -> rock -> snow.
    stops = [
        (0.00, Color3(0.78, 0.72, 0.52)),  # beach sand
        (0.12, Color3(0.36, 0.56, 0.30)),  # shoreline green
        (0.42, Color3(0.28, 0.48, 0.22)),  # meadow
        (0.64, Color3(0.44, 0.40, 0.30)),  # earthy rock
        (0.82, Color3(0.54, 0.52, 0.50)),  # grey stone
        (1.00, Color3(0.97, 0.98, 1.00)),  # snow cap
    ]
    terrain_color(t) = begin
        t = clamp(t, 0.0, 1.0)
        for i in 1:length(stops) - 1
            t0, c0 = stops[i]
            t1, c1 = stops[i + 1]
            if t <= t1
                f = clamp((t - t0) / max(t1 - t0, 1e-9), 0.0, 1.0)
                return Color3(c0.r + (c1.r - c0.r) * f,
                              c0.g + (c1.g - c0.g) * f,
                              c0.b + (c1.b - c0.b) * f)
            end
        end
        return stops[end][2]
    end

    # ---- Displace a PlaneGeometry into the height field + per-vertex colours ----
    world = 16.0
    amplitude = 2.9
    geo = PlaneGeometry(width=world, height=world,
                        width_segments=segments, height_segments=segments)

    # Sample raw heights, then normalise to [0,1] for both displacement and colour.
    raw = Vector{Float64}(undef, geo.n_vertices)
    for iy in 0:segments, ix in 0:segments
        vi = iy * ncols + ix + 1
        raw[vi] = terrain_h(ix / segments, iy / segments)
    end
    rmin = minimum(raw)
    rmax = maximum(raw)
    span = max(rmax - rmin, 1e-9)

    colors = Vector{Float64}(undef, 3 * geo.n_vertices)
    for vi in 1:geo.n_vertices
        t = (raw[vi] - rmin) / span
        geo.positions[3vi] = amplitude * t          # displace along plane +Z (its normal)
        c = terrain_color(t)
        colors[3vi - 2] = c.r
        colors[3vi - 1] = c.g
        colors[3vi]     = c.b
    end

    # Recompute per-vertex normals from the displaced grid (plane space) so the
    # standard-material lighting follows the new relief instead of the flat plane.
    plane_pos(vi) = Vec3(geo.positions[3vi - 2], geo.positions[3vi - 1], geo.positions[3vi])
    for iy in 0:segments, ix in 0:segments
        vi = iy * ncols + ix + 1
        ixm = max(ix - 1, 0); ixp = min(ix + 1, segments)
        iym = max(iy - 1, 0); iyp = min(iy + 1, segments)
        tx = plane_pos(iy * ncols + ixp + 1) - plane_pos(iy * ncols + ixm + 1)
        ty = plane_pos(iyp * ncols + ix + 1) - plane_pos(iym * ncols + ix + 1)
        n = cross(tx, ty)
        n.z < 0.0 && (n = -n)                        # keep normals on the +Z (front) side
        n = normalize(n)
        geo.normals[3vi - 2] = n.x
        geo.normals[3vi - 1] = n.y
        geo.normals[3vi]     = n.z
    end
    set_attribute!(geo, :color, colors, 3)

    terrain = Mesh(geo,
                   MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0),
                                        vertex_colors=true,
                                        roughness=0.94, metalness=0.02,
                                        side=:double);
                   name="rolling_terrain")
    terrain.rotation = Euler(-pi / 2, 0.0, 0.0)      # lay the plane flat: +Z -> world +Y

    # ---- Scene, outdoor lighting, water base, and an orbiting sun ----
    sky = Color3(0.62, 0.74, 0.86)
    scene = Scene(background=sky, fog=FogExp2(color=sky, density=0.017))
    add!(scene, AmbientLight(color=Color3(0.42, 0.48, 0.58), intensity=0.35))
    add!(scene, HemisphereLight(color=Color3(0.68, 0.80, 0.95),
                                ground_color=Color3(0.30, 0.26, 0.20),
                                intensity=0.70))
    add!(scene, DirectionalLight(color=Color3(1.0, 0.94, 0.80), intensity=1.70,
                                 position=Vec3(6.0, 9.0, 4.0)))

    water = Mesh(PlaneGeometry(width=30.0, height=30.0, width_segments=1, height_segments=1),
                 MeshStandardMaterial(color=Color3(0.10, 0.28, 0.38),
                                      roughness=0.35, metalness=0.20, side=:double);
                 name="water")
    water.rotation = Euler(-pi / 2, 0.0, 0.0)
    water.position = Vec3(0.0, -0.03, 0.0)
    add!(scene, water)

    island = Group(name="terrain_island")
    add!(island, terrain)
    add!(scene, island)

    sun = Mesh(SphereGeometry(radius=0.6, width_segments=24, height_segments=16),
               MeshBasicMaterial(color=Color3(1.0, 0.86, 0.42));
               name="sun")
    sun.position = Vec3(9.0, 5.0, 0.0)
    add!(scene, sun)

    # ---- Looping animation: slow terrain turntable + a sun arcing overhead ----
    turn = KeyframeTrack(island, :rotation, [0.0, 8.0, 16.0],
        [Vec3(0.0, 0.0, 0.0), Vec3(0.0, pi, 0.0), Vec3(0.0, 2pi, 0.0)])
    sun_track = KeyframeTrack(sun, :position, [0.0, 4.0, 8.0, 12.0, 16.0],
        [Vec3(9.0, 5.0, 0.0), Vec3(0.0, 6.5, 9.0), Vec3(-9.0, 5.0, 0.0),
         Vec3(0.0, 4.5, -9.0), Vec3(9.0, 5.0, 0.0)]; interpolation=:cubic)
    clip = AnimationClip("terrain_turntable", 16.0,
                         AbstractKeyframeTrack[turn, sun_track]; loop=:repeat)

    return WebGLExportCase(
        "terrain",
        "Rolling Terrain",
        "A displaced PlaneGeometry heightfield with a per-vertex height gradient baked into a vertex-color BufferAttribute.",
        scene;
        target=Vec3(0.0, 1.0, 0.0),
        radius=15.0,
        height=8.5,
        fov=pi / 4.3,
        tone_mapping=:aces,
        tone_exposure=1.05,
        animations=[clip],
    )
end

function _vessel_profile(rys)
    return Vec2{Float64}[Vec2(Float64(r), Float64(y)) for (r, y) in rys]
end

function _add_floor_tube!(parent, path::Vector{<:Vec3}, name, material;
                          radius, radial_segments, x, z, lift_extra=0.04)
    geo = TubeGeometry(path; radius=radius, radial_segments=radial_segments)
    geo.n_vertices > 0 || error("TubeGeometry produced no vertices for $name")
    min_y = minimum(p.y for p in path) - radius
    mesh = Mesh(geo, material; name=name, cast_shadow=true, receive_shadow=true)
    mesh.position = Vec3(x, -min_y + lift_extra, z)
    add!(parent, mesh)
    return mesh
end

function _helix_coil_path(; samples=132, turns=4, coil_radius=0.5, height=1.7)
    pts = Vec3{Float64}[]
    for i in 0:samples
        t = 2pi * turns * i / samples
        y = height * i / samples
        push!(pts, Vec3(coil_radius * cos(t), y, coil_radius * sin(t)))
    end
    return pts
end

function _trefoil_path(; samples=150, scale=0.42)
    pts = Vec3{Float64}[]
    for i in 0:samples
        t = 2pi * i / samples
        x = sin(t) + 2sin(2t)
        y = cos(t) - 2cos(2t)
        z = -sin(3t)
        push!(pts, Vec3(scale * x, scale * z, scale * y))
    end
    return pts
end

function build_curves_case()
    scene = Scene(background=Color3(0.030, 0.034, 0.044),
                  fog=FogExp2(color=Color3(0.030, 0.034, 0.044), density=0.020))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=15.0, depth=15.0, color=Color3(0.21, 0.22, 0.27)))

    # Everything that "turns" lives under one slowly rotating turntable so the
    # static floor stays put underneath it.
    turntable = Group(name="vessel_turntable")
    add!(scene, turntable)

    # --- Lathe-revolved ceramic vessels ---
    terracotta = Color3(0.80, 0.38, 0.26)
    teal = Color3(0.13, 0.55, 0.55)
    cream = Color3(0.90, 0.86, 0.74)

    amphora = _vessel_profile([
        (0.00, 0.00), (0.36, 0.00), (0.42, 0.12), (0.58, 0.40),
        (0.63, 0.66), (0.55, 0.95), (0.36, 1.22), (0.27, 1.42),
        (0.34, 1.60), (0.31, 1.66),
    ])
    bottle = _vessel_profile([
        (0.00, 0.00), (0.31, 0.00), (0.35, 0.22), (0.30, 0.62),
        (0.21, 1.05), (0.15, 1.45), (0.135, 1.85), (0.20, 2.02),
        (0.17, 2.06),
    ])
    bowl = _vessel_profile([
        (0.00, 0.00), (0.22, 0.00), (0.48, 0.12), (0.66, 0.34),
        (0.72, 0.55), (0.69, 0.60),
    ])

    # Lathe revolution segments -> 64 so the rim/profile reads as smoothly round.
    lathe_segments = 64
    vase_a = Mesh(LatheGeometry(amphora; segments=lathe_segments),
                  MeshPhysicalMaterial(color=terracotta, roughness=0.34, metalness=0.0,
                                       clearcoat=0.6, clearcoat_roughness=0.22, side=:double);
                  name="vase_amphora", cast_shadow=true, receive_shadow=true)
    vase_a.position = Vec3(-2.5, 0.0, 0.7)

    vase_b = Mesh(LatheGeometry(bottle; segments=lathe_segments),
                  MeshStandardMaterial(color=teal, roughness=0.28, metalness=0.12, side=:double);
                  name="vase_bottle", cast_shadow=true, receive_shadow=true)
    vase_b.position = Vec3(-0.2, 0.0, -1.7)

    vase_c = Mesh(LatheGeometry(bowl; segments=lathe_segments),
                  MeshStandardMaterial(color=cream, roughness=0.5, metalness=0.0, side=:double);
                  name="vase_bowl", cast_shadow=true, receive_shadow=true)
    vase_c.position = Vec3(2.6, 0.0, 0.9)

    add!(turntable, vase_a); add!(turntable, vase_b); add!(turntable, vase_c)

    # --- TubeGeometry pipes swept along curves (metal accents) ---
    copper = MeshStandardMaterial(color=Color3(0.72, 0.45, 0.30),
                                  roughness=0.32, metalness=0.9, side=:double)
    brass = MeshStandardMaterial(color=Color3(0.83, 0.68, 0.28),
                                 roughness=0.30, metalness=0.85, side=:double)

    # Tubular segments (path samples) -> 160 and tube radial_segments -> 16 so the
    # round cross-section and the swept path both read as smooth metal pipes.
    _add_floor_tube!(turntable, _helix_coil_path(samples=160), "copper_coil", copper;
                     radius=0.06, radial_segments=16, x=1.5, z=-1.7)
    _add_floor_tube!(turntable, _trefoil_path(samples=160), "brass_knot", brass;
                     radius=0.055, radial_segments=16, x=0.55, z=0.7)

    # Slow turntable rotation about the vertical axis (one turn every 16 s).
    clip = AnimationClip("vessel_turntable_spin", 16.0, AbstractKeyframeTrack[
        KeyframeTrack(turntable, :rotation, [0.0, 16.0],
                      [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 2pi, 0.0)]),
    ]; loop=:repeat)

    return WebGLExportCase(
        "curves",
        "Turned Vessels",
        "Lathe-revolved ceramic vases and TubeGeometry metal pipes swept along curves on a slow turntable.",
        scene;
        target=Vec3(0.0, 0.85, 0.0),
        radius=9.2,
        height=4.6,
        fov=pi / 4.3,
        tone_mapping=:aces,
        tone_exposure=1.05,
        animations=[clip],
    )
end

# --- Unchanged private helpers that build_curves_case depends on (already present
#     in example_gallery.jl above this function; shown here for completeness, do
#     NOT paste a second copy). ---
#
# function _vessel_profile(rys)
#     return Vec2{Float64}[Vec2(Float64(r), Float64(y)) for (r, y) in rys]
# end
#
# function _add_floor_tube!(parent, path::Vector{<:Vec3}, name, material;
#                           radius, radial_segments, x, z, lift_extra=0.04)
#     geo = TubeGeometry(path; radius=radius, radial_segments=radial_segments)
#     geo.n_vertices > 0 || error("TubeGeometry produced no vertices for $name")
#     min_y = minimum(p.y for p in path) - radius
#     mesh = Mesh(geo, material; name=name, cast_shadow=true, receive_shadow=true)
#     mesh.position = Vec3(x, -min_y + lift_extra, z)
#     add!(parent, mesh)
#     return mesh
# end
#
# function _helix_coil_path(; samples=132, turns=4, coil_radius=0.5, height=1.7)
#     pts = Vec3{Float64}[]
#     for i in 0:samples
#         t = 2pi * turns * i / samples
#         y = height * i / samples
#         push!(pts, Vec3(coil_radius * cos(t), y, coil_radius * sin(t)))
#     end
#     return pts
# end
#
# function _trefoil_path(; samples=150, scale=0.42)
#     pts = Vec3{Float64}[]
#     for i in 0:samples
#         t = 2pi * i / samples
#         x = sin(t) + 2sin(2t)
#         y = cos(t) - 2cos(2t)
#         z = -sin(3t)
#         push!(pts, Vec3(scale * x, scale * z, scale * y))
#     end
#     return pts
# end

function build_lines_case()
    scene = Scene(background=Color3(0.015, 0.012, 0.028),
                  fog=FogExp2(color=Color3(0.015, 0.012, 0.028), density=0.030))

    # Moody synthwave lighting. The wire shapes use unlit LineBasic/LineDashed
    # materials that glow on their own; the point lights only wash the floor.
    add!(scene, AmbientLight(color=Color3(0.16, 0.18, 0.30), intensity=0.60))
    add!(scene, PointLight(color=Color3(0.24, 0.82, 1.0), intensity=9.0,
                           distance=16.0, position=Vec3(3.2, 4.2, 3.0)))
    add!(scene, PointLight(color=Color3(1.0, 0.28, 0.72), intensity=7.0,
                           distance=16.0, position=Vec3(-3.4, 2.6, -2.6)))

    add!(scene, make_floor(width=18.0, depth=18.0, color=Color3(0.06, 0.07, 0.12)))

    cyan = Color3(0.16, 0.94, 1.0)
    magenta = Color3(1.0, 0.24, 0.78)

    wire = Group(name="neon_wire")
    wire.position = Vec3(0.0, 1.7, 0.0)
    add!(scene, wire)

    # --- Wire icosahedron: unique edges via edges_geometry, drawn as
    #     LineSegments with a per-vertex cyan -> magenta vertical gradient. ---
    ico_radius = 1.45
    ico_edges = edges_geometry(IcosahedronGeometry(radius=ico_radius, detail=0))
    ico_colors = Float64[]
    for i in 1:ico_edges.n_vertices
        v = get_vertex(ico_edges, i)
        t = clamp(0.5 + 0.5 * v.y / ico_radius, 0.0, 1.0)
        append!(ico_colors, (cyan.r + (magenta.r - cyan.r) * t,
                             cyan.g + (magenta.g - cyan.g) * t,
                             cyan.b + (magenta.b - cyan.b) * t))
    end
    set_attribute!(ico_edges, :color, ico_colors, 3)
    ico = LineSegments(ico_edges, LineBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                       name="wire_icosahedron")
    add!(wire, ico)

    # --- Dashed neon helix: a LineObject line strip. Dashed rendering reads the
    #     :lineDistance attribute, so compute_line_distances!(mode=:line_strip). ---
    helix_pos = Float64[]
    turns = 4
    n = 320
    for i in 0:n
        t = i / n
        a = 2pi * turns * t
        r = 2.35
        y = -1.55 + 3.1 * t
        append!(helix_pos, (r * cos(a), y, r * sin(a)))
    end
    helix_geo = BufferGeometry(helix_pos, Float64[], Float64[], Int[],
                               length(helix_pos) ÷ 3, 0)
    compute_line_distances!(helix_geo; mode=:line_strip)
    helix = LineObject(helix_geo,
                       LineDashedMaterial(color=Color3(0.40, 1.0, 0.86),
                                          dash_size=0.26, gap_size=0.14);
                       name="neon_helix_dashed")
    add!(wire, helix)

    # --- Floor rings: LineLoop with per-vertex rainbow colors. ---
    for band in 1:3
        ring_pos = Float64[]
        ring_col = Float64[]
        radius = 2.4 + 1.35 * band
        segs = 128
        for i in 0:(segs - 1)
            a = 2pi * i / segs
            append!(ring_pos, (radius * cos(a), 0.03, radius * sin(a)))
            hue = i / segs
            append!(ring_col, (0.5 + 0.5 * cos(2pi * hue),
                               0.5 + 0.5 * cos(2pi * (hue + 0.33)),
                               0.5 + 0.5 * cos(2pi * (hue + 0.66))))
        end
        geo = BufferGeometry(ring_pos, Float64[], Float64[], Int[], segs, 0)
        set_attribute!(geo, :color, ring_col, 3)
        add!(scene, LineLoop(geo, LineBasicMaterial(color=Color3(1.0, 1.0, 1.0));
                             name="neon_ring_$band"))
    end

    # Animation: slow group spin + independent icosahedron tumble + helix bob.
    tracks = AbstractKeyframeTrack[
        KeyframeTrack(wire, :rotation, [0.0, 6.0],
            [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 2pi, 0.0)]),
        KeyframeTrack(ico, :rotation, [0.0, 6.0],
            [Vec3(0.0, 0.0, 0.0), Vec3(2pi, -2pi, 0.0)]),
        KeyframeTrack(helix, :position, [0.0, 3.0, 6.0],
            [Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.35, 0.0), Vec3(0.0, 0.0, 0.0)];
            interpolation=:cubic),
    ]
    clip = AnimationClip("neon_wire_spin", 6.0, tracks; loop=:repeat)

    return WebGLExportCase(
        "lines",
        "Neon Wireframe",
        "Glowing edge, loop, and dashed line primitives with per-vertex colors.",
        scene;
        target=Vec3(0.0, 1.4, 0.0),
        radius=9.6,
        height=4.6,
        fov=pi / 4.3,
        tone_mapping=:linear,
        output_color_space=:srgb,
        animations=[clip],
    )
end

function build_texture_case()
    # --- procedural textures generated on the Julia side and mapped via material `map=` ---
    # Hand-authored wooden-crate bitmap exported as a CanvasTexture (RGBA), mirroring
    # the crate_texture pattern from webgl_geometry_cube.jl. Kept low-res: texture data
    # serializes as one RGBA byte per pixel, so resolution dominates the export size.
    function wood_crate_texture(; n::Int=40)
        data = zeros(Float64, n, n, 4)
        for y in 1:n, x in 1:n
            u = (x - 1) / (n - 1)
            v = (y - 1) / (n - 1)
            plank = mod(floor(Int, 4v), 2) == 0
            grain = 0.5 + 0.5 * sin(38u + 2.5 * sin(6pi * v))
            frame = u < 0.06 || u > 0.94 || v < 0.06 || v > 0.94
            brace = abs(u - v) < 0.05 || abs(u + v - 1.0) < 0.05
            base = plank ? Color3(0.62, 0.40, 0.20) : Color3(0.52, 0.32, 0.15)
            shade = 0.80 + 0.20 * grain
            col = (frame || brace) ? Color3(0.28, 0.18, 0.09) :
                  Color3(base.r * shade, base.g * shade, base.b * shade)
            data[y, x, 1] = col.r
            data[y, x, 2] = col.g
            data[y, x, 3] = col.b
            data[y, x, 4] = 1.0
        end
        CanvasTexture(data; filter=:linear, colorspace=:srgb, wrap_s=:repeat, wrap_t=:repeat)
    end

    # UV reference texture for the floating globe: a repeating checker with an equator
    # band so the sphere's UV parameterization is visible as it rotates.
    function uv_globe_texture(; n::Int=44)
        data = zeros(Float64, n, n, 4)
        cell = max(1, n ÷ 8)               # 8 checker cells across the tile (as at n=128)
        for y in 1:n, x in 1:n
            v = (y - 1) / (n - 1)
            checker = (fld(x - 1, cell) + fld(y - 1, cell)) % 2 == 0
            equator = abs(v - 0.5) < 0.05  # widened so the band stays visible at low res
            col = equator ? Color3(0.98, 0.82, 0.22) :
                  (checker ? Color3(0.18, 0.60, 0.92) : Color3(0.90, 0.94, 0.98))
            data[y, x, 1] = col.r
            data[y, x, 2] = col.g
            data[y, x, 3] = col.b
            data[y, x, 4] = 1.0
        end
        Texture(data; filter=:linear, colorspace=:srgb, wrap_s=:repeat, wrap_t=:repeat,
                repeat=Vec2(2.0, 1.0))
    end

    scene = Scene(background=Color3(0.028, 0.032, 0.044),
                  fog=FogExp2(color=Color3(0.028, 0.032, 0.044), density=0.020))
    add_studio_lights!(scene)
    add!(scene, make_floor(width=18.0, depth=18.0, color=Color3(0.24, 0.26, 0.30)))

    # Three textured crates: a procedural checker, a procedural grid, and a canvas
    # wood bitmap, each mapped through MeshStandardMaterial.map so it responds to light.
    # Textures use :repeat wrap, so a small tile is upscaled/repeated on the crate faces
    # without visible loss of the pattern.
    checker_tex = checker_texture(n=4, cell=4, a=Color3(0.95, 0.36, 0.26),
                                  b=Color3(0.96, 0.92, 0.84))
    grid_tex = grid_texture(size_px=40, cell=10, line=Color3(0.08, 0.11, 0.16),
                            bg=Color3(0.32, 0.74, 0.86), thickness=1)
    wood_tex = wood_crate_texture()

    crate_specs = [
        ("crate_checker", checker_tex, -2.9, 0.60, 0.04, 1.0),
        ("crate_grid",    grid_tex,     0.0, 0.55, 0.10, -1.0),
        ("crate_wood",    wood_tex,     2.9, 0.72, 0.00, 1.0),
    ]

    tracks = AbstractKeyframeTrack[]
    for (name, tex, x, rough, metal, dir) in crate_specs
        crate = Mesh(BoxGeometry(width=1.7, height=1.7, depth=1.7),
                     MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0), map=tex,
                                          roughness=rough, metalness=metal);
                     name=name, cast_shadow=true, receive_shadow=true)
        crate.position = Vec3(x, 0.88, 0.0)
        add!(scene, crate)
        push!(tracks, KeyframeTrack(crate, :rotation, [0.0, 8.0],
                                    [Vec3(0.0, 0.0, 0.0), Vec3(0.0, dir * 2pi, 0.0)]))
    end

    # A textured globe floating above the crates showing UV mapping on a sphere.
    # Raised tessellation (48x28) so the silhouette reads as a smooth sphere instead
    # of a faceted polyhedron; the UV parameterization is unchanged so the texture
    # still maps correctly.
    globe = Mesh(SphereGeometry(radius=1.0, width_segments=40, height_segments=24),
                 MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0), map=uv_globe_texture(),
                                      roughness=0.42, metalness=0.08);
                 name="uv_globe", cast_shadow=true, receive_shadow=true)
    globe.position = Vec3(0.0, 3.05, 0.0)
    add!(scene, globe)
    push!(tracks, KeyframeTrack(globe, :rotation, [0.0, 8.0],
                                [Vec3(0.35, 0.0, 0.0), Vec3(0.35, 2pi, 0.0)]))
    push!(tracks, KeyframeTrack(globe, :position, [0.0, 4.0, 8.0],
                                [Vec3(0.0, 3.05, 0.0), Vec3(0.0, 3.42, 0.0), Vec3(0.0, 3.05, 0.0)];
                                interpolation=:cubic))

    clip = AnimationClip("crate_turntable", 8.0, tracks; loop=:repeat)
    return WebGLExportCase(
        "texture",
        "Textured Crates",
        "Procedural checker, grid, and canvas bitmaps mapped onto spinning crates plus a UV globe.",
        scene;
        target=Vec3(0.0, 1.25, 0.0),
        radius=8.2,
        height=4.4,
        fov=pi / 4.3,
        tone_mapping=:aces,
        tone_exposure=1.05,
        animations=[clip],
    )
end

function main(; output_path=joinpath(OUT, "example_gallery.html"))
    mkpath(dirname(output_path))
    cases = [
        build_robot_case(),
        build_materials_case(),
        build_shadows_case(),
        build_spotlights_case(),
        build_clipping_case(),
        build_csg_case(),
        build_extrude_case(),
        build_text_case(),
        build_terrain_case(),
        build_curves_case(),
        build_instancing_case(),
        build_lines_case(),
        build_texture_case(),
        build_particles_case(),
    ]
    html = save_webgl_html(output_path, cases; title="Diff3D.jl Example Gallery")
    println("EXAMPLE_GALLERY_OK $html")
    return html
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
