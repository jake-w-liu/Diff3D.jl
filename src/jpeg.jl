# Pure-Julia JPEG decoder.
#
# Decodes 8-bit Huffman JPEG streams (SOF0 baseline, SOF1 extended sequential,
# SOF2 progressive) into an H x W x 3 UInt8 RGB array.  The implementation
# mirrors the libjpeg-turbo 3.2.0 decoder pipeline bit-exactly for the inputs
# its default configuration accepts: the integer "islow" IDCT (jidctint.c),
# fancy triangle-filter upsampling for 2x1/1x2/2x2 chroma ratios and box
# upsampling for other integral ratios (jdsample.c), integer YCbCr->RGB
# conversion (jdcolor.c), and progressive inter-block smoothing (jdcoefct.c).
# Truncated or corrupt entropy data is a hard error rather than a partially
# gray image.

const _JPEG_MAX_DIMENSION = 65500

# Arithmetic guards mirroring the PNG decoder's checked integer helpers
# (defined in loaders_extra.jl, included after this file at load time).

# zigzag coefficient index -> natural (row-major) position; indexes 65..80 are
# the guard entries libjpeg keeps for out-of-range runs in corrupt streams.
const _JPEG_NATURAL_ORDER = let o = (
        0,  1,  8, 16,  9,  2,  3, 10,
       17, 24, 32, 25, 18, 11,  4,  5,
       12, 19, 26, 33, 40, 48, 41, 34,
       27, 20, 13,  6,  7, 14, 21, 28,
       35, 42, 49, 56, 57, 50, 43, 36,
       29, 22, 15, 23, 30, 37, 44, 51,
       58, 59, 52, 45, 38, 31, 39, 46,
       53, 60, 61, 54, 47, 55, 62, 63)
    ntuple(i -> Int32(i <= 64 ? o[i] : 63), 80)
end

# Post-IDCT range-limit table (jdmaster.c prepare_range_limit_table): a
# descaled IDCT value masked with RANGE_MASK = 1023 indexes this table.
const _JPEG_RANGE_LIMIT = ntuple(1024) do i
    j = i - 1
    if j <= 127
        UInt8(j + 128)
    elseif j <= 511
        UInt8(255)
    elseif j <= 895
        UInt8(0)
    else
        UInt8(j - 896)
    end
end

# Float64 values identical to Float64(reinterpret(N0f8, v)) for every v: the
# Normed -> Float64 conversion reduces to the correctly-rounded division v/255,
# which equals the stored value for all 256 inputs.
const _JPEG_N0F8_TO_FLOAT64 = ntuple(i -> (i - 1) / 255.0, 256)

mutable struct _JpegComponent
    id::Int32
    h::Int32                       # horizontal sampling factor
    v::Int32                       # vertical sampling factor
    tq::Int32                      # quantization table selector
    dc_tbl::Int32                  # DC Huffman selector (current scan)
    ac_tbl::Int32                  # AC Huffman selector (current scan)
    width_in_blocks::Int
    height_in_blocks::Int
    downsampled_width::Int
    downsampled_height::Int
    MCU_width::Int
    MCU_height::Int
    last_col_width::Int
    last_row_height::Int
    quant_table::Union{Nothing,Vector{Int32}}   # latched at first scan
    coefs::Array{Int16,3}          # (64, padded width blocks, padded height blocks)
end

struct _JpegHuffTbl
    maxcode::Vector{Int32}         # [l] largest code of length l, -1 if none
    valoffset::Vector{Int32}
    huffval::Vector{UInt8}
    lookup::Vector{Int32}          # 512-entry lookahead: (len << 8) | symbol
end

mutable struct _JpegState
    data::Vector{UInt8}
    pos::Int                       # next byte offset for marker-level input
    epos::Int                      # next entropy-data byte offset
    bitbuf::UInt64                 # buffered bits, right-justified
    nbits::Int                     # number of valid bits in bitbuf
    unread_marker::Int32           # marker code reached by the bit reader, else 0
    W::Int
    H::Int
    ncomp::Int
    progressive::Bool
    streaming::Bool                # sequential single-scan band pipeline
    nscans::Int
    comps::Vector{_JpegComponent}
    max_h::Int32
    max_v::Int32
    total_imcu_rows::Int
    restart_interval::Int
    qt::Vector{Union{Nothing,Vector{Int32}}}              # 4, natural order
    dcht::Vector{Union{Nothing,_JpegHuffTbl}}
    acht::Vector{Union{Nothing,_JpegHuffTbl}}
    saw_JFIF::Bool
    saw_Adobe::Bool
    Adobe_transform::Int32
    saw_SOF::Bool
    input_scan_number::Int
    coef_bits::Array{Int8,2}       # (64, ncomp): -1 or current Al per coef
    prev_coef_bits::Array{Int8,2}  # (64, ncomp): state before the current scan
    # per-scan state
    scan_comps::Vector{Int}
    Ss::Int
    Se::Int
    Ah::Int
    Al::Int
    MCUs_per_row::Int
    blocks_in_MCU::Int
    MCU_membership::Vector{Int8}   # scan-component index (0-based) per block
    MCU_blk_col::Vector{Int32}     # block column within the MCU
    MCU_blk_row::Vector{Int32}     # block row within the MCU
    scan_dc::Vector{_JpegHuffTbl}  # derived DC table per MCU block
    scan_ac::Vector{_JpegHuffTbl}  # derived AC table per MCU block
    restarts_to_go::Int
    next_restart_num::Int
    eobrun::Int
    last_dc::Vector{Int32}         # DC prediction per scan-component index
end

function _JpegState(data::Vector{UInt8})
    _JpegState(data, 1, 1, UInt64(0), 0, Int32(0),
               0, 0, 0, false, false, 0, _JpegComponent[], Int32(1), Int32(1), 0, 0,
               Union{Nothing,Vector{Int32}}[nothing, nothing, nothing, nothing],
               Union{Nothing,_JpegHuffTbl}[nothing, nothing, nothing, nothing],
               Union{Nothing,_JpegHuffTbl}[nothing, nothing, nothing, nothing],
               false, false, Int32(0), false, 0,
               zeros(Int8, 64, 0), zeros(Int8, 64, 0),
               Int[], 0, 0, 0, 0, 0, 0, Int8[], Int32[], Int32[],
               _JpegHuffTbl[], _JpegHuffTbl[],
               0, 0, 0, Int32[])
end

# ------------------------------ marker-level input --------------------------

@inline function _jpeg_u8(st::_JpegState)
    st.pos > length(st.data) && error("JPEG data is truncated")
    b = st.data[st.pos]
    st.pos += 1
    return Int32(b)
end

@inline function _jpeg_u16(st::_JpegState)
    st.pos + 1 <= length(st.data) || error("JPEG data is truncated")
    v = (Int32(st.data[st.pos]) << 8) | Int32(st.data[st.pos + 1])
    st.pos += 2
    return v
end

# Read a 16-bit segment length field, minus the two length bytes themselves.
@inline function _jpeg_seglen(st::_JpegState, what::AbstractString)
    len = Int(_jpeg_u16(st)) - 2
    len < 0 && error("JPEG $what segment has an invalid length")
    return len
end

function _jpeg_skip(st::_JpegState, n::Int)
    n < 0 && error("JPEG segment has an invalid length")
    st.pos + n <= length(st.data) + 1 || error("JPEG data is truncated")
    st.pos += n
    return nothing
end

# next_marker: scan forward to a 0xFF byte, swallow repeated 0xFF fill bytes,
# then return the following byte.  Extraneous garbage bytes are skipped, and a
# stuffed 0xFF00 pair does not end the search.
function _jpeg_next_marker(st::_JpegState, from_entropy::Bool)
    data = st.data
    len = length(data)
    p = from_entropy ? st.epos : st.pos
    while true
        p > len && error("JPEG data is truncated; no marker found")
        data[p] == 0xFF && break
        p += 1
    end
    while true
        p += 1
        p > len && error("JPEG data is truncated; no marker found")
        data[p] != 0xFF && break
    end
    c = data[p]
    p += 1
    if from_entropy
        st.epos = p
    else
        st.pos = p
    end
    c == 0x00 && return _jpeg_next_marker(st, from_entropy)
    return Int32(c)
end

# ------------------------------ entropy bit reader --------------------------

# Pull one entropy byte, undoing 0xFF00 stuffing and stopping at markers.
# Returns the byte, or -1 once a marker has been reached (unread_marker set)
# or the data runs out.
@inline function _jpeg_entropy_byte(st::_JpegState)
    data = st.data
    p = st.epos
    p > length(data) && return Int32(-1)
    c = data[p]
    if c == 0xFF
        p += 1
        while p <= length(data) && data[p] == 0xFF
            p += 1
        end
        if p > length(data)
            st.epos = p
            return Int32(-1)
        end
        nxt = data[p]
        if nxt != 0x00
            st.epos = p + 1
            st.unread_marker = Int32(nxt)
            return Int32(-1)
        end
        st.epos = p + 1
        return Int32(0xFF)
    end
    st.epos = p + 1
    return Int32(c)
end

# Load 8 bytes from data starting at p (1-based) as a big-endian UInt64 when
# none of them is 0xFF; returns (chunk, true) or (0, false).
@inline function _jpeg_clean8(data::Vector{UInt8}, p::Int)
    v = unsafe_load(Ptr{UInt64}(pointer(data, p)))
    x = v ⊻ 0xFFFFFFFFFFFFFFFF
    (x - 0x0101010101010101) & ~x & 0x8080808080808080 != 0 &&
        return UInt64(0), false
    return ntoh(v), true
end

# Ensure at least n bits (n <= 57) are buffered.  libjpeg-turbo stuffs zero
# bits when the terminating marker is reached; this decoder treats running out
# of entropy data as corruption instead.
@inline function _jpeg_need_bits(st::_JpegState, n::Int)
    st.nbits >= n && return nothing
    st.unread_marker == 0 ||
        error("JPEG entropy-coded data is truncated or corrupt")
    buf = st.bitbuf
    left = st.nbits
    data = st.data
    while left < n
        p = st.epos
        if p + 7 <= length(data)
            chunk, clean = _jpeg_clean8(data, p)
            if clean
                # stuffing-free run: take as many whole bytes as fit
                k = min(8, (64 - left) >> 3)
                if k == 8
                    buf = chunk
                    left = 64
                    st.epos = p + 8
                else
                    buf = (buf << (8 * k)) | (chunk >> (64 - 8 * k))
                    left += 8 * k
                    st.epos = p + k
                end
                continue
            end
        end
        b = _jpeg_entropy_byte(st)
        b >= 0 || error("JPEG entropy-coded data is truncated or corrupt")
        buf = (buf << 8) | UInt64(b % UInt8)
        left += 8
    end
    st.bitbuf = buf
    st.nbits = left
    return nothing
end

@inline function _jpeg_take_bits(st::_JpegState, n::Int)
    _jpeg_need_bits(st, n)
    st.nbits -= n
    return Int32((st.bitbuf >> st.nbits) & ((UInt64(1) << n) - UInt64(1)))
end

# ------------------------------ Huffman tables ------------------------------

