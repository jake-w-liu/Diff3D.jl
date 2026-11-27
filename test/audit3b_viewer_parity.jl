using Test, Diff3D

# Round-2 regression tests for the exported WebGL viewer: places where the browser backend
# disagreed with the CPU renderer or with three.js r186. Nothing in Julia parses the viewer
# code, so each test pins the corrected source and, where node is installed, runs the
# viewer's own functions and compares them with Diff3D's Julia implementation or with
# numbers printed by three.js r186 under node.

_audit3b_viewer_html() = Diff3D._webgl_html("{\"cases\":[]}", "audit3b")

# The top-level viewer function `name`, as emitted: its one line, or through the line that
# closes it at the viewer's two-space indentation.
function _audit3b_viewer_function(html::AbstractString, name::AbstractString)
    lines = split(html, '\n')
    first = findfirst(line -> startswith(line, "  function $name("), lines)
    first === nothing && error("viewer function $name not found")
    endswith(rstrip(lines[first]), "}") && return String(lines[first])
    last = findnext(==("  }"), lines, first + 1)
    last === nothing && error("viewer function $name is not closed")
    return join(lines[first:last], "\n")
end

# The viewer's top-level `const name=...;` statement (one line).
function _audit3b_viewer_const(html::AbstractString, name::AbstractString)
    for line in split(html, '\n')
        startswith(line, "  const $name=") && return String(line)
    end
    error("viewer const $name not found")
end

# Runs `body` (JavaScript printing JSON) under node after the given viewer functions, or
# returns nothing when node is not installed.
function _audit3b_node_json(html::AbstractString, names, body::AbstractString;
                            prelude::AbstractString="")
    node = Sys.which("node")
    node === nothing && return nothing
    path = tempname() * ".js"
    try
        write(path, prelude * "\n" *
                    join((_audit3b_viewer_function(html, n) for n in names), "\n") * "\n" * body)
        return Diff3D._json_parse(read(`$node $path`, String))
    finally
        rm(path; force=true)
    end
end

@testset "page title rejects what HTML cannot carry" begin
    scene = Scene()
    case = WebGLExportCase("a", "A", "", scene)
    mktempdir() do dir
        path = joinpath(dir, "out.html")
        # HTML tokenizer, RCDATA state: U+0000 is an unexpected-null-character parse error
        # and is emitted as U+FFFD; `&#0;` is a null-character-reference and becomes U+FFFD
        # too. Headless Chromium reported document.title code points [97,98,65533,99,100]
        # for "ab\0cd" before this check.
        @test_throws ArgumentError save_webgl_html(path, [case]; title="ab\0cd")
        @test !isfile(path)
        @test_throws ArgumentError save_webgl_html(path, [case]; title=String(UInt8[0x61, 0xff]))
        @test !isfile(path)
        save_webgl_html(path, [case]; title="a & <b>")
        @test occursin("<title>a &amp; &lt;b&gt;</title>", read(path, String))
    end
end

# The viewer's multi-line `const name = {` ... `  };` block.
function _audit3b_viewer_block(html::AbstractString, name::AbstractString)
    lines = split(html, '\n')
    first = findfirst(line -> startswith(line, "  const $name = {"), lines)
    first === nothing && error("viewer block $name not found")
    last = findnext(==("  };"), lines, first + 1)
    return join(lines[first:last], "\n")
end

