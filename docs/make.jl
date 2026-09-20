using Documenter
using Diff3D

documentation_ref = get(ENV, "GITHUB_REF", "")
if startswith(documentation_ref, "refs/tags/v")
    tag_version = VersionNumber(chopprefix(documentation_ref, "refs/tags/v"))
    tag_version == pkgversion(Diff3D) ||
        error("Documentation tag version $tag_version does not match installed Diff3D $(pkgversion(Diff3D))")
end

gallery_output = joinpath(@__DIR__, "src", "assets", "gallery", "example_gallery.html")
include(joinpath(@__DIR__, "..", "examples", "example_gallery.jl"))
main(output_path=gallery_output)

makedocs(
    sitename = "Diff3D.jl",
    modules = [Diff3D],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        size_threshold_warn = 400_000,
        size_threshold = 400_000,
    ),
    pages = [
        "Home" => "index.md",
        "Example Gallery" => "gallery.md",
        "Compatibility" => "compatibility.md",
        "API Reference" => "api.md",
        "Publication Audit" => "audit.md",
    ],
    checkdocs = :exports,
    doctest = true,
    warnonly = false,
)

if get(ENV, "DOCUMENTER_DEPLOY", "false") == "true"
    deploydocs(
        repo = "github.com/jake-w-liu/Diff3D.jl.git",
        devbranch = "main",
        devurl = "dev",
        versions = ["stable" => "v^", "v#.#", "dev" => "dev"],
    )
end
