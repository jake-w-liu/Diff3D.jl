# Standalone Diff3D.jl partial port for:
#   https://threejs.org/examples/#webgl_loader_svg

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
isdir(OUT) || mkpath(OUT)

function svg_loader_asset()
    return """
<svg xmlns="http://www.w3.org/2000/svg" width="180" height="140" viewBox="0 0 180 140">
  <defs>
    <style>
      .panel { fill: #0f74bd; fill-opacity: 0.92; }
      .accent { fill: #f7c948; fill-opacity: 0.86; }
      .glow { fill: #8bd3ff; fill-opacity: 0.32; }
      .outline { fill: none; stroke: #102a43; stroke-width: 5; stroke-linejoin: round; stroke-linecap: round; }
      .dash { fill: none; stroke: #ffffff; stroke-width: 4; stroke-dasharray: 10 6; stroke-linecap: round; stroke-opacity: 0.82; }
    </style>
    <clipPath id="diagonal-clip">
      <polygon points="18,20 162,20 122,120 18,120"/>
    </clipPath>
    <g id="bolt-mark">
      <polygon class="accent" points="88,22 58,78 82,78 70,118 126,56 98,56"/>
      <path class="outline" d="M88 22 L58 78 L82 78 L70 118 L126 56 L98 56 Z"/>
    </g>
  </defs>
  <rect class="panel" x="12" y="18" width="156" height="104" rx="14" ry="14"/>
  <circle class="glow" cx="62" cy="54" r="32"/>
  <rect class="accent" clip-path="url(#diagonal-clip)" x="104" y="22" width="54" height="96"/>
  <use href="#bolt-mark" x="0" y="0"/>
  <polyline class="dash" points="24,106 50,95 78,103 110,90 148,102"/>
</svg>
"""
end

function write_svg_asset!(dir::String)
    path = joinpath(dir, "diff3d_loader_svg.svg")
    write(path, svg_loader_asset())
    return path
end

function loaded_svg_objects()
    mktempdir() do dir
        path = write_svg_asset!(dir)
        document = SVGLoader(path; curve_segments=6, circle_segments=24)
        fill_meshes = svg_meshes(document)
        stroke_meshes = svg_stroke_meshes(document)
        isempty(fill_meshes) && error("SVGLoader produced no fill meshes")
        isempty(stroke_meshes) && error("SVGLoader produced no stroke meshes")
        return fill_meshes, stroke_meshes
    end
end

function add_loaded_svg!(group::Group)
    fill_meshes, stroke_meshes = loaded_svg_objects()
    for (i, mesh) in enumerate(fill_meshes)
        mesh.name = "svg_loader_fill_$i"
        mesh.position = Vec3(0.0, 0.0, 0.0)
        add!(group, mesh)
    end
    for (i, mesh) in enumerate(stroke_meshes)
        mesh.name = "svg_loader_stroke_$i"
        mesh.position = Vec3(0.0, 0.0, 0.01 + 0.002i)
        add!(group, mesh)
    end
    return length(fill_meshes), length(stroke_meshes)
end

function build_case()
    scene = Scene(background=Color3(0.69, 0.69, 0.69),
                  fog=Fog(color=Color3(0.69, 0.69, 0.69), near=6.0, far=14.0))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.75))
    add!(scene, DirectionalLight(color=Color3(1.0, 1.0, 1.0), intensity=0.85,
                                 position=Vec3(0.4, 0.6, 2.0)))

    grid = GridHelper(4.4, 10; color=Color3(0.55, 0.55, 0.55))
    grid.rotation = Euler(pi / 2, 0.0, 0.0)
    add!(scene, grid)

    group = Group(name="svg_loader_group")
    group.scale = Vec3(0.028, -0.028, 0.028)
    group.position = Vec3(-2.55, 1.95, 0.0)
    add!(scene, group)
    fill_count, stroke_count = add_loaded_svg!(group)

    clip = AnimationClip("svg_loader_turntable", AbstractKeyframeTrack[
        QuaternionKeyframeTrack(group, :rotation, [0.0, 4.0, 8.0],
                                [Quaternion(),
                                 quat_from_euler(0.0, 0.0, 0.08),
                                 Quaternion()])
    ]; loop=:repeat)

    WebGLExportCase("loader-svg", "SVG Loader",
                    "Generated SVG asset loaded through Diff3D.jl SVGLoader with $fill_count fill mesh groups and $stroke_count stroke mesh groups.",
                    scene; target=Vec3(0.0, 0.0, 0.0), radius=6.2, height=0.35,
                    fov=pi / 4.2, animations=[clip],
                    tone_mapping=:reinhard, tone_exposure=1.0,
                    output_color_space=:srgb)
end

function main()
    html = save_webgl_html(joinpath(OUT, "webgl_loader_svg.html"), [build_case()])
    println("WEBGL_LOADER_SVG_OK $html")
end

main()