# jpeg_make_d_derived_tbl (jdhuff.c): build decode tables and validate.
function _jpeg_make_hufftbl(bits::Vector{UInt8}, huffval::Vector{UInt8},
                            isdc::Bool)
    huffsize = Vector{Int32}(undef, 257)
    huffcode = Vector{UInt32}(undef, 257)
    p = 0
    @inbounds for l in 1:16
        i = Int(bits[l + 1])
        p + i > 256 && error("JPEG Huffman table is invalid")
        while i > 0
            p += 1
            huffsize[p] = Int32(l)
            i -= 1
        end
    end
    p += 1
    huffsize[p] = 0
    numsymbols = p - 1
    code = UInt32(0)
    si = huffsize[1]
    p = 1
    @inbounds while huffsize[p] != 0
        while huffsize[p] == si
            huffcode[p] = code
            code += UInt32(1)
            p += 1
        end
        code >= (UInt32(1) << si) && error("JPEG Huffman table is invalid")
        code <<= 1
        si += Int32(1)
    end
    maxcode = fill(Int32(-1), 18)
    valoffset = zeros(Int32, 18)
    p = 1
    @inbounds for l in 1:16
        if bits[l + 1] != 0
            valoffset[l] = Int32(p - 1) - Int32(huffcode[p])
            p += Int(bits[l + 1])
            maxcode[l] = Int32(huffcode[p - 1])
        end
    end
    valoffset[17] = 0
    maxcode[17] = Int32(0x000FFFFF)
    lookup = fill(Int32(10) << 8, 512)
    p = 1
    @inbounds for l in 1:9
        for _ in 1:bits[l + 1]
            lb = Int32(huffcode[p]) << (9 - l)
            for _ in 1:(1 << (9 - l))
                lookup[lb + 1] = (Int32(l) << 8) | Int32(huffval[p])
                lb += 1
            end
            p += 1
        end
    end
    if isdc
        for i in 1:numsymbols
            huffval[i] > 15 && error("JPEG DC Huffman table has a bad symbol")
        end
    end
    return _JpegHuffTbl(maxcode, valoffset, huffval, lookup)
end

# Fill up to n bits without failing at a marker.  Used by the lookahead path,
# where the request is a hint rather than a hard requirement.
@inline function _jpeg_fill_soft(st::_JpegState, n::Int)
    left = st.nbits
    buf = st.bitbuf
    data = st.data
    while left < n && st.unread_marker == 0
        p = st.epos
        if p + 7 <= length(data)
            chunk, clean = _jpeg_clean8(data, p)
            if clean
                k = min(8, (64 - left) >> 3)
                if k == 8
                    buf = chunk
                    left = 64
                    st.epos = p + 8
                else
                    buf = (buf << (8 * k)) | (chunk >> (64 - 8 * k))
                    left += 8 * k
                    st.epos = p + k
                end
                continue
            end
        end
        b = _jpeg_entropy_byte(st)
        b < 0 && break
        buf = (buf << 8) | UInt64(b % UInt8)
        left += 8
    end
    st.bitbuf = buf
    st.nbits = left
    return left
end

# Bit-sequential decode per Figure F.16: the first minl bits are already
# known to be part of the code, then extend one bit at a time.
@inline function _jpeg_huff_slow(st::_JpegState, tbl::_JpegHuffTbl, minl::Int)
    _jpeg_need_bits(st, minl)
    st.nbits -= minl
    code = Int32((st.bitbuf >> st.nbits) & ((UInt64(1) << minl) - UInt64(1)))
    l = minl
    maxcode = tbl.maxcode
    while code > maxcode[l]
        code <<= 1
        _jpeg_need_bits(st, 1)
        st.nbits -= 1
        code |= Int32((st.bitbuf >> st.nbits) & 0x1)
        l += 1
    end
    # l is at most 17: maxcode[17] is the all-ones sentinel.
    l > 16 && error("JPEG Huffman code is invalid")
    return Int32(tbl.huffval[Int(code + tbl.valoffset[l]) + 1])
end

@inline function _jpeg_huff_decode(st::_JpegState, tbl::_JpegHuffTbl)
    if st.nbits < 9
        _jpeg_fill_soft(st, 9)
        st.nbits < 9 && return _jpeg_huff_slow(st, tbl, 1)
    end
    look = Int32((st.bitbuf >> (st.nbits - 9)) & 0x1FF)
    @inbounds nb = tbl.lookup[look + 1]
    nb < (Int32(10) << 8) || return _jpeg_huff_slow(st, tbl, 10)
    st.nbits -= Int(nb >> 8)
    return nb % Int32(256)
end

# extend the sign of an s-bit value (Figure F.12)
@inline function _jpeg_extend(v::Integer, s::Integer)
    v32 = v % Int32
    s32 = s % Int32
    return v32 < (Int32(1) << (s32 - Int32(1))) ?
           v32 + (Int32(-1) << s32) + Int32(1) : v32
end

# ------------------------------ marker handlers -----------------------------

const _JPEG_TEM   = Int32(0x01)
const _JPEG_SOF0  = Int32(0xC0)
const _JPEG_SOF1  = Int32(0xC1)
const _JPEG_SOF2  = Int32(0xC2)
const _JPEG_SOF3  = Int32(0xC3)
const _JPEG_DHT   = Int32(0xC4)
const _JPEG_SOF5  = Int32(0xC5)
const _JPEG_SOF6  = Int32(0xC6)
const _JPEG_SOF7  = Int32(0xC7)
const _JPEG_JPG   = Int32(0xC8)
const _JPEG_SOF9  = Int32(0xC9)
const _JPEG_SOF10 = Int32(0xCA)
const _JPEG_SOF11 = Int32(0xCB)
const _JPEG_DAC   = Int32(0xCC)
const _JPEG_SOF13 = Int32(0xCD)
const _JPEG_SOF14 = Int32(0xCE)
const _JPEG_SOF15 = Int32(0xCF)
const _JPEG_RST0  = Int32(0xD0)
const _JPEG_SOI   = Int32(0xD8)
const _JPEG_EOI   = Int32(0xD9)
const _JPEG_SOS   = Int32(0xDA)
const _JPEG_DQT   = Int32(0xDB)
const _JPEG_DNL   = Int32(0xDC)
const _JPEG_DRI   = Int32(0xDD)
const _JPEG_APP0  = Int32(0xE0)
const _JPEG_APP14 = Int32(0xEE)
const _JPEG_COM   = Int32(0xFE)

function _jpeg_get_sof!(st::_JpegState, marker::Int32)
    if marker == _JPEG_SOF3 || marker == _JPEG_SOF7 || marker == _JPEG_SOF11 ||
       marker == _JPEG_SOF15
        error("JPEG lossless coding (marker 0x$(string(marker; base=16))) is not supported")
    elseif marker == _JPEG_SOF5 || marker == _JPEG_SOF6 ||
           marker == _JPEG_SOF13 || marker == _JPEG_SOF14
        error("JPEG differential coding (marker 0x$(string(marker; base=16))) is not supported")
    elseif marker == _JPEG_SOF9 || marker == _JPEG_SOF10
        error("JPEG arithmetic coding (marker 0x$(string(marker; base=16))) is not supported")
    elseif marker != _JPEG_SOF0 && marker != _JPEG_SOF1 && marker != _JPEG_SOF2
        error("JPEG marker 0x$(string(marker; base=16)) is not supported")
    end
    st.saw_SOF && error("JPEG contains multiple SOF markers")
    len = _jpeg_seglen(st, "SOF")
    precision = _jpeg_u8(st)
    H = Int(_jpeg_u16(st))
    W = Int(_jpeg_u16(st))
    ncomp = Int(_jpeg_u8(st))
    (H <= 0 || W <= 0 || ncomp <= 0) && error("JPEG has empty image dimensions")
    len == ncomp * 3 + 6 || error("JPEG SOF segment has a bad length")
    precision == 8 ||
        error("JPEG data precision $precision is not supported; only 8-bit data is handled")
    st.H = H; st.W = W; st.ncomp = ncomp
    st.progressive = marker == _JPEG_SOF2
    empty!(st.comps)
    for _ in 1:ncomp
        id = _jpeg_u8(st)
        c = _jpeg_u8(st)
        tq = _jpeg_u8(st)
        push!(st.comps, _JpegComponent(id, Int32(c >> 4), Int32(c & 15), tq,
                                       Int32(0), Int32(0), 0, 0, 0, 0,
                                       0, 0, 0, 0, nothing,
                                       zeros(Int16, 0, 0, 0)))
    end
    st.saw_SOF = true
    return nothing
end

function _jpeg_get_sos!(st::_JpegState)
    st.saw_SOF || error("JPEG scan data appears before any SOF marker")
    len = _jpeg_seglen(st, "SOS")
    n = Int(_jpeg_u8(st))
    (len != n * 2 + 4 || n < 1 || n > 4) &&
        error("JPEG SOS segment has a bad length")
    empty!(st.scan_comps)
    for _ in 1:n
        cc = _jpeg_u8(st)
        c = _jpeg_u8(st)
        ci = 0
        for j in 1:min(st.ncomp, 4)
            if st.comps[j].id == cc && !(j in st.scan_comps)
                ci = j
                break
            end
        end
        ci == 0 && error("JPEG SOS references an unknown component $cc")
        comp = st.comps[ci]
        comp.dc_tbl = c >> 4
        comp.ac_tbl = c & 15
        push!(st.scan_comps, ci)
    end
    st.Ss = Int(_jpeg_u8(st))
    st.Se = Int(_jpeg_u8(st))
    c = _jpeg_u8(st)
    st.Ah = Int(c >> 4)
    st.Al = Int(c & 15)
    st.next_restart_num = 0
    st.input_scan_number += 1
    return nothing
end

function _jpeg_get_dqt!(st::_JpegState)
    len = _jpeg_seglen(st, "DQT")
    while len > 0
        n = _jpeg_u8(st)
        prec = n >> 4
        tq = Int(n & 15)
        tq < 4 || error("JPEG DQT index $tq is out of range")
        prec <= 1 || error("JPEG DQT has invalid precision $prec")
        tbl = Vector{Int32}(undef, 64)
        for i in 1:64
            tbl[_JPEG_NATURAL_ORDER[i] + 1] = prec == 0 ? _jpeg_u8(st) : _jpeg_u16(st)
        end
        st.qt[tq + 1] = tbl
        len -= prec == 0 ? 65 : 129
    end
    len == 0 || error("JPEG DQT segment has a bad length")
    return nothing
end

function _jpeg_get_dht!(st::_JpegState)
    len = _jpeg_seglen(st, "DHT")
    while len > 16
        index = _jpeg_u8(st)
        len -= 1
        bits = Vector{UInt8}(undef, 17)
        bits[1] = 0
        count = 0
        for i in 2:17
            b = _jpeg_u8(st)
            bits[i] = UInt8(b)
            count += Int(b)
        end
        len -= 16
        (count > 256 || count > len) && error("JPEG DHT segment is invalid")
        huffval = Vector{UInt8}(undef, 256)
        for i in 1:count
            huffval[i] = UInt8(_jpeg_u8(st))
        end
        fill!(@view(huffval[count + 1:256]), UInt8(0))
        len -= count
        isac = index & 0x10 != 0
        t = Int(index & 0x0F)
        t < 4 || error("JPEG DHT index is out of range")
        tbl = _jpeg_make_hufftbl(bits, huffval, !isac)
        if isac
            st.acht[t + 1] = tbl
        else
            st.dcht[t + 1] = tbl
        end
    end
    len == 0 || error("JPEG DHT segment has a bad length")
    return nothing
