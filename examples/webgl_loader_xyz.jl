# Standalone Diff3D.jl port for:
#   https://threejs.org/examples/#webgl_loader_xyz

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function xyz_text(; n::Int=420)
    io = IOBuffer()
    println(io, "# Diff3D.jl deterministic XYZRGB helix")
    denom = max(n - 1, 1)
    for i in 0:(n - 1)
        t = i / denom
        a = 10pi * t
        r = 1.0 + 0.42sin(6pi * t)
        x = r * cos(a)
        y = 3.2 * (t - 0.5)
        z = r * sin(a)
        red = round(Int, 255 * (0.5 + 0.5cos(a)))
        green = round(Int, 255 * (0.35 + 0.65t))
        blue = round(Int, 255 * (0.5 + 0.5sin(a + 1.2)))
        println(io, "$x $y $z $red $green $blue")
    end
    return String(take!(io))
end

function loaded_xyz_geometry()
    mktempdir() do dir
        path = joinpath(dir, "diff3d_loader_xyz.xyz")
        write(path, xyz_text())
        return load_xyz(path)
    end
end

function build_case()
    scene = Scene(background=Color3(0.008, 0.010, 0.016),
                  fog=FogExp2(color=Color3(0.008, 0.010, 0.016), density=0.055))
    add!(scene, AmbientLight(color=Color3(0.36, 0.39, 0.46), intensity=0.62))
    add!(scene, HemisphereLight(color=Color3(0.48, 0.70, 0.95),
                                ground_color=Color3(0.10, 0.08, 0.09),
                                intensity=0.42))
    add!(scene, PointLight(color=Color3(0.26, 0.58, 1.0), intensity=5.0,
                           distance=7.5, position=Vec3(2.6, 2.2, 2.0)))
    add!(scene, GridHelper(5.5, 11; color=Color3(0.10, 0.14, 0.18)))

    group = Group(name="xyz_loader_group")
    add!(scene, group)

    geo = loaded_xyz_geometry()
    add!(group, PointsObject(geo, PointsMaterial(color=Color3(1.0, 1.0, 1.0), size=5.5);
                             name="xyzrgb_helix_points"))

    clip = AnimationClip("xyz_loader_spin", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, pi, 0.0),
                                 quat_from_euler(0.0, 2pi, 0.0)])
    ]; loop=:repeat)

    WebGLExportCase("loader-xyz", "XYZ Loader",
                    "XYZRGB point cloud loaded through Diff3D.jl load_xyz and exported as colored WebGL points.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=6.6, height=1.9,
                    fov=pi / 4.4, animations=[clip],
                    tone_mapping=:aces, tone_exposure=1.05,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_loader_xyz.html"), [build_case()])
    println("WEBGL_LOADER_XYZ_OK $html")
end

main()
