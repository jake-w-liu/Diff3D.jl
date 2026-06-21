# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_shadowmap_viewer

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const SHADOWMAP_VIEWER_DURATION = 8pi
const SHADOWMAP_VIEWER_KEYFRAME_COUNT = 65
const SHADOWMAP_VIEWER_TARGET = Vec3(0.0, 2.0, 0.0)
const SHADOWMAP_VIEWER_CAMERA_POSITION = Vec3(0.0, 15.0, 35.0)

function shadowmap_viewer_key_times()
    collect(range(0.0, stop=SHADOWMAP_VIEWER_DURATION,
                  length=SHADOWMAP_VIEWER_KEYFRAME_COUNT))
end

function shadowmap_viewer_texture(kind::Symbol; size::Int=64)
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = (y - 0.5) / size
        if kind === :directional
            stripe = 0.5 + 0.5sin(34u + 11v)
            edge = max(abs(u - 0.5), abs(v - 0.5))
            shade = clamp(0.18 + 0.55stripe - 0.42edge, 0.0, 1.0)
        elseif kind === :spot
            dx = u - 0.55
            dy = v - 0.48
            radial = exp(-18.0 * (dx * dx + dy * dy))
            ring = 0.5 + 0.5cos(44.0 * sqrt(dx * dx + dy * dy))
            shade = clamp(0.08 + 0.72radial * (0.55 + 0.45ring), 0.0, 1.0)
        else
            throw(ArgumentError("unsupported shadow map viewer texture kind: $kind"))
        end
        data[y, x, 1] = shade
        data[y, x, 2] = shade
        data[y, x, 3] = shade
    end
    Texture(data; wrap_s=:clamp, wrap_t=:clamp, filter=:nearest,
            min_filter=:nearest, mag_filter=:nearest, colorspace=:linear)
end

function shadowmap_viewer_panel(name::String, texture::Texture, position::Vec3)
    panel = Mesh(PlaneGeometry(width=3.2, height=3.2),
                 MeshBasicMaterial(color=Color3(1.0, 1.0, 1.0), map=texture,
                                   side=:double);
                 name=name)
    panel.position = position
    return panel
end

function shadowmap_viewer_spot_shadow_camera(spot::SpotLight)
    cam = PerspectiveCamera(fov=2 * spot.angle, aspect=1.0, near=8.0, far=30.0,
                            name="shadowmap_viewer_spot_shadow_camera")
    cam.position = spot.position
    cam.target = spot.target
    return cam
end

function shadowmap_viewer_directional_shadow_camera(dir::DirectionalLight)
    cam = OrthographicCamera(left=-15.0, right=15.0, bottom=-15.0, top=15.0,
                             near=1.0, far=10.0,
                             name="shadowmap_viewer_directional_shadow_camera")
    cam.position = dir.position
    cam.target = dir.target
    return cam
end

function build_shadowmap_viewer_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    add!(scene, AmbientLight(color=Color3(0.251, 0.251, 0.251), intensity=3.0,
                             name="shadowmap_viewer_ambient"))

    spot = SpotLight(color=Color3(1.0, 1.0, 1.0), intensity=500.0,
                     angle=pi / 5, penumbra=0.3, decay=2.0,
                     position=Vec3(10.0, 10.0, 5.0),
                     target=Vec3(0.0, 0.0, 0.0), cast_shadow=true,
                     shadow_pcf_radius=0, name="Spot Light")
    add!(scene, spot)
    add!(scene, CameraHelper(shadowmap_viewer_spot_shadow_camera(spot);
                             color=Color3(1.0, 0.78, 0.22)))

    dir = DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=3.0,
                           position=Vec3(0.0, 10.0, 0.0), cast_shadow=true,
                           shadow_pcf_radius=0, name="Dir. Light")
    add!(scene, dir)
    add!(scene, CameraHelper(shadowmap_viewer_directional_shadow_camera(dir);
                             color=Color3(0.28, 0.62, 1.0)))

    object_material = MeshPhongMaterial(color=Color3(1.0, 0.0, 0.0),
                                        shininess=150.0,
                                        specular=Color3(0.133, 0.133, 0.133))

    torus = Mesh(TorusKnotGeometry(radius=25.0, tube=8.0,
                                   tubular_segments=75, radial_segments=20),
                 object_material; name="shadowmap_viewer_torus_knot",
                 cast_shadow=true, receive_shadow=true)
    torus.scale = Vec3(1 / 18, 1 / 18, 1 / 18)
    torus.position = Vec3(0.0, 3.0, 0.0)
    add!(scene, torus)

    cube = Mesh(BoxGeometry(width=3.0, height=3.0, depth=3.0),
                object_material; name="shadowmap_viewer_cube",
                cast_shadow=true, receive_shadow=true)
    cube.position = Vec3(8.0, 3.0, 8.0)
    add!(scene, cube)

    ground = Mesh(BoxGeometry(width=10.0, height=0.15, depth=10.0),
                  MeshPhongMaterial(color=Color3(0.627, 0.678, 0.686),
                                    shininess=150.0,
                                    specular=Color3(0.067, 0.067, 0.067));
                  name="shadowmap_viewer_ground", receive_shadow=true)
    ground.scale = Vec3(3.0, 3.0, 3.0)
    add!(scene, ground)

    add!(scene, shadowmap_viewer_panel("shadowmap_viewer_directional_panel",
                                       shadowmap_viewer_texture(:directional),
                                       Vec3(-5.0, 9.5, -7.0)))
    add!(scene, shadowmap_viewer_panel("shadowmap_viewer_spot_panel",
                                       shadowmap_viewer_texture(:spot),
                                       Vec3(-1.2, 9.5, -7.0)))

    times = shadowmap_viewer_key_times()
    clip = AnimationClip("shadowmap_viewer_motion", SHADOWMAP_VIEWER_DURATION,
                         AbstractKeyframeTrack[
        NumberKeyframeTrack(torus, "rotation.x", copy(times), [0.25t for t in times]),
        NumberKeyframeTrack(torus, "rotation.y", copy(times), [2.0t for t in times]),
        NumberKeyframeTrack(torus, "rotation.z", copy(times), [t for t in times]),
        NumberKeyframeTrack(cube, "rotation.x", copy(times), [0.25t for t in times]),
        NumberKeyframeTrack(cube, "rotation.y", copy(times), [2.0t for t in times]),
        NumberKeyframeTrack(cube, "rotation.z", copy(times), [t for t in times]),
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=45pi / 180, aspect=16 / 9, near=1.0, far=1000.0)
    camera.position = SHADOWMAP_VIEWER_CAMERA_POSITION
    camera.target = SHADOWMAP_VIEWER_TARGET

    WebGLExportCase("shadowmap-viewer", "Shadowmap Viewer",
                    "ShadowMapViewer scene port with shadow camera helpers and generated viewer panels.",
                    scene; camera=camera, target=SHADOWMAP_VIEWER_TARGET,
                    radius=38.0, height=7.0, fov=45pi / 180,
                    animations=[clip], output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_shadowmap_viewer.html"),
                           [build_shadowmap_viewer_case()])
    println("WEBGL_SHADOWMAP_VIEWER_OK $html")
end

main()