end

function _jpeg_get_dri!(st::_JpegState)
    len = _jpeg_seglen(st, "DRI")
    len == 2 || error("JPEG DRI segment has a bad length")
    st.restart_interval = Int(_jpeg_u16(st))
    return nothing
end

function _jpeg_appn!(st::_JpegState, marker::Int32)
    len = _jpeg_seglen(st, "APP$(marker - _JPEG_APP0)")
    toread = min(len, 14)
    base = st.pos
    _jpeg_skip(st, toread)
    if marker == _JPEG_APP0
        if len >= 14 &&
           st.data[base] == 0x4A && st.data[base + 1] == 0x46 &&
           st.data[base + 2] == 0x49 && st.data[base + 3] == 0x46 &&
           st.data[base + 4] == 0x00
            st.saw_JFIF = true
        end
    elseif marker == _JPEG_APP14
        if len >= 12 &&
           st.data[base] == 0x41 && st.data[base + 1] == 0x64 &&
           st.data[base + 2] == 0x6F && st.data[base + 3] == 0x62 &&
           st.data[base + 4] == 0x65
            st.saw_Adobe = true
            st.Adobe_transform = Int32(st.data[base + 11])
        end
    end
    _jpeg_skip(st, len - toread)
    return nothing
end

# initial_setup (jdinput.c): frame geometry, derived when the first SOS
# arrives.
function _jpeg_initial_setup!(st::_JpegState)
    (st.H > _JPEG_MAX_DIMENSION || st.W > _JPEG_MAX_DIMENSION) &&
        error("JPEG image dimensions exceed $(_JPEG_MAX_DIMENSION) pixels")
    _checked_mul_int(st.W, st.H, "JPEG image")
    st.ncomp > 4 && error("JPEG has more than 4 components")
    maxh = Int32(1); maxv = Int32(1)
    for comp in st.comps
        (comp.h < 1 || comp.h > 4 || comp.v < 1 || comp.v > 4) &&
            error("JPEG sampling factors are invalid")
        maxh = max(maxh, comp.h)
        maxv = max(maxv, comp.v)
    end
    st.max_h = maxh; st.max_v = maxv
    total_blocks = 0
    for comp in st.comps
        comp.width_in_blocks = cld(st.W * Int(comp.h), Int(maxh) * 8)
        comp.height_in_blocks = cld(st.H * Int(comp.v), Int(maxv) * 8)
        comp.downsampled_width = cld(st.W * Int(comp.h), Int(maxh))
        comp.downsampled_height = cld(st.H * Int(comp.v), Int(maxv))
        wb = comp.width_in_blocks +
             mod(comp.h - comp.width_in_blocks % comp.h, comp.h)
        hb = comp.height_in_blocks +
             mod(comp.v - comp.height_in_blocks % comp.v, comp.v)
        total_blocks = _checked_add_int(total_blocks,
                                        _checked_mul_int(wb, hb, "JPEG image"),
                                        "JPEG image")
    end
    st.streaming = !st.progressive && st.nscans == 1
    # Fail fast on declared-giant frames before allocating the coefficient
    # planes: the first scan must carry at least one bit of entropy data per
    # block it covers (two bits for sequential scans, where each block at
    # minimum encodes a DC size code and an EOB).  Byte stuffing and markers
    # can only inflate that bound, so fewer remaining bytes than the bound
    # guarantees a truncated stream.
    if length(st.scan_comps) == 1
        comp0 = st.comps[st.scan_comps[1]]
        scan_blocks = comp0.width_in_blocks * comp0.height_in_blocks
    else
        mcus = cld(st.W, Int(maxh) * 8) * cld(st.H, Int(maxv) * 8)
        per_mcu = 0
        for cidx in st.scan_comps
            per_mcu += Int(st.comps[cidx].h) * Int(st.comps[cidx].v)
        end
        scan_blocks = mcus * per_mcu
    end
    minbits = st.progressive ? 1 : 2
    scan_blocks = _checked_mul_int(scan_blocks, minbits, "JPEG image")
    (length(st.data) - st.pos + 1) * 8 < scan_blocks &&
        error("JPEG entropy-coded data is truncated or corrupt")
    st.streaming || for comp in st.comps
        wb = comp.width_in_blocks +
             mod(comp.h - comp.width_in_blocks % comp.h, comp.h)
        hb = comp.height_in_blocks +
             mod(comp.v - comp.height_in_blocks % comp.v, comp.v)
        comp.coefs = zeros(Int16, 64, wb, hb)
    end
    st.total_imcu_rows = cld(st.H, Int(maxv) * 8)
    st.coef_bits = fill(Int8(-1), 64, st.ncomp)
    st.prev_coef_bits = zeros(Int8, 64, st.ncomp)
    return nothing
end

# per_scan_setup (jdinput.c): MCU layout for the upcoming scan.
function _jpeg_per_scan_setup!(st::_JpegState)
    if length(st.scan_comps) == 1
        comp = st.comps[st.scan_comps[1]]
        st.MCUs_per_row = comp.width_in_blocks
        comp.MCU_width = 1
        comp.MCU_height = 1
        comp.last_col_width = 1
        tmp = comp.height_in_blocks % comp.v
        comp.last_row_height = tmp == 0 ? Int(comp.v) : tmp
        st.blocks_in_MCU = 1
        resize!(st.MCU_membership, 1)
        resize!(st.MCU_blk_col, 1)
        resize!(st.MCU_blk_row, 1)
        st.MCU_membership[1] = Int8(0)
        st.MCU_blk_col[1] = Int32(0)
        st.MCU_blk_row[1] = Int32(0)
    else
        st.MCUs_per_row = cld(st.W, Int(st.max_h) * 8)
        st.blocks_in_MCU = 0
        empty!(st.MCU_membership)
        empty!(st.MCU_blk_col)
        empty!(st.MCU_blk_row)
        for (i, cidx) in enumerate(st.scan_comps)
            comp = st.comps[cidx]
            comp.MCU_width = Int(comp.h)
            comp.MCU_height = Int(comp.v)
            tmp = comp.width_in_blocks % comp.MCU_width
            comp.last_col_width = tmp == 0 ? comp.MCU_width : tmp
            tmp = comp.height_in_blocks % comp.MCU_height
            comp.last_row_height = tmp == 0 ? comp.MCU_height : tmp
            st.blocks_in_MCU + comp.MCU_width * comp.MCU_height > 10 &&
                error("JPEG MCU contains more than 10 blocks")
            for y in 0:(comp.MCU_height - 1), x in 0:(comp.MCU_width - 1)
                push!(st.MCU_membership, Int8(i - 1))
                push!(st.MCU_blk_row, Int32(y))
                push!(st.MCU_blk_col, Int32(x))
            end
            st.blocks_in_MCU += comp.MCU_width * comp.MCU_height
        end
    end
    return nothing
end

# latch_quant_tables (jdinput.c): a component keeps the quant table latched at
# the first scan that references it.
function _jpeg_latch_quant!(st::_JpegState)
    for cidx in st.scan_comps
        comp = st.comps[cidx]
        comp.quant_table === nothing || continue
        tq = Int(comp.tq)
        (tq > 3 || st.qt[tq + 1] === nothing) &&
            error("JPEG component references missing quantization table $tq")
        comp.quant_table = st.qt[tq + 1]
    end
    return nothing
end

# ------------------------------ entropy decode ------------------------------

# Re-synchronize at a restart interval boundary (jdmarker.c
# read_restart_marker).  A mismatched restart sequence is corrupt data.
function _jpeg_process_restart!(st::_JpegState)
    st.nbits = 0
    st.bitbuf = UInt64(0)
    if st.unread_marker == 0
        st.unread_marker = _jpeg_next_marker(st, true)
    end
    expected = _JPEG_RST0 + Int32(st.next_restart_num)
    st.unread_marker == expected ||
        error("JPEG restart marker sequence is corrupt")
    st.unread_marker = Int32(0)
    st.next_restart_num = (st.next_restart_num + 1) & 7
    fill!(st.last_dc, Int32(0))
    st.eobrun = 0
    st.restarts_to_go = st.restart_interval
    return nothing
end

const _JPEG_EMPTY_HUFF = _JpegHuffTbl(Int32[], Int32[], UInt8[], Int32[])

# Entropy decoder start-of-scan (jdhuff.c / jdphuff.c start_pass).
function _jpeg_start_scan!(st::_JpegState)
    if st.progressive
        is_dc = st.Ss == 0
        bad = st.Ss > st.Se || st.Se >= 64 ||
              (!is_dc && length(st.scan_comps) != 1)
        if st.Ah != 0
            st.Al != st.Ah - 1 && (bad = true)
        end
        st.Al > 13 && (bad = true)
        bad && error("JPEG progressive scan parameters (Ss=$(st.Ss) " *
                     "Se=$(st.Se) Ah=$(st.Ah) Al=$(st.Al)) are invalid")
        for cidx in st.scan_comps
            comp = st.comps[cidx]
            lo = min(st.Ss, 1) + 1
            hi = max(st.Se, 9) + 1
            for coefi in lo:hi
                st.prev_coef_bits[coefi, cidx] =
                    st.input_scan_number > 1 ? st.coef_bits[coefi, cidx] : Int8(0)
            end
            for coefi in (st.Ss + 1):(st.Se + 1)
                st.coef_bits[coefi, cidx] = Int8(st.Al)
            end
        end
    end
    empty!(st.scan_dc)
    empty!(st.scan_ac)
    n = length(st.scan_comps)
    resize!(st.last_dc, n)
    fill!(st.last_dc, Int32(0))
    st.eobrun = 0
    st.restarts_to_go = st.restart_interval
    st.bitbuf = UInt64(0)
    st.nbits = 0
    st.epos = st.pos
    for blkn in 0:(st.blocks_in_MCU - 1)
        scanidx = Int(st.MCU_membership[blkn + 1]) + 1
        comp = st.comps[st.scan_comps[scanidx]]
        if !st.progressive || (st.Ss == 0 && st.Ah == 0)
            t = Int(comp.dc_tbl)
            (t > 3 || st.dcht[t + 1] === nothing) &&
                error("JPEG scan references missing DC Huffman table $t")
            push!(st.scan_dc, st.dcht[t + 1])
        else
            push!(st.scan_dc, _JPEG_EMPTY_HUFF)
        end
        if !st.progressive || st.Ss != 0
            t = Int(comp.ac_tbl)
            (t > 3 || st.acht[t + 1] === nothing) &&
                error("JPEG scan references missing AC Huffman table $t")
            push!(st.scan_ac, st.acht[t + 1])
        else
            push!(st.scan_ac, _JPEG_EMPTY_HUFF)
        end
    end
    return nothing
end

