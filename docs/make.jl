using Documenter
using Three

gallery_output = joinpath(@__DIR__, "src", "assets", "gallery", "example_gallery.html")
include(joinpath(@__DIR__, "..", "examples", "example_gallery.jl"))
main(output_path=gallery_output)

makedocs(
    sitename = "Three.jl",
    modules = [Three],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        size_threshold_warn = 400_000,
        size_threshold = 400_000,
    ),
    pages = [
        "Home" => "index.md",
        "Example Gallery" => "gallery.md",
        "API Reference" => "api.md",
        "Publication Audit" => "audit.md",
    ],
    checkdocs = :exports,
    doctest = true,
    warnonly = false,
)

if get(ENV, "CI", "false") == "true"
    deploydocs(
        repo = "github.com/jake-w-liu/Three.jl.git",
        devbranch = "main",
        devurl = "stable",
    )
end
