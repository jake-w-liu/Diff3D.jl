using Test
using Diff3D

@testset "WebGL export preserves destinations on failure" begin
    mktempdir() do directory
        valid = WebGLExportCase("valid", "Valid", "", Scene())
        unsupported_scene = Scene()
        add!(unsupported_scene, Mesh(BoxGeometry(), ShaderMaterial()))
        unsupported = WebGLExportCase("unsupported", "Unsupported", "", unsupported_scene)
        cases = [valid, unsupported] # Fail after the first case has been serialized.
        path = joinpath(directory, "scene.html")

        @test_throws ArgumentError save_webgl_html(path, cases)
        @test !isfile(path)
        @test isempty(readdir(directory))

        previous = "Previously published scene\n"
        write(path, previous)
        @test_throws ArgumentError save_webgl_html(path, cases)
        @test read(path, String) == previous
        @test readdir(directory) == ["scene.html"]

        @test save_webgl_html(path, [valid]; title="Complete export") == path
        html = read(path, String)
        @test occursin("<title>Complete export</title>", html)
        @test occursin("\"id\":\"valid\"", html)
        @test endswith(strip(html), "</html>")
        @test readdir(directory) == ["scene.html"]

        destination_directory = joinpath(directory, "existing-directory")
        mkdir(destination_directory)
        @test_throws Base.IOError save_webgl_html(destination_directory, [valid])
        @test isdir(destination_directory)
        @test isempty(readdir(destination_directory))
        @test sort(readdir(directory)) == ["existing-directory", "scene.html"]

        if !Sys.iswindows() # Windows symlink creation requires host privileges.
            chmod(path, 0o640)
            save_webgl_html(path, [valid])
            @test filemode(path) & 0o777 == 0o640
            link = joinpath(directory, "linked.html")
            symlink(path, link)
            target_before = read(path)
            @test_throws ArgumentError save_webgl_html(link, cases)
            @test islink(link)
            @test read(path) == target_before
            save_webgl_html(link, [valid]; title="Link replacement")
            @test !islink(link)
            @test read(path) == target_before
            @test occursin("<title>Link replacement</title>", read(link, String))
        end
    end
end
