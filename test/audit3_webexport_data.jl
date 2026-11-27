using Test, Diff3D

# Reference text: Printf "%.17g", the format the exporter has always written
# (`_WEB_NUM_PRINTF_FORMAT`). Printf is reached through Diff3D so the test
# environment needs no extra dependency.
_audit3_printf_g17(x) =
    Diff3D.Printf.format(Diff3D._WEB_NUM_PRINTF_FORMAT, Float64(x))

function _audit3_num(x)
    io = IOBuffer()
    Diff3D._js_write_num(io, x, Diff3D._web_num_buffer())
    return String(take!(io))
end

function _audit3_num_allocations(io, xs, buf)
    seekstart(io)
    Diff3D._js_write_array(io, xs, buf)
    seekstart(io)
    return @allocated Diff3D._js_write_array(io, xs, buf)
end

@testset "WebGL export numbers keep the exact %.17g text" begin
    # Hard-coded "%.17g" outputs (Printf/Ryu on Julia 1.10 and 1.13). The
    # 1 + k * 2^-17 values are exact ties at the 17th significant digit:
    # Ryu rounds them half to even (base/ryu/fixed.jl `roundUp == 2`).
    expected = [
        0.1 => "0.10000000000000001", -0.0 => "-0", 0.0 => "0", 1.0 => "1",
        0.5 => "0.5", 1 / 3 => "0.33333333333333331",
        -2 / 3 => "-0.66666666666666663", 1.0e-5 => "1.0000000000000001e-05",
        prevfloat(1.0e-4) => "9.9999999999999991e-05", 1.0e-4 => "0.0001",
        0.00012345 => "0.00012344999999999999", 123456.789 => "123456.789",
        1 + 2.0^-17 => "1.0000076293945312", 1 + 3 * 2.0^-17 => "1.0000228881835938",
        2.0^53 => "9007199254740992", prevfloat(1.0e17) => "99999999999999984",
        1.0e17 => "1e+17", 1.0e16 => "10000000000000000",
        1.2246467991473532e-16 => "1.2246467991473532e-16",
        nextfloat(0.0) => "4.9406564584124654e-324",
        floatmax(Float64) => "1.7976931348623157e+308",
        -3.0e-6 => "-3.0000000000000001e-06", 0.30000000000000004 => "0.30000000000000004",
        255.0 => "255", 12345678901234567.0 => "12345678901234568",
    ]
    for (x, text) in expected
        @test _audit3_num(x) == text
        @test _audit3_printf_g17(x) == text
    end
    # Integer arguments within 2^53 print their exact decimal digits, which is
    # the "%.17g" text of their exact Float64 value; larger ones round.
    for i in (0, 1, -1, 9, 10, 99, 100, 101, 12345, -98765, 2^53, -2^53,
              typemax(Int32), typemin(Int32))
        @test _audit3_num(i) == string(i) == _audit3_printf_g17(i)
    end
    for i in (2^53 + 1, -(2^53 + 1), typemax(Int), typemin(Int))
        @test _audit3_num(i) == _audit3_printf_g17(i)
    end
    @test _audit3_num(Int32(-7)) == "-7"
    @test _audit3_num(UInt8(255)) == "255"
    @test _audit3_num(true) == "1"
    @test _audit3_num(Float32(0.1)) == "0.10000000149011612"

    # Boundaries of the exact fixed-notation path and of Printf's exponent
    # selection (18 significant digits), then a seeded spread of magnitudes.
    values = Float64[]
    for k in -7:18, d in 0:40
        push!(values, nextfloat(10.0^k, d), prevfloat(10.0^k, d))
    end
    for s in 1:70, j in 1:20
        push!(values, Float64(j) * 2.0^-s, 1.0 + j * 2.0^-s, 4096.0 + j * 2.0^-s)
    end
    state = UInt64(0x9e3779b97f4a7c15)
    for _ in 1:20000
        state = state * 0x5851f42d4c957f2d + 0x14057b7ef767814f
        bits = state
        x = reinterpret(Float64, bits)
        isfinite(x) && push!(values, x)
        mantissa = Float64(bits >> 11) / 2.0^53
        push!(values, (isodd(bits) ? -1 : 1) * mantissa * 10.0^(Int(bits % 26) - 7))
    end
    mismatches = count(x -> _audit3_num(x) != _audit3_printf_g17(x), values)
    @test mismatches == 0
end

@testset "WebGL export number writing does not allocate" begin
    if Base.JLOptions().opt_level > 0
        xs = [sin(0.37i) * 10.0^(i % 9 - 4) for i in 1:4096]
        ints = collect(-2000:2000)
        buf = Diff3D._web_num_buffer()
        io = IOBuffer(sizehint=26 * 8192)
        _audit3_num_allocations(io, xs, buf)
        @test _audit3_num_allocations(io, xs, buf) == 0
        _audit3_num_allocations(io, ints, buf)
        @test _audit3_num_allocations(io, ints, buf) == 0
    end