@testset "mirrored world matrices draw with clockwise front faces" begin
    html = _audit3b_viewer_html()
    # A recording WebGL stub: applySide's calls decide which faces survive culling and which
    # side gl_FrontFacing reports, so they are compared with three.js state transitions.
    prelude = """
    const gl={CULL_FACE:2884,FRONT:1028,BACK:1029,CW:2304,CCW:2305,calls:[],
      enable(c){this.calls.push(["enable",c]);}, disable(c){this.calls.push(["disable",c]);},
      cullFace(f){this.calls.push(["cullFace",f]);}, frontFace(f){this.calls.push(["frontFace",f]);}};
    const glCache={program:null,blend:false,cull:false,cullFace:gl.BACK,frontFace:gl.CCW,depthTest:true,depthMask:true,lineWidth:1};
    const add=(a,b)=>[a[0]+b[0],a[1]+b[1],a[2]+b[2]], sub=(a,b)=>[a[0]-b[0],a[1]-b[1],a[2]-b[2]], dot=(a,b)=>a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
    const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
    const norm=a=>{ const l=Math.hypot(a[0],a[1],a[2])||1; return [a[0]/l,a[1]/l,a[2]/l]; };
    """ * _audit3b_viewer_block(html, "M4")
    names = filter(n -> occursin("  function $n(", html),
                   ["setCapability", "objectMirrored", "setFrontFace", "applySide"])
    mirror = "[-1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]"
    ident = "[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]"
    body = """
    function state(o){ gl.calls=[]; applySide(o); return {cull:glCache.cull, cullFace:glCache.cullFace, frontFace:glCache.frontFace}; }
    const out={};
    for(const side of ["front","back","double"]){
      out["mirrored-"+side]=state({mode:"triangles",side:side,transformMatrix:$mirror,matrix:$mirror});
      out["plain-"+side]=state({mode:"triangles",side:side,transformMatrix:$ident,matrix:$ident});
    }
    // A split transparent instance bakes a mirroring instance matrix into o.matrix; three.js
    // tests the InstancedMesh's matrixWorld only.
    out.instance=state({mode:"triangles",side:"front",transformMatrix:$ident,matrix:$mirror});
    // A skinned mesh draws with o.matrix = identity and tests its own world matrix.
    out.skinned=state({mode:"triangles",side:"front",transformMatrix:$mirror,matrix:$ident,skin:{}});
    out.line=state({mode:"lines",side:"front",transformMatrix:$mirror,matrix:$mirror});
    console.log(JSON.stringify(out));
    """
    r = _audit3b_node_json(html, names, body; prelude)
    if r !== nothing
        CW, CCW, FRONT, BACK = 2304, 2305, 1028, 1029
        # WebGLState.js:754-763: DoubleSide disables culling; flipSided = (side == BackSide)
        # xor frontFaceCW selects gl.CW. The viewer culls FRONT for BackSide instead of
        # flipping, so the drawn faces and the !gl_FrontFacing normal flip match three.js.
        for side in ("front", "back", "double")
            @test r["mirrored-$side"]["frontFace"] == CW
            @test r["plain-$side"]["frontFace"] == CCW
            @test r["mirrored-$side"]["cull"] == (side != "double")
            side != "double" && @test r["mirrored-$side"]["cullFace"] == (side == "back" ? FRONT : BACK)
        end
        @test r["instance"]["frontFace"] == CCW
        @test r["skinned"]["frontFace"] == CW
        @test r["line"]["cull"] == false
    end
    @test occursin("o.mirrored=M4.orientation3(m)<0", html)
end

const _AUDIT3B_VEC_PRELUDE = """
const add=(a,b)=>[a[0]+b[0],a[1]+b[1],a[2]+b[2]], sub=(a,b)=>[a[0]-b[0],a[1]-b[1],a[2]-b[2]];
const scale=(a,s)=>[a[0]*s,a[1]*s,a[2]*s], dot=(a,b)=>a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
const norm=a=>{ const l=Math.hypot(a[0],a[1],a[2])||1; return [a[0]/l,a[1]/l,a[2]/l]; };
"""