function _jpeg_decode_scan!(st::_JpegState)
    _jpeg_per_scan_setup!(st)
    _jpeg_latch_quant!(st)
    _jpeg_start_scan!(st)
    single = length(st.scan_comps) == 1
    v = single ? Int(st.comps[st.scan_comps[1]].v) : 1
    lastrow = single ? Int(st.comps[st.scan_comps[1]].last_row_height) : 1
    for imcu in 0:(st.total_imcu_rows - 1)
        rows_this = single ? (imcu < st.total_imcu_rows - 1 ? v : lastrow) : 1
        for yoff in 0:(rows_this - 1)
            for mcu_col in 0:(st.MCUs_per_row - 1)
                _jpeg_decode_mcu!(st, imcu, yoff, mcu_col)
            end
        end
    end
    st.pos = st.epos
    return nothing
end

@inline function _jpeg_decode_mcu!(st::_JpegState, imcu::Int, yoff::Int,
                                   mcu_col::Int)
    if st.restart_interval != 0
        st.restarts_to_go == 0 && _jpeg_process_restart!(st)
        st.restarts_to_go -= 1
    end
    if st.progressive
        _jpeg_mcu_progressive!(st, imcu, yoff, mcu_col)
    else
        _jpeg_mcu_sequential!(st, imcu, yoff, mcu_col)
    end
    return nothing
end

# Map MCU block blkn (0-based) to (scan comp index, block row, block col).
@inline function _jpeg_block_pos(st::_JpegState, blkn::Int, imcu::Int,
                                 yoff::Int, mcu_col::Int)
    scanidx = Int(st.MCU_membership[blkn + 1]) + 1
    comp = st.comps[st.scan_comps[scanidx]]
    if length(st.scan_comps) == 1
        return scanidx, imcu * Int(comp.v) + yoff, mcu_col
    end
    return scanidx,
           imcu * Int(comp.v) + Int(st.MCU_blk_row[blkn + 1]),
           mcu_col * comp.MCU_width + Int(st.MCU_blk_col[blkn + 1])
end

function _jpeg_mcu_sequential!(st::_JpegState, imcu::Int, yoff::Int,
                               mcu_col::Int)
    for blkn in 0:(st.blocks_in_MCU - 1)
        scanidx, brow, bcol = _jpeg_block_pos(st, blkn, imcu, yoff, mcu_col)
        comp = st.comps[st.scan_comps[scanidx]]
        coefs = comp.coefs
        dctbl = st.scan_dc[blkn + 1]
        actbl = st.scan_ac[blkn + 1]
        s = _jpeg_huff_decode(st, dctbl)
        if s != 0
            s = _jpeg_extend(_jpeg_take_bits(st, Int(s)), s)
        end
        s = (st.last_dc[scanidx] + s) % Int32   # C int32 wraparound
        st.last_dc[scanidx] = s
        # In streaming mode comp.coefs is a one-band buffer; the row index is
        # local to the current iMCU row and the block must be zeroed first so
        # coefficients not written this band do not leak in from the last.
        brw = st.streaming ? brow - imcu * Int(comp.v) : brow
        st.streaming && fill!(@view(coefs[:, bcol + 1, brw + 1]), Int16(0))
        coefs[1, bcol + 1, brw + 1] = s % Int16
        k = 1
        while k < 64
            rs = _jpeg_huff_decode(st, actbl)
            r = rs >> 4
            s = rs & 15
            if s != 0
                k += r
                v = _jpeg_extend(_jpeg_take_bits(st, Int(s)), s)
                coefs[_JPEG_NATURAL_ORDER[k + 1] + 1, bcol + 1, brw + 1] =
                    v % Int16
            else
                r != 15 && break
                k += 15
            end
            k += 1
        end
    end
    return nothing
end

function _jpeg_mcu_progressive!(st::_JpegState, imcu::Int, yoff::Int,
                                mcu_col::Int)
    if st.Ah == 0
        if st.Ss == 0
            _jpeg_mcu_dc_first!(st, imcu, yoff, mcu_col)
        else
            _jpeg_mcu_ac_first!(st, imcu, yoff, mcu_col)
        end
    else
        if st.Ss == 0
            _jpeg_mcu_dc_refine!(st, imcu, yoff, mcu_col)
        else
            _jpeg_mcu_ac_refine!(st, imcu, yoff, mcu_col)
        end
    end
    return nothing
end

function _jpeg_mcu_dc_first!(st::_JpegState, imcu::Int, yoff::Int, mcu_col::Int)
    Al = Int32(st.Al)
    for blkn in 0:(st.blocks_in_MCU - 1)
        scanidx, brow, bcol = _jpeg_block_pos(st, blkn, imcu, yoff, mcu_col)
        comp = st.comps[st.scan_comps[scanidx]]
        tbl = st.scan_dc[blkn + 1]
        s = _jpeg_huff_decode(st, tbl)
        if s != 0
            s = _jpeg_extend(_jpeg_take_bits(st, Int(s)), s)
        end
        last = st.last_dc[scanidx]
        (Int64(s) > Int64(0x7fffffff) - Int64(last) ||
         Int64(s) < Int64(typemin(Int32)) - Int64(last)) &&
            error("JPEG DC coefficient is out of range")
        s += last
        st.last_dc[scanidx] = s
        comp.coefs[1, bcol + 1, brow + 1] = (s << Al) % Int16
    end
    return nothing
end

function _jpeg_mcu_ac_first!(st::_JpegState, imcu::Int, yoff::Int, mcu_col::Int)
    if st.eobrun > 0
        st.eobrun -= 1
        return nothing
    end
    Se = st.Se
    Al = Int32(st.Al)
    comp = st.comps[st.scan_comps[1]]
    coefs = comp.coefs
    brow = imcu * Int(comp.v) + yoff + 1
    bcol = mcu_col + 1
    tbl = st.scan_ac[1]
    k = st.Ss
    @inbounds while k <= Se
        rs = _jpeg_huff_decode(st, tbl)
        r = rs >> 4
        s = rs & 15
        if s != 0
            k += r
            v = _jpeg_extend(_jpeg_take_bits(st, Int(s)), s)
            coefs[_JPEG_NATURAL_ORDER[k + 1] + 1, bcol, brow] = (v << Al) % Int16
        else
            if r == 15
                k += 15
            else
                st.eobrun = 1 << r
                r != 0 && (st.eobrun += Int(_jpeg_take_bits(st, Int(r))))
                st.eobrun -= 1
                break
            end
        end
        k += 1
    end
    return nothing
end

function _jpeg_mcu_dc_refine!(st::_JpegState, imcu::Int, yoff::Int, mcu_col::Int)
    p1 = Int16(1 << st.Al)
    for blkn in 0:(st.blocks_in_MCU - 1)
        scanidx, brow, bcol = _jpeg_block_pos(st, blkn, imcu, yoff, mcu_col)
        comp = st.comps[st.scan_comps[scanidx]]
        if _jpeg_take_bits(st, 1) != 0
            comp.coefs[1, bcol + 1, brow + 1] |= p1
        end
    end
    return nothing
end

function _jpeg_mcu_ac_refine!(st::_JpegState, imcu::Int, yoff::Int,
                              mcu_col::Int)
    Se = st.Se
    p1 = Int16(1 << st.Al)
    m1 = Int16(-1 << st.Al)
    comp = st.comps[st.scan_comps[1]]
    coefs = comp.coefs
    brow = imcu * Int(comp.v) + yoff + 1
    bcol = mcu_col + 1
    tbl = st.scan_ac[1]
    k = st.Ss
    @inbounds begin
        if st.eobrun == 0
            while k <= Se
                rs = _jpeg_huff_decode(st, tbl)
                r = rs >> 4
                s = rs & 15
                if s != 0
                    # size of a newly nonzero coefficient is always 1
                    s = _jpeg_take_bits(st, 1) != 0 ? p1 : m1
                else
                    if r != 15
                        st.eobrun = 1 << r
                        if r != 0
                            st.eobrun += Int(_jpeg_take_bits(st, Int(r)))
                        end
                        break
                    end
                    # s == 0, r == 15: ZRL, process r below
                end
                # Advance over already-nonzero coefs (appending correction
                # bits) and r still-zero coefs.
                while true
                    idx = _JPEG_NATURAL_ORDER[k + 1] + 1
                    cur = coefs[idx, bcol, brow]
                    if cur != 0
                        if _jpeg_take_bits(st, 1) != 0 && (cur & p1) == 0
                            coefs[idx, bcol, brow] =
                                cur >= 0 ? cur + p1 : cur + m1
                        end
                    else
                        r -= 1
                        r < 0 && break
                    end
                    k += 1
                    k <= Se || break
                end
                if s != 0
                    coefs[_JPEG_NATURAL_ORDER[k + 1] + 1, bcol, brow] = s
                end
                k += 1
            end
        end
        if st.eobrun > 0
            while k <= Se
                idx = _JPEG_NATURAL_ORDER[k + 1] + 1
                cur = coefs[idx, bcol, brow]
                if cur != 0
                    if _jpeg_take_bits(st, 1) != 0 && (cur & p1) == 0
                        coefs[idx, bcol, brow] = cur >= 0 ? cur + p1 : cur + m1
                    end
                end
                k += 1
            end
            st.eobrun -= 1
        end
    end
    return nothing
end


# --------------------------------- IDCT -------------------------------------

# jpeg_idct_islow (jidctint.c) with CONST_BITS = 13, PASS1_BITS = 2.  All
# intermediate arithmetic wraps at 32 bits, matching `long`/`JLONG` on the
# 32-bit-long reference build; the final descale is masked with RANGE_MASK.
@inline _jpeg_descale(x::Int32, n::Int) = (x + (Int32(1) << (n - 1))) >> n

