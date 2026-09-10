using Diff3D, Test

@testset "SVG compound selectors retain Unicode attribute values" begin
    mktempdir() do directory
        path=joinpath(directory,"unicode.svg")
        for value in ("中","é","𝄞","e\u0301","δοκιμή"),suffix in (".a",".hot",":not(.cold)")
            wanted_class=suffix==".a" ? "a" : "hot"
            unwanted_class=suffix==":not(.cold)" ? "cold" : "other"
            document="""
            <svg><style>
              rect { fill: blue; }
              rect[data-label="$value"]$suffix { fill: red; }
            </style>
            <rect data-label="$value" class="$wanted_class" width="1" height="1"/>
            <rect data-label="$value" class="$unwanted_class" x="2" width="1" height="1"/>
            <rect data-label="different" class="$wanted_class" x="4" width="1" height="1"/>
            </svg>
            """
            write(path,document)
            svg=load_svg(path)
            @test length(svg.paths)==3
            @test [shape.style.fill for shape in svg.paths]==
                  [Color3(1.0,0.0,0.0),Color3(0.0,0.0,1.0),Color3(0.0,0.0,1.0)]
        end
    end
end
