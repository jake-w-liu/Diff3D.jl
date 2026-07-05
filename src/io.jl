# --------------------------------------------------------------------------
# Image I/O: export rendered images to PPM (no external deps) and PNG.
# --------------------------------------------------------------------------

# Map a pixel value to [0,1], treating NaN as 0 (black). clamp() propagates NaN
# (clamp(NaN,0,1)==NaN), so round(UInt8/Int/UInt16, NaN*scale) would throw an
# InexactError; this matches render_to_rgb8's NaN convention so a frame holding
# a stray NaN exports as black instead of crashing the writer.
@inline _clamp01(v) = (x = Float64(v); isnan(x) ? 0.0 : clamp(x, 0.0, 1.0))

function _image_size_and_channels(img::AbstractArray, label::String)
    nd = ndims(img)
    (nd == 2 || nd == 3) ||
        throw(ArgumentError("$label must be a 2-D grayscale image or a 3-D H×W×C image"))
    H, W = size(img, 1), size(img, 2)
    (H > 0 && W > 0) || throw(ArgumentError("$label dimensions must be positive"))
    C = nd == 2 ? 1 : size(img, 3)
    C >= 1 || throw(ArgumentError("$label must have at least one channel"))
    return H, W, C
end

function _checked_positive_finite_number(value, label::String)
    value isa Bool && throw(ArgumentError("$label must be a finite positive number"))
    x = try
        Float64(value)
    catch
        throw(ArgumentError("$label must be a finite positive number"))
    end
    (isfinite(x) && x > 0) || throw(ArgumentError("$label must be a finite positive number"))
    return x
end

"""
Save image as PPM (Portable Pixmap) — no dependencies needed.
`image` is Array{T, 3} of size (H, W, 3), values in [0,1].
"""
function save_ppm(filename::String, image::Array{T, 3}) where T
    H, W, C = _image_size_and_channels(image, "PPM image")
    gi = C >= 3 ? 2 : 1   # broadcast channel 1 across RGB for a <3-channel (grayscale) image
    bi = C >= 3 ? 3 : 1
    open(filename, "w") do f
        println(f, "P3")
        println(f, "$W $H")
        println(f, "255")
        for i in 1:H
            for j in 1:W
                r = round(Int, _clamp01(image[i, j, 1]) * 255)
                g = round(Int, _clamp01(image[i, j, gi]) * 255)
                b = round(Int, _clamp01(image[i, j, bi]) * 255)
                print(f, "$r $g $b ")
            end
            println(f)
        end
    end
    return filename
end

"""
Save image as raw binary PPM (P6 format) — more compact.
"""
function save_ppm_binary(filename::String, image::Array{T, 3}) where T
    H, W, C = _image_size_and_channels(image, "PPM image")
    gi = C >= 3 ? 2 : 1   # broadcast channel 1 across RGB for a <3-channel (grayscale) image
    bi = C >= 3 ? 3 : 1
    open(filename, "w") do f
        write(f, "P6\n$W $H\n255\n")
        for i in 1:H
            for j in 1:W
                r = UInt8(round(Int, _clamp01(image[i, j, 1]) * 255))
                g = UInt8(round(Int, _clamp01(image[i, j, gi]) * 255))
                b = UInt8(round(Int, _clamp01(image[i, j, bi]) * 255))
                write(f, r)
                write(f, g)
                write(f, b)
            end
        end
    end
    return filename
end

"""
Convert render target to image array (H × W × 3, Float64 in [0,1]).
"""
function render_target_to_image(rt::RenderTarget)
    return copy(rt.color)
end

"""
Create a simple test pattern image for validation.
"""
function test_pattern(width::Int, height::Int)
    (width > 0 && height > 0) || throw(ArgumentError("test_pattern dimensions must be positive"))
    img = Array{Float64}(undef, height, width, 3)
    # max(.,1) keeps the gradient finite for a 1-wide or 1-tall image (where the
    # single pixel sits at gradient endpoint 0.0) instead of yielding 0/0 = NaN.
    wden = max(width - 1, 1)
    hden = max(height - 1, 1)
    for j in 1:width
        for i in 1:height
            img[i, j, 1] = (j - 1) / wden    # red gradient horizontal
            img[i, j, 2] = (i - 1) / hden    # green gradient vertical
            img[i, j, 3] = 0.5                # constant blue
        end
    end
    return img