# IDCT one 8x8 block whose 64 natural-order coefficients start at `cbase`
# (0-based linear index) in `coef`.  Writes into `plane` (row-major column
# index): sample (r, c) of the block lands at plane[brow0 + r, bcol0 + c].
function _jpeg_idct_block!(plane::Matrix{UInt8}, brow0::Int, bcol0::Int,
                           coef::AbstractArray{Int16}, cbase::Int,
                           q::Vector{Int32}, ws::Vector{Int32})
    nrows = size(plane, 1)
    @inbounds begin
        for ctr in 0:7   # pass 1: columns, scaled by sqrt(8) << PASS1_BITS
            if coef[cbase + ctr + 9] == 0 && coef[cbase + ctr + 17] == 0 &&
               coef[cbase + ctr + 25] == 0 && coef[cbase + ctr + 33] == 0 &&
               coef[cbase + ctr + 41] == 0 && coef[cbase + ctr + 49] == 0 &&
               coef[cbase + ctr + 57] == 0
                dcval = (Int32(coef[cbase + ctr + 1]) * q[ctr + 1]) << 2
                for r in 0:7
                    ws[ctr + r * 8 + 1] = dcval
                end
                continue
            end
            z2 = Int32(coef[cbase + ctr + 17]) * q[ctr + 17]
            z3 = Int32(coef[cbase + ctr + 49]) * q[ctr + 49]
            z1 = (z2 + z3) * Int32(4433)
            tmp2 = z1 + z3 * Int32(-15137)
            tmp3 = z1 + z2 * Int32(6270)
            z2 = Int32(coef[cbase + ctr + 1]) * q[ctr + 1]
            z3 = Int32(coef[cbase + ctr + 33]) * q[ctr + 33]
            tmp0 = (z2 + z3) << 13
            tmp1 = (z2 - z3) << 13
            tmp10 = tmp0 + tmp3
            tmp13 = tmp0 - tmp3
            tmp11 = tmp1 + tmp2
            tmp12 = tmp1 - tmp2
            tmp0 = Int32(coef[cbase + ctr + 57]) * q[ctr + 57]
            tmp1 = Int32(coef[cbase + ctr + 41]) * q[ctr + 41]
            tmp2 = Int32(coef[cbase + ctr + 25]) * q[ctr + 25]
            tmp3 = Int32(coef[cbase + ctr + 9]) * q[ctr + 9]
            z1 = tmp0 + tmp3
            z2 = tmp1 + tmp2
            z3 = tmp0 + tmp2
            z4 = tmp1 + tmp3
            z5 = (z3 + z4) * Int32(9633)
            tmp0 *= Int32(2446)
            tmp1 *= Int32(16819)
            tmp2 *= Int32(25172)
            tmp3 *= Int32(12299)
            z1 *= Int32(-7373)
            z2 *= Int32(-20995)
            z3 *= Int32(-16069)
            z4 *= Int32(-3196)
            z3 += z5
            z4 += z5
            tmp0 += z1 + z3
            tmp1 += z2 + z4
            tmp2 += z2 + z3
            tmp3 += z1 + z4
            ws[ctr + 1]  = _jpeg_descale(tmp10 + tmp3, 11)
            ws[ctr + 57] = _jpeg_descale(tmp10 - tmp3, 11)
            ws[ctr + 9]  = _jpeg_descale(tmp11 + tmp2, 11)
            ws[ctr + 49] = _jpeg_descale(tmp11 - tmp2, 11)
            ws[ctr + 17] = _jpeg_descale(tmp12 + tmp1, 11)
            ws[ctr + 41] = _jpeg_descale(tmp12 - tmp1, 11)
            ws[ctr + 25] = _jpeg_descale(tmp13 + tmp0, 11)
            ws[ctr + 33] = _jpeg_descale(tmp13 - tmp0, 11)
        end
        rl = _JPEG_RANGE_LIMIT
        for ctr in 0:7   # pass 2: rows, descale by 8 then PASS1_BITS
            base = ctr * 8
            if ws[base + 2] == 0 && ws[base + 3] == 0 && ws[base + 4] == 0 &&
               ws[base + 5] == 0 && ws[base + 6] == 0 && ws[base + 7] == 0 &&
               ws[base + 8] == 0
                dcval = rl[Int(_jpeg_descale(ws[base + 1], 5) & Int32(1023)) + 1]
                for c in 0:7
                    plane[brow0 + ctr + (bcol0 + c) * nrows + 1] = dcval
                end
                continue
            end
            z2 = ws[base + 3]
            z3 = ws[base + 7]
            z1 = (z2 + z3) * Int32(4433)
            tmp2 = z1 + z3 * Int32(-15137)
            tmp3 = z1 + z2 * Int32(6270)
            tmp0 = (ws[base + 1] + ws[base + 5]) << 13
            tmp1 = (ws[base + 1] - ws[base + 5]) << 13
            tmp10 = tmp0 + tmp3
            tmp13 = tmp0 - tmp3
            tmp11 = tmp1 + tmp2
            tmp12 = tmp1 - tmp2
            tmp0 = ws[base + 8]
            tmp1 = ws[base + 6]
            tmp2 = ws[base + 4]
            tmp3 = ws[base + 2]
            z1 = tmp0 + tmp3
            z2 = tmp1 + tmp2
            z3 = tmp0 + tmp2
            z4 = tmp1 + tmp3
            z5 = (z3 + z4) * Int32(9633)
            tmp0 *= Int32(2446)
            tmp1 *= Int32(16819)
            tmp2 *= Int32(25172)
            tmp3 *= Int32(12299)
            z1 *= Int32(-7373)
            z2 *= Int32(-20995)
            z3 *= Int32(-16069)
            z4 *= Int32(-3196)
            z3 += z5
            z4 += z5
            tmp0 += z1 + z3
            tmp1 += z2 + z4
            tmp2 += z2 + z3
            tmp3 += z1 + z4
            plane[brow0 + ctr + bcol0 * nrows + 1] =
                rl[Int(_jpeg_descale(tmp10 + tmp3, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 7) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp10 - tmp3, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 1) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp11 + tmp2, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 6) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp11 - tmp2, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 2) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp12 + tmp1, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 5) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp12 - tmp1, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 3) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp13 + tmp0, 18) & Int32(1023)) + 1]
            plane[brow0 + ctr + (bcol0 + 4) * nrows + 1] =
                rl[Int(_jpeg_descale(tmp13 - tmp0, 18) & Int32(1023)) + 1]
        end
    end
    return nothing
end

# ------------------------- progressive block smoothing -----------------------

# smoothing_ok (jdcoefct.c): latch the coefficient-bit state for this output
# pass; block smoothing runs only when it is applicable and useful.
function _jpeg_smoothing_latch!(st::_JpegState, latch::Array{Int8,2},
                              prev_latch::Array{Int8,2})
    st.progressive || return false
    useful = false
    for ci in 1:st.ncomp
        q = st.comps[ci].quant_table
        q === nothing && return false
        # DC and the first nine AC quantizers must be nonzero.
        for pos in (1, 2, 9, 17, 10, 3, 4, 11, 18, 25)
            q[pos] == 0 && return false
        end
        st.coef_bits[1, ci] < 0 && return false
        latch[1, ci] = st.coef_bits[1, ci]
        for coefi in 2:10
            prev_latch[coefi, ci] =
                st.input_scan_number > 1 ? st.prev_coef_bits[coefi, ci] : Int8(-1)
            latch[coefi, ci] = st.coef_bits[coefi, ci]
            latch[coefi, ci] != 0 && (useful = true)
        end
    end
    return useful
end

# div by 2^k the C way: JLONG division truncates toward zero.
@inline _jpeg_cdiv(a::Int32, b::Int32) = div(a, b)

# One smoothing estimate: num is a signed Int32 accumulation, Q the quantizer.
@inline function _jpeg_smooth_pred(num::Int32, Q::Int32, Al::Int32)
    if num >= 0
        pred = _jpeg_cdiv((Q << 7) + num, Q << 8)
        Al > 0 && pred >= (Int32(1) << Al) && (pred = (Int32(1) << Al) - Int32(1))
        return pred
    end
    pred = _jpeg_cdiv((Q << 7) - num, Q << 8)
    Al > 0 && pred >= (Int32(1) << Al) && (pred = (Int32(1) << Al) - Int32(1))
    return -pred
end

# decompress_smooth_data inner block (jdcoefct.c): ws is the 64-element block
# copy (mutated), cbits the latched coef_bits, DC the 25-element DC window.
function _jpeg_smooth_block!(ws::Vector{Int16}, q::Vector{Int32},
                             cbits::AbstractVector{Int8}, DC::Vector{Int32})
    change_dc = true
    for i in 2:10
        if cbits[i] != -1
            change_dc = false
            break
        end
    end
    Q00 = q[1]; Q01 = q[2]; Q10 = q[9]; Q20 = q[17]; Q11 = q[10]; Q02 = q[3]
    Q03 = Int32(0); Q12 = Int32(0); Q21 = Int32(0); Q30 = Int32(0)
    if change_dc
        Q03 = q[4]; Q12 = q[11]; Q21 = q[18]; Q30 = q[25]
    end
    (DC01, DC02, DC03, DC04, DC05, DC06, DC07, DC08, DC09, DC10,
     DC11, DC12, DC13, DC14, DC15, DC16, DC17, DC18, DC19, DC20,
     DC21, DC22, DC23, DC24, DC25) = DC
    # AC01
    if (Al = Int32(cbits[2])) != 0 && ws[2] == 0
        num = Q00 * (change_dc ?
              (-DC01 - DC02 + DC04 + DC05 - Int32(3) * DC06 + Int32(13) * DC07 -
               Int32(13) * DC09 + Int32(3) * DC10 - Int32(3) * DC11 + Int32(38) * DC12 - Int32(38) * DC14 +
               Int32(3) * DC15 - Int32(3) * DC16 + Int32(13) * DC17 - Int32(13) * DC19 + Int32(3) * DC20 -
               DC21 - DC22 + DC24 + DC25) :
              (-Int32(7) * DC11 + Int32(50) * DC12 - Int32(50) * DC14 + Int32(7) * DC15))
        ws[2] = _jpeg_smooth_pred(num, Q01, Al) % Int16
    end
    # AC10
    if (Al = Int32(cbits[3])) != 0 && ws[9] == 0
        num = Q00 * (change_dc ?
              (-DC01 - Int32(3) * DC02 - Int32(3) * DC03 - Int32(3) * DC04 - DC05 - DC06 +
               Int32(13) * DC07 + Int32(38) * DC08 + Int32(13) * DC09 - DC10 + DC16 -
               Int32(13) * DC17 - Int32(38) * DC18 - Int32(13) * DC19 + DC20 + DC21 +
               Int32(3) * DC22 + Int32(3) * DC23 + Int32(3) * DC24 + DC25) :
              (-Int32(7) * DC03 + Int32(50) * DC08 - Int32(50) * DC18 + Int32(7) * DC23))
        ws[9] = _jpeg_smooth_pred(num, Q10, Al) % Int16
    end
    # AC20
    if (Al = Int32(cbits[4])) != 0 && ws[17] == 0
        num = Q00 * (change_dc ?
              (DC03 + Int32(2) * DC07 + Int32(7) * DC08 + Int32(2) * DC09 - Int32(5) * DC12 - Int32(14) * DC13 -
               Int32(5) * DC14 + Int32(2) * DC17 + Int32(7) * DC18 + Int32(2) * DC19 + DC23) :
              (-DC03 + Int32(13) * DC08 - Int32(24) * DC13 + Int32(13) * DC18 - DC23))
        ws[17] = _jpeg_smooth_pred(num, Q20, Al) % Int16
    end
    # AC11
    if (Al = Int32(cbits[5])) != 0 && ws[10] == 0
        num = Q00 * (change_dc ?
              (-DC01 + DC05 + Int32(9) * DC07 - Int32(9) * DC09 - Int32(9) * DC17 +
               Int32(9) * DC19 + DC21 - DC25) :
              (DC10 + DC16 - Int32(10) * DC17 + Int32(10) * DC19 - DC02 - DC20 + DC22 -
               DC24 + DC04 - DC06 + Int32(10) * DC07 - Int32(10) * DC09))
        ws[10] = _jpeg_smooth_pred(num, Q11, Al) % Int16
    end
    # AC02
    if (Al = Int32(cbits[6])) != 0 && ws[3] == 0
        num = Q00 * (change_dc ?
              (Int32(2) * DC07 - Int32(5) * DC08 + Int32(2) * DC09 + DC11 + Int32(7) * DC12 - Int32(14) * DC13 +
               Int32(7) * DC14 + DC15 + Int32(2) * DC17 - Int32(5) * DC18 + Int32(2) * DC19) :
              (-DC11 + Int32(13) * DC12 - Int32(24) * DC13 + Int32(13) * DC14 - DC15))
        ws[3] = _jpeg_smooth_pred(num, Q02, Al) % Int16
    end
    if change_dc
        # AC03
        if (Al = Int32(cbits[7])) != 0 && ws[4] == 0
            num = Q00 * (DC07 - DC09 + Int32(2) * DC12 - Int32(2) * DC14 + DC17 - DC19)
            ws[4] = _jpeg_smooth_pred(num, Q03, Al) % Int16
        end
        # AC12
        if (Al = Int32(cbits[8])) != 0 && ws[11] == 0
            num = Q00 * (DC07 - Int32(3) * DC08 + DC09 - DC17 + Int32(3) * DC18 - DC19)
            ws[11] = _jpeg_smooth_pred(num, Q12, Al) % Int16
        end
        # AC21
        if (Al = Int32(cbits[9])) != 0 && ws[18] == 0
            num = Q00 * (DC07 - DC09 - Int32(3) * DC12 + Int32(3) * DC14 + DC17 - DC19)
            ws[18] = _jpeg_smooth_pred(num, Q21, Al) % Int16
        end
        # AC30
        if (Al = Int32(cbits[10])) != 0 && ws[25] == 0
            num = Q00 * (DC07 + Int32(2) * DC08 + DC09 - DC17 - Int32(2) * DC18 - DC19)
            ws[25] = _jpeg_smooth_pred(num, Q30, Al) % Int16
        end
        # DC: coef_bits[0] is non-negative here (checked by the latch).
        num = Q00 *
              (-Int32(2) * DC01 - Int32(6) * DC02 - Int32(8) * DC03 - Int32(6) * DC04 - Int32(2) * DC05 -
               Int32(6) * DC06 + Int32(6) * DC07 + Int32(42) * DC08 + Int32(6) * DC09 - Int32(6) * DC10 -
               Int32(8) * DC11 + Int32(42) * DC12 + Int32(152) * DC13 + Int32(42) * DC14 - Int32(8) * DC15 -
               Int32(6) * DC16 + Int32(6) * DC17 + Int32(42) * DC18 + Int32(6) * DC19 - Int32(6) * DC20 -
               Int32(2) * DC21 - Int32(6) * DC22 - Int32(8) * DC23 - Int32(6) * DC24 - Int32(2) * DC25)
        if num >= 0
            pred = _jpeg_cdiv((Q00 << 7) + num, Q00 << 8)
        else
            pred = -_jpeg_cdiv((Q00 << 7) - num, Q00 << 8)
        end
        ws[1] = pred % Int16
    end
    return nothing
