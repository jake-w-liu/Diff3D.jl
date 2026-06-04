# Offline interactive showcase.
#
# This pre-renders orbit frames with Diff3D.jl, then writes an HTML viewer where
# each case is clickable and horizontal mouse/touch drag changes the camera angle.
# It is not WebGL; every frame is rendered by the Julia implementation.
#
# Run:
#   julia --project=. examples/interactive_showcase.jl
#
# Open:
#   examples/output/interactive_showcase.html

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using Diff3D

const OUT = joinpath(@__DIR__, "output")
const FRAME_DIR = joinpath(OUT, "interactive_frames")
isdir(FRAME_DIR) || mkpath(FRAME_DIR)

const W = 560
const H = 360
const NFRAMES = 12

struct OrbitCase
    id::String
    title::String
    subtitle::String
    scene::Scene
    target::Vec3{Float64}
    radius::Float64
    height::Float64
    fov::Float64
    shading::Symbol
    shadows::Bool
    post::Symbol
end

function orbit_camera(case::OrbitCase, frame::Int)
    θ = 2π * (frame - 1) / NFRAMES + 0.35
    cam = PerspectiveCamera(fov=case.fov, aspect=W/H, near=0.1, far=160.0)
    cam.position = case.target + Vec3(case.radius*cos(θ), case.height, case.radius*sin(θ))
    cam.target = case.target
    return cam
end

function render_case_frame(case::OrbitCase, frame::Int)
    rt = RenderTarget(W, H)
    render!(rt, case.scene, orbit_camera(case, frame);
            shading=case.shading, shadows=case.shadows, shadow_resolution=768)
    if case.post === :bloom_outline
        c = EffectComposer()
        add_pass!(c, bloom_pass(threshold=0.38, intensity=0.8, radius=4))
        add_pass!(c, outline_pass(rt.depth; threshold=0.04, color=Color3(0.015, 0.018, 0.024)))
        add_pass!(c, fxaa_pass())
        return compose(c, rt.color)
    elseif case.post === :particles
        c = EffectComposer()
        add_pass!(c, bloom_pass(threshold=0.26, intensity=0.75, radius=3))
        add_pass!(c, fxaa_pass())
        return compose(c, rt.color)
    elseif case.post === :dof
        finite_depths = sort([d for d in vec(rt.depth) if isfinite(d)])
        focus = finite_depths[max(1, length(finite_depths) ÷ 2)]
        c = EffectComposer()
        add_pass!(c, ssao_pass(rt.depth; radius=2.4, intensity=0.45, samples=8))
        add_pass!(c, outline_pass(rt.depth; threshold=0.04, color=Color3(0.02, 0.023, 0.03)))
        add_pass!(c, bokeh_pass(depth=rt.depth, focus_depth=focus, aperture=13.0))
        add_pass!(c, fxaa_pass())
        return compose(c, rt.color)
    end
    return rt.color
end

function build_instancing_case()
    scene = Scene(background=Color3(0.015, 0.018, 0.026))
    add!(scene, AmbientLight(color=Color3(0.7, 0.8, 1.0), intensity=0.24))
    key = DirectionalLight(color=Color3(1.0, 0.94, 0.82), intensity=1.05, position=Vec3(5.0, 9.0, 7.0))
    key.target = Vec3(0.0, 0.0, 0.0)
    add!(scene, key)

    ground = Mesh(PlaneGeometry(width=17.0, height=17.0, width_segments=20, height_segments=20),
                  MeshStandardMaterial(color=Color3(0.30, 0.32, 0.38), roughness=0.95))
    ground.rotation = Euler(-π/2, 0.0, 0.0)
    add!(scene, ground)

    inst = InstancedMesh(IcosahedronGeometry(radius=0.34),
                         MeshStandardMaterial(color=Color3(0.28, 0.78, 0.98), metalness=0.2, roughness=0.35),
                         9 * 9)
    k = 0
    for ix in 1:9, iz in 1:9
        x = (ix - 5) * 0.9
        z = (iz - 5) * 0.9
        y = 0.55 + 0.5 * sin(0.9*x + 0.7*z)
        k += 1
        set_instance_matrix!(inst, k,
            mat4_translation(x, y, z) *
            mat4_rotation_y(0.45*x) *
            mat4_rotation_x(0.25*z) *
            mat4_scaling(0.85, 0.85, 0.85))
    end
    add!(scene, inst)
    OrbitCase("instancing", "Instancing + Bloom", "Drag to orbit around instanced meshes with bloom and outlines.",
              scene, Vec3(0.0, 0.65, 0.0), 8.5, 4.8, π/4.0, :flat, false, :bloom_outline)
end

function positions_geometry(points)
    positions = Float64[]
    for p in points
        append!(positions, (p.x, p.y, p.z))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], length(points), 0)
