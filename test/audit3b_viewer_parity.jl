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
