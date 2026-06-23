# --------------------------------------------------------------------------
# Extended loaders: PNG decode (pure-Julia INFLATE), TextureLoader, OBJ .mtl
# materials, and a minimal glTF 2.0 loader (embedded base64 buffers). All pure
# Julia, no external dependencies.
# --------------------------------------------------------------------------

# ========================== DEFLATE / INFLATE ==========================

mutable struct _BitReader
    data::Vector{UInt8}
    pos::Int
    bitbuf::UInt32
    bitcnt::Int
end
_BitReader(d::Vector{UInt8}) = _BitReader(d, 1, UInt32(0), 0)

@inline function _getbit(br::_BitReader)
    if br.bitcnt == 0
        br.bitbuf = UInt32(br.data[br.pos]); br.pos += 1; br.bitcnt = 8
    end
    b = br.bitbuf & 0x1
    br.bitbuf >>= 1; br.bitcnt -= 1
    return Int(b)
end
@inline function _getbits(br::_BitReader, n::Int)
    v = 0
    for i in 0:n-1
        v |= _getbit(br) << i
    end
    return v
end

# Canonical Huffman decode table (RFC 1951). Decoding walks MSB-first one bit at
# a time, but each length check is O(1) instead of scanning all symbols.
#
# Fields, indexed by code length `len` (1..maxbits):
#   first_code[len]   smallest canonical code of that length
#   first_index[len]  offset into `symbols` where that length's symbols start
#   count[len]        number of symbols of that length
#   symbols           symbol values (0-based) sorted by (length, code), i.e. by
#                     ascending symbol index within each length — exactly the
#                     order `_build_huff` assigns consecutive codes, so
#                     symbol = symbols[first_index[len] + (code - first_code[len])].
struct _Huff
    maxbits::Int
    first_code::Vector{Int}
    first_index::Vector{Int}
    count::Vector{Int}
    symbols::Vector{Int}
end

# Build the canonical-Huffman fast-decode table from per-symbol code lengths.
# Produces the identical canonical code assignment as the previous (lengths,
# codes) form: within a length, codes increase in symbol-index order.
function _build_huff(lengths::Vector{Int})
    maxbits = isempty(lengths) ? 0 : maximum(lengths)
    if maxbits == 0
        return _Huff(0, Int[], Int[], Int[], Int[])
    end
    # Count codes per length and derive the first canonical code per length.
    blcount = zeros(Int, maxbits + 1)        # blcount[len+1] = #codes of length len
    @inbounds for l in lengths
        l > 0 && (blcount[l + 1] += 1)
    end
    first_code = zeros(Int, maxbits)         # first_code[len]
    count = zeros(Int, maxbits)              # count[len]
    code = 0
    @inbounds for len in 1:maxbits
        code = (code + blcount[len]) << 1    # matches _build_huff(prev) recurrence
        first_code[len] = code
        count[len] = blcount[len + 1]
    end
    # `symbols` holds symbol values grouped by length, in ascending symbol order.
    first_index = zeros(Int, maxbits)        # offset (0-based) into symbols per length
    acc = 0
    @inbounds for len in 1:maxbits
        first_index[len] = acc
        acc += count[len]
    end
    symbols = Vector{Int}(undef, acc)
    fill_pos = copy(first_index)             # running write cursor per length
    @inbounds for n in 1:length(lengths)
        l = lengths[n]
        if l > 0
            symbols[fill_pos[l] + 1] = n - 1 # 0-based symbol value
            fill_pos[l] += 1
        end
    end
    return _Huff(maxbits, first_code, first_index, count, symbols)
end

# Decode one symbol. O(code length) bit reads with O(1) work per bit.
@inline function _decode_sym(br::_BitReader, huff::_Huff)
    code = 0
    @inbounds for len in 1:huff.maxbits
        code = (code << 1) | _getbit(br)
        cnt = huff.count[len]
        if cnt > 0
            off = code - huff.first_code[len]
            if 0 <= off < cnt
                return huff.symbols[huff.first_index[len] + off + 1]
            end
        end
    end
    error("invalid Huffman code")
end

const _LEN_BASE   = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
const _LEN_EXTRA  = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
const _DIST_BASE  = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
const _DIST_EXTRA = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]

function _fixed_huffs()
    litlen = Vector{Int}(undef, 288)
    for i in 1:288
        litlen[i] = i <= 144 ? 8 : i <= 256 ? 9 : i <= 280 ? 7 : 8
    end
    (_build_huff(litlen), _build_huff(fill(5, 30)))
end

function _read_dynamic(br::_BitReader)
    hlit = _getbits(br, 5) + 257
    hdist = _getbits(br, 5) + 1
    hclen = _getbits(br, 4) + 4
    order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
    cl_lengths = zeros(Int, 19)
    for i in 1:hclen
        cl_lengths[order[i] + 1] = _getbits(br, 3)
    end
    cl_huff = _build_huff(cl_lengths)
    all_lengths = Int[]
    while length(all_lengths) < hlit + hdist
        sym = _decode_sym(br, cl_huff)
        if sym < 16
            push!(all_lengths, sym)
        elseif sym == 16
            rep = _getbits(br, 2) + 3; prev = all_lengths[end]
            append!(all_lengths, fill(prev, rep))
        elseif sym == 17
            append!(all_lengths, fill(0, _getbits(br, 3) + 3))
        else
            append!(all_lengths, fill(0, _getbits(br, 7) + 11))
        end
    end
    lit = _build_huff(all_lengths[1:hlit])
    dist = _build_huff(all_lengths[hlit+1:hlit+hdist])
    return (lit, dist)
end

function _inflate_block!(out::Vector{UInt8}, br::_BitReader, lit, dist)
    while true
        sym = _decode_sym(br, lit)
        if sym < 256
            push!(out, UInt8(sym))
        elseif sym == 256
            break
        else
            li = sym - 256
            len = _LEN_BASE[li] + _getbits(br, _LEN_EXTRA[li])
            dsym = _decode_sym(br, dist)
            d = _DIST_BASE[dsym + 1] + _getbits(br, _DIST_EXTRA[dsym + 1])
            start = length(out) - d
            for k in 1:len
                push!(out, out[start + k])
            end
        end
    end
end

"""Inflate a raw DEFLATE stream (no zlib header) to bytes."""
function inflate(data::Vector{UInt8})
    br = _BitReader(data); out = UInt8[]
    while true
        bfinal = _getbit(br); btype = _getbits(br, 2)
        if btype == 0
            br.bitcnt = 0                       # align to byte boundary
            len = Int(br.data[br.pos]) | (Int(br.data[br.pos + 1]) << 8)
            br.pos += 4                         # skip LEN(2) + NLEN(2)
            for _ in 1:len
                push!(out, br.data[br.pos]); br.pos += 1
            end
        elseif btype == 1
            lit, dist = _fixed_huffs(); _inflate_block!(out, br, lit, dist)
        elseif btype == 2
            lit, dist = _read_dynamic(br); _inflate_block!(out, br, lit, dist)
        else
            error("invalid DEFLATE block type 3")
        end
        bfinal == 1 && break
    end
    return out
end

zlib_inflate(data::Vector{UInt8}) = inflate(data[3:end])   # skip 2-byte zlib header; ignore Adler trailer

# ========================== PNG decode ==========================

@inline _rd_be32(b, i) = (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])

@inline function _paeth(a, b, c)
    p = a + b - c
    pa = abs(p - a); pb = abs(p - b); pc = abs(p - c)
    return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
end

const _PNG_SIGNATURE = UInt8[137,80,78,71,13,10,26,10]
_is_png_bytes(bytes::Vector{UInt8}) =
    length(bytes) >= length(_PNG_SIGNATURE) && bytes[1:length(_PNG_SIGNATURE)] == _PNG_SIGNATURE

const _PNG_ADAM7_PASSES = (
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
)

@inline _png_pass_size(n::Int, start::Int, step::Int) =
    n <= start ? 0 : ((n - start + step - 1) ÷ step)

function _png_unfilter_scanline!(cur::Vector{UInt8}, prev::Vector{UInt8},
                                 bpp::Int, ftype::UInt8)
    stride = length(cur)
    length(prev) == stride || error("PNG previous scanline length mismatch")
    @inbounds for i in 1:stride
        a = i > bpp ? cur[i-bpp] : 0x00
        b = prev[i]
        c = i > bpp ? prev[i-bpp] : 0x00
        x = cur[i]
        cur[i] = if ftype == 0; x
                 elseif ftype == 1; x + a
                 elseif ftype == 2; x + b
                 elseif ftype == 3; x + UInt8((Int(a) + Int(b)) ÷ 2)
                 elseif ftype == 4; x + UInt8(_paeth(Int(a), Int(b), Int(c)))
                 else error("bad PNG filter $ftype") end
    end
    return cur
end

@inline function _png_channel_value(cur::Vector{UInt8}, base::Int,
                                   bps::Int, norm::Float64)
    return bps == 2 ? ((Int(cur[base]) << 8) | Int(cur[base + 1])) / norm :
                      cur[base] / norm
end

function _png_store_scanline!(img::Array{Float64,3}, row::Int, cur::Vector{UInt8},
                              W::Int, channels::Int, bps::Int, bpp::Int,
                              norm::Float64)
    @inbounds for j in 1:W, c in 1:channels
        base = (j - 1) * bpp + (c - 1) * bps + 1
        img[row, j, c] = _png_channel_value(cur, base, bps, norm)
    end
    return img
end

function _png_decode_noninterlaced!(img::Array{Float64,3}, raw::Vector{UInt8},
                                    W::Int, H::Int, channels::Int, bps::Int,
                                    bpp::Int, norm::Float64)
    stride = W * bpp
    prev = zeros(UInt8, stride)
    p = 1
    for row in 1:H
        p <= length(raw) || error("PNG image data is truncated")
        ftype = raw[p]; p += 1
        p + stride - 1 <= length(raw) || error("PNG image data is truncated")
        cur = Vector{UInt8}(raw[p:p+stride-1]); p += stride
        _png_unfilter_scanline!(cur, prev, bpp, ftype)
        _png_store_scanline!(img, row, cur, W, channels, bps, bpp, norm)
        prev = cur
    end
    return img
end

function _png_decode_adam7!(img::Array{Float64,3}, raw::Vector{UInt8},
                            W::Int, H::Int, channels::Int, bps::Int,
                            bpp::Int, norm::Float64)
    p = 1
    @inbounds for (x0, y0, xstep, ystep) in _PNG_ADAM7_PASSES
        pass_w = _png_pass_size(W, x0, xstep)
        pass_h = _png_pass_size(H, y0, ystep)
        (pass_w == 0 || pass_h == 0) && continue
        stride = pass_w * bpp
        prev = zeros(UInt8, stride)
        for prow in 0:(pass_h - 1)
            p <= length(raw) || error("PNG image data is truncated")
            ftype = raw[p]; p += 1
            p + stride - 1 <= length(raw) || error("PNG image data is truncated")
            cur = Vector{UInt8}(raw[p:p+stride-1]); p += stride
            _png_unfilter_scanline!(cur, prev, bpp, ftype)
            row = y0 + prow * ystep + 1
            for pcol in 0:(pass_w - 1), c in 1:channels
                col = x0 + pcol * xstep + 1
                base = pcol * bpp + (c - 1) * bps + 1
                img[row, col, c] = _png_channel_value(cur, base, bps, norm)
            end
            prev = cur
        end
    end
    return img
end

@inline function _png_packed_index(cur::Vector{UInt8}, pcol::Int, bitdepth::Int)
    if bitdepth == 8
        return Int(cur[pcol + 1])
    elseif bitdepth == 4
        byte = cur[(pcol ÷ 2) + 1]
        return iseven(pcol) ? Int(byte >> 4) : Int(byte & 0x0f)
    elseif bitdepth == 2
        byte = cur[(pcol ÷ 4) + 1]
        shift = 6 - 2 * (pcol % 4)
        return Int((byte >> shift) & 0x03)
    else # bitdepth == 1
        byte = cur[(pcol ÷ 8) + 1]
        shift = 7 - (pcol % 8)
        return Int((byte >> shift) & 0x01)
    end
end

function _png_store_palette_pixel!(img::Array{Float64,3}, row::Int, col::Int,
                                   idx::Int, palette::Vector{UInt8},
                                   trns::Vector{UInt8}, channels::Int)
    entry = 3idx + 1
    entry + 2 <= length(palette) || error("PNG palette index $idx is out of range")
    img[row, col, 1] = palette[entry] / 255
    img[row, col, 2] = palette[entry + 1] / 255
    img[row, col, 3] = palette[entry + 2] / 255
    if channels == 4
        alpha = idx + 1 <= length(trns) ? trns[idx + 1] : UInt8(255)
        img[row, col, 4] = alpha / 255
    end
    return img
end

function _png_decode_palette_noninterlaced!(img::Array{Float64,3}, raw::Vector{UInt8},
                                            W::Int, H::Int, bitdepth::Int,
                                            palette::Vector{UInt8},
                                            trns::Vector{UInt8}, channels::Int)
    stride = cld(W * bitdepth, 8)
    prev = zeros(UInt8, stride)
    p = 1
    for row in 1:H
        p <= length(raw) || error("PNG image data is truncated")
        ftype = raw[p]; p += 1
        p + stride - 1 <= length(raw) || error("PNG image data is truncated")
        cur = Vector{UInt8}(raw[p:p+stride-1]); p += stride
        _png_unfilter_scanline!(cur, prev, 1, ftype)
        for pcol in 0:(W - 1)
            idx = _png_packed_index(cur, pcol, bitdepth)
            _png_store_palette_pixel!(img, row, pcol + 1, idx, palette, trns, channels)
        end
        prev = cur
    end
    return img
end

function _png_decode_palette_adam7!(img::Array{Float64,3}, raw::Vector{UInt8},
                                    W::Int, H::Int, bitdepth::Int,
                                    palette::Vector{UInt8},
                                    trns::Vector{UInt8}, channels::Int)
    p = 1
    @inbounds for (x0, y0, xstep, ystep) in _PNG_ADAM7_PASSES
        pass_w = _png_pass_size(W, x0, xstep)
        pass_h = _png_pass_size(H, y0, ystep)
        (pass_w == 0 || pass_h == 0) && continue
        stride = cld(pass_w * bitdepth, 8)
        prev = zeros(UInt8, stride)
        for prow in 0:(pass_h - 1)
            p <= length(raw) || error("PNG image data is truncated")
            ftype = raw[p]; p += 1
            p + stride - 1 <= length(raw) || error("PNG image data is truncated")
            cur = Vector{UInt8}(raw[p:p+stride-1]); p += stride
            _png_unfilter_scanline!(cur, prev, 1, ftype)
            row = y0 + prow * ystep + 1
            for pcol in 0:(pass_w - 1)
                col = x0 + pcol * xstep + 1
                idx = _png_packed_index(cur, pcol, bitdepth)
                _png_store_palette_pixel!(img, row, col, idx, palette, trns, channels)
            end
            prev = cur
        end
    end
    return img
end

"""
    load_png(path) -> Array{Float64,3}

Decode an 8-bit or 16-bit PNG (grayscale, grayscale+alpha, RGB, RGBA, or palette) to an H×W×C array in [0,1].
Implements full INFLATE (stored/fixed/dynamic Huffman), all five PNG filters,
and Adam7 interlacing for supported 8-bit and 16-bit color types.
"""
function _decode_png(bytes::Vector{UInt8})
    _is_png_bytes(bytes) || error("not a PNG file")
    pos = 9; W = 0; H = 0; bitdepth = 8; colortype = 2; interlace = 0
    idat = UInt8[]
    palette = UInt8[]
    trns = UInt8[]
    while pos <= length(bytes)
        len = _rd_be32(bytes, pos); pos += 4
        ctype = String(bytes[pos:pos+3]); pos += 4
        if ctype == "IHDR"
            W = _rd_be32(bytes, pos); H = _rd_be32(bytes, pos+4)
            bitdepth = bytes[pos+8]; colortype = bytes[pos+9]
            interlace = bytes[pos+12]
        elseif ctype == "IDAT"
            append!(idat, @view bytes[pos:pos+len-1])
        elseif ctype == "PLTE"
            palette = collect(@view bytes[pos:pos+len-1])
        elseif ctype == "tRNS"
            trns = collect(@view bytes[pos:pos+len-1])
        elseif ctype == "IEND"
            break
        end
        pos += len + 4                          # data + CRC
    end
    (interlace == 0 || interlace == 1) || error("unsupported PNG interlace method $interlace")
    if colortype == 3
        bitdepth in (1, 2, 4, 8) || error("unsupported PNG palette bit depth $bitdepth")
        (!isempty(palette) && length(palette) % 3 == 0 && length(palette) <= 768) ||
            error("PNG palette is missing or malformed")
        length(trns) <= length(palette) ÷ 3 ||
            error("PNG tRNS palette alpha data is longer than the palette")
        palette_bitdepth = Int(bitdepth)
        channels = isempty(trns) ? 3 : 4
        raw = zlib_inflate(idat)
        img = Array{Float64}(undef, H, W, channels)
        return interlace == 0 ?
               _png_decode_palette_noninterlaced!(img, raw, W, H, palette_bitdepth,
                                                   palette, trns, channels) :
               _png_decode_palette_adam7!(img, raw, W, H, palette_bitdepth,
                                          palette, trns, channels)
    end
    (bitdepth == 8 || bitdepth == 16) || error("only 8-bit and 16-bit PNG decode is supported")
    channels = colortype == 0 ? 1 : colortype == 2 ? 3 : colortype == 4 ? 2 :
               colortype == 6 ? 4 :
               error("unsupported PNG color type $colortype")
    bps = Int(bitdepth) ÷ 8                     # bytes per sample
    bpp = channels * bps                        # bytes per pixel (filter window)
    raw = zlib_inflate(idat)
    img = Array{Float64}(undef, H, W, channels)
    norm = bitdepth == 16 ? 65535.0 : 255.0
    return interlace == 0 ?
           _png_decode_noninterlaced!(img, raw, W, H, channels, bps, bpp, norm) :
           _png_decode_adam7!(img, raw, W, H, channels, bps, bpp, norm)
end

function load_png(path::String)
    _decode_png(read(path))
end

@inline function _is_jpeg_bytes(bytes::Vector{UInt8})
    length(bytes) >= 4 &&
        bytes[1] == 0xff && bytes[2] == 0xd8 &&
        bytes[end - 1] == 0xff && bytes[end] == 0xd9
end

"""Decode a JPEG/JPG file into an H×W×3 RGB array in [0,1]."""
load_jpeg(path::String) = _decode_jpeg(read(path); label="JPEG image")

# ===== KTX2 (Khronos texture container) — uncompressed decode =====
# Basis Universal (vkFormat 0) and supercompressed payloads need a transcoder
# and fail clearly rather than being silently approximated.
const _KTX2_IDENTIFIER = UInt8[0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB,
                               0x0D, 0x0A, 0x1A, 0x0A]

# Supported uncompressed Vulkan formats -> (channel count, component kind).
# 8-bit UNORM/SRGB decode to [0,1]; 16/32-bit SFLOAT decode to linear unclamped
# HDR values (used by KTX2 environment maps), reusing the EXR float helpers.
const _KTX2_VKFORMATS = Dict{Int,Tuple{Int,Symbol}}(
    9 => (1, :unorm8), 15 => (1, :unorm8),    # VK_FORMAT_R8_UNORM / _SRGB
    16 => (2, :unorm8), 22 => (2, :unorm8),   # R8G8
    23 => (3, :unorm8), 29 => (3, :unorm8),   # R8G8B8
    37 => (4, :unorm8), 43 => (4, :unorm8),   # R8G8B8A8
    76 => (1, :sfloat16), 83 => (2, :sfloat16),   # R16 / R16G16 SFLOAT
    90 => (3, :sfloat16), 97 => (4, :sfloat16),   # R16G16B16(A16) SFLOAT
    100 => (1, :sfloat32), 103 => (2, :sfloat32), # R32 / R32G32 SFLOAT
    106 => (3, :sfloat32), 109 => (4, :sfloat32), # R32G32B32(A32) SFLOAT
)

_ktx2_comp_bytes(kind::Symbol) = kind === :unorm8 ? 1 : kind === :sfloat16 ? 2 : 4

# Little-endian u64 from two u32 reads (`_rd_le32` is defined later in-module).
@inline _rd_le64(b, i) = _rd_le32(b, i) | (_rd_le32(b, i + 4) << 32)

@inline function _is_ktx2_bytes(bytes::Vector{UInt8})
    length(bytes) >= 12 && (@views bytes[1:12]) == _KTX2_IDENTIFIER
end

# Read the KTXorientation value string from the key/value data section.
# KVD entries are: keyAndValueByteLength (u32), NUL-terminated key, value bytes,
# then 0-3 bytes of padding to a 4-byte boundary.
function _ktx2_orientation(bytes::Vector{UInt8}, kvd_off::Int, kvd_len::Int)
    (kvd_len > 0 && kvd_off >= 0 && kvd_off + kvd_len <= length(bytes)) || return ""
    key = b"KTXorientation"
    pos = kvd_off + 1                              # 1-based start of KVD
    stop = kvd_off + kvd_len                       # 1-based last KVD byte
    while pos + 3 <= stop
        n = _rd_le32(bytes, pos)                   # keyAndValueByteLength
        pos += 4
        (n >= 1 && pos + n - 1 <= stop) || break
        kstart = pos; kstop = pos + n - 1
        knul = kstart
        while knul <= kstop && bytes[knul] != 0x00
            knul += 1
        end
        if knul <= kstop && (knul - kstart) == length(key) &&
           (@views bytes[kstart:(knul - 1)]) == key
            vstart = knul + 1
            vstop = vstart
            while vstop <= kstop && bytes[vstop] != 0x00
                vstop += 1
            end
            return String(@view bytes[vstart:(vstop - 1)])
        end
        pos = kstart + n
        pos += (4 - (n % 4)) % 4                    # 4-byte value padding
    end
    return ""
end

function _decode_ktx2(bytes::Vector{UInt8})
    length(bytes) >= 80 ||
        error("KTX2 image is truncated: a valid header needs at least 80 bytes, got $(length(bytes))")
    _is_ktx2_bytes(bytes) ||
        error("KTX2 identifier mismatch; data is not a KTX2 file")
    vkFormat    = _rd_le32(bytes, 13)
    pixelWidth  = _rd_le32(bytes, 21)
    pixelHeight = _rd_le32(bytes, 25)
    pixelDepth  = _rd_le32(bytes, 29)
    layerCount  = _rd_le32(bytes, 33)
    faceCount   = _rd_le32(bytes, 37)
    superScheme = _rd_le32(bytes, 45)
    kvdOffset   = _rd_le32(bytes, 57)
    kvdLength   = _rd_le32(bytes, 61)

    superScheme == 0 ||
        error("KTX2 supercompression scheme $superScheme is not supported; only uncompressed KTX2 is implemented (Basis/Zstd/Zlib need a transcoder)")
    vkFormat != 0 ||
        error("KTX2 vkFormat 0 (Basis Universal) is not supported; Basis transcoding is not implemented")
    haskey(_KTX2_VKFORMATS, vkFormat) ||
        error("KTX2 vkFormat $vkFormat is not supported; only uncompressed 8-bit UNORM/SRGB and 16/32-bit SFLOAT R/RG/RGB/RGBA formats are implemented")
    (pixelWidth > 0 && pixelHeight > 0) ||
        error("KTX2 image has non-positive dimensions $(pixelWidth)x$(pixelHeight)")
    pixelDepth <= 1 ||
        error("KTX2 3D textures (pixelDepth=$pixelDepth) are not supported")
    faceCount == 1 ||
        error("KTX2 cube maps (faceCount=$faceCount) are not supported")
    layerCount <= 1 ||
        error("KTX2 texture arrays (layerCount=$layerCount) are not supported")

    channels, kind = _KTX2_VKFORMATS[vkFormat]
    cbytes = _ktx2_comp_bytes(kind)
    pixel_bytes = channels * cbytes
    length(bytes) >= 104 ||                         # 80-byte header + one level entry
        error("KTX2 level index is truncated")
    byteOffset = _rd_le64(bytes, 81)                # level 0 = full resolution
    byteLength = _rd_le64(bytes, 89)

    expected = pixelWidth * pixelHeight * pixel_bytes
    byteLength == expected ||
        error("KTX2 level 0 byteLength $byteLength does not match $(pixelWidth)x$(pixelHeight)x$channels x$cbytes = $expected uncompressed bytes")
    (byteOffset >= 0 && byteOffset + byteLength <= length(bytes)) ||
        error("KTX2 level 0 data range exceeds the file length $(length(bytes))")

    # KTXorientation second axis: 'u' (up) stores the bottom row first, so flip
    # to the top-first layout used by the PNG/JPEG decoders. 'd' or absent keeps
    # rows as stored (glTF mandates "rd", which toktx also writes).
    orient = _ktx2_orientation(bytes, kvdOffset, kvdLength)
    flip = length(orient) >= 2 && orient[2] == 'u'

    img = Array{Float64}(undef, pixelHeight, pixelWidth, channels)
    @inbounds for y in 1:pixelHeight
        srow = flip ? (pixelHeight - y + 1) : y
        rowbase = byteOffset + (srow - 1) * pixelWidth * pixel_bytes   # 0-based
        for x in 1:pixelWidth
            px = rowbase + (x - 1) * pixel_bytes                       # 0-based pixel start
            for c in 1:channels
                b1 = px + (c - 1) * cbytes + 1                         # 1-based component byte
                img[y, x, c] = kind === :unorm8 ? bytes[b1] / 255.0 :
                               kind === :sfloat16 ? _half_to_float(_rd_le16(bytes, b1)) :
                               Float64(_rd_f32(bytes, b1))
            end
        end
    end
    return img
end

"""
    load_ktx2(path) -> Array{Float64,3}

Decode an uncompressed KTX2 (Khronos texture) file into an `H×W×C` image,
matching the layout produced by [`load_png`](@ref). Supports single-level
8-bit R/RG/RGB/RGBA `UNORM`/`SRGB` formats (decoded to `[0, 1]`) and 16/32-bit
`SFLOAT` formats (decoded to linear unclamped HDR values), and honors the
`KTXorientation` metadata. Basis Universal (`vkFormat` 0) and supercompressed
payloads require a transcoder and raise a clear error instead of guessing.
"""
load_ktx2(path::String) = _decode_ktx2(read(path))

"""
    load_image(path) -> Array{Float64,3}

Decode a PNG, JPEG/JPG, or uncompressed KTX2 image by inspecting the file bytes.
Use [`load_rgbe`](@ref) / [`RGBELoader`](@ref) for Radiance HDR files.
"""
function load_image(path::String)
    bytes = read(path)
    _is_png_bytes(bytes) && return _decode_png(bytes)
    _is_jpeg_bytes(bytes) && return _decode_jpeg(bytes; label="JPEG image")
    _is_ktx2_bytes(bytes) && return _decode_ktx2(bytes)
    error("unsupported image format for $path; TextureLoader supports PNG, JPEG/JPG, and uncompressed KTX2")
end

"""Load a PNG or JPEG/JPG image into a [`Texture`]."""
TextureLoader(path::String; kwargs...) = Texture(load_image(path); kwargs...)

# ========================== Audio decode ==========================

"""Decoded audio buffer data, with samples stored as frames × channels."""
struct AudioBufferData
    sample_rate::Int
    channels::Int
    samples::Matrix{Float64}
end

audio_duration(a::AudioBufferData) = size(a.samples, 1) / a.sample_rate

@inline function _le_u16(bytes::Vector{UInt8}, pos::Int)
    pos + 1 <= length(bytes) || error("WAV chunk is truncated")
    return Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
end

@inline function _le_u32(bytes::Vector{UInt8}, pos::Int)
    pos + 3 <= length(bytes) || error("WAV chunk is truncated")
    return Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) |
           (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
end

@inline function _le_i16(bytes::Vector{UInt8}, pos::Int)
    u = _le_u16(bytes, pos)
    return u >= 0x8000 ? u - 0x10000 : u
end

@inline function _le_i24(bytes::Vector{UInt8}, pos::Int)
    pos + 2 <= length(bytes) || error("WAV chunk is truncated")
    u = Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) | (Int(bytes[pos + 2]) << 16)
    return u >= 0x800000 ? u - 0x1000000 : u
end

@inline function _le_i32(bytes::Vector{UInt8}, pos::Int)
    u = _le_u32(bytes, pos)
    return u >= 0x80000000 ? u - 0x100000000 : u
end

function _le_float32(bytes::Vector{UInt8}, pos::Int)
    return reinterpret(Float32, UInt32(_le_u32(bytes, pos)))
end

function _le_float64(bytes::Vector{UInt8}, pos::Int)
    pos + 7 <= length(bytes) || error("WAV chunk is truncated")
    lo = UInt64(_le_u32(bytes, pos))
    hi = UInt64(_le_u32(bytes, pos + 4))
    return reinterpret(Float64, lo | (hi << 32))
end

function _wav_format_from_extensible(fmt::Vector{UInt8})
    length(fmt) >= 40 || error("WAV extensible fmt chunk is truncated")
    cb_size = _le_u16(fmt, 17)
    cb_size >= 22 || error("WAV extensible fmt chunk is missing its subformat GUID")
    guid = fmt[25:40]
    tail = UInt8[0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71]
    guid[5:16] == tail || error("unsupported WAV extensible subformat GUID")
    return _le_u16(guid, 1)
end

function _decode_wav(bytes::Vector{UInt8})
    length(bytes) >= 12 || error("WAV file is truncated")
    String(bytes[1:4]) == "RIFF" || error("not a RIFF WAV file")
    String(bytes[9:12]) == "WAVE" || error("RIFF file is not WAVE audio")
    riff_size = _le_u32(bytes, 5)
    riff_size + 8 <= length(bytes) || error("WAV RIFF size exceeds file length")
    fmt = nothing
    data_start = 0
    data_len = 0
    pos = 13
    while pos + 7 <= min(length(bytes), riff_size + 8)
        chunk_id = String(bytes[pos:pos + 3])
        chunk_len = _le_u32(bytes, pos + 4)
        chunk_start = pos + 8
        chunk_end = chunk_start + chunk_len - 1
        chunk_end <= length(bytes) || error("WAV chunk $chunk_id exceeds file length")
        if chunk_id == "fmt "
            fmt = bytes[chunk_start:chunk_end]
        elseif chunk_id == "data"
            data_start = chunk_start
            data_len = chunk_len
        end
        pos = chunk_start + chunk_len + (isodd(chunk_len) ? 1 : 0)
    end
    fmt === nothing && error("WAV fmt chunk is missing")
    data_len > 0 || error("WAV data chunk is missing or empty")
    length(fmt) >= 16 || error("WAV fmt chunk is truncated")
    format_tag = _le_u16(fmt, 1)
    channels = _le_u16(fmt, 3)
    sample_rate = _le_u32(fmt, 5)
    block_align = _le_u16(fmt, 13)
    bits_per_sample = _le_u16(fmt, 15)
    format_tag == 0xfffe && (format_tag = _wav_format_from_extensible(fmt))
    channels > 0 || error("WAV channel count must be positive")
    sample_rate > 0 || error("WAV sample rate must be positive")
    bytes_per_sample = bits_per_sample ÷ 8
    bits_per_sample % 8 == 0 || error("WAV bits per sample must be byte-aligned")
    bytes_per_sample > 0 || error("WAV bits per sample must be positive")
    block_align == channels * bytes_per_sample ||
        error("WAV blockAlign does not match channels and bits per sample")
    data_len % block_align == 0 || error("WAV data chunk is not aligned to complete frames")
    frames = data_len ÷ block_align
    samples = Matrix{Float64}(undef, frames, channels)
    @inbounds for frame in 1:frames, ch in 1:channels
        p = data_start + (frame - 1) * block_align + (ch - 1) * bytes_per_sample
        samples[frame, ch] = if format_tag == 1
            if bits_per_sample == 8
                (Float64(bytes[p]) - 128.0) / 128.0
            elseif bits_per_sample == 16
                max(-1.0, Float64(_le_i16(bytes, p)) / 32767.0)
            elseif bits_per_sample == 24
                max(-1.0, Float64(_le_i24(bytes, p)) / 8388607.0)
            elseif bits_per_sample == 32
                max(-1.0, Float64(_le_i32(bytes, p)) / 2147483647.0)
            else
                error("unsupported PCM WAV bit depth $bits_per_sample")
            end
        elseif format_tag == 3
            if bits_per_sample == 32
                Float64(_le_float32(bytes, p))
            elseif bits_per_sample == 64
                _le_float64(bytes, p)
            else
                error("unsupported IEEE float WAV bit depth $bits_per_sample")
            end
        else
            error("unsupported WAV audio format tag $format_tag")
        end
    end
    return AudioBufferData(sample_rate, channels, samples)
end

"""Decode RIFF/WAVE PCM or IEEE-float audio into [`AudioBufferData`](@ref)."""
load_wav(path::String) = _decode_wav(read(path))

"""
    load_audio(path) -> AudioBufferData

Decode audio bytes supported by Diff3D.jl's loader surface. Currently supports
RIFF/WAVE PCM and IEEE-float WAV files; browser-specific compressed audio
decode remains outside this native loader.
"""
function load_audio(path::String)
    bytes = read(path)
    length(bytes) >= 12 && String(bytes[1:4]) == "RIFF" &&
        String(bytes[9:12]) == "WAVE" && return _decode_wav(bytes)
    error("unsupported audio format for $path; AudioLoader currently supports WAV")
end

"""Load a RIFF/WAVE audio buffer from disk."""
AudioLoader(path::String) = load_audio(path)

# ========================== Radiance RGBE / HDR decode ==========================

function _rgbe_read_line(bytes::Vector{UInt8}, pos::Int)
    pos <= length(bytes) || error("RGBE file ended before header completed")
    start = pos
    while pos <= length(bytes) && bytes[pos] != UInt8('\n')
        pos += 1
    end
    line_bytes = collect(@view bytes[start:pos-1])
    if !isempty(line_bytes) && line_bytes[end] == UInt8('\r')
        pop!(line_bytes)
    end
    pos <= length(bytes) && bytes[pos] == UInt8('\n') && (pos += 1)
    return String(line_bytes), pos
end

function _rgbe_parse_resolution(line::AbstractString)
    parts = split(strip(line))
    length(parts) == 4 || return nothing
    function axis_token(tok)
        length(tok) == 2 || return nothing
        sign = tok[1]
        axis = tok[2]
        (sign == '+' || sign == '-') || return nothing
        (axis == 'X' || axis == 'Y') || return nothing
        return (axis=axis, sign=sign)
    end
    a1 = axis_token(parts[1])
    a2 = axis_token(parts[3])
    (a1 === nothing || a2 === nothing) && return nothing
    n1 = tryparse(Int, parts[2])
    n2 = tryparse(Int, parts[4])
    (n1 === nothing || n2 === nothing || n1 <= 0 || n2 <= 0) && return nothing
    (a1.axis == 'Y' && a2.axis == 'X') ||
        error("RGBE loader supports Y-major resolution lines like -Y height +X width")
    return (height=n1, width=n2, y_sign=a1.sign, x_sign=a2.sign)
end

@inline _rgbe_value(c::UInt8, e::UInt8) =
    e == 0x00 ? 0.0 : ldexp(Float64(c), Int(e) - 136)

function _rgbe_flat_scanline(bytes::Vector{UInt8}, pos::Int, width::Int)
    needed = 4 * width
    pos + needed - 1 <= length(bytes) || error("RGBE flat scanline is truncated")
    channels = Matrix{UInt8}(undef, 4, width)
    @inbounds for x in 1:width
        base = pos + 4 * (x - 1)
        channels[1, x] = bytes[base]
        channels[2, x] = bytes[base + 1]
        channels[3, x] = bytes[base + 2]
        channels[4, x] = bytes[base + 3]
    end
    return channels, pos + needed
end

function _rgbe_rle_scanline(bytes::Vector{UInt8}, pos::Int, width::Int)
    pos + 3 <= length(bytes) || error("RGBE RLE scanline header is truncated")
    bytes[pos] == 0x02 && bytes[pos + 1] == 0x02 ||
        return _rgbe_flat_scanline(bytes, pos, width)
    (bytes[pos + 2] & 0x80) == 0x00 ||
        error("unsupported old-style RGBE run-length encoding")
    encoded_width = (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
    encoded_width == width ||
        error("RGBE RLE scanline width $encoded_width does not match header width $width")
    pos += 4
    channels = Matrix{UInt8}(undef, 4, width)
    @inbounds for c in 1:4
        x = 1
        while x <= width
            pos <= length(bytes) || error("RGBE RLE scanline is truncated")
            count = Int(bytes[pos])
            pos += 1
            if count > 128
                run = count - 128
                run > 0 || error("RGBE RLE run length must be positive")
                x + run - 1 <= width || error("RGBE RLE run exceeds scanline width")
                pos <= length(bytes) || error("RGBE RLE run value is truncated")
                value = bytes[pos]
                pos += 1
                for i in x:(x + run - 1)
                    channels[c, i] = value
                end
                x += run
            elseif count > 0
                x + count - 1 <= width || error("RGBE RLE literal exceeds scanline width")
                pos + count - 1 <= length(bytes) || error("RGBE RLE literal is truncated")
                for i in x:(x + count - 1)
                    channels[c, i] = bytes[pos]
                    pos += 1
                end
                x += count
            else
                error("RGBE RLE packet length must be positive")
            end
        end
    end
    return channels, pos
end

function _decode_rgbe(bytes::Vector{UInt8})
    line, pos = _rgbe_read_line(bytes, 1)
    (startswith(line, "#?RADIANCE") || startswith(line, "#?RGBE")) ||
        error("not a Radiance RGBE/HDR file")
    have_format = false
    resolution = nothing
    while pos <= length(bytes)
        line, pos = _rgbe_read_line(bytes, pos)
        s = strip(line)
        isempty(s) && continue
        parsed_resolution = _rgbe_parse_resolution(s)
        if parsed_resolution !== nothing
            resolution = parsed_resolution
            break
        elseif startswith(s, "FORMAT=")
            s == "FORMAT=32-bit_rle_rgbe" ||
                error("unsupported RGBE format $(repr(s)); expected FORMAT=32-bit_rle_rgbe")
            have_format = true
        end
    end
    have_format || error("RGBE FORMAT=32-bit_rle_rgbe header is required")
    resolution === nothing && error("RGBE resolution line is missing")

    height = resolution.height
    width = resolution.width
    img = Array{Float64}(undef, height, width, 3)
    use_rle = 8 <= width <= 0x7fff
    @inbounds for sy in 1:height
        channels, pos = use_rle ? _rgbe_rle_scanline(bytes, pos, width) :
                                  _rgbe_flat_scanline(bytes, pos, width)
        row = resolution.y_sign == '-' ? sy : height - sy + 1
        for sx in 1:width
            col = resolution.x_sign == '+' ? sx : width - sx + 1
            e = channels[4, sx]
            img[row, col, 1] = _rgbe_value(channels[1, sx], e)
            img[row, col, 2] = _rgbe_value(channels[2, sx], e)
            img[row, col, 3] = _rgbe_value(channels[3, sx], e)
        end
    end
    return img
end

"""
    load_rgbe(path) -> Array{Float64,3}

Decode a Radiance RGBE/HDR image with `FORMAT=32-bit_rle_rgbe` into a linear
H×W×3 floating-point array. Supports both flat scanlines and the standard
per-channel RLE scanline encoding used by `.hdr` environment maps.
"""
load_rgbe(path::String) = _decode_rgbe(read(path))

"""Alias for [`load_rgbe`](@ref), matching common `.hdr` file naming."""
load_hdr(path::String) = load_rgbe(path)

"""Load a Radiance RGBE/HDR image into a linear [`Texture`]."""
RGBELoader(path::String; colorspace::Symbol=:linear, kwargs...) =
    Texture(load_rgbe(path); colorspace=colorspace, kwargs...)

# ========================== OpenEXR (scanline) ==========================
# Supports scanline images with NONE/ZIP/ZIPS compression and HALF/FLOAT/UINT
# pixels. Tiled, deep, multi-part, and PIZ/PXR24/B44/DWA payloads fail clearly.

const _EXR_MAGIC = 20000630                      # 0x01312f76

@inline _rd_le16(b, i) = UInt16(b[i]) | (UInt16(b[i + 1]) << 8)

@inline function _rd_i32(b, i)                   # signed little-endian int32
    v = _rd_le32(b, i)
    return v >= 0x80000000 ? v - 0x100000000 : v
end

@inline _rd_f32(b, i) = reinterpret(Float32, UInt32(_rd_le32(b, i)))

# IEEE-754 binary16 (half) -> Float64.
@inline function _half_to_float(h::UInt16)
    s = (h >> 15) & 0x0001
    e = (h >> 10) & 0x001f
    m = h & 0x03ff
    if e == 0x0000
        val = m == 0x0000 ? 0.0 : ldexp(Float64(m), -24)        # subnormal: m * 2^-24
    elseif e == 0x001f
        val = m == 0x0000 ? Inf : NaN
    else
        val = ldexp(Float64(Int(m) + 1024), Int(e) - 25)        # (1024+m) * 2^(e-25)
    end
    return s == 0x0001 ? -val : val
end

# Read a NUL-terminated string at 1-based `pos`; return (string, next_pos).
function _exr_str(bytes, pos::Int, stop::Int)
    s = pos
    while pos <= stop && bytes[pos] != 0x00
        pos += 1
    end
    pos <= stop || error("EXR string is not NUL-terminated")
    return String(@view bytes[s:(pos - 1)]), pos + 1
end

# Reverse the ZIP/ZIPS post-process (verified against OpenEXR ImfZip.cpp):
# predictor delta reconstruction, then deinterleave of the two halves.
function _exr_unpredict!(buf::Vector{UInt8})
    @inbounds for i in 2:length(buf)
        buf[i] = UInt8((Int(buf[i - 1]) + Int(buf[i]) - 128) & 0xff)
    end
    return buf
end

function _exr_deinterleave(src::Vector{UInt8})
    n = length(src)
    out = Vector{UInt8}(undef, n)
    half = (n + 1) >> 1
    t1 = 1; t2 = half + 1; s = 1
    @inbounds while s <= n
        out[s] = src[t1]; t1 += 1; s += 1
        s <= n || break
        out[s] = src[t2]; t2 += 1; s += 1
    end
    return out
end

# EXR RLE (PackBits-style) decode, verified against OpenEXR internal_rle.c:
# a non-negative control byte c repeats the next byte c+1 times; a negative
# control byte (c >= 0x80 as signed) copies -c literal bytes.
function _exr_rle_decompress(data::Vector{UInt8}, outsize::Int)
    out = Vector{UInt8}(undef, outsize)
    di = 1; p = 1; n = length(data)
    while di <= outsize
        p <= n || error("EXR RLE stream is truncated")
        c = data[p]; p += 1
        if c >= 0x80                                  # signed-negative -> literal run
            count = 256 - Int(c)
            (p + count - 1 <= n) || error("EXR RLE literal run is truncated")
            (di + count - 1 <= outsize) || error("EXR RLE literal run overflows output")
            @inbounds for k in 0:(count - 1)
                out[di + k] = data[p + k]
            end
            di += count; p += count
        else                                          # non-negative -> repeated run
            count = Int(c) + 1
            p <= n || error("EXR RLE repeat run is truncated")
            b = data[p]; p += 1
            (di + count - 1 <= outsize) || error("EXR RLE repeat run overflows output")
            @inbounds for k in 0:(count - 1)
                out[di + k] = b
            end
            di += count
        end
    end
    return out
end

# PXR24 reconstruction, matching three.js EXRLoader `uncompressPXR`: the
# zlib-inflated data holds, per scanline and channel, MSB-first byte planes
# carrying left-neighbour deltas. HALF keeps 2 bytes; FLOAT keeps the top 3
# bytes of the 32-bit value (the dropped low byte is PXR24's lossy precision).
# UINT is unsupported (three.js does not handle it either).
function _exr_pxr24_decode(raw::Vector{UInt8}, nlines::Int, channels, width::Int)
    out = UInt8[]
    n = length(raw)
    cur = 1                                       # 1-based plane base cursor
    for _ in 1:nlines
        for (_, pt) in channels
            pixel = UInt32(0)
            if pt == 1                            # HALF: 2 planes -> u16
                p0 = cur; p1 = cur + width; cur = p1 + width
                (cur - 1 <= n) || error("EXR PXR24 HALF plane is truncated")
                for j in 0:(width - 1)
                    diff = (UInt32(raw[p0 + j]) << 8) | UInt32(raw[p1 + j])
                    pixel = (pixel + diff) & 0xffff
                    push!(out, UInt8(pixel & 0xff), UInt8((pixel >> 8) & 0xff))
                end
            elseif pt == 2                        # FLOAT: 3 planes -> u32 (low byte 0)
                p0 = cur; p1 = cur + width; p2 = cur + 2width; cur = p2 + width
                (cur - 1 <= n) || error("EXR PXR24 FLOAT plane is truncated")
                for j in 0:(width - 1)
                    diff = (UInt32(raw[p0 + j]) << 24) | (UInt32(raw[p1 + j]) << 16) |
                           (UInt32(raw[p2 + j]) << 8)
                    pixel = pixel + diff           # UInt32 wraps mod 2^32
                    push!(out, UInt8(pixel & 0xff), UInt8((pixel >> 8) & 0xff),
                          UInt8((pixel >> 16) & 0xff), UInt8((pixel >> 24) & 0xff))
                end
            else
                error("EXR PXR24 does not support UINT channels")
            end
        end
    end
    return out
end

# B44/B44A 4x4-block HALF decompression, transcribed from three.js EXRLoader
# `uncompressB44`. HALF channels use 14-byte blocks (or 3-byte flat blocks for
# B44A); other pixel types are stored raw. pLinear channels (rare) are
# unsupported and error clearly. Returns the standard scanline block layout.
function _exr_b44_decode(src::Vector{UInt8}, nlines::Int, channels, plinear,
                         width::Int, isB44A::Bool)
    row_bytes = sum(width * _exr_chan_size(pt) for (_, pt) in channels)
    out = zeros(UInt8, nlines * row_bytes)
    n = length(src)
    so = 1                                        # 1-based read cursor
    cbyte = 0                                     # channel byte offset in a scanline
    for (ci, (_, pt)) in enumerate(channels)
        psize = _exr_chan_size(pt)
        if pt != 1                                # non-HALF: raw scanlines
            for y in 0:(nlines - 1)
                cnt = width * psize
                (so + cnt - 1 <= n) || error("EXR B44 raw channel is truncated")
                base = y * row_bytes + cbyte * width
                @inbounds for k in 0:(cnt - 1)
                    out[base + k + 1] = src[so + k]
                end
                so += cnt
            end
            cbyte += psize
            continue
        end
        plinear[ci] == 0 || error("EXR B44 pLinear channels are not supported")
        nbx = cld(width, 4); nby = cld(nlines, 4)
        block = Vector{UInt16}(undef, 16)
        for by in 0:(nby - 1), bx in 0:(nbx - 1)
            if isB44A && (so + 2 <= n) && src[so + 2] >= 0x34   # 3-byte flat block
                t = (UInt16(src[so]) << 8) | UInt16(src[so + 1])
                h = (t & 0x8000) != 0 ? (t & 0x7fff) : ((~t) & 0xffff)
                fill!(block, h); so += 3
            else
                (so + 13 <= n) || error("EXR B44 block is truncated")
                shift = src[so + 2] >> 2
                bias = UInt32(0x20) << shift
                d(a, q) = (a + (UInt32(q) & 0x3f) * (UInt32(1) << shift) - bias) & 0xffff
                b = so - 1                         # so src[b+1] == three.js src[srcOffset+0]
                s = Vector{UInt32}(undef, 16)
                s[1]  = (UInt32(src[b+1]) << 8) | UInt32(src[b+2])
                s[5]  = d(s[1],  (UInt32(src[b+3]) << 4) | (UInt32(src[b+4]) >> 4))
                s[9]  = d(s[5],  (UInt32(src[b+4]) << 2) | (UInt32(src[b+5]) >> 6))
                s[13] = d(s[9],  src[b+5])
                s[2]  = d(s[1],  UInt32(src[b+6]) >> 2)
                s[6]  = d(s[5],  (UInt32(src[b+6]) << 4) | (UInt32(src[b+7]) >> 4))
                s[10] = d(s[9],  (UInt32(src[b+7]) << 2) | (UInt32(src[b+8]) >> 6))
                s[14] = d(s[13], src[b+8])
                s[3]  = d(s[2],  UInt32(src[b+9]) >> 2)
                s[7]  = d(s[6],  (UInt32(src[b+9]) << 4) | (UInt32(src[b+10]) >> 4))
                s[11] = d(s[10], (UInt32(src[b+10]) << 2) | (UInt32(src[b+11]) >> 6))
                s[15] = d(s[14], src[b+11])
                s[4]  = d(s[3],  UInt32(src[b+12]) >> 2)
                s[8]  = d(s[7],  (UInt32(src[b+12]) << 4) | (UInt32(src[b+13]) >> 4))
                s[12] = d(s[11], (UInt32(src[b+13]) << 2) | (UInt32(src[b+14]) >> 6))
                s[16] = d(s[15], src[b+14])
                @inbounds for i in 1:16
                    ti = s[i] & 0xffff
                    block[i] = (ti & 0x8000) != 0 ? UInt16(ti & 0x7fff) : UInt16((~ti) & 0xffff)
                end
                so += 14
            end
            @inbounds for py in 0:3
                cy = by * 4 + py
                cy >= nlines && continue
                for px in 0:3
                    cx = bx * 4 + px
                    cx >= width && continue
                    val = block[py * 4 + px + 1]
                    oi = cy * row_bytes + cbyte * width + cx * 2
                    out[oi + 1] = UInt8(val & 0xff)
                    out[oi + 2] = UInt8((val >> 8) & 0xff)
                end
            end
        end
        cbyte += 2
    end
    return out
end

_exr_chan_size(pt::Int) = pt == 1 ? 2 : 4        # HALF=2; UINT/FLOAT=4

function _decode_exr(bytes::Vector{UInt8})
    length(bytes) >= 8 || error("EXR file is truncated")
    _rd_le32(bytes, 1) == _EXR_MAGIC || error("not an OpenEXR file (bad magic number)")
    version = _rd_le32(bytes, 5)
    (version & 0xff) == 2 || error("unsupported EXR version $(version & 0xff); only version 2 is supported")
    (version & 0x200) == 0 || error("tiled EXR files are not supported")
    (version & 0x800) == 0 || error("deep EXR files are not supported")
    (version & 0x1000) == 0 || error("multi-part EXR files are not supported")

    n = length(bytes)
    pos = 9
    channels = Tuple{String,Int}[]               # (name, pixelType) in stored order
    plinear = Int[]                              # per-channel pLinear flag (B44)
    compression = -1
    xmin = ymin = xmax = ymax = 0
    have_dw = false
    lineorder = 0

    while pos <= n
        bytes[pos] == 0x00 && (pos += 1; break)  # empty name -> end of header
        name, pos = _exr_str(bytes, pos, n)
        _atype, pos = _exr_str(bytes, pos, n)
        asize = _rd_i32(bytes, pos); pos += 4
        asize >= 0 || error("EXR attribute '$name' has negative size")
        vstart = pos; vstop = pos + asize - 1
        vstop <= n || error("EXR attribute '$name' exceeds the file length")
        if name == "channels"
            cp = vstart
            while cp <= vstop && bytes[cp] != 0x00
                cname, cp = _exr_str(bytes, cp, vstop)
                ptype = _rd_i32(bytes, cp); cp += 4
                pl = Int(bytes[cp]); cp += 4       # pLinear (1) + reserved (3)
                xs = _rd_i32(bytes, cp); cp += 4
                ys = _rd_i32(bytes, cp); cp += 4
                (xs == 1 && ys == 1) || error("EXR subsampled channels are not supported")
                ptype in (0, 1, 2) || error("EXR channel '$cname' has unknown pixel type $ptype")
                push!(channels, (cname, ptype))
                push!(plinear, pl)
            end
        elseif name == "compression"
            compression = Int(bytes[vstart])
        elseif name == "dataWindow"
            xmin = _rd_i32(bytes, vstart);     ymin = _rd_i32(bytes, vstart + 4)
            xmax = _rd_i32(bytes, vstart + 8); ymax = _rd_i32(bytes, vstart + 12)
            have_dw = true
        elseif name == "lineOrder"
            lineorder = Int(bytes[vstart])
        end
        pos = vstop + 1
    end

    have_dw || error("EXR dataWindow attribute is required")
    compression >= 0 || error("EXR compression attribute is required")
    isempty(channels) && error("EXR channels attribute is required")
    width = xmax - xmin + 1
    height = ymax - ymin + 1
    (width > 0 && height > 0) || error("EXR data window is empty")
    lineorder in (0, 1) || error("EXR random-order scanlines are not supported")

    lines_per_block = compression == 0 ? 1 :        # NONE
                      compression == 1 ? 1 :        # RLE
                      compression == 2 ? 1 :        # ZIPS
                      compression == 3 ? 16 :       # ZIP
                      compression == 5 ? 16 :       # PXR24
                      compression == 6 ? 32 :       # B44
                      compression == 7 ? 32 :       # B44A
                      error("EXR compression mode $compression is not supported; only NONE, RLE, ZIP, ZIPS, PXR24, and B44/B44A are implemented")

    cnames = first.(channels)
    found = join(cnames, ", ")
    (("R" in cnames) && ("G" in cnames) && ("B" in cnames)) ||
        error("EXR image must contain R, G, and B channels; found $found")
    row_bytes = sum(width * _exr_chan_size(pt) for (_, pt) in channels)

    nblocks = cld(height, lines_per_block)
    pos + nblocks * 8 - 1 <= n || error("EXR scanline offset table is truncated")
    offsets = (Int(_rd_le64(bytes, pos + 8 * (i - 1))) for i in 1:nblocks)

    img = zeros(Float64, height, width, 3)
    for off in offsets
        bp = off + 1
        bp + 7 <= n || error("EXR scanline block header is truncated")
        y0 = _rd_i32(bytes, bp); bp += 4
        dsize = _rd_i32(bytes, bp); bp += 4
        (dsize >= 0 && bp + dsize - 1 <= n) || error("EXR scanline block data is truncated")
        (ymin <= y0 <= ymax) || error("EXR scanline block has out-of-range y=$y0")
        nlines = min(lines_per_block, ymax - y0 + 1)
        uncompressed = nlines * row_bytes
        raw = if compression == 6 || compression == 7  # B44 / B44A (raw-packed, not zlib)
            _exr_b44_decode(bytes[bp:(bp + dsize - 1)], nlines, channels, plinear, width, compression == 7)
        elseif compression == 0 || dsize >= uncompressed
            bytes[bp:(bp + dsize - 1)]
        elseif compression == 1
            _exr_deinterleave(_exr_unpredict!(_exr_rle_decompress(bytes[bp:(bp + dsize - 1)], uncompressed)))
        elseif compression == 5                       # PXR24
            _exr_pxr24_decode(zlib_inflate(bytes[bp:(bp + dsize - 1)]), nlines, channels, width)
        else                                          # ZIP / ZIPS
            inflated = zlib_inflate(bytes[bp:(bp + dsize - 1)])
            length(inflated) == uncompressed ||
                error("EXR ZIP block inflated to $(length(inflated)) bytes, expected $uncompressed")
            _exr_deinterleave(_exr_unpredict!(inflated))
        end
        length(raw) >= uncompressed || error("EXR scanline block is shorter than its declared pixels")
        rp = 1
        for ln in 0:(nlines - 1)
            yrow = (y0 + ln) - ymin + 1
            for (cname, pt) in channels
                csz = _exr_chan_size(pt)
                outc = cname == "R" ? 1 : cname == "G" ? 2 : cname == "B" ? 3 : 0
                if outc != 0
                    @inbounds for x in 1:width
                        base = rp + (x - 1) * csz
                        img[yrow, x, outc] =
                            pt == 1 ? Float64(_half_to_float(_rd_le16(raw, base))) :
                            pt == 2 ? Float64(_rd_f32(raw, base)) :
                                      Float64(_rd_le32(raw, base))      # UINT
                    end
                end
                rp += width * csz
            end
        end
    end
    return img
end

"""
    load_exr(path) -> Array{Float64,3}

Decode an OpenEXR scanline image into a linear, unclamped `H×W×3` RGB array.
Supports `NONE`, `RLE`, `ZIP`, `ZIPS`, `PXR24`, and `B44`/`B44A` compression and
`HALF`/`FLOAT`/`UINT` channels (`PXR24`/`B44` cover HALF/FLOAT, matching
three.js). Tiled, deep, multi-part, subsampled, `pLinear`-B44, and `PIZ`/`DWA`
payloads raise a clear error rather than being approximated.
"""
load_exr(path::String) = _decode_exr(read(path))

"""Load an OpenEXR scanline image into a linear [`Texture`]."""
EXRLoader(path::String; colorspace::Symbol=:linear, kwargs...) =
    Texture(load_exr(path); colorspace=colorspace, kwargs...)

# ========================== OBJ .mtl materials ==========================

"""
    load_mtl(path) -> Dict{String, MeshPhongMaterial}

Parse a Wavefront .mtl file: `newmtl`, `Kd` (diffuse), `Ks` (specular),
`Ns` (shininess), `Ke` (emissive), `d`/`Tr` (opacity), and `map_Kd`
(diffuse texture).
"""
function _mtl_texture_path(tokens::Vector{SubString{String}})
    numeric_option_max = Dict("-boost"=>1, "-mm"=>2, "-o"=>3, "-s"=>3,
                              "-t"=>3, "-texres"=>1, "-bm"=>1)
    string_option_counts = Dict("-blendu"=>1, "-blendv"=>1, "-clamp"=>1,
                                "-imfchan"=>1, "-type"=>1, "-cc"=>1)
    i = 2
    while i <= length(tokens)
        tok = String(tokens[i])
        if startswith(tok, "-")
            if haskey(numeric_option_max, tok)
                i += 1
                skipped = 0
                while i <= length(tokens) && skipped < numeric_option_max[tok] &&
                      tryparse(Float64, String(tokens[i])) !== nothing
                    i += 1
                    skipped += 1
                end
            else
                i += 1 + get(string_option_counts, tok, 0)
            end
        else
            return join(String.(tokens[i:end]), " ")
        end
    end
    return ""
end

function load_mtl(path::String)
    mats = Dict{String, MeshPhongMaterial}()
    name = ""
    kd = Color3(1.0,1.0,1.0); ks = Color3(0.0,0.0,0.0); ke = Color3(0.0,0.0,0.0)
    ns = 30.0; d = 1.0; diffuse_map = nothing
    dir = dirname(path)
    function flush!()
        isempty(name) && return
        mats[name] = MeshPhongMaterial(color=kd, specular=ks, emissive=ke, shininess=ns,
                                       opacity=d, transparent=(d < 1.0),
                                       map=diffuse_map)
    end
    for raw in eachline(path)
        t = split(strip(raw))
        isempty(t) && continue
        tag = t[1]
        if tag == "newmtl"
            flush!()
            name = t[2]; kd = Color3(1.0,1.0,1.0); ks = Color3(0.0,0.0,0.0)
            ke = Color3(0.0,0.0,0.0); ns = 30.0; d = 1.0; diffuse_map = nothing
        elseif tag == "Kd"; kd = Color3(parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "Ks"; ks = Color3(parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "Ke"; ke = Color3(parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "Ns"; ns = parse(Float64, t[2])
        elseif tag == "d";  d = parse(Float64, t[2])
        elseif tag == "Tr"; d = 1.0 - parse(Float64, t[2])
        elseif tag == "map_Kd"
            texpath = _mtl_texture_path(t)
            isempty(texpath) && error("MTL map_Kd requires a texture path")
            diffuse_map = TextureLoader(isabspath(texpath) ? texpath : joinpath(dir, texpath))
        end
    end
    flush!()
    return mats
end

"""
    load_obj_groups(path) -> (geometry, face_material_names, materials)

Like [`load_obj`](@ref) but also returns, per triangle, the active `usemtl`
name and the material dictionary parsed from any referenced `mtllib`.
"""
function load_obj_groups(path::String)
    verts = Float64[]; file_uvs = Float64[]; file_normals = Float64[]
    out_pos = Float64[]; out_uvs = Float64[]; out_nrm = Float64[]; indices = Int[]
    face_mtl = String[]
    have_normals = false; have_uvs = false; out_vi = 0; cur_mtl = ""
    materials = Dict{String, MeshPhongMaterial}()
    parse_index(tok, n) = (i = parse(Int, tok); i < 0 ? n + i + 1 : i)
    dir = dirname(path)
    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        t = split(line); tag = t[1]
        if tag == "v"
            push!(verts, parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "vt"
            push!(file_uvs, parse(Float64,t[2]), parse(Float64,t[3]))
        elseif tag == "vn"
            push!(file_normals, parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4])); have_normals = true
        elseif tag == "mtllib"
            mp = joinpath(dir, t[2]); isfile(mp) && merge!(materials, load_mtl(mp))
        elseif tag == "usemtl"
            cur_mtl = t[2]
        elseif tag == "f"
            nv = length(verts) ÷ 3; nuv = length(file_uvs) ÷ 2; nn = length(file_normals) ÷ 3
            corners = t[2:end]
            for k in 2:(length(corners) - 1)
                for c in (corners[1], corners[k], corners[k+1])
                    sub = split(c, '/')
                    vidx = parse_index(sub[1], nv); base = (vidx-1)*3
                    push!(out_pos, verts[base+1], verts[base+2], verts[base+3])
                    if length(sub) >= 2 && !isempty(sub[2])
                        uidx = parse_index(sub[2], nuv); ub = (uidx-1)*2
                        push!(out_uvs, file_uvs[ub+1], file_uvs[ub+2])
                        have_uvs = true
                    else
                        push!(out_uvs, 0.0, 0.0)
                    end
                    if have_normals && length(sub) >= 3 && !isempty(sub[3])
                        nidx = parse_index(sub[3], nn); nb = (nidx-1)*3
                        push!(out_nrm, file_normals[nb+1], file_normals[nb+2], file_normals[nb+3])
                    else
                        push!(out_nrm, 0.0, 0.0, 0.0)
                    end
                    out_vi += 1; push!(indices, out_vi)
                end
                push!(face_mtl, cur_mtl)
            end
        end
    end
    nfaces = length(indices) ÷ 3
    geo = BufferGeometry(out_pos, out_nrm, have_uvs ? out_uvs : Float64[],
                         indices, out_vi, nfaces)
    # Recompute smooth normals when the file had none, or when ANY emitted vertex
    # normal is zero-length (some faces lacked vn) — otherwise those vertices
    # keep a degenerate (0,0,0) normal and shade black.
    needs_recompute = !have_normals
    if !needs_recompute
        @inbounds for b in 1:3:length(out_nrm)
            if out_nrm[b] == 0.0 && out_nrm[b+1] == 0.0 && out_nrm[b+2] == 0.0
                needs_recompute = true
                break
            end
        end
    end
    needs_recompute && compute_vertex_normals!(geo)
    return (geo, face_mtl, materials)
end

# ========================== Minimal JSON parser ==========================
# Supports objects, arrays, strings, numbers, true/false/null — enough for glTF.

mutable struct _JSONParser
    s::String
    i::Int
end

function _json_parse(s::String)
    p = _JSONParser(s, 1)
    _json_ws(p)
    v = _json_value(p)
    return v
end

@inline function _json_ws(p)
    n = ncodeunits(p.s)
    while p.i <= n && (p.s[p.i] in (' ', '\t', '\n', '\r'))
        p.i += 1
    end
end

function _json_value(p)
    c = p.s[p.i]
    if c == '{'; return _json_object(p)
    elseif c == '['; return _json_array(p)
    elseif c == '"'; return _json_string(p)
    elseif c == 't'; p.i += 4; return true
    elseif c == 'f'; p.i += 5; return false
    elseif c == 'n'; p.i += 4; return nothing
    else; return _json_number(p)
    end
end

function _json_object(p)
    d = Dict{String, Any}(); p.i += 1; _json_ws(p)
    p.s[p.i] == '}' && (p.i += 1; return d)
    while true
        _json_ws(p); key = _json_string(p); _json_ws(p)
        p.i += 1                                # ':'
        _json_ws(p); d[key] = _json_value(p); _json_ws(p)
        if p.s[p.i] == ','; p.i += 1
        else; p.i += 1; break; end              # '}'
    end
    return d
end

function _json_array(p)
    a = Any[]; p.i += 1; _json_ws(p)
    p.s[p.i] == ']' && (p.i += 1; return a)
    while true
        _json_ws(p); push!(a, _json_value(p)); _json_ws(p)
        if p.s[p.i] == ','; p.i += 1
        else; p.i += 1; break; end              # ']'
    end
    return a
end

function _json_hex_value(c)
    '0' <= c <= '9' && return Int(c - '0')
    'a' <= c <= 'f' && return Int(c - 'a') + 10
    'A' <= c <= 'F' && return Int(c - 'A') + 10
    error("invalid JSON unicode escape")
end

function _json_hex4!(p)
    n = ncodeunits(p.s)
    p.i + 3 <= n || error("incomplete JSON unicode escape")
    v = 0
    for _ in 1:4
        v = (v << 4) | _json_hex_value(p.s[p.i])
        p.i += 1
    end
    return v
end

function _json_string(p)
    p.i += 1; io = IOBuffer()
    n = ncodeunits(p.s)
    while p.i <= n && p.s[p.i] != '"'
        c = p.s[p.i]
        if c == '\\'
            p.i += 1
            p.i <= n || error("unterminated JSON escape")
            e = p.s[p.i]
            if e == 'u'
                p.i += 1
                cp = _json_hex4!(p)
                if 0xD800 <= cp <= 0xDBFF
                    (p.i + 1 <= n && p.s[p.i] == '\\' && p.s[p.i + 1] == 'u') ||
                        error("JSON unicode high surrogate without low surrogate")
                    p.i += 2
                    lo = _json_hex4!(p)
                    0xDC00 <= lo <= 0xDFFF ||
                        error("JSON unicode high surrogate without low surrogate")
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                elseif 0xDC00 <= cp <= 0xDFFF
                    error("JSON unicode low surrogate without high surrogate")
                end
                print(io, Char(cp))
                continue
            elseif e == '"'
                print(io, '"')
            elseif e == '\\'
                print(io, '\\')
            elseif e == '/'
                print(io, '/')
            elseif e == 'b'
                print(io, '\b')
            elseif e == 'f'
                print(io, '\f')
            elseif e == 'n'
                print(io, '\n')
            elseif e == 'r'
                print(io, '\r')
            elseif e == 't'
                print(io, '\t')
            else
                error("unsupported JSON escape: \\$e")
            end
            p.i += 1
        else
            print(io, c)
            p.i = nextind(p.s, p.i)             # skip full (possibly multibyte) char
        end
    end
    p.i <= n || error("unterminated JSON string")
    p.i += 1
    return String(take!(io))
end

function _json_number(p)
    start = p.i; n = ncodeunits(p.s)
    while p.i <= n && (p.s[p.i] in ('-','+','.','e','E','0','1','2','3','4','5','6','7','8','9'))
        p.i += 1
    end
    return parse(Float64, p.s[start:p.i-1])
end

# ========================== FontLoader / typeface JSON ==========================

"""One parsed command from a three.js typeface glyph outline."""
struct FontCommand
    kind::Symbol
    points::Vector{Vec2{Float64}}
end

"""Typeface glyph metadata and parsed outline commands."""
struct FontGlyph
    char::String
    advance_width::Float64
    x_min::Float64
    x_max::Float64
    outline::String
    commands::Vector{FontCommand}
end

"""Decoded three.js typeface JSON font data."""
struct FontData
    family_name::String
    resolution::Float64
    ascender::Float64
    descender::Float64
    glyphs::Dict{String,FontGlyph}
    kernings::Dict{Tuple{String,String},Float64}
end

FontData(family_name, resolution, ascender, descender, glyphs) =
    FontData(String(family_name), Float64(resolution), Float64(ascender),
             Float64(descender), glyphs, Dict{Tuple{String,String},Float64}())

_font_float(d::AbstractDict, key::String, default::Real=0.0) =
    haskey(d, key) && d[key] !== nothing ? Float64(d[key]) : Float64(default)

function _font_parse_outline(outline::AbstractString)
    tokens = split(strip(String(outline)))
    commands = FontCommand[]
    i = 1
    function need(n::Int, cmd)
        i + n - 1 <= length(tokens) || error("font glyph command $cmd is missing coordinates")
    end
    while i <= length(tokens)
        cmd = lowercase(String(tokens[i]))
        i += 1
        if cmd == "m" || cmd == "l"
            need(2, cmd)
            x = parse(Float64, tokens[i])
            y = parse(Float64, tokens[i + 1])
            i += 2
            push!(commands, FontCommand(cmd == "m" ? :move : :line,
                                        [Vec2(x, y)]))
        elseif cmd == "q"
            need(4, cmd)
            c = Vec2(parse(Float64, tokens[i]), parse(Float64, tokens[i + 1]))
            p = Vec2(parse(Float64, tokens[i + 2]), parse(Float64, tokens[i + 3]))
            i += 4
            push!(commands, FontCommand(:quadratic, [c, p]))
        elseif cmd == "b"
            need(6, cmd)
            c1 = Vec2(parse(Float64, tokens[i]), parse(Float64, tokens[i + 1]))
            c2 = Vec2(parse(Float64, tokens[i + 2]), parse(Float64, tokens[i + 3]))
            p = Vec2(parse(Float64, tokens[i + 4]), parse(Float64, tokens[i + 5]))
            i += 6
            push!(commands, FontCommand(:bezier, [c1, c2, p]))
        else
            error("unsupported font glyph outline command $cmd")
        end
    end
    return commands
end

function _font_glyph(char::String, raw)
    raw isa AbstractDict || error("font glyph $char must be a JSON object")
    outline = String(get(raw, "o", ""))
    return FontGlyph(char,
                     _font_float(raw, "ha", _font_float(raw, "x_max", 0.0)),
                     _font_float(raw, "x_min", 0.0),
                     _font_float(raw, "x_max", 0.0),
                     outline,
                     _font_parse_outline(outline))
end

function _font_kerning_amount(raw, context::AbstractString)
    amount = Float64(raw)
    isfinite(amount) || error("font kerning $context must be finite")
    return amount
end

function _font_kerning_pair(raw::AbstractString)
    key = strip(String(raw))
    chars = collect(key)
    if length(chars) == 2
        return string(chars[1]), string(chars[2])
    end
    parts = split(key, r"[\s,]+", keepempty=false)
    length(parts) == 2 && return String(parts[1]), String(parts[2])
    error("font kerning key $(repr(key)) must name two glyphs")
end

function _font_kernings(raw)
    out = Dict{Tuple{String,String},Float64}()
    raw === nothing && return out
    raw isa AbstractDict || error("font kernings must be a JSON object")
    for (left_raw, value) in raw
        left = String(left_raw)
        if value isa AbstractDict
            for (right_raw, amount_raw) in value
                right = String(right_raw)
                out[(left, right)] =
                    _font_kerning_amount(amount_raw, "$(repr(left)) $(repr(right))")
            end
        else
            left_key, right_key = _font_kerning_pair(left)
            out[(left_key, right_key)] =
                _font_kerning_amount(value, repr(left))
        end
    end
    return out
end

function _font_data(raw)
    raw isa AbstractDict || error("font JSON root must be an object")
    haskey(raw, "glyphs") || error("font JSON is missing glyphs")
    glyph_defs = raw["glyphs"]
    glyph_defs isa AbstractDict || error("font glyphs must be an object")
    glyphs = Dict{String,FontGlyph}()
    for (char, glyph_raw) in glyph_defs
        glyphs[String(char)] = _font_glyph(String(char), glyph_raw)
    end
    resolution = _font_float(raw, "resolution", 1000.0)
    resolution > 0 || error("font resolution must be positive")
    return FontData(String(get(raw, "familyName", "")),
                    resolution,
                    _font_float(raw, "ascender", 0.0),
                    _font_float(raw, "descender", 0.0),
                    glyphs,
                    _font_kernings(get(raw, "kernings", get(raw, "kerning", nothing))))
end

"""Load a three.js typeface JSON font."""
load_font(path::String) = _font_data(_json_parse(read(path, String)))

"""Alias for [`load_font`](@ref), matching three.js `FontLoader` naming."""
FontLoader(path::String) = load_font(path)

"""Return the typeface kerning adjustment from `left` to `right`, in font units."""
font_kerning(font::FontData, left::AbstractString, right::AbstractString) =
    get(font.kernings, (String(left), String(right)), 0.0)

function _font_quadratic(p0::Vec2, c::Vec2, p1::Vec2, t::Float64)
    u = 1.0 - t
    return p0 * (u * u) + c * (2.0 * u * t) + p1 * (t * t)
end

function _font_bezier(p0::Vec2, c1::Vec2, c2::Vec2, p1::Vec2, t::Float64)
    u = 1.0 - t
    return p0 * (u * u * u) + c1 * (3.0 * u * u * t) +
           c2 * (3.0 * u * t * t) + p1 * (t * t * t)
end

function _font_push_scaled!(shape::Vector{Vec2{Float64}}, p::Vec2, scale::Float64,
                            offset_x::Float64)
    push!(shape, Vec2(offset_x + p.x * scale, p.y * scale))
end

function _font_scale(font::FontData, size::Real)
    scale = Float64(size) / font.resolution
    isfinite(scale) && scale >= 0.0 ||
        throw(ArgumentError("font size must be finite and non-negative"))
    return scale
end

function _font_curve_segments(curve_segments::Integer)
    curve_segments > 0 || throw(ArgumentError("curve_segments must be positive"))
    curve_segments <= typemax(Int) ||
        throw(ArgumentError("curve_segments is too large"))
    return Int(curve_segments)
end

"""
    font_glyph_shapes(font, char; size=1.0, curve_segments=8, offset_x=0.0)

Flatten one glyph outline from a loaded typeface JSON font into one or more
point loops suitable for `ShapeGeometry` when the glyph outline is simple.
Quadratic (`q`) and cubic (`b`) commands are subdivided into `curve_segments`
line segments.
"""
function font_glyph_shapes(font::FontData, char::AbstractString;
                           size::Real=1.0, curve_segments::Integer=8,
                           offset_x::Real=0.0)
    haskey(font.glyphs, String(char)) || error("font has no glyph for $(repr(String(char)))")
    segments = _font_curve_segments(curve_segments)
    scale = _font_scale(font, size)
    xoff = Float64(offset_x)
    isfinite(xoff) || throw(ArgumentError("offset_x must be finite"))
    glyph = font.glyphs[String(char)]
    shapes = Vector{Vec2{Float64}}[]
    current = Vec2(0.0, 0.0)
    active = Vec2{Float64}[]
    for cmd in glyph.commands
        if cmd.kind === :move
            length(active) >= 2 && push!(shapes, active)
            active = Vec2{Float64}[]
            current = cmd.points[1]
            _font_push_scaled!(active, current, scale, xoff)
        elseif cmd.kind === :line
            current = cmd.points[1]
            _font_push_scaled!(active, current, scale, xoff)
        elseif cmd.kind === :quadratic
            start = current
            control, stop = cmd.points
            for step in 1:segments
                p = _font_quadratic(start, control, stop, step / Float64(segments))
                _font_push_scaled!(active, p, scale, xoff)
            end
            current = stop
        elseif cmd.kind === :bezier
            start = current
            c1, c2, stop = cmd.points
            for step in 1:segments
                p = _font_bezier(start, c1, c2, stop, step / Float64(segments))
                _font_push_scaled!(active, p, scale, xoff)
            end
            current = stop
        else
            error("unsupported font command $(cmd.kind)")
        end
    end
    length(active) >= 2 && push!(shapes, active)
    return shapes
end

"""
    font_text_shapes(font, text; size=1.0, curve_segments=8)

Flatten all available glyph outlines for `text` into point loops. Horizontal
advance uses each glyph's `ha` metric plus any parsed kerning pair adjustment
from the typeface JSON data.
"""
function font_text_shapes(font::FontData, text::AbstractString;
                          size::Real=1.0, curve_segments::Integer=8)
    shapes = Vector{Vec2{Float64}}[]
    cursor = 0.0
    segments = _font_curve_segments(curve_segments)
    scale = _font_scale(font, size)
    previous_key = nothing
    for ch in text
        key = string(ch)
        glyph = get(font.glyphs, key, nothing)
        if glyph !== nothing
            previous_key !== nothing &&
                (cursor += font_kerning(font, previous_key, key) * scale)
            append!(shapes, font_glyph_shapes(font, key; size=size,
                                              curve_segments=segments,
                                              offset_x=cursor))
            cursor += glyph.advance_width * scale
            previous_key = key
        else
            previous_key = nothing
        end
    end
    return shapes
end

function _font_loop_points(shape::Vector{Vec2{Float64}})
    points = Vec2{Float64}[]
    for p in shape
        if isempty(points) || hypot(points[end].x - p.x, points[end].y - p.y) > 1e-9
            push!(points, p)
        end
    end
    if length(points) > 1 && hypot(points[1].x - points[end].x,
                                   points[1].y - points[end].y) <= 1e-9
        pop!(points)
    end
    return points
end

function _font_polygon_area(shape::Vector{Vec2{Float64}})
    area = 0.0
    n = length(shape)
    for i in 1:n
        a = shape[i]
        b = shape[i == n ? 1 : i + 1]
        area += a.x * b.y - b.x * a.y
    end
    return area / 2.0
end

function _font_orient_loop(shape::Vector{Vec2{Float64}}, ccw::Bool)
    area = _font_polygon_area(shape)
    if (area >= 0.0) == ccw
        return copy(shape)
    end
    return reverse(copy(shape))
end

_font_same_point(a::Vec2{Float64}, b::Vec2{Float64}) =
    hypot(a.x - b.x, a.y - b.y) <= 1e-9

function _font_point_in_loop(p::Vec2{Float64}, loop::Vector{Vec2{Float64}})
    inside = false
    n = length(loop)
    j = n
    for i in 1:n
        a = loop[i]
        b = loop[j]
        if ((a.y > p.y) != (b.y > p.y))
            x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
            x > p.x && (inside = !inside)
        end
        j = i
    end
    return inside
end

function _font_loop_groups(loops::Vector{Vector{Vec2{Float64}}})
    clean = [_font_loop_points(loop) for loop in loops]
    clean = [loop for loop in clean if length(loop) >= 3 && abs(_font_polygon_area(loop)) > 1e-12]
    groups = NamedTuple{(:outer, :holes),
                        Tuple{Vector{Vec2{Float64}},Vector{Vector{Vec2{Float64}}}}}[]
    isempty(clean) && return groups
    areas = abs.(_font_polygon_area.(clean))
    direct_parent = fill(0, length(clean))
    for i in eachindex(clean)
        p = clean[i][1]
        best = 0
        best_area = Inf
        for j in eachindex(clean)
            i == j && continue
            areas[j] > areas[i] || continue
            if _font_point_in_loop(p, clean[j]) && areas[j] < best_area
                best = j
                best_area = areas[j]
            end
        end
        direct_parent[i] = best
    end
    for i in eachindex(clean)
        direct_parent[i] == 0 || continue
        outer = _font_orient_loop(clean[i], true)
        holes = Vector{Vec2{Float64}}[]
        for j in eachindex(clean)
            direct_parent[j] == i || continue
            push!(holes, _font_orient_loop(clean[j], false))
        end
        push!(groups, (outer=outer, holes=holes))
    end
    return groups
end

function _font_ray_edge_intersection_x(p::Vec2{Float64}, a::Vec2{Float64},
                                       b::Vec2{Float64})
    abs(a.y - b.y) > 1e-12 || return nothing
    ymin = min(a.y, b.y)
    ymax = max(a.y, b.y)
    (p.y >= ymin && p.y < ymax) || return nothing
    t = (p.y - a.y) / (b.y - a.y)
    (t >= -1e-12 && t <= 1.0 + 1e-12) || return nothing
    x = a.x + (b.x - a.x) * t
    x > p.x + 1e-12 || return nothing
    return x
end

function _font_insert_bridge_point(poly::Vector{Vec2{Float64}},
                                   point::Vec2{Float64}, edge_index::Int)
    a = poly[edge_index]
    b = poly[edge_index == length(poly) ? 1 : edge_index + 1]
    if hypot(point.x - a.x, point.y - a.y) <= 1e-9
        return copy(poly), edge_index
    elseif hypot(point.x - b.x, point.y - b.y) <= 1e-9
        return copy(poly), edge_index == length(poly) ? 1 : edge_index + 1
    end
    out = Vec2{Float64}[]
    append!(out, poly[1:edge_index])
    push!(out, point)
    edge_index < length(poly) && append!(out, poly[edge_index + 1:end])
    return out, edge_index + 1
end

function _font_bridge_one_hole(poly::Vector{Vec2{Float64}},
                               hole::Vector{Vec2{Float64}})
    hidx = argmax([p.x for p in hole])
    hp = hole[hidx]
    best_x = Inf
    best_edge = 0
    for i in eachindex(poly)
        a = poly[i]
        b = poly[i == length(poly) ? 1 : i + 1]
        x = _font_ray_edge_intersection_x(hp, a, b)
        x === nothing && continue
        if x < best_x
            best_x = x
            best_edge = i
        end
    end
    if best_edge == 0
        best_edge = argmin([hypot(p.x - hp.x, p.y - hp.y) for p in poly])
        bridge = poly[best_edge]
    else
        bridge = Vec2(best_x, hp.y)
    end
    bridged_poly, bridge_index = _font_insert_bridge_point(poly, bridge, best_edge)
    ordered_hole = Vec2{Float64}[]
    hidx < length(hole) && append!(ordered_hole, hole[hidx + 1:end])
    hidx > 1 && append!(ordered_hole, hole[1:hidx - 1])
    out = Vec2{Float64}[]
    append!(out, bridged_poly[1:bridge_index])
    push!(out, hp)
    append!(out, ordered_hole)
    push!(out, hp)
    push!(out, bridged_poly[bridge_index])
    bridge_index < length(bridged_poly) && append!(out, bridged_poly[bridge_index + 1:end])
    return out
end

function _font_point_in_triangle(p::Vec2{Float64}, a::Vec2{Float64},
                                 b::Vec2{Float64}, c::Vec2{Float64})
    c1 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    c2 = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
    c3 = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
    return c1 >= -1e-10 && c2 >= -1e-10 && c3 >= -1e-10
end

function _font_triangulate_simple(poly::Vector{Vec2{Float64}})
    points = _font_loop_points(poly)
    length(points) >= 3 || return points, NTuple{3,Int}[]
    _font_polygon_area(points) < 0.0 && reverse!(points)
    remaining = collect(eachindex(points))
    tris = NTuple{3,Int}[]
    guard = 0
    while length(remaining) > 3 && guard < length(points)^2
        guard += 1
        clipped = false
        for pos in eachindex(remaining)
            ip = remaining[pos == 1 ? end : pos - 1]
            ic = remaining[pos]
            inext = remaining[pos == length(remaining) ? 1 : pos + 1]
            a = points[ip]
            b = points[ic]
            c = points[inext]
            cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            cross > 1e-12 || continue
            contains = false
            for other in remaining
                (other == ip || other == ic || other == inext) && continue
                (_font_same_point(points[other], a) ||
                 _font_same_point(points[other], b) ||
                 _font_same_point(points[other], c)) && continue
                if _font_point_in_triangle(points[other], a, b, c)
                    contains = true
                    break
                end
            end
            contains && continue
            push!(tris, (ip, ic, inext))
            deleteat!(remaining, pos)
            clipped = true
            break
        end
        clipped && continue
        break
    end
    if length(remaining) == 3
        a, b, c = remaining
        pa, pb, pc = points[a], points[b], points[c]
        cross = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
        abs(cross) > 1e-12 && push!(tris, cross > 0.0 ? (a, b, c) : (a, c, b))
    end
    length(tris) > 0 || error("font glyph loop triangulation failed")
    return points, tris
end

function _font_triangulate_group(outer::Vector{Vec2{Float64}},
                                 holes::Vector{Vector{Vec2{Float64}}})
    poly = _font_orient_loop(_font_loop_points(outer), true)
    clean_holes = Vector{Vec2{Float64}}[]
    for h in holes
        loop = _font_loop_points(h)
        length(loop) >= 3 || continue
        abs(_font_polygon_area(loop)) > 1e-12 || continue
        push!(clean_holes, _font_orient_loop(loop, false))
    end
    ordered_holes = sort(clean_holes, by=h -> maximum(p.x for p in h),
                         rev=true)
    for hole in ordered_holes
        length(hole) >= 3 || continue
        poly = _font_bridge_one_hole(poly, hole)
    end
    return _font_triangulate_simple(poly)
end

function _font_text_shape_groups(font::FontData, text::AbstractString;
                                 size::Real=1.0,
                                 curve_segments::Integer=8)
    groups = NamedTuple{(:outer, :holes),
                        Tuple{Vector{Vec2{Float64}},Vector{Vector{Vec2{Float64}}}}}[]
    cursor = 0.0
    segments = _font_curve_segments(curve_segments)
    scale = _font_scale(font, size)
    previous_key = nothing
    for ch in text
        key = string(ch)
        glyph = get(font.glyphs, key, nothing)
        if glyph !== nothing
            previous_key !== nothing &&
                (cursor += font_kerning(font, previous_key, key) * scale)
            loops = font_glyph_shapes(font, key; size=size,
                                      curve_segments=segments,
                                      offset_x=cursor)
            append!(groups, _font_loop_groups(loops))
            cursor += glyph.advance_width * scale
            previous_key = key
        else
            previous_key = nothing
        end
    end
    return groups
end

function _font_line_intersection(p1::Vec2{Float64}, d1, p2::Vec2{Float64}, d2)
    denom = d1[1] * d2[2] - d1[2] * d2[1]
    abs(denom) > 1e-12 || return nothing
    qx = p2.x - p1.x
    qy = p2.y - p1.y
    t = (qx * d2[2] - qy * d2[1]) / denom
    return Vec2(p1.x + d1[1] * t, p1.y + d1[2] * t)
end

function _font_inward_normal(a::Vec2{Float64}, b::Vec2{Float64}, ccw::Bool)
    dx = b.x - a.x
    dy = b.y - a.y
    len = hypot(dx, dy)
    len > 0.0 || return (0.0, 0.0)
    return ccw ? (-dy / len, dx / len) : (dy / len, -dx / len)
end

function _font_offset_loop(shape::Vector{Vec2{Float64}}, amount::Float64)
    amount == 0.0 && return copy(shape)
    n = length(shape)
    n >= 3 || return copy(shape)
    ccw = _font_polygon_area(shape) >= 0.0
    out = Vec2{Float64}[]
    for i in 1:n
        prev = shape[i == 1 ? n : i - 1]
        p = shape[i]
        next = shape[i == n ? 1 : i + 1]
        dprev = (p.x - prev.x, p.y - prev.y)
        dnext = (next.x - p.x, next.y - p.y)
        nprev = _font_inward_normal(prev, p, ccw)
        nnext = _font_inward_normal(p, next, ccw)
        l1 = Vec2(p.x + nprev[1] * amount, p.y + nprev[2] * amount)
        l2 = Vec2(p.x + nnext[1] * amount, p.y + nnext[2] * amount)
        hit = _font_line_intersection(l1, dprev, l2, dnext)
        if hit === nothing || !isfinite(hit.x) || !isfinite(hit.y)
            nx = nprev[1] + nnext[1]
            ny = nprev[2] + nnext[2]
            len = hypot(nx, ny)
            hit = len > 0.0 ? Vec2(p.x + nx / len * amount,
                                   p.y + ny / len * amount) : p
        end
        push!(out, hit)
    end
    return out
end

function _font_clean_group(outer::Vector{Vec2{Float64}},
                           holes::Vector{Vector{Vec2{Float64}}})
    clean_outer = _font_loop_points(outer)
    length(clean_outer) >= 3 || return clean_outer, Vector{Vec2{Float64}}[]
    clean_outer = _font_orient_loop(clean_outer, true)
    clean_holes = Vector{Vec2{Float64}}[]
    for hole in holes
        loop = _font_loop_points(hole)
        length(loop) >= 3 || continue
        abs(_font_polygon_area(loop)) > 1e-12 || continue
        push!(clean_holes, _font_orient_loop(loop, false))
    end
    return clean_outer, clean_holes
end

function _font_shape_geometry_with_holes(outer::Vector{Vec2{Float64}},
                                         holes::Vector{Vector{Vec2{Float64}}})
    clean_outer, clean_holes = _font_clean_group(outer, holes)
    length(clean_outer) >= 3 || return BufferGeometry()
    points, tris = _font_triangulate_group(clean_outer, clean_holes)
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    for p in points
        _font_push_geo_vertex!(positions, normals, uvs, p, 0.0,
                               Vec3(0.0, 0.0, 1.0))
    end
    for (a, b, c) in tris
        push!(indices, a, b, c)
    end
    return BufferGeometry(positions, normals, uvs, indices,
                          length(points), length(indices) ÷ 3)
end

function _font_push_geo_vertex!(positions::Vector{Float64}, normals::Vector{Float64},
                                uvs::Vector{Float64}, p::Vec2{Float64},
                                z::Float64, normal::Vec3{Float64})
    push!(positions, p.x, p.y, z)
    push!(normals, normal.x, normal.y, normal.z)
    push!(uvs, p.x, p.y)
    return length(positions) ÷ 3
end

function _font_push_side_quad!(positions::Vector{Float64}, normals::Vector{Float64},
                               uvs::Vector{Float64}, indices::Vector{Int},
                               a::Vec2{Float64}, b::Vec2{Float64},
                               c::Vec2{Float64}, d::Vec2{Float64},
                               za::Float64, zb::Float64)
    ux = b.x - a.x
    uy = b.y - a.y
    vx = d.x - a.x
    vy = d.y - a.y
    vz = zb - za
    normal = normalize(Vec3(uy * vz, -ux * vz, ux * vy - uy * vx))
    i1 = _font_push_geo_vertex!(positions, normals, uvs, a, za, normal)
    i2 = _font_push_geo_vertex!(positions, normals, uvs, b, za, normal)
    i3 = _font_push_geo_vertex!(positions, normals, uvs, c, zb, normal)
    i4 = _font_push_geo_vertex!(positions, normals, uvs, d, zb, normal)
    push!(indices, i1, i2, i3, i1, i3, i4)
end

function _font_push_ring_sides!(positions::Vector{Float64},
                                normals::Vector{Float64},
                                uvs::Vector{Float64},
                                indices::Vector{Int},
                                lo::Vector{Vec2{Float64}},
                                hi::Vector{Vec2{Float64}},
                                za::Float64, zb::Float64)
    n = length(lo)
    n == length(hi) || error("font bevel rings have mismatched vertex counts")
    for i in 1:n
        j = i == n ? 1 : i + 1
        _font_push_side_quad!(positions, normals, uvs, indices,
                              lo[i], lo[j], hi[j], hi[i], za, zb)
    end
end

function _font_extrude_geometry_with_holes(outer::Vector{Vec2{Float64}},
                                           holes::Vector{Vector{Vec2{Float64}}};
                                           depth::Float64)
    clean_outer, clean_holes = _font_clean_group(outer, holes)
    length(clean_outer) >= 3 || return BufferGeometry()
    depth > 0.0 || return _font_shape_geometry_with_holes(clean_outer, clean_holes)
    points, tris = _font_triangulate_group(clean_outer, clean_holes)
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    front = Int[]
    back = Int[]
    for p in points
        push!(front, _font_push_geo_vertex!(positions, normals, uvs, p, 0.0,
                                            Vec3(0.0, 0.0, -1.0)))
    end
    for p in points
        push!(back, _font_push_geo_vertex!(positions, normals, uvs, p, depth,
                                           Vec3(0.0, 0.0, 1.0)))
    end
    for (a, b, c) in tris
        push!(indices, front[a], front[c], front[b])
        push!(indices, back[a], back[b], back[c])
    end
    _font_push_ring_sides!(positions, normals, uvs, indices,
                           clean_outer, clean_outer, 0.0, depth)
    for hole in clean_holes
        _font_push_ring_sides!(positions, normals, uvs, indices,
                               hole, hole, 0.0, depth)
    end
    return BufferGeometry(positions, normals, uvs, indices,
                          length(positions) ÷ 3, length(indices) ÷ 3)
end

function _font_offset_group(outer::Vector{Vec2{Float64}},
                            holes::Vector{Vector{Vec2{Float64}}},
                            amount::Float64)
    offset_outer = _font_offset_loop(outer, amount)
    offset_holes = Vector{Vec2{Float64}}[]
    for hole in holes
        push!(offset_holes, _font_offset_loop(hole, -amount))
    end
    return (outer=offset_outer, holes=offset_holes)
end

function _font_beveled_extrude_geometry(outer::Vector{Vec2{Float64}},
                                        holes::Vector{Vector{Vec2{Float64}}};
                                        depth::Float64,
                                        bevel_size::Float64,
                                        bevel_thickness::Float64,
                                        bevel_segments::Int)
    base_outer, base_holes = _font_clean_group(outer, holes)
    length(base_outer) >= 3 || return BufferGeometry()
    depth > 0.0 || return _font_shape_geometry_with_holes(base_outer, base_holes)
    actual_thickness = min(bevel_thickness, depth / 2.0)
    if bevel_size <= 0.0 || actual_thickness <= 0.0
        return _font_extrude_geometry_with_holes(base_outer, base_holes;
                                                depth=depth)
    end
    layers = NamedTuple{(:outer, :holes),
                        Tuple{Vector{Vec2{Float64}},Vector{Vector{Vec2{Float64}}}}}[]
    zs = Float64[]
    for step in 0:bevel_segments
        t = step / Float64(bevel_segments)
        push!(layers, _font_offset_group(base_outer, base_holes, bevel_size * t))
        push!(zs, actual_thickness * t)
    end
    if depth > 2actual_thickness + 1e-9
        push!(layers, _font_offset_group(base_outer, base_holes, bevel_size))
        push!(zs, depth - actual_thickness)
    end
    for step in (bevel_segments - 1):-1:0
        t = step / Float64(bevel_segments)
        push!(layers, _font_offset_group(base_outer, base_holes, bevel_size * t))
        push!(zs, depth - actual_thickness * t)
    end

    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    bottom = Int[]
    top = Int[]
    bottom_points, bottom_tris = _font_triangulate_group(layers[1].outer,
                                                         layers[1].holes)
    top_points, top_tris = _font_triangulate_group(layers[end].outer,
                                                   layers[end].holes)
    for p in bottom_points
        push!(bottom, _font_push_geo_vertex!(positions, normals, uvs, p, zs[1],
                                             Vec3(0.0, 0.0, -1.0)))
    end
    for p in top_points
        push!(top, _font_push_geo_vertex!(positions, normals, uvs, p, zs[end],
                                          Vec3(0.0, 0.0, 1.0)))
    end
    for (a, b, c) in bottom_tris
        push!(indices, bottom[a], bottom[c], bottom[b])
    end
    for (a, b, c) in top_tris
        push!(indices, top[a], top[b], top[c])
    end
    for ri in 1:(length(layers) - 1)
        lo = layers[ri]
        hi = layers[ri + 1]
        _font_push_ring_sides!(positions, normals, uvs, indices,
                               lo.outer, hi.outer, zs[ri], zs[ri + 1])
        for i in eachindex(lo.holes)
            _font_push_ring_sides!(positions, normals, uvs, indices,
                                   lo.holes[i], hi.holes[i], zs[ri],
                                   zs[ri + 1])
        end
    end
    return BufferGeometry(positions, normals, uvs, indices,
                          length(positions) ÷ 3, length(indices) ÷ 3)
end

function _font_beveled_extrude_geometry(shape::Vector{Vec2{Float64}};
                                        depth::Float64,
                                        bevel_size::Float64,
                                        bevel_thickness::Float64,
                                        bevel_segments::Int)
    return _font_beveled_extrude_geometry(shape, Vector{Vec2{Float64}}[];
                                          depth=depth,
                                          bevel_size=bevel_size,
                                          bevel_thickness=bevel_thickness,
                                          bevel_segments=bevel_segments)
end

"""
    TextGeometry(font, text; size=1.0, curve_segments=8, depth=0.0,
                 bevel_enabled=false, bevel_size=0.0,
                 bevel_thickness=bevel_size, bevel_segments=1)

Build a flat or extruded `BufferGeometry` from loaded typeface JSON outlines.
Glyph contours are grouped into outer loops and simple holes before
triangulation. With beveling enabled, closed contour groups are offset into
bevel rings and extruded with chamfered side bands.
"""
function TextGeometry(font::FontData, text::AbstractString;
                      size::Real=1.0, curve_segments::Integer=8,
                      depth::Real=0.0, bevel_enabled::Bool=false,
                      bevel_size::Real=0.0,
                      bevel_thickness::Real=bevel_size,
                      bevel_segments::Integer=1)
    zdepth = Float64(depth)
    isfinite(zdepth) && zdepth >= 0.0 ||
        throw(ArgumentError("depth must be finite and non-negative"))
    bsize = Float64(bevel_size)
    isfinite(bsize) && bsize >= 0.0 ||
        throw(ArgumentError("bevel_size must be finite and non-negative"))
    bthick = Float64(bevel_thickness)
    isfinite(bthick) && bthick >= 0.0 ||
        throw(ArgumentError("bevel_thickness must be finite and non-negative"))
    bsegs = bevel_enabled ? _font_curve_segments(bevel_segments) : 1
    geos = BufferGeometry[]
    for group in _font_text_shape_groups(font, text; size=size,
                                         curve_segments=curve_segments)
        length(group.outer) >= 3 || continue
        push!(geos, bevel_enabled ?
                    _font_beveled_extrude_geometry(group.outer, group.holes;
                                                   depth=zdepth,
                                                   bevel_size=bsize,
                                                   bevel_thickness=bthick,
                                                   bevel_segments=bsegs) :
                    (zdepth == 0.0 ?
                        _font_shape_geometry_with_holes(group.outer,
                                                        group.holes) :
                        _font_extrude_geometry_with_holes(group.outer,
                                                          group.holes;
                                                          depth=zdepth)))
    end
    isempty(geos) && return BufferGeometry()
    return merge_geometries(geos; with_groups=false)
end

"""Alias accepting text first, matching three.js constructor order."""
TextGeometry(text::AbstractString, font::FontData; kwargs...) =
    TextGeometry(font, text; kwargs...)

# ========================== SVGLoader / basic SVG shapes ==========================

"""Inherited SVG fill/stroke presentation data for one parsed path."""
struct SVGStyle
    fill::Union{Nothing,Color3{Float64}}
    stroke::Union{Nothing,Color3{Float64}}
    stroke_width::Float64
    opacity::Float64
    fill_opacity::Float64
    stroke_opacity::Float64
    stroke_dasharray::Vector{Float64}
    stroke_dashoffset::Float64
    stroke_linecap::Symbol
    stroke_linejoin::Symbol
    stroke_miterlimit::Float64
    fill_rule::Symbol
end

SVGStyle(fill, stroke, stroke_width, opacity, fill_opacity, stroke_opacity) =
    SVGStyle(fill, stroke, Float64(stroke_width), Float64(opacity),
             Float64(fill_opacity), Float64(stroke_opacity), Float64[], 0.0,
             :butt, :miter, 4.0, :nonzero)

SVGStyle(fill, stroke, stroke_width, opacity, fill_opacity, stroke_opacity,
         stroke_dasharray, stroke_dashoffset) =
    SVGStyle(fill, stroke, Float64(stroke_width), Float64(opacity),
             Float64(fill_opacity), Float64(stroke_opacity),
             [Float64(x) for x in stroke_dasharray],
             Float64(stroke_dashoffset), :butt, :miter, 4.0, :nonzero)

SVGStyle(fill, stroke, stroke_width, opacity, fill_opacity, stroke_opacity,
         stroke_dasharray, stroke_dashoffset, stroke_linecap) =
    SVGStyle(fill, stroke, Float64(stroke_width), Float64(opacity),
             Float64(fill_opacity), Float64(stroke_opacity),
             [Float64(x) for x in stroke_dasharray],
             Float64(stroke_dashoffset), stroke_linecap, :miter, 4.0, :nonzero)

SVGStyle(fill, stroke, stroke_width, opacity, fill_opacity, stroke_opacity,
         stroke_dasharray, stroke_dashoffset, stroke_linecap, stroke_linejoin,
         stroke_miterlimit) =
    SVGStyle(fill, stroke, Float64(stroke_width), Float64(opacity),
             Float64(fill_opacity), Float64(stroke_opacity),
             [Float64(x) for x in stroke_dasharray],
             Float64(stroke_dashoffset), stroke_linecap, stroke_linejoin,
             Float64(stroke_miterlimit), :nonzero)

const _SVG_DEFAULT_STYLE =
    SVGStyle(Color3(0.0, 0.0, 0.0), nothing, 1.0, 1.0, 1.0, 1.0)
const _SVG_STYLE_KEYS = ("fill", "stroke", "stroke-width", "opacity",
                         "fill-opacity", "stroke-opacity", "stroke-dasharray",
                         "stroke-dashoffset", "stroke-linecap",
                         "stroke-linejoin", "stroke-miterlimit", "fill-rule",
                         "display", "visibility", "clip-path", "mask", "mask-type")

const _SVG_STATEFUL_PSEUDO_CLASSES = (
    "active", "autofill", "checked", "current", "default", "disabled",
    "enabled", "focus", "focus-visible", "focus-within", "fullscreen",
    "hover", "in-range", "indeterminate", "invalid", "modal", "optional",
    "out-of-range", "past", "paused", "placeholder-shown", "playing",
    "popover-open", "read-only", "read-write", "required", "target",
    "target-within", "user-invalid", "user-valid", "valid", "visited",
)

struct _SVGAttributeSelector
    key::String
    op::Symbol
    value::String
end

struct _SVGPseudoSelector
    name::Symbol
    a::Int
    b::Int
    argument::String
    specificity::Int
end

struct _SVGSimpleSelector
    tag::Union{Nothing,String}
    id::Union{Nothing,String}
    classes::Vector{String}
    attributes::Vector{_SVGAttributeSelector}
    pseudos::Vector{_SVGPseudoSelector}
    specificity::Int
end

struct _SVGStyleRule
    chain::Vector{_SVGSimpleSelector}
    combinators::Vector{Symbol}
    declarations::Dict{String,String}
    specificity::Int
    order::Int
end

"""One parsed SVG primitive or path subpath."""
struct SVGPath
    tag::Symbol
    points::Vector{Vec2{Float64}}
    closed::Bool
    style::SVGStyle
    element_id::Int

    SVGPath(tag::Symbol, points::Vector{Vec2{Float64}}, closed::Bool,
            style::SVGStyle, element_id::Integer) =
        new(tag, points, closed, style, Int(element_id))
    SVGPath(tag::Symbol, points::Vector{Vec2{Float64}}, closed::Bool,
            style::SVGStyle) = new(tag, points, closed, style, 0)
    SVGPath(tag::Symbol, points::Vector{Vec2{Float64}}, closed::Bool) =
        new(tag, points, closed, _SVG_DEFAULT_STYLE, 0)
end

struct _SVGClipDefinition
    paths::Vector{SVGPath}
    units::Symbol
    mask_type::Symbol
end

struct _SVGMaskEntry
    loops::Vector{Vector{Vec2{Float64}}}
    alpha::Float64
    intensity::Float64
end

struct _SVGInsetValue
    value::Float64
    percent::Bool
end

struct _SVGShapeRadius
    kind::Symbol
    value::_SVGInsetValue
end

struct _SVGRectEdge
    value::_SVGInsetValue
    auto::Bool
end

struct _SVGCornerRadii
    x::_SVGInsetValue
    y::_SVGInsetValue
end

struct _SVGClipSpec
    kind::Symbol
    id::Union{Nothing,String}
    inset::NTuple{4,_SVGInsetValue}
    rect::NTuple{4,_SVGRectEdge}
    xywh::NTuple{4,_SVGInsetValue}
    corners::NTuple{4,_SVGCornerRadii}
    radius::_SVGShapeRadius
    radii::NTuple{2,_SVGShapeRadius}
    position::NTuple{2,_SVGInsetValue}
    points::Vector{NTuple{2,_SVGInsetValue}}
    polygon_round::Float64
    path_loops::Vector{Vector{Vec2{Float64}}}
    path_fill_rule::Symbol
    reference_box::Symbol
    segments::Int
end

const _SVG_ZERO_INSET_VALUE = _SVGInsetValue(0.0, false)
const _SVG_ZERO_INSET = (_SVG_ZERO_INSET_VALUE, _SVG_ZERO_INSET_VALUE,
                         _SVG_ZERO_INSET_VALUE, _SVG_ZERO_INSET_VALUE)
const _SVG_CENTER_VALUE = _SVGInsetValue(50.0, true)
const _SVG_DEFAULT_POSITION = (_SVG_CENTER_VALUE, _SVG_CENTER_VALUE)
const _SVG_CLOSEST_SIDE_RADIUS = _SVGShapeRadius(:closest_side,
                                                 _SVG_ZERO_INSET_VALUE)
const _SVG_AUTO_RECT_EDGE = _SVGRectEdge(_SVG_ZERO_INSET_VALUE, true)
const _SVG_ZERO_RECT = (_SVG_AUTO_RECT_EDGE, _SVG_AUTO_RECT_EDGE,
                       _SVG_AUTO_RECT_EDGE, _SVG_AUTO_RECT_EDGE)
const _SVG_ZERO_CORNER_RADII = _SVGCornerRadii(_SVG_ZERO_INSET_VALUE,
                                               _SVG_ZERO_INSET_VALUE)
const _SVG_ZERO_CORNERS = (_SVG_ZERO_CORNER_RADII, _SVG_ZERO_CORNER_RADII,
                           _SVG_ZERO_CORNER_RADII, _SVG_ZERO_CORNER_RADII)

struct _SVGClipApplication
    spec::_SVGClipSpec
    scope::Symbol
    reference_bbox::Union{Nothing,NTuple{4,Float64}}
end

_SVGClipApplication(spec::_SVGClipSpec, scope::Symbol) =
    _SVGClipApplication(spec, scope, nothing)

struct _SVGContainerDefinition
    kind::Symbol
    id::Union{Nothing,String}
    units::Symbol
    bbox_clip::Union{Nothing,_SVGClipApplication}
    bbox_mask::Union{Nothing,_SVGClipApplication}
    mask_type::Symbol
    render_start::Int
end

"""Decoded SVG document with common path, shape, line, bounded URL/basic-shape clipped, and vector-masked primitives converted to point paths."""
struct SVGDocument
    width::Float64
    height::Float64
    paths::Vector{SVGPath}
end

const _SVG_NUMBER_RE =
    r"[-+]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][-+]?\d+)?"
const _SVG_PATH_TOKEN_RE =
    r"[AaCcHhLlMmQqSsTtVvZz]|[-+]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][-+]?\d+)?"
const _SVG_ATTR_RE =
    r"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"
const _SVG_PATH_COMMANDS = Set("AaCcHhLlMmQqSsTtVvZz")

_svg_is_command(token::AbstractString) =
    ncodeunits(token) == 1 && token[1] in _SVG_PATH_COMMANDS

function _svg_lex(raw::AbstractString, re::Regex, context::AbstractString)
    s = String(raw)
    tokens = String[]
    pos = firstindex(s)
    for m in eachmatch(re, s)
        if pos < m.offset
            gap = SubString(s, pos, prevind(s, m.offset))
            occursin(r"[^\s,]", gap) &&
                error("$context contains unsupported syntax near $(repr(String(gap)))")
        end
        push!(tokens, m.match)
        pos = nextind(s, m.offset, length(m.match))
    end
    if pos <= lastindex(s)
        gap = SubString(s, pos, lastindex(s))
        occursin(r"[^\s,]", gap) &&
            error("$context contains unsupported syntax near $(repr(String(gap)))")
    end
    return tokens
end

function _svg_unescape_attr(value::AbstractString)
    return replace(String(value),
                   "&quot;" => "\"",
                   "&apos;" => "'",
                   "&lt;" => "<",
                   "&gt;" => ">",
                   "&amp;" => "&")
end

function _svg_attrs(raw::AbstractString)
    attrs = Dict{String,String}()
    for m in eachmatch(_SVG_ATTR_RE, raw)
        value = m.captures[2] === nothing ? m.captures[3] : m.captures[2]
        attrs[lowercase(m.captures[1])] = _svg_unescape_attr(value)
    end
    return attrs
end

function _svg_style_declarations(raw::AbstractString)
    attrs = Dict{String,String}()
    for decl in split(raw, ';')
        parts = split(decl, ':'; limit=2)
        length(parts) == 2 || continue
        attrs[lowercase(strip(parts[1]))] = strip(parts[2])
    end
    return attrs
end

function _svg_drop_ascii_prefix(s::String, n::Integer)
    n <= 0 && return s
    n >= ncodeunits(s) && return ""
    return s[nextind(s, firstindex(s), n):end]
end

function _svg_unquote_css_attr_value(raw::AbstractString)
    value = String(strip(String(raw)))
    isempty(value) && return nothing
    if (startswith(value, "\"") && endswith(value, "\"")) ||
       (startswith(value, "'") && endswith(value, "'"))
        if ncodeunits(value) == 2
            return ""
        end
        lo = nextind(value, firstindex(value))
        hi = prevind(value, lastindex(value))
        return _svg_unescape_attr(value[lo:hi])
    end
    occursin(r"\s", value) && return nothing
    return _svg_unescape_attr(value)
end

function _svg_attribute_selector(raw::AbstractString)
    s = String(strip(String(raw)))
    m = match(r"^([A-Za-z_:][-A-Za-z0-9_:.]*)$", s)
    if m !== nothing
        return _SVGAttributeSelector(lowercase(m.captures[1]), :exists, "")
    end
    m = match(r"^([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(~=|\|=|\^=|\$=|\*=|=)\s*(.+)$", s)
    if m !== nothing
        value = _svg_unquote_css_attr_value(m.captures[3])
        value === nothing && return nothing
        op = Dict("=" => :equals, "~=" => :includes, "|=" => :dashmatch,
                  "^=" => :prefix, "\$=" => :suffix, "*=" => :substring)[m.captures[2]]
        return _SVGAttributeSelector(lowercase(m.captures[1]), op, value)
    end
    return nothing
end

function _svg_unsupported_selector_syntax(raw::String)
    bracket_depth = 0
    active_quote = nothing
    for ch in raw
        if active_quote !== nothing
            ch == active_quote && (active_quote = nothing)
        elseif ch == '"' || ch == '\''
            active_quote = ch
        elseif ch == '['
            bracket_depth += 1
        elseif ch == ']'
            bracket_depth == 0 && return true
            bracket_depth -= 1
        end
    end
    return active_quote !== nothing || bracket_depth != 0
end

function _svg_split_selector_list(raw::AbstractString)
    selectors = String[]
    buf = IOBuffer()
    bracket_depth = 0
    paren_depth = 0
    active_quote = nothing

    function push_selector!()
        selector = String(strip(String(take!(buf))))
        isempty(selector) && return false
        push!(selectors, selector)
        return true
    end

    for ch in String(raw)
        if active_quote !== nothing
            print(buf, ch)
            ch == active_quote && (active_quote = nothing)
        elseif ch == '"' || ch == '\''
            active_quote = ch
            print(buf, ch)
        elseif ch == '['
            bracket_depth += 1
            print(buf, ch)
        elseif ch == ']'
            bracket_depth == 0 && return nothing
            bracket_depth -= 1
            print(buf, ch)
        elseif ch == '(' && bracket_depth == 0
            paren_depth += 1
            print(buf, ch)
        elseif ch == ')' && bracket_depth == 0
            paren_depth == 0 && return nothing
            paren_depth -= 1
            print(buf, ch)
        elseif ch == ',' && bracket_depth == 0 && paren_depth == 0
            push_selector!() || return nothing
        else
            print(buf, ch)
        end
    end
    active_quote === nothing || return nothing
    bracket_depth == 0 && paren_depth == 0 || return nothing
    push_selector!() || return nothing
    return selectors
end

function _svg_selector_parts(raw::String)
    parts = String[]
    combinators = Symbol[]
    buf = IOBuffer()
    bracket_depth = 0
    paren_depth = 0
    active_quote = nothing

    function push_part!(part::String)
        isempty(part) && return true
        if isempty(parts)
            isempty(combinators) || return false
        elseif length(combinators) == length(parts) - 1
            push!(combinators, :descendant)
        elseif length(combinators) != length(parts)
            return false
        end
        push!(parts, part)
        return true
    end

    for ch in raw
        if active_quote !== nothing
            print(buf, ch)
            ch == active_quote && (active_quote = nothing)
        elseif ch == '"' || ch == '\''
            active_quote = ch
            print(buf, ch)
        elseif ch == '['
            bracket_depth += 1
            print(buf, ch)
        elseif ch == ']'
            bracket_depth == 0 && return nothing
            bracket_depth -= 1
            print(buf, ch)
        elseif ch == '(' && bracket_depth == 0
            paren_depth += 1
            print(buf, ch)
        elseif ch == ')' && bracket_depth == 0
            paren_depth == 0 && return nothing
            paren_depth -= 1
            print(buf, ch)
        elseif (ch == '>' || ch == '+' || ch == '~') &&
               bracket_depth == 0 && paren_depth == 0
            part = String(strip(String(take!(buf))))
            push_part!(part) || return nothing
            isempty(parts) && return nothing
            length(combinators) == length(parts) && return nothing
            combinator = ch == '>' ? :child : (ch == '+' ? :adjacent : :sibling)
            push!(combinators, combinator)
        elseif isspace(ch) && bracket_depth == 0 && paren_depth == 0
            part = String(strip(String(take!(buf))))
            push_part!(part) || return nothing
        else
            print(buf, ch)
        end
    end
    active_quote === nothing || return nothing
    bracket_depth == 0 && paren_depth == 0 || return nothing
    part = String(strip(String(take!(buf))))
    push_part!(part) || return nothing
    isempty(parts) && return nothing
    length(combinators) == length(parts) - 1 || return nothing
    return parts, combinators
end

function _svg_selector_bracket_close(rest::String)
    first(rest) == '[' || return nothing
    active_quote = nothing
    for i in eachindex(rest)
        ch = rest[i]
        if active_quote !== nothing
            ch == active_quote && (active_quote = nothing)
        elseif ch == '"' || ch == '\''
            active_quote = ch
        elseif ch == ']' && i != firstindex(rest)
            return i
        end
    end
    return nothing
end

function _svg_function_argument(rest::String)
    startswith(rest, "(") || return nothing
    active_quote = nothing
    bracket_depth = 0
    paren_depth = 0
    content_start = nextind(rest, firstindex(rest))
    for i in eachindex(rest)
        ch = rest[i]
        if active_quote !== nothing
            ch == active_quote && (active_quote = nothing)
        elseif ch == '"' || ch == '\''
            active_quote = ch
        elseif ch == '['
            bracket_depth += 1
        elseif ch == ']'
            bracket_depth == 0 && return nothing
            bracket_depth -= 1
        elseif ch == '(' && bracket_depth == 0
            paren_depth += 1
        elseif ch == ')' && bracket_depth == 0
            paren_depth == 0 && return nothing
            paren_depth -= 1
            if paren_depth == 0
                content = content_start == i ? "" :
                          rest[content_start:prevind(rest, i)]
                next_idx = nextind(rest, i)
                remainder = next_idx > lastindex(rest) ? "" : rest[next_idx:end]
                return content, remainder
            end
        end
    end
    return nothing
end

function _svg_selector_list_specificity(raw::AbstractString)
    selectors = _svg_split_selector_list(raw)
    selectors === nothing && return nothing
    specificity = 0
    for selector in selectors
        parsed = _svg_selector_chain(selector)
        parsed === nothing && return nothing
        chain, _ = parsed
        specificity = max(specificity, sum(sel.specificity for sel in chain))
    end
    return specificity
end

function _svg_nth_formula(raw::AbstractString)
    s = replace(lowercase(strip(String(raw))), r"\s+" => "")
    isempty(s) && return nothing
    s == "odd" && return (2, 1)
    s == "even" && return (2, 0)
    if !occursin('n', s)
        m = match(r"^[+-]?\d+$", s)
        m === nothing && return nothing
        b = tryparse(Int, s)
        b === nothing && return nothing
        return (0, b)
    end
    count(==('n'), s) == 1 || return nothing
    n_idx = findfirst(==('n'), s)
    prefix = n_idx == firstindex(s) ? "" : s[firstindex(s):prevind(s, n_idx)]
    suffix = n_idx == lastindex(s) ? "" : s[nextind(s, n_idx):lastindex(s)]
    a = if prefix == "" || prefix == "+"
        1
    elseif prefix == "-"
        -1
    elseif match(r"^[+-]?\d+$", prefix) !== nothing
        parsed = tryparse(Int, prefix)
        parsed === nothing && return nothing
        parsed
    else
        return nothing
    end
    b = if suffix == ""
        0
    elseif match(r"^[+-]\d+$", suffix) !== nothing
        parsed = tryparse(Int, suffix)
        parsed === nothing && return nothing
        parsed
    else
        return nothing
    end
    return (a, b)
end

function _svg_pseudo_selector(rest::String)
    m = match(r"^:([A-Za-z-]+)", rest)
    m === nothing && return nothing
    name = lowercase(m.captures[1])
    after = _svg_drop_ascii_prefix(rest, ncodeunits(m.match))
    if name == "root"
        startswith(after, "(") && return nothing
        return _SVGPseudoSelector(:root, 0, 0, "", 10), after
    elseif name == "first-child"
        startswith(after, "(") && return nothing
        return _SVGPseudoSelector(:first_child, 0, 0, "", 10), after
    elseif name == "first-of-type"
        startswith(after, "(") && return nothing
        return _SVGPseudoSelector(:first_of_type, 0, 0, "", 10), after
    elseif name == "nth-child" || name == "nth-of-type"
        parsed_arg = _svg_function_argument(after)
        parsed_arg === nothing && return nothing
        content, remainder = parsed_arg
        formula = _svg_nth_formula(content)
        formula === nothing && return nothing
        symbol = name == "nth-child" ? :nth_child : :nth_of_type
        a, b = formula
        return _SVGPseudoSelector(symbol, a, b, "", 10), remainder
    elseif name == "is" || name == "not" || name == "where"
        parsed_arg = _svg_function_argument(after)
        parsed_arg === nothing && return nothing
        argument, remainder = parsed_arg
        specificity = _svg_selector_list_specificity(argument)
        specificity === nothing && return nothing
        symbol = name == "is" ? :is : (name == "not" ? :not : :where)
        return _SVGPseudoSelector(symbol, 0, 0, String(argument),
                                  symbol === :where ? 0 : specificity), remainder
    elseif name in _SVG_STATEFUL_PSEUDO_CLASSES
        startswith(after, "(") && return nothing
        return _SVGPseudoSelector(:stateful, 0, 0, name, 10), after
    end
    return nothing
end

function _svg_simple_selector(selector::AbstractString)
    raw = String(strip(String(selector)))
    isempty(raw) && return nothing
    _svg_unsupported_selector_syntax(raw) && return nothing

    rest = raw
    tag = nothing
    id = nothing
    classes = String[]
    attributes = _SVGAttributeSelector[]
    pseudos = _SVGPseudoSelector[]
    if startswith(rest, "*")
        rest = _svg_drop_ascii_prefix(rest, 1)
    elseif !startswith(rest, ".") && !startswith(rest, "#") &&
           !startswith(rest, "[") && !startswith(rest, ":")
        m = match(r"^[A-Za-z][A-Za-z0-9_-]*", rest)
        m === nothing && return nothing
        tag = lowercase(m.match)
        rest = _svg_drop_ascii_prefix(rest, ncodeunits(m.match))
    end

    while !isempty(rest)
        prefix = rest[1]
        if prefix == '['
            close_idx = _svg_selector_bracket_close(rest)
            close_idx === nothing && return nothing
            content = rest[nextind(rest, firstindex(rest)):prevind(rest, close_idx)]
            attr = _svg_attribute_selector(content)
            attr === nothing && return nothing
            push!(attributes, attr)
            rest = _svg_drop_ascii_prefix(rest, close_idx)
        elseif prefix == ':'
            parsed = _svg_pseudo_selector(rest)
            parsed === nothing && return nothing
            pseudo, rest = parsed
            push!(pseudos, pseudo)
        else
            (prefix == '.' || prefix == '#') || return nothing
            m = match(r"^[#.][A-Za-z_][A-Za-z0-9_-]*", rest)
            m === nothing && return nothing
            name = m.match[2:end]
            if prefix == '#'
                id === nothing || return nothing
                id = name
            else
                push!(classes, name)
            end
            rest = _svg_drop_ascii_prefix(rest, ncodeunits(m.match))
        end
    end

    specificity = (id === nothing ? 0 : 100) + 10 * length(classes) +
                  10 * length(attributes) +
                  sum((p.specificity for p in pseudos); init=0) +
                  (tag === nothing ? 0 : 1)
    return _SVGSimpleSelector(tag, id, classes, attributes, pseudos, specificity)
end

function _svg_selector_chain(selector::AbstractString)
    raw = String(strip(String(selector)))
    isempty(raw) && return nothing
    _svg_unsupported_selector_syntax(raw) && return nothing
    chain = _SVGSimpleSelector[]
    parsed_parts = _svg_selector_parts(raw)
    parsed_parts === nothing && return nothing
    parts, combinators = parsed_parts
    for part in parts
        parsed = _svg_simple_selector(part)
        parsed === nothing && return nothing
        push!(chain, parsed)
    end
    isempty(chain) && return nothing
    return chain, combinators
end

function _svg_css_rules(raw::AbstractString)
    rules = _SVGStyleRule[]
    order = 0
    for style_match in eachmatch(r"(?is)<\s*style\b[^>]*>(.*?)<\s*/\s*style\s*>",
                                 raw)
        css = replace(style_match.captures[1], "<![CDATA[" => "",
                      "]]>" => "")
        css = replace(css, r"(?s)/\*.*?\*/" => "")
        for block in eachmatch(r"(?s)([^{}]+)\{([^{}]*)\}", css)
            declarations = Dict(k => v for (k, v) in
                                _svg_style_declarations(block.captures[2])
                                if k in _SVG_STYLE_KEYS)
            isempty(declarations) && continue
            selectors = _svg_split_selector_list(block.captures[1])
            selectors === nothing && continue
            for selector in selectors
                parsed = _svg_selector_chain(selector)
                parsed === nothing && continue
                chain, combinators = parsed
                specificity = sum(sel.specificity for sel in chain)
                order += 1
                push!(rules, _SVGStyleRule(chain, combinators, declarations,
                                           specificity, order))
            end
        end
    end
    return rules
end

function _svg_simple_selector_matches(selector::_SVGSimpleSelector, tag::String,
                                      attrs::AbstractDict)
    selector.tag !== nothing && selector.tag != lowercase(tag) && return false
    selector.id !== nothing && get(attrs, "id", "") != selector.id && return false
    if !isempty(selector.classes)
        classes = Set(split(get(attrs, "class", "")))
        all(cls -> cls in classes, selector.classes) || return false
    end
    for attr in selector.attributes
        value = get(attrs, attr.key, nothing)
        if attr.op === :exists
            haskey(attrs, attr.key) || return false
        elseif attr.op === :equals
            value == attr.value || return false
        elseif attr.op === :includes
            value !== nothing || return false
            !isempty(attr.value) || return false
            attr.value in split(value) || return false
        elseif attr.op === :dashmatch
            value !== nothing || return false
            if value != attr.value
                !isempty(attr.value) || return false
                startswith(value, attr.value * "-") || return false
            end
        elseif attr.op === :prefix
            value !== nothing || return false
            !isempty(attr.value) || return false
            startswith(value, attr.value) || return false
        elseif attr.op === :suffix
            value !== nothing || return false
            !isempty(attr.value) || return false
            endswith(value, attr.value) || return false
        elseif attr.op === :substring
            value !== nothing || return false
            !isempty(attr.value) || return false
            occursin(attr.value, value) || return false
        else
            return false
        end
    end
    return true
end

struct _SVGElementContext
    tag::String
    attrs::Dict{String,String}
    ancestors::Vector{_SVGElementContext}
    previous_siblings::Vector{_SVGElementContext}
end

const _SVGAncestorStack = Vector{_SVGElementContext}
const _SVGSiblingStack = Vector{Vector{_SVGElementContext}}

function _svg_element_context(tag::String, attrs::AbstractDict,
                              ancestors::_SVGAncestorStack,
                              siblings::Vector{_SVGElementContext})
    return _SVGElementContext(tag, Dict{String,String}(attrs),
                              copy(ancestors), copy(siblings))
end

function _svg_context_matches(selector::_SVGSimpleSelector,
                              context::_SVGElementContext)
    _svg_simple_selector_matches(selector, context.tag, context.attrs) ||
        return false
    return all(pseudo -> _svg_pseudo_selector_matches(pseudo, context),
               selector.pseudos)
end

function _svg_nth_matches(index::Int, a::Int, b::Int)
    index >= 1 || return false
    a == 0 && return index == b
    delta = index - b
    rem(delta, a) == 0 || return false
    return div(delta, a) >= 0
end

function _svg_selector_list_matches(raw::AbstractString,
                                    context::_SVGElementContext)
    selectors = _svg_split_selector_list(raw)
    selectors === nothing && return false
    for selector in selectors
        parsed = _svg_selector_chain(selector)
        parsed === nothing && return false
        chain, combinators = parsed
        rule = _SVGStyleRule(chain, combinators, Dict{String,String}(), 0, 0)
        _svg_rule_matches(rule, context) && return true
    end
    return false
end

function _svg_pseudo_selector_matches(pseudo::_SVGPseudoSelector,
                                      context::_SVGElementContext)
    child_index = length(context.previous_siblings) + 1
    type_index = count(sibling -> sibling.tag == context.tag,
                       context.previous_siblings) + 1
    if pseudo.name === :root
        return isempty(context.ancestors)
    elseif pseudo.name === :first_child
        return child_index == 1
    elseif pseudo.name === :nth_child
        return _svg_nth_matches(child_index, pseudo.a, pseudo.b)
    elseif pseudo.name === :first_of_type
        return type_index == 1
    elseif pseudo.name === :nth_of_type
        return _svg_nth_matches(type_index, pseudo.a, pseudo.b)
    elseif pseudo.name === :is || pseudo.name === :where
        return _svg_selector_list_matches(pseudo.argument, context)
    elseif pseudo.name === :not
        return !_svg_selector_list_matches(pseudo.argument, context)
    elseif pseudo.name === :stateful
        return false
    end
    return false
end

function _svg_rule_matches(rule::_SVGStyleRule, context::_SVGElementContext)
    _svg_context_matches(rule.chain[end], context) || return false
    current = context
    for selector_idx in (length(rule.chain) - 1):-1:1
        selector = rule.chain[selector_idx]
        combinator = rule.combinators[selector_idx]
        if combinator === :child
            isempty(current.ancestors) && return false
            parent = current.ancestors[end]
            _svg_context_matches(selector, parent) || return false
            current = parent
        elseif combinator === :descendant
            found = false
            for ancestor in Iterators.reverse(current.ancestors)
                if _svg_context_matches(selector, ancestor)
                    found = true
                    current = ancestor
                    break
                end
            end
            found || return false
        elseif combinator === :adjacent
            isempty(current.previous_siblings) && return false
            sibling = current.previous_siblings[end]
            _svg_context_matches(selector, sibling) || return false
            current = sibling
        elseif combinator === :sibling
            found = false
            for sibling in Iterators.reverse(current.previous_siblings)
                if _svg_context_matches(selector, sibling)
                    found = true
                    current = sibling
                    break
                end
            end
            found || return false
        else
            return false
        end
    end
    return true
end

function _svg_css_attrs(tag::String, attrs::AbstractDict,
                        rules::Vector{_SVGStyleRule},
                        context::Union{Nothing,_SVGElementContext}=nothing)
    match_context = context === nothing ?
                    _svg_element_context(tag, attrs, _SVGAncestorStack(),
                                         _SVGElementContext[]) :
                    context
    out = Dict{String,String}()
    for rule in sort([rule for rule in rules
                      if _svg_rule_matches(rule, match_context)];
                     by=rule -> (rule.specificity, rule.order))
        for (key, value) in rule.declarations
            out[key] = value
        end
    end
    return out
end

function _svg_numbers(raw::AbstractString)
    values = Float64[]
    for token in _svg_lex(raw, _SVG_NUMBER_RE, "SVG numeric list")
        v = parse(Float64, token)
        isfinite(v) || error("SVG numeric value must be finite")
        push!(values, v)
    end
    return values
end

function _svg_unit_interval(raw::AbstractString, key::String)
    value = _svg_length(Dict(key => raw), key)
    0.0 <= value <= 1.0 || error("SVG $key must be between 0 and 1")
    return value
end

function _svg_color(raw::AbstractString)
    s = lowercase(strip(String(raw)))
    s == "none" && return nothing
    s == "transparent" && return nothing
    named = Dict(
        "black" => Color3(0.0, 0.0, 0.0),
        "white" => Color3(1.0, 1.0, 1.0),
        "red" => Color3(1.0, 0.0, 0.0),
        "green" => Color3(0.0, 0.5019607843137255, 0.0),
        "blue" => Color3(0.0, 0.0, 1.0),
        "yellow" => Color3(1.0, 1.0, 0.0),
        "cyan" => Color3(0.0, 1.0, 1.0),
        "magenta" => Color3(1.0, 0.0, 1.0),
        "gray" => Color3(0.5019607843137255, 0.5019607843137255, 0.5019607843137255),
        "grey" => Color3(0.5019607843137255, 0.5019607843137255, 0.5019607843137255),
    )
    haskey(named, s) && return named[s]
    if startswith(s, "#")
        hex = s[2:end]
        hex_channel(part) = begin
            value = tryparse(Int, part; base=16)
            value === nothing && error("unsupported SVG color $raw")
            value / 255
        end
        if ncodeunits(hex) == 3
            vals = [hex_channel(string(ch, ch)) for ch in hex]
        elseif ncodeunits(hex) == 6
            vals = [hex_channel(hex[i:i+1]) for i in (1, 3, 5)]
        else
            error("unsupported SVG color $raw")
        end
        return Color3(vals[1], vals[2], vals[3])
    end
    m = match(r"^rgb\((.*)\)$", s)
    if m !== nothing
        parts = strip.(split(m.captures[1], ','))
        length(parts) == 3 || error("SVG rgb() color needs three channels")
        values = Float64[]
        for part in parts
            if endswith(part, "%")
                parsed = tryparse(Float64, part[1:prevind(part, lastindex(part))])
                parsed === nothing && error("unsupported SVG color $raw")
                v = parsed / 100
            else
                parsed = tryparse(Float64, part)
                parsed === nothing && error("unsupported SVG color $raw")
                v = parsed / 255
            end
            isfinite(v) || error("SVG rgb() channel must be finite")
            push!(values, clamp(v, 0.0, 1.0))
        end
        return Color3(values[1], values[2], values[3])
    end
    error("unsupported SVG color $raw")
end

function _svg_cascaded_style_attrs(attrs::AbstractDict,
                                   css_rules::Vector{_SVGStyleRule},
                                   tag::String,
                                   context::Union{Nothing,_SVGElementContext},
                                   keys)
    local_attrs = Dict{String,String}()
    for key in keys
        haskey(attrs, key) && (local_attrs[key] = attrs[key])
    end
    for (key, value) in _svg_css_attrs(tag, attrs, css_rules, context)
        key in keys && (local_attrs[key] = value)
    end
    if haskey(attrs, "style")
        for (key, value) in _svg_style_declarations(attrs["style"])
            key in keys && (local_attrs[key] = value)
        end
    end
    return local_attrs
end

function _svg_style_from_attrs(parent::SVGStyle, attrs::AbstractDict,
                               css_rules::Vector{_SVGStyleRule}=_SVGStyleRule[],
                               tag::String="",
                               context::Union{Nothing,_SVGElementContext}=nothing)
    local_attrs = _svg_cascaded_style_attrs(attrs, css_rules, tag, context,
                                            _SVG_STYLE_KEYS)
    fill = haskey(local_attrs, "fill") ? _svg_color(local_attrs["fill"]) : parent.fill
    stroke = haskey(local_attrs, "stroke") ? _svg_color(local_attrs["stroke"]) : parent.stroke
    stroke_width = haskey(local_attrs, "stroke-width") ?
                   _svg_length(local_attrs, "stroke-width") : parent.stroke_width
    opacity = haskey(local_attrs, "opacity") ?
              _svg_unit_interval(local_attrs["opacity"], "opacity") : parent.opacity
    fill_opacity = haskey(local_attrs, "fill-opacity") ?
                   _svg_unit_interval(local_attrs["fill-opacity"], "fill-opacity") :
                   parent.fill_opacity
    stroke_opacity = haskey(local_attrs, "stroke-opacity") ?
                     _svg_unit_interval(local_attrs["stroke-opacity"], "stroke-opacity") :
                     parent.stroke_opacity
    dasharray = haskey(local_attrs, "stroke-dasharray") ?
                _svg_dasharray(local_attrs["stroke-dasharray"]) :
                copy(parent.stroke_dasharray)
    dashoffset = haskey(local_attrs, "stroke-dashoffset") ?
                 _svg_length(local_attrs, "stroke-dashoffset") :
                 parent.stroke_dashoffset
    linecap = haskey(local_attrs, "stroke-linecap") ?
              _svg_linecap(local_attrs["stroke-linecap"]) :
              parent.stroke_linecap
    linejoin = haskey(local_attrs, "stroke-linejoin") ?
               _svg_linejoin(local_attrs["stroke-linejoin"]) :
               parent.stroke_linejoin
    miterlimit = haskey(local_attrs, "stroke-miterlimit") ?
                 _svg_miterlimit(local_attrs["stroke-miterlimit"]) :
                 parent.stroke_miterlimit
    fill_rule = haskey(local_attrs, "fill-rule") ?
                _svg_fill_rule(local_attrs["fill-rule"]) :
                parent.fill_rule
    stroke_width >= 0.0 || error("SVG stroke-width must be non-negative")
    return SVGStyle(fill, stroke, stroke_width, opacity, fill_opacity,
                    stroke_opacity, dasharray, dashoffset, linecap, linejoin,
                    miterlimit, fill_rule)
end

function _svg_display_visibility(parent_display::Bool, parent_visibility::Symbol,
                                 attrs::AbstractDict,
                                 css_rules::Vector{_SVGStyleRule},
                                 tag::String,
                                 context::Union{Nothing,_SVGElementContext})
    local_attrs = _svg_cascaded_style_attrs(attrs, css_rules, tag, context,
                                            ("display", "visibility"))
    display = lowercase(strip(get(local_attrs, "display", "")))
    display_ok = parent_display && display != "none"
    visibility = parent_visibility
    if haskey(local_attrs, "visibility")
        raw = lowercase(strip(local_attrs["visibility"]))
        if raw == "hidden" || raw == "collapse"
            visibility = :hidden
        elseif raw == "visible"
            visibility = :visible
        elseif raw == "inherit" || raw == ""
            visibility = parent_visibility
        else
            error("unsupported SVG visibility $raw")
        end
    end
    return display_ok, visibility
end

function _svg_length(attrs::AbstractDict, key::String, default::Real=0.0)
    raw = get(attrs, key, nothing)
    raw === nothing && return Float64(default)
    m = match(r"^\s*([-+]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][-+]?\d+)?)\s*(px)?\s*$",
              raw)
    m === nothing && error("unsupported SVG length for $key")
    v = parse(Float64, m.captures[1])
    isfinite(v) || error("SVG length for $key must be finite")
    return v
end

function _svg_dasharray(raw::AbstractString)
    lowercase(strip(String(raw))) == "none" && return Float64[]
    values = Float64[]
    for token in _svg_lex(raw,
                          r"[-+]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][-+]?\d+)?(?:px)?",
                          "SVG stroke-dasharray")
        value = endswith(token, "px") ? token[1:prevind(token, lastindex(token), 2)] : token
        dash = parse(Float64, value)
        isfinite(dash) || error("SVG stroke-dasharray values must be finite")
        dash >= 0.0 || error("SVG stroke-dasharray values must be non-negative")
        push!(values, dash)
    end
    isempty(values) && return Float64[]
    all(iszero, values) && return Float64[]
    isodd(length(values)) && append!(values, copy(values))
    return values
end

function _svg_linecap(raw::AbstractString)
    value = lowercase(strip(String(raw)))
    value == "butt" && return :butt
    value == "round" && return :round
    value == "square" && return :square
    error("unsupported SVG stroke-linecap $raw")
end

function _svg_linejoin(raw::AbstractString)
    value = lowercase(strip(String(raw)))
    value == "miter" && return :miter
    value == "round" && return :round
    value == "bevel" && return :bevel
    error("unsupported SVG stroke-linejoin $raw")
end

function _svg_fill_rule(raw::AbstractString)
    value = lowercase(strip(String(raw)))
    value == "nonzero" && return :nonzero
    value == "evenodd" && return :evenodd
    error("unsupported SVG fill-rule $raw")
end

function _svg_miterlimit(raw::AbstractString)
    value = _svg_length(Dict("stroke-miterlimit" => raw), "stroke-miterlimit")
    value >= 1.0 || error("SVG stroke-miterlimit must be at least 1")
    return value
end

function _svg_root_size(root_attrs::AbstractDict)
    view_box = get(root_attrs, "viewbox", nothing)
    view_numbers = view_box === nothing ? Float64[] : _svg_numbers(view_box)
    (!isempty(view_numbers) && length(view_numbers) != 4) &&
        error("SVG viewBox must contain four numbers")
    width = haskey(root_attrs, "width") ? _svg_length(root_attrs, "width") :
            (length(view_numbers) == 4 ? view_numbers[3] : 0.0)
    height = haskey(root_attrs, "height") ? _svg_length(root_attrs, "height") :
             (length(view_numbers) == 4 ? view_numbers[4] : 0.0)
    return width, height
end

function _svg_root_reference_bbox(root_attrs::AbstractDict, width::Float64,
                                  height::Float64)
    view_box = get(root_attrs, "viewbox", nothing)
    if view_box !== nothing
        values = _svg_numbers(view_box)
        length(values) == 4 || error("SVG viewBox must contain four numbers")
        values[3] > 0.0 && values[4] > 0.0 ||
            error("SVG viewBox width/height must be positive")
        return (values[1], values[2], values[1] + values[3],
                values[2] + values[4])
    end
    return (0.0, 0.0, width, height)
end

function _svg_curve_segments(curve_segments::Integer)
    curve_segments > 0 || throw(ArgumentError("curve_segments must be positive"))
    curve_segments <= typemax(Int) ||
        throw(ArgumentError("curve_segments is too large"))
    return Int(curve_segments)
end

function _svg_circle_segments(circle_segments::Integer)
    circle_segments >= 3 || throw(ArgumentError("circle_segments must be at least 3"))
    circle_segments <= typemax(Int) ||
        throw(ArgumentError("circle_segments is too large"))
    return Int(circle_segments)
end

function _svg_points(raw::AbstractString)
    values = _svg_numbers(raw)
    iseven(length(values)) || error("SVG points attribute must contain x/y pairs")
    points = Vec2{Float64}[]
    for i in 1:2:length(values)
        push!(points, Vec2(values[i], values[i + 1]))
    end
    return points
end

function _svg_rect(attrs::AbstractDict, segments::Int)
    x = _svg_length(attrs, "x", 0.0)
    y = _svg_length(attrs, "y", 0.0)
    w = _svg_length(attrs, "width", 0.0)
    h = _svg_length(attrs, "height", 0.0)
    w < 0.0 && error("SVG rect width must be non-negative")
    h < 0.0 && error("SVG rect height must be non-negative")
    (w == 0.0 || h == 0.0) && return nothing
    has_rx = haskey(attrs, "rx")
    has_ry = haskey(attrs, "ry")
    rx = has_rx ? _svg_length(attrs, "rx") :
         (has_ry ? _svg_length(attrs, "ry") : 0.0)
    ry = has_ry ? _svg_length(attrs, "ry") : rx
    rx < 0.0 && error("SVG rect radius must be non-negative")
    ry < 0.0 && error("SVG rect radius must be non-negative")
    rx = min(rx, w / 2.0)
    ry = min(ry, h / 2.0)
    if rx > 0.0 && ry > 0.0
        points = Vec2{Float64}[]
        function push_point!(p::Vec2{Float64})
            if isempty(points) ||
               hypot(points[end].x - p.x, points[end].y - p.y) > 1e-9
                push!(points, p)
            end
            return nothing
        end
        function push_arc!(cx::Float64, cy::Float64, start_angle, stop_angle)
            for step in 1:segments
                t = step / Float64(segments)
                θ = start_angle + (stop_angle - start_angle) * t
                push_point!(Vec2(cx + rx * cos(θ), cy + ry * sin(θ)))
            end
            return nothing
        end
        push_point!(Vec2(x + rx, y))
        push_point!(Vec2(x + w - rx, y))
        push_arc!(x + w - rx, y + ry, -π / 2.0, 0.0)
        push_point!(Vec2(x + w, y + h - ry))
        push_arc!(x + w - rx, y + h - ry, 0.0, π / 2.0)
        push_point!(Vec2(x + rx, y + h))
        push_arc!(x + rx, y + h - ry, π / 2.0, π)
        push_point!(Vec2(x, y + ry))
        push_arc!(x + rx, y + ry, π, 3π / 2.0)
        if length(points) > 1 &&
           hypot(points[end].x - points[1].x,
                 points[end].y - points[1].y) <= 1e-9
            pop!(points)
        end
        return SVGPath(:rect, points, true)
    end
    return SVGPath(:rect, [Vec2(x, y), Vec2(x + w, y),
                           Vec2(x + w, y + h), Vec2(x, y + h)], true)
end

function _svg_line(attrs::AbstractDict)
    x1 = _svg_length(attrs, "x1", 0.0)
    y1 = _svg_length(attrs, "y1", 0.0)
    x2 = _svg_length(attrs, "x2", 0.0)
    y2 = _svg_length(attrs, "y2", 0.0)
    a = Vec2(x1, y1)
    b = Vec2(x2, y2)
    a == b && return nothing
    return SVGPath(:line, [a, b], false)
end

function _svg_ellipse_points(cx::Float64, cy::Float64, rx::Float64, ry::Float64,
                             segments::Int)
    rx < 0.0 && error("SVG radius must be non-negative")
    ry < 0.0 && error("SVG radius must be non-negative")
    (rx == 0.0 || ry == 0.0) && return Vec2{Float64}[]
    return [Vec2(cx + rx * cos(2π * i / segments),
                 cy + ry * sin(2π * i / segments)) for i in 0:segments-1]
end

_svg_identity_transform() = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

function _svg_compose_transform(a, b)
    aa, ab, ac, ad, ae, af = a
    ba, bb, bc, bd, be, bf = b
    return (aa * ba + ac * bb,
            ab * ba + ad * bb,
            aa * bc + ac * bd,
            ab * bc + ad * bd,
            aa * be + ac * bf + ae,
            ab * be + ad * bf + af)
end

function _svg_apply_transform(t, p::Vec2{Float64})
    a, b, c, d, e, f = t
    return Vec2(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
end

function _svg_transform_path(path::SVGPath, t)
    t == _svg_identity_transform() && return path
    return SVGPath(path.tag, [_svg_apply_transform(t, p) for p in path.points],
                   path.closed, path.style, path.element_id)
end

_svg_style_path(path::SVGPath, style::SVGStyle) =
    SVGPath(path.tag, path.points, path.closed, style, path.element_id)

_svg_element_path(path::SVGPath, element_id::Int) =
    SVGPath(path.tag, path.points, path.closed, path.style, element_id)

function _svg_local_href_id(attrs::AbstractDict)
    raw = get(attrs, "href", get(attrs, "xlink:href", nothing))
    raw === nothing && return nothing
    value = strip(String(raw))
    isempty(value) && return nothing
    startswith(value, "#") && return value[nextind(value, firstindex(value)):end]
    error("unsupported SVG use reference $value")
end

function _svg_clip_path_units(attrs::AbstractDict)
    raw = lowercase(strip(get(attrs, "clippathunits", "userSpaceOnUse")))
    raw == "userspaceonuse" && return :userSpaceOnUse
    raw == "objectboundingbox" && return :objectBoundingBox
    error("unsupported SVG clipPathUnits $raw")
end

function _svg_mask_content_units(attrs::AbstractDict)
    raw = lowercase(strip(get(attrs, "maskcontentunits", "userSpaceOnUse")))
    raw == "userspaceonuse" && return :userSpaceOnUse
    raw == "objectboundingbox" && return :objectBoundingBox
    error("unsupported SVG maskContentUnits $raw")
end

function _svg_mask_type(attrs::AbstractDict,
                        css_rules::Vector{_SVGStyleRule},
                        tag::String,
                        context::Union{Nothing,_SVGElementContext})
    local_attrs = _svg_cascaded_style_attrs(attrs, css_rules, tag, context,
                                            ("mask-type",))
    raw = lowercase(strip(get(local_attrs, "mask-type", "luminance")))
    raw == "luminance" && return :luminance
    raw == "alpha" && return :alpha
    error("unsupported SVG mask-type $raw")
end

function _svg_clip_spec(kind::Symbol; id::Union{Nothing,AbstractString}=nothing,
                        inset::NTuple{4,_SVGInsetValue}=_SVG_ZERO_INSET,
                        rect::NTuple{4,_SVGRectEdge}=_SVG_ZERO_RECT,
                        xywh::NTuple{4,_SVGInsetValue}=_SVG_ZERO_INSET,
                        corners::NTuple{4,_SVGCornerRadii}=_SVG_ZERO_CORNERS,
                        radius::_SVGShapeRadius=_SVG_CLOSEST_SIDE_RADIUS,
                        radii::NTuple{2,_SVGShapeRadius}=(_SVG_CLOSEST_SIDE_RADIUS,
                                                          _SVG_CLOSEST_SIDE_RADIUS),
                        position::NTuple{2,_SVGInsetValue}=_SVG_DEFAULT_POSITION,
                        points::Vector{NTuple{2,_SVGInsetValue}}=NTuple{2,_SVGInsetValue}[],
                        polygon_round::Float64=0.0,
                        path_loops::Vector{Vector{Vec2{Float64}}}=Vector{Vec2{Float64}}[],
                        path_fill_rule::Symbol=:nonzero,
                        reference_box::Symbol=:fillBox,
                        segments::Int=32)
    return _SVGClipSpec(kind, id === nothing ? nothing : String(id), inset,
                        rect, xywh, corners, radius, radii, position, points,
                        polygon_round, path_loops, path_fill_rule, reference_box,
                        segments)
end

function _svg_clip_spec_reference_box(spec::_SVGClipSpec, reference_box::Symbol)
    return _SVGClipSpec(spec.kind, spec.id, spec.inset, spec.rect, spec.xywh,
                        spec.corners, spec.radius, spec.radii, spec.position,
                        spec.points, spec.polygon_round, spec.path_loops,
                        spec.path_fill_rule, reference_box, spec.segments)
end

_svg_url_clip_spec(id::AbstractString, circle_segments::Int) =
    _svg_clip_spec(:url; id, segments=circle_segments)
_svg_inset_clip_spec(inset::NTuple{4,_SVGInsetValue},
                     corners::NTuple{4,_SVGCornerRadii},
                     circle_segments::Int) =
    _svg_clip_spec(:inset; inset, corners, segments=circle_segments)
_svg_rect_clip_spec(rect::NTuple{4,_SVGRectEdge},
                    corners::NTuple{4,_SVGCornerRadii},
                    circle_segments::Int) =
    _svg_clip_spec(:rect; rect, corners, segments=circle_segments)
_svg_xywh_clip_spec(xywh::NTuple{4,_SVGInsetValue},
                    corners::NTuple{4,_SVGCornerRadii},
                    circle_segments::Int) =
    _svg_clip_spec(:xywh; xywh, corners, segments=circle_segments)
_svg_circle_clip_spec(radius::_SVGShapeRadius,
                      position::NTuple{2,_SVGInsetValue},
                      circle_segments::Int) =
    _svg_clip_spec(:circle; radius, position, segments=circle_segments)
_svg_ellipse_clip_spec(radii::NTuple{2,_SVGShapeRadius},
                       position::NTuple{2,_SVGInsetValue},
                       circle_segments::Int) =
    _svg_clip_spec(:ellipse; radii, position, segments=circle_segments)
_svg_polygon_clip_spec(points::Vector{NTuple{2,_SVGInsetValue}},
                       polygon_round::Float64,
                       circle_segments::Int) =
    _svg_clip_spec(:polygon; points, polygon_round, segments=circle_segments)
_svg_path_clip_spec(path_loops::Vector{Vector{Vec2{Float64}}},
                    fill_rule::Symbol,
                    circle_segments::Int) =
    _svg_clip_spec(:path; path_loops, path_fill_rule=fill_rule,
                   segments=circle_segments)

const _SVG_LENGTH_PERCENT_RE =
    r"^([-+]?(?:(?:\d+\.\d*)|(?:\.\d+)|(?:\d+))(?:[eE][-+]?\d+)?)(%|px)?$"

function _svg_length_percentage_value(raw::AbstractString,
                                      context::AbstractString;
                                      nonnegative::Bool=false)
    value = strip(String(raw))
    m = match(_SVG_LENGTH_PERCENT_RE, value)
    m === nothing && error("unsupported $context $raw")
    amount = parse(Float64, m.captures[1])
    isfinite(amount) || error("$context must be finite")
    nonnegative && amount < 0.0 && error("$context must be non-negative")
    return _SVGInsetValue(amount, m.captures[2] == "%")
end

_svg_inset_value(raw::AbstractString) =
    _svg_length_percentage_value(raw, "SVG clip-path inset value")

function _svg_basic_shape_value_tokens(raw::AbstractString)
    return split(replace(replace(strip(String(raw)), "," => " "), "/" => " / "))
end

function _svg_rectangular_round_tokens(raw::AbstractString,
                                       context::AbstractString)
    tokens = _svg_basic_shape_value_tokens(raw)
    round_indexes = findall(token -> lowercase(String(token)) == "round", tokens)
    length(round_indexes) > 1 && error("$context contains multiple round keywords")
    isempty(round_indexes) && return tokens, _SVG_ZERO_CORNERS
    round_index = only(round_indexes)
    round_index == length(tokens) && error("$context round corners are missing")
    main = tokens[1:(round_index - 1)]
    corners = _svg_corner_radii(tokens[(round_index + 1):end], context)
    return main, corners
end

function _svg_radius_values(tokens::Vector{SubString{String}},
                            context::AbstractString)
    1 <= length(tokens) <= 4 || error("$context needs one to four radius values")
    values = [_svg_length_percentage_value(token, "$context radius";
                                           nonnegative=true)
              for token in tokens]
    top_left = values[1]
    top_right = length(values) >= 2 ? values[2] : values[1]
    bottom_right = length(values) >= 3 ? values[3] : values[1]
    bottom_left = length(values) >= 4 ? values[4] : top_right
    return (top_left, top_right, bottom_right, bottom_left)
end

function _svg_corner_radii(tokens::Vector{SubString{String}},
                           context::AbstractString)
    slash_indexes = findall(token -> String(token) == "/", tokens)
    length(slash_indexes) > 1 && error("$context round corners contain multiple slashes")
    if isempty(slash_indexes)
        x_values = _svg_radius_values(tokens, context)
        y_values = x_values
    else
        slash_index = only(slash_indexes)
        (slash_index > 1 && slash_index < length(tokens)) ||
            error("$context round corners need radii on both sides of /")
        x_values = _svg_radius_values(tokens[1:(slash_index - 1)], context)
        y_values = _svg_radius_values(tokens[(slash_index + 1):end], context)
    end
    return (_SVGCornerRadii(x_values[1], y_values[1]),
            _SVGCornerRadii(x_values[2], y_values[2]),
            _SVGCornerRadii(x_values[3], y_values[3]),
            _SVGCornerRadii(x_values[4], y_values[4]))
end

function _svg_inset_values(raw::AbstractString)
    tokens, corners = _svg_rectangular_round_tokens(raw, "SVG clip-path inset")
    1 <= length(tokens) <= 4 || error("SVG clip-path inset needs 1 to 4 values")
    values = [_svg_inset_value(token) for token in tokens]
    top = values[1]
    right = length(values) >= 2 ? values[2] : values[1]
    bottom = length(values) >= 3 ? values[3] : values[1]
    left = length(values) >= 4 ? values[4] : right
    return (top, right, bottom, left), corners
end

function _svg_rect_edge_value(raw::AbstractString)
    value = lowercase(strip(String(raw)))
    value == "auto" && return _SVG_AUTO_RECT_EDGE
    return _SVGRectEdge(_svg_length_percentage_value(raw,
                                                     "SVG clip-path rect value"),
                        false)
end

function _svg_rect_clip_spec(raw::AbstractString, circle_segments::Int)
    tokens, corners = _svg_rectangular_round_tokens(raw, "SVG clip-path rect")
    length(tokens) == 4 || error("SVG clip-path rect needs four values")
    rect = (_svg_rect_edge_value(tokens[1]), _svg_rect_edge_value(tokens[2]),
            _svg_rect_edge_value(tokens[3]), _svg_rect_edge_value(tokens[4]))
    return _svg_rect_clip_spec(rect, corners, circle_segments)
end

function _svg_xywh_clip_spec(raw::AbstractString, circle_segments::Int)
    tokens, corners = _svg_rectangular_round_tokens(raw, "SVG clip-path xywh")
    length(tokens) == 4 || error("SVG clip-path xywh needs four values")
    x = _svg_length_percentage_value(tokens[1], "SVG clip-path xywh x value")
    y = _svg_length_percentage_value(tokens[2], "SVG clip-path xywh y value")
    width = _svg_length_percentage_value(tokens[3],
                                         "SVG clip-path xywh width";
                                         nonnegative=true)
    height = _svg_length_percentage_value(tokens[4],
                                          "SVG clip-path xywh height";
                                          nonnegative=true)
    return _svg_xywh_clip_spec((x, y, width, height), corners, circle_segments)
end

function _svg_shape_radius(raw::AbstractString, context::AbstractString)
    value = lowercase(strip(String(raw)))
    value == "closest-side" && return _SVGShapeRadius(:closest_side,
                                                      _SVG_ZERO_INSET_VALUE)
    value == "farthest-side" && return _SVGShapeRadius(:farthest_side,
                                                       _SVG_ZERO_INSET_VALUE)
    return _SVGShapeRadius(:length,
                           _svg_length_percentage_value(raw, context;
                                                        nonnegative=true))
end

function _svg_basic_shape_tokens(raw::AbstractString, context::AbstractString)
    value = strip(String(raw))
    isempty(value) && return String[]
    occursin(',', value) && error("$context contains unsupported comma syntax")
    return String.(split(value))
end

function _svg_split_basic_shape_at(tokens::Vector{String},
                                   context::AbstractString)
    at_positions = findall(token -> lowercase(token) == "at", tokens)
    length(at_positions) > 1 && error("$context contains multiple at keywords")
    if isempty(at_positions)
        return tokens, String[]
    end
    at_index = only(at_positions)
    at_index == length(tokens) && error("$context position is missing")
    return tokens[1:(at_index - 1)], tokens[(at_index + 1):end]
end

function _svg_position_axis(token::AbstractString)
    value = lowercase(strip(String(token)))
    value in ("left", "x-start") && return :x
    value in ("right", "x-end") && return :x
    value in ("top", "y-start") && return :y
    value in ("bottom", "y-end") && return :y
    value == "center" && return :both
    match(_SVG_LENGTH_PERCENT_RE, value) !== nothing && return :length
    return nothing
end

function _svg_position_value(token::AbstractString, axis::Symbol)
    value = lowercase(strip(String(token)))
    if axis === :x
        (value == "left" || value == "x-start") &&
            return _SVGInsetValue(0.0, true)
        (value == "right" || value == "x-end") &&
            return _SVGInsetValue(100.0, true)
    elseif axis === :y
        (value == "top" || value == "y-start") &&
            return _SVGInsetValue(0.0, true)
        (value == "bottom" || value == "y-end") &&
            return _SVGInsetValue(100.0, true)
    end
    value == "center" && return _SVG_CENTER_VALUE
    return _svg_length_percentage_value(token,
                                        "SVG clip-path basic-shape position value")
end

function _svg_basic_shape_position(tokens::Vector{String},
                                   context::AbstractString)
    isempty(tokens) && return _SVG_DEFAULT_POSITION
    length(tokens) <= 2 ||
        error("$context supports one- or two-value positions")
    axes = [_svg_position_axis(token) for token in tokens]
    any(axis -> axis === nothing, axes) &&
        error("unsupported SVG clip-path basic-shape position $(join(tokens, " "))")
    if length(tokens) == 1
        axis = axes[1]
        if axis === :y
            return (_SVG_CENTER_VALUE, _svg_position_value(tokens[1], :y))
        else
            return (_svg_position_value(tokens[1], :x), _SVG_CENTER_VALUE)
        end
    end

    a1, a2 = axes
    if (a1 === :x || a1 === :both) && (a2 === :y || a2 === :both)
        return (_svg_position_value(tokens[1], :x),
                _svg_position_value(tokens[2], :y))
    elseif a1 === :y && (a2 === :x || a2 === :both)
        return (_svg_position_value(tokens[2], :x),
                _svg_position_value(tokens[1], :y))
    elseif a1 === :length && (a2 === :length || a2 === :y || a2 === :both)
        return (_svg_position_value(tokens[1], :x),
                _svg_position_value(tokens[2], :y))
    elseif (a1 === :x || a1 === :both) && a2 === :length
        return (_svg_position_value(tokens[1], :x),
                _svg_position_value(tokens[2], :y))
    elseif a1 === :y && a2 === :length
        return (_svg_position_value(tokens[2], :x),
                _svg_position_value(tokens[1], :y))
    end
    error("unsupported SVG clip-path basic-shape position $(join(tokens, " "))")
end

function _svg_circle_clip_spec(raw::AbstractString, circle_segments::Int)
    tokens = _svg_basic_shape_tokens(raw, "SVG clip-path circle")
    radius_tokens, position_tokens = _svg_split_basic_shape_at(tokens,
                                                               "SVG clip-path circle")
    length(radius_tokens) <= 1 ||
        error("SVG clip-path circle needs zero or one radius")
    radius = isempty(radius_tokens) ? _SVG_CLOSEST_SIDE_RADIUS :
             _svg_shape_radius(radius_tokens[1],
                               "SVG clip-path circle radius")
    position = _svg_basic_shape_position(position_tokens,
                                         "SVG clip-path circle")
    return _svg_circle_clip_spec(radius, position, circle_segments)
end

function _svg_ellipse_clip_spec(raw::AbstractString, circle_segments::Int)
    tokens = _svg_basic_shape_tokens(raw, "SVG clip-path ellipse")
    radius_tokens, position_tokens = _svg_split_basic_shape_at(tokens,
                                                               "SVG clip-path ellipse")
    radii = if isempty(radius_tokens)
        (_SVG_CLOSEST_SIDE_RADIUS, _SVG_CLOSEST_SIDE_RADIUS)
    elseif length(radius_tokens) == 1
        radius = _svg_shape_radius(radius_tokens[1],
                                   "SVG clip-path ellipse radius")
        radius.kind === :length &&
            error("SVG clip-path ellipse needs zero, one keyword, or two radii")
        (radius, radius)
    elseif length(radius_tokens) == 2
        (_svg_shape_radius(radius_tokens[1],
                           "SVG clip-path ellipse x radius"),
         _svg_shape_radius(radius_tokens[2],
                           "SVG clip-path ellipse y radius"))
    else
        error("SVG clip-path ellipse needs zero, one keyword, or two radii")
    end
    position = _svg_basic_shape_position(position_tokens,
                                         "SVG clip-path ellipse")
    return _svg_ellipse_clip_spec(radii, position, circle_segments)
end

function _svg_polygon_round_value(raw::AbstractString)
    radius = _svg_length_percentage_value(raw, "SVG clip-path polygon round radius";
                                          nonnegative=true)
    radius.percent &&
        error("SVG clip-path polygon round radius must be a length")
    return radius.value
end

function _svg_polygon_header!(raw_points::Vector{String})
    isempty(raw_points) && error("SVG clip-path polygon needs at least three points")
    tokens = _svg_basic_shape_value_tokens(raw_points[1])
    isempty(tokens) && error("SVG clip-path polygon contains an empty component")
    head = lowercase(String(tokens[1]))
    is_header = head == "nonzero" || head == "evenodd" || head == "round"
    is_header || return 0.0

    index = 1
    if head == "nonzero" || head == "evenodd"
        index += 1
    end
    polygon_round = 0.0
    if index <= length(tokens) && lowercase(String(tokens[index])) == "round"
        index += 1
        index <= length(tokens) ||
            error("SVG clip-path polygon round radius is missing")
        polygon_round = _svg_polygon_round_value(tokens[index])
        index += 1
    end
    index > length(tokens) ||
        error("unsupported SVG clip-path polygon header $(raw_points[1])")
    popfirst!(raw_points)
    return polygon_round
end

function _svg_polygon_clip_spec(raw::AbstractString, circle_segments::Int)
    value = strip(String(raw))
    raw_points = String.(strip.(split(value, ",")))
    filter!(!isempty, raw_points)
    isempty(raw_points) && error("SVG clip-path polygon needs at least three points")
    polygon_round = _svg_polygon_header!(raw_points)
    length(raw_points) >= 3 ||
        error("SVG clip-path polygon needs at least three points")
    points = NTuple{2,_SVGInsetValue}[]
    for raw_point in raw_points
        tokens = _svg_basic_shape_tokens(raw_point,
                                         "SVG clip-path polygon point")
        length(tokens) == 2 ||
            error("SVG clip-path polygon points need x/y pairs")
        push!(points, (_svg_length_percentage_value(tokens[1],
                                                    "SVG clip-path polygon point value"),
                       _svg_length_percentage_value(tokens[2],
                                                    "SVG clip-path polygon point value")))
    end
    return _svg_polygon_clip_spec(points, polygon_round, circle_segments)
end

function _svg_split_css_function_args(raw::AbstractString, context::AbstractString)
    args = String[]
    buf = IOBuffer()
    active_quote = nothing
    escaped = false

    function push_arg!()
        arg = String(strip(String(take!(buf))))
        isempty(arg) && error("$context contains an empty argument")
        push!(args, arg)
        return nothing
    end

    for ch in String(raw)
        if active_quote !== nothing
            print(buf, ch)
            if escaped
                escaped = false
            elseif ch == '\\'
                escaped = true
            elseif ch == active_quote
                active_quote = nothing
            end
        elseif ch == '"' || ch == '\''
            active_quote = ch
            print(buf, ch)
        elseif ch == ','
            push_arg!()
        else
            print(buf, ch)
        end
    end
    active_quote === nothing || error("$context contains an unterminated string")
    escaped && error("$context contains an unterminated escape")
    push_arg!()
    return args
end

function _svg_css_string(raw::AbstractString, context::AbstractString)
    value = strip(String(raw))
    ncodeunits(value) >= 2 || error("$context needs a quoted path string")
    quote_char = value[firstindex(value)]
    (quote_char == '"' || quote_char == '\'') || error("$context needs a quoted path string")
    value[lastindex(value)] == quote_char || error("$context contains an unterminated string")
    buf = IOBuffer()
    escaped = false
    lo = nextind(value, firstindex(value))
    hi = prevind(value, lastindex(value))
    lo > hi && return ""
    for ch in value[lo:hi]
        if escaped
            print(buf, ch)
            escaped = false
        elseif ch == '\\'
            escaped = true
        else
            print(buf, ch)
        end
    end
    escaped && error("$context contains an unterminated escape")
    return String(take!(buf))
end

function _svg_path_clip_spec(raw::AbstractString, curve_segments::Int,
                             circle_segments::Int)
    args = _svg_split_css_function_args(raw, "SVG clip-path path")
    length(args) <= 2 || error("SVG clip-path path needs a string or fill-rule and string")
    fill_rule = :nonzero
    path_arg = if length(args) == 1
        args[1]
    else
        raw_fill_rule = lowercase(strip(args[1]))
        (raw_fill_rule == "nonzero" || raw_fill_rule == "evenodd") ||
            error("unsupported SVG clip-path path fill-rule $(args[1])")
        fill_rule = Symbol(raw_fill_rule)
        args[2]
    end
    path_data = _svg_css_string(path_arg, "SVG clip-path path")
    raw_paths = _svg_path_points(path_data, curve_segments)
    isempty(raw_paths) && error("SVG clip-path path must define a non-empty path")
    loops = Vector{Vec2{Float64}}[]
    for path in raw_paths
        length(path.points) >= 3 ||
            error("SVG clip-path path must contain closed areas")
        loop = _font_loop_points(path.points)
        length(loop) >= 3 && abs(_font_polygon_area(loop)) > 1e-12 ||
            error("SVG clip-path path must define a non-empty path")
        push!(loops, loop)
    end
    return _svg_path_clip_spec(loops, fill_rule, circle_segments)
end

const _SVG_SHAPE_BOX_MAP = Dict(
    "content-box" => :cssLayoutBox,
    "fill-box" => :fillBox,
    "padding-box" => :cssLayoutBox,
    "border-box" => :cssLayoutBox,
    "margin-box" => :cssLayoutBox,
    "stroke-box" => :strokeBox,
    "view-box" => :viewBox,
)

function _svg_parse_shape_box(raw::AbstractString)
    token = lowercase(strip(String(raw)))
    haskey(_SVG_SHAPE_BOX_MAP, token) && return _SVG_SHAPE_BOX_MAP[token]
    return nothing
end

function _svg_clip_shape_and_box(raw::AbstractString)
    value = strip(String(raw))
    m = match(r"(?is)^([A-Za-z-]+)\s+(.+)$", value)
    if m !== nothing
        box = _svg_parse_shape_box(m.captures[1])
        box !== nothing && return strip(m.captures[2]), box
    end
    m = match(r"(?is)^(.+)\s+([A-Za-z-]+)$", value)
    if m !== nothing
        box = _svg_parse_shape_box(m.captures[2])
        box !== nothing && return strip(m.captures[1]), box
    end
    return value, :fillBox
end

function _svg_clip_spec_from_raw(raw::AbstractString, curve_segments::Int,
                                 circle_segments::Int)
    value = strip(String(raw))
    isempty(value) && return nothing
    lowercase(value) == "none" && return nothing
    m = match(r"^url\(\s*(['\"]?)#([^'\"\)\s]+)\1\s*\)$", value)
    m !== nothing && return _svg_url_clip_spec(m.captures[2], circle_segments)
    shape_value, reference_box = _svg_clip_shape_and_box(value)
    spec = nothing
    m = match(r"(?is)^inset\((.*)\)$", shape_value)
    if m !== nothing
        inset, corners = _svg_inset_values(m.captures[1])
        spec = _svg_inset_clip_spec(inset, corners, circle_segments)
    end
    if spec === nothing
        m = match(r"(?is)^rect\((.*)\)$", shape_value)
        m !== nothing && (spec = _svg_rect_clip_spec(m.captures[1],
                                                     circle_segments))
    end
    if spec === nothing
        m = match(r"(?is)^xywh\((.*)\)$", shape_value)
        m !== nothing && (spec = _svg_xywh_clip_spec(m.captures[1],
                                                     circle_segments))
    end
    if spec === nothing
        m = match(r"(?is)^circle\((.*)\)$", shape_value)
        m !== nothing && (spec = _svg_circle_clip_spec(m.captures[1],
                                                       circle_segments))
    end
    if spec === nothing
        m = match(r"(?is)^ellipse\((.*)\)$", shape_value)
        m !== nothing && (spec = _svg_ellipse_clip_spec(m.captures[1],
                                                        circle_segments))
    end
    if spec === nothing
        m = match(r"(?is)^polygon\((.*)\)$", shape_value)
        m !== nothing && (spec = _svg_polygon_clip_spec(m.captures[1],
                                                        circle_segments))
    end
    if spec === nothing
        m = match(r"(?is)^path\((.*)\)$", shape_value)
        m !== nothing && (spec = _svg_path_clip_spec(m.captures[1],
                                                     curve_segments,
                                                     circle_segments))
    end
    spec !== nothing && return _svg_clip_spec_reference_box(spec, reference_box)
    error("unsupported SVG clip-path $value")
end

function _svg_clip_spec_from_attrs(attrs::AbstractDict,
                                   css_rules::Vector{_SVGStyleRule},
                                   tag::String,
                                   context::Union{Nothing,_SVGElementContext},
                                   curve_segments::Int,
                                   circle_segments::Int)
    local_attrs = _svg_cascaded_style_attrs(attrs, css_rules, tag, context,
                                            ("clip-path",))
    haskey(local_attrs, "clip-path") || return nothing
    return _svg_clip_spec_from_raw(local_attrs["clip-path"], curve_segments,
                                   circle_segments)
end

function _svg_url_reference_id(raw::AbstractString, context::AbstractString)
    value = strip(String(raw))
    isempty(value) && return nothing
    lowercase(value) == "none" && return nothing
    m = match(r"^url\(\s*(['\"]?)#([^'\"\)\s]+)\1\s*\)$", value)
    m !== nothing && return m.captures[2]
    error("unsupported $context $value")
end

function _svg_mask_spec_from_attrs(attrs::AbstractDict,
                                   css_rules::Vector{_SVGStyleRule},
                                   tag::String,
                                   context::Union{Nothing,_SVGElementContext},
                                   circle_segments::Int)
    local_attrs = _svg_cascaded_style_attrs(attrs, css_rules, tag, context,
                                            ("mask",))
    haskey(local_attrs, "mask") || return nothing
    id = _svg_url_reference_id(local_attrs["mask"], "SVG mask")
    id === nothing && return nothing
    return _svg_clip_spec(:url; id, segments=circle_segments)
end

function _svg_path_with_points(path::SVGPath, points::Vector{Vec2{Float64}},
                               closed::Bool)
    return SVGPath(path.tag, points, closed, path.style, path.element_id)
end

function _svg_style_with_opacity_factor(style::SVGStyle, factor::Float64)
    opacity = clamp(style.opacity * factor, 0.0, 1.0)
    return SVGStyle(style.fill, style.stroke, style.stroke_width, opacity,
                    style.fill_opacity, style.stroke_opacity,
                    copy(style.stroke_dasharray), style.stroke_dashoffset,
                    style.stroke_linecap, style.stroke_linejoin,
                    style.stroke_miterlimit, style.fill_rule)
end

function _svg_path_with_opacity_factor(path::SVGPath, factor::Float64)
    return SVGPath(path.tag, path.points, path.closed,
                   _svg_style_with_opacity_factor(path.style, factor),
                   path.element_id)
end

function _svg_is_convex_clip_loop(loop::Vector{Vec2{Float64}})
    length(loop) >= 3 || return false
    area = _font_polygon_area(loop)
    abs(area) > 1e-12 || return false
    sign = area >= 0.0 ? 1.0 : -1.0
    for i in eachindex(loop)
        a = loop[i == 1 ? end : i - 1]
        b = loop[i]
        c = loop[i == length(loop) ? 1 : i + 1]
        cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        cross * sign >= -1e-9 || return false
    end
    return true
end

function _svg_clip_loop_pieces(loop::Vector{Vec2{Float64}},
                               context::AbstractString)
    clean = _font_loop_points(loop)
    length(clean) >= 3 && abs(_font_polygon_area(clean)) > 1e-12 ||
        error("$context must define a non-empty clip loop")
    _svg_is_convex_clip_loop(clean) && return [clean]
    points, tris = try
        _font_triangulate_simple(clean)
    catch err
        err isa ErrorException || rethrow()
        error("$context must be a simple non-convex clip loop")
    end
    pieces = Vector{Vec2{Float64}}[]
    for (a, b, c) in tris
        tri = [points[a], points[b], points[c]]
        abs(_font_polygon_area(tri)) > 1e-12 && push!(pieces, tri)
    end
    isempty(pieces) && error("$context must be a simple non-convex clip loop")
    return pieces
end

function _svg_clip_area_loop_pieces(loops::Vector{Vector{Vec2{Float64}}},
                                    fill_rule::Symbol,
                                    context::AbstractString)
    pieces = Vector{Vec2{Float64}}[]
    for group in _svg_fill_loop_groups(loops, fill_rule)
        if isempty(group.holes) && _svg_is_convex_clip_loop(group.outer)
            push!(pieces, group.outer)
            continue
        end
        points, tris = try
            _font_triangulate_group(group.outer, group.holes)
        catch err
            err isa ErrorException || rethrow()
            error("$context must contain simple clip loops")
        end
        for (a, b, c) in tris
            tri = [points[a], points[b], points[c]]
            abs(_font_polygon_area(tri)) > 1e-12 && push!(pieces, tri)
        end
    end
    isempty(pieces) && return nothing
    return pieces
end

_svg_mask_fill_luminance(color::Color3) =
    0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b

_svg_mask_path_alpha(path::SVGPath) =
    clamp(path.style.opacity * path.style.fill_opacity, 0.0, 1.0)

function _svg_mask_path_opacity(path::SVGPath, mask_type::Symbol)
    fill = path.style.fill
    fill === nothing && return 0.0
    alpha = _svg_mask_path_alpha(path)
    mask_type === :alpha && return clamp(alpha, 0.0, 1.0)
    mask_type === :luminance &&
        return clamp(alpha * _svg_mask_fill_luminance(fill), 0.0, 1.0)
    error("unsupported SVG mask-type $(mask_type)")
end

function _svg_mask_definition_paths(paths::Vector{SVGPath}, mask_type::Symbol)
    mask_type === :luminance || mask_type === :alpha ||
        error("unsupported SVG mask-type $(mask_type)")
    out = SVGPath[]
    for path in paths
        path.closed && length(path.points) >= 3 || continue
        path.style.fill !== nothing || continue
        _svg_mask_path_alpha(path) > 1e-12 || continue
        push!(out, path)
    end
    return out
end

function _svg_clip_loops(definitions::Dict{String,_SVGClipDefinition},
                         clip_id::String)
    haskey(definitions, clip_id) ||
        error("SVG clip-path references unknown id $clip_id")
    definition = definitions[clip_id]
    isempty(definition.paths) && return nothing
    closed = [path for path in definition.paths
              if path.closed && length(path.points) >= 3]
    length(closed) == length(definition.paths) ||
        error("SVG clipPath #$clip_id must contain only closed clipping paths")
    pieces = Vector{Vec2{Float64}}[]
    for group in _svg_element_path_groups(closed)
        fill_rule = group[1].style.fill_rule
        loops = [_font_loop_points(path.points) for path in group]
        group_pieces = _svg_clip_area_loop_pieces(loops, fill_rule,
                                                  "SVG clipPath #$clip_id")
        group_pieces === nothing || append!(pieces, group_pieces)
    end
    return pieces
end

function _svg_paths_bbox(paths::Vector{SVGPath})
    found = false
    minx = Inf
    miny = Inf
    maxx = -Inf
    maxy = -Inf
    for path in paths, p in path.points
        found = true
        minx = min(minx, p.x)
        miny = min(miny, p.y)
        maxx = max(maxx, p.x)
        maxy = max(maxy, p.y)
    end
    found || return nothing
    return minx, miny, maxx, maxy
end

function _svg_include_xy_bbox(bbox::Union{Nothing,NTuple{4,Float64}},
                              x::Float64, y::Float64)
    bbox === nothing && return (x, y, x, y)
    minx, miny, maxx, maxy = bbox
    return min(minx, x), min(miny, y), max(maxx, x), max(maxy, y)
end

function _svg_include_geometry_bbox(bbox::Union{Nothing,NTuple{4,Float64}},
                                    geo::BufferGeometry)
    @inbounds for i in 1:3:length(geo.positions)
        bbox = _svg_include_xy_bbox(bbox, geo.positions[i], geo.positions[i + 1])
    end
    return bbox
end

function _svg_paths_stroke_bbox(paths::Vector{SVGPath})
    bbox = nothing
    for path in paths
        for p in path.points
            bbox = _svg_include_xy_bbox(bbox, p.x, p.y)
        end
        style = path.style
        style.stroke === nothing && continue
        length(path.points) >= 2 || continue
        style.stroke_width > 0.0 || continue
        style.opacity * style.stroke_opacity > 0.0 || continue
        for (subpath, subpath_closed) in
            _svg_stroke_subpaths(copy(path.points), path.closed,
                                 style.stroke_dasharray, style.stroke_dashoffset)
            geo = _svg_stroke_outline_geometry(subpath, subpath_closed,
                                               style.stroke_width,
                                               style.stroke_linecap,
                                               style.stroke_linejoin,
                                               style.stroke_miterlimit)
            bbox = _svg_include_geometry_bbox(bbox, geo)
        end
    end
    return bbox
end

function _svg_bbox_rect_path(bbox::NTuple{4,Float64})
    minx, miny, maxx, maxy = bbox
    return SVGPath(:rect, [Vec2(minx, miny), Vec2(maxx, miny),
                           Vec2(maxx, maxy), Vec2(minx, maxy)], true)
end

function _svg_reference_box_paths(application::_SVGClipApplication,
                                  paths::Vector{SVGPath})
    spec = application.spec
    (spec.reference_box === :fillBox || spec.reference_box === :cssLayoutBox) &&
        return paths
    if spec.reference_box === :strokeBox
        bbox = _svg_paths_stroke_bbox(paths)
        bbox === nothing && return SVGPath[]
        return [_svg_bbox_rect_path(bbox)]
    end
    if spec.reference_box === :viewBox
        bbox = application.reference_bbox
        bbox === nothing &&
            error("SVG view-box clip-path requires root viewBox or viewport bounds")
        return [_svg_bbox_rect_path(bbox)]
    end
    error("unsupported SVG clip-path shape box $(spec.reference_box)")
end

function _svg_object_bbox_clip_loops(loops::Vector{Vector{Vec2{Float64}}},
                                     paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    mapped_loops = Vector{Vec2{Float64}}[]
    for loop in loops
        mapped = [Vec2(minx + p.x * width, miny + p.y * height) for p in loop]
        _svg_is_convex_clip_loop(mapped) || return nothing
        push!(mapped_loops, mapped)
    end
    return mapped_loops
end

function _svg_inset_amount(value::_SVGInsetValue, extent::Float64)
    return value.percent ? extent * value.value / 100.0 : value.value
end

function _svg_inset_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    top, right, bottom, left = spec.inset
    x0 = minx + _svg_inset_amount(left, width)
    x1 = maxx - _svg_inset_amount(right, width)
    y0 = miny + _svg_inset_amount(top, height)
    y1 = maxy - _svg_inset_amount(bottom, height)
    loop = _svg_rect_loop(x0, y0, x1, y1, spec.corners, spec.segments)
    loop === nothing && return nothing
    return [loop]
end

_svg_clip_spec_uses_bbox(spec::_SVGClipSpec) =
    spec.kind === :inset || spec.kind === :rect || spec.kind === :xywh ||
    spec.kind === :circle ||
    spec.kind === :ellipse || spec.kind === :polygon || spec.kind === :path

function _svg_position_amount(value::_SVGInsetValue, origin::Float64,
                              extent::Float64)
    return origin + _svg_inset_amount(value, extent)
end

function _svg_rect_edge_amount(edge::_SVGRectEdge, fallback::Float64,
                               origin::Float64, extent::Float64)
    return edge.auto ? fallback : _svg_position_amount(edge.value, origin, extent)
end

function _svg_resolved_corner_radii(corners::NTuple{4,_SVGCornerRadii},
                                    width::Float64, height::Float64)
    radii = [(max(0.0, _svg_inset_amount(corner.x, width)),
              max(0.0, _svg_inset_amount(corner.y, height)))
             for corner in corners]
    scale = 1.0
    for (sum_r, extent) in ((radii[1][1] + radii[2][1], width),
                            (radii[4][1] + radii[3][1], width),
                            (radii[1][2] + radii[4][2], height),
                            (radii[2][2] + radii[3][2], height))
        sum_r > 0.0 && (scale = min(scale, extent / sum_r))
    end
    scale = min(scale, 1.0)
    return [(rx * scale, ry * scale) for (rx, ry) in radii]
end

function _svg_rect_loop(x0::Float64, y0::Float64, x1::Float64, y1::Float64,
                        corners::NTuple{4,_SVGCornerRadii}, segments::Int)
    (x1 > x0 && y1 > y0) || return nothing
    width = x1 - x0
    height = y1 - y0
    radii = _svg_resolved_corner_radii(corners, width, height)
    all(((rx, ry),) -> rx <= 1e-12 || ry <= 1e-12, radii) &&
        return [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]

    points = Vec2{Float64}[]
    arc_segments = max(1, segments)

    function push_corner!(rx::Float64, ry::Float64, cx::Float64, cy::Float64,
                          start_angle, stop_angle,
                          square_point::Vec2{Float64})
        if rx <= 1e-12 || ry <= 1e-12
            _svg_push_unique_point!(points, square_point)
        else
            for step in 1:arc_segments
                t = step / Float64(arc_segments)
                θ = start_angle + (stop_angle - start_angle) * t
                _svg_push_unique_point!(points,
                                        Vec2(cx + rx * cos(θ),
                                             cy + ry * sin(θ)))
            end
        end
        return nothing
    end

    tl, tr, br, bl = radii
    tl_rx, tl_ry = tl
    tr_rx, tr_ry = tr
    br_rx, br_ry = br
    bl_rx, bl_ry = bl

    _svg_push_unique_point!(points, Vec2(x0 + tl_rx, y0))
    _svg_push_unique_point!(points, Vec2(x1 - tr_rx, y0))
    push_corner!(tr_rx, tr_ry, x1 - tr_rx, y0 + tr_ry,
                 -π / 2.0, 0.0, Vec2(x1, y0))
    _svg_push_unique_point!(points, Vec2(x1, y1 - br_ry))
    push_corner!(br_rx, br_ry, x1 - br_rx, y1 - br_ry,
                 0.0, π / 2.0, Vec2(x1, y1))
    _svg_push_unique_point!(points, Vec2(x0 + bl_rx, y1))
    push_corner!(bl_rx, bl_ry, x0 + bl_rx, y1 - bl_ry,
                 π / 2.0, π, Vec2(x0, y1))
    _svg_push_unique_point!(points, Vec2(x0, y0 + tl_ry))
    push_corner!(tl_rx, tl_ry, x0 + tl_rx, y0 + tl_ry,
                 π, 3π / 2.0, Vec2(x0, y0))

    if length(points) > 1 && _font_same_point(points[end], points[1])
        pop!(points)
    end
    length(points) >= 3 || return nothing
    return points
end

function _svg_rect_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    top, right, bottom, left = spec.rect
    y0 = _svg_rect_edge_amount(top, miny, miny, height)
    x1 = _svg_rect_edge_amount(right, maxx, minx, width)
    y1 = _svg_rect_edge_amount(bottom, maxy, miny, height)
    x0 = _svg_rect_edge_amount(left, minx, minx, width)
    loop = _svg_rect_loop(x0, y0, x1, y1, spec.corners, spec.segments)
    loop === nothing && return nothing
    return [loop]
end

function _svg_xywh_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    x, y, w, h = spec.xywh
    x0 = _svg_position_amount(x, minx, width)
    y0 = _svg_position_amount(y, miny, height)
    x1 = x0 + _svg_inset_amount(w, width)
    y1 = y0 + _svg_inset_amount(h, height)
    loop = _svg_rect_loop(x0, y0, x1, y1, spec.corners, spec.segments)
    loop === nothing && return nothing
    return [loop]
end

function _svg_resolve_shape_radius(radius::_SVGShapeRadius, axis::Symbol,
                                   minx::Float64, miny::Float64,
                                   maxx::Float64, maxy::Float64,
                                   cx::Float64, cy::Float64)
    width = maxx - minx
    height = maxy - miny
    if radius.kind === :length
        extent = axis === :circle ? hypot(width, height) / sqrt(2.0) :
                 (axis === :x ? width : height)
        return _svg_inset_amount(radius.value, extent)
    elseif radius.kind === :closest_side
        if axis === :circle
            return min(abs(cx - minx), abs(maxx - cx),
                       abs(cy - miny), abs(maxy - cy))
        elseif axis === :x
            return min(abs(cx - minx), abs(maxx - cx))
        elseif axis === :y
            return min(abs(cy - miny), abs(maxy - cy))
        end
    elseif radius.kind === :farthest_side
        if axis === :circle
            return max(abs(cx - minx), abs(maxx - cx),
                       abs(cy - miny), abs(maxy - cy))
        elseif axis === :x
            return max(abs(cx - minx), abs(maxx - cx))
        elseif axis === :y
            return max(abs(cy - miny), abs(maxy - cy))
        end
    end
    error("unsupported SVG clip-path radius kind $(radius.kind)")
end

function _svg_bbox_shape_center(spec::_SVGClipSpec,
                                bbox::NTuple{4,Float64})
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    x = _svg_position_amount(spec.position[1], minx, width)
    y = _svg_position_amount(spec.position[2], miny, height)
    return x, y
end

function _svg_circle_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    cx, cy = _svg_bbox_shape_center(spec, bbox)
    r = _svg_resolve_shape_radius(spec.radius, :circle,
                                  minx, miny, maxx, maxy, cx, cy)
    r > 0.0 || return nothing
    points = _svg_ellipse_points(cx, cy, r, r, spec.segments)
    isempty(points) && return nothing
    return [points]
end

function _svg_ellipse_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    cx, cy = _svg_bbox_shape_center(spec, bbox)
    rx = _svg_resolve_shape_radius(spec.radii[1], :x,
                                   minx, miny, maxx, maxy, cx, cy)
    ry = _svg_resolve_shape_radius(spec.radii[2], :y,
                                   minx, miny, maxx, maxy, cx, cy)
    (rx > 0.0 && ry > 0.0) || return nothing
    points = _svg_ellipse_points(cx, cy, rx, ry, spec.segments)
    isempty(points) && return nothing
    return [points]
end

function _svg_shortest_angle_delta(from::Float64, to::Float64)
    delta = mod(to - from + π, 2π) - π
    delta <= -π && (delta += 2π)
    return delta
end

function _svg_rounded_polygon_loop(loop::Vector{Vec2{Float64}},
                                   radius::Float64, segments::Int)
    radius > 0.0 || return loop
    rounded = Vec2{Float64}[]
    arc_segments = max(1, segments)
    n = length(loop)
    for i in eachindex(loop)
        prev = loop[i == 1 ? n : i - 1]
        vertex = loop[i]
        next = loop[i == n ? 1 : i + 1]
        to_prev = prev - vertex
        to_next = next - vertex
        len_prev = hypot(to_prev.x, to_prev.y)
        len_next = hypot(to_next.x, to_next.y)
        if len_prev <= 1e-12 || len_next <= 1e-12
            _svg_push_unique_point!(rounded, vertex)
            continue
        end
        v_prev = Vec2(to_prev.x / len_prev, to_prev.y / len_prev)
        v_next = Vec2(to_next.x / len_next, to_next.y / len_next)
        dotv = clamp(v_prev.x * v_next.x + v_prev.y * v_next.y, -1.0, 1.0)
        angle = acos(dotv)
        if angle <= 1e-12 || abs(π - angle) <= 1e-12
            _svg_push_unique_point!(rounded, vertex)
            continue
        end
        tan_half = tan(angle / 2.0)
        max_radius = tan_half * min(len_prev, len_next) / 2.0
        local_radius = min(radius, max_radius)
        if local_radius <= 1e-12
            _svg_push_unique_point!(rounded, vertex)
            continue
        end
        distance = local_radius / tan_half
        start_point = vertex + v_prev * distance
        stop_point = vertex + v_next * distance
        bisector = v_prev + v_next
        bisector_len = hypot(bisector.x, bisector.y)
        if bisector_len <= 1e-12
            _svg_push_unique_point!(rounded, vertex)
            continue
        end
        center_distance = local_radius / sin(angle / 2.0)
        center = vertex + Vec2(bisector.x / bisector_len,
                               bisector.y / bisector_len) * center_distance
        start_angle = atan(start_point.y - center.y, start_point.x - center.x)
        stop_angle = atan(stop_point.y - center.y, stop_point.x - center.x)
        delta = _svg_shortest_angle_delta(start_angle, stop_angle)

        _svg_push_unique_point!(rounded, start_point)
        for step in 1:arc_segments
            t = step / Float64(arc_segments)
            θ = start_angle + delta * t
            _svg_push_unique_point!(rounded,
                                    Vec2(center.x + local_radius * cos(θ),
                                         center.y + local_radius * sin(θ)))
        end
    end
    if length(rounded) > 1 && _font_same_point(rounded[end], rounded[1])
        pop!(rounded)
    end
    length(rounded) >= 3 || return loop
    return rounded
end

function _svg_polygon_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    loop = [Vec2(_svg_position_amount(p[1], minx, width),
                 _svg_position_amount(p[2], miny, height))
            for p in spec.points]
    loop = _font_loop_points(loop)
    length(loop) >= 3 && abs(_font_polygon_area(loop)) > 1e-12 || return nothing
    if spec.polygon_round > 0.0
        _svg_is_convex_clip_loop(loop) ||
            error("SVG clip-path rounded polygon must be convex")
        loop = _svg_rounded_polygon_loop(loop, spec.polygon_round, spec.segments)
        _svg_is_convex_clip_loop(loop) ||
            error("SVG clip-path rounded polygon must be convex")
        return [loop]
    end
    return _svg_clip_loop_pieces(loop, "SVG clip-path polygon")
end

function _svg_path_clip_loops(spec::_SVGClipSpec, paths::Vector{SVGPath})
    bbox = _svg_paths_bbox(paths)
    bbox === nothing && return nothing
    minx, miny, maxx, maxy = bbox
    width = maxx - minx
    height = maxy - miny
    (width > 0.0 && height > 0.0) || return nothing
    loops = [[Vec2(minx + p.x, miny + p.y) for p in loop]
             for loop in spec.path_loops]
    return _svg_clip_area_loop_pieces(loops, spec.path_fill_rule,
                                      "SVG clip-path path")
end

function _svg_resolved_clip_loops(definitions::Dict{String,_SVGClipDefinition},
                                  application::_SVGClipApplication,
                                  paths::Vector{SVGPath})
    spec = application.spec
    reference_paths =
        spec.kind === :url ? paths : _svg_reference_box_paths(application, paths)
    if spec.kind === :inset
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG inset clip-path requires local or deferred container bounds")
        return _svg_inset_clip_loops(spec, reference_paths)
    elseif spec.kind === :rect
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG rect clip-path requires local or deferred container bounds")
        return _svg_rect_clip_loops(spec, reference_paths)
    elseif spec.kind === :xywh
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG xywh clip-path requires local or deferred container bounds")
        return _svg_xywh_clip_loops(spec, reference_paths)
    elseif spec.kind === :circle
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG circle clip-path requires local or deferred container bounds")
        return _svg_circle_clip_loops(spec, reference_paths)
    elseif spec.kind === :ellipse
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG ellipse clip-path requires local or deferred container bounds")
        return _svg_ellipse_clip_loops(spec, reference_paths)
    elseif spec.kind === :polygon
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG polygon clip-path requires local or deferred container bounds")
        return _svg_polygon_clip_loops(spec, reference_paths)
    elseif spec.kind === :path
        (application.scope === :local || application.scope === :container_bbox) ||
            error("SVG path clip-path requires local or deferred container bounds")
        return _svg_path_clip_loops(spec, reference_paths)
    elseif spec.kind === :url
        clip_id = spec.id::String
        haskey(definitions, clip_id) ||
            error("SVG clip-path references unknown id $clip_id")
        definition = definitions[clip_id]
        loops = _svg_clip_loops(definitions, clip_id)
        loops === nothing && return nothing
        if definition.units === :userSpaceOnUse
            return loops
        elseif definition.units === :objectBoundingBox
            (application.scope === :local || application.scope === :container_bbox) ||
                error("SVG objectBoundingBox clipPath requires local or deferred container bounds")
            return _svg_object_bbox_clip_loops(loops, paths)
        else
            error("unsupported SVG clipPathUnits $(definition.units)")
        end
    else
        error("unsupported SVG clip-path kind $(spec.kind)")
    end
end

function _svg_resolved_mask_entries(definitions::Dict{String,_SVGClipDefinition},
                                    application::_SVGClipApplication,
                                    paths::Vector{SVGPath})
    spec = application.spec
    spec.kind === :url || error("unsupported SVG mask kind $(spec.kind)")
    mask_id = spec.id::String
    haskey(definitions, mask_id) ||
        error("SVG mask references unknown id $mask_id")
    definition = definitions[mask_id]
    isempty(definition.paths) && return nothing
    entries = _SVGMaskEntry[]
    for group in _svg_element_path_groups(definition.paths)
        alpha = _svg_mask_path_alpha(group[1])
        alpha > 1e-12 || continue
        intensity = _svg_mask_path_opacity(group[1], definition.mask_type)
        loops = [_font_loop_points(path.points) for path in group]
        pieces = _svg_clip_area_loop_pieces(loops, group[1].style.fill_rule,
                                            "SVG mask #$mask_id")
        pieces === nothing && continue
        if definition.units === :objectBoundingBox
            (application.scope === :local || application.scope === :container_bbox) ||
                error("SVG objectBoundingBox mask requires local or deferred container bounds")
            mapped = _svg_object_bbox_clip_loops(pieces, paths)
            mapped === nothing && continue
            pieces = mapped
        elseif definition.units !== :userSpaceOnUse
            error("unsupported SVG maskContentUnits $(definition.units)")
        end
        push!(entries, _SVGMaskEntry(pieces, alpha, intensity))
    end
    isempty(entries) && return nothing
    return entries
end

function _svg_clip_signed_distance(p::Vec2{Float64}, a::Vec2{Float64},
                                   b::Vec2{Float64}, ccw::Bool)
    cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    return ccw ? cross : -cross
end

function _svg_clip_edge_intersection(s::Vec2{Float64}, e::Vec2{Float64},
                                     ds::Float64, de::Float64)
    denom = ds - de
    abs(denom) > 1e-15 || return e
    t = ds / denom
    return Vec2(s.x + (e.x - s.x) * t, s.y + (e.y - s.y) * t)
end

function _svg_clip_polygon_to_loop(subject::Vector{Vec2{Float64}},
                                   clip_loop::Vector{Vec2{Float64}})
    out = _font_loop_points(subject)
    length(out) >= 3 || return Vec2{Float64}[]
    ccw = _font_polygon_area(clip_loop) >= 0.0
    for i in eachindex(clip_loop)
        a = clip_loop[i]
        b = clip_loop[i == length(clip_loop) ? 1 : i + 1]
        input = out
        out = Vec2{Float64}[]
        isempty(input) && break
        s = input[end]
        ds = _svg_clip_signed_distance(s, a, b, ccw)
        s_inside = ds >= -1e-9
        for e in input
            de = _svg_clip_signed_distance(e, a, b, ccw)
            e_inside = de >= -1e-9
            if e_inside
                !s_inside &&
                    _svg_push_unique_point!(out,
                                            _svg_clip_edge_intersection(s, e,
                                                                        ds, de))
                _svg_push_unique_point!(out, e)
            elseif s_inside
                _svg_push_unique_point!(out,
                                        _svg_clip_edge_intersection(s, e,
                                                                    ds, de))
            end
            s = e
            ds = de
            s_inside = e_inside
        end
        out = _font_loop_points(out)
    end
    length(out) >= 3 && abs(_font_polygon_area(out)) > 1e-12 || return Vec2{Float64}[]
    return out
end

function _svg_clip_segment_to_loop(a::Vec2{Float64}, b::Vec2{Float64},
                                   clip_loop::Vector{Vec2{Float64}})
    p0 = a
    p1 = b
    ccw = _font_polygon_area(clip_loop) >= 0.0
    for i in eachindex(clip_loop)
        c = clip_loop[i]
        d = clip_loop[i == length(clip_loop) ? 1 : i + 1]
        d0 = _svg_clip_signed_distance(p0, c, d, ccw)
        d1 = _svg_clip_signed_distance(p1, c, d, ccw)
        in0 = d0 >= -1e-9
        in1 = d1 >= -1e-9
        in0 && in1 && continue
        (!in0 && !in1) && return nothing
        hit = _svg_clip_edge_intersection(p0, p1, d0, d1)
        if in0
            p1 = hit
        else
            p0 = hit
        end
    end
    _font_same_point(p0, p1) && return nothing
    return p0, p1
end

function _svg_clip_open_path_to_loop(path::SVGPath,
                                     clip_loop::Vector{Vec2{Float64}})
    fragments = SVGPath[]
    current = Vec2{Float64}[]
    function flush_current!()
        if length(current) >= 2
            push!(fragments, _svg_path_with_points(path, copy(current), false))
        end
        empty!(current)
        return nothing
    end

    for i in 1:(length(path.points) - 1)
        clipped = _svg_clip_segment_to_loop(path.points[i], path.points[i + 1],
                                            clip_loop)
        if clipped === nothing
            flush_current!()
            continue
        end
        a, b = clipped
        if isempty(current)
            push!(current, a)
            push!(current, b)
        elseif _font_same_point(current[end], a)
            _svg_push_unique_point!(current, b)
        else
            flush_current!()
            push!(current, a)
            push!(current, b)
        end
    end
    flush_current!()
    return fragments
end

function _svg_lerp_point(a::Vec2{Float64}, b::Vec2{Float64}, t::Float64)
    return Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
end

function _svg_clip_segment_interval_to_loop(a::Vec2{Float64}, b::Vec2{Float64},
                                            clip_loop::Vector{Vec2{Float64}})
    t0 = 0.0
    t1 = 1.0
    ccw = _font_polygon_area(clip_loop) >= 0.0
    for i in eachindex(clip_loop)
        c = clip_loop[i]
        d = clip_loop[i == length(clip_loop) ? 1 : i + 1]
        da = _svg_clip_signed_distance(a, c, d, ccw)
        db = _svg_clip_signed_distance(b, c, d, ccw)
        ina = da >= -1e-9
        inb = db >= -1e-9
        ina && inb && continue
        (!ina && !inb) && return nothing
        denom = da - db
        abs(denom) > 1e-15 || return nothing
        t = clamp(da / denom, 0.0, 1.0)
        if ina
            t1 = min(t1, t)
        else
            t0 = max(t0, t)
        end
        t1 - t0 > 1e-12 || return nothing
    end
    return t0, t1
end

function _svg_merge_intervals(intervals::Vector{NTuple{2,Float64}})
    isempty(intervals) && return intervals
    sort!(intervals, by=first)
    merged = NTuple{2,Float64}[]
    lo, hi = intervals[1]
    for i in 2:length(intervals)
        next_lo, next_hi = intervals[i]
        if next_lo <= hi + 1e-9
            hi = max(hi, next_hi)
        else
            hi - lo > 1e-12 && push!(merged, (lo, hi))
            lo, hi = next_lo, next_hi
        end
    end
    hi - lo > 1e-12 && push!(merged, (lo, hi))
    return merged
end

function _svg_clip_open_path_to_union(path::SVGPath,
                                      clip_loops::Vector{Vector{Vec2{Float64}}})
    fragments = SVGPath[]
    current = Vec2{Float64}[]
    function flush_current!()
        if length(current) >= 2
            push!(fragments, _svg_path_with_points(path, copy(current), false))
        end
        empty!(current)
        return nothing
    end

    for i in 1:(length(path.points) - 1)
        a = path.points[i]
        b = path.points[i + 1]
        _font_same_point(a, b) && continue
        intervals = NTuple{2,Float64}[]
        for clip_loop in clip_loops
            interval = _svg_clip_segment_interval_to_loop(a, b, clip_loop)
            interval === nothing || push!(intervals, interval)
        end
        for (lo, hi) in _svg_merge_intervals(intervals)
            p0 = _svg_lerp_point(a, b, lo)
            p1 = _svg_lerp_point(a, b, hi)
            if isempty(current)
                push!(current, p0)
                push!(current, p1)
            elseif _font_same_point(current[end], p0)
                _svg_push_unique_point!(current, p1)
            else
                flush_current!()
                push!(current, p0)
                push!(current, p1)
            end
        end
        isempty(intervals) && flush_current!()
    end
    flush_current!()
    return fragments
end

function _svg_segment_intersection_point(a::Vec2{Float64}, b::Vec2{Float64},
                                         c::Vec2{Float64}, d::Vec2{Float64})
    rx = b.x - a.x
    ry = b.y - a.y
    sx = d.x - c.x
    sy = d.y - c.y
    denom = rx * sy - ry * sx
    abs(denom) > 1e-12 || return nothing
    qx = c.x - a.x
    qy = c.y - a.y
    t = (qx * sy - qy * sx) / denom
    u = (qx * ry - qy * rx) / denom
    -1e-9 <= t <= 1.0 + 1e-9 || return nothing
    -1e-9 <= u <= 1.0 + 1e-9 || return nothing
    t = clamp(t, 0.0, 1.0)
    return Vec2(a.x + rx * t, a.y + ry * t)
end

function _svg_loop_edges(loops::Vector{Vector{Vec2{Float64}}})
    edges = NTuple{2,Vec2{Float64}}[]
    for loop in loops
        for i in eachindex(loop)
            push!(edges, (loop[i], loop[i == length(loop) ? 1 : i + 1]))
        end
    end
    return edges
end

function _svg_unique_sorted_values(values::Vector{Float64})
    sort!(filter!(isfinite, values))
    out = Float64[]
    for value in values
        if isempty(out) || abs(value - out[end]) > 1e-9
            push!(out, value)
        end
    end
    return out
end

function _svg_boolean_x_breaks(loops::Vector{Vector{Vec2{Float64}}})
    xs = Float64[]
    for loop in loops, p in loop
        push!(xs, p.x)
    end
    edges = _svg_loop_edges(loops)
    for i in 1:length(edges)
        a, b = edges[i]
        for j in (i + 1):length(edges)
            c, d = edges[j]
            hit = _svg_segment_intersection_point(a, b, c, d)
            hit === nothing || push!(xs, hit.x)
        end
    end
    return _svg_unique_sorted_values(xs)
end

function _svg_edge_y_at_x(a::Vec2{Float64}, b::Vec2{Float64},
                          x::Float64; strict::Bool)
    dx = b.x - a.x
    abs(dx) > 1e-12 || return nothing
    xmin = min(a.x, b.x)
    xmax = max(a.x, b.x)
    if strict
        xmin + 1e-10 < x < xmax - 1e-10 || return nothing
    else
        xmin - 1e-9 <= x <= xmax + 1e-9 || return nothing
    end
    t = clamp((x - a.x) / dx, 0.0, 1.0)
    return a.y + (b.y - a.y) * t
end

function _svg_slab_crossings(loops::Vector{Vector{Vec2{Float64}}},
                             x0::Float64, x1::Float64)
    xm = (x0 + x1) / 2.0
    crossings = NamedTuple{(:y0, :y1, :ym),Tuple{Float64,Float64,Float64}}[]
    for (a, b) in _svg_loop_edges(loops)
        ym = _svg_edge_y_at_x(a, b, xm; strict=true)
        ym === nothing && continue
        y0 = _svg_edge_y_at_x(a, b, x0; strict=false)
        y1 = _svg_edge_y_at_x(a, b, x1; strict=false)
        (y0 === nothing || y1 === nothing) && continue
        push!(crossings, (y0=y0, y1=y1, ym=ym))
    end
    sort!(crossings, by=c -> c.ym)
    return crossings
end

function _svg_loops_overlap_positive(a::Vector{Vec2{Float64}},
                                     b::Vector{Vec2{Float64}})
    loops = [_font_loop_points(a), _font_loop_points(b)]
    any(length(loop) < 3 || abs(_font_polygon_area(loop)) <= 1e-12 for loop in loops) &&
        return false
    xs = _svg_boolean_x_breaks(loops)
    length(xs) >= 2 || return false
    for i in 1:(length(xs) - 1)
        x0 = xs[i]
        x1 = xs[i + 1]
        x1 - x0 > 1e-9 || continue
        xm = (x0 + x1) / 2.0
        crossings = _svg_slab_crossings(loops, x0, x1)
        for j in 1:(length(crossings) - 1)
            lower = crossings[j]
            upper = crossings[j + 1]
            upper.ym - lower.ym > 1e-9 || continue
            p = Vec2(xm, (lower.ym + upper.ym) / 2.0)
            if _font_point_in_loop(p, loops[1]) && _font_point_in_loop(p, loops[2])
                return true
            end
        end
    end
    return false
end

function _svg_fragments_overlap_positive(fragments::Vector{SVGPath})
    for i in 1:length(fragments)
        for j in (i + 1):length(fragments)
            _svg_loops_overlap_positive(fragments[i].points,
                                        fragments[j].points) && return true
        end
    end
    return false
end

function _svg_clip_closed_path_to_union(path::SVGPath,
                                        clip_loops::Vector{Vector{Vec2{Float64}}})
    subject = _font_loop_points(path.points)
    length(subject) >= 3 && abs(_font_polygon_area(subject)) > 1e-12 ||
        return SVGPath[]
    clean_clips = Vector{Vec2{Float64}}[]
    for clip_loop in clip_loops
        loop = _font_loop_points(clip_loop)
        length(loop) >= 3 && abs(_font_polygon_area(loop)) > 1e-12 &&
            push!(clean_clips, loop)
    end
    isempty(clean_clips) && return SVGPath[]
    loops = Vector{Vec2{Float64}}[subject]
    append!(loops, clean_clips)
    xs = _svg_boolean_x_breaks(loops)
    fragments = SVGPath[]
    length(xs) >= 2 || return fragments
    for i in 1:(length(xs) - 1)
        x0 = xs[i]
        x1 = xs[i + 1]
        x1 - x0 > 1e-9 || continue
        xm = (x0 + x1) / 2.0
        crossings = _svg_slab_crossings(loops, x0, x1)
        for j in 1:(length(crossings) - 1)
            lower = crossings[j]
            upper = crossings[j + 1]
            upper.ym - lower.ym > 1e-9 || continue
            sample = Vec2(xm, (lower.ym + upper.ym) / 2.0)
            _font_point_in_loop(sample, subject) || continue
            any(loop -> _font_point_in_loop(sample, loop), clean_clips) || continue
            points = _font_loop_points([Vec2(x0, lower.y0),
                                        Vec2(x1, lower.y1),
                                        Vec2(x1, upper.y1),
                                        Vec2(x0, upper.y0)])
            length(points) >= 3 && abs(_font_polygon_area(points)) > 1e-12 ||
                continue
            push!(fragments,
                  _svg_path_with_points(path, _font_orient_loop(points, true),
                                        true))
        end
    end
    return fragments
end

function _svg_clip_path_to_loops(path::SVGPath,
                                 clip_loops::Vector{Vector{Vec2{Float64}}})
    fragments = SVGPath[]
    if path.closed
        for clip_loop in clip_loops
            points = _svg_clip_polygon_to_loop(path.points, clip_loop)
            isempty(points) ||
                push!(fragments, _svg_path_with_points(path, points, true))
        end
        length(fragments) > 1 && _svg_fragments_overlap_positive(fragments) &&
            return _svg_clip_closed_path_to_union(path, clip_loops)
    else
        return _svg_clip_open_path_to_union(path, clip_loops)
    end
    return fragments
end

function _svg_mask_entry_covers(entry::_SVGMaskEntry, p::Vec2{Float64})
    return any(loop -> _font_point_in_loop(p, loop), entry.loops)
end

function _svg_mask_source_over_intensity(entries::Vector{_SVGMaskEntry},
                                         p::Vec2{Float64})
    intensity = 0.0
    for entry in entries
        _svg_mask_entry_covers(entry, p) || continue
        intensity = entry.intensity + intensity * (1.0 - entry.alpha)
    end
    return clamp(intensity, 0.0, 1.0)
end

function _svg_mask_closed_path_to_entries(path::SVGPath,
                                          entries::Vector{_SVGMaskEntry})
    subject = _font_loop_points(path.points)
    length(subject) >= 3 && abs(_font_polygon_area(subject)) > 1e-12 ||
        return SVGPath[]
    loops = Vector{Vec2{Float64}}[subject]
    for entry in entries
        append!(loops, entry.loops)
    end
    xs = _svg_boolean_x_breaks(loops)
    fragments = SVGPath[]
    length(xs) >= 2 || return fragments
    for i in 1:(length(xs) - 1)
        x0 = xs[i]
        x1 = xs[i + 1]
        x1 - x0 > 1e-9 || continue
        xm = (x0 + x1) / 2.0
        crossings = _svg_slab_crossings(loops, x0, x1)
        for j in 1:(length(crossings) - 1)
            lower = crossings[j]
            upper = crossings[j + 1]
            upper.ym - lower.ym > 1e-9 || continue
            sample = Vec2(xm, (lower.ym + upper.ym) / 2.0)
            _font_point_in_loop(sample, subject) || continue
            intensity = _svg_mask_source_over_intensity(entries, sample)
            intensity > 1e-12 || continue
            points = _font_loop_points([Vec2(x0, lower.y0),
                                        Vec2(x1, lower.y1),
                                        Vec2(x1, upper.y1),
                                        Vec2(x0, upper.y0)])
            length(points) >= 3 && abs(_font_polygon_area(points)) > 1e-12 ||
                continue
            push!(fragments,
                  _svg_path_with_opacity_factor(
                      _svg_path_with_points(path, _font_orient_loop(points, true),
                                            true),
                      intensity))
        end
    end
    return fragments
end

function _svg_push_segment_mask_breaks!(breaks::Vector{Float64},
                                        a::Vec2{Float64}, b::Vec2{Float64},
                                        loop::Vector{Vec2{Float64}})
    rx = b.x - a.x
    ry = b.y - a.y
    len2 = rx * rx + ry * ry
    len2 > 1e-24 || return breaks
    for (c, d) in _svg_loop_edges(Vector{Vec2{Float64}}[loop])
        sx = d.x - c.x
        sy = d.y - c.y
        qx = c.x - a.x
        qy = c.y - a.y
        denom = rx * sy - ry * sx
        if abs(denom) <= 1e-12
            abs(qx * ry - qy * rx) <= 1e-12 || continue
            t0 = ((c.x - a.x) * rx + (c.y - a.y) * ry) / len2
            t1 = ((d.x - a.x) * rx + (d.y - a.y) * ry) / len2
            lo = max(0.0, min(t0, t1))
            hi = min(1.0, max(t0, t1))
            hi >= lo - 1e-12 || continue
            push!(breaks, clamp(lo, 0.0, 1.0), clamp(hi, 0.0, 1.0))
            continue
        end
        t = (qx * sy - qy * sx) / denom
        u = (qx * ry - qy * rx) / denom
        if -1e-9 <= t <= 1.0 + 1e-9 && -1e-9 <= u <= 1.0 + 1e-9
            push!(breaks, clamp(t, 0.0, 1.0))
        end
    end
    return breaks
end

function _svg_segment_mask_breaks(a::Vec2{Float64}, b::Vec2{Float64},
                                  entries::Vector{_SVGMaskEntry})
    breaks = [0.0, 1.0]
    for entry in entries, loop in entry.loops
        _svg_push_segment_mask_breaks!(breaks, a, b, loop)
    end
    return _svg_unique_sorted_values(breaks)
end

function _svg_mask_open_path_to_entries(path::SVGPath,
                                        entries::Vector{_SVGMaskEntry})
    fragments = SVGPath[]
    current = Vec2{Float64}[]
    current_intensity = 0.0

    function flush_current!()
        if length(current) >= 2
            fragment = _svg_path_with_points(path, copy(current), false)
            push!(fragments, _svg_path_with_opacity_factor(fragment,
                                                           current_intensity))
        end
        empty!(current)
        current_intensity = 0.0
        return nothing
    end

    for i in 1:(length(path.points) - 1)
        a = path.points[i]
        b = path.points[i + 1]
        _font_same_point(a, b) && continue
        breaks = _svg_segment_mask_breaks(a, b, entries)
        for j in 1:(length(breaks) - 1)
            t0 = breaks[j]
            t1 = breaks[j + 1]
            t1 - t0 > 1e-12 || continue
            mid = _svg_lerp_point(a, b, (t0 + t1) / 2.0)
            intensity = _svg_mask_source_over_intensity(entries, mid)
            if intensity <= 1e-12
                flush_current!()
                continue
            end
            p0 = _svg_lerp_point(a, b, t0)
            p1 = _svg_lerp_point(a, b, t1)
            if isempty(current) ||
               abs(current_intensity - intensity) > 1e-9 ||
               !_font_same_point(current[end], p0)
                flush_current!()
                push!(current, p0, p1)
                current_intensity = intensity
            else
                _svg_push_unique_point!(current, p1)
            end
        end
    end
    flush_current!()
    return fragments
end

function _svg_mask_path_to_entries(path::SVGPath,
                                   entries::Vector{_SVGMaskEntry})
    if path.closed
        return _svg_mask_closed_path_to_entries(path, entries)
    end
    return _svg_mask_open_path_to_entries(path, entries)
end

function _svg_apply_clip_paths(paths::Vector{SVGPath},
                               clip_applications::Vector{_SVGClipApplication},
                               definitions::Dict{String,_SVGClipDefinition})
    out = paths
    for application in clip_applications
        loops = _svg_resolved_clip_loops(definitions, application, out)
        loops === nothing && return SVGPath[]
        clipped = SVGPath[]
        for path in out
            append!(clipped, _svg_clip_path_to_loops(path, loops))
        end
        out = clipped
        isempty(out) && break
    end
    return out
end

function _svg_apply_mask_paths(paths::Vector{SVGPath},
                               mask_applications::Vector{_SVGClipApplication},
                               definitions::Dict{String,_SVGClipDefinition})
    out = paths
    for application in mask_applications
        entries = _svg_resolved_mask_entries(definitions, application, out)
        entries === nothing && return SVGPath[]
        masked = SVGPath[]
        if all(entry -> entry.intensity >= 1.0 - 1e-12 &&
                        entry.alpha >= 1.0 - 1e-12, entries)
            loops = Vector{Vec2{Float64}}[]
            for entry in entries
                append!(loops, entry.loops)
            end
            for path in out
                append!(masked, _svg_clip_path_to_loops(path, loops))
            end
        else
            for path in out
                append!(masked, _svg_mask_path_to_entries(path, entries))
            end
        end
        out = masked
        isempty(out) && break
    end
    return out
end

function _svg_transform_numbers(raw::AbstractString)
    values = _svg_numbers(raw)
    isempty(values) && error("SVG transform is missing numeric arguments")
    return values
end

function _svg_transform_from_attrs(attrs::AbstractDict)
    raw = get(attrs, "transform", nothing)
    raw === nothing && return _svg_identity_transform()
    s = String(raw)
    transform = _svg_identity_transform()
    pos = firstindex(s)
    for m in eachmatch(r"([A-Za-z]+)\s*\(([^)]*)\)", s)
        if pos < m.offset
            gap = SubString(s, pos, prevind(s, m.offset))
            occursin(r"[^\s,]", gap) &&
                error("SVG transform list contains unsupported syntax near $(repr(String(gap)))")
        end
        name = lowercase(m.captures[1])
        args = _svg_transform_numbers(m.captures[2])
        local t
        if name == "matrix"
            length(args) == 6 || error("SVG matrix transform needs 6 arguments")
            t = (args[1], args[2], args[3], args[4], args[5], args[6])
        elseif name == "translate"
            (length(args) == 1 || length(args) == 2) ||
                error("SVG translate transform needs 1 or 2 arguments")
            t = (1.0, 0.0, 0.0, 1.0, args[1], length(args) == 2 ? args[2] : 0.0)
        elseif name == "scale"
            (length(args) == 1 || length(args) == 2) ||
                error("SVG scale transform needs 1 or 2 arguments")
            sy = length(args) == 2 ? args[2] : args[1]
            t = (args[1], 0.0, 0.0, sy, 0.0, 0.0)
        elseif name == "rotate"
            (length(args) == 1 || length(args) == 3) ||
                error("SVG rotate transform needs 1 or 3 arguments")
            θ = args[1] * π / 180.0
            c = cos(θ)
            sn = sin(θ)
            r = (c, sn, -sn, c, 0.0, 0.0)
            if length(args) == 3
                cx, cy = args[2], args[3]
                t = _svg_compose_transform(
                    _svg_compose_transform((1.0, 0.0, 0.0, 1.0, cx, cy), r),
                    (1.0, 0.0, 0.0, 1.0, -cx, -cy))
            else
                t = r
            end
        elseif name == "skewx"
            length(args) == 1 || error("SVG skewX transform needs 1 argument")
            t = (1.0, 0.0, tan(args[1] * π / 180.0), 1.0, 0.0, 0.0)
        elseif name == "skewy"
            length(args) == 1 || error("SVG skewY transform needs 1 argument")
            t = (1.0, tan(args[1] * π / 180.0), 0.0, 1.0, 0.0, 0.0)
        else
            error("unsupported SVG transform $name")
        end
        transform = _svg_compose_transform(transform, t)
        pos = nextind(s, m.offset, length(m.match))
    end
    if pos <= lastindex(s)
        gap = SubString(s, pos, lastindex(s))
        occursin(r"[^\s,]", gap) &&
            error("SVG transform list contains unsupported syntax near $(repr(String(gap)))")
    end
    return transform
end

function _svg_arc_flag(value::Float64, name)
    value == 0.0 && return false
    value == 1.0 && return true
    error("SVG arc $name flag must be 0 or 1")
end

function _svg_arc_points(start::Vec2{Float64}, rx::Float64, ry::Float64,
                         rotation_deg::Float64, large_arc::Bool, sweep::Bool,
                         stop::Vec2{Float64}, segments::Int)
    rx < 0.0 && error("SVG arc radius must be non-negative")
    ry < 0.0 && error("SVG arc radius must be non-negative")
    (start == stop) && return Vec2{Float64}[]
    (rx == 0.0 || ry == 0.0) && return [stop]

    φ = rotation_deg * π / 180.0
    cosφ = cos(φ)
    sinφ = sin(φ)
    dx = (start.x - stop.x) / 2.0
    dy = (start.y - stop.y) / 2.0
    x1p = cosφ * dx + sinφ * dy
    y1p = -sinφ * dx + cosφ * dy
    rx = abs(rx)
    ry = abs(ry)

    λ = x1p^2 / rx^2 + y1p^2 / ry^2
    if λ > 1.0
        scale = sqrt(λ)
        rx *= scale
        ry *= scale
    end

    rx2 = rx^2
    ry2 = ry^2
    x1p2 = x1p^2
    y1p2 = y1p^2
    denom = rx2 * y1p2 + ry2 * x1p2
    denom == 0.0 && return [stop]
    numer = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2
    coef = (large_arc == sweep ? -1.0 : 1.0) *
           sqrt(max(0.0, numer / denom))
    cxp = coef * rx * y1p / ry
    cyp = coef * -ry * x1p / rx
    cx = cosφ * cxp - sinφ * cyp + (start.x + stop.x) / 2.0
    cy = sinφ * cxp + cosφ * cyp + (start.y + stop.y) / 2.0

    ux = (x1p - cxp) / rx
    uy = (y1p - cyp) / ry
    vx = (-x1p - cxp) / rx
    vy = (-y1p - cyp) / ry
    θ1 = atan(uy, ux)
    Δθ = atan(ux * vy - uy * vx, ux * vx + uy * vy)
    !sweep && Δθ > 0.0 && (Δθ -= 2π)
    sweep && Δθ < 0.0 && (Δθ += 2π)

    n = max(1, ceil(Int, abs(Δθ) / (π / 2.0)) * segments)
    return [begin
                θ = θ1 + Δθ * step / n
                Vec2(cosφ * rx * cos(θ) - sinφ * ry * sin(θ) + cx,
                     sinφ * rx * cos(θ) + cosφ * ry * sin(θ) + cy)
            end for step in 1:n]
end

function _svg_path_points(raw::AbstractString, segments::Int)
    tokens = _svg_lex(raw, _SVG_PATH_TOKEN_RE, "SVG path data")
    paths = SVGPath[]
    i = 1
    cmd = '\0'
    current = Vec2(0.0, 0.0)
    start = Vec2(0.0, 0.0)
    active = Vec2{Float64}[]
    last_cubic_control = nothing
    last_quadratic_control = nothing

    next_is_number() = i <= length(tokens) && !_svg_is_command(tokens[i])

    reflect_control(control::Vec2{Float64}) =
        Vec2(2.0 * current.x - control.x, 2.0 * current.y - control.y)

    function read_number(context)
        i <= length(tokens) || error("SVG path command $context is missing numbers")
        _svg_is_command(tokens[i]) &&
            error("SVG path command $context is missing numbers")
        v = parse(Float64, tokens[i])
        isfinite(v) || error("SVG path number must be finite")
        i += 1
        return v
    end

    function read_point(relative::Bool, context)
        p = Vec2(read_number(context), read_number(context))
        return relative ? current + p : p
    end

    function finish!(closed::Bool)
        if !isempty(active)
            closed && length(active) > 1 && active[end] == active[1] && pop!(active)
            length(active) >= 2 && push!(paths, SVGPath(:path, active, closed))
            active = Vec2{Float64}[]
        end
    end

    while i <= length(tokens)
        if _svg_is_command(tokens[i])
            cmd = tokens[i][1]
            i += 1
        elseif cmd == '\0'
            error("SVG path data must start with a command")
        end
        upper = uppercase(cmd)
        relative = islowercase(cmd)

        if upper == 'M'
            p = read_point(relative, cmd)
            finish!(false)
            current = p
            start = p
            active = [p]
            last_cubic_control = nothing
            last_quadratic_control = nothing
            cmd = relative ? 'l' : 'L'
            while next_is_number()
                current = read_point(relative, cmd)
                push!(active, current)
            end
            last_cubic_control = nothing
            last_quadratic_control = nothing
        elseif upper == 'L'
            while next_is_number()
                current = read_point(relative, cmd)
                push!(active, current)
            end
            last_cubic_control = nothing
            last_quadratic_control = nothing
        elseif upper == 'H'
            while next_is_number()
                x = read_number(cmd)
                current = Vec2(relative ? current.x + x : x, current.y)
                push!(active, current)
            end
            last_cubic_control = nothing
            last_quadratic_control = nothing
        elseif upper == 'V'
            while next_is_number()
                y = read_number(cmd)
                current = Vec2(current.x, relative ? current.y + y : y)
                push!(active, current)
            end
            last_cubic_control = nothing
            last_quadratic_control = nothing
        elseif upper == 'Q'
            while next_is_number()
                control = read_point(relative, cmd)
                stop = read_point(relative, cmd)
                origin = current
                for step in 1:segments
                    push!(active, _font_quadratic(origin, control, stop,
                                                  step / Float64(segments)))
                end
                current = stop
                last_quadratic_control = control
            end
            last_cubic_control = nothing
        elseif upper == 'T'
            while next_is_number()
                control = last_quadratic_control === nothing ? current :
                          reflect_control(last_quadratic_control)
                stop = read_point(relative, cmd)
                origin = current
                for step in 1:segments
                    push!(active, _font_quadratic(origin, control, stop,
                                                  step / Float64(segments)))
                end
                current = stop
                last_quadratic_control = control
            end
            last_cubic_control = nothing
        elseif upper == 'C'
            while next_is_number()
                c1 = read_point(relative, cmd)
                c2 = read_point(relative, cmd)
                stop = read_point(relative, cmd)
                origin = current
                for step in 1:segments
                    push!(active, _font_bezier(origin, c1, c2, stop,
                                               step / Float64(segments)))
                end
                current = stop
                last_cubic_control = c2
            end
            last_quadratic_control = nothing
        elseif upper == 'S'
            while next_is_number()
                c1 = last_cubic_control === nothing ? current :
                     reflect_control(last_cubic_control)
                c2 = read_point(relative, cmd)
                stop = read_point(relative, cmd)
                origin = current
                for step in 1:segments
                    push!(active, _font_bezier(origin, c1, c2, stop,
                                               step / Float64(segments)))
                end
                current = stop
                last_cubic_control = c2
            end
            last_quadratic_control = nothing
        elseif upper == 'A'
            while next_is_number()
                rx = read_number(cmd)
                ry = read_number(cmd)
                rotation = read_number(cmd)
                large_arc = _svg_arc_flag(read_number(cmd), "large-arc")
                sweep = _svg_arc_flag(read_number(cmd), "sweep")
                stop = read_point(relative, cmd)
                append!(active, _svg_arc_points(current, rx, ry, rotation,
                                                large_arc, sweep, stop,
                                                segments))
                current = stop
            end
            last_cubic_control = nothing
            last_quadratic_control = nothing
        elseif upper == 'Z'
            finish!(true)
            current = start
            last_cubic_control = nothing
            last_quadratic_control = nothing
        else
            error("unsupported SVG path command $cmd")
        end
    end
    finish!(false)
    return paths
end

function _svg_parse(raw::AbstractString; curve_segments::Integer=16,
                    circle_segments::Integer=32)
    segments = _svg_curve_segments(curve_segments)
    circle_n = _svg_circle_segments(circle_segments)
    root = match(r"(?is)<\s*svg\b([^>]*)>", raw)
    root === nothing && error("SVG document is missing <svg> root")
    root_attrs = _svg_attrs(root.captures[1])
    width, height = _svg_root_size(root_attrs)
    root_reference_bbox = _svg_root_reference_bbox(root_attrs, width, height)
    paths = SVGPath[]
    transform_stack = [_svg_identity_transform()]
    style_stack = [_SVG_DEFAULT_STYLE]
    display_stack = [true]
    visibility_stack = [:visible]
    clip_stack = [_SVGClipApplication[]]
    mask_stack = [_SVGClipApplication[]]
    ancestor_stack = _SVGAncestorStack()
    sibling_stack = _SVGSiblingStack([_SVGElementContext[]])
    css_rules = _svg_css_rules(raw)
    definitions = Dict{String,Vector{SVGPath}}()
    clip_definitions = Dict{String,_SVGClipDefinition}()
    mask_definitions = Dict{String,_SVGClipDefinition}()
    container_definition_stack = Union{Nothing,_SVGContainerDefinition}[nothing]
    container_paths_stack = [SVGPath[]]
    next_element_id = 0

    for m in eachmatch(r"(?is)<\s*(/)?\s*(svg|g|defs|clipPath|mask|path|rect|line|circle|ellipse|polygon|polyline|use)\b([^>]*)>",
                       raw)
        closing = m.captures[1] !== nothing
        tag = lowercase(m.captures[2])
        attrs = _svg_attrs(m.captures[3])
        self_closing = occursin(r"/\s*>$", m.match)

        if tag == "svg" || tag == "g" || tag == "defs" ||
           tag == "clippath" || tag == "mask"
            if closing
                if length(container_paths_stack) > 1
                    collected_paths = pop!(container_paths_stack)
                    definition = pop!(container_definition_stack)
                    if definition !== nothing && definition.bbox_clip !== nothing
                        if definition.kind === :element &&
                           display_stack[end] && visibility_stack[end] === :visible &&
                           length(paths) > definition.render_start
                            rendered_paths = paths[(definition.render_start + 1):end]
                            deleteat!(paths, (definition.render_start + 1):length(paths))
                            append!(paths,
                                    _svg_apply_clip_paths(rendered_paths,
                                                          [definition.bbox_clip],
                                                          clip_definitions))
                        end
                        collected_paths =
                            _svg_apply_clip_paths(collected_paths,
                                                  [definition.bbox_clip],
                                                  clip_definitions)
                    end
                    if definition !== nothing && definition.bbox_mask !== nothing
                        if definition.kind === :element &&
                           display_stack[end] && visibility_stack[end] === :visible &&
                           length(paths) > definition.render_start
                            rendered_paths = paths[(definition.render_start + 1):end]
                            deleteat!(paths, (definition.render_start + 1):length(paths))
                            append!(paths,
                                    _svg_apply_mask_paths(rendered_paths,
                                                          [definition.bbox_mask],
                                                          mask_definitions))
                        end
                        collected_paths =
                            _svg_apply_mask_paths(collected_paths,
                                                  [definition.bbox_mask],
                                                  mask_definitions)
                    end
                    if definition !== nothing && definition.kind === :clip
                        definition.id !== nothing &&
                            (clip_definitions[definition.id] =
                                _SVGClipDefinition(copy(collected_paths),
                                                   definition.units,
                                                   :luminance))
                    elseif definition !== nothing && definition.kind === :mask
                        definition.id !== nothing &&
                            (mask_definitions[definition.id] =
                                _SVGClipDefinition(_svg_mask_definition_paths(collected_paths,
                                                                              definition.mask_type),
                                                   definition.units,
                                                   definition.mask_type))
                    elseif definition !== nothing && !isempty(collected_paths)
                        definition.id !== nothing &&
                            (definitions[definition.id] = copy(collected_paths))
                        append!(container_paths_stack[end], collected_paths)
                    elseif definition === nothing || definition.kind !== :clip
                        append!(container_paths_stack[end], collected_paths)
                    end
                end
                length(transform_stack) > 1 && pop!(transform_stack)
                length(style_stack) > 1 && pop!(style_stack)
                length(display_stack) > 1 && pop!(display_stack)
                length(visibility_stack) > 1 && pop!(visibility_stack)
                length(clip_stack) > 1 && pop!(clip_stack)
                length(mask_stack) > 1 && pop!(mask_stack)
                !isempty(ancestor_stack) && pop!(ancestor_stack)
                length(sibling_stack) > 1 && pop!(sibling_stack)
            else
                context = _svg_element_context(tag, attrs, ancestor_stack,
                                               sibling_stack[end])
                push!(sibling_stack[end], context)
                if self_closing && tag == "clippath" && haskey(attrs, "id")
                    clip_definitions[attrs["id"]] =
                        _SVGClipDefinition(SVGPath[],
                                           _svg_clip_path_units(attrs),
                                           :luminance)
                end
                if self_closing && tag == "mask" && haskey(attrs, "id")
                    mask_definitions[attrs["id"]] =
                        _SVGClipDefinition(SVGPath[],
                                           _svg_mask_content_units(attrs),
                                           _svg_mask_type(attrs, css_rules, tag,
                                                          context))
                end
                if !self_closing
                    display_ok, visibility =
                        (tag == "defs" || tag == "clippath" || tag == "mask") ?
                        (false, visibility_stack[end]) :
                        _svg_display_visibility(display_stack[end],
                                                visibility_stack[end], attrs,
                                                css_rules, tag, context)
                    local_clip_spec =
                        tag == "defs" ? nothing :
                        _svg_clip_spec_from_attrs(attrs, css_rules, tag,
                                                  context, segments, circle_n)
                    local_mask_spec =
                        tag == "defs" ? nothing :
                        _svg_mask_spec_from_attrs(attrs, css_rules, tag,
                                                  context, circle_n)
                    child_clip_ids = copy(clip_stack[end])
                    child_mask_ids = copy(mask_stack[end])
                    local_bbox_clip = nothing
                    local_bbox_mask = nothing
                    if local_clip_spec !== nothing
                        if _svg_clip_spec_uses_bbox(local_clip_spec)
                            local_bbox_clip =
                                _SVGClipApplication(local_clip_spec,
                                                    :container_bbox,
                                                    root_reference_bbox)
                        elseif haskey(clip_definitions, local_clip_spec.id) &&
                              clip_definitions[local_clip_spec.id].units === :objectBoundingBox
                            local_bbox_clip =
                                _SVGClipApplication(local_clip_spec,
                                                    :container_bbox,
                                                    root_reference_bbox)
                        else
                            push!(child_clip_ids,
                                  _SVGClipApplication(local_clip_spec, :container,
                                                      root_reference_bbox))
                        end
                    end
                    if local_mask_spec !== nothing
                        if haskey(mask_definitions, local_mask_spec.id) &&
                           mask_definitions[local_mask_spec.id].units === :objectBoundingBox
                            local_bbox_mask =
                                _SVGClipApplication(local_mask_spec,
                                                    :container_bbox,
                                                    root_reference_bbox)
                        else
                            push!(child_mask_ids,
                                  _SVGClipApplication(local_mask_spec, :container,
                                                      root_reference_bbox))
                        end
                    end
                    push!(transform_stack,
                          _svg_compose_transform(transform_stack[end],
                                                 _svg_transform_from_attrs(attrs)))
                    push!(style_stack,
                          _svg_style_from_attrs(style_stack[end], attrs, css_rules,
                                                tag, context))
                    push!(display_stack, display_ok)
                    push!(visibility_stack, visibility)
                    push!(clip_stack, child_clip_ids)
                    push!(mask_stack, child_mask_ids)
                    push!(ancestor_stack, context)
                    push!(sibling_stack, _SVGElementContext[])
                    definition = if tag == "clippath"
                        _SVGContainerDefinition(:clip, get(attrs, "id", nothing),
                                                _svg_clip_path_units(attrs),
                                                local_bbox_clip, local_bbox_mask,
                                                :luminance, length(paths))
                    elseif tag == "mask"
                        _SVGContainerDefinition(:mask, get(attrs, "id", nothing),
                                                _svg_mask_content_units(attrs),
                                                local_bbox_clip, local_bbox_mask,
                                                _svg_mask_type(attrs, css_rules, tag,
                                                               context),
                                                length(paths))
                    else
                        _SVGContainerDefinition(:element,
                                                get(attrs, "id", nothing),
                                                :userSpaceOnUse,
                                                local_bbox_clip, local_bbox_mask,
                                                :luminance, length(paths))
                    end
                    push!(container_definition_stack, definition)
                    push!(container_paths_stack, SVGPath[])
                end
            end
            continue
        end
        closing && continue

        context = _svg_element_context(tag, attrs, ancestor_stack,
                                       sibling_stack[end])
        local_transform = _svg_transform_from_attrs(attrs)
        total_transform = _svg_compose_transform(transform_stack[end],
                                                 local_transform)
        style = _svg_style_from_attrs(style_stack[end], attrs, css_rules, tag,
                                      context)
        display_ok, visibility =
            _svg_display_visibility(display_stack[end], visibility_stack[end],
                                    attrs, css_rules, tag, context)
        if tag == "use" && (!display_ok || visibility !== :visible)
            push!(sibling_stack[end], context)
            continue
        end
        clip_applications = copy(clip_stack[end])
        mask_applications = copy(mask_stack[end])
        local_clip_spec = _svg_clip_spec_from_attrs(attrs, css_rules, tag,
                                                    context, segments, circle_n)
        local_clip_spec !== nothing &&
            push!(clip_applications,
                  _SVGClipApplication(local_clip_spec, :local,
                                      root_reference_bbox))
        local_mask_spec = _svg_mask_spec_from_attrs(attrs, css_rules, tag,
                                                    context, circle_n)
        local_mask_spec !== nothing &&
            push!(mask_applications,
                  _SVGClipApplication(local_mask_spec, :local,
                                      root_reference_bbox))
        raw_paths = SVGPath[]
        if tag == "use"
            href_id = _svg_local_href_id(attrs)
            if href_id !== nothing
                haskey(definitions, href_id) ||
                    error("SVG use references unknown id $href_id")
                x = _svg_length(attrs, "x", 0.0)
                y = _svg_length(attrs, "y", 0.0)
                use_transform = _svg_compose_transform(
                    total_transform, (1.0, 0.0, 0.0, 1.0, x, y))
                for template in definitions[href_id]
                    use_style = _svg_style_from_attrs(template.style, attrs,
                                                      css_rules, tag, context)
                    push!(raw_paths,
                          _svg_transform_path(_svg_style_path(template,
                                                              use_style),
                                              use_transform))
                end
            end
        elseif tag == "path"
            d = get(attrs, "d", nothing)
            d !== nothing && append!(raw_paths, _svg_path_points(d, segments))
        elseif tag == "rect"
            rect = _svg_rect(attrs, segments)
            rect !== nothing && push!(raw_paths, rect)
        elseif tag == "line"
            line = _svg_line(attrs)
            line !== nothing && push!(raw_paths, line)
        elseif tag == "circle"
            cx = _svg_length(attrs, "cx", 0.0)
            cy = _svg_length(attrs, "cy", 0.0)
            r = _svg_length(attrs, "r", 0.0)
            points = _svg_ellipse_points(cx, cy, r, r, circle_n)
            !isempty(points) && push!(raw_paths, SVGPath(:circle, points, true))
        elseif tag == "ellipse"
            cx = _svg_length(attrs, "cx", 0.0)
            cy = _svg_length(attrs, "cy", 0.0)
            rx = _svg_length(attrs, "rx", 0.0)
            ry = _svg_length(attrs, "ry", 0.0)
            points = _svg_ellipse_points(cx, cy, rx, ry, circle_n)
            !isempty(points) && push!(raw_paths, SVGPath(:ellipse, points, true))
        elseif tag == "polygon" || tag == "polyline"
            points_raw = get(attrs, "points", "")
            points = _svg_points(points_raw)
            length(points) >= 2 &&
                push!(raw_paths, SVGPath(Symbol(tag), points, tag == "polygon"))
        end
        element_paths = tag == "use" ? raw_paths :
                        [_svg_transform_path(_svg_style_path(path, style),
                                             total_transform)
                         for path in raw_paths]
        !isempty(clip_applications) &&
            (element_paths = _svg_apply_clip_paths(element_paths,
                                                   clip_applications,
                                                   clip_definitions))
        !isempty(mask_applications) &&
            (element_paths = _svg_apply_mask_paths(element_paths,
                                                   mask_applications,
                                                   mask_definitions))
        if !isempty(element_paths)
            next_element_id += 1
            element_paths = [_svg_element_path(path, next_element_id)
                             for path in element_paths]
        end
        if tag != "use" && haskey(attrs, "id") && !isempty(element_paths)
            definitions[attrs["id"]] = copy(element_paths)
        end
        append!(container_paths_stack[end], element_paths)
        if !display_ok || visibility !== :visible
            push!(sibling_stack[end], context)
            continue
        end
        append!(paths, element_paths)
        push!(sibling_stack[end], context)
    end

    return SVGDocument(width, height, paths)
end

"""Load common SVG path, primitive, bounded URL/basic-shape clip-path, and vector URL mask geometry into an `SVGDocument`."""
load_svg(path::String; kwargs...) = _svg_parse(read(path, String); kwargs...)

"""Alias for [`load_svg`](@ref), matching three.js `SVGLoader` naming."""
SVGLoader(path::String; kwargs...) = load_svg(path; kwargs...)

"""Return closed SVG point loops that can be consumed by `ShapeGeometry`."""
svg_shapes(svg::SVGDocument) =
    [copy(path.points) for path in svg.paths if path.closed && length(path.points) >= 3]

svg_shapes(path::String; kwargs...) = svg_shapes(load_svg(path; kwargs...))

function _svg_element_path_groups(paths::Vector{SVGPath})
    buckets = Dict{Int,Vector{SVGPath}}()
    order = Int[]
    for (idx, path) in enumerate(paths)
        key = path.element_id == 0 ? -idx : path.element_id
        if !haskey(buckets, key)
            buckets[key] = SVGPath[]
            push!(order, key)
        end
        push!(buckets[key], path)
    end
    return [buckets[key] for key in order]
end

function _svg_fill_loop_groups(loops::Vector{Vector{Vec2{Float64}}},
                               fill_rule::Symbol)
    fill_rule === :nonzero || fill_rule === :evenodd ||
        error("unsupported SVG fill-rule $(fill_rule)")
    clean = [_font_loop_points(loop) for loop in loops]
    clean = [loop for loop in clean
             if length(loop) >= 3 && abs(_font_polygon_area(loop)) > 1e-12]
    groups = NamedTuple{(:outer, :holes),
                        Tuple{Vector{Vec2{Float64}},Vector{Vector{Vec2{Float64}}}}}[]
    isempty(clean) && return groups

    areas = abs.(_font_polygon_area.(clean))
    signs = [_font_polygon_area(loop) >= 0.0 ? 1 : -1 for loop in clean]
    direct_parent = fill(0, length(clean))
    for i in eachindex(clean)
        p = clean[i][1]
        best = 0
        best_area = Inf
        for j in eachindex(clean)
            i == j && continue
            areas[j] > areas[i] || continue
            if _font_point_in_loop(p, clean[j]) && areas[j] < best_area
                best = j
                best_area = areas[j]
            end
        end
        direct_parent[i] = best
    end

    depths = zeros(Int, length(clean))
    ancestor_winding = zeros(Int, length(clean))
    for i in eachindex(clean)
        parent = direct_parent[i]
        while parent != 0
            depths[i] += 1
            ancestor_winding[i] += signs[parent]
            parent = direct_parent[parent]
        end
    end

    is_outer = falses(length(clean))
    is_hole = falses(length(clean))
    for i in eachindex(clean)
        if fill_rule === :evenodd
            outside_filled = isodd(depths[i])
            inside_filled = !outside_filled
        else
            outside_filled = ancestor_winding[i] != 0
            inside_filled = ancestor_winding[i] + signs[i] != 0
        end
        is_outer[i] = !outside_filled && inside_filled
        is_hole[i] = outside_filled && !inside_filled
    end

    outer_group = Dict{Int,Int}()
    for i in eachindex(clean)
        is_outer[i] || continue
        holes = Vector{Vec2{Float64}}[]
        push!(groups, (outer=_font_orient_loop(clean[i], true), holes=holes))
        outer_group[i] = length(groups)
    end
    for i in eachindex(clean)
        is_hole[i] || continue
        parent = direct_parent[i]
        while parent != 0
            group_idx = get(outer_group, parent, 0)
            if group_idx != 0
                push!(groups[group_idx].holes, _font_orient_loop(clean[i], false))
                break
            end
            parent = direct_parent[parent]
        end
    end
    return groups
end

function _svg_fill_geometries(paths::Vector{SVGPath})
    closed = [path for path in paths if path.closed && length(path.points) >= 3]
    isempty(closed) && return BufferGeometry[]
    fill_rule = closed[1].style.fill_rule
    geos = BufferGeometry[]
    for group in _svg_fill_loop_groups([path.points for path in closed], fill_rule)
        geo = _font_shape_geometry_with_holes(group.outer, group.holes)
        geo.n_faces > 0 && push!(geos, geo)
    end
    return geos
end

function _svg_same_fill_mesh_style(a::SVGStyle, b::SVGStyle)
    return a.fill == b.fill &&
           a.opacity == b.opacity &&
           a.fill_opacity == b.fill_opacity &&
           a.fill_rule === b.fill_rule
end

function _svg_fill_mesh_path_groups(paths::Vector{SVGPath})
    groups = Vector{SVGPath}[]
    for path in paths
        inserted = false
        for group in groups
            if _svg_same_fill_mesh_style(group[1].style, path.style)
                push!(group, path)
                inserted = true
                break
            end
        end
        inserted || push!(groups, SVGPath[path])
    end
    return groups
end

"""Triangulate closed SVG loops into a merged `BufferGeometry`."""
function svg_geometry(svg::SVGDocument)
    geos = BufferGeometry[]
    for paths in _svg_element_path_groups(svg.paths)
        append!(geos, _svg_fill_geometries(paths))
    end
    isempty(geos) && return BufferGeometry()
    return merge_geometries(geos; with_groups=false)
end

svg_geometry(path::String; kwargs...) = svg_geometry(load_svg(path; kwargs...))

function _svg_line_geometry(points::Vector{Vec2{Float64}})
    positions = Float64[]
    for p in points
        push!(positions, p.x, p.y, 0.0)
    end
    return BufferGeometry(positions, Float64[], Float64[], Int[], length(points), 0)
end

function _svg_dash_phase(dasharray::Vector{Float64}, phase::Float64)
    cursor = 0.0
    for (idx, dash) in enumerate(dasharray)
        next_cursor = cursor + dash
        if phase < next_cursor
            return isodd(idx), next_cursor - phase
        end
        cursor = next_cursor
    end
    cursor = 0.0
    for (idx, dash) in enumerate(dasharray)
        dash > 0.0 && return isodd(idx), dash
        cursor += dash
    end
    return true, Inf
end

function _svg_dash_intervals(total::Float64, dasharray::Vector{Float64},
                             dashoffset::Float64)
    intervals = Tuple{Float64,Float64}[]
    total > 0.0 || return intervals
    isempty(dasharray) && return [(0.0, total)]
    period = sum(dasharray)
    period > 0.0 || return [(0.0, total)]
    offset = mod(dashoffset, period)
    cursor = 0.0
    while cursor < total
        visible, remain = _svg_dash_phase(dasharray, mod(cursor + offset, period))
        step = min(remain, total - cursor)
        step > 0.0 || break
        visible && push!(intervals, (cursor, cursor + step))
        cursor += step
    end
    return intervals
end

function _svg_path_segments(points::Vector{Vec2{Float64}}, closed::Bool)
    segments = NamedTuple{(:a, :b, :s0, :s1),
                          Tuple{Vec2{Float64},Vec2{Float64},Float64,Float64}}[]
    closed_path = closed && length(points) >= 3
    segment_count = closed_path ? length(points) : length(points) - 1
    total = 0.0
    for i in 1:segment_count
        a = points[i]
        b = points[i == length(points) ? 1 : i + 1]
        len = hypot(b.x - a.x, b.y - a.y)
        len > 0.0 || continue
        push!(segments, (a=a, b=b, s0=total, s1=total + len))
        total += len
    end
    return segments, total, closed_path
end

function _svg_segment_point(segment, distance::Float64)
    t = (distance - segment.s0) / (segment.s1 - segment.s0)
    return Vec2(segment.a.x + (segment.b.x - segment.a.x) * t,
                segment.a.y + (segment.b.y - segment.a.y) * t)
end

function _svg_path_point_at(segments, distance::Float64)
    isempty(segments) && return Vec2(0.0, 0.0)
    distance <= segments[1].s0 && return segments[1].a
    distance >= segments[end].s1 && return segments[end].b
    for segment in segments
        distance <= segment.s1 && return _svg_segment_point(segment, distance)
    end
    return segments[end].b
end

function _svg_push_unique_point!(points::Vector{Vec2{Float64}},
                                 p::Vec2{Float64})
    if isempty(points) || hypot(points[end].x - p.x, points[end].y - p.y) > 1e-9
        push!(points, p)
    end
    return points
end

function _svg_interval_subpath(segments, start_distance::Float64,
                               stop_distance::Float64)
    points = Vec2{Float64}[]
    stop_distance > start_distance || return points
    _svg_push_unique_point!(points, _svg_path_point_at(segments, start_distance))
    for segment in segments
        if segment.s1 > start_distance + 1e-9 &&
           segment.s1 < stop_distance - 1e-9
            _svg_push_unique_point!(points, segment.b)
        end
    end
    _svg_push_unique_point!(points, _svg_path_point_at(segments, stop_distance))
    return points
end

function _svg_stroke_subpaths(points::Vector{Vec2{Float64}}, closed::Bool,
                              dasharray::Vector{Float64}, dashoffset::Float64)
    length(points) >= 2 || return Tuple{Vector{Vec2{Float64}},Bool}[]
    segments, total, closed_path = _svg_path_segments(points, closed)
    isempty(segments) && return Tuple{Vector{Vec2{Float64}},Bool}[]
    intervals = _svg_dash_intervals(total, dasharray, dashoffset)
    if length(intervals) == 1 && intervals[1][1] <= 1e-9 &&
       intervals[1][2] >= total - 1e-9
        return [(copy(points), closed_path)]
    end
    out = Tuple{Vector{Vec2{Float64}},Bool}[]
    for (start_distance, stop_distance) in intervals
        subpath = _svg_interval_subpath(segments, start_distance, stop_distance)
        length(subpath) >= 2 && push!(out, (subpath, false))
    end
    return out
end

const _SVG_ROUND_CAP_SEGMENTS = 12

function _svg_compact_consecutive_points(points::Vector{Vec2{Float64}})
    out = Vec2{Float64}[]
    for p in points
        _svg_push_unique_point!(out, p)
    end
    return out
end

function _svg_endpoint_directions(points::Vector{Vec2{Float64}})
    first_dir = nothing
    for i in 1:(length(points) - 1)
        a = points[i]
        b = points[i + 1]
        len = hypot(b.x - a.x, b.y - a.y)
        if len > 0.0
            first_dir = ((b.x - a.x) / len, (b.y - a.y) / len)
            break
        end
    end
    first_dir === nothing && return nothing
    for i in (length(points) - 1):-1:1
        a = points[i]
        b = points[i + 1]
        len = hypot(b.x - a.x, b.y - a.y)
        if len > 0.0
            return first_dir, ((b.x - a.x) / len, (b.y - a.y) / len)
        end
    end
    return nothing
end

function _svg_square_cap_points(points::Vector{Vec2{Float64}}, half_width::Float64)
    dirs = _svg_endpoint_directions(points)
    dirs === nothing && return points
    first_dir, last_dir = dirs
    out = copy(points)
    out[1] = Vec2(out[1].x - first_dir[1] * half_width,
                  out[1].y - first_dir[2] * half_width)
    out[end] = Vec2(out[end].x + last_dir[1] * half_width,
                    out[end].y + last_dir[2] * half_width)
    return out
end

function _svg_push_stroke_vertex!(positions::Vector{Float64},
                                  normals::Vector{Float64},
                                  uvs::Vector{Float64}, p::Vec2{Float64},
                                  u::Float64, v::Float64)
    push!(positions, p.x, p.y, 0.0)
    push!(normals, 0.0, 0.0, 1.0)
    push!(uvs, u, v)
    return length(positions) ÷ 3
end

function _svg_add_round_cap!(positions::Vector{Float64},
                             normals::Vector{Float64}, uvs::Vector{Float64},
                             indices::Vector{Int}, center::Vec2{Float64},
                             start_angle::Float64, stop_angle::Float64,
                             half_width::Float64)
    center_idx = _svg_push_stroke_vertex!(positions, normals, uvs, center, 0.5, 0.5)
    prev = _svg_push_stroke_vertex!(positions, normals, uvs,
                                    Vec2(center.x + cos(start_angle) * half_width,
                                         center.y + sin(start_angle) * half_width),
                                    0.0, 0.0)
    for step in 1:_SVG_ROUND_CAP_SEGMENTS
        t = step / Float64(_SVG_ROUND_CAP_SEGMENTS)
        angle = start_angle + (stop_angle - start_angle) * t
        next = _svg_push_stroke_vertex!(positions, normals, uvs,
                                        Vec2(center.x + cos(angle) * half_width,
                                             center.y + sin(angle) * half_width),
                                        t, 1.0)
        push!(indices, center_idx, prev, next)
        prev = next
    end
    return nothing
end

_svg_cross2(ax::Float64, ay::Float64, bx::Float64, by::Float64) = ax * by - ay * bx

function _svg_join_directions(prev::Vec2{Float64}, p::Vec2{Float64},
                              next::Vec2{Float64})
    d1x = p.x - prev.x
    d1y = p.y - prev.y
    d2x = next.x - p.x
    d2y = next.y - p.y
    len1 = hypot(d1x, d1y)
    len2 = hypot(d2x, d2y)
    (len1 > 0.0 && len2 > 0.0) || return nothing
    return (d1x / len1, d1y / len1), (d2x / len2, d2y / len2)
end

function _svg_offset_line_intersection(p1::Vec2{Float64}, d1,
                                       p2::Vec2{Float64}, d2)
    denom = _svg_cross2(d1[1], d1[2], d2[1], d2[2])
    abs(denom) > 1e-12 || return nothing
    qx = p2.x - p1.x
    qy = p2.y - p1.y
    t = _svg_cross2(qx, qy, d2[1], d2[2]) / denom
    return Vec2(p1.x + d1[1] * t, p1.y + d1[2] * t)
end

function _svg_join_outer_points(prev::Vec2{Float64}, p::Vec2{Float64},
                                next::Vec2{Float64}, half_width::Float64)
    dirs = _svg_join_directions(prev, p, next)
    dirs === nothing && return nothing
    d1, d2 = dirs
    turn = _svg_cross2(d1[1], d1[2], d2[1], d2[2])
    abs(turn) > 1e-12 || return nothing
    side = turn > 0.0 ? -1.0 : 1.0
    n1 = (-d1[2] * side, d1[1] * side)
    n2 = (-d2[2] * side, d2[1] * side)
    outer1 = Vec2(p.x + n1[1] * half_width, p.y + n1[2] * half_width)
    outer2 = Vec2(p.x + n2[1] * half_width, p.y + n2[2] * half_width)
    return d1, d2, turn, outer1, outer2
end

function _svg_add_bevel_join!(positions::Vector{Float64},
                              normals::Vector{Float64}, uvs::Vector{Float64},
                              indices::Vector{Int}, p::Vec2{Float64},
                              outer1::Vec2{Float64}, outer2::Vec2{Float64})
    center = _svg_push_stroke_vertex!(positions, normals, uvs, p, 0.5, 0.5)
    a = _svg_push_stroke_vertex!(positions, normals, uvs, outer1, 0.0, 0.0)
    b = _svg_push_stroke_vertex!(positions, normals, uvs, outer2, 1.0, 1.0)
    push!(indices, center, a, b)
    return nothing
end

function _svg_add_miter_join!(positions::Vector{Float64},
                              normals::Vector{Float64}, uvs::Vector{Float64},
                              indices::Vector{Int}, p::Vec2{Float64}, d1, d2,
                              outer1::Vec2{Float64}, outer2::Vec2{Float64},
                              half_width::Float64, miterlimit::Float64)
    miter = _svg_offset_line_intersection(outer1, d1, outer2, d2)
    if miter === nothing ||
       hypot(miter.x - p.x, miter.y - p.y) > half_width * miterlimit + 1e-9
        _svg_add_bevel_join!(positions, normals, uvs, indices, p, outer1, outer2)
        return nothing
    end
    a = _svg_push_stroke_vertex!(positions, normals, uvs, outer1, 0.0, 0.0)
    m = _svg_push_stroke_vertex!(positions, normals, uvs, miter, 0.5, 1.0)
    b = _svg_push_stroke_vertex!(positions, normals, uvs, outer2, 1.0, 0.0)
    push!(indices, a, m, b)
    return nothing
end

function _svg_round_join_sweep(start_angle::Float64, stop_angle::Float64,
                               turn::Float64)
    if turn > 0.0
        while stop_angle <= start_angle
            stop_angle += 2pi
        end
    else
        while stop_angle >= start_angle
            stop_angle -= 2pi
        end
    end
    return start_angle, stop_angle
end

function _svg_add_round_join!(positions::Vector{Float64},
                              normals::Vector{Float64}, uvs::Vector{Float64},
                              indices::Vector{Int}, p::Vec2{Float64},
                              outer1::Vec2{Float64}, outer2::Vec2{Float64},
                              half_width::Float64, turn::Float64)
    start_angle = atan(outer1.y - p.y, outer1.x - p.x)
    stop_angle = atan(outer2.y - p.y, outer2.x - p.x)
    start_angle, stop_angle = _svg_round_join_sweep(start_angle, stop_angle, turn)
    sweep = stop_angle - start_angle
    segments = max(1, ceil(Int, abs(sweep) / pi * _SVG_ROUND_CAP_SEGMENTS))
    center_idx = _svg_push_stroke_vertex!(positions, normals, uvs, p, 0.5, 0.5)
    prev = _svg_push_stroke_vertex!(positions, normals, uvs, outer1, 0.0, 0.0)
    for step in 1:segments
        t = step / Float64(segments)
        angle = start_angle + sweep * t
        next_idx = _svg_push_stroke_vertex!(positions, normals, uvs,
                                            Vec2(p.x + cos(angle) * half_width,
                                                 p.y + sin(angle) * half_width),
                                            t, 1.0)
        push!(indices, center_idx, prev, next_idx)
        prev = next_idx
    end
    return nothing
end

function _svg_add_stroke_join!(positions::Vector{Float64},
                               normals::Vector{Float64}, uvs::Vector{Float64},
                               indices::Vector{Int}, prev::Vec2{Float64},
                               p::Vec2{Float64}, next::Vec2{Float64},
                               half_width::Float64, linejoin::Symbol,
                               miterlimit::Float64)
    info = _svg_join_outer_points(prev, p, next, half_width)
    info === nothing && return nothing
    d1, d2, turn, outer1, outer2 = info
    if linejoin === :bevel
        _svg_add_bevel_join!(positions, normals, uvs, indices, p, outer1, outer2)
    elseif linejoin === :round
        _svg_add_round_join!(positions, normals, uvs, indices, p, outer1, outer2,
                             half_width, turn)
    elseif linejoin === :miter
        _svg_add_miter_join!(positions, normals, uvs, indices, p, d1, d2,
                             outer1, outer2, half_width, miterlimit)
    else
        error("unsupported SVG stroke-linejoin $(linejoin)")
    end
    return nothing
end

function _svg_stroke_outline_geometry(points::Vector{Vec2{Float64}},
                                      closed::Bool, stroke_width::Float64,
                                      linecap::Symbol=:butt,
                                      linejoin::Symbol=:miter,
                                      miterlimit::Float64=4.0)
    positions = Float64[]
    normals = Float64[]
    uvs = Float64[]
    indices = Int[]
    work_points = _svg_compact_consecutive_points(points)
    length(work_points) >= 2 && stroke_width > 0.0 || return BufferGeometry()
    linecap in (:butt, :round, :square) ||
        error("unsupported SVG stroke-linecap $(linecap)")
    linejoin in (:miter, :round, :bevel) ||
        error("unsupported SVG stroke-linejoin $(linejoin)")
    miterlimit >= 1.0 || error("SVG stroke-miterlimit must be at least 1")
    half_width = stroke_width / 2.0
    closed_path = closed && length(work_points) >= 3
    if !closed_path && linecap === :square
        work_points = _svg_square_cap_points(work_points, half_width)
    end
    segment_count = closed_path ? length(work_points) : length(work_points) - 1
    for i in 1:segment_count
        a = work_points[i]
        b = work_points[i == length(work_points) ? 1 : i + 1]
        dx = b.x - a.x
        dy = b.y - a.y
        len = hypot(dx, dy)
        len > 0.0 || continue
        nx = -dy / len * half_width
        ny = dx / len * half_width
        quad = (Vec2(a.x + nx, a.y + ny),
                Vec2(a.x - nx, a.y - ny),
                Vec2(b.x - nx, b.y - ny),
                Vec2(b.x + nx, b.y + ny))
        quad_indices = Int[]
        for (u, p) in zip((0.0, 0.0, 1.0, 1.0), quad)
            push!(quad_indices,
                  _svg_push_stroke_vertex!(positions, normals, uvs, p, u,
                                           i == 1 ? 0.0 : 1.0))
        end
        push!(indices, quad_indices[1], quad_indices[2], quad_indices[3],
              quad_indices[1], quad_indices[3], quad_indices[4])
    end
    if closed_path
        for i in 1:length(work_points)
            prev = work_points[i == 1 ? end : i - 1]
            p = work_points[i]
            next = work_points[i == length(work_points) ? 1 : i + 1]
            _svg_add_stroke_join!(positions, normals, uvs, indices, prev, p, next,
                                  half_width, linejoin, miterlimit)
        end
    else
        for i in 2:(length(work_points) - 1)
            _svg_add_stroke_join!(positions, normals, uvs, indices,
                                  work_points[i - 1], work_points[i],
                                  work_points[i + 1], half_width, linejoin,
                                  miterlimit)
        end
    end
    if !closed_path && linecap === :round
        dirs = _svg_endpoint_directions(work_points)
        if dirs !== nothing
            first_dir, last_dir = dirs
            start_angle = atan(first_dir[2], first_dir[1]) + pi / 2.0
            _svg_add_round_cap!(positions, normals, uvs, indices, work_points[1],
                                start_angle, start_angle + pi, half_width)
            stop_angle = atan(last_dir[2], last_dir[1]) - pi / 2.0
            _svg_add_round_cap!(positions, normals, uvs, indices, work_points[end],
                                stop_angle, stop_angle + pi, half_width)
        end
    end
    return BufferGeometry(positions, normals, uvs, indices, length(positions) ÷ 3,
                          length(indices) ÷ 3)
end

"""
    points_to_stroke_geometry(points; closed=false, stroke_width=1.0,
                              linecap=:butt, linejoin=:miter,
                              miterlimit=4.0)

Build triangle geometry for a stroked 2D point loop or polyline, similar to
three.js `SVGLoader.pointsToStroke`. The tessellator expands each
non-degenerate segment into quads and supports square/round caps plus
miter/bevel/round joins.
"""
function points_to_stroke_geometry(points::AbstractVector{<:Vec2};
                                   closed::Bool=false,
                                   stroke_width::Real=1.0,
                                   linecap::Symbol=:butt,
                                   linejoin::Symbol=:miter,
                                   miterlimit::Real=4.0)
    width = Float64(stroke_width)
    isfinite(width) && width >= 0.0 ||
        throw(ArgumentError("stroke_width must be finite and non-negative"))
    limit = Float64(miterlimit)
    isfinite(limit) && limit >= 1.0 ||
        throw(ArgumentError("miterlimit must be finite and at least 1"))
    clean = Vec2{Float64}[]
    for point in points
        x = Float64(point.x)
        y = Float64(point.y)
        isfinite(x) && isfinite(y) ||
            throw(ArgumentError("stroke points must have finite coordinates"))
        push!(clean, Vec2(x, y))
    end
    return _svg_stroke_outline_geometry(clean, closed, width, linecap, linejoin,
                                        limit)
end

"""Build `Mesh` objects for filled, closed SVG paths using parsed fill styles."""
function svg_meshes(svg::SVGDocument)
    out = Mesh[]
    for paths in _svg_element_path_groups(svg.paths)
        for styled_paths in _svg_fill_mesh_path_groups(paths)
            isempty(styled_paths) && continue
            style = styled_paths[1].style
            fill = style.fill
            fill === nothing && continue
            opacity = style.opacity * style.fill_opacity
            opacity > 0.0 || continue
            geos = _svg_fill_geometries(styled_paths)
            isempty(geos) && continue
            geo = length(geos) == 1 ? geos[1] :
                  merge_geometries(geos; with_groups=false)
            mat = MeshBasicMaterial(color=fill, opacity=opacity,
                                    transparent=opacity < 1.0, side=:double)
            push!(out, Mesh(geo, mat; name="SVGFill"))
        end
    end
    return out
end

svg_meshes(path::String; kwargs...) = svg_meshes(load_svg(path; kwargs...))

"""Build triangle meshes for stroked SVG paths using parsed stroke styles.

The outline tessellator emits a quad per non-degenerate path segment, expands
`stroke-dasharray`/`stroke-dashoffset` into visible stroked subpaths, and adds
square/round caps plus miter/bevel/round exterior joins. It is useful when a
downstream renderer needs triangle meshes instead of native line primitives.
"""
function svg_stroke_meshes(svg::SVGDocument)
    out = Mesh[]
    for path in svg.paths
        stroke = path.style.stroke
        stroke === nothing && continue
        length(path.points) >= 2 || continue
        path.style.stroke_width > 0.0 || continue
        opacity = path.style.opacity * path.style.stroke_opacity
        opacity > 0.0 || continue
        geos = BufferGeometry[]
        for (subpath, subpath_closed) in
            _svg_stroke_subpaths(copy(path.points), path.closed,
                                 path.style.stroke_dasharray,
                                 path.style.stroke_dashoffset)
            geo = _svg_stroke_outline_geometry(subpath, subpath_closed,
                                               path.style.stroke_width,
                                               path.style.stroke_linecap,
                                               path.style.stroke_linejoin,
                                               path.style.stroke_miterlimit)
            geo.n_faces > 0 && push!(geos, geo)
        end
        isempty(geos) && continue
        geo = length(geos) == 1 ? geos[1] : merge_geometries(geos; with_groups=false)
        geo.n_faces > 0 || continue
        mat = MeshBasicMaterial(color=stroke, opacity=opacity,
                                transparent=opacity < 1.0, side=:double)
        push!(out, Mesh(geo, mat; name="SVGStrokeMesh"))
    end
    return out
end

svg_stroke_meshes(path::String; kwargs...) = svg_stroke_meshes(load_svg(path; kwargs...))

"""Build line objects for stroked SVG paths using parsed stroke styles."""
function svg_strokes(svg::SVGDocument)
    out = AbstractObject3D[]
    for path in svg.paths
        stroke = path.style.stroke
        stroke === nothing && continue
        length(path.points) >= 2 || continue
        path.style.stroke_width > 0.0 || continue
        opacity = path.style.opacity * path.style.stroke_opacity
        opacity > 0.0 || continue
        mat = LineBasicMaterial(color=stroke, linewidth=path.style.stroke_width,
                                opacity=opacity)
        for (subpath, subpath_closed) in
            _svg_stroke_subpaths(copy(path.points), path.closed,
                                 path.style.stroke_dasharray,
                                 path.style.stroke_dashoffset)
            geo = _svg_line_geometry(subpath)
            push!(out, subpath_closed ? LineLoop(geo, mat; name="SVGStroke") :
                                        LineObject(geo, mat; name="SVGStroke"))
        end
    end
    return out
end

svg_strokes(path::String; kwargs...) = svg_strokes(load_svg(path; kwargs...))

# ========================== base64 ==========================

const _B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const _B64_LUT = let lut = fill(-1, 256); for (k, ch) in enumerate(_B64_CHARS); lut[Int(ch)+1] = k-1; end; lut end

function base64_decode(s::AbstractString)
    out = UInt8[]; acc = 0; nbits = 0
    for ch in s
        ch in ('=', '\n', '\r', ' ') && continue
        v = _B64_LUT[Int(ch) + 1]
        v < 0 && continue
        acc = (acc << 6) | v; nbits += 6
        if nbits >= 8
            nbits -= 8; push!(out, UInt8((acc >> nbits) & 0xff))
        end
    end
    return out
end

function _gltf_base64_decode_strict(s::AbstractString)
    out = UInt8[]
    quartet = Int[]
    done = false
    for ch in s
        ch in (' ', '\n', '\r', '\t') && continue
        done && error("glTF data URI base64 has data after padding")
        if ch == '='
            push!(quartet, -1)
        else
            Int(ch) <= 255 || error("glTF data URI base64 contains invalid character")
            v = _B64_LUT[Int(ch) + 1]
            v >= 0 || error("glTF data URI base64 contains invalid character")
            any(<(0), quartet) && error("glTF data URI base64 has data after padding")
            push!(quartet, v)
        end
        if length(quartet) == 4
            quartet[1] >= 0 && quartet[2] >= 0 ||
                error("glTF data URI base64 has invalid padding")
            if quartet[3] < 0
                quartet[4] < 0 || error("glTF data URI base64 has invalid padding")
                (quartet[2] & 0x0f) == 0 ||
                    error("glTF data URI base64 has non-zero padding bits")
                push!(out, UInt8((quartet[1] << 2) | (quartet[2] >> 4)))
                done = true
            elseif quartet[4] < 0
                (quartet[3] & 0x03) == 0 ||
                    error("glTF data URI base64 has non-zero padding bits")
                push!(out, UInt8((quartet[1] << 2) | (quartet[2] >> 4)))
                push!(out, UInt8(((quartet[2] & 0x0f) << 4) | (quartet[3] >> 2)))
                done = true
            else
                push!(out, UInt8((quartet[1] << 2) | (quartet[2] >> 4)))
                push!(out, UInt8(((quartet[2] & 0x0f) << 4) | (quartet[3] >> 2)))
                push!(out, UInt8(((quartet[3] & 0x03) << 6) | quartet[4]))
            end
            empty!(quartet)
        end
    end
    isempty(quartet) || error("glTF data URI base64 length is not a multiple of 4")
    return out
end

# ========================== glTF 2.0 ==========================

const _GLTF_COMP_SIZE = Dict("SCALAR"=>1, "VEC2"=>2, "VEC3"=>3, "VEC4"=>4, "MAT4"=>16)

struct GLTFAsset
    scene::Scene
    animations::Vector{AnimationClip}
end

function _gltf_uri_without_query_fragment(uri::AbstractString)
    return String(split(split(uri, '#', limit=2)[1], '?', limit=2)[1])
end

function _gltf_uri_hex_value(c::Char)
    '0' <= c <= '9' && return Int(c) - Int('0')
    'a' <= c <= 'f' && return Int(c) - Int('a') + 10
    'A' <= c <= 'F' && return Int(c) - Int('A') + 10
    error("glTF URI has invalid percent escape")
end

function _gltf_percent_decode_uri_path(path::AbstractString)
    bytes = UInt8[]
    i = firstindex(path)
    while i <= lastindex(path)
        c = path[i]
        if c == '%'
            j1 = nextind(path, i)
            j1 <= lastindex(path) || error("glTF URI has incomplete percent escape")
            j2 = nextind(path, j1)
            j2 <= lastindex(path) || error("glTF URI has incomplete percent escape")
            push!(bytes, UInt8((_gltf_uri_hex_value(path[j1]) << 4) |
                               _gltf_uri_hex_value(path[j2])))
            i = nextind(path, j2)
        else
            append!(bytes, codeunits(string(c)))
            i = nextind(path, i)
        end
    end
    try
        return String(bytes)
    catch
        error("glTF URI percent-decoded path is not valid UTF-8")
    end
end

function _gltf_external_resource_path(dir::String, uri::String)
    raw_path = _gltf_uri_without_query_fragment(uri)
    isempty(raw_path) && error("glTF external URI path is empty")
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*):", raw_path)
    if m !== nothing
        scheme = lowercase(String(m.captures[1]))
        scheme == "file" || error("glTF external URI scheme $scheme is not supported")
        path_uri = if startswith(raw_path, "file://")
            rest = lastindex(raw_path) >= 8 ? raw_path[8:end] : ""
            if startswith(rest, "localhost/")
                rest[10:end]
            elseif startswith(rest, "/")
                rest
            elseif isempty(rest)
                ""
            else
                error("glTF file URI authorities are not supported")
            end
        else
            lastindex(raw_path) >= 6 ? raw_path[6:end] : ""
        end
        path = _gltf_percent_decode_uri_path(path_uri)
        isempty(path) && error("glTF external URI path is empty")
        return isabspath(path) ? path : joinpath(dir, path)
    end
    path = _gltf_percent_decode_uri_path(raw_path)
    isempty(path) && error("glTF external URI path is empty")
    return isabspath(path) ? path : joinpath(dir, path)
end

function _gltf_read_buffer(buf::Dict, dir::String)
    uri = get(buf, "uri", nothing)
    uri === nothing && error("glTF buffer without uri; use load_glb for binary .glb containers")
    uri = String(uri)
    data = if startswith(uri, "data:")
        _gltf_data_uri_parts(uri)[2]
    else
        read(_gltf_external_resource_path(dir, uri))
    end
    return _gltf_trim_declared_buffer(buf, data, "glTF buffer")
end

function _gltf_trim_declared_buffer(buf::Dict, data::Vector{UInt8}, label::String)
    declared = get(buf, "byteLength", length(data))
    expected = Int(declared)
    expected >= 0 || error("$label byteLength must be non-negative")
    length(data) >= expected ||
        error("$label byteLength $expected exceeds available bytes $(length(data))")
    return data[1:expected]
end

_gltf_document_buffers(gltf) = get(gltf, "buffers", Any[])

# Read accessor `ai` (0-based) as a vector of Float64 tuples / scalars.
function _gltf_accessor(gltf, buffers, ai::Int)
    acc = gltf["accessors"][ai + 1]
    count = Int(acc["count"])
    ncomp = _GLTF_COMP_SIZE[acc["type"]]
    ctype = Int(acc["componentType"])
    normalized = Bool(get(acc, "normalized", false))
    out = zeros(Float64, count * ncomp)

    compbytes = _gltf_component_bytes(ctype)

    if haskey(acc, "bufferView")
        bv = gltf["bufferViews"][Int(acc["bufferView"]) + 1]
        buf = buffers[Int(bv["buffer"]) + 1]
        offset = Int(get(bv, "byteOffset", 0.0)) + Int(get(acc, "byteOffset", 0.0))
        stride = Int(get(bv, "byteStride", 0.0))   # 0 (or absent) => tightly packed
        stride = stride == 0 ? ncomp * compbytes : stride
        _gltf_read_accessor_payload!(out, buf, offset, count, ncomp, ctype, stride, normalized)
    end

    if haskey(acc, "sparse")
        sparse = acc["sparse"]
        scount = Int(sparse["count"])
        indices_def = sparse["indices"]
        values_def = sparse["values"]
        ibv = gltf["bufferViews"][Int(indices_def["bufferView"]) + 1]
        vbv = gltf["bufferViews"][Int(values_def["bufferView"]) + 1]
        ibuf = buffers[Int(ibv["buffer"]) + 1]
        vbuf = buffers[Int(vbv["buffer"]) + 1]
        ioffset = Int(get(ibv, "byteOffset", 0.0)) + Int(get(indices_def, "byteOffset", 0.0))
        voffset = Int(get(vbv, "byteOffset", 0.0)) + Int(get(values_def, "byteOffset", 0.0))
        ictype = Int(indices_def["componentType"])
        icompbytes = _gltf_component_bytes(ictype)
        vstride = ncomp * compbytes
        tmp = Vector{Float64}(undef, ncomp)
        for s in 0:scount-1
            idx = Int(_gltf_read_component(ibuf, ioffset + s * icompbytes, ictype, false))
            0 <= idx < count || error("glTF sparse accessor index $idx out of bounds")
            _gltf_read_accessor_payload!(tmp, vbuf, voffset + s * vstride, 1, ncomp,
                                         ctype, vstride, normalized)
            copyto!(out, idx * ncomp + 1, tmp, 1, ncomp)
        end
    end
    return (out, ncomp, count)
end

function _gltf_component_bytes(ctype::Int)
    ctype == 5120 && return 1  # BYTE
    ctype == 5121 && return 1  # UNSIGNED_BYTE
    ctype == 5122 && return 2  # SHORT
    ctype == 5123 && return 2  # UNSIGNED_SHORT
    ctype == 5125 && return 4  # UNSIGNED_INT
    ctype == 5126 && return 4  # FLOAT
    error("glTF componentType $ctype")
end

function _gltf_read_component(buf::Vector{UInt8}, offset::Int, ctype::Int, normalized::Bool)
    io = IOBuffer(buf)
    seek(io, offset)
    if ctype == 5126
        return Float64(read(io, Float32))
    elseif ctype == 5125
        v = read(io, UInt32)
        return normalized ? Float64(v) / Float64(typemax(UInt32)) : Float64(v)
    elseif ctype == 5123
        v = read(io, UInt16)
        return normalized ? Float64(v) / Float64(typemax(UInt16)) : Float64(v)
    elseif ctype == 5121
        v = read(io, UInt8)
        return normalized ? Float64(v) / Float64(typemax(UInt8)) : Float64(v)
    elseif ctype == 5122
        v = read(io, Int16)
        return normalized ? max(Float64(v) / Float64(typemax(Int16)), -1.0) : Float64(v)
    elseif ctype == 5120
        v = read(io, Int8)
        return normalized ? max(Float64(v) / Float64(typemax(Int8)), -1.0) : Float64(v)
    end
    error("glTF componentType $ctype")
end

function _gltf_read_accessor_payload!(out::Vector{Float64}, buf::Vector{UInt8}, offset::Int,
                                      count::Int, ncomp::Int, ctype::Int, stride::Int,
                                      normalized::Bool)
    compbytes = _gltf_component_bytes(ctype)
    for e in 0:count-1
        base_offset = offset + e * stride
        base = e * ncomp
        for c in 0:ncomp-1
            out[base + c + 1] = _gltf_read_component(buf, base_offset + c * compbytes,
                                                     ctype, normalized)
        end
    end
    return out
end

_gltf_wrap_mode(v) = Int(v) == 33071 ? :clamp : Int(v) == 33648 ? :mirror : :repeat
_gltf_filter_mode(v) = Int(v) in (9728, 9984, 9986) ? :nearest : :bilinear
_gltf_mag_filter_mode(v) = Int(v) == 9728 ? :nearest : :linear
function _gltf_min_filter_mode(v)
    iv = Int(v)
    iv == 9728 && return :nearest
    iv == 9729 && return :linear
    iv == 9984 && return :nearest_mipmap_nearest
    iv == 9985 && return :linear_mipmap_nearest
    iv == 9986 && return :nearest_mipmap_linear
    iv == 9987 && return :linear_mipmap_linear
    return :linear
end
_gltf_uses_mipmaps(filter::Symbol) =
    filter in (:nearest_mipmap_nearest, :nearest_mipmap_linear,
               :linear_mipmap_nearest, :linear_mipmap_linear)

const _GLTF_SUPPORTED_EXTENSIONS = Set([
    "KHR_lights_punctual",
    "KHR_texture_transform",
    "KHR_materials_unlit",
    "KHR_materials_emissive_strength",
    "KHR_materials_clearcoat",
    "KHR_materials_transmission",
    "KHR_materials_ior",
    "KHR_materials_volume",
    "KHR_materials_sheen",
    "KHR_materials_iridescence",
    "KHR_materials_specular",
    "KHR_materials_pbrSpecularGlossiness",
    "KHR_materials_dispersion",
    "KHR_materials_anisotropy",
    "EXT_mesh_gpu_instancing",
])

function _gltf_check_required_extensions(gltf)
    for ext in get(gltf, "extensionsRequired", Any[])
        name = String(ext)
        name in _GLTF_SUPPORTED_EXTENSIONS ||
            error("glTF requires unsupported extension $name")
    end
    return nothing
end

function _gltf_texture_transform(texinfo)
    ext = get(get(texinfo, "extensions", Dict{String,Any}()),
              "KHR_texture_transform", Dict{String,Any}())
    offset = get(ext, "offset", [0.0, 0.0])
    scale = get(ext, "scale", [1.0, 1.0])
    rotation = Float64(get(ext, "rotation", 0.0))
    tex_coord = Int(get(ext, "texCoord", get(texinfo, "texCoord", 0.0)))
    return (Vec2(Float64(offset[1]), Float64(offset[2])),
            Vec2(Float64(scale[1]), Float64(scale[2])),
            rotation,
            tex_coord)
end

function _gltf_data_uri_parts(uri::String)
    startswith(uri, "data:") || error("glTF data URI must start with data:")
    parts = split(uri, ",", limit=2)
    length(parts) == 2 || error("glTF data URI is missing its comma separator")
    header = String(parts[1])
    meta = lastindex(header) >= 6 ? header[6:end] : ""
    tokens = split(meta, ';')
    mime = isempty(tokens) || isempty(tokens[1]) ? "" : lowercase(String(tokens[1]))
    any(t -> lowercase(String(t)) == "base64", tokens) ||
        error("glTF data URI resources must be base64 encoded")
    return mime, _gltf_base64_decode_strict(parts[2])
end

function _gltf_image_mime_from_uri(uri::String)
    path = _gltf_percent_decode_uri_path(_gltf_uri_without_query_fragment(uri))
    ext = lowercase(splitext(path)[2])
    ext == ".png" && return "image/png"
    (ext == ".jpg" || ext == ".jpeg") && return "image/jpeg"
    ext == ".ktx2" && return "image/ktx2"
    return ""
end

function _gltf_buffer_view_bytes(gltf, buffers, buffer_view_index::Int, label::String)
    bv = gltf["bufferViews"][buffer_view_index + 1]
    buf = buffers[Int(bv["buffer"]) + 1]
    offset = Int(get(bv, "byteOffset", 0.0))
    len = Int(bv["byteLength"])
    offset >= 0 || error("$label byteOffset must be non-negative")
    len >= 0 || error("$label byteLength must be non-negative")
    offset + len <= length(buf) ||
        error("$label byteLength $len at byteOffset $offset exceeds buffer length $(length(buf))")
    return len == 0 ? UInt8[] : buf[(offset + 1):(offset + len)]
end

function _gltf_image_bytes_and_mime(gltf, buffers, dir::String, imgdef)
    declared_mime = haskey(imgdef, "mimeType") ? lowercase(String(imgdef["mimeType"])) : ""
    if haskey(imgdef, "uri")
        uri = String(imgdef["uri"])
        if startswith(uri, "data:")
            data_mime, bytes = _gltf_data_uri_parts(uri)
            return bytes, !isempty(declared_mime) ? declared_mime : data_mime
        end
        bytes = read(_gltf_external_resource_path(dir, uri))
        inferred_mime = _gltf_image_mime_from_uri(uri)
        return bytes, !isempty(declared_mime) ? declared_mime : inferred_mime
    elseif haskey(imgdef, "bufferView")
        bytes = _gltf_buffer_view_bytes(gltf, buffers, Int(imgdef["bufferView"]),
                                        "glTF image bufferView")
        return bytes, declared_mime
    end
    return nothing, ""
end

function _gltf_decode_image(bytes::Vector{UInt8}, mime::AbstractString)
    image_mime = lowercase(strip(String(mime)))
    if image_mime == "" || image_mime == "image/png"
        _is_png_bytes(bytes) ||
            error(image_mime == "" ?
                  "glTF image has unsupported or unknown format; image/png and image/jpeg are supported" :
                  "glTF image MIME image/png does not contain PNG data")
        return _decode_png(bytes)
    elseif image_mime == "image/jpeg" || image_mime == "image/jpg"
        return _decode_jpeg(bytes)
    elseif image_mime == "image/ktx2"
        return _decode_ktx2(bytes)
    end
    error("glTF image MIME $image_mime is not supported; image/png and image/jpeg are supported")
end

function _jpeg_bytes_for_jpegturbo(bytes::Vector{UInt8})
    length(bytes) > 623 && return bytes
    length(bytes) >= 4 &&
        bytes[1] == 0xff && bytes[2] == 0xd8 &&
        bytes[end - 1] == 0xff && bytes[end] == 0xd9 ||
        return bytes
    # JpegTurbo rejects some tiny valid JPEG payloads; a COM segment before EOI
    # preserves the image stream while meeting the decoder's input-size floor.
    payload_len = max(0, 624 - length(bytes) - 4)
    segment_len = payload_len + 2
    segment_len <= typemax(UInt16) ||
        error("JPEG compatibility comment segment is too large")
    padded = UInt8[]
    sizehint!(padded, length(bytes) + payload_len + 4)
    append!(padded, @view bytes[1:end - 2])
    push!(padded, UInt8(0xff), UInt8(0xfe),
          UInt8(segment_len >>> 8), UInt8(segment_len & 0xff))
    append!(padded, zeros(UInt8, payload_len))
    append!(padded, @view bytes[end - 1:end])
    return padded
end

function _decode_jpeg(bytes::Vector{UInt8}; label::AbstractString="glTF image MIME image/jpeg")
    try
        img = jpeg_decode(RGB, _jpeg_bytes_for_jpegturbo(bytes))
        H, W = size(img)
        out = Array{Float64}(undef, H, W, 3)
        @inbounds for y in 1:H, x in 1:W
            px = img[y, x]
            out[y, x, 1] = Float64(red(px))
            out[y, x, 2] = Float64(green(px))
            out[y, x, 3] = Float64(blue(px))
        end
        return out
    catch err
        error("$label could not be decoded: $(sprint(showerror, err))")
    end
end

function _gltf_texture(gltf, buffers, dir::String, texinfo; colorspace::Symbol=:srgb)
    texinfo === nothing && return nothing
    haskey(gltf, "textures") || return nothing
    ti = Int(texinfo["index"])
    texdef = gltf["textures"][ti + 1]
    if !haskey(texdef, "source")
        basisu = get(get(texdef, "extensions", Dict{String,Any}()),
                     "KHR_texture_basisu", nothing)
        basisu === nothing && return nothing
        haskey(basisu, "source") ||
            error("glTF KHR_texture_basisu texture requires a source image index")
        error("glTF KHR_texture_basisu textures are not supported; KTX2/Basis texture loading is not implemented")
    end
    imgdef = gltf["images"][Int(texdef["source"]) + 1]
    bytes, mime = _gltf_image_bytes_and_mime(gltf, buffers, dir, imgdef)
    bytes === nothing && return nothing
    data = _gltf_decode_image(bytes, mime)
    # glTF UV (0,0) is the TOP-left corner, but the engine samples with a
    # bottom-left origin (the 1-v flip in `sample_texture`). Reverse the rows so
    # raw glTF UVs sample correctly — the flipY=false equivalent of three.js
    # GLTFLoader. KHR_texture_transform stays correct because
    # `texture_transform_uv` runs on the untouched glTF-space UVs.
    data = data[end:-1:1, :, :]
    sampler = haskey(texdef, "sampler") && haskey(gltf, "samplers") ?
              gltf["samplers"][Int(texdef["sampler"]) + 1] : Dict{String,Any}()
    offset, scale, rotation, tex_coord = _gltf_texture_transform(texinfo)
    min_filter = _gltf_min_filter_mode(get(sampler, "minFilter",
                                           get(sampler, "magFilter", 9729.0)))
    mag_filter = _gltf_mag_filter_mode(get(sampler, "magFilter", 9729.0))
    tex = Texture(data;
                  wrap_s=_gltf_wrap_mode(get(sampler, "wrapS", 10497.0)),
                  wrap_t=_gltf_wrap_mode(get(sampler, "wrapT", 10497.0)),
                  filter=_gltf_filter_mode(get(sampler, "magFilter",
                                               get(sampler, "minFilter", 9729.0))),
                  min_filter=min_filter,
                  mag_filter=mag_filter,
                  colorspace=colorspace,
                  offset=offset,
                  repeat=scale,
                  rotation=rotation,
                  tex_coord=tex_coord)
    _gltf_uses_mipmaps(min_filter) && generate_mipmaps!(tex)
    return tex
end

function _gltf_material(gltf, buffers, dir::String, mi)
    mi === nothing && return MeshStandardMaterial()
    m = gltf["materials"][Int(mi) + 1]
    pbr = get(m, "pbrMetallicRoughness", Dict{String,Any}())
    extensions = get(m, "extensions", Dict{String,Any}())
    bc = get(pbr, "baseColorFactor", [1.0,1.0,1.0,1.0])
    emissive = get(m, "emissiveFactor", [0.0,0.0,0.0])
    alpha_mode = String(get(m, "alphaMode", "OPAQUE"))
    alpha_test = alpha_mode == "MASK" ? Float64(get(m, "alphaCutoff", 0.5)) : 0.0
    # OPAQUE ignores the alpha value entirely (spec); only BLEND alpha-blends.
    opacity = (alpha_mode == "BLEND" || alpha_mode == "MASK") ? Float64(bc[4]) : 1.0
    transparent = alpha_mode == "BLEND"
    side = Bool(get(m, "doubleSided", false)) ? :double : :front
    base_color_texture = _gltf_texture(gltf, buffers, dir, get(pbr, "baseColorTexture", nothing);
                                       colorspace=:srgb)
    if haskey(extensions, "KHR_materials_unlit")
        return MeshBasicMaterial(color=Color3(bc[1], bc[2], bc[3]),
                                  opacity=opacity,
                                  transparent=transparent,
                                  side=side,
                                  map=base_color_texture,
                                  alpha_test=alpha_test)
    end
    normal_info = get(m, "normalTexture", nothing)
    normal_scale = normal_info isa AbstractDict ? Float64(get(normal_info, "scale", 1.0)) : 1.0
    occ = get(m, "occlusionTexture", nothing)
    emissive_strength = Float64(get(get(extensions, "KHR_materials_emissive_strength",
                                        Dict{String,Any}()), "emissiveStrength", 1.0))
    ao_strength = occ isa AbstractDict ? Float64(get(occ, "strength", 1.0)) : 1.0
    if haskey(extensions, "KHR_materials_pbrSpecularGlossiness")
        specgloss_ext = get(extensions, "KHR_materials_pbrSpecularGlossiness", Dict{String,Any}())
        diffuse = get(specgloss_ext, "diffuseFactor", [1.0, 1.0, 1.0, 1.0])
        specular = get(specgloss_ext, "specularFactor", [1.0, 1.0, 1.0])
        glossiness = Float64(get(specgloss_ext, "glossinessFactor", 1.0))
        diffuse_texture = _gltf_texture(gltf, buffers, dir,
                                        get(specgloss_ext, "diffuseTexture", nothing);
                                        colorspace=:srgb)
        specgloss_texture = _gltf_texture(gltf, buffers, dir,
                                          get(specgloss_ext, "specularGlossinessTexture", nothing);
                                          colorspace=:srgb)
        specgloss_opacity = (alpha_mode == "BLEND" || alpha_mode == "MASK") ?
                            Float64(diffuse[4]) : 1.0
        return MeshPhongMaterial(color=Color3(diffuse[1], diffuse[2], diffuse[3]),
                                 specular=Color3(specular[1], specular[2], specular[3]),
                                 emissive=Color3(emissive[1], emissive[2], emissive[3]),
                                 shininess=_phong_shininess_from_glossiness(glossiness),
                                 glossiness=glossiness,
                                 opacity=specgloss_opacity,
                                 transparent=transparent,
                                 alpha_test=alpha_test,
                                 side=side,
                                 map=diffuse_texture,
                                 specular_map=specgloss_texture,
                                 glossiness_map=specgloss_texture,
                                 normal_map=_gltf_texture(gltf, buffers, dir, normal_info;
                                                          colorspace=:linear),
                                 normal_scale=normal_scale,
                                 ao_map=_gltf_texture(gltf, buffers, dir, occ;
                                                      colorspace=:linear),
                                 emissive_map=_gltf_texture(gltf, buffers, dir, get(m, "emissiveTexture", nothing);
                                                            colorspace=:srgb),
                                 emissive_intensity=emissive_strength,
                                 ao_map_intensity=ao_strength)
    end
    metallic_roughness_texture = _gltf_texture(gltf, buffers, dir,
                                               get(pbr, "metallicRoughnessTexture", nothing);
                                               colorspace=:linear)
    physical_extension_keys = ("KHR_materials_clearcoat",
                               "KHR_materials_transmission",
                               "KHR_materials_ior",
                               "KHR_materials_volume",
                               "KHR_materials_sheen",
                               "KHR_materials_iridescence",
                               "KHR_materials_specular",
                               "KHR_materials_dispersion",
                               "KHR_materials_anisotropy")
    if any(k -> haskey(extensions, k), physical_extension_keys)
        clearcoat_ext = get(extensions, "KHR_materials_clearcoat", Dict{String,Any}())
        transmission_ext = get(extensions, "KHR_materials_transmission", Dict{String,Any}())
        ior_ext = get(extensions, "KHR_materials_ior", Dict{String,Any}())
        volume_ext = get(extensions, "KHR_materials_volume", Dict{String,Any}())
        sheen_ext = get(extensions, "KHR_materials_sheen", Dict{String,Any}())
        iridescence_ext = get(extensions, "KHR_materials_iridescence", Dict{String,Any}())
        specular_ext = get(extensions, "KHR_materials_specular", Dict{String,Any}())
        dispersion_ext = get(extensions, "KHR_materials_dispersion", Dict{String,Any}())
        anisotropy_ext = get(extensions, "KHR_materials_anisotropy", Dict{String,Any}())
        clearcoat_normal_info = get(clearcoat_ext, "clearcoatNormalTexture", nothing)
        clearcoat_normal_scale = clearcoat_normal_info isa AbstractDict ?
                                 Float64(get(clearcoat_normal_info, "scale", 1.0)) : 1.0
        sheen_color_factor = get(sheen_ext, "sheenColorFactor", [0.0, 0.0, 0.0])
        attenuation_color = get(volume_ext, "attenuationColor", [1.0, 1.0, 1.0])
        specular_color_factor = get(specular_ext, "specularColorFactor", [1.0, 1.0, 1.0])
        thickness_min = Float64(get(iridescence_ext, "iridescenceThicknessMinimum", 100.0))
        thickness_max = Float64(get(iridescence_ext, "iridescenceThicknessMaximum", 400.0))
        return MeshPhysicalMaterial(color=Color3(bc[1], bc[2], bc[3]),
                                    emissive=Color3(emissive[1], emissive[2], emissive[3]),
                                    metalness=Float64(get(pbr, "metallicFactor", 1.0)),
                                    roughness=Float64(get(pbr, "roughnessFactor", 1.0)),
                                     opacity=opacity,
                                     transparent=transparent,
                                     alpha_test=alpha_test,
                                     side=side,
                                     map=base_color_texture,
                                     normal_map=_gltf_texture(gltf, buffers, dir, normal_info;
                                                              colorspace=:linear),
                                     normal_scale=normal_scale,
                                     roughness_map=metallic_roughness_texture,
                                    metalness_map=metallic_roughness_texture,
                                    ao_map=_gltf_texture(gltf, buffers, dir, occ;
                                                         colorspace=:linear),
                                    emissive_map=_gltf_texture(gltf, buffers, dir, get(m, "emissiveTexture", nothing);
                                                               colorspace=:srgb),
                                    emissive_intensity=emissive_strength,
                                    ao_map_intensity=ao_strength,
                                    clearcoat=Float64(get(clearcoat_ext, "clearcoatFactor", 0.0)),
                                    clearcoat_roughness=Float64(get(clearcoat_ext, "clearcoatRoughnessFactor", 0.0)),
                                    clearcoat_map=_gltf_texture(gltf, buffers, dir, get(clearcoat_ext, "clearcoatTexture", nothing);
                                                                colorspace=:linear),
                                    clearcoat_roughness_map=_gltf_texture(gltf, buffers, dir, get(clearcoat_ext, "clearcoatRoughnessTexture", nothing);
                                                                          colorspace=:linear),
                                    clearcoat_normal_map=_gltf_texture(gltf, buffers, dir, clearcoat_normal_info;
                                                                       colorspace=:linear),
                                    clearcoat_normal_scale=clearcoat_normal_scale,
                                    transmission=Float64(get(transmission_ext, "transmissionFactor", 0.0)),
                                    transmission_map=_gltf_texture(gltf, buffers, dir, get(transmission_ext, "transmissionTexture", nothing);
                                                                   colorspace=:linear),
                                    thickness=Float64(get(volume_ext, "thicknessFactor", 0.0)),
                                    thickness_map=_gltf_texture(gltf, buffers, dir, get(volume_ext, "thicknessTexture", nothing);
                                                                colorspace=:linear),
                                    attenuation_distance=Float64(get(volume_ext, "attenuationDistance", 0.0)),
                                    attenuation_color=Color3(attenuation_color[1],
                                                             attenuation_color[2],
                                                             attenuation_color[3]),
                                    ior=Float64(get(ior_ext, "ior", 1.5)),
                                    sheen=maximum(Float64.(sheen_color_factor)),
                                    sheen_color=Color3(sheen_color_factor[1],
                                                       sheen_color_factor[2],
                                                       sheen_color_factor[3]),
                                    sheen_roughness=Float64(get(sheen_ext, "sheenRoughnessFactor", 0.0)),
                                    sheen_color_map=_gltf_texture(gltf, buffers, dir, get(sheen_ext, "sheenColorTexture", nothing);
                                                                  colorspace=:srgb),
                                    sheen_roughness_map=_gltf_texture(gltf, buffers, dir, get(sheen_ext, "sheenRoughnessTexture", nothing);
                                                                      colorspace=:linear),
                                    iridescence=Float64(get(iridescence_ext, "iridescenceFactor", 0.0)),
                                    iridescence_ior=Float64(get(iridescence_ext, "iridescenceIor", 1.3)),
                                    iridescence_thickness=0.5 * (thickness_min + thickness_max),
                                    iridescence_map=_gltf_texture(gltf, buffers, dir, get(iridescence_ext, "iridescenceTexture", nothing);
                                                                  colorspace=:linear),
                                    iridescence_thickness_map=_gltf_texture(gltf, buffers, dir, get(iridescence_ext, "iridescenceThicknessTexture", nothing);
                                                                            colorspace=:linear),
                                    specular_intensity=Float64(get(specular_ext, "specularFactor", 1.0)),
                                    specular_color=Color3(specular_color_factor[1],
                                                          specular_color_factor[2],
                                                          specular_color_factor[3]),
                                    specular_intensity_map=_gltf_texture(gltf, buffers, dir, get(specular_ext, "specularTexture", nothing);
                                                                         colorspace=:linear),
                                    specular_color_map=_gltf_texture(gltf, buffers, dir, get(specular_ext, "specularColorTexture", nothing);
                                                                     colorspace=:srgb),
                                    dispersion=Float64(get(dispersion_ext, "dispersion", 0.0)),
                                    anisotropy=Float64(get(anisotropy_ext, "anisotropyStrength", 0.0)),
                                    anisotropy_rotation=Float64(get(anisotropy_ext, "anisotropyRotation", 0.0)),
                                    anisotropy_map=_gltf_texture(gltf, buffers, dir, get(anisotropy_ext, "anisotropyTexture", nothing);
                                                                 colorspace=:linear))
    end
    MeshStandardMaterial(color=Color3(bc[1], bc[2], bc[3]),
                         emissive=Color3(emissive[1], emissive[2], emissive[3]),
                         metalness=Float64(get(pbr, "metallicFactor", 1.0)),
                         roughness=Float64(get(pbr, "roughnessFactor", 1.0)),
                          opacity=opacity,
                          transparent=transparent,
                          alpha_test=alpha_test,
                          side=side,
                          map=base_color_texture,
                          normal_map=_gltf_texture(gltf, buffers, dir, normal_info;
                                                   colorspace=:linear),
                          normal_scale=normal_scale,
                          roughness_map=metallic_roughness_texture,
                         metalness_map=metallic_roughness_texture,
                         ao_map=_gltf_texture(gltf, buffers, dir, occ;
                                              colorspace=:linear),
                         emissive_map=_gltf_texture(gltf, buffers, dir, get(m, "emissiveTexture", nothing);
                                                    colorspace=:srgb),
                         emissive_intensity=emissive_strength,
                         ao_map_intensity=ao_strength)
end

_gltf_material_color(mat) =
    hasproperty(mat, :color) ? getproperty(mat, :color) : Color3(1.0, 1.0, 1.0)
_gltf_material_opacity(mat) =
    hasproperty(mat, :opacity) ? Float64(getproperty(mat, :opacity)) : 1.0
_gltf_material_transparent(mat) =
    hasproperty(mat, :transparent) ? Bool(getproperty(mat, :transparent)) :
    _gltf_material_opacity(mat) < 1.0
_gltf_material_depth_test(mat) =
    hasproperty(mat, :depth_test) ? Bool(getproperty(mat, :depth_test)) : true
_gltf_material_depth_write(mat) =
    hasproperty(mat, :depth_write) ? Bool(getproperty(mat, :depth_write)) : true
_gltf_material_map(mat) =
    hasproperty(mat, :map) ? getproperty(mat, :map) : nothing
_gltf_material_alpha_map(mat) =
    hasproperty(mat, :alpha_map) ? getproperty(mat, :alpha_map) : nothing
_gltf_material_alpha_test(mat) =
    hasproperty(mat, :alpha_test) ? Float64(getproperty(mat, :alpha_test)) : 0.0

function _gltf_line_material(mat)
    LineBasicMaterial(color=_gltf_material_color(mat),
                      opacity=_gltf_material_opacity(mat),
                      depth_test=_gltf_material_depth_test(mat),
                      depth_write=_gltf_material_depth_write(mat))
end

function _gltf_points_material(mat)
    PointsMaterial(color=_gltf_material_color(mat),
                   opacity=_gltf_material_opacity(mat),
                   transparent=_gltf_material_transparent(mat),
                   map=_gltf_material_map(mat),
                   alpha_map=_gltf_material_alpha_map(mat),
                   alpha_test=_gltf_material_alpha_test(mat),
                   depth_test=_gltf_material_depth_test(mat),
                   depth_write=_gltf_material_depth_write(mat))
end

_gltf_enable_vertex_colors(mat::AbstractMaterial) = mat
function _gltf_enable_vertex_colors(m::MeshBasicMaterial)
    MeshBasicMaterial(color=m.color, opacity=m.opacity, transparent=m.transparent,
                      wireframe=m.wireframe, side=m.side, map=m.map, alpha_map=m.alpha_map,
                      vertex_colors=true, alpha_test=m.alpha_test,
                      depth_test=m.depth_test, depth_write=m.depth_write)
end
function _gltf_enable_vertex_colors(m::MeshPhongMaterial)
    MeshPhongMaterial(color=m.color, specular=m.specular, emissive=m.emissive,
                      shininess=m.shininess, glossiness=m.glossiness,
                      opacity=m.opacity, transparent=m.transparent,
                      wireframe=m.wireframe, side=m.side, map=m.map,
                      specular_map=m.specular_map,
                      glossiness_map=m.glossiness_map,
                      normal_map=m.normal_map, normal_scale=m.normal_scale,
                      alpha_map=m.alpha_map, ao_map=m.ao_map,
                      emissive_map=m.emissive_map, light_map=m.light_map,
                      vertex_colors=true, alpha_test=m.alpha_test,
                      clipping_planes=m.clipping_planes,
                      emissive_intensity=m.emissive_intensity,
                      ao_map_intensity=m.ao_map_intensity,
                      light_map_intensity=m.light_map_intensity,
                      depth_test=m.depth_test, depth_write=m.depth_write)
end
function _gltf_enable_vertex_colors(m::MeshStandardMaterial)
    MeshStandardMaterial(color=m.color, emissive=m.emissive, metalness=m.metalness,
                         roughness=m.roughness, opacity=m.opacity,
                         transparent=m.transparent, side=m.side, map=m.map,
                         normal_map=m.normal_map, normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         alpha_map=m.alpha_map, ao_map=m.ao_map,
                         emissive_map=m.emissive_map, vertex_colors=true,
                         alpha_test=m.alpha_test, envmap=m.envmap, light_map=m.light_map,
                         emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         depth_test=m.depth_test, depth_write=m.depth_write)
end
function _gltf_enable_vertex_colors(m::MeshPhysicalMaterial)
    MeshPhysicalMaterial(color=m.color, emissive=m.emissive, metalness=m.metalness,
                         roughness=m.roughness, clearcoat=m.clearcoat,
                         clearcoat_roughness=m.clearcoat_roughness,
                         transmission=m.transmission, ior=m.ior, opacity=m.opacity,
                         transparent=m.transparent, side=m.side, envmap=m.envmap,
                         map=m.map, normal_map=m.normal_map, normal_scale=m.normal_scale,
                         roughness_map=m.roughness_map, metalness_map=m.metalness_map,
                         ao_map=m.ao_map, emissive_map=m.emissive_map, alpha_map=m.alpha_map,
                         emissive_intensity=m.emissive_intensity,
                         ao_map_intensity=m.ao_map_intensity,
                         light_map_intensity=m.light_map_intensity,
                         env_map_intensity=m.env_map_intensity,
                         alpha_test=m.alpha_test, sheen=m.sheen,
                         sheen_color=m.sheen_color, sheen_roughness=m.sheen_roughness,
                         iridescence=m.iridescence, iridescence_ior=m.iridescence_ior,
                         iridescence_thickness=m.iridescence_thickness,
                         light_map=m.light_map, clearcoat_map=m.clearcoat_map,
                         clearcoat_roughness_map=m.clearcoat_roughness_map,
                         transmission_map=m.transmission_map, thickness=m.thickness,
                         thickness_map=m.thickness_map,
                         attenuation_distance=m.attenuation_distance,
                         attenuation_color=m.attenuation_color,
                         sheen_color_map=m.sheen_color_map,
                         sheen_roughness_map=m.sheen_roughness_map,
                         iridescence_map=m.iridescence_map,
                         iridescence_thickness_map=m.iridescence_thickness_map,
                         specular_intensity=m.specular_intensity,
                         specular_color=m.specular_color,
                         specular_intensity_map=m.specular_intensity_map,
                         specular_color_map=m.specular_color_map,
                         vertex_colors=true,
                         clearcoat_normal_map=m.clearcoat_normal_map,
                         clearcoat_normal_scale=m.clearcoat_normal_scale,
                         dispersion=m.dispersion,
                         anisotropy=m.anisotropy,
                         anisotropy_rotation=m.anisotropy_rotation,
                         anisotropy_map=m.anisotropy_map,
                         depth_test=m.depth_test, depth_write=m.depth_write)
end

function _gltf_triangulate_indices(order::Vector{Int}, mode::Int)
    out = Int[]
    length(order) < 3 && return out
    if mode == 5
        sizehint!(out, 3 * (length(order) - 2))
        for i in 1:(length(order) - 2)
            a, b, c = order[i], order[i + 1], order[i + 2]
            isodd(i) ? append!(out, (a, b, c)) : append!(out, (c, b, a))
        end
    elseif mode == 6
        sizehint!(out, 3 * (length(order) - 2))
        first_index = order[1]
        for i in 2:(length(order) - 1)
            append!(out, (first_index, order[i], order[i + 1]))
        end
    else
        error("glTF primitive mode $mode is not a triangle strip or fan")
    end
    return out
end

function _gltf_expand_attribute(data::AbstractVector, item_size::Int,
                                order::Vector{Int}, nverts::Int, label::String)
    item_size > 0 || error("$label item_size must be positive")
    length(data) >= nverts * item_size ||
        error("$label count does not match POSITION")
    out = Vector{eltype(data)}(undef, length(order) * item_size)
    @inbounds for (oi, vi) in enumerate(order)
        1 <= vi <= nverts || error("glTF primitive index $(vi - 1) out of bounds")
        dst = (oi - 1) * item_size + 1
        src = (vi - 1) * item_size + 1
        for j in 0:(item_size - 1)
            out[dst + j] = data[src + j]
        end
    end
    return out
end

function _gltf_expand_nontriangle_geometry(geo::BufferGeometry, order::Vector{Int})
    nverts = geo.n_vertices
    positions = _gltf_expand_attribute(geo.positions, 3, order, nverts, "glTF POSITION")
    normals = isempty(geo.normals) ? Float64[] :
              _gltf_expand_attribute(geo.normals, 3, order, nverts, "glTF NORMAL")
    uvs = isempty(geo.uvs) ? Float64[] :
          _gltf_expand_attribute(geo.uvs, 2, order, nverts, "glTF TEXCOORD_0")
    attrs = Dict{Symbol, BufferAttribute}()
    for (name, attr) in geo.attributes
        attrs[name] = BufferAttribute(
            _gltf_expand_attribute(attr.data, attr.item_size, order, nverts, String(name)),
            attr.item_size)
    end
    return BufferGeometry(positions, normals, uvs, Int[], length(order), 0, attrs)
end

function _gltf_node_matrix(node)
    if haskey(node, "matrix")
        m = node["matrix"]
        return Mat4{Float64}(ntuple(k -> Float64(m[k]), 16))
    end
    t = get(node, "translation", [0.0,0.0,0.0])
    r = get(node, "rotation", [0.0,0.0,0.0,1.0])
    s = get(node, "scale", [1.0,1.0,1.0])
    T = mat4_translation(t[1], t[2], t[3])
    R = quat_to_mat4(Quaternion(r[1], r[2], r[3], r[4]))
    S = mat4_scaling(s[1], s[2], s[3])
    return T * R * S
end

function _gltf_instance_attribute(gltf, buffers, attrs, name::String, ncomp::Int)
    haskey(attrs, name) || return nothing
    data, item_size, count = _gltf_accessor(gltf, buffers, Int(attrs[name]))
    item_size == ncomp || error("EXT_mesh_gpu_instancing $name accessor must be $(ncomp == 3 ? "VEC3" : "VEC4")")
    return data, count
end

function _gltf_instance_matrices(gltf, buffers, node)
    ext = get(get(node, "extensions", Dict{String,Any}()),
              "EXT_mesh_gpu_instancing", nothing)
    ext === nothing && return nothing
    attrs = get(ext, "attributes", nothing)
    attrs isa AbstractDict || error("EXT_mesh_gpu_instancing requires an attributes object")
    isempty(attrs) && error("EXT_mesh_gpu_instancing attributes must not be empty")
    translation = _gltf_instance_attribute(gltf, buffers, attrs, "TRANSLATION", 3)
    rotation = _gltf_instance_attribute(gltf, buffers, attrs, "ROTATION", 4)
    scale = _gltf_instance_attribute(gltf, buffers, attrs, "SCALE", 3)
    counts = Int[]
    translation !== nothing && push!(counts, translation[2])
    rotation !== nothing && push!(counts, rotation[2])
    scale !== nothing && push!(counts, scale[2])
    isempty(counts) && error("EXT_mesh_gpu_instancing must define TRANSLATION, ROTATION, or SCALE")
    all(==(counts[1]), counts) ||
        error("EXT_mesh_gpu_instancing attribute accessors must have matching counts")
    count = counts[1]
    matrices = Vector{Mat4{Float64}}(undef, count)
    for i in 1:count
        ti = translation === nothing ? (0.0, 0.0, 0.0) :
             (translation[1][3i - 2], translation[1][3i - 1], translation[1][3i])
        ri = rotation === nothing ? (0.0, 0.0, 0.0, 1.0) :
             (rotation[1][4i - 3], rotation[1][4i - 2],
              rotation[1][4i - 1], rotation[1][4i])
        si = scale === nothing ? (1.0, 1.0, 1.0) :
             (scale[1][3i - 2], scale[1][3i - 1], scale[1][3i])
        q = quat_normalize(Quaternion(ri[1], ri[2], ri[3], ri[4]))
        matrices[i] = mat4_translation(ti[1], ti[2], ti[3]) *
                      quat_to_mat4(q) *
                      mat4_scaling(si[1], si[2], si[3])
    end
    return matrices
end

# Decompose a column-major TRS matrix `M` into (position, rotation::Euler{:XYZ},
# scale), matching three.js `Matrix4.decompose` + `Euler.setFromRotationMatrix`
# (order XYZ). Returned components recompose as T*R*S exactly as
# `compute_local_matrix`.
function _gltf_decompose(M::Mat4)
    position = Vec3(mat4_get(M,1,4), mat4_get(M,2,4), mat4_get(M,3,4))
    # Column vectors of the upper-left 3x3.
    c1 = Vec3(mat4_get(M,1,1), mat4_get(M,2,1), mat4_get(M,3,1))
    c2 = Vec3(mat4_get(M,1,2), mat4_get(M,2,2), mat4_get(M,3,2))
    c3 = Vec3(mat4_get(M,1,3), mat4_get(M,2,3), mat4_get(M,3,3))
    sx = norm(c1); sy = norm(c2); sz = norm(c3)
    # Negative determinant means a reflected basis; three.js folds the sign into sx
    # only (NOT the column): dividing the original column by the now-negative sx
    # below yields a proper rotation whose recomposition T*R*S reproduces M. Also
    # negating c1 here would cancel that and silently drop the reflection.
    det = dot(c1, cross(c2, c3))
    if det < 0
        sx = -sx
    end
    # Pure-rotation columns (guard against zero scale).
    isx = sx == 0 ? zero(sx) : one(sx)/sx
    isy = sy == 0 ? zero(sy) : one(sy)/sy
    isz = sz == 0 ? zero(sz) : one(sz)/sz
    r1 = c1 * isx; r2 = c2 * isy; r3 = c3 * isz
    # R indexed [row, col]: column r1 -> (R11,R21,R31), r2 -> (R12,R22,R32),
    # r3 -> (R13,R23,R33).
    R11 = r1.x
    R12 = r2.x; R22 = r2.y; R32 = r2.z
    R13 = r3.x; R23 = r3.y; R33 = r3.z
    _y = asin(clamp(R13, -one(R13), one(R13)))
    if abs(R13) < 0.9999999
        _x = atan(-R23, R33)
        _z = atan(-R12, R11)
    else
        _x = atan(R32, R22)
        _z = zero(R13)
    end
    return (position, Euler(_x, _y, _z, :XYZ), Vec3(sx, sy, sz))
end

function _gltf_transform_direction(M::Mat4, v::Vec3)
    o = mat4_transform_point(M, Vec3(0.0, 0.0, 0.0))
    p = mat4_transform_point(M, v)
    d = p - o
    n = norm(d)
    return n > 0 ? d / n : v
end

function _gltf_color3(v)
    Color3(Float64(v[1]), Float64(v[2]), Float64(v[3]))
end

function _gltf_camera(gltf, camera_idx::Int, name::String, M::Mat4)
    camdef = gltf["cameras"][camera_idx + 1]
    typ = String(camdef["type"])
    cam = if typ == "perspective"
        p = camdef["perspective"]
        PerspectiveCamera(fov=Float64(p["yfov"]),
                          aspect=Float64(get(p, "aspectRatio", 1.0)),
                          near=Float64(p["znear"]),
                          far=Float64(get(p, "zfar", 1000.0)),
                          name=name)
    elseif typ == "orthographic"
        o = camdef["orthographic"]
        xmag = Float64(o["xmag"])
        ymag = Float64(o["ymag"])
        # xmag/ymag are HALF extents (spec: P[0][0] = 1/xmag, P[1][1] = 1/ymag).
        OrthographicCamera(left=-xmag, right=xmag,
                           bottom=-ymag, top=ymag,
                           near=Float64(o["znear"]),
                           far=Float64(o["zfar"]),
                           name=name)
    else
        error("unsupported glTF camera type: $typ")
    end
    pos, rot, scl = _gltf_decompose(M)
    cam.position = pos
    cam.rotation = rot
    cam.scale = scl
    cam.target = pos + _gltf_transform_direction(M, Vec3(0.0, 0.0, -1.0))
    cam.up = _gltf_transform_direction(M, Vec3(0.0, 1.0, 0.0))
    return cam
end

function _gltf_punctual_lights(gltf)
    ext = get(gltf, "extensions", Dict{String,Any}())
    lights_ext = get(ext, "KHR_lights_punctual", nothing)
    lights_ext === nothing && return Any[]
    return get(lights_ext, "lights", Any[])
end

function _gltf_node_light(gltf, light_idx::Int, name::String, M::Mat4)
    lights = _gltf_punctual_lights(gltf)
    ldef = lights[light_idx + 1]
    typ = String(ldef["type"])
    color = _gltf_color3(get(ldef, "color", [1.0, 1.0, 1.0]))
    intensity = Float64(get(ldef, "intensity", 1.0))
    pos, rot, scl = _gltf_decompose(M)
    light = if typ == "directional"
        DirectionalLight(color=color, intensity=intensity, position=pos, name=name)
    elseif typ == "point"
        PointLight(color=color, intensity=intensity,
                   distance=Float64(get(ldef, "range", 0.0)),
                   position=pos, name=name)
    elseif typ == "spot"
        spot = get(ldef, "spot", Dict{String,Any}())
        outer = Float64(get(spot, "outerConeAngle", pi/4))
        inner = Float64(get(spot, "innerConeAngle", 0.0))
        penumbra = outer > 0 ? clamp(1.0 - inner / outer, 0.0, 1.0) : 0.0
        SpotLight(color=color, intensity=intensity,
                  distance=Float64(get(ldef, "range", 0.0)),
                  angle=outer, penumbra=penumbra,
                  position=pos, name=name)
    else
        error("unsupported glTF punctual light type: $typ")
    end
    light.rotation = rot
    light.scale = scl
    if light isa DirectionalLight || light isa SpotLight
        light.target = pos + _gltf_transform_direction(M, Vec3(0.0, 0.0, -1.0))
    end
    return light
end

function _gltf_checked_node_index(raw, node_count::Int, label::String)
    idx = Int(raw)
    0 <= idx < node_count || error("glTF $label node index $idx out of bounds")
    return idx
end

function _gltf_skin_node_sets(gltf)
    joint_nodes = Set{Int}()
    skin_root_nodes = Set{Int}()
    node_count = length(get(gltf, "nodes", Any[]))
    for skin in get(gltf, "skins", Any[])
        skin_joints = Set{Int}()
        for j in get(skin, "joints", Any[])
            idx = _gltf_checked_node_index(j, node_count, "skin joint")
            idx in skin_joints && error("glTF skin joints must be unique")
            push!(skin_joints, idx)
            push!(joint_nodes, idx)
        end
        if haskey(skin, "skeleton")
            push!(skin_root_nodes,
                  _gltf_checked_node_index(skin["skeleton"], node_count, "skin.skeleton"))
        end
    end
    return joint_nodes, skin_root_nodes
end

function _gltf_skin_tuples(geo::BufferGeometry, name::Symbol, nverts::Int; indices::Bool=false)
    has_attribute(geo, name) || error("glTF skinned mesh is missing $name")
    attr = get_attribute(geo, name)
    attr.item_size == 4 || error("glTF $name accessor must be VEC4")
    length(attr.data) == nverts * 4 || error("glTF $name count does not match POSITION")
    if indices
        return [ntuple(k -> Int(round(attr.data[4i - 4 + k])) + 1, 4) for i in 1:nverts]
    end
    tuples = NTuple{4,Float64}[]
    sizehint!(tuples, nverts)
    for i in 1:nverts
        w = ntuple(k -> Float64(attr.data[4i - 4 + k]), 4)
        s = sum(w)
        push!(tuples, s > 0 ? ntuple(k -> w[k] / s, 4) : w)
    end
    return tuples
end

function _gltf_inverse_bind_matrices(gltf, buffers, skin, joint_count::Int)
    haskey(skin, "inverseBindMatrices") || return nothing
    data, ncomp, count = _gltf_accessor(gltf, buffers, Int(skin["inverseBindMatrices"]))
    ncomp == 16 || error("glTF inverseBindMatrices accessor must be MAT4")
    count == joint_count || error("glTF inverseBindMatrices count must match joints")
    return [Mat4{Float64}(ntuple(k -> data[(i - 1) * 16 + k], 16)) for i in 1:count]
end

# Build a `Scene` from a parsed glTF document and its decoded buffers. Shared by
# `load_gltf` (text/embedded buffers) and `load_glb` (binary container, where
# the BIN chunk is supplied as buffer 0). `buffers` must already contain the raw
# bytes for every buffer referenced by the document.
function _gltf_build_scene(gltf, buffers; return_nodes::Bool=false, dir::String="")
    _gltf_check_required_extensions(gltf)
    scene = Scene()
    node_objects = Dict{Int, AbstractObject3D}()
    joint_nodes, skin_root_nodes = _gltf_skin_node_sets(gltf)
    morph_animated_nodes = Set{Int}()
    for anim in get(gltf, "animations", Any[]), ch in get(anim, "channels", Any[])
        target = get(ch, "target", Dict{String,Any}())
        get(target, "path", "") == "weights" && haskey(target, "node") &&
            push!(morph_animated_nodes, Int(target["node"]))
    end
    pending_skin_binds = SkinnedMesh[]
    pending_inverse_calcs = SkinnedMesh[]

    function _gltf_target_names(mesh_def)
        extras = get(mesh_def, "extras", Dict{String,Any}())
        names = get(extras, "targetNames", String[])
        return [String(name) for name in names]
    end

    function _gltf_instanced_draw_mode(obj)
        obj isa Mesh && return :triangles
        obj isa PointsObject && return :points
        obj isa LineSegments && return :lines
        obj isa LineLoop && return :line_loop
        obj isa LineObject && return :line_strip
        error("EXT_mesh_gpu_instancing only supports mesh, point, and line primitives")
    end

    function _gltf_bake_static_morphs!(geo::BufferGeometry,
                                       morph_weights::Vector{Float64})
        isempty(morph_weights) && return geo
        for (ti, weight) in enumerate(morph_weights)
            weight == 0.0 && continue
            pos_name = Symbol("morphPosition$(ti - 1)")
            if has_attribute(geo, pos_name)
                attr = get_attribute(geo, pos_name)
                attr.item_size == 3 && length(attr.data) == length(geo.positions) ||
                    error("glTF morph target POSITION count does not match primitive positions")
                @inbounds for i in eachindex(geo.positions)
                    geo.positions[i] += weight * attr.data[i]
                end
            end
            nrm_name = Symbol("morphNormal$(ti - 1)")
            if !isempty(geo.normals) && has_attribute(geo, nrm_name)
                attr = get_attribute(geo, nrm_name)
                attr.item_size == 3 && length(attr.data) == length(geo.normals) ||
                    error("glTF morph target NORMAL count does not match primitive normals")
                @inbounds for i in eachindex(geo.normals)
                    geo.normals[i] += weight * attr.data[i]
                end
            end
        end
        return geo
    end

    function build_primitive(prim, skin_idx=nothing, morph_weights=Float64[],
                             morph_names=String[]; preserve_nontriangle_morphs::Bool=false)
        mode = Int(get(prim, "mode", 4))
        0 <= mode <= 6 || error("unsupported glTF primitive mode $mode")
        skin_idx === nothing || mode in (4, 5, 6) ||
            error("glTF primitive mode $mode cannot be loaded as SkinnedMesh")
        attrs = prim["attributes"]
        pos, _, nverts = _gltf_accessor(gltf, buffers, Int(attrs["POSITION"]))
        normals = Float64[]
        if haskey(attrs, "NORMAL")
            normals, _, _ = _gltf_accessor(gltf, buffers, Int(attrs["NORMAL"]))
        end
        uvs = Float64[]
        if haskey(attrs, "TEXCOORD_0")
            uvs, uvcomp, _ = _gltf_accessor(gltf, buffers, Int(attrs["TEXCOORD_0"]))
            uvcomp == 2 || error("glTF TEXCOORD_0 accessor must be VEC2")
        end
        if haskey(prim, "indices")
            idxf, _, _ = _gltf_accessor(gltf, buffers, Int(prim["indices"]))
            indices = Int.(round.(idxf)) .+ 1
        else
            indices = collect(1:nverts)
        end
        tri_indices = mode == 5 || mode == 6 ? _gltf_triangulate_indices(indices, mode) : indices
        geo_indices = mode in (0, 1, 2, 3) ? Int[] : tri_indices
        geo = BufferGeometry(pos, normals, uvs, geo_indices, nverts,
                             mode in (0, 1, 2, 3) ? 0 : length(geo_indices) ÷ 3)
        for (gltf_name, local_name) in (
            ("TEXCOORD_1", :uv2),
            ("COLOR_0", :color),
            ("TANGENT", :tangent),
            ("JOINTS_0", :skinIndex),
            ("WEIGHTS_0", :skinWeight),
        )
            haskey(attrs, gltf_name) || continue
            data, item_size, attr_count = _gltf_accessor(gltf, buffers, Int(attrs[gltf_name]))
            attr_count == nverts || error("glTF $gltf_name count does not match POSITION")
            set_attribute!(geo, local_name, data, item_size)
        end
        for (ti, target) in enumerate(get(prim, "targets", Any[]))
            for (gltf_name, local_prefix) in (
                ("POSITION", "morphPosition"),
                ("NORMAL", "morphNormal"),
                ("TANGENT", "morphTangent"),
            )
                haskey(target, gltf_name) || continue
                data, item_size, attr_count = _gltf_accessor(gltf, buffers, Int(target[gltf_name]))
                attr_count == nverts || error("glTF morph target $gltf_name count does not match POSITION")
                set_attribute!(geo, Symbol(local_prefix * string(ti - 1)), data, item_size)
            end
        end
        if mode in (0, 1, 2, 3)
            geo = _gltf_expand_nontriangle_geometry(geo, indices)
            preserve_nontriangle_morphs || _gltf_bake_static_morphs!(geo, morph_weights)
        elseif isempty(normals)
            compute_vertex_normals!(geo)
        end
        mat = _gltf_material(gltf, buffers, dir, get(prim, "material", nothing))
        has_attribute(geo, :color) && (mat = _gltf_enable_vertex_colors(mat))
        nontriangle_weights = preserve_nontriangle_morphs ? morph_weights : Float64[]
        nontriangle_names = preserve_nontriangle_morphs ? morph_names : String[]
        mode == 0 && return PointsObject(geo, _gltf_points_material(mat);
                                         morph_target_influences=nontriangle_weights,
                                         morph_target_names=nontriangle_names)
        mode == 1 && return LineSegments(geo, _gltf_line_material(mat);
                                         morph_target_influences=nontriangle_weights,
                                         morph_target_names=nontriangle_names)
        mode == 2 && return LineLoop(geo, _gltf_line_material(mat);
                                     morph_target_influences=nontriangle_weights,
                                     morph_target_names=nontriangle_names)
        mode == 3 && return LineObject(geo, _gltf_line_material(mat);
                                       morph_target_influences=nontriangle_weights,
                                       morph_target_names=nontriangle_names)
        if skin_idx === nothing
            return Mesh(geo, mat; morph_target_influences=morph_weights,
                        morph_target_names=morph_names)
        end
        skin = gltf["skins"][Int(skin_idx) + 1]
        bones = Bone[]
        for j in skin["joints"]
            bone = node_objects[Int(j)]
            bone isa Bone || error("glTF skin joint node was not loaded as a Bone")
            push!(bones, bone)
        end
        inv = _gltf_inverse_bind_matrices(gltf, buffers, skin, length(bones))
        skeleton = inv === nothing ? Skeleton(bones, fill(Mat4(), length(bones))) : Skeleton(bones, inv)
        skin_indices = _gltf_skin_tuples(geo, :skinIndex, nverts; indices=true)
        skin_weights = _gltf_skin_tuples(geo, :skinWeight, nverts)
        sm = SkinnedMesh(geo, mat, skeleton, skin_indices, skin_weights;
                         morph_target_influences=morph_weights,
                         morph_target_names=morph_names)
        push!(pending_skin_binds, sm)
        inv === nothing && push!(pending_inverse_calcs, sm)
        return sm
    end

    function create_node_object!(node_idx)
        node = gltf["nodes"][node_idx + 1]
        M = _gltf_node_matrix(node)
        node_name = String(get(node, "name", "node_$node_idx"))
        obj = if haskey(node, "camera")
            _gltf_camera(gltf, Int(node["camera"]), node_name, M)
        elseif haskey(node, "extensions") &&
               haskey(node["extensions"], "KHR_lights_punctual") &&
               haskey(node["extensions"]["KHR_lights_punctual"], "light")
            light_idx = Int(node["extensions"]["KHR_lights_punctual"]["light"])
            _gltf_node_light(gltf, light_idx, node_name, M)
        elseif node_idx in joint_nodes
            Bone(name=node_name)
        else
            Group()
        end
        pos, rot, scl = _gltf_decompose(M)   # full TRS, not just translation
        obj.position = pos
        obj.rotation = rot
        obj.scale = scl
        obj.name = node_name
        node_objects[node_idx] = obj
    end

    for node_idx in 0:(length(get(gltf, "nodes", Any[])) - 1)
        create_node_object!(node_idx)
    end

    scene_linked_nodes = Set{Int}()

    function add_node!(parent, node_idx)
        push!(scene_linked_nodes, node_idx)
        node = gltf["nodes"][node_idx + 1]
        obj = node_objects[node_idx]
        add!(parent, obj)
        instance_matrices = _gltf_instance_matrices(gltf, buffers, node)
        instance_matrices !== nothing && !haskey(node, "mesh") &&
            error("EXT_mesh_gpu_instancing can only be used on glTF mesh nodes")
        if haskey(node, "mesh")
            instance_matrices !== nothing && haskey(node, "skin") &&
                error("EXT_mesh_gpu_instancing with skinned meshes is not supported")
            mesh_def = gltf["meshes"][Int(node["mesh"]) + 1]
            morph_weights = Float64.(get(node, "weights", get(mesh_def, "weights", Float64[])))
            morph_names = _gltf_target_names(mesh_def)
            for prim in mesh_def["primitives"]
                if instance_matrices !== nothing
                    (isempty(get(prim, "targets", Any[])) && isempty(morph_weights)) ||
                        error("EXT_mesh_gpu_instancing with morph targets is not supported")
                end
                mesh_obj = build_primitive(
                    prim, get(node, "skin", nothing), morph_weights, morph_names;
                    preserve_nontriangle_morphs=(node_idx in morph_animated_nodes))
                if instance_matrices === nothing
                    add!(obj, mesh_obj)
                else
                    draw_mode = _gltf_instanced_draw_mode(mesh_obj)
                    inst = InstancedMesh(mesh_obj.geometry, mesh_obj.material,
                                         length(instance_matrices);
                                         name=mesh_obj.name,
                                         cast_shadow=object_casts_shadow(mesh_obj),
                                         receive_shadow=object_receives_shadow(mesh_obj),
                                         draw_mode=draw_mode)
                    inst.instance_matrices = copy(instance_matrices)
                    add!(obj, inst)
                end
            end
        end
        for child in get(node, "children", Any[])
            add_node!(obj, Int(child))
        end
    end

    function link_node_hierarchy!(node_idx)
        node = gltf["nodes"][node_idx + 1]
        obj = node_objects[node_idx]
        for child in get(node, "children", Any[])
            child_idx = Int(child)
            child_obj = node_objects[child_idx]
            add!(obj, child_obj)
            link_node_hierarchy!(child_idx)
        end
    end

    scene_def = gltf["scenes"][Int(get(gltf, "scene", 0.0)) + 1]
    for n in scene_def["nodes"]
        add_node!(scene, Int(n))
    end
    for root_idx in skin_root_nodes
        root_idx in scene_linked_nodes || link_node_hierarchy!(root_idx)
    end
    for sm in pending_inverse_calcs
        calculate_inverses!(sm.skeleton)
    end
    for sm in pending_skin_binds
        bind_skeleton!(sm, sm.skeleton, compute_world_matrix(sm);
                       bind_mode=:attached, calculate_inverses=false)
    end
    return return_nodes ? (scene, node_objects) : scene
end

function _gltf_track_values(data::Vector{Float64}, ncomp::Int, count::Int, path::String)
    if path == "rotation"
        ncomp == 4 || error("glTF rotation animation accessor must be VEC4")
        return [quat_normalize(Quaternion(data[4i-3], data[4i-2], data[4i-1], data[4i])) for i in 1:count]
    elseif path == "translation" || path == "scale"
        ncomp == 3 || error("glTF $path animation accessor must be VEC3")
        return [Vec3(data[3i-2], data[3i-1], data[3i]) for i in 1:count]
    else
        return nothing
    end
end

function _gltf_weight_values(data::Vector{Float64}, ncomp::Int, key_count::Int)
    ncomp == 1 || error("glTF weights animation accessor must be SCALAR")
    # The SCALAR output holds key_count * n_targets values; derive the
    # per-keyframe target count from the data length.
    targets = key_count > 0 ? length(data) ÷ key_count : 0
    (targets >= 1 && length(data) == key_count * targets) ||
        error("glTF weights animation input/output keyframe counts differ")
    return [collect(@view data[(i - 1) * targets + 1:i * targets]) for i in 1:key_count]
end

function _gltf_cubic_weight_values(data::Vector{Float64}, ncomp::Int, key_count::Int)
    ncomp == 1 || error("glTF CUBICSPLINE weights animation accessor must be SCALAR")
    # Per keyframe the layout is: in-tangents for all targets, then values,
    # then out-tangents. Derive the target count from the data length.
    targets = key_count > 0 ? length(data) ÷ (3 * key_count) : 0
    (targets >= 1 && length(data) == key_count * 3 * targets) ||
        error("glTF CUBICSPLINE weights output count must be 3x input count")
    ins = Vector{Float64}[]
    vals = Vector{Float64}[]
    outs = Vector{Float64}[]
    sizehint!(ins, key_count); sizehint!(vals, key_count); sizehint!(outs, key_count)
    for i in 1:key_count
        base = (i - 1) * 3 * targets
        push!(ins, collect(@view data[base + 1:base + targets]))
        push!(vals, collect(@view data[base + targets + 1:base + 2targets]))
        push!(outs, collect(@view data[base + 2targets + 1:base + 3targets]))
    end
    return ins, vals, outs
end

function _gltf_cubic_vec3_values(data::Vector{Float64}, ncomp::Int, key_count::Int, path::String)
    ncomp == 3 || error("glTF CUBICSPLINE $path animation accessor must be VEC3")
    length(data) == key_count * 3 * ncomp || error("glTF CUBICSPLINE output count must be 3x input count")
    ins = Vec3{Float64}[]; vals = Vec3{Float64}[]; outs = Vec3{Float64}[]
    sizehint!(ins, key_count); sizehint!(vals, key_count); sizehint!(outs, key_count)
    for i in 1:key_count
        base = (i - 1) * 9
        push!(ins, Vec3(data[base+1], data[base+2], data[base+3]))
        push!(vals, Vec3(data[base+4], data[base+5], data[base+6]))
        push!(outs, Vec3(data[base+7], data[base+8], data[base+9]))
    end
    return ins, vals, outs
end

function _gltf_cubic_quat_values(data::Vector{Float64}, ncomp::Int, key_count::Int)
    ncomp == 4 || error("glTF CUBICSPLINE rotation animation accessor must be VEC4")
    length(data) == key_count * 3 * ncomp || error("glTF CUBICSPLINE output count must be 3x input count")
    ins = Quaternion{Float64}[]; vals = Quaternion{Float64}[]; outs = Quaternion{Float64}[]
    sizehint!(ins, key_count); sizehint!(vals, key_count); sizehint!(outs, key_count)
    for i in 1:key_count
        base = (i - 1) * 12
        push!(ins, Quaternion(data[base+1], data[base+2], data[base+3], data[base+4]))
        push!(vals, quat_normalize(Quaternion(data[base+5], data[base+6], data[base+7], data[base+8])))
        push!(outs, Quaternion(data[base+9], data[base+10], data[base+11], data[base+12]))
    end
    return ins, vals, outs
end

function _gltf_animation_clips(gltf, buffers, node_objects)
    haskey(gltf, "animations") || return AnimationClip[]
    clips = AnimationClip[]
    for (ai, anim) in enumerate(gltf["animations"])
        samplers = anim["samplers"]
        channels = get(anim, "channels", Any[])
        tracks = AbstractKeyframeTrack[]
        for ch in channels
            target = ch["target"]
            haskey(target, "node") || continue
            node_idx = Int(target["node"])
            haskey(node_objects, node_idx) || continue
            path = String(target["path"])
            path in ("translation", "rotation", "scale", "weights") || continue
            sampler = samplers[Int(ch["sampler"]) + 1]
            interpolation = Symbol(lowercase(String(get(sampler, "interpolation", "LINEAR"))))
            times, tncomp, tcount = _gltf_accessor(gltf, buffers, Int(sampler["input"]))
            tncomp == 1 || error("glTF animation input accessor must be SCALAR")
            out, ncomp, count = _gltf_accessor(gltf, buffers, Int(sampler["output"]))
            obj = node_objects[node_idx]
            if path == "weights"
                if interpolation === :cubicspline
                    ins, vals, outs = _gltf_cubic_weight_values(out, ncomp, tcount)
                    push!(tracks, CubicSplineMorphWeightsKeyframeTrack(
                        obj, :morph_target_influences, times, vals, ins, outs))
                    continue
                end
                vals = _gltf_weight_values(out, ncomp, tcount)
                push!(tracks, MorphWeightsKeyframeTrack(obj, :morph_target_influences,
                                                        times, vals; interpolation=interpolation))
                continue
            end
            if interpolation === :cubicspline
                if path == "rotation"
                    ins, vals, outs = _gltf_cubic_quat_values(out, ncomp, tcount)
                    push!(tracks, CubicSplineQuaternionKeyframeTrack(obj, :rotation, times, vals, ins, outs))
                else
                    ins, vals, outs = _gltf_cubic_vec3_values(out, ncomp, tcount, path)
                    prop = path == "translation" ? :position : :scale
                    push!(tracks, CubicSplineKeyframeTrack(obj, prop, times, vals, ins, outs))
                end
                continue
            end
            vals = _gltf_track_values(out, ncomp, count, path)
            vals === nothing && continue
            length(times) == length(vals) || error("glTF animation input/output keyframe counts differ")
            if path == "rotation"
                qinterp = interpolation === :step ? :step : :slerp
                push!(tracks, QuaternionKeyframeTrack(obj, :rotation, times, vals;
                                                      interpolation=qinterp))
            else
                prop = path == "translation" ? :position : :scale
                push!(tracks, KeyframeTrack(obj, prop, times, vals; interpolation=interpolation))
            end
        end
        name = String(get(anim, "name", "animation_$ai"))
        push!(clips, AnimationClip(name, tracks))
    end
    return clips
end

function _gltf_build_asset(gltf, buffers; dir::String="")
    scene, node_objects = _gltf_build_scene(gltf, buffers; return_nodes=true, dir=dir)
    return GLTFAsset(scene, _gltf_animation_clips(gltf, buffers, node_objects))
end

"""
    load_gltf(path) -> Scene

Load a text glTF 2.0 file into a `Scene`.

Supports data-URI and external buffers, node transforms, cameras, punctual
lights, mesh primitives, basic PBR metallic-roughness materials, skin binding,
morph targets, and texture references supported by Diff3D's built-in loaders.
Use [`load_glb`](@ref) for binary `.glb` containers whose first buffer is stored
in the GLB BIN chunk.
"""
function load_gltf(path::String)
    gltf = _json_parse(read(path, String))
    _gltf_check_required_extensions(gltf)
    dir = dirname(path)
    buffers = [_gltf_read_buffer(b, dir) for b in _gltf_document_buffers(gltf)]
    return _gltf_build_scene(gltf, buffers; dir=dir)
end

"""
    load_gltf_asset(path) -> GLTFAsset

Load a glTF 2.0 file and return both the scene and parsed animation clips.
Node `translation`, `rotation`, and `scale` channels are mapped to Diff3D.jl
`KeyframeTrack` / `QuaternionKeyframeTrack` objects targeting the loaded scene
nodes, and `weights` channels drive morph-target influences. Use
[`load_glb_asset`](@ref) for binary `.glb` containers.
"""
function load_gltf_asset(path::String)
    gltf = _json_parse(read(path, String))
    _gltf_check_required_extensions(gltf)
    dir = dirname(path)
    buffers = [_gltf_read_buffer(b, dir) for b in _gltf_document_buffers(gltf)]
    return _gltf_build_asset(gltf, buffers; dir=dir)
end

# Resolve a glTF buffer that may reference the GLB binary chunk. A buffer with no
# `uri` is the embedded GLB binary buffer (buffer 0 by spec); otherwise behave
# exactly like `_gltf_read_buffer`.
function _glb_read_buffer(buf::Dict, dir::String, bin::Vector{UInt8})
    uri = get(buf, "uri", nothing)
    uri !== nothing && (uri = String(uri))
    data = if uri === nothing
        bin
    elseif startswith(uri, "data:")
        _gltf_data_uri_parts(uri)[2]
    else
        read(_gltf_external_resource_path(dir, uri))
    end
    label = uri === nothing ? "GLB BIN chunk" : "glTF buffer"
    return _gltf_trim_declared_buffer(buf, data, label)
end

@inline _rd_le32(b, i) = Int(b[i]) | (Int(b[i+1]) << 8) | (Int(b[i+2]) << 16) | (Int(b[i+3]) << 24)

function _parse_glb(path::String)
    bytes = read(path)
    length(bytes) >= 12 || error("GLB file too short")
    # 12-byte header: magic, version, total length (all little-endian uint32).
    magic = _rd_le32(bytes, 1)
    magic == 0x46546C67 || error("not a GLB file (bad magic)")   # 'glTF' little-endian
    version = _rd_le32(bytes, 5)
    version == 2 || error("unsupported GLB version $version")
    total = _rd_le32(bytes, 9)
    total == length(bytes) ||
        error("GLB declared length $total does not match file length $(length(bytes))")

    json_bytes = UInt8[]
    bin_bytes = UInt8[]
    have_json = false
    have_bin = false
    pos = 13                                                     # first chunk header
    while pos <= total
        pos + 7 <= total || error("GLB chunk header exceeds file bounds")
        clen = _rd_le32(bytes, pos)
        clen % 4 == 0 || error("GLB chunk length $clen is not 4-byte aligned")
        ctype = _rd_le32(bytes, pos + 4)
        dstart = pos + 8
        dend = dstart + clen - 1
        dend <= total || error("GLB chunk exceeds file bounds")
        if ctype == 0x4E4F534A          # 'JSON'
            !have_json || error("GLB has multiple JSON chunks")
            json_bytes = bytes[dstart:dend]
            have_json = true
        elseif ctype == 0x004E4942      # 'BIN\0'
            !have_bin || error("GLB has multiple BIN chunks")
            bin_bytes = bytes[dstart:dend]
            have_bin = true
        end
        pos = dend + 1
    end
    have_json || error("GLB has no JSON chunk")

    gltf = _json_parse(String(json_bytes))
    _gltf_check_required_extensions(gltf)
    dir = dirname(path)
    buffers = [_glb_read_buffer(b, dir, bin_bytes) for b in _gltf_document_buffers(gltf)]
    return gltf, buffers, dir
end

"""
    load_glb(path) -> Scene

Load a binary glTF (`.glb`) container into a `Scene`. Parses the 12-byte header
(magic `glTF`, version, total length) and the chunk list, extracts the JSON
chunk (type `0x4E4F534A`) and the optional binary chunk (type `0x004E4942`),
then reuses the glTF document logic. A buffer view without a `uri` reads from
the embedded binary chunk (buffer 0). Mirrors [`load_gltf`](@ref) output.
"""
function load_glb(path::String)
    gltf, buffers, dir = _parse_glb(path)
    return _gltf_build_scene(gltf, buffers; dir=dir)
end

"""Load a binary glTF (`.glb`) and return both scene and animation clips."""
function load_glb_asset(path::String)
    gltf, buffers, dir = _parse_glb(path)
    return _gltf_build_asset(gltf, buffers; dir=dir)
end
