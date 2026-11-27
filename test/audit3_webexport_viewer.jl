using Test, Diff3D

# Regression tests for the exported WebGL viewer (the JavaScript/GLSL that
# _web_write_webgl_html emits). Nothing in Julia parses that code, so each test pins the
# corrected source and, where node is installed, also runs the viewer's own functions and
# compares them with Diff3D's Julia implementation.

_audit3_viewer_html() = Diff3D._webgl_html("{\"cases\":[]}", "audit3")

# The top-level viewer function `name`, as emitted: its one line, or through the line that
# closes it at the viewer's two-space indentation.
function _audit3_viewer_function(html::AbstractString, name::AbstractString)
    lines = split(html, '\n')
    first = findfirst(line -> startswith(line, "  function $name("), lines)
    first === nothing && error("viewer function $name not found")
    endswith(rstrip(lines[first]), "}") && return String(lines[first])
    last = findnext(==("  }"), lines, first + 1)
    last === nothing && error("viewer function $name is not closed")
    return join(lines[first:last], "\n")
end

# Runs `body` (JavaScript printing JSON) under node after the given viewer functions, or
# returns nothing when node is not installed.
function _audit3_node_json(html::AbstractString, names, body::AbstractString)
    node = Sys.which("node")
    node === nothing && return nothing
    path = tempname() * ".js"
    try
        write(path, join((_audit3_viewer_function(html, n) for n in names), "\n") * "\n" * body)
        return Diff3D._json_parse(read(`$node $path`, String))
    finally
        rm(path; force=true)
    end
end

@testset "viewer clip time follows Julia's mixer loop time" begin
    html = _audit3_viewer_html()
    source = _audit3_viewer_function(html, "clipTime")
    # The removed rules: zero repetitions froze the clip at time 0 (three.js plays the first
    # loop, AnimationAction.js:780-800 only stops on a wrap), an exact multiple of the
    # duration sampled the end pose (three.js wraps to 0, :808-810), and a negative time
    # scale never finished.
    @test !occursin("if(r===0) return 0;", source)
    @test !occursin("Math.abs(y)<1e-9?d:y", source)
    @test occursin("if(x<-d*reps)", source)
    grid = vec([(loop, reps, clamp, ts, x) for loop in (:repeat, :pingpong, :once),
            reps in (-1, 0, 1, 2, 3), clamp in (false, true), ts in (1.0, -1.0, 0.5, -0.75),
            x in (0.0, 0.3, 1.7, 2.0, 2.5, 3.9, 4.0, 4.5, 5.5, 6.0, 6.2, 7.9, 9.0, 1e-17, 2.0 - 1e-16)])
    calls = join(("clipTime({duration:2,loop:\"$loop\",repetitions:$reps,clampWhenFinished:$clamp,timeScale:$(repr(ts))},$(repr(x)))"
                  for (loop, reps, clamp, ts, x) in grid), ",")
    values = _audit3_node_json(html, ("floorMod", "clipTime"),
                               "console.log(JSON.stringify([$calls]));")
    if values !== nothing
        expected = [Diff3D._animation_loop_time(x * ts, 2.0, loop, reps, clamp)
                    for (loop, reps, clamp, ts, x) in grid]
        # Bitwise: both evaluate the same IEEE operations (Julia's mod is rem plus the divisor).
        @test Float64.(values) == expected
        # three.js AnimationMixer.setTime oracle points (node, r186): zero repetitions play
        # the first loop; a repeat at exactly 2 durations samples 0; a reverse clamped repeat
        # with one repetition finishes at 0 once past -1 loop.
        @test expected[findfirst(==((:repeat, 0, false, 1.0, 1.7)), grid)] == 1.7
        @test expected[findfirst(==((:repeat, -1, false, 1.0, 4.0)), grid)] == 0.0
        @test expected[findfirst(==((:repeat, 1, true, -1.0, 2.5)), grid)] == 0.0
    end
end

# The viewer's top-level `const name=...` line, as emitted.
function _audit3_viewer_const(html::AbstractString, name::AbstractString)
    for line in eachsplit(html, '\n')
        startswith(line, "  const $name=") && return String(line)
    end
    error("viewer constant $name not found")
end

@testset "shadow depth pass divides clip z by w per fragment" begin
    # three.js depth.glsl.js passes gl_Position.zw (:41) and divides in the fragment shader
    # (:91). The old pass divided per vertex; perspective-correct interpolation of that
    # quotient is linear in world space, but z/w is not, so a spot-light shadow camera stored
    # depths nearer than its own surfaces. Modelled with the viewer's spotShadowMatrix on a
    # 20x20 floor lit from (-8,6,-8), 722 of 760 interior samples fell more than the 0.0015
    # bias behind the stored depth (worst 0.346); dividing interpolated z and w leaves 0.
    html = _audit3_viewer_html()
    dvsh = _audit3_viewer_const(html, "DVSH")
    dfsh = _audit3_viewer_const(html, "DFSH")
    pdfsh = _audit3_viewer_const(html, "PDFSH")
    @test !occursin("clip.z/clip.w", html)
    @test occursin("varying vec2 vShadowZW;", dvsh)
    @test occursin("vShadowZW=clip.zw; gl_Position=clip;", dvsh)
    @test occursin("varying vec2 vShadowZW;", dfsh)
    @test occursin("clamp(vShadowZW.x/vShadowZW.y*.5+.5,0.0,1.0)", dfsh)
    # The point-shadow programs strip that assignment; the pattern must still match, and the
    # varying keeps one type across both stages.
    for name in ("PDVSH", "PDVSH_BONE_TEXTURE")
        @test occursin(".replace(\"vShadowZW=clip.zw; gl_Position=clip;\",\"gl_Position=clip;\")",
                       _audit3_viewer_const(html, name))
    end
    @test occursin("varying vec2 vShadowZW;", pdfsh)
    @test !occursin("vShadowDepth", html)
end

@testset "viewer morph bounding sphere grows its box in three.js order" begin
    # BufferGeometry.computeBoundingSphere (BufferGeometry.js:749-756) offsets the max corner
    # from the box the min corner already expanded. The old viewer offset both corners from
    # the base box, so a morph moving every vertex up (+2 in y) left the sort centre at y=1.
    html = _audit3_viewer_html()
    source = _audit3_viewer_function(html, "geometrySphere")
    @test !occursin("const lo=[min[0]+dmin[0]", source)
    @test occursin("expand(min[0]+dmin[0],min[1]+dmin[1],min[2]+dmin[2]); expand(max[0]+dmax[0],max[1]+dmax[1],max[2]+dmax[2]);", source)
    sphere = _audit3_node_json(html, ("geometrySphere",),
        "console.log(JSON.stringify(geometrySphere({basePositions:[0,0,0,1,0,0],morphTargets:[[0.5,2,0,0.5,2,0]]})));")
    if sphere !== nothing
        # three.js r186 oracle (node): center (0.75, 2, 0), radius 2.1360009363293826.
        @test Float64.(sphere["center"]) == [0.75, 2.0, 0.0]
        @test sphere["radius"] ≈ 2.1360009363293826 rtol=1e-15
    end
end
