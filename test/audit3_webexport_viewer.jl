using Test, Diff3D

# Regression tests for the exported WebGL viewer (the JavaScript/GLSL that
# _web_write_webgl_html emits). Nothing in Julia parses that code, so each test pins the
# corrected source and, where node is installed, also runs the viewer's own functions and
# compares them with Diff3D's Julia implementation.

_audit3_viewer_html() = Diff3D._webgl_html("{\"cases\":[]}", "audit3")

# The one-line top-level viewer function `name`, as emitted.
function _audit3_viewer_function(html::AbstractString, name::AbstractString)
    for line in eachsplit(html, '\n')
        startswith(line, "  function $name(") && return String(line)
    end
    error("viewer function $name not found")
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
