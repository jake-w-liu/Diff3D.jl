using Test, Diff3D, SHA

# ---------------------------------------------------------------------------
# DEFLATE stream writer for hand-built test streams (RFC 1951). Bits are packed
# LSB-first; Huffman codes are packed starting from their most significant bit.
# ---------------------------------------------------------------------------
mutable struct Audit3BitWriter
    bytes::Vector{UInt8}
    acc::UInt64
    n::Int
end
Audit3BitWriter() = Audit3BitWriter(UInt8[], UInt64(0), 0)

function audit3_put!(w::Audit3BitWriter, value::Integer, nbits::Integer)
    for i in 0:(nbits - 1)
        w.acc |= UInt64((value >> i) & 1) << w.n
        w.n += 1
        if w.n == 8
            push!(w.bytes, UInt8(w.acc))
            w.acc = 0
            w.n = 0
        end
    end
    return w
end

audit3_put_code!(w::Audit3BitWriter, code::Integer, len::Integer) =
    audit3_put!(w, bitreverse(UInt16(code)) >> (16 - len), len)

function audit3_finish(w::Audit3BitWriter)
    w.n > 0 && push!(w.bytes, UInt8(w.acc))
    return w.bytes
end

# Canonical codes for per-symbol lengths (RFC 1951 §3.2.2).
function audit3_canonical(lengths::Vector{Int})
    bl_count = zeros(Int, 16)
    for l in lengths
        l > 0 && (bl_count[l] += 1)
    end
    next = zeros(Int, 16)
    code = 0
    for bits in 1:15
        code = (code + (bits == 1 ? 0 : bl_count[bits - 1])) << 1
        next[bits] = code
    end
    codes = zeros(Int, length(lengths))
    for (i, l) in enumerate(lengths)
        if l > 0
            codes[i] = next[l]
            next[l] += 1
        end
    end
    return codes
end

const AUDIT3_LEN_BASE = (3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258)
const AUDIT3_LEN_EXTRA = (0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0)
const AUDIT3_DIST_BASE = (1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577)
const AUDIT3_DIST_EXTRA = (0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13)

# One dynamic-Huffman block. `items` are byte literals or `(length, distance)`
# pairs; the end-of-block code is appended. The code-length code gives the 16
# literal lengths 0-15 four bits each (a complete code) and no repeat codes.
function audit3_dynamic_block!(w::Audit3BitWriter, lit_lengths::Vector{Int},
                               dist_lengths::Vector{Int}, items; final::Bool=true,
                               emit_eob::Bool=true)
    audit3_put!(w, final ? 1 : 0, 1)
    audit3_put!(w, 2, 2)
    audit3_put!(w, length(lit_lengths) - 257, 5)
    audit3_put!(w, length(dist_lengths) - 1, 5)
    audit3_put!(w, 19 - 4, 4)
    order = (16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15)
    cl_lengths = [s <= 15 ? 4 : 0 for s in 0:18]
    for s in order
        audit3_put!(w, cl_lengths[s + 1], 3)
    end
    cl_codes = audit3_canonical(cl_lengths)
    for l in vcat(lit_lengths, dist_lengths)
        audit3_put_code!(w, cl_codes[l + 1], 4)
    end
    lit_codes = audit3_canonical(lit_lengths)
    dist_codes = audit3_canonical(dist_lengths)
    for item in items
        if item isa Integer
            audit3_put_code!(w, lit_codes[item + 1], lit_lengths[item + 1])
        else
            n, d = item
            li = findlast(<=(n), AUDIT3_LEN_BASE)
            n == 258 && (li = 29)
            sym = 256 + li
            audit3_put_code!(w, lit_codes[sym + 1], lit_lengths[sym + 1])
            audit3_put!(w, n - AUDIT3_LEN_BASE[li], AUDIT3_LEN_EXTRA[li])
            di = findlast(<=(d), AUDIT3_DIST_BASE)
            audit3_put_code!(w, dist_codes[di], dist_lengths[di])
            audit3_put!(w, d - AUDIT3_DIST_BASE[di], AUDIT3_DIST_EXTRA[di])
        end
    end
    emit_eob && audit3_put_code!(w, lit_codes[257], lit_lengths[257])
    return w