end

# --------------------------------------------------------------------------
# Self-contained PNG and PDF export (no external image packages).
# A render produces an H×W×3 array in [0,1]; these writers encode it to a
# publication-grade PNG (8-bit RGB) or a single-page PDF (image XObject) with
# only Base + Printf. PNG uses a valid zlib/DEFLATE stream built from stored
# (uncompressed) blocks, so the files open in any standard viewer/LaTeX.
# --------------------------------------------------------------------------

@inline _be32(x::Integer) = UInt8[(x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff]

@inline function _write_be32(io::IO, x::Integer)
    write(io, UInt8((x >> 24) & 0xff))
    write(io, UInt8((x >> 16) & 0xff))
    write(io, UInt8((x >> 8) & 0xff))
    write(io, UInt8(x & 0xff))
    return nothing
end

# Coerce an image (Float in [0,1] or UInt8) to a UInt8 RGB array. A grayscale or
# luminance(+alpha) image (1 or 2 channels) broadcasts its first channel across
# RGB instead of reading past the end of a hardcoded 3-channel loop.
function image_to_uint8(img::AbstractArray)
    H, W, C = _image_size_and_channels(img, "image")
    isgray2d = ndims(img) == 2
    eltype(img) === UInt8 && C == 3 && !isgray2d && return img
    isu8 = eltype(img) === UInt8
    out = Array{UInt8}(undef, H, W, 3)
    @inbounds for j in 1:W, i in 1:H, c in 1:3
        sc = C >= 3 ? c : 1     # broadcast channel 1 for <3-channel (grayscale) input
        v = isgray2d ? img[i, j] : img[i, j, sc]
        out[i, j, c] = isu8 ? UInt8(v) : round(UInt8, _clamp01(v) * 255)
    end
    return out
end
image_to_uint8(rt::RenderTarget) = image_to_uint8(rt.color)

const _CRC32_TABLE = let tbl = Vector{UInt32}(undef, 256)
    for n in 0:255
        c = UInt32(n)
        for _ in 1:8
            c = (c & 0x00000001) != 0 ? (0xedb88320 ⊻ (c >> 1)) : (c >> 1)
        end
        tbl[n + 1] = c
    end
    tbl
end

function _crc32_update(c::UInt32, data)
    @inbounds for b in data
        c = _CRC32_TABLE[((c ⊻ UInt32(b)) & 0xff) + 1] ⊻ (c >> 8)
    end
    return c
end

@inline _crc32_update_byte(c::UInt32, byte::UInt8) =
    _CRC32_TABLE[((c ⊻ UInt32(byte)) & 0xff) + 1] ⊻ (c >> 8)

_crc32_finish(c::UInt32) = c ⊻ UInt32(0xffffffff)

function _crc32(data)
    c = _crc32_update(UInt32(0xffffffff), data)
    return _crc32_finish(c)
end

function _crc32_concat(a, b)
    c = _crc32_update(UInt32(0xffffffff), a)
    c = _crc32_update(c, b)
    return _crc32_finish(c)
end

function _adler32(data)
    a = UInt32(1)
    b = UInt32(0)
    @inbounds for byte in data
        a = (a + UInt32(byte)) % 65521
        b = (b + a) % 65521
    end
    return (b << 16) | a
end

@inline function _adler32_update_byte(a::UInt32, b::UInt32, byte::UInt8)
    a = (a + UInt32(byte)) % UInt32(65521)
    b = (b + a) % UInt32(65521)
    return a, b
end

# Wrap raw bytes in a zlib stream using DEFLATE stored (BTYPE=00) blocks.
function _zlib_store(data::Vector{UInt8})
    out = UInt8[]
    push!(out, 0x78, 0x01)            # zlib header: CM=8, CINFO=7, FCHECK
    n = length(data)
    pos = 1
    if n == 0
        # Empty input still needs one final empty stored block (BFINAL=1,BTYPE=00,
        # LEN=0,NLEN=~0); otherwise the stream has no BFINAL flag and standard
        # zlib decoders reject it as truncated.
        push!(out, 0x01, 0x00, 0x00, 0xff, 0xff)
    end
    while pos <= n
        block = min(65535, n - pos + 1)
        final = (pos + block - 1) >= n
        push!(out, final ? 0x01 : 0x00)
        push!(out, UInt8(block & 0xff), UInt8((block >> 8) & 0xff))
        nlen = UInt16(block) ⊻ 0xffff
        push!(out, UInt8(nlen & 0xff), UInt8((nlen >> 8) & 0xff))
        append!(out, @view data[pos:(pos + block - 1)])
        pos += block
    end
    ad = _adler32(data)
    append!(out, _be32(ad))           # Adler32, big-endian
    return out
end

function _png_chunk(io::IO, ctype::String, data::Vector{UInt8})
    _write_be32(io, length(data))
    tb = codeunits(ctype)
    write(io, tb)
    write(io, data)
    _write_be32(io, _crc32_concat(tb, data))
    return nothing
end

@inline function _png_write_crc_byte(io::IO, byte::UInt8, crc::UInt32)
    write(io, byte)
    return _crc32_update_byte(crc, byte)
end

function _png_write_crc_adler_slice(io::IO, data::Vector{UInt8}, pos::Int,
                                    len::Int, crc::UInt32,
                                    adler_a::UInt32, adler_b::UInt32)
    @inbounds for k in pos:(pos + len - 1)
        byte = data[k]
        crc = _crc32_update_byte(crc, byte)
        adler_a, adler_b = _adler32_update_byte(adler_a, adler_b, byte)
    end
    GC.@preserve data unsafe_write(io, pointer(data, pos), len)
    return crc, adler_a, adler_b
end

@inline _zlib_store_length(raw_len::Int) =
    2 + (raw_len == 0 ? 1 : cld(raw_len, 65535)) * 5 + raw_len + 4

@inline _png_u8(v, isu8::Bool) =
    isu8 ? UInt8(v) : round(UInt8, _clamp01(v) * 255)

function _png_fill_rgb_scanline!(line::Vector{UInt8}, img::AbstractArray,
                                 row::Int, width::Int, channels::Int,
                                 isgray2d::Bool, isu8::Bool)
    line[1] = 0x00
    k = 2
    if isgray2d
        @inbounds for col in 1:width
            px = _png_u8(img[row, col], isu8)
            line[k] = px
            line[k + 1] = px
            line[k + 2] = px
            k += 3
        end
    elseif channels >= 3
        @inbounds for col in 1:width
            line[k] = _png_u8(img[row, col, 1], isu8)
            line[k + 1] = _png_u8(img[row, col, 2], isu8)
            line[k + 2] = _png_u8(img[row, col, 3], isu8)
            k += 3
        end
    else
        @inbounds for col in 1:width
            px = _png_u8(img[row, col, 1], isu8)
            line[k] = px
            line[k + 1] = px
            line[k + 2] = px
            k += 3
        end
    end
    return line
end

function _png_fill_rgba_scanline!(line::Vector{UInt8}, img::AbstractArray,
                                  row::Int, width::Int, isu8::Bool)
    line[1] = 0x00
    k = 2
    @inbounds for col in 1:width
        line[k] = _png_u8(img[row, col, 1], isu8)
        line[k + 1] = _png_u8(img[row, col, 2], isu8)
        line[k + 2] = _png_u8(img[row, col, 3], isu8)
        line[k + 3] = _png_u8(img[row, col, 4], isu8)
        k += 4
    end
    return line
end

@inline _png_u16(v) = round(UInt16, _clamp01(v) * 65535)

function _png_fill_gray16_scanline!(line::Vector{UInt8}, img::AbstractArray,
                                    row::Int, width::Int, isgray3d::Bool)
    line[1] = 0x00
    k = 2
    if isgray3d
        @inbounds for col in 1:width
            v = _png_u16(img[row, col, 1])
            line[k] = UInt8(v >> 8)
            line[k + 1] = UInt8(v & 0xff)
            k += 2
        end
    else
        @inbounds for col in 1:width
            v = _png_u16(img[row, col])
            line[k] = UInt8(v >> 8)
            line[k + 1] = UInt8(v & 0xff)
            k += 2
        end
    end
    return line
end

function _png_write_idat_scanlines(fill_scanline!::F, io::IO, height::Int,
                                   line::Vector{UInt8}) where {F}
    raw_len = height * length(line)
    _write_be32(io, _zlib_store_length(raw_len))
    tb = codeunits("IDAT")
    write(io, tb)
    crc = _crc32_update(UInt32(0xffffffff), tb)

    crc = _png_write_crc_byte(io, 0x78, crc)
    crc = _png_write_crc_byte(io, 0x01, crc)

    remaining = raw_len
    block_remaining = 0
    adler_a = UInt32(1)
    adler_b = UInt32(0)

    for row in 1:height
        fill_scanline!(line, row)
        pos = 1
        line_remaining = length(line)
        while line_remaining > 0
            if block_remaining == 0
                block = min(65535, remaining)
                final = block == remaining
                crc = _png_write_crc_byte(io, final ? 0x01 : 0x00, crc)
                crc = _png_write_crc_byte(io, UInt8(block & 0xff), crc)
                crc = _png_write_crc_byte(io, UInt8((block >> 8) & 0xff), crc)
                nlen = UInt16(block) ⊻ 0xffff
                crc = _png_write_crc_byte(io, UInt8(nlen & 0xff), crc)
                crc = _png_write_crc_byte(io, UInt8((nlen >> 8) & 0xff), crc)
                block_remaining = block
            end
            n = min(line_remaining, block_remaining)
            crc, adler_a, adler_b =
                _png_write_crc_adler_slice(io, line, pos, n, crc, adler_a, adler_b)
            pos += n
            line_remaining -= n
            block_remaining -= n
            remaining -= n
        end
    end

    adler = (adler_b << 16) | adler_a
    crc = _png_write_crc_byte(io, UInt8((adler >> 24) & 0xff), crc)
    crc = _png_write_crc_byte(io, UInt8((adler >> 16) & 0xff), crc)
    crc = _png_write_crc_byte(io, UInt8((adler >> 8) & 0xff), crc)
    crc = _png_write_crc_byte(io, UInt8(adler & 0xff), crc)
    _write_be32(io, _crc32_finish(crc))
    return nothing
end

function _png_write_idat_rgb(io::IO, img::AbstractArray, height::Int, width::Int,
                             channels::Int, isgray2d::Bool, isu8::Bool)
    line = Vector{UInt8}(undef, 1 + width * 3)
    return _png_write_idat_scanlines(io, height, line) do dst, row
        _png_fill_rgb_scanline!(dst, img, row, width, channels, isgray2d, isu8)
    end
end

function _png_write_idat_rgba(io::IO, img::AbstractArray, height::Int,
                              width::Int, isu8::Bool)
    line = Vector{UInt8}(undef, 1 + width * 4)
    return _png_write_idat_scanlines(io, height, line) do dst, row
        _png_fill_rgba_scanline!(dst, img, row, width, isu8)
    end
end

function _png_write_idat_gray16(io::IO, img::AbstractArray, height::Int,
                                width::Int, isgray3d::Bool)
    line = Vector{UInt8}(undef, 1 + width * 2)
    return _png_write_idat_scanlines(io, height, line) do dst, row
        _png_fill_gray16_scanline!(dst, img, row, width, isgray3d)
    end
end

"""
    save_png(filename, img)

Write an H×W×3 image (Float in [0,1], UInt8, or a `RenderTarget`) as an 8-bit
RGB PNG. Pure Julia; no external dependencies.
"""
function save_png(filename::String, img::AbstractArray)
    H, W, C = _image_size_and_channels(img, "image")
    isgray2d = ndims(img) == 2
    isu8 = eltype(img) === UInt8
    open(filename, "w") do io
        write(io, UInt8[137, 80, 78, 71, 13, 10, 26, 10])   # PNG signature
        ihdr = UInt8[]
        append!(ihdr, _be32(W)); append!(ihdr, _be32(H))
        push!(ihdr, 0x08, 0x02, 0x00, 0x00, 0x00)           # 8-bit, RGB, deflate, no filter/interlace
        _png_chunk(io, "IHDR", ihdr)
        _png_write_idat_rgb(io, img, H, W, C, isgray2d, isu8)
        _png_chunk(io, "IEND", UInt8[])
    end
    return filename
end
save_png(filename::String, rt::RenderTarget) = save_png(filename, rt.color)

"""
    save_png_rgba(filename, img)

Write an H×W×4 image (Float in [0,1] or UInt8) as an 8-bit RGBA PNG (color type 6).
"""
function save_png_rgba(filename::String, img::AbstractArray)
    H, W, C = _image_size_and_channels(img, "RGBA image")
    C == 4 || throw(ArgumentError("save_png_rgba expects an H×W×4 image"))
    isu8 = eltype(img) === UInt8
    open(filename, "w") do io
        write(io, UInt8[137,80,78,71,13,10,26,10])
        ihdr = UInt8[]; append!(ihdr, _be32(W)); append!(ihdr, _be32(H))
        push!(ihdr, 0x08, 0x06, 0x00, 0x00, 0x00)   # 8-bit, RGBA
        _png_chunk(io, "IHDR", ihdr)
        _png_write_idat_rgba(io, img, H, W, isu8)
        _png_chunk(io, "IEND", UInt8[])
    end
    return filename
end

"""
    save_png16(filename, img)

Write a 16-bit grayscale PNG from an H×W (or H×W×1) image of values in [0,1].
"""
function save_png16(filename::String, img::AbstractArray)
    H, W, C = _image_size_and_channels(img, "16-bit grayscale image")
    C == 1 || throw(ArgumentError("save_png16 expects an H×W or H×W×1 image"))
    isgray3d = ndims(img) == 3
    open(filename, "w") do io
        write(io, UInt8[137,80,78,71,13,10,26,10])
        ihdr = UInt8[]; append!(ihdr, _be32(W)); append!(ihdr, _be32(H))
        push!(ihdr, 0x10, 0x00, 0x00, 0x00, 0x00)   # 16-bit grayscale
        _png_chunk(io, "IHDR", ihdr)
        _png_write_idat_gray16(io, img, H, W, isgray3d)
        _png_chunk(io, "IEND", UInt8[])
    end
    return filename
end

"""
    save_pdf(filename, img; dpi=144)

Write an H×W×3 image as a single-page PDF whose page holds the rendered frame
as a DeviceRGB image XObject. Page size is `pixels / dpi` inches. Pure Julia.
"""
function save_pdf(filename::String, img::AbstractArray; dpi::Real=144)
    buf = image_to_uint8(img)
    H, W = size(buf, 1), size(buf, 2)
    dpi_value = _checked_positive_finite_number(dpi, "save_pdf dpi")
    rgb = Vector{UInt8}(undef, H * W * 3)         # PDF image samples: top row first
    k = 1
    @inbounds for i in 1:H, j in 1:W
        rgb[k] = buf[i, j, 1]; rgb[k + 1] = buf[i, j, 2]; rgb[k + 2] = buf[i, j, 3]; k += 3
    end
    pw = round(W / dpi_value * 72; digits=2)
    ph = round(H / dpi_value * 72; digits=2)
    content = Vector{UInt8}(codeunits("q $pw 0 0 $ph 0 0 cm /Im0 Do Q"))

    io = IOBuffer()
    off = Dict{Int,Int}()
    write(io, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    off[1] = position(io); write(io, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
    off[2] = position(io); write(io, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")
    off[3] = position(io); write(io, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $pw $ph] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\nendobj\n")
    off[4] = position(io)
    write(io, "4 0 obj\n<< /Type /XObject /Subtype /Image /Width $W /Height $H /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length $(length(rgb)) >>\nstream\n")
    write(io, rgb); write(io, "\nendstream\nendobj\n")
    off[5] = position(io)
    write(io, "5 0 obj\n<< /Length $(length(content)) >>\nstream\n")
    write(io, content); write(io, "\nendstream\nendobj\n")
    xref_pos = position(io)
    write(io, "xref\n0 6\n0000000000 65535 f \n")
    for n in 1:5
        write(io, @sprintf("%010d 00000 n \n", off[n]))
    end
    write(io, "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref_pos\n%%EOF\n")
    open(f -> write(f, take!(io)), filename, "w")
    return filename
end
save_pdf(filename::String, rt::RenderTarget; kwargs...) = save_pdf(filename, rt.color; kwargs...)