end

@testset "WebGL export staging buffer preserves bytes" begin
    sink = IOBuffer()
    staged = Diff3D._WebStagedIO(sink)
    big = rand(UInt8, 3 * Diff3D._WEB_STAGING_BYTES + 17)
    reference = IOBuffer()
    for chunk in (b"[", big[1:100], big, b",", big[1:Diff3D._WEB_STAGING_BYTES - 3])
        write(staged, chunk)
        write(reference, chunk)
    end
    write(staged, 'é')
    write(reference, 'é')
    print(staged, 12345)
    print(reference, 12345)
    Diff3D._web_flush_staged!(staged)
    @test take!(sink) == take!(reference)

    # The staged data JSON equals the unstaged case writer, and the file export
    # embeds exactly that text.
    scene = Scene()
    add!(scene, AmbientLight(intensity=0.25))
    add!(scene, Mesh(SphereGeometry(width_segments=24, height_segments=12),
                     MeshStandardMaterial(map=Texture(fill(0.25, 3, 5, 4)))))
    case = WebGLExportCase("staged", "Staged", "bytes", scene)
    direct = IOBuffer()
    write(direct, "{\"cases\":[")
    Diff3D._web_write_case_json(direct, case)
    write(direct, "]}")
    staged_json = IOBuffer()
    Diff3D._web_write_data_json(staged_json, [case])
    data = take!(staged_json)
    @test data == take!(direct)
    path = tempname() * ".html"
    try
        save_webgl_html(path, [case]; chrome=false)
        html = read(path, String)
        @test occursin("  const DATA = " * String(copy(data)) * ";", html)
    finally
        rm(path; force=true)
    end
end

@testset "WebGL export escapes C0 controls in strings" begin
    # HTML script data (WHATWG tokenizer "script data state") replaces a raw
    # U+0000 with U+FFFD before JavaScript parses the literal, so it must be
    # written as an escape. Every C0 control gets a JSON escape.
    @test Diff3D._js_str("a\0b") == "\"a\\u0000b\""
    @test Diff3D._js_str("\x01\x1f\x0b") == "\"\\u0001\\u001f\\u000b\""
    @test Diff3D._js_str("\b\f\n\r\t") == "\"\\b\\f\\n\\r\\t\""
    controls = String(Char.(0:31))
    encoded = Diff3D._js_str(controls)
    @test all(c -> c >= ' ', encoded)
    @test Diff3D._json_parse("[" * encoded * "]") == Any[controls]
    @test Diff3D._js_str("</script><!--\u2028\u2029") ==
          "\"\\u003c/script>\\u003c!--\\u2028\\u2029\""

    scene = Scene()
    add!(scene, Mesh(BoxGeometry(), MeshBasicMaterial(); name="box\0one"))
    drawable = only(Diff3D._web_collect_drawables(scene))
    @test !occursin('\0', drawable)
    @test Diff3D._json_parse(drawable)["name"] == "box\0one"
end