end

function audit3_dynamic_stream(lit_lengths, dist_lengths, items; kwargs...)
    w = Audit3BitWriter()
    audit3_dynamic_block!(w, lit_lengths, dist_lengths, items; kwargs...)
    return audit3_finish(w)
end

function audit3_zlib_wrap(raw::Vector{UInt8}, payload::Vector{UInt8})
    a = UInt32(1); b = UInt32(0)
    for byte in payload
        a = (a + byte) % 65521
        b = (b + a) % 65521
    end
    adler = (b << 16) | a
    return vcat(UInt8[0x78, 0x01], raw,
                UInt8[adler >> 24, (adler >> 16) & 0xff, (adler >> 8) & 0xff, adler & 0xff])
end

# A literal/length code whose codes for 'A'..'N' have lengths 1..14 and whose
# 'O' and end-of-block codes have length 15 (a complete code). Codes longer
# than the decoder's 10-bit lookup exercise its canonical slow path.
function audit3_skewed_lit_lengths()
    lit = zeros(Int, 257)
    for (i, c) in enumerate(Int('A'):Int('N'))
        lit[c + 1] = i
    end
    lit[Int('O') + 1] = 15
    lit[257] = 15
    return lit
end

@testset "inflate rejects invalid Huffman code sets" begin
    # Streams found by differential fuzzing against CPython zlib 1.3
    # (zlib.decompressobj(-15)). zlib inflate_table rejects them with the
    # quoted messages; the previous decoder returned 22, 50, and 42 bytes.
    bad_litlen = UInt8[0xe5,0xc1,0x21,0x01,0x00,0x00,0x00,0x00,0x90,0xc1,0xfe,0x77,
                       0x00,0x00,0x00,0x00,0x00,0x00,0x10]   # "invalid literal/lengths set"
    bad_codelen = UInt8[0x05,0xc1,0x81,0xe0,0x00,0x00,0x00,0x00,0x90,0x49,0xff,0x2d,
                        0x00,0x00,0x00,0x00,0x00,0x00,0x20]  # "invalid code lengths set"
    bad_dist = UInt8[0x05,0xc9,0x21,0x01,0x00,0x00,0x00,0x00,0x90,0xc1,0xfe,0x77,
                     0x00,0x00,0x00,0x00,0x00,0x00,0x10]     # "invalid distances set"
    @test_throws "corrupt DEFLATE Huffman code" inflate(bad_litlen)
    @test_throws "corrupt DEFLATE Huffman code" inflate(bad_codelen)
    @test_throws "corrupt DEFLATE Huffman code" inflate(bad_dist)

    # Hand-built tables: over-subscribed (three 1-bit codes) and incomplete
    # (two 2-bit codes) literal/length sets are not prefix codes (RFC 1951
    # §3.2.2); zlib reports "invalid literal/lengths set" for both.
    over = zeros(Int, 257); over[Int('A') + 1] = 1; over[Int('B') + 1] = 1; over[257] = 1
    @test_throws "over-subscribed" inflate(audit3_dynamic_stream(over, [1], UInt8[]))
    incomplete = zeros(Int, 257); incomplete[Int('A') + 1] = 2; incomplete[257] = 2
    @test_throws "incomplete" inflate(audit3_dynamic_stream(incomplete, [1], UInt8[]))
    # RFC 1951 §3.2.7 allows one distance code of one bit, and a distance
    # code with no codes at all when the block has no matches.
    single = zeros(Int, 257); single[Int('A') + 1] = 1; single[257] = 1
    @test inflate(audit3_dynamic_stream(single, [1], [Int('A'), Int('A')])) ==
          UInt8['A', 'A']
    @test inflate(audit3_dynamic_stream(single, [0], [Int('A')])) == UInt8['A']
    # HLIT above 286 and a missing end-of-block code are invalid (RFC 1951
    # §3.2.7; zlib: "too many length or distance symbols", "invalid code --
    # missing end-of-block").
    wide = zeros(Int, 288); wide[Int('A') + 1] = 1; wide[257] = 1
    @test_throws "HLIT 288 exceeds 286" inflate(audit3_dynamic_stream(wide, [1], [Int('A')]))
    no_eob = zeros(Int, 257); no_eob[Int('A') + 1] = 1; no_eob[Int('B') + 1] = 1
    @test_throws "missing end-of-block" inflate(
        audit3_dynamic_stream(no_eob, [1], [Int('A')]; emit_eob=false))