end

# Render each component's coefficient array into its (iMCU-padded) sample
# plane, with block smoothing if applicable (decompress_smooth_data).
function _jpeg_render_planes!(st::_JpegState, planes::Vector{Matrix{UInt8}},
                              ws32::Vector{Int32})
    latch = zeros(Int8, 10, st.ncomp)
    prev_latch = fill(Int8(-1), 10, st.ncomp)
    smooth = _jpeg_smoothing_latch!(st, latch, prev_latch)
    last_imcu = st.total_imcu_rows - 1
    ws16 = smooth ? Vector{Int16}(undef, 64) : Int16[]
    DC = smooth ? Vector{Int32}(undef, 25) : Int32[]
    for ci in 1:st.ncomp
        comp = st.comps[ci]
        # A component never covered by a scan has no latched table; its all-zero
        # coefficient array renders as mid-gray regardless of the multipliers.
        q = comp.quant_table === nothing ? zeros(Int32, 64) : comp.quant_table
        plane = planes[ci]
        coefs = comp.coefs
        wb = size(coefs, 2)
        wib = comp.width_in_blocks
        last_col = wib - 1
        for imcu in 0:last_imcu
            block_rows = if imcu < last_imcu
                Int(comp.v)
            else
                r = Int(comp.height_in_blocks % comp.v)
                r == 0 ? Int(comp.v) : r
            end
            image_block_rows = block_rows * st.total_imcu_rows
            for block_row in 0:(block_rows - 1)
                br = imcu * Int(comp.v) + block_row + 1
                if !smooth
                    for bcol in 1:wib
                        _jpeg_idct_block!(plane, (br - 1) * 8, (bcol - 1) * 8,
                                          coefs,
                                          (br - 1) * wb * 64 + (bcol - 1) * 64,
                                          q, ws32)
                    end
                    continue
                end
                image_block_row = imcu * block_rows + block_row
                prev_r = image_block_row > 0 ? br - 1 : br
                prevprev_r = image_block_row > 1 ? br - 2 : prev_r
                next_r = image_block_row < image_block_rows - 1 ? br + 1 : br
                nextnext_r = image_block_row < image_block_rows - 2 ? br + 2 : next_r
                DC[1] = DC[2] = DC[3] = DC[4] = DC[5] =
                    Int32(coefs[1, 1, prevprev_r])
                DC[6] = DC[7] = DC[8] = DC[9] = DC[10] =
                    Int32(coefs[1, 1, prev_r])
                DC[11] = DC[12] = DC[13] = DC[14] = DC[15] =
                    Int32(coefs[1, 1, br])
                DC[16] = DC[17] = DC[18] = DC[19] = DC[20] =
                    Int32(coefs[1, 1, next_r])
                DC[21] = DC[22] = DC[23] = DC[24] = DC[25] =
                    Int32(coefs[1, 1, nextnext_r])
                for bnum in 0:last_col
                    copyto!(ws16, 1, coefs, (br - 1) * wb * 64 + bnum * 64 + 1, 64)
                    if bnum == 0 && bnum < last_col
                        DC[4] = DC[5] = Int32(coefs[1, 2, prevprev_r])
                        DC[9] = DC[10] = Int32(coefs[1, 2, prev_r])
                        DC[14] = DC[15] = Int32(coefs[1, 2, br])
                        DC[19] = DC[20] = Int32(coefs[1, 2, next_r])
                        DC[24] = DC[25] = Int32(coefs[1, 2, nextnext_r])
                    end
                    if bnum + 1 < last_col
                        DC[5] = Int32(coefs[1, bnum + 3, prevprev_r])
                        DC[10] = Int32(coefs[1, bnum + 3, prev_r])
                        DC[15] = Int32(coefs[1, bnum + 3, br])
                        DC[20] = Int32(coefs[1, bnum + 3, next_r])
                        DC[25] = Int32(coefs[1, bnum + 3, nextnext_r])
                    end
                    _jpeg_smooth_block!(ws16, q, @view(latch[:, ci]), DC)
                    _jpeg_idct_block!(plane, (br - 1) * 8, bnum * 8,
                                      ws16, 0, q, ws32)
                    for i in 1:20
                        DC[i] = DC[i + 1]
                    end
                end
            end
        end
    end
    return nothing
end

# ------------------------------- upsampling ---------------------------------

# Per-component upsampling (jdsample.c).  Input row indices are clamped to the
# component's real downsampled rows, matching the context-row duplication that
# jdmainct.c performs at the image edges.

function _jpeg_upselect(comp::_JpegComponent, maxh::Int, maxv::Int)
    h_in = Int(comp.h); v_in = Int(comp.v)
    h_in == maxh && v_in == maxv && return :fullsize
    dw = comp.downsampled_width
    if h_in * 2 == maxh && v_in == maxv
        return dw > 2 ? :h2v1_fancy : :h2v1_box
    elseif h_in == maxh && v_in * 2 == maxv
        return :h1v2_fancy    # do_fancy is always true at scale 1
    elseif h_in * 2 == maxh && v_in * 2 == maxv
        return dw > 2 ? :h2v2_fancy : :h2v2_box
    elseif maxh % h_in == 0 && maxv % v_in == 0
        return :int
    end
    error("JPEG fractional sampling factors are not supported")
end

# Row clamped to the component's real downsampled rows (0-based r -> 1-based).
@inline _jpeg_prow(r::Int, dh::Int) = r < 0 ? 1 : (r >= dh ? dh : r + 1)

# h2v1 fancy upsample of one input row into one output row of 2*dw samples.
function _jpeg_h2v1_fancy_row!(out::AbstractVector{UInt8},
                               plane::Matrix{UInt8}, r::Int, dw::Int)
    @inbounds begin
        in0 = Int32(plane[r, 1])
        out[1] = UInt8(in0)
        out[2] = UInt8((in0 * 3 + Int32(plane[r, 2]) + 2) >> 2)
        for k in 2:(dw - 1)
            v = Int32(plane[r, k]) * 3
            out[2 * k - 1] = UInt8((v + Int32(plane[r, k - 1]) + 1) >> 2)
            out[2 * k]     = UInt8((v + Int32(plane[r, k + 1]) + 2) >> 2)
        end
        vl = Int32(plane[r, dw])
        out[2 * dw - 1] = UInt8((vl * 3 + Int32(plane[r, dw - 1]) + 1) >> 2)
        out[2 * dw] = UInt8(vl)
    end
    return nothing
end

# h2v2 fancy: one input row pair -> one output row of 2*dw samples.
# r0 is the nearer input row, r1 the next-nearest (both already clamped).
function _jpeg_h2v2_fancy_row!(out::AbstractVector{UInt8},
                               plane::Matrix{UInt8}, r0::Int, r1::Int,
                               dw::Int)
    @inbounds begin
        this = Int32(plane[r0, 1]) * 3 + Int32(plane[r1, 1])
        nxt = Int32(plane[r0, 2]) * 3 + Int32(plane[r1, 2])
        out[1] = UInt8((this * 4 + 8) >> 4)
        out[2] = UInt8((this * 3 + nxt + 7) >> 4)
        last = this
        this = nxt
        for k in 2:(dw - 1)
            nxt = Int32(plane[r0, k + 1]) * 3 + Int32(plane[r1, k + 1])
            out[2 * k - 1] = UInt8((this * 3 + last + 8) >> 4)
            out[2 * k]     = UInt8((this * 3 + nxt + 7) >> 4)
            last = this
            this = nxt
        end
        out[2 * dw - 1] = UInt8((this * 3 + last + 8) >> 4)
        out[2 * dw]     = UInt8((this * 4 + 7) >> 4)
    end
    return nothing
end

