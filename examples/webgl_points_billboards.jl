# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_points_billboards

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function billboard_disc_texture(; n::Int=48)
    data = zeros(Float64, n, n, 4)
    mid = (n + 1) / 2
    radius = (n - 2) / 2
    for y in 1:n, x in 1:n
        dx = (x - mid) / radius
        dy = (y - mid) / radius
        r2 = dx * dx + dy * dy
        alpha = clamp(1.0 - r2, 0.0, 1.0)^1.7
        core = clamp(1.0 - 2.6r2, 0.0, 1.0)
        data[y, x, 1] = 0.72 + 0.28core
        data[y, x, 2] = 0.82 + 0.18core
        data[y, x, 3] = 1.0
        data[y, x, 4] = alpha
    end
    Texture(data; filter=:linear, min_filter=:linear_mipmap_linear,
            mag_filter=:linear, wrap_s=:clamp, wrap_t=:clamp,
            colorspace=:srgb)
end

function billboard_geometry(; n::Int=2200)
    positions = Float64[]
    colors = Float64[]
    sizehint!(positions, 3n)
    sizehint!(colors, 3n)
    golden = pi * (3.0 - sqrt(5.0))
    for i in 0:(n - 1)
        t = i / max(n - 1, 1)
        y = 5.2 * (t - 0.5)
        ring = sqrt(max(0.0, 1.0 - (2t - 1)^2))
        a = i * golden
        radius = 1.15 + 2.9ring + 0.25sin(19a)
        x = radius * cos(a)
        z = radius * sin(a)
        hue = 0.5 + 0.5sin(a + 5t)
        append!(positions, (x, y, z))
        append!(colors, (0.42 + 0.48hue, 0.58 + 0.32t, 0.90 + 0.10ring))
    end
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], n, 0)
    set_attribute!(geo, :color, colors, 3)
    return geo
end

function build_case()
    scene = Scene(background=Color3(0.006, 0.008, 0.014),
                  fog=FogExp2(color=Color3(0.006, 0.008, 0.014), density=0.045))
    add!(scene, AmbientLight(color=Color3(0.22, 0.26, 0.34), intensity=0.85))
    add!(scene, GridHelper(8.0, 16; color=Color3(0.08, 0.11, 0.16)))

    group = Group(name="points_billboards_group")
    add!(scene, group)
    add!(group, PointsObject(
        billboard_geometry(),
        PointsMaterial(color=Color3(1.0, 1.0, 1.0),
                       size=12.0,
                       transparent=true,
                       map=billboard_disc_texture(),
                       alpha_test=0.04,
                       size_attenuation=true);
        name="points_billboards_cloud"))

    clip = AnimationClip("points_billboards_orbit", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("points-billboards", "Points Billboards",
                    "Generated textured point billboards exported from Diff3D.jl PointsMaterial.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=9.0, height=2.2,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.1,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_points_billboards.html"), [build_case()])
    println("WEBGL_POINTS_BILLBOARDS_OK $html")
end

main()
