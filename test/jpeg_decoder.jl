using Diff3D, Test, Base64, SHA

# Reference outputs are SHA-256 digests of the decoded UInt8 RGB planes
# (H×W×3) produced by libjpeg-turbo 3.2.0 for files it decodes; CMYK/YCCK
# digests pin the pure-Julia Adobe conversion path, which has no JpegTurbo
# equivalent.

const _JPEG_FIXTURES = Dict{String,String}(
    # 16x12 baseline, 2x2 sampling
    "base_2x2" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAMABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwA8O/Eqz/swfvF+761x/iX4lWf27769fWvIPDk0n9lj94/3f71cd4lmk+2/6x+v96vt+AuCsJ9Y3P23jbgzCf2RR17H/9k=",
    # 16x12 progressive, 1x1 sampling
    "prog" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wgARCAAMABADAREAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAABQAG/8QAFwEBAQEBAAAAAAAAAAAAAAAABwYECP/aAAwDAQACEAMQAAABpW5HSjrH5+hR0o6//8QAGRAAAgMBAAAAAAAAAAAAAAAAAQQCBRIT/9oACAEBAAEFAl7KHNmyhtcnkyTv/8QAGREAAgMBAAAAAAAAAAAAAAAAAAIBBRME/9oACAEDAQE/AeevbEta9tDnWMS1WND/xAAZEQADAAMAAAAAAAAAAAAAAAAAAgUEERL/2gAIAQIBAT8Bx5zdE2c2jHReiai6P//EABYQAQEBAAAAAAAAAAAAAAAAADEAEP/aAAgBAQAGPwJxm//EABkQAAMAAwAAAAAAAAAAAAAAAAAxQQFRkf/aAAgBAQABPyGaRVwXC2VHT//aAAwDAQACAAMAAAAQIo//xAAXEQADAQAAAAAAAAAAAAAAAAAAEUEh/9oACAEDAQE/EI8H+EeD/D//xAAWEQADAAAAAAAAAAAAAAAAAAAAESH/2gAIAQIBAT8QQQQwSQSw/8QAGBABAAMBAAAAAAAAAAAAAAAAABFRcaH/2gAIAQEAAT8QgehsVogmyn//2Q==",
    # 16x12 baseline, 2x1 sampling, restart interval 1 MCU
    "rst" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAMABADASEAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/90ABAAB/9oADAMBAAIRAxEAPwA8O/Eqz/swfvF+761x/iX4lWf27769fWuXgLh2p9Y2PruNuHqv9kUdOx//0PnDw5NJ/ZY/eP8Ad/vVx3iWaT7b/rH6/wB6v3rgKhT+sbH9W8bUof2RR07H/9k=",
    # 16x12 grayscale
    "gray" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/wAALCAAMABABAREA/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/ADSPEtt9iHzjpWFrPiW2+0/fHWuG0h3+xD526etYWsu/2n77dfWv/9k=",
    # 16x12 baseline, 4x1 sampling (integer-ratio upsampling)
    "s4x1" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAAMABADAUEAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwA8O/Eqz/swfvF+761x/iX4lWf27769fWiivu+A+Han9jx06s8zjjh6r/au32I/keQeHJpP7LH7x/u/3q47xLNJ9t/1j9f71FFf0JwJQp/2PHTqz+gOOKUP7V2+xH8j/9k=",
    # 16x12 baseline, RGB color space (Adobe APP14 transform 0)
    "rgb" => "/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgICAgIDAgICAwMDAwQGBAQEBAQIBgYFBgkICgoJCAkJCgwPDAoLDgsJCQ0RDQ4PEBAREAoMEhMSEBMPEBAQ/8AAEQgADAAQA1IRAEcRAEIRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAAwDUgBHAEIAAD8A+ofhfpv/ABb5fl/5Y/0riv8AhpDQf+fqP8xXzX8JPCP+p/denavgz9p7Tf8Airn+X/lp/Wj/AIaQ0H/n6j/MV9q/CTwj/qf3Xp2r9F/hfBH/AMK+X5f+WP8ASvzn/tG//wCf2b/vs14J8JNNtP3P7v0r4M/aegj/AOEuf5f+Wn9aP7Rv/wDn9m/77Nfavwk020/c/u/Sv//Z",
    # 16x12 progressive with DC successive approximation (Ah/Al refinement)
    "scans" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wgARCAAMABADAREAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAABAAF/9oACAEBAAAAAoeOP//EABcBAQEBAQAAAAAAAAAAAAAAAAgHBQn/2gAKAgIQAxAAAACV3NKHTP6FpQ6f/9oACAEBAAAAIQ//2gAIAQEAAAAQL//EACIQAAAEBQUBAAAAAAAAAAAAAAACAwYBBAcUMhUjMVFSM//aAAgBAQABPwBu1Kk9MhuFx7DlqVJ32Zeew3FlNLhuHx9ByrKXv0Pz6H//xAAbEQABBAMAAAAAAAAAAAAAAAADAAEGIQUSE//aAAgBAgEBPwDHx0nRqUbjpNGpY8A+jUo2AejUv//EAB0RAAAFBQAAAAAAAAAAAAAAAAABAwYUAgUhMUH/2gAIAQMBAT8At7eVha4HW3lZJ4FvSoha4HWlRJPA/9k=",
    # 16x12 Adobe CMYK (APP14 transform 0)
    "cmyk" => "/9j/7gAOQWRvYmUAZAAAAAAA/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAFAgADAAQBEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4EQwBNAFkASwAAPwD6h+F+m/8AFvl4/wCWX9K4r/hpDS/+e6fnXzX8JPCP+p+T07V+qdfBn7T2m/8AFXPx/HR/w0hpf/PdPzr7V+EnhH/U/J6dqK/Rf4XwJ/wr5eP+WX9K/Of+0br/AJ+Jf++zXgnwk02D9z8npRXwZ+09An/CXPx/HR/aN1/z8S/99mvtX4SabB+5+T0or//Z",
    # 16x12 Adobe YCCK (APP14 transform 2)
    "ycck" => "/9j/7gAOQWRvYmUAZAAAAAAC/9sAQwADAgIDAgIDAwMDBAMDBAUIBQUEBAUKBwcGCAwKDAwLCgsLDQ4SEA0OEQ4LCxAWEBETFBUVFQwPFxgWFBgSFBUU/8AAFAgADAAQBEMRAE0RAFkRAEsRAP/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/aAA4EQwBNAFkASwAAPwD6h+F+m/8AFvl4/wCWX9K4r/hpDS/+e6fnXzX8JPCP+p+T07V+qdfBn7T2m/8AFXPx/HR/w0hpf/PdPzr7V+EnhH/U/J6dqK/Rf4XwJ/wr5eP+WX9K/Of+0br/AJ+Jf++zXgnwk02D9z8npRXwZ+09An/CXPx/HR/aN1/z8S/99mvtX4SabB+5+T0or//Z",
    # truncated mid-scan progressive stream
    "trunc" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wgARCAAMABADAREAAhEBAxEB/8QAFgABAQEAAAAAAAAAAAAAAAAABQAG/8QAFwEBAQEBAAAAAAAAAAAAAAAABwYECP/aAAwDAQACEAMQAAABpW5HSjrH5+hR0o6//8QAGRAAAgMBAAAAAAAAAAAAAAAAAQQCBRIT/9oACAEBAAEFAl7KHNmyhtcnkyTv/8QAGREAAgMBAAAAAAAAAAAAAAAAAAIBBRME/9oACAEDAQE/AeevbEta9tDnWMS1WND/xAAZEQADAAMAAAAAAAAAAAAAAAAAAgUEERL/2gAIAQIBAT8Bx5zdE2c2jHReiai6P//EABYQAQEBAAAAAAAAAAA=",
    # 16x12 arithmetic coding (SOF9) — unsupported
    "arith" => "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAUDBAQEAwUEBAQFBQUGBwwIBwcHBw8LCwkMEQ8SEhEPERETFhwXExQaFRERGCEYGh0dHx8fExciJCIeJBweHx7/2wBDAQUFBQcGBw4ICA4eFBEUHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh7/yQARCAAMABADASIAAhEBAxEB/8wACgAQEAUBEBEF/9oADAMBAAIRAxEAPwCdWzlWg/saS3F2Vb/mNlnHGn5EM4XpU2TjejrgPz5ikjgSd4NS13ljSlMEzwL/2Q==",
)