# Upsample one component's plane to output resolution: rows 1..H, cols 1..W.
function _jpeg_upsample!(st::_JpegState, comp::_JpegComponent,
                       plane::Matrix{UInt8}, uplane::Matrix{UInt8},
                       scratch::Vector{UInt8})
    method = _jpeg_upselect(comp, Int(st.max_h), Int(st.max_v))
    H = st.H; W = st.W
    dh = comp.downsampled_height
    dw = comp.downsampled_width
    if method === :fullsize
        uplane .= @view(plane[1:H, 1:W])
        return uplane
    end
    hex = Int(st.max_h) ÷ Int(comp.h)
    vex = Int(st.max_v) ÷ Int(comp.v)
    @inbounds for orow in 0:(H - 1)
        outrow = @view uplane[orow + 1, :]
        if method === :h2v1_fancy
            r0 = _jpeg_prow(min(orow ÷ vex, dh - 1), dh)
            _jpeg_h2v1_fancy_row!(scratch, plane, r0, dw)
            copyto!(outrow, 1, scratch, 1, W)
        elseif method === :h2v1_box
            r0 = _jpeg_prow(min(orow, dh - 1), dh)
            for c in 0:(W - 1)
                outrow[c + 1] = plane[r0, (c >> 1) + 1]
            end
        elseif method === :h1v2_fancy
            inrow = orow >> 1
            r0 = _jpeg_prow(inrow, dh)
            r1 = _jpeg_prow(inrow + (orow & 1 == 0 ? -1 : 1), dh)
            bias = orow & 1 == 0 ? 1 : 2
            for c in 1:dw
                outrow[c] = UInt8((Int32(plane[r0, c]) * 3 +
                                   Int32(plane[r1, c]) + bias) >> 2)
            end
        elseif method === :h2v2_fancy
            inrow = orow >> 1
            r0 = _jpeg_prow(inrow, dh)
            r1 = _jpeg_prow(inrow + (orow & 1 == 0 ? -1 : 1), dh)
            _jpeg_h2v2_fancy_row!(scratch, plane, r0, r1, dw)
            copyto!(outrow, 1, scratch, 1, W)
        elseif method === :h2v2_box
            r0 = _jpeg_prow(orow >> 1, dh)
            for c in 0:(W - 1)
                outrow[c + 1] = plane[r0, (c >> 1) + 1]
            end
        else                                       # :int box upsample
            r0 = _jpeg_prow(min(orow ÷ vex, dh - 1), dh)
            for c in 0:(W - 1)
                outrow[c + 1] = plane[r0, min(c ÷ hex, dw - 1) + 1]
            end
        end
    end
    return uplane
end

# ------------------------------ color convert -------------------------------

# Integer YCbCr -> RGB tables (jdcolor.c build_ycc_rgb_table, SCALEBITS = 16;
# FIX(x) truncates x*65536 + 0.5 toward zero).
const _JPEG_CR_R = let f = Int32(floor(1.40200 * 65536.0 + 0.5))
    ntuple(i -> (f * (i - 129) + Int32(32768)) >> 16, 256)
end
const _JPEG_CB_B = let f = Int32(floor(1.77200 * 65536.0 + 0.5))
    ntuple(i -> (f * (i - 129) + Int32(32768)) >> 16, 256)
end
const _JPEG_CR_G = let f = Int32(floor(0.71414 * 65536.0 + 0.5))
    ntuple(i -> -f * (i - 129), 256)
end
const _JPEG_CB_G = let f = Int32(floor(0.34414 * 65536.0 + 0.5))
    ntuple(i -> -f * (i - 129) + Int32(32768), 256)
end

# The post-IDCT values fed to these tables lie in [-227, 483], within the part
# of sample_range_limit that is a plain clamp.
@inline _jpeg_clamp8(x::Integer) = x < 0 ? UInt8(0) : (x > 255 ? UInt8(255) : UInt8(x))

# default_decompress_parms color-space selection (jdapimin.c).
function _jpeg_colorspace(st::_JpegState)
    ncomp = st.ncomp
    ncomp == 1 && return :gray
    if ncomp == 3
        if st.saw_JFIF
            return :ycbcr
        elseif st.saw_Adobe
            return st.Adobe_transform == 0 ? :rgb : :ycbcr
        else
            c0 = st.comps[1].id; c1 = st.comps[2].id; c2 = st.comps[3].id
            if c0 == 82 && c1 == 71 && c2 == 66
                return :rgb    # ASCII 'R','G','B'
            elseif c0 == 1 && c1 == 2 && c2 == 3
                return :ycbcr
            else
                return :ycbcr
            end
        end
    elseif ncomp == 4
        if st.saw_Adobe
            return st.Adobe_transform == 0 ? :cmyk_inv : :ycck
        else
            return :cmyk
        end
    end
    error("JPEG with $ncomp components is not supported")
end

# Rounded c*k/255 (round half up) for CMYK-derived RGB.
@inline _jpeg_ck(c::UInt8, k::UInt8) =
    UInt8((Int32(c) * Int32(k) * 2 + 255) ÷ 510)

# UInt8 sample -> output element.  For Float64 output the lookup table keeps
# the values identical to Float64(reinterpret(N0f8, v)) at zero extra cost.
@inline _jpeg_outval(::Type{UInt8}, v::UInt8) = v
@inline _jpeg_outval(::Type{Float64}, v::UInt8) =
    _JPEG_N0F8_TO_FLOAT64[Int(v) + 1]

# Color-convert nr consecutive output rows starting at absolute row y0
# (1-based).  Row y0 + j reads uplines[ci][j + 1, x]: for whole-image calls
# (y0 == 1) the row index equals the image row; for band emission it is the
# row within the staging band.
function _jpeg_color_convert!(st::_JpegState, uplines::Vector{Matrix{UInt8}},
                              out::Array{T,3}, y0::Int, nr::Int) where T
    cs = _jpeg_colorspace(st)
    W = st.W
    if cs === :gray
        p = uplines[1]
        @inbounds for x in 1:W, j in 0:(nr - 1)
            v = p[j + 1, x]
            y = y0 + j
            out[y, x, 1] = _jpeg_outval(T, v)
            out[y, x, 2] = _jpeg_outval(T, v)
            out[y, x, 3] = _jpeg_outval(T, v)
        end
    elseif cs === :ycbcr
        p0 = uplines[1]; p1 = uplines[2]; p2 = uplines[3]
        @inbounds for x in 1:W, j in 0:(nr - 1)
            yv = Int32(p0[j + 1, x])
            cb = Int(p1[j + 1, x]) + 1
            cr = Int(p2[j + 1, x]) + 1
            y = y0 + j
            out[y, x, 1] = _jpeg_outval(T, _jpeg_clamp8(yv + _JPEG_CR_R[cr]))
            out[y, x, 2] = _jpeg_outval(T,
                _jpeg_clamp8(yv + ((_JPEG_CB_G[cb] + _JPEG_CR_G[cr]) >> 16)))
            out[y, x, 3] = _jpeg_outval(T, _jpeg_clamp8(yv + _JPEG_CB_B[cb]))
        end
    elseif cs === :rgb
        p0 = uplines[1]; p1 = uplines[2]; p2 = uplines[3]
        @inbounds for x in 1:W, j in 0:(nr - 1)
            y = y0 + j
            out[y, x, 1] = _jpeg_outval(T, p0[j + 1, x])
            out[y, x, 2] = _jpeg_outval(T, p1[j + 1, x])
            out[y, x, 3] = _jpeg_outval(T, p2[j + 1, x])
        end
    else
        # Four components.  Adobe data is stored inverted (value = 255 -
        # colorant); treat those decoded channels as inverted CMYK and emit
        # R = C*K/255 etc., rounded.  Non-Adobe four-component data is treated
        # as straight CMYK: R = (255-C)*(255-K)/255, rounded.
        p3 = uplines[4]
        adobe = cs !== :cmyk
        @inbounds for x in 1:W, j in 0:(nr - 1)
            k = p3[j + 1, x]
            c = uplines[1][j + 1, x]
            m = uplines[2][j + 1, x]
            yy = uplines[3][j + 1, x]
            if cs === :ycck
                # ycck_cmyk_convert (jdcolor.c): inverted CMY from YCbCr.
                yv = Int32(c)
                cb = Int(m) + 1
                cr = Int(yy) + 1
                c = UInt8(clamp(255 - Int(yv + _JPEG_CR_R[cr]), 0, 255))
                m = UInt8(clamp(255 - Int(yv +
                          ((_JPEG_CB_G[cb] + _JPEG_CR_G[cr]) >> 16)), 0, 255))
                yy = UInt8(clamp(255 - Int(yv + _JPEG_CB_B[cb]), 0, 255))
            end
            y = y0 + j
            if adobe
                out[y, x, 1] = _jpeg_outval(T, _jpeg_ck(c, k))
                out[y, x, 2] = _jpeg_outval(T, _jpeg_ck(m, k))
                out[y, x, 3] = _jpeg_outval(T, _jpeg_ck(yy, k))
            else
                out[y, x, 1] = _jpeg_outval(T, _jpeg_ck(255 - c, 255 - k))
                out[y, x, 2] = _jpeg_outval(T, _jpeg_ck(255 - m, 255 - k))
                out[y, x, 3] = _jpeg_outval(T, _jpeg_ck(255 - yy, 255 - k))
            end
        end
    end
    return nothing
end

# ------------------------ sequential band streaming -------------------------
#
# A single-scan sequential (SOF0/SOF1) file does not need whole-image
# coefficient planes: MCU rows decode in order, so each iMCU row of blocks can
# be IDCT'd into a small per-component ring of input rows, upsampled, and
# color-converted a band at a time.  Fancy vertical upsampling needs one input
# row of context on each side, so output for band b is emitted once band b + 1
# is decoded (the last band's context clamps at the image edge, matching the
# whole-plane path which renders and clamps identically).

mutable struct _JpegBands
    bandcoefs::Vector{Array{Int16,3}}  # per comp: (64, padded wb, v) band coefs
    ring::Vector{Matrix{UInt8}}        # per comp: ((2v+1)*8, wib*8) input rows
    ringn::Vector{Int}                 # ring row count (multiple of 8)
    ustage::Vector{Matrix{UInt8}}      # per comp: (maxv*8, W) upsampled band
    methods::Vector{Symbol}            # per comp upsampling method
    ws32::Vector{Int32}
    scratch::Vector{UInt8}
end

function _jpeg_band_setup!(st::_JpegState)
    bo = Int(st.max_v) * 8
    bandcoefs = Array{Int16,3}[]
    ring = Matrix{UInt8}[]
    ringn = Int[]
    ustage = Matrix{UInt8}[]
    for comp in st.comps
        v = Int(comp.v)
        wb = comp.width_in_blocks +
             mod(comp.h - comp.width_in_blocks % comp.h, comp.h)
        b = zeros(Int16, 64, wb, v)
        comp.coefs = b
        push!(bandcoefs, b)
        N = (2 * v + 1) * 8
        push!(ring, zeros(UInt8, N, comp.width_in_blocks * 8))
        push!(ringn, N)
        push!(ustage, Matrix{UInt8}(undef, bo, st.W))
    end
    methods = Symbol[
        _jpeg_upselect(comp, Int(st.max_h), Int(st.max_v)) for comp in st.comps]
    return _JpegBands(bandcoefs, ring, ringn, ustage, methods,
                      Vector{Int32}(undef, 64),
                      Vector{UInt8}(undef, st.W * Int(st.max_h) + 16))
end

# IDCT one iMCU row of blocks into each component's input-row ring.
function _jpeg_render_band!(st::_JpegState, bands::_JpegBands, imcu::Int)
    for ci in 1:st.ncomp
        comp = st.comps[ci]
        v = Int(comp.v)
        coefs = bands.bandcoefs[ci]
        wb = comp.width_in_blocks
        wbp = size(coefs, 2)
        ring = bands.ring[ci]
        N = bands.ringn[ci]
        q = comp.quant_table === nothing ? zeros(Int32, 64) : comp.quant_table
        hib = comp.height_in_blocks
        base = imcu * v
        for r in 0:(v - 1)
            br = base + r + 1
            br > hib && continue
            brow0 = mod((base + r) * 8, N)
            for bcol in 1:wb
                _jpeg_idct_block!(ring, brow0, (bcol - 1) * 8, coefs,
                                  r * wbp * 64 + (bcol - 1) * 64, q,
                                  bands.ws32)
            end
        end
    end
    return nothing
