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