end

function segment_geometry(segments)
    positions = Float64[]
    for (a, b) in segments
        append!(positions, (a.x, a.y, a.z, b.x, b.y, b.z))
    end
    BufferGeometry(positions, Float64[], Float64[], Int[], 2length(segments), 0)
end

function build_particles_case()
    scene = Scene(background=Color3(0.006, 0.008, 0.018))
    pts = Vec3{Float64}[]
    for i in 1:300
        t = 0.2 * i
        r = 0.026 * i
        y = 0.015 * i - 2.3
        push!(pts, Vec3(r*cos(t), y, r*sin(t)))
    end
    add!(scene, PointsObject(positions_geometry(pts), PointsMaterial(color=Color3(0.62, 0.86, 1.0), size=3.0)))
    a = MeshBasicMaterial(color=Color3(1.0, 0.52, 0.28), side=:double)
    b = MeshBasicMaterial(color=Color3(0.56, 1.0, 0.72), side=:double)
    for (i, p) in enumerate(pts[1:34:end])
        sp = Sprite(isodd(i) ? a : b)
        sp.position = p + Vec3(0.0, 0.16, 0.0)
        s = 0.17 + 0.035 * (i % 4)
        sp.scale = Vec3(s, s, s)
        add!(scene, sp)
    end
    OrbitCase("particles", "Particles + Sprites", "Click, drag, or swipe through a point-sprite helix.",
              scene, Vec3(0.0, 0.1, 0.0), 8.2, 1.9, π/3.1, :flat, false, :particles)
end

function build_dof_case()
    scene = Scene(background=Color3(0.055, 0.060, 0.075))
    add!(scene, AmbientLight(color=Color3(1.0, 1.0, 1.0), intensity=0.25))
    key = DirectionalLight(color=Color3(1.0, 0.92, 0.78), intensity=0.95, position=Vec3(5.0, 9.0, 5.0))
    key.target = Vec3(0.0, 0.7, 0.0)
    add!(scene, key)
    add!(scene, DirectionalLight(color=Color3(0.45, 0.60, 1.0), intensity=0.55, position=Vec3(-7.0, 5.0, -3.0)))

    floor = Mesh(PlaneGeometry(width=17.0, height=19.0, width_segments=18, height_segments=18),
                 MeshStandardMaterial(color=Color3(1.0, 1.0, 1.0), roughness=0.88,
                                      map=checker_texture(n=10, cell=8, a=Color3(0.55, 0.57, 0.64), b=Color3(0.26, 0.28, 0.34))))
    floor.rotation = Euler(-π/2, 0.0, 0.0)
    add!(scene, floor)

    colors = [Color3(0.95, 0.35, 0.26), Color3(0.26, 0.72, 0.96), Color3(0.95, 0.78, 0.24), Color3(0.46, 0.86, 0.48)]
    for row in 1:4, col in 1:4
        z = -4.5 + 2.1 * row
        x = -3.6 + 2.3 * col
        radius = 0.42 + 0.05 * row
        mat = MeshStandardMaterial(color=colors[mod1(row + col, length(colors))], metalness=0.15, roughness=0.42)
        obj = isodd(row + col) ?
            Mesh(SphereGeometry(radius=radius, width_segments=28, height_segments=18), mat) :
            Mesh(TorusKnotGeometry(radius=radius, tube=0.13, tubular_segments=48, radial_segments=8), mat)
        obj.position = Vec3(x, radius + 0.05, z)
        obj.rotation = Euler(0.2row, 0.35col, 0.1row)
        add!(scene, obj)
    end
    OrbitCase("postfx", "Postprocessing + DOF", "Orbit a shaded scene with SSAO, outlines, and depth of field.",
              scene, Vec3(0.1, 0.6, 0.2), 9.0, 4.2, π/4.5, :smooth, false, :dof)
end