end

# Upsample one output row of component ci into ustage row or (1-based).  Input
# row indices are absolute (1-based), clamped to real rows exactly like the
# whole-plane path; the ring holds every row the emit schedule can reference.
function _jpeg_upsample_outrow!(st::_JpegState, bands::_JpegBands, ci::Int,
                                orow::Int, or_::Int)
    comp = st.comps[ci]
    ring = bands.ring[ci]
    N = bands.ringn[ci]
    u = bands.ustage[ci]
    W = st.W
    dh = comp.downsampled_height
    dw = comp.downsampled_width
    method = bands.methods[ci]
    if method === :fullsize
        l0 = mod(_jpeg_prow(orow, dh) - 1, N) + 1
        @inbounds for x in 1:W
            u[or_, x] = ring[l0, x]
        end
        return nothing
    end
    hex = Int(st.max_h) ÷ Int(comp.h)
    vex = Int(st.max_v) ÷ Int(comp.v)
    scratch = bands.scratch
    if method === :h2v1_fancy
        l0 = mod(_jpeg_prow(min(orow ÷ vex, dh - 1), dh) - 1, N) + 1
        _jpeg_h2v1_fancy_row!(scratch, ring, l0, dw)
        @inbounds for x in 1:W
            u[or_, x] = scratch[x]
        end
    elseif method === :h2v1_box
        l0 = mod(_jpeg_prow(min(orow, dh - 1), dh) - 1, N) + 1
        @inbounds for x in 1:W
            u[or_, x] = ring[l0, ((x - 1) >> 1) + 1]
        end
    elseif method === :h1v2_fancy
        inrow = orow >> 1
        l0 = mod(_jpeg_prow(inrow, dh) - 1, N) + 1
        l1 = mod(_jpeg_prow(inrow + (orow & 1 == 0 ? -1 : 1), dh) - 1, N) + 1
        bias = orow & 1 == 0 ? 1 : 2
        @inbounds for x in 1:dw
            u[or_, x] = UInt8((Int32(ring[l0, x]) * 3 +
                               Int32(ring[l1, x]) + bias) >> 2)
        end
    elseif method === :h2v2_fancy
        inrow = orow >> 1
        l0 = mod(_jpeg_prow(inrow, dh) - 1, N) + 1
        l1 = mod(_jpeg_prow(inrow + (orow & 1 == 0 ? -1 : 1), dh) - 1, N) + 1
        _jpeg_h2v2_fancy_row!(scratch, ring, l0, l1, dw)
        @inbounds for x in 1:W
            u[or_, x] = scratch[x]
        end
    elseif method === :h2v2_box
        l0 = mod(_jpeg_prow(orow >> 1, dh) - 1, N) + 1
        @inbounds for x in 1:W
            u[or_, x] = ring[l0, ((x - 1) >> 1) + 1]
        end
    else                                       # :int box upsample
        l0 = mod(_jpeg_prow(min(orow ÷ vex, dh - 1), dh) - 1, N) + 1
        @inbounds for x in 1:W
            u[or_, x] = ring[l0, min((x - 1) ÷ hex, dw - 1) + 1]
        end
    end
    return nothing
end

# Upsample + color-convert output rows [b*bo, min((b+1)*bo, H)) of band b.
function _jpeg_emit_band!(st::_JpegState, bands::_JpegBands, out, b::Int)
    bo = Int(st.max_v) * 8
    y0 = b * bo
    y1 = min((b + 1) * bo, st.H)
    nr = y1 - y0
    for ci in 1:st.ncomp
        for j in 1:nr
            _jpeg_upsample_outrow!(st, bands, ci, y0 + j - 1, j)
        end
    end
    _jpeg_color_convert!(st, bands.ustage, out, y0 + 1, nr)
    return nothing
end

function _jpeg_decode_scan_streamed!(st::_JpegState, bands::_JpegBands, out)
    _jpeg_per_scan_setup!(st)
    _jpeg_latch_quant!(st)
    _jpeg_start_scan!(st)
    single = length(st.scan_comps) == 1
    v = single ? Int(st.comps[st.scan_comps[1]].v) : 1
    lastrow = single ? Int(st.comps[st.scan_comps[1]].last_row_height) : 1
    last_imcu = st.total_imcu_rows - 1
    for imcu in 0:last_imcu
        rows_this = single ? (imcu < last_imcu ? v : lastrow) : 1
        for yoff in 0:(rows_this - 1)
            for mcu_col in 0:(st.MCUs_per_row - 1)
                _jpeg_decode_mcu!(st, imcu, yoff, mcu_col)
            end
        end
        _jpeg_render_band!(st, bands, imcu)
        imcu > 0 && _jpeg_emit_band!(st, bands, out, imcu - 1)
    end
    _jpeg_emit_band!(st, bands, out, last_imcu)
    st.pos = st.epos
    return nothing
end

# ------------------------------ top-level driver ----------------------------

# Count SOS markers by walking the segment structure (entropy data is
# guaranteed marker-clean by 0xFF00 stuffing).  Used only to decide whether
# the single-scan band-streaming path applies; a corrupt file that fools the
# count still errors out through the normal checks.
function _jpeg_count_scans(data::Vector{UInt8})
    len = length(data)
    p = 3
    ns = 0
    entropy = false
    while p <= len
        while p <= len && data[p] != 0xFF
            p += 1
        end
        p > len && break
        while p + 1 <= len && data[p + 1] == 0xFF
            p += 1
        end
        p + 1 > len && break
        m = data[p + 1]
        p += 2
        if entropy
            m == 0x00 && continue
            0xD0 <= m <= 0xD7 && continue
            entropy = false
        else
            m == 0x00 && continue
        end
        if m == 0xD8 || m == 0xD9 || m == 0x01 || (0xD0 <= m <= 0xD7)
            continue
        end
        p + 1 > len && break
        slen = (Int(data[p]) << 8) | Int(data[p + 1])
        slen < 2 && break
        p += slen
        if m == 0xDA
            ns += 1
            entropy = true
        end
    end
    return ns
end

# Decode `bytes` to an H x W x 3 RGB array of element type T (UInt8 or
# Float64; Float64 entries are the exact Float64(N0f8) values), or throw on
# any stream the decoder does not support or that is corrupt.
function _jpeg_decode_impl(bytes::AbstractVector{UInt8},
                           ::Type{T}) where {T<:Union{UInt8,Float64}}
    data = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    length(data) >= 4 || error("not a JPEG file")
    (data[1] == 0xFF && data[2] == 0xD8) || error("not a JPEG file")
    st = _JpegState(data)
    st.nscans = _jpeg_count_scans(data)
    st.pos = 3
    saw_scan = false
    out = Array{T,3}(undef, 0, 0, 0)
    local bands::_JpegBands
    while true
        m = if st.unread_marker != 0
            marker = st.unread_marker
            st.unread_marker = Int32(0)
            marker
        else
            _jpeg_next_marker(st, false)
        end
        if m == _JPEG_SOI
            error("JPEG has a duplicate SOI marker")
        elseif m == _JPEG_SOF0 || m == _JPEG_SOF1 || m == _JPEG_SOF2
            _jpeg_get_sof!(st, m)
        elseif m == _JPEG_SOF3 || m == _JPEG_SOF7 || m == _JPEG_SOF11 ||
               m == _JPEG_SOF15
            error("JPEG lossless coding (marker 0x$(string(m; base=16))) is not supported")
        elseif m == _JPEG_SOF5 || m == _JPEG_SOF6 ||
               m == _JPEG_SOF13 || m == _JPEG_SOF14
            error("JPEG differential coding (marker 0x$(string(m; base=16))) is not supported")
        elseif m == _JPEG_SOF9 || m == _JPEG_SOF10
            error("JPEG arithmetic coding (marker 0x$(string(m; base=16))) is not supported")
        elseif m == _JPEG_SOS
            _jpeg_get_sos!(st)
            if st.input_scan_number == 1
                _jpeg_initial_setup!(st)
            end
            if st.streaming
                if st.input_scan_number > 1
                    error("JPEG contains more scan data than declared")
                end
                if st.input_scan_number == 1
                    out = Array{T,3}(undef, st.H, st.W, 3)
                    bands = _jpeg_band_setup!(st)
                end
                _jpeg_decode_scan_streamed!(st, bands, out)
            else
                _jpeg_decode_scan!(st)
            end
            saw_scan = true
        elseif m == _JPEG_EOI
            break
        elseif m == _JPEG_DHT
            _jpeg_get_dht!(st)
        elseif m == _JPEG_DQT
            _jpeg_get_dqt!(st)
        elseif m == _JPEG_DRI
            _jpeg_get_dri!(st)
        elseif m == _JPEG_DAC
            _jpeg_skip(st, _jpeg_seglen(st, "DAC"))
        elseif m >= _JPEG_APP0 && m <= _JPEG_APP0 + 15
            _jpeg_appn!(st, m)
        elseif m == _JPEG_COM || m == _JPEG_DNL
            _jpeg_skip(st, _jpeg_seglen(st, "segment"))
        elseif m >= _JPEG_RST0 && m <= _JPEG_RST0 + 7 || m == _JPEG_TEM
            # parameterless markers between scans: ignored
        else
            error("JPEG marker 0x$(string(m; base=16)) is not supported")
        end
    end
    st.saw_SOF || error("JPEG has no image (no SOF marker)")
    saw_scan || error("JPEG has no scan data (no SOS marker)")
    st.streaming && return out
    # Render planes, upsample, convert color.
    ws32 = Vector{Int32}(undef, 64)
    planes = Vector{Matrix{UInt8}}(undef, st.ncomp)
    for (ci, comp) in enumerate(st.comps)
        ph = st.total_imcu_rows * Int(comp.v) * 8
        pw = comp.width_in_blocks * 8
        planes[ci] = zeros(UInt8, ph, pw)
    end
    _jpeg_render_planes!(st, planes, ws32)
    uplines = [Matrix{UInt8}(undef, st.H, st.W) for _ in 1:st.ncomp]
    scratch = Vector{UInt8}(undef, st.W * Int(st.max_h) + 16)
    for ci in 1:st.ncomp
        _jpeg_upsample!(st, st.comps[ci], planes[ci], uplines[ci], scratch)
    end
    out = Array{T,3}(undef, st.H, st.W, 3)
    _jpeg_color_convert!(st, uplines, out, 1, st.H)
    return out
end

_jpeg_decode_rgb8(bytes::AbstractVector{UInt8}) =
    _jpeg_decode_impl(bytes, UInt8)

# Decode to Float64 [0, 1] samples identical to Float64(reinterpret(N0f8, v))
# on the UInt8 path, without materializing the H x W x 3 UInt8 intermediate.
_jpeg_decode_float64(bytes::AbstractVector{UInt8}) =
    _jpeg_decode_impl(bytes, Float64)