end

@testset "inflate decodes codes longer than the lookup table" begin
    lit = audit3_skewed_lit_lengths()
    text = Int.(collect("ABCDEFGHIJKLMNOONMLKJIHGFEDCBA"))
    stream = audit3_dynamic_stream(lit, [1], text)
    @test inflate(stream) == UInt8.(text)
    # The same stream truncated anywhere is an error, never a short result.
    for cut in 0:(length(stream) - 1)
        @test_throws ErrorException inflate(stream[1:cut])
    end
    # Back-references, including overlapping copies (distance < length) and
    # the maximum length 258, across two blocks sharing the output window.
    lit2 = zeros(Int, 286)
    for c in Int('a'):Int('d')
        lit2[c + 1] = 3
    end
    lit2[257] = 3
    for sym in (257, 258, 259, 265, 284, 285)
        lit2[sym + 1] = 4
    end
    dist2 = zeros(Int, 30)       # symbols 0, 1, 3 (2 bits) and 4, 10 (3 bits)
    dist2[1] = 2; dist2[2] = 2; dist2[4] = 2; dist2[5] = 3; dist2[11] = 3
    w = Audit3BitWriter()
    items1 = [Int('a'), Int('b'), Int('c'), Int('d'), (3, 4), (11, 1), (258, 2)]
    audit3_dynamic_block!(w, lit2, dist2, items1; final=false)
    items2 = [(227, 34), Int('a'), (4, 5)]
    audit3_dynamic_block!(w, lit2, dist2, items2; final=true)
    raw = audit3_finish(w)
    expected = UInt8[]
    function apply!(out, items)
        for item in items
            if item isa Integer
                push!(out, UInt8(item))
            else
                n, d = item
                for _ in 1:n
                    push!(out, out[end - d + 1])
                end
            end
        end
        return out
    end
    apply!(expected, items1); apply!(expected, items2)
    @test inflate(raw) == expected
    # Contiguous views take the 8-byte refill; other vectors read bytewise.
    @test inflate(view(vcat(UInt8[0xaa], raw), 2:(length(raw) + 1))) == expected
    @test inflate(view(raw, collect(1:length(raw)))) == expected
    @test zlib_inflate(audit3_zlib_wrap(raw, expected)) == expected
    # max_output bounds the result exactly.
    @test inflate(raw; max_output=length(expected)) == expected
    @test_throws "DEFLATE output exceeds expected size" inflate(
        raw; max_output=length(expected) - 1)
end

@testset "zlib_inflate reads the Adler-32 right after the DEFLATE stream" begin
    # RFC 1950 §2.2: ADLER32 immediately follows the compressed data. Bytes
    # between the final block and the checksum were silently skipped before.
    payload = UInt8['A', 'B', 'C']
    stored = UInt8[0x01, 0x03, 0x00, 0xfc, 0xff, 0x41, 0x42, 0x43]
    good = audit3_zlib_wrap(stored, payload)
    @test zlib_inflate(good) == payload
    junk = vcat(good[1:end - 4], UInt8[0x00], good[end - 3:end])
    @test_throws "zlib Adler-32 checksum mismatch" zlib_inflate(junk)
    @test_throws "trailing data" zlib_inflate(vcat(good, UInt8[0x00]))
    @test_throws "checksum is truncated" zlib_inflate(good[1:end - 1])
end