function write_html(cases::Vector{OrbitCase})
    cards = join(["""
        <button class="case-card$(i == 1 ? " active" : "")" data-case="$(case.id)">
          <img src="interactive_frames/$(case.id)_01.png" alt="$(case.title)">
          <span><strong>$(case.title)</strong><small>$(case.subtitle)</small></span>
        </button>
        """ for (i, case) in enumerate(cases)], "\n")
    data = join(["$(case.id): {title: '$(case.title)', subtitle: '$(case.subtitle)'}" for case in cases], ",\n      ")
    html = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Diff3D.jl Interactive Showcase</title>
  <style>
    :root { color-scheme: dark; --bg:#090c12; --panel:#141923; --text:#edf3fb; --muted:#9aa7b8; --edge:#2a3342; --accent:#55c7ff; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    main { width:min(1180px, calc(100vw - 28px)); margin:0 auto; padding:26px 0 38px; }
    header { display:flex; justify-content:space-between; gap:18px; align-items:end; margin-bottom:16px; }
    h1 { margin:0 0 6px; font-size:26px; letter-spacing:0; }
    p { margin:0; color:var(--muted); line-height:1.5; }
    .viewer { display:grid; grid-template-columns:minmax(0, 1fr) 310px; gap:18px; align-items:start; }
    .stage { border:1px solid var(--edge); border-radius:8px; overflow:hidden; background:#030407; }
    .stage img { display:block; width:100%; aspect-ratio:$W / $H; object-fit:cover; cursor:grab; user-select:none; touch-action:none; }
    .stage img:active { cursor:grabbing; }
    .bar { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:12px 14px; border-top:1px solid var(--edge); background:var(--panel); }
    .bar strong { font-size:14px; }
    .bar span { color:var(--muted); font-size:13px; }
    .cases { display:grid; gap:10px; }
    .case-card { width:100%; display:grid; grid-template-columns:96px 1fr; gap:10px; align-items:center; text-align:left; padding:8px; border:1px solid var(--edge); border-radius:8px; background:var(--panel); color:var(--text); cursor:pointer; }
    .case-card.active { border-color:var(--accent); box-shadow:0 0 0 1px rgba(85,199,255,.35) inset; }
    .case-card img { width:96px; aspect-ratio:$W / $H; object-fit:cover; border-radius:5px; background:#05070a; }
    .case-card strong { display:block; font-size:13px; margin-bottom:3px; }
    .case-card small { display:block; color:var(--muted); font-size:12px; line-height:1.35; }
    @media (max-width: 860px) { header { display:block; } .viewer { grid-template-columns:1fr; } .cases { grid-template-columns:repeat(auto-fit, minmax(240px, 1fr)); } }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <h1>Diff3D.jl Interactive Showcase</h1>
        <p>Click a case, then drag horizontally on the render to orbit through Julia-rendered frames.</p>
      </div>
      <p><span id="counter">1 / $NFRAMES</span></p>
    </header>
    <section class="viewer">
      <div class="stage">
        <img id="frame" src="interactive_frames/$(cases[1].id)_01.png" alt="$(cases[1].title)" draggable="false">
        <div class="bar"><strong id="title">$(cases[1].title)</strong><span id="subtitle">$(cases[1].subtitle)</span></div>
      </div>
      <nav class="cases">$cards</nav>
    </section>
  </main>
  <script>
    const frameCount = $NFRAMES;
    const cases = {
      $data
    };
    let currentCase = '$(cases[1].id)';
    let currentFrame = 1;
    let dragging = false;
    let startX = 0;
    let startFrame = 1;
    const img = document.getElementById('frame');
    const title = document.getElementById('title');
    const subtitle = document.getElementById('subtitle');
    const counter = document.getElementById('counter');
    function pad(n) { return String(n).padStart(2, '0'); }
    function setFrame(n) {
      currentFrame = ((n - 1) % frameCount + frameCount) % frameCount + 1;
      img.src = `interactive_frames/\${currentCase}_\${pad(currentFrame)}.png`;
      counter.textContent = `\${currentFrame} / \${frameCount}`;
    }
    function setCase(id) {
      currentCase = id;
      title.textContent = cases[id].title;
      subtitle.textContent = cases[id].subtitle;
      document.querySelectorAll('.case-card').forEach(btn => btn.classList.toggle('active', btn.dataset.case === id));
      setFrame(1);
    }
    document.querySelectorAll('.case-card').forEach(btn => btn.addEventListener('click', () => setCase(btn.dataset.case)));
    img.addEventListener('pointerdown', ev => { dragging = true; startX = ev.clientX; startFrame = currentFrame; img.setPointerCapture(ev.pointerId); });
    img.addEventListener('pointermove', ev => {
      if (!dragging) return;
      const steps = Math.round((ev.clientX - startX) / 28);
      setFrame(startFrame + steps);
    });
    img.addEventListener('pointerup', () => dragging = false);
    img.addEventListener('pointercancel', () => dragging = false);
    img.addEventListener('wheel', ev => { ev.preventDefault(); setFrame(currentFrame + Math.sign(ev.deltaY)); }, {passive:false});
  </script>
</body>
</html>
"""
    path = joinpath(OUT, "interactive_showcase.html")
    open(path, "w") do io
        write(io, html)
    end
    return path
end

function main()
    cases = [build_instancing_case(), build_particles_case(), build_dof_case()]
    for case in cases
        println("rendering $(case.id)")
        for frame in 1:NFRAMES
            path = joinpath(FRAME_DIR, "$(case.id)_$(lpad(frame, 2, '0')).png")
            save_png(path, render_case_frame(case, frame))
        end
    end
    html = write_html(cases)
    println("INTERACTIVE_SHOWCASE_OK $html")
end

main()
