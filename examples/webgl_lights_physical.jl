# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_lights_physical

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

const PHYSICAL_BULB_LUMENS = 400.0
const PHYSICAL_HEMI_IRRADIANCE = 0.0001
const PHYSICAL_CAMERA_POSITION = Vec3(-4.0, 2.0, 4.0)

lumens_to_point_intensity(lumens::Real) = Float64(lumens) / (4pi)

function physical_hardwood_texture(kind::Symbol; width::Int=96, height::Int=96)
    data = Array{Float64}(undef, height, width, 3)
    for y in 1:height, x in 1:width
        u = (x - 0.5) / width
        v = (y - 0.5) / height
        plank = mod(floor(Int, 10u), 2)
        grain = 0.5 + 0.5 * sin(42v + 5sin(12u))
        seam = abs(mod(10u, 1.0) - 0.5) > 0.47 ? 0.52 : 1.0
        if kind === :diffuse
            base = plank == 0 ? Color3(0.58, 0.34, 0.16) : Color3(0.44, 0.25, 0.11)
            c = base * (0.72 + 0.28 * grain) * seam
        elseif kind === :roughness
            r = clamp(0.58 + 0.25 * grain + 0.08 * plank, 0.0, 1.0)
            c = Color3(r, r, r)
        elseif kind === :normal
            gx = 0.5 + 0.10 * sin(2pi * 10u)
            gy = 0.5 + 0.16 * cos(42v + 5sin(12u))
            c = Color3(clamp(gx, 0.0, 1.0), clamp(gy, 0.0, 1.0), 1.0)
        else
            throw(ArgumentError("unsupported hardwood texture kind: $kind"))
        end
        data[y, x, 1] = c.r
        data[y, x, 2] = c.g
        data[y, x, 3] = c.b
    end
    tex = Texture(data; repeat=Vec2(10.0, 24.0), wrap_s=:repeat, wrap_t=:repeat,
                  filter=:linear, min_filter=:linear_mipmap_linear,
                  colorspace=kind === :diffuse ? :srgb : :linear,
                  max_anisotropy=4)
    generate_mipmaps!(tex)
    return tex
end

function physical_brick_texture(kind::Symbol; size::Int=96)
    data = Array{Float64}(undef, size, size, 3)
    for y in 1:size, x in 1:size
        u = (x - 0.5) / size
        v = (y - 0.5) / size
        row = floor(Int, 5v)
        shifted_u = mod(u + 0.5 * isodd(row), 1.0)
        mortar = abs(mod(5v, 1.0) - 0.5) > 0.43 ||
                 abs(mod(4shifted_u, 1.0) - 0.5) > 0.45
        fleck = 0.5 + 0.5 * sin(47u + 31v)
        if kind === :diffuse
            c = mortar ? Color3(0.55, 0.52, 0.48) :
                Color3(0.62 + 0.12 * fleck, 0.26 + 0.07 * fleck, 0.13 + 0.04 * fleck)
        elseif kind === :normal
            z = mortar ? 0.86 : 1.0
            c = Color3(0.5 + 0.08 * sin(4pi * shifted_u),
                       0.5 + 0.08 * cos(5pi * v), z)
        else
            throw(ArgumentError("unsupported brick texture kind: $kind"))
        end
        data[y, x, 1] = clamp(c.r, 0.0, 1.0)
        data[y, x, 2] = clamp(c.g, 0.0, 1.0)
        data[y, x, 3] = clamp(c.b, 0.0, 1.0)
    end
    tex = Texture(data; wrap_s=:repeat, wrap_t=:repeat, filter=:linear,
                  min_filter=:linear_mipmap_linear,
                  colorspace=kind === :diffuse ? :srgb : :linear,
                  max_anisotropy=4)
    generate_mipmaps!(tex)
    return tex
end

function physical_earth_texture(kind::Symbol; width::Int=128, height::Int=64)
    data = Array{Float64}(undef, height, width, 3)
    for y in 1:height, x in 1:width
        lon = 2pi * (x - 0.5) / width
        lat = pi * ((y - 0.5) / height - 0.5)
        land = sin(2.2lon + 0.7sin(3lat)) + 0.65cos(3.6lon - 2lat) +
               0.35sin(7lon + 5lat)
        equator = exp(-(lat / 0.45)^2)
        if kind === :diffuse
            ocean = Color3(0.05, 0.19 + 0.10 * equator, 0.42 + 0.18 * equator)
            continent = Color3(0.28 + 0.20 * equator, 0.42, 0.18)
            cloud = max(sin(9lon + 4lat), 0.0)^5 * 0.16
            c = land > 0.15 ? continent : ocean
            c = c + Color3(cloud, cloud, cloud)
        elseif kind === :metalness
            ocean_mask = land > 0.15 ? 0.05 : 0.86
            c = Color3(ocean_mask, ocean_mask, ocean_mask)
        else
            throw(ArgumentError("unsupported earth texture kind: $kind"))
        end
        data[y, x, 1] = clamp(c.r, 0.0, 1.0)
        data[y, x, 2] = clamp(c.g, 0.0, 1.0)
        data[y, x, 3] = clamp(c.b, 0.0, 1.0)
    end
    tex = Texture(data; wrap_s=:repeat, wrap_t=:clamp, filter=:linear,
                  min_filter=:linear_mipmap_linear,
                  colorspace=kind === :diffuse ? :srgb : :linear,
                  max_anisotropy=4)
    generate_mipmaps!(tex)
    return tex