@testset "inflate and zlib_inflate document their contracts" begin
    # The raw-DEFLATE docstring was attached to an internal helper, leaving
    # `inflate` with only the generic one-line summary.
    @test occursin("max_output", string(@doc inflate))
    @test occursin("Adler-32", string(@doc zlib_inflate))
end

audit3_hdr(header::String, pixels::Vector{UInt8}) = vcat(Vector{UInt8}(codeunits(header)), pixels)
# rgbe.c rgbe2float: mantissa * 2^(exponent - 136), exponent 0 is black.
audit3_rgbe(c, e) = e == 0 ? 0.0 : c * 2.0^(Int(e) - 136)

@testset "RGBE decoding follows rgbe.c / three.js HDRLoader scanline rules" begin
    # A flat 8-pixel scanline whose first pixel is (2, 2, 200, 130). Its blue
    # byte has the top bit set, so it is not an RLE header (HDRLoader.js:243
    # treats the image as flat); it used to raise "old-style RLE".
    px = UInt8[]
    for x in 1:8
        append!(px, x == 1 ? UInt8[2, 2, 200, 130] : UInt8[10x, 20, 30, 129])
    end
    img = Diff3D._decode_rgbe(audit3_hdr("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 8\n", px))
    @test img[1, 1, :] == [audit3_rgbe(2, 130), audit3_rgbe(2, 130), audit3_rgbe(200, 130)]
    @test img[1, 8, :] == [audit3_rgbe(80, 129), audit3_rgbe(20, 129), audit3_rgbe(30, 129)]
    # The first scanline decides RLE versus flat for the whole image
    # (HDRLoader.js:239-248). A flat image whose second scanline happens to
    # start with (2, 2, 0, 9) is still flat; it used to fail as an RLE width
    # mismatch. three.js decodes that pixel as 2 * 2^-119 / 255.
    px = UInt8[]
    for y in 1:2, x in 1:8
        append!(px, (y == 2 && x == 1) ? UInt8[2, 2, 0, 9] : UInt8[10x, 20y, 30, 129])
    end
    img = Diff3D._decode_rgbe(audit3_hdr("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 8\n", px))
    @test img[2, 1, :] == [audit3_rgbe(2, 9), audit3_rgbe(2, 9), 0.0]
    @test img[2, 2, :] == [audit3_rgbe(20, 129), audit3_rgbe(40, 129), audit3_rgbe(30, 129)]
    # An RLE image may not switch to a flat scanline (HDRLoader.js:286-289
    # "bad rgbe scanline format").
    rle_line = UInt8[2, 2, 0, 8, 136, 1, 136, 2, 136, 3, 136, 129]
    @test size(Diff3D._decode_rgbe(audit3_hdr(
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 8\n", vcat(rle_line, rle_line)))) == (2, 8, 3)
    @test_throws "without an RLE header" Diff3D._decode_rgbe(audit3_hdr(
        "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 2 +X 8\n", vcat(rle_line, fill(0x05, 32))))
    # The magic line is "#?" plus any program name (HDRLoader.js:129,165).
    img = Diff3D._decode_rgbe(audit3_hdr("#?PFSTOOLS\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n",
                                         UInt8[128, 64, 32, 129, 1, 2, 3, 140]))
    @test img[1, :, 1] == [1.0, 16.0]
    @test_throws "not a Radiance" Diff3D._decode_rgbe(audit3_hdr(
        "#? RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n", UInt8[1, 1, 1, 129]))
    @test_throws "not a Radiance" Diff3D._decode_rgbe(audit3_hdr(
        "#?\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n", UInt8[1, 1, 1, 129]))
end

@testset "RGBE banded store matches per-pixel decoding" begin
    # Heights that are not multiples of the 16-row band, in all four
    # orientations, against a direct per-pixel decode of flat data.
    for (H, W) in ((37, 9), (16, 8), (1, 3)), ysign in ("-", "+"), xsign in ("+", "-")
        px = UInt8[]
        for y in 1:H, x in 1:W
            append!(px, UInt8[(7y + 3x) % 256, (5y * x) % 256, (y + 11x) % 251,
                              y == x ? 0 : 120 + (x + y) % 20])
        end
        W >= 8 && (px[1] = 0x09)   # first pixel must not read as an RLE header
        img = Diff3D._decode_rgbe(audit3_hdr(
            "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n$(ysign)Y $H $(xsign)X $W\n", px))
        expected = zeros(H, W, 3)
        for sy in 1:H, sx in 1:W
            base = 4 * ((sy - 1) * W + (sx - 1))
            row = ysign == "-" ? sy : H - sy + 1
            col = xsign == "+" ? sx : W - sx + 1
            for c in 1:3
                expected[row, col, c] = audit3_rgbe(px[base + c], px[base + 4])
            end
        end
        @test img == expected
    end
end

# Byte positions of the first PIZ block's Huffman fields in an OpenEXR file:
# the length field after the bitmap, and nBits (OpenEXR ImfPizCompressor.cpp,
# ImfHuf.cpp hufUncompress: im, iM, table length, nBits, reserved).
function audit3_piz_fields(bytes::Vector{UInt8})
    le32(p) = Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 |
              Int(bytes[p + 3]) << 24
    pos = 9
    while bytes[pos] != 0x00
        for _ in 1:2                       # attribute name and type
            while bytes[pos] != 0x00
                pos += 1
            end
            pos += 1
        end
        pos += 4 + le32(pos)
    end
    offsets = pos + 1
    block = le32(offsets) + 1              # first scanline block (y, size)
    piz = block + 8
    minnz = Int(bytes[piz]) | Int(bytes[piz + 1]) << 8
    maxnz = Int(bytes[piz + 2]) | Int(bytes[piz + 3]) << 8
    length_pos = piz + 4 + (minnz <= maxnz ? maxnz - minnz + 1 : 0)
    return (block_size=le32(block + 4), length_pos=length_pos,
            length=le32(length_pos), nbits_pos=length_pos + 16,
            nbits=le32(length_pos + 16))
end

function audit3_put_le32!(bytes::Vector{UInt8}, pos::Int, value::Integer)
    for k in 0:3
        bytes[pos + k] = UInt8((value >> (8k)) & 0xff)
    end
    return bytes
end

@testset "EXR PIZ Huffman sizes are validated" begin
    fixture = read(joinpath(@__DIR__, "fixtures", "AllHalfValues.exr"))
    good = Diff3D._decode_exr(fixture)
    f = audit3_piz_fields(fixture)
    # three.js EXRLoader.js:785 and OpenEXR hufUncompress reject an nBits
    # beyond the Huffman payload. The decoder used to read 512 MiB of
    # virtual zero bytes (seconds per block) and return an image.
    huge = audit3_put_le32!(copy(fixture), f.nbits_pos, 0xffffffff)
    @test_throws "EXR PIZ Huffman bit count 4294967295 exceeds its data" Diff3D._decode_exr(huge)
    # Too few coded bits leave part of the block undecoded; OpenEXR raises
    # notEnoughData. The old decoder returned zeros for the missing values.
    short = audit3_put_le32!(copy(fixture), f.nbits_pos, f.nbits ÷ 2)
    @test_throws "EXR PIZ Huffman data decoded to" Diff3D._decode_exr(short)
    # OpenEXR PizCompressor::uncompress: the length cannot exceed the block.
    long = audit3_put_le32!(copy(fixture), f.length_pos, 4 * f.block_size)
    @test_throws "EXR PIZ Huffman data length" Diff3D._decode_exr(long)
    @test isequal(Diff3D._decode_exr(copy(fixture)), good)
end

# PNG encoder for tests (PNG §8-§10): every filter type cycles across rows so
# Sub/Up/Average/Paeth reconstruction is exercised; Adam7 when `interlace`.
function audit3_png(samples::Array{Int,3}, colortype::Int, bitdepth::Int;
                    interlace::Bool=false, plte::Vector{UInt8}=UInt8[],
                    trns::Vector{UInt8}=UInt8[])
    H, W, C = size(samples)
    function pack(row)
        bitdepth == 16 && return reduce(vcat, [UInt8[v >> 8, v & 0xff] for v in row]; init=UInt8[])
        bitdepth == 8 && return UInt8.(row)
        out = UInt8[]; acc = 0; n = 0
        for v in row
            acc = (acc << bitdepth) | v; n += bitdepth
            n == 8 && (push!(out, UInt8(acc)); acc = 0; n = 0)
        end
        n > 0 && push!(out, UInt8(acc << (8 - n)))
        return out
    end
    paeth(a, b, c) = (p = a + b - c; pa = abs(p - a); pb = abs(p - b); pc = abs(p - c);
                      pa <= pb && pa <= pc ? a : pb <= pc ? b : c)
    bpp = max(1, C * bitdepth ÷ 8)
    raw = UInt8[]
    passes = interlace ? ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                          (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)) : ((0, 0, 1, 1),)
    rowcount = 0
    for (x0, y0, dx, dy) in passes
        ys = (y0 + 1):dy:H; xs = (x0 + 1):dx:W
        (isempty(ys) || isempty(xs)) && continue
        prev = nothing
        for y in ys
            cur = pack(vec(permutedims(samples[y, xs, :])))
            prev === nothing && (prev = zeros(UInt8, length(cur)))
            ft = rowcount % 5; rowcount += 1
            push!(raw, UInt8(ft))
            for i in eachindex(cur)
                a = i > bpp ? Int(cur[i - bpp]) : 0
                b = Int(prev[i]); c = i > bpp ? Int(prev[i - bpp]) : 0
                pred = (0, a, b, (a + b) ÷ 2, paeth(a, b, c))[ft + 1]
                push!(raw, UInt8(mod(Int(cur[i]) - pred, 256)))
            end
            prev = cur
        end
    end
    chunk(t, d) = (td = vcat(Vector{UInt8}(codeunits(t)), d);
                   vcat(reinterpret(UInt8, [hton(UInt32(length(d)))]), td,
                        reinterpret(UInt8, [hton(Diff3D._crc32(td))])))
    ihdr = vcat(reinterpret(UInt8, [hton(UInt32(W)), hton(UInt32(H))]),
                UInt8[bitdepth, colortype, 0, 0, interlace ? 1 : 0])
    out = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    append!(out, chunk("IHDR", ihdr))
    isempty(plte) || append!(out, chunk("PLTE", plte))
    isempty(trns) || append!(out, chunk("tRNS", trns))
    append!(out, chunk("IDAT", Diff3D._zlib_store(raw)))
    append!(out, chunk("IEND", UInt8[]))
    return out
end

@testset "PNG in-place unfiltering and banded store" begin
    # 37 rows span several 16-row store bands; all five filters occur in
    # every pass. Expected values are the encoded samples / (2^depth - 1).
    H, W = 37, 13
    for interlace in (false, true)
        rgb = [(31y + 17x + 5c) % 256 for y in 1:H, x in 1:W, c in 1:3]
        @test Diff3D._decode_png(audit3_png(rgb, 2, 8; interlace)) == rgb ./ 255
        ga = [(977y + 131x + 4099c) % 65536 for y in 1:H, x in 1:W, c in 1:2]
        @test Diff3D._decode_png(audit3_png(ga, 4, 16; interlace)) == ga ./ 65535
        gray2 = [(y + 2x) % 4 for y in 1:H, x in 1:W, c in 1:1]
        @test Diff3D._decode_png(audit3_png(gray2, 0, 2; interlace)) == gray2 ./ 3
        # Palette with tRNS alpha for the first entries only.
        plte = UInt8[(7i) % 256 for i in 1:18]
        idx = [(y * x) % 6 for y in 1:H, x in 1:W, c in 1:1]
        img = Diff3D._decode_png(audit3_png(idx, 3, 4; interlace, plte,
                                             trns=UInt8[0, 128]))
        @test size(img) == (H, W, 4)
        @test img[:, :, 1] == [plte[3i + 1] / 255 for i in idx[:, :, 1]]
        @test img[:, :, 3] == [plte[3i + 3] / 255 for i in idx[:, :, 1]]
        @test img[:, :, 4] == [(i == 0 ? 0 : i == 1 ? 128 : 255) / 255 for i in idx[:, :, 1]]
        # RGB tRNS marks exactly the matching pixels transparent.
        key = rgb[5, 6, :]
        img = Diff3D._decode_png(audit3_png(rgb, 2, 8; interlace,
                                             trns=UInt8[0, key[1], 0, key[2], 0, key[3]]))
        @test img[:, :, 4] == [rgb[y, x, :] == key ? 0.0 : 1.0 for y in 1:H, x in 1:W]
    end
    # A palette index past the PLTE entries is an error, not a read past it.
    idx = fill(0, 2, 2, 1); idx[2, 2, 1] = 3
    @test_throws "PNG palette index 3 is out of range" Diff3D._decode_png(
        audit3_png(idx, 3, 8; plte=UInt8[1, 2, 3, 4, 5, 6]))
end

@testset "JSON parser follows JSON.parse on valid input" begin
    # ECMA-262 JSON.parse rounds numbers to the nearest double, so values
    # below half the least subnormal become ±0 (node: JSON.parse("1e-400") === 0,
    # Object.is(JSON.parse("-1e-400"), -0)).
    @test Diff3D._json_parse("1e-400") === 0.0
    @test only(Diff3D._json_parse("[2.4703282292062327e-324]")) === 0.0
    @test Diff3D._json_parse("-1e-400") === -0.0
    @test Diff3D._json_parse(Vector{UInt8}("-1e-400")) === -0.0
    @test Diff3D._json_parse("2.4703282292062328e-324") === 5.0e-324
    # Correct rounding, including halfway cases (node JSON.parse values).
    @test Diff3D._json_parse("9007199254740993") === 9.007199254740992e15
    @test Diff3D._json_parse("9007199254740995") === 9.007199254740996e15
    @test Diff3D._json_parse("123456789012345678901234567890") === 1.2345678901234568e29
    @test Diff3D._json_parse("0.1") === 0.1
    @test Diff3D._json_parse("-0") === -0.0
    @test Diff3D._json_parse("1.7976931348623157e308") === 1.7976931348623157e308
    @test Diff3D._json_parse("4.35e-21") === 4.35e-21
    # Nesting depth is limited by memory, not the call stack (JSON.parse
    # accepts 10^6 nested arrays).
    depth = 200_000
    nested = Diff3D._json_parse("["^depth * "{\"k\":1}" * "]"^depth)
    levels = 0
    while nested isa Vector{Any}
        nested = only(nested)
        levels += 1
    end
    @test levels == depth && nested == Dict{String,Any}("k" => 1.0)
end

@testset "JSON parser rejects invalid input with an ErrorException" begin
    # Multibyte text after a literal prefix used to throw StringIndexError.
    @test_throws ErrorException("invalid JSON literal at byte 1") Diff3D._json_parse("tr€")
    @test_throws ErrorException("invalid JSON literal at byte 2") Diff3D._json_parse("[nul€]")
    # String and byte input share one parser: same errors for the same bytes.
    for input in ("01", "1.", "+1", "1.2.3", "[1-2]", "\"\\ud800\"", "1e400", "{\"a\" 1}")
        e1 = try Diff3D._json_parse(input); nothing catch e; e end
        e2 = try Diff3D._json_parse(Vector{UInt8}(input)); nothing catch e; e end
        @test e1 isa ErrorException && e2 isa ErrorException && e1.msg == e2.msg
    end
    @test_throws "invalid JSON number 01" Diff3D._json_parse("01")
    @test_throws "JSON number 1e400 must be finite" Diff3D._json_parse("1e400")
    @test_throws "invalid UTF-8" Diff3D._json_parse(String(UInt8[0x22, 0xff, 0x22]))
    # Unclosed deep nesting ends with an error, not a stack overflow.
    @test_throws "unexpected end of JSON" Diff3D._json_parse("["^200_000)
end
