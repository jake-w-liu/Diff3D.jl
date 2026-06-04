# Three.jl example gallery.
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

using Three

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
        SphereGeometry(radius=radius, width_segments=28, height_segments=16),
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
    flower_geo = IcosahedronGeometry(radius=0.22, detail=1)
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

function main(; output_path=joinpath(OUT, "example_gallery.html"))
    mkpath(dirname(output_path))
    cases = [
        build_robot_case(),
        build_materials_case(),
        build_instancing_case(),
        build_particles_case(),
    ]
    html = save_webgl_html(output_path, cases; title="Three.jl Example Gallery")
    println("EXAMPLE_GALLERY_OK $html")
    return html
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
