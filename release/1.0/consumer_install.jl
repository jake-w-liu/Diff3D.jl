using Pkg

length(ARGS) == 2 || error("usage: consumer_install.jl OUTPUT_DIRECTORY COMMIT_SHA")
output, revision = abspath(ARGS[1]), ARGS[2]
occursin(r"^[0-9a-f]{40}$", revision) || error("COMMIT_SHA must be a full commit ID")
repository = normpath(joinpath(@__DIR__, "..", ".."))
resolved = strip(read(`git -C $repository rev-parse $(revision * "^{commit}")`, String))
resolved == revision || error("requested revision did not resolve exactly")
tree = strip(read(`git -C $repository rev-parse $(revision * "^{tree}")`, String))
mkpath(output)

mktempdir(; prefix="diff3d-consumer-") do environment
    Pkg.activate(environment)
    # Install a committed git tree into package storage, as an independent
    # consumer would. Do not develop the mutable checkout or add its test extras.
    Pkg.add(PackageSpec(url=repository, rev=revision))
    cp(joinpath(environment, "Project.toml"), joinpath(output, "consumer-project.toml"); force=true)
    cp(joinpath(environment, "Manifest.toml"), joinpath(output, "consumer-manifest.toml"); force=true)
    acceptance = joinpath(@__DIR__, "consumer_acceptance.jl")
    command = `$(Base.julia_cmd()) --startup-file=no --check-bounds=yes --project=$environment $acceptance $output $repository $revision $tree`
    load_path = Sys.iswindows() ? "@;@stdlib" : "@:@stdlib"
    run(addenv(command, "JULIA_LOAD_PATH" => load_path))
end
