using Diff3D, Test

# The exported viewer writes every uniform through one typed writer that looks the name up in
# the program's link-time table of ACTIVE uniforms, as three.js WebGLUniforms does. A name the
# linker optimised out has no entry there and writing it is a legal no-op, so at run time a
# misspelt name is indistinguishable from an optimised-out one. The shipped GLSL can tell them
# apart: every name the viewer writes or requires must be a uniform it declares, and every call
# site's kind must be able to write every GLSL type declared under that name.
function _web_uniform_call_text(script::AbstractString, start::Int)
    depth = 0
    quote_char = nothing
    i = start
    while i <= lastindex(script)
        c = script[i]
        if quote_char !== nothing
            c == quote_char && (quote_char = nothing)
        elseif c == '"' || c == '\''
            quote_char = c
        elseif c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth == 0 && return script[start:i]
        end
        i = nextind(script, i)
    end
    error("unbalanced uniform write starting at index $start")
end

@testset "WebGL viewer writes only declared uniforms, through the typed writer" begin
    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial()))
    file = tempname() * ".html"
    save_webgl_html(file, [WebGLExportCase("names", "Names", "writer audit", scene)]; chrome=false)
    html = read(file, String)
    rm(file; force=true)
    open_tag = findfirst("<script>", html)
    close_tag = findlast("</script>", html)
    @test open_tag !== nothing && close_tag !== nothing
    script = html[nextind(html, last(open_tag)):prevind(html, first(close_tag))]

    glsl_type = "(?:float|int|bool|vec[234]|ivec[234]|bvec[234]|mat[234]|sampler2D|samplerCube)"
    declaration = Regex("\\buniform\\s+(?:(?:lowp|mediump|highp)\\s+)?" * glsl_type * "\\s+([^;]+);")
    declared = Set{String}()
    for m in eachmatch(declaration, script), part in split(m.captures[1], ',')
        push!(declared, replace(strip(part), r"\s*\[.*$" => ""))
    end

    writers = "uniform1f|uniform1i|uniform1fv|uniform1iv|uniform2v|uniform3v|uniform4v|uniformMat3|uniformMat4|uniformTexMatrix"
    name_literal = r"\"(\w+)(?:\[0\])?\""
    required = Set(["uModel", "uView", "uProj", "uColor", "uOpacity", "uViewProj", "uPointShadowPos", "uPointShadowFar"])
    written = Set{String}()
    required_writes = 0
    unflagged = String[]
    for m in eachmatch(Regex("\\b(?:" * writers * ")\\(p,([^,]*),"), script)
        names = [s.captures[1] for s in eachmatch(name_literal, m.captures[1])]
        union!(written, names)
        if any(in(required), names)
            required_writes += 1
            call = _web_uniform_call_text(script, m.offset + findfirst('(', m.match) - 1)
            endswith(call, ",REQUIRED)") || push!(unflagged, call)
        end
    end
    # the audit has to see the writer's call sites, or everything below passes vacuously
    @test length(declared) > 100
    @test length(written) > 100
    @test sort(collect(setdiff(written, declared))) == String[]

    # every call site's kind accepts every GLSL type declared under the name it writes, so a
    # changed declaration fails here rather than in a user's viewer
    glsl_types = Dict{String,Set{String}}()
    for m in eachmatch(r"\buniform\s+(?:(?:lowp|mediump|highp)\s+)?(\w+)\s+([^;{}()]+);", script), part in split(m.captures[2], ',')
        push!(get!(Set{String}, glsl_types, replace(strip(part), r"\s*\[.*$" => "")), m.captures[1])
    end
    accepts = Dict("uniform1f" => ("float", "bool"), "uniform1fv" => ("float", "bool"),
        "uniform1i" => ("int", "bool", "sampler2D", "samplerCube"), "uniform1iv" => ("int", "bool", "sampler2D", "samplerCube"),
        "uniform2v" => ("vec2", "bvec2"), "uniform3v" => ("vec3", "bvec3"), "uniform4v" => ("vec4", "bvec4"),
        "uniformMat3" => ("mat3",), "uniformMat4" => ("mat4",), "uniformTexMatrix" => ("mat3",))
    kind_mismatches = String[]
    kind_checked = 0
    for m in eachmatch(Regex("\\b(" * writers * ")\\(p,([^,]*),"), script), s in eachmatch(name_literal, m.captures[2])
        kind_checked += 1
        for t in get(glsl_types, s.captures[1], Set{String}())
            t in accepts[m.captures[1]] || push!(kind_mismatches, "$(m.captures[1]) $(s.captures[1]) :: $t")
        end
    end
    @test kind_checked > 200
    @test kind_mismatches == String[]

    # uniforms whose GL default of zero blanks or collapses the draw are required when a program
    # is linked and at every write
    listed = Set{String}()
    for m in eachmatch(r"requireUniforms\(\{[^}]*\},\[([^\]]*)\]\)", script)
        union!(listed, s.captures[1] for s in eachmatch(name_literal, m.captures[1]))
    end
    @test listed == required
    @test issubset(required, declared)
    @test required_writes >= 10
    @test unflagged == String[]

    # the typed kinds are the only place a GL uniform entry point is called
    @test [m.match for m in eachmatch(r"gl\.uniform\w*\((?!l,)[^;]{0,80}", script)] == String[]
    @test !occursin("programUniformLocations", script)
    @test occursin("const programInfo=new WeakMap();", script)
end