@testset "viewer animation sampling matches Julia's mixer on random tracks" begin
    html = _audit3b_viewer_html()
    @test occursin("const ct=clipTime(clip,t), ends=cubicEndings(clip,t);", html)
    @test occursin("const v=sampleTrack(tr,ct,ends);", html)
    # A fixed linear congruential stream keeps the cases reproducible without Random.
    state = Ref(UInt64(0x2545f4914f6cdd1d))
    rnd() = (state[] = state[] * 6364136223846793005 + 1442695040888963407;
             Float64(state[] >> 11) / 2.0^53)
    rv() = Vec3(4rnd() - 2, 4rnd() - 2, 4rnd() - 2)
    rq() = Quaternion(4rnd() - 2, 4rnd() - 2, 4rnd() - 2, 4rnd() - 2)   # not unit length
    obj = Group()
    clips = AnimationClip[]
    loops = [(:repeat, -1), (:repeat, 0), (:repeat, 1), (:repeat, 3), (:pingpong, -1),
             (:pingpong, 2), (:once, -1)]
    for c in 1:42
        n = 2 + c % 5
        start = c % 3 == 0 ? 0.0 : 0.5rnd()
        times = cumsum([start; [0.2 + rnd() for _ in 2:n]])
        q() = [rq() for _ in 1:n]
        v() = [rv() for _ in 1:n]
        tracks = AbstractKeyframeTrack[
            KeyframeTrack(obj, :position, times, v(); interpolation=:cubic),
            NumberKeyframeTrack(obj, :position, times, [4rnd() - 2 for _ in 1:n];
                                interpolation=:cubic, component=2),
            KeyframeTrack(obj, :scale, times, v()),
            KeyframeTrack(obj, :scale, times, v(); interpolation=:step),
            QuaternionKeyframeTrack(obj, :quaternion, times, [quat_normalize(x) for x in q()]),
            QuaternionKeyframeTrack(obj, :quaternion, times, q(); interpolation=:step),
            CubicSplineKeyframeTrack(obj, :position, times, v(), v(), v()),
            # glTF cubic-spline rotations need not be unit length at the keys.
            CubicSplineQuaternionKeyframeTrack(obj, :quaternion, times, q(), q(), q()),
        ]
        loop, reps = loops[1 + c % length(loops)]
        push!(clips, AnimationClip("c$c", times[end] + (c % 4 == 0 ? 0.3 : 0.0), tracks;
                                   loop, repetitions=reps, clamp_when_finished=isodd(c),
                                   time_scale=(1.0, -1.0, 0.7)[1 + c % 3]))
    end
    flat(x::Vec3) = [x.x, x.y, x.z]
    flat(x::Quaternion) = [x.x, x.y, x.z, x.w]
    flat(x::Real) = [Float64(x)]
    samples = Float64[]
    counts = Int[]
    expected = Vector{Vector{Vector{Float64}}}()
    for clip in clips
        d = clip.duration
        ts = vcat([k * d / 3 for k in -10:10], [tr.times[k] / clip.time_scale for tr in clip.tracks[1:1]
                                                for k in eachindex(tr.times)],
                  [(8rnd() - 4) * d for _ in 1:12])
        append!(samples, ts)
        push!(counts, length(ts))
        mixer = AnimationMixer(clip)
        for T in ts
            x = T * clip.time_scale
            mixer.sample_time = Diff3D._animation_loop_time(x, d, clip.loop, clip.repetitions,
                                                            clip.clamp_when_finished)
            mixer.ending_start, mixer.ending_end =
                Diff3D._animation_cubic_endings(x, d, clip.loop, clip.repetitions)
            push!(expected, [flat(Diff3D._mixer_track_value(tr, mixer)) for tr in clip.tracks])
        end
    end
    clips_json = "[" * join((Diff3D._web_clip_json(c) for c in clips), ",") * "]"
    prelude = join((_audit3b_viewer_const(html, n) for n in
                    ("mix", "mix3", "sub3", "scale3", "add3", "scaleN", "addN", "mixN", "norm4")
                    if occursin("  const $n=", html)), "\n")
    names = filter(n -> occursin("  function $n(", html),
                   ["hermite3", "catmull3", "hermiteN", "catmullN", "cubicInterpolant", "slerp",
                    "sampleTrack", "floorMod", "clipTime", "cubicEndings"])
    body = """
    const clips=$clips_json, samples=[$(join(repr.(samples), ","))], counts=[$(join(counts, ","))];
    const out=[]; let s=0;
    clips.forEach((clip,ci)=>{ for(let k=0;k<counts[ci];k++){ const t=samples[s++];
      const ct=clipTime(clip,t), ends=typeof cubicEndings==="function"?cubicEndings(clip,t):undefined;
      out.push(clip.tracks.map(tr=>sampleTrack(tr,ct,ends))); } });
    console.log(JSON.stringify(out));
    """
    r = _audit3b_node_json(html, names, body; prelude)
    # Before the fix the viewer evaluated cubic tracks with its own end tangents and no loop
    # endings, and returned a cubic-spline rotation's raw first key: [374, 374, 0, 0, 0, 0, 0,
    # 231] mismatched samples per kind, worst error 1.415.
    if r !== nothing
        @test length(r) == length(expected)
        worst = 0.0
        bad = zeros(Int, 8)   # mismatched samples per track kind, in the order built above
        for (got, want) in zip(r, expected), (k, (g, w)) in enumerate(zip(got, want))
            err = maximum(abs.(Float64.(g) .- w))
            worst = max(worst, err)
            bad[k] += err > 1e-12 * max(1.0, maximum(abs, w))
        end
        @test bad == zeros(Int, 8)
        @test worst < 1e-11
    end
    # quat_normalize maps the zero quaternion to the identity, as three.js Quaternion.normalize.
    z = _audit3b_node_json(html, String[], "console.log(JSON.stringify(norm4([0,0,0,0])));";
                           prelude=_audit3b_viewer_const(html, "norm4"))
    z === nothing || @test z == [0, 0, 0, 1]
    q = quat_normalize(Quaternion(0.0, 0.0, 0.0, 0.0))
    @test [q.x, q.y, q.z, q.w] == [0.0, 0.0, 0.0, 1.0]