# sha256 of the UInt8 RGB plane bytes for each fixture, generated with
# libjpeg-turbo 3.2.0 (djpeg) where it supports the colorspace.
const _JPEG_FIXTURE_SHA256 = Dict{String,String}(
    "base_2x2" => "d752361bb8df8206f3f3f8f167d00964a714834da106c8c5d36fa64de7d2c480",
    "prog"     => "0760bb4228e17247bfbad69b80287a12e00eac5fab771c20bf939ee691ebf994",
    "rst"      => "6678743fe22346524b88f61069348a76becbfad028e282412600b4e6a9e126f1",
    "gray"     => "6e63c6b19d95c5ef519c87d9b5de4879b8355f9fb07307af624a1b3e97c95ed1",
    "s4x1"     => "7d3d52eb7c85ac83ed6f6bd6d0c95614ea042e16409f46996a518f7fcff01547",
    "rgb"      => "67c9358d8e9e5fdb4edf1fc22014dd36c985541601f5c97ae59faf0c25d4b3a6",
    "scans"    => "0760bb4228e17247bfbad69b80287a12e00eac5fab771c20bf939ee691ebf994",
    "cmyk"     => "147d91c99b0fb805c8ba6019a5b0921f844a4053285a3eab58189942a0743102",
    "ycck"     => "fb3488a492d1766eb9322b00f622ebb34b2eef39833b86662f1c96a2fa5deb7d",
)