@testset "WebGL export keeps wireframe and line blending" begin
    # three.js draws a wireframe with its own material, so `transparent`
    # survives (WebGLRenderLists.js push: material.transparent). The CPU
    # wireframe pass also tests the mesh material (rasterizer.jl
    # `material_wireframe(mat) ? _primitive_transparent(mat)`).
    function payloads(object)
        scene = Scene()
        add!(scene, object)
        return [Diff3D._json_parse(s) for s in Diff3D._web_collect_drawables(scene)]
    end
    wire = only(payloads(Mesh(BoxGeometry(),
        MeshBasicMaterial(wireframe=true, transparent=true, opacity=0.42))))
    @test wire["mode"] == "lines"
    @test wire["transparent"] === true
    @test wire["opacity"] == 0.42
    opaque_wire = only(payloads(Mesh(BoxGeometry(),
        MeshBasicMaterial(wireframe=true, opacity=0.42))))
    @test opaque_wire["transparent"] === false
    matrices = [mat4_translation(Float64(i), 0.0, 0.0) for i in 1:2]
    split = payloads(InstancedMesh(BoxGeometry(),
        MeshBasicMaterial(wireframe=true, transparent=true, opacity=0.3), matrices))
    @test length(split) == 2
    @test all(p -> p["transparent"] === true && p["mode"] == "lines", split)

    # Line materials have no `transparent` field; the CPU renderer blends them
    # when opacity is below one (`_primitive_transparent`), and so does export.
    segment = BufferGeometry([0.0, 0.0, 0.0, 1.0, 0.0, 0.0], Float64[], Float64[],
                             Int[], 2, 0)
    for Material in (LineBasicMaterial, LineDashedMaterial)
        @test Diff3D._primitive_transparent(Material(opacity=0.5))
        @test only(payloads(LineSegments(segment, Material(opacity=0.5))))["transparent"] === true
        @test only(payloads(LineSegments(segment, Material())))["transparent"] === false
    end
    # A translucent instanced line takes the per-instance sorted split, so each
    # draw bakes its instance matrix and instance colour like the mesh path.
    line_instances = InstancedMesh(segment, LineBasicMaterial(opacity=0.5, color=Color3(1.0, 0.5, 0.25)),
                                   [mat4_translation(Float64(i), 0.0, 0.0) for i in 1:3];
                                   draw_mode=:lines)
    set_instance_color!(line_instances, 1, Color3(0.5, 1.0, 1.0))
    line_split = payloads(line_instances)
    @test length(line_split) == 3
    @test all(p -> p["transparent"] === true && p["mode"] == "lines", line_split)
    @test [p["matrix"][13] for p in line_split] == [1, 2, 3]
    @test line_split[1]["color"] == [0.5, 0.5, 0.25]
    @test line_split[2]["color"] == [1, 0.5, 0.25]
    opaque_line_instances = InstancedMesh(segment, LineBasicMaterial(),
                                          [mat4_translation(Float64(i), 0.0, 0.0) for i in 1:3];
                                          draw_mode=:lines)
    @test only(payloads(opaque_line_instances))["transparent"] === false
    # Materials with the field stay authoritative (WebGLRenderLists.js push).
    @test only(payloads(Mesh(BoxGeometry(), MeshBasicMaterial(opacity=0.5))))["transparent"] === false
end

@testset "WebGL export writes the hemisphere light sky axis" begin
    # three.js r186 oracle (node): WebGLLights.js hemisphere
    # `direction.setFromMatrixPosition(light.matrixWorld)` then
    # `transformDirection` (normalized) for this parented light.
    group = Group()
    group.position = Vec3(0.0, 1.0, 0.0)
    group.rotation = Euler(0.0, 0.5, 0.25)
    group.scale = Vec3(2.0, 0.5, 3.0)
    light = HemisphereLight(position=Vec3(1.0, 2.0, 2.0))
    add!(group, light)
    scene = Scene()
    add!(scene, group)
    payload = only(Diff3D._json_parse(Diff3D._web_lights_json(scene)))
    @test payload["type"] == "hemisphere"
    @test isapprox(payload["direction"],
                   [0.6504805978210656, 0.36756620069764756, 0.6646578668480844];
                   rtol=0, atol=4eps())
    # Two nested parents with negative and non-uniform scales (same oracle).
    outer = Group()
    outer.position = Vec3(0.0, 1.0, 0.0)
    outer.rotation = Euler(0.3, -0.7, 1.1)
    outer.scale = Vec3(-2.0, 0.5, 3.0)
    inner = Group()
    inner.position = Vec3(1.0, -2.0, 0.5)
    inner.rotation = Euler(-0.4, 0.2, 0.9)
    inner.scale = Vec3(1.0, -1.0, 2.0)
    add!(outer, inner)
    add!(inner, HemisphereLight(position=Vec3(1.0, 2.0, -3.0)))
    nested_scene = Scene()
    add!(nested_scene, outer)
    @test isapprox(only(Diff3D._json_parse(Diff3D._web_lights_json(nested_scene)))["direction"],
                   [0.6376511080927291, 0.0014803232472177413, -0.7703238753869689];
                   rtol=0, atol=4eps())
    # Default position is Object3D.DEFAULT_UP; a zero position stays zero
    # (Vector3.normalize divides by `length() || 1`).
    default_scene = Scene()
    add!(default_scene, HemisphereLight())
    @test only(Diff3D._json_parse(Diff3D._web_lights_json(default_scene)))["direction"] == [0, 1, 0]
    zero_scene = Scene()
    add!(zero_scene, HemisphereLight(position=Vec3(0.0, 0.0, 0.0)))
    @test only(Diff3D._json_parse(Diff3D._web_lights_json(zero_scene)))["direction"] == [0, 0, 0]
end

@testset "WebGL export averages two-channel cube faces as luminance" begin
    # Two-channel texels are luminance + alpha (textures.jl `_texel`); the
    # fallback face colour must not read alpha as green.
    data = zeros(2, 2, 2)
    data[:, :, 1] .= 0.25
    data[:, :, 2] .= 1.0
    face = Texture(data)
    @test sample_texture(face, 0.5, 0.5) == Color3(0.25, 0.25, 0.25)
    @test Diff3D._web_texture_average_color(face) == Color3(0.25, 0.25, 0.25)
    env = Diff3D._json_parse(Diff3D._web_env_json(CubeTexture(ntuple(_ -> Texture(copy(data)), 6))))
    @test all(==([0.25, 0.25, 0.25]), env["colors"])
    rgb = zeros(1, 2, 3)
    rgb[1, 1, :] .= (0.2, 0.4, 0.6)
    rgb[1, 2, :] .= (0.4, 0.6, 0.8)
    average = Diff3D._web_texture_average_color(Texture(rgb))
    @test [average.r, average.g, average.b] ≈ [0.3, 0.5, 0.7]