end

@testset "hemisphere light sky axis follows the light's world position" begin
    html = _audit3b_viewer_html()
    # three.js getHemisphereLightIrradiance (lights_pars_begin.glsl.js:222-230) weights the sky
    # by 0.5*dot(normal, direction)+0.5; the viewer used the world y axis.
    @test occursin("float h=clamp(dot(n,uHemiDir[i])*.5+.5,0.0,1.0);", html)
    @test !occursin("clamp(n.y*.5+.5", html)
    @test occursin("uHemiDir[MAX_HEMI]", html)
    @test occursin("uniform3v(p,\"uHemiDir[0]\",light.hemiDir);", html)
    prelude = _AUDIT3B_VEC_PRELUDE * """
    const MAX_DIR=4, MAX_POINT=4, MAX_SPOT=4, MAX_HEMI=4, MAX_RECT=4; const shadowTextureSlots=[];
    """ * _audit3b_viewer_block(html, "M4")
    names = ["padded3", "padded2", "padded1", "layerMatches", "lighting", "eachCamera",
             "transformPoint", "transformDir", "refreshLightDerived", "updateViewAndLightPoses"]
    # A hemisphere light at local (0,1,0) under a parent turned +90 deg about x and moved: the
    # world position is (2, 0, 1) + R*(0,1,0) = (2, 0, 2), so the sky axis is (1,0,1)/sqrt(2)
    # (WebGLLights.js:634-635, setFromMatrixPosition then normalize). A light at the origin
    # keeps the zero axis (Vector3.normalize divides by length || 1).
    body = """
    const world=[1,0,0,0, 0,0,1,0, 0,-1,0,0, 2,0,1,1];
    const local=[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1,0,1];
    const hemi={type:"hemisphere",id:7,color:[1,1,1],groundColor:[0,0,0],intensity:2,direction:[0,1,0]};
    const origin={type:"hemisphere",id:8,color:[1,1,1],groundColor:[0,0,0],intensity:1,direction:[0,1,0]};
    const c={camera:null,lights:[hemi,origin],nodeMap:new Map([[7,{transformMatrix:M4.mul(world,local)}],[8,{transformMatrix:M4.ident()}]])};
    updateViewAndLightPoses(c);
    const L=lighting(c);
    console.log(JSON.stringify({dir:hemi.direction,zero:origin.direction,count:L.hemiCount,hemiDir:L.hemiDir,sky:L.hemiSky}));
    """
    r = _audit3b_node_json(html, names, body; prelude)
    if r !== nothing
        s = 1 / sqrt(2)
        @test r["dir"] ≈ [s, 0.0, s] atol=1e-15
        @test r["zero"] == [0.0, 0.0, 0.0]
        @test r["count"] == 2
        @test r["hemiDir"][1:6] ≈ [s, 0.0, s, 0.0, 0.0, 0.0] atol=1e-15
        @test r["sky"][1:3] == [2.0, 2.0, 2.0]
    end
    # The exported axis is Julia's _hemisphere_direction, the world position normalized.
    scene = Scene()
    rig = Group(); rig.position = Vec3(2.0, 0.0, 1.0); rig.rotation = Euler(pi / 2, 0.0, 0.0)
    add!(scene, rig)
    h = HemisphereLight(color=Color3(1.0, 1.0, 1.0), ground_color=Color3(0.0, 0.0, 0.0))
    add!(rig, h)
    json = Diff3D._web_lights_json(scene)
    @test occursin("\"type\":\"hemisphere\"", json)
    d = Diff3D._hemisphere_direction(h)
    @test [d.x, d.y, d.z] ≈ [1 / sqrt(2), 0.0, 1 / sqrt(2)] atol=1e-15
    @test occursin("\"direction\":[", json)
