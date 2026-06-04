using Documenter
using Three

makedocs(
    sitename = "Three.jl",
    modules = [Three],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        size_threshold = 400_000,
    ),
    pages = [
        "Home" => "index.md",
        "API Reference" => "api.md",
        "Publication Audit" => "audit.md",
    ],
    checkdocs = :exports,
)