end

function build_lights_physical_case()
    scene = Scene(background=Color3(0.0, 0.0, 0.0))

    bulb_light = PointLight(color=Color3(1.0, 0.933, 0.533),
                            intensity=lumens_to_point_intensity(PHYSICAL_BULB_LUMENS),
                            distance=100.0, decay=2.0,
                            position=Vec3(0.0, 2.0, 0.0),
                            cast_shadow=true, name="physical_bulb_light")
    bulb_mesh = Mesh(SphereGeometry(radius=0.02, width_segments=16, height_segments=8),
                     MeshStandardMaterial(emissive=Color3(1.0, 1.0, 0.933),
                                          emissive_intensity=120.0,
                                          color=Color3(0.0, 0.0, 0.0));
                     name="physical_bulb_globe")
    add!(bulb_light, bulb_mesh)
    add!(scene, bulb_light)

    add!(scene, HemisphereLight(color=Color3(0.867, 0.933, 1.0),
                                ground_color=Color3(0.059, 0.055, 0.051),
                                intensity=PHYSICAL_HEMI_IRRADIANCE,
                                name="physical_hemi_light"))

    floor = Mesh(PlaneGeometry(width=20.0, height=20.0),
                 MeshStandardMaterial(roughness=0.8, color=Color3(1.0, 1.0, 1.0),
                                      metalness=0.2,
                                      map=physical_hardwood_texture(:diffuse),
                                      normal_map=physical_hardwood_texture(:normal),
                                      normal_scale=0.35,
                                      roughness_map=physical_hardwood_texture(:roughness));
                 name="physical_hardwood_floor", receive_shadow=true)
    floor.rotation = Euler(-pi / 2, 0.0, 0.0)
    add!(scene, floor)

    ball = Mesh(SphereGeometry(radius=0.25, width_segments=32, height_segments=32),
                MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0),
                                     roughness=0.5, metalness=1.0,
                                     map=physical_earth_texture(:diffuse),
                                     metalness_map=physical_earth_texture(:metalness));
                name="physical_earth_ball", cast_shadow=true, receive_shadow=true)
    ball.position = Vec3(1.0, 0.25, 1.0)
    ball.rotation = Euler(0.0, pi, 0.0)
    add!(scene, ball)

    cube_material = MeshStandardMaterial(roughness=0.7, color=Color3(1.0, 1.0, 1.0),
                                         metalness=0.2,
                                         map=physical_brick_texture(:diffuse),
                                         normal_map=physical_brick_texture(:normal),
                                         normal_scale=0.4)
    for (idx, pos) in enumerate((Vec3(-0.5, 0.25, -1.0),
                                 Vec3(0.0, 0.25, -5.0),
                                 Vec3(7.0, 0.25, 0.0)))
        cube = Mesh(BoxGeometry(width=0.5, height=0.5, depth=0.5),
                    cube_material; name="physical_brick_cube_$idx",
                    cast_shadow=true, receive_shadow=true)
        cube.position = pos
        add!(scene, cube)
    end

    clip = AnimationClip("physical_bulb_motion", AbstractKeyframeTrack[
        NumberKeyframeTrack(bulb_light, "position.y",
                            [0.0, 1.5, 3.0, 4.5, 6.0],
                            [2.0, 1.25, 0.5, 1.25, 2.0])
    ]; loop=:repeat)

    camera = PerspectiveCamera(fov=50pi / 180, aspect=16 / 9, near=0.1, far=100.0)
    camera.position = PHYSICAL_CAMERA_POSITION
    camera.target = Vec3(0.0, 0.35, 0.0)

    WebGLExportCase("lights-physical", "Lights Physical",
                    "Physically scaled bulb and decay-2 point light over textured hardwood, brick, and earth materials.",
                    scene; target=Vec3(0.0, 0.35, 0.0), radius=5.7, height=1.2,
                    fov=50pi / 180, camera=camera, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=0.68^5,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_lights_physical.html"),
                           [build_lights_physical_case()])
    println("WEBGL_LIGHTS_PHYSICAL_OK $html")
end

main()