end

# GLSL vector constructors and dot for evaluating emitted shader expressions in Julia.
_audit3b_vec(a...) = collect(Float64, a)
_audit3b_dot(a, b) = sum(a .* b)

@testset "viewer lighting uses three.js r186 BRDFs with 1/pi diffuse" begin
    html = _audit3b_viewer_html()
    # BRDF_Lambert = RECIPROCAL_PI * diffuseColor (bsdfs.glsl.js) for every lit material and
    # light: the viewer used base * irradiance, PI times three.js. Headless Chrome readbacks of
    # a 0.8-grey plane facing the camera (8-bit, linear output) before -> after, with three.js
    # r186 float readbacks x 255 at the same pixel: Lambert + directional 204 -> 65 (64.94),
    # Standard roughness 1 + directional 255 -> 63 (63.20), Standard + ambient 204 -> 64
    # (63.98), Lambert + hemisphere 102 -> 32 (32.47), Lambert + point I=10 at z=2 255 -> 162
    # (162.21), Phong shininess 30 + directional 205 -> 67 (66.81).
    @test occursin("#define RECIPROCAL_PI 0.3183098861837907", html)
    @test occursin("gDirectDiffuse+=irradiance*gDiffuse*RECIPROCAL_PI;", html)
    @test occursin("if(!physical) indirectDiffuse=irradiance*gDiffuse*RECIPROCAL_PI;", html)
    @test occursin("vec3 bc=(uUseLightMap>0.5?lightMapIrradiance*RECIPROCAL_PI:vec3(1.0))*ambientOcclusion*base;", html)
    # lights_physical_fragment.glsl.js: roughness = min(max(roughness, 0.0525), 1).
    @test occursin("uUseRoughnessMap),0.0525,1.0);", html)
    @test !occursin("vec3 diffuse=uAmbientColor;", html)
    @test !occursin("vec2 DFGApprox(", html)

    # The split-sum DFG term is a fit of the r186 dfgLUT that Julia's _dfg_lut samples; check
    # the emitted GLSL numerically against it over the clamped roughness range.
    line = only(filter(l -> occursin("vec2 DFGFit(float dotNV,float roughness)", l), split(html, '\n')))
    expr = match(r"return clamp\((.*),0\.0,1\.0\); }$", line).captures[1]
    jl = replace(expr, "vec2(" => "_audit3b_vec(", "vec4(" => "_audit3b_vec(", "dot(" => "_audit3b_dot(")
    fitexpr = Meta.parse(jl)
    fit = eval(:((s, t, b, e24) -> $fitexpr))
    worst = zeros(3)
    for nv in range(0.0, 1.0; length=101), r in range(0.0525, 1.0; length=101)
        s, t = 2r - 1, 2nv - 1
        f = clamp.(Base.invokelatest(fit, s, t, [1.0, t, t * t, exp2(-6nv)], exp2(-24nv)), 0.0, 1.0)
        lx, ly = Diff3D._dfg_lut(r, nv)
        worst .= max.(worst, abs.([f[1] - lx, f[2] - ly, f[1] + f[2] - lx - ly]))
    end
    @test worst[1] < 0.031
    @test worst[2] < 0.028
    @test worst[3] < 0.057
