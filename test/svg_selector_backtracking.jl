using Diff3D, Test

@testset "SVG selector alternatives match the complete chain" begin
    cases=Diff3D._json_parse(read(joinpath(@__DIR__,"fixtures","svg_backtracking.json"),String))
    mktempdir() do directory
        path=joinpath(directory,"selectors.svg")
        for case in cases
            @testset "$(case["name"])" begin
                write(path,"<svg><style>rect{fill:blue;}"*case["selector"]*
                    "{fill:red;}</style>"*case["markup"]*"</svg>")
                document=load_svg(path)
                @test length(document.paths)==1
                expected=case["match"] ? Color3(1.0,0.0,0.0) : Color3(0.0,0.0,1.0)
                @test only(document.paths).style.fill==expected
            end
        end
    end
end
