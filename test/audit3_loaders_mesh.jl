using Test, Diff3D, Base64, SHA

# Regression tests for the loaders-mesh audit (STL/OBJ/PLY/XYZ loaders, image
# writers, and the JPEG decoder). JPEG reference digests are SHA-256 over the
# H x W x 3 UInt8 RGB bytes (row-major, channel-interleaved) produced by
# libjpeg-turbo 3.2.0 `djpeg -pnm` with JSIMD_FORCENONE=1 (the portable C
# path that src/jpeg.jl mirrors). Fixtures were encoded with cjpeg/jpegtran
# 3.2.0 from a synthetic gradient source.

_audit3_jpeg_digest(img) =
    bytes2hex(sha256([img[y, x, c] for y in 1:size(img, 1)
                      for x in 1:size(img, 2) for c in 1:3]))

function _audit3_file(bytes, ext)
    path = tempname() * ext
    write(path, bytes)
    return path
end

# 24x8 grayscale progressive JPEG holding only a DC scan (jpegtran script
# "0: 0 0 0 0;"), so libjpeg's block smoothing interpolates every AC term and
# the DC itself from the 5x5 DC window.
const _AUDIT3_JPEG_DC_ONLY = base64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoM" *
    "DAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wgALCAAIABgBAREA/8QAFQAB" *
    "AQAAAAAAAAAAAAAAAAAABgf/2gAIAQEAAAAAn7Zv/9k=")

@testset "JPEG block smoothing slides each DC window row separately" begin
    # jdcoefct.c decompress_smooth_data "Advance for next column" shifts
    # DC01..DC04 <- DC02..DC05 (and likewise per row); DC05/DC10/... keep
    # their value at the right edge. Shifting the flattened 25-entry window
    # pulled the next row's first DC into the last two block columns.
    img = Diff3D._jpeg_decode_rgb8(_AUDIT3_JPEG_DC_ONLY)
    @test size(img) == (8, 24, 3)
    @test _audit3_jpeg_digest(img) ==
          "0490e1ff73079e04aadf16aab216a251d04eae001fa95354f758bff2fcc1aeeb"
end