end

@testset "flat_shading meshes draw with the face normal in the viewer" begin
    # normal_fragment_begin.glsl.js FLAT_SHADED: normalize(cross(dFdx(p), dFdy(p))), no
    # gl_FrontFacing flip. The viewer ignored flat_shading: a flat 8x6 sphere drew the smooth
    # gradient 16 19 22 ... 61 along its centre row. After, the row is 41 x16 then 64 x17,
    # the same as three.js r186 with flatShading = true at that row (headless Chrome).
    html = _audit3b_viewer_html()
    @test occursin("vec3 n=uFlatShading>0.5?normalize(cross(dFdx(vWorld),dFdy(vWorld))):safeNormal(vNormal); if(uFlatShading<0.5&&!gl_FrontFacing)n=-n;", html)
    @test occursin("uniform1f(p,\"uFlatShading\",o.flatShading?1:0);", html)
    mktempdir() do dir
        for (flat, expected) in ((true, true), (nothing, false), (false, false))
            scene = Scene()
            add!(scene, Mesh(SphereGeometry(width_segments=8, height_segments=6),
                             MeshLambertMaterial(); flat_shading=flat))
            path = joinpath(dir, "flat.html")
            save_webgl_html(path, [WebGLExportCase("f", "F", "", scene)]; chrome=false)
            @test occursin("\"flatShading\":true", read(path, String)) == expected
        end
    end
end

@testset "point-light shadows cover all six cube faces" begin
    # three.js PointLightShadow renders six faces (WebGLShadowMap.js), as Julia's
    # _point_shadow_cube does. The static export stored one 90-degree map aimed at the scene
    # centre: with the light between two boxes, the ground behind the -x box read 7..57
    # (lit) in the viewer where the CPU renders 0. The light now uses the six-face path.
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshLambertMaterial(); cast_shadow=true, receive_shadow=true))
    point = PointLight(position=Vec3(0.0, 1.2, 0.0), cast_shadow=true)
    add!(scene, point)
    json = Diff3D._web_shadow_json(scene, point)
    @test occursin("\"type\":\"pointDynamic\"", json)
    @test !occursin("\"data\":", json)
    @test Diff3D._web_shadow_json(scene, point; shadow_mode=:none) == "null"
    # A shadowed sample passes no light (three.js shadow.intensity 1; _shadow_lookup returns
    # 0): the viewer kept 0.35, so the ground behind a box still read 20 of 57 after the
    # six-face fix and reads 0 now.
    html = _audit3b_viewer_html()
    @test count("sum += current>stored ? 0.0 : 1.0;", html) == 4
    @test !occursin("current>stored ? 0.35", html)
end
