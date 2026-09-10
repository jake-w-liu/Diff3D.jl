using Test
using Diff3D

@testset "ASCII loader decimal conversion" begin
    literals = ["10e-324", "0.1e309", "-0.1e309", "1.2345678901234567",
                "0.10000000000000001", "9007199254740993", "-0", "-0.0e123",
                "+.125", "12.", "1.7976931348623157e308", "2.2250738585072014e-308",
                "4.9406564584124654e-324", "1" * repeat("0", 400) * "e-400",
                "0." * repeat("0", 400) * "1e401"]
    # Exercise correctly rounded ordinary mantissas across the exponent range.
    for mantissa in ("1.2345678901234567", "7.0000000000000001", "9.999999999999998"),
        exponent in (-320, -200, -10, 0, 10, 200, 306)
        push!(literals, mantissa * "e" * string(exponent))
    end
    expected = parse.(Float64, literals)
    function ply_document(tokens)
        return "ply\nformat ascii 1.0\nelement vertex $(length(tokens))\n" *
               "property double x\nproperty double y\nproperty double z\nend_header\n" *
               join(("$token 0 0" for token in tokens), "\n")
    end
    xyz = join(("$token 0 0" for token in literals), "\r\n")
    for text in (xyz, SubString("prefix" * xyz * "suffix", 7, 6 + ncodeunits(xyz)))
        actual = parse_xyz(text).positions[1:3:end]
        @test reinterpret(UInt64, actual) == reinterpret(UInt64, expected)
    end
    mktempdir() do directory
        path = joinpath(directory, "numbers.ply")
        write(path, ply_document(literals))
        actual = load_ply(path).positions[1:3:end]
        @test reinterpret(UInt64, actual) == reinterpret(UInt64, expected)

        for token in ("0e99999", "-0e99999", "1e-99999", "-1e-99999",
                      "0." * repeat("0", 400) * "1")
            reference = Float64(parse(BigFloat, token))
            actual = parse_xyz("0 0 " * token).positions[3]
            @test isequal(actual, reference)
            write(path, ply_document([token]))
            @test isequal(load_ply(path).positions[1], reference)
        end

        for token in ("nan", "NaN", "+Inf", "-INFINITY", "1e309", "-1e99999")
            @test_throws "XYZ line 1 has non-finite z value" parse_xyz("0 0 " * token)
            write(path, ply_document([token]))
            @test_throws "PLY vertex row 1 property x must be finite" load_ply(path)
        end
        for token in (".", "+", "-.", "1e", "1e+", "1ee2", "1_000", "0x1p0",
                      "1.2.3", "nan(1)", "1\0", "1é")
            @test_throws "XYZ line 1 has invalid z value" parse_xyz("0 0 " * token)
            write(path, ply_document([token]))
            @test_throws "PLY vertex row 1 property x must be a number" load_ply(path)
        end
    end

    token = "1.2345678901234567"
    interleaved = collect(codeunits(join(collect(token), "x")))
    for bytes in (codeunits(token), collect(codeunits(token)),
                  view(interleaved, 1:2:length(interleaved)))
        @test Diff3D._xyz_parse_float(bytes, 1, length(bytes), 1, "x") == parse(Float64, token)
    end
end