_jpeg_fixture(name) = base64decode(_JPEG_FIXTURES[name])
# Digest over bytes in row-major, channel-interleaved (PPM) order.
function _jpeg_digest(img)
    H, W = size(img, 1), size(img, 2)
    bytes2hex(sha256([img[y, x, c] for y in 1:H for x in 1:W for c in 1:3]))
end

@testset "JPEG decoder produces reference RGB bytes" begin
    for name in ("base_2x2", "prog", "rst", "gray", "s4x1", "rgb", "scans",
                 "cmyk", "ycck")
        img = Diff3D._jpeg_decode_rgb8(_jpeg_fixture(name))
        @test size(img) == (12, 16, 3)
        @test _jpeg_digest(img) == _JPEG_FIXTURE_SHA256[name]
    end
    # The successive-approximation script and default progressive encoding of
    # the same source must decode to identical pixels.
    @test Diff3D._jpeg_decode_rgb8(_jpeg_fixture("scans")) ==
          Diff3D._jpeg_decode_rgb8(_jpeg_fixture("prog"))
end

@testset "JPEG decoder public path and Float64 output" begin
    img = Diff3D._decode_jpeg(_jpeg_fixture("base_2x2"); label="test JPEG")
    @test size(img) == (12, 16, 3)
    @test img isa Array{Float64,3}
    raw = Diff3D._jpeg_decode_rgb8(_jpeg_fixture("base_2x2"))
    @test img == Float64.(raw) ./ 255.0
    mktempdir() do dir
        path = joinpath(dir, "tiny.jpg")
        write(path, _jpeg_fixture("base_2x2"))
        @test load_jpeg(path) == img
        @test load_image(path) == img
    end
end

@testset "JPEG decoder rejects unsupported and corrupt data" begin
    @test_throws ErrorException Diff3D._jpeg_decode_rgb8(_jpeg_fixture("arith"))
    @test_throws ErrorException Diff3D._jpeg_decode_rgb8(_jpeg_fixture("trunc"))
    @test_throws ErrorException Diff3D._jpeg_decode_rgb8(UInt8[])
    @test_throws ErrorException Diff3D._jpeg_decode_rgb8(zeros(UInt8, 64))
    @test_throws ErrorException Diff3D._jpeg_decode_rgb8(
        _jpeg_fixture("base_2x2")[1:end-3])
    # wrapping contract: public loader labels the failure
    err = try
        Diff3D._decode_jpeg(_jpeg_fixture("trunc"); label="mylabel")
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("mylabel could not be decoded", sprint(showerror, err))
end

@testset "JPEG giant declared dimensions fail fast" begin
    # Forging a 65500x65500 SOF must error before the decoder allocates
    # image-sized buffers: the first scan's blocks cannot fit in the bytes
    # that follow the SOS header.
    forged = copy(_jpeg_fixture("base_2x2"))
    sof = findfirst(i -> forged[i] == 0xFF && forged[i + 1] == 0xC0,
                    1:(length(forged) - 1))
    forged[sof + 5] = 0xFF; forged[sof + 6] = 0xDC   # H = 65500
    forged[sof + 7] = 0xFF; forged[sof + 8] = 0xDC   # W = 65500
    Diff3D._jpeg_decode_rgb8(_jpeg_fixture("base_2x2"))  # warm the code path
    t = @elapsed begin
        err = try
            Diff3D._jpeg_decode_rgb8(forged)
            nothing
        catch e
            e
        end
    end
    @test err isa ErrorException
    @test occursin("truncated or corrupt", sprint(showerror, err))
    @test t < 1.0
    alloc = @allocated try
        Diff3D._jpeg_decode_rgb8(forged)
    catch
    end
    @test alloc < 1_000_000
end

@testset "JPEG decode allocation is output-bound" begin
    bytes = _jpeg_fixture("base_2x2")
    Diff3D._decode_jpeg(bytes; label="warmup")  # warm the code path
    out = Diff3D._decode_jpeg(bytes; label="warmup")
    # ~12x16x3 Float64 output plus the decoder's small band buffers.
    @test (@allocated(Diff3D._decode_jpeg(bytes; label="pin")) <=
           sizeof(out) + 65536)
end

@testset "JPEG N0f8 conversion table is exact" begin
    # Float64(N0f8(v)) reduces to v/255 exactly for all 256 byte values; the
    # loader must keep that identity so decoded pixels are bit-identical to the
    # previous JpegTurbo-backed path.
    for v in 0:255
        @test Diff3D._JPEG_N0F8_TO_FLOAT64[v+1] === Float64(v) / 255.0
    end
end