end

function _audit3_many_objects_case(count)
    scene = Scene()
    add!(scene, AmbientLight(intensity=0.3))
    geometry = BoxGeometry()
    for index in 1:count
        group = Group()
        group.position = Vec3(0.01 * index, 0.0, 0.0)
        mesh = Mesh(geometry, MeshStandardMaterial(color=Color3(0.5, 0.25, index / count));
                    name="box$index")
        add!(group, mesh)
        add!(scene, group)
    end
    return WebGLExportCase("many", "Many", "objects", scene)
end

function _audit3_data_json_allocations(case, io)
    seekstart(io)
    truncate(io, 0)
    Diff3D._web_write_data_json(io, [case])
    seekstart(io)
    truncate(io, 0)
    return @allocated Diff3D._web_write_data_json(io, [case])
end

@testset "WebGL export integer text" begin
    for x in (0, 7, 10, 99, 100, 12345, -1, -10, -987654321, typemax(Int), typemin(Int))
        io = IOBuffer()
        Diff3D._web_print_int(io, x)
        @test String(take!(io)) == string(x)
    end
end

@testset "WebGL export per-object allocation budget" begin
    if Base.JLOptions().opt_level > 0
        count = 300
        case = _audit3_many_objects_case(count)
        io = IOBuffer(sizehint=4_000_000)
        bytes = _audit3_data_json_allocations(case, io)
        # v1.1.1 allocated about 2.9 KiB (1.13) to 3.3 KiB (1.10) per drawable
        # through boxed texture registries and per-integer strings; the
        # remaining cost is matrix/material boxing at dynamic call sites.
        @test bytes <= 2400 * count
    end
end

function audit3_staged_export_allocations(cases)
    Diff3D._web_write_data_json_validated(devnull, cases)
    return @allocated Diff3D._web_write_data_json_validated(devnull, cases)
end

# An IO whose first write starts another export on the same task, while the
# outer export still holds the task's staging buffer.
struct Audit3NestedExportIO <: IO
    inner::IOBuffer
    cases::Vector{WebGLExportCase}
    nested::Vector{Vector{UInt8}}
end

function Base.unsafe_write(io::Audit3NestedExportIO, p::Ptr{UInt8}, n::UInt)
    if isempty(io.nested)
        push!(io.nested, UInt8[])
        buffer = IOBuffer()
        Diff3D._web_write_data_json_validated(buffer, io.cases)
        io.nested[1] = take!(buffer)
    end
    return unsafe_write(io.inner, p, n)
end

Base.write(io::Audit3NestedExportIO, byte::UInt8) = write(io.inner, byte)

@testset "export data staging buffer is reused per task" begin
    scene = Scene()
    for i in 1:2
        add!(scene, Mesh(SphereGeometry(radius=1.0, width_segments=16, height_segments=8),
                         MeshBasicMaterial(); name="staged_$i"))
    end
    cases = [WebGLExportCase("staged", "Staged", "", scene; radius=4.0)]
    reference = IOBuffer()
    Diff3D._web_write_data_json_cases(reference, cases)     # unstaged writer
    expected = take!(reference)
    direct = IOBuffer()
    Diff3D._web_write_data_json_validated(direct, cases)
    @test take!(direct) == expected
    # A nested export on the same task must not share the lent buffer.
    nesting = Audit3NestedExportIO(IOBuffer(), cases, Vector{UInt8}[])
    Diff3D._web_write_data_json_validated(nesting, cases)
    @test take!(nesting.inner) == expected
    @test nesting.nested == [expected]
    # The buffer is returned after an error and is per task.
    @test_throws ArgumentError Diff3D._web_write_data_json_validated(
        devnull, [WebGLExportCase("staged", "Staged", "", Scene(); radius=NaN)])
    @test !Diff3D._web_staging_slot().lent
    results = fetch.([Threads.@spawn begin
        buffer = IOBuffer()
        Diff3D._web_write_data_json_validated(buffer, cases)
        take!(buffer)
    end for _ in 1:4])
    @test all(==(expected), results)
    if Base.JLOptions().opt_level > 0
        # The 64 KiB staging buffer used to be allocated by every export.
        @test audit3_staged_export_allocations(cases) < 16_384
    end
end
