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

"""
    load_png(path) -> Array{Float64,3}

Decode an 8-bit or 16-bit PNG (grayscale, RGB, or RGBA) to an H×W×C array in [0,1].
Implements full INFLATE (stored/fixed/dynamic Huffman) and all five PNG filters.
"""
function _decode_png(bytes::Vector{UInt8})
    bytes[1:8] == UInt8[137,80,78,71,13,10,26,10] || error("not a PNG file")
    pos = 9; W = 0; H = 0; bitdepth = 8; colortype = 2; interlace = 0
    idat = UInt8[]
    while pos <= length(bytes)
        len = _rd_be32(bytes, pos); pos += 4
        ctype = String(bytes[pos:pos+3]); pos += 4
        if ctype == "IHDR"
            W = _rd_be32(bytes, pos); H = _rd_be32(bytes, pos+4)
            bitdepth = bytes[pos+8]; colortype = bytes[pos+9]
            interlace = bytes[pos+12]
        elseif ctype == "IDAT"
            append!(idat, @view bytes[pos:pos+len-1])
        elseif ctype == "IEND"
            break
        end
        pos += len + 4                          # data + CRC
    end
    (bitdepth == 8 || bitdepth == 16) || error("only 8-bit and 16-bit PNG decode is supported")
    interlace == 0 || error("interlaced (Adam7) PNG decode is not supported")
    channels = colortype == 0 ? 1 : colortype == 2 ? 3 : colortype == 6 ? 4 :
               error("unsupported PNG color type $colortype")
    bps = bitdepth ÷ 8                          # bytes per sample
    bpp = channels * bps                        # bytes per pixel (filter window)
    raw = zlib_inflate(idat)
    stride = W * bpp
    img = Array{Float64}(undef, H, W, channels)
    norm = bitdepth == 16 ? 65535.0 : 255.0
    prev = zeros(UInt8, stride)
    p = 1
    for row in 1:H
        ftype = raw[p]; p += 1
        cur = Vector{UInt8}(raw[p:p+stride-1]); p += stride
        # Unfilter in place (filter window is one pixel = bpp bytes).
        for i in 1:stride
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
        for j in 1:W, c in 1:channels
            base = (j-1)*bpp + (c-1)*bps + 1
            img[row, j, c] = bps == 2 ? ((Int(cur[base]) << 8) | Int(cur[base+1])) / norm :
                                        cur[base] / norm
        end
        prev = cur
    end
    return img
end

function load_png(path::String)
    _decode_png(read(path))
end

"""Load a PNG into a [`Texture`]."""
TextureLoader(path::String; kwargs...) = Texture(load_png(path); kwargs...)

# ========================== OBJ .mtl materials ==========================

"""
    load_mtl(path) -> Dict{String, MeshPhongMaterial}

Parse a Wavefront .mtl file: `newmtl`, `Kd` (diffuse), `Ks` (specular),
`Ns` (shininess), `Ke` (emissive), `d`/`Tr` (opacity).
"""
function load_mtl(path::String)
    mats = Dict{String, MeshPhongMaterial}()
    name = ""
    kd = Color3(1.0,1.0,1.0); ks = Color3(0.0,0.0,0.0); ke = Color3(0.0,0.0,0.0)
    ns = 30.0; d = 1.0
    function flush!()
        isempty(name) && return
        mats[name] = MeshPhongMaterial(color=kd, specular=ks, emissive=ke, shininess=ns,
                                       opacity=d, transparent=(d < 1.0))
    end
    for raw in eachline(path)
        t = split(strip(raw))
        isempty(t) && continue
        tag = t[1]
        if tag == "newmtl"
            flush!()
            name = t[2]; kd = Color3(1.0,1.0,1.0); ks = Color3(0.0,0.0,0.0)
            ke = Color3(0.0,0.0,0.0); ns = 30.0; d = 1.0
        elseif tag == "Kd"; kd = Color3(parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "Ks"; ks = Color3(parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "Ke"; ke = Color3(parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "Ns"; ns = parse(Float64, t[2])
        elseif tag == "d";  d = parse(Float64, t[2])
        elseif tag == "Tr"; d = 1.0 - parse(Float64, t[2])
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
    verts = Float64[]; file_normals = Float64[]
    out_pos = Float64[]; out_nrm = Float64[]; indices = Int[]
    face_mtl = String[]
    have_normals = false; out_vi = 0; cur_mtl = ""
    materials = Dict{String, MeshPhongMaterial}()
    parse_index(tok, n) = (i = parse(Int, tok); i < 0 ? n + i + 1 : i)
    dir = dirname(path)
    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        t = split(line); tag = t[1]
        if tag == "v"
            push!(verts, parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4]))
        elseif tag == "vn"
            push!(file_normals, parse(Float64,t[2]), parse(Float64,t[3]), parse(Float64,t[4])); have_normals = true
        elseif tag == "mtllib"
            mp = joinpath(dir, t[2]); isfile(mp) && merge!(materials, load_mtl(mp))
        elseif tag == "usemtl"
            cur_mtl = t[2]
        elseif tag == "f"
            nv = length(verts) ÷ 3; nn = length(file_normals) ÷ 3
            corners = t[2:end]
            for k in 2:(length(corners) - 1)
                for c in (corners[1], corners[k], corners[k+1])
                    sub = split(c, '/')
                    vidx = parse_index(sub[1], nv); base = (vidx-1)*3
                    push!(out_pos, verts[base+1], verts[base+2], verts[base+3])
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
    geo = BufferGeometry(out_pos, out_nrm, Float64[], indices, out_vi, nfaces)
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

# ========================== glTF 2.0 ==========================

const _GLTF_COMP_SIZE = Dict("SCALAR"=>1, "VEC2"=>2, "VEC3"=>3, "VEC4"=>4, "MAT4"=>16)

struct GLTFAsset
    scene::Scene
    animations::Vector{AnimationClip}
end

function _gltf_read_buffer(buf::Dict, dir::String)
    uri = get(buf, "uri", nothing)
    uri === nothing && error("glTF buffer without uri; use load_glb for binary .glb containers")
    data = if startswith(uri, "data:")
        base64_decode(split(uri, ",", limit=2)[2])
    else
        read(joinpath(dir, uri))
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

function _gltf_texture(gltf, buffers, dir::String, texinfo; colorspace::Symbol=:srgb)
    texinfo === nothing && return nothing
    haskey(gltf, "textures") || return nothing
    ti = Int(texinfo["index"])
    texdef = gltf["textures"][ti + 1]
    haskey(texdef, "source") || return nothing
    imgdef = gltf["images"][Int(texdef["source"]) + 1]
    bytes = if haskey(imgdef, "uri")
        uri = String(imgdef["uri"])
        startswith(uri, "data:") ? base64_decode(split(uri, ",", limit=2)[2]) : read(joinpath(dir, uri))
    elseif haskey(imgdef, "bufferView")
        bv = gltf["bufferViews"][Int(imgdef["bufferView"]) + 1]
        buf = buffers[Int(bv["buffer"]) + 1]
        off = Int(get(bv, "byteOffset", 0.0)) + 1
        len = Int(bv["byteLength"])
        buf[off:(off + len - 1)]
    else
        return nothing
    end
    data = _decode_png(bytes)
    # glTF UV (0,0) is the TOP-left corner, but the engine samples with a
    # bottom-left origin (the 1-v flip in `sample_texture`). Reverse the rows so
    # raw glTF UVs sample correctly — the flipY=false equivalent of three.js
    # GLTFLoader. KHR_texture_transform stays correct because
    # `texture_transform_uv` runs on the untouched glTF-space UVs.
    data = data[end:-1:1, :, :]
    sampler = haskey(texdef, "sampler") && haskey(gltf, "samplers") ?
              gltf["samplers"][Int(texdef["sampler"]) + 1] : Dict{String,Any}()
    offset, scale, rotation, tex_coord = _gltf_texture_transform(texinfo)
    Texture(data;
            wrap_s=_gltf_wrap_mode(get(sampler, "wrapS", 10497.0)),
            wrap_t=_gltf_wrap_mode(get(sampler, "wrapT", 10497.0)),
            filter=_gltf_filter_mode(get(sampler, "magFilter", get(sampler, "minFilter", 9729.0))),
            colorspace=colorspace,
            offset=offset,
            repeat=scale,
            rotation=rotation,
            tex_coord=tex_coord)
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
    metallic_roughness_texture = _gltf_texture(gltf, buffers, dir,
                                               get(pbr, "metallicRoughnessTexture", nothing);
                                               colorspace=:linear)
    normal_info = get(m, "normalTexture", nothing)
    normal_scale = normal_info isa AbstractDict ? Float64(get(normal_info, "scale", 1.0)) : 1.0
    occ = get(m, "occlusionTexture", nothing)
    emissive_strength = Float64(get(get(extensions, "KHR_materials_emissive_strength",
                                        Dict{String,Any}()), "emissiveStrength", 1.0))
    ao_strength = occ isa AbstractDict ? Float64(get(occ, "strength", 1.0)) : 1.0
    physical_extension_keys = ("KHR_materials_clearcoat",
                               "KHR_materials_transmission",
                               "KHR_materials_ior",
                               "KHR_materials_volume",
                               "KHR_materials_sheen",
                               "KHR_materials_iridescence",
                               "KHR_materials_specular")
    if any(k -> haskey(extensions, k), physical_extension_keys)
        clearcoat_ext = get(extensions, "KHR_materials_clearcoat", Dict{String,Any}())
        transmission_ext = get(extensions, "KHR_materials_transmission", Dict{String,Any}())
        ior_ext = get(extensions, "KHR_materials_ior", Dict{String,Any}())
        volume_ext = get(extensions, "KHR_materials_volume", Dict{String,Any}())
        sheen_ext = get(extensions, "KHR_materials_sheen", Dict{String,Any}())
        iridescence_ext = get(extensions, "KHR_materials_iridescence", Dict{String,Any}())
        specular_ext = get(extensions, "KHR_materials_specular", Dict{String,Any}())
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
                                                                     colorspace=:srgb))
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

function _gltf_joint_node_set(gltf)
    out = Set{Int}()
    for skin in get(gltf, "skins", Any[])
        for j in get(skin, "joints", Any[])
            push!(out, Int(j))
        end
    end
    return out
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
    scene = Scene()
    node_objects = Dict{Int, AbstractObject3D}()
    joint_nodes = _gltf_joint_node_set(gltf)

    function build_primitive(prim, skin_idx=nothing, morph_weights=Float64[])
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
        geo = BufferGeometry(pos, normals, uvs, indices, nverts, length(indices) ÷ 3)
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
        isempty(normals) && compute_vertex_normals!(geo)
        mat = _gltf_material(gltf, buffers, dir, get(prim, "material", nothing))
        if skin_idx === nothing
            return Mesh(geo, mat; morph_target_influences=morph_weights)
        end
        skin = gltf["skins"][Int(skin_idx) + 1]
        bones = Bone[]
        for j in skin["joints"]
            bone = node_objects[Int(j)]
            bone isa Bone || error("glTF skin joint node was not loaded as a Bone")
            push!(bones, bone)
        end
        inv = _gltf_inverse_bind_matrices(gltf, buffers, skin, length(bones))
        skeleton = inv === nothing ? Skeleton(bones) : Skeleton(bones, inv)
        skin_indices = _gltf_skin_tuples(geo, :skinIndex, nverts; indices=true)
        skin_weights = _gltf_skin_tuples(geo, :skinWeight, nverts)
        return SkinnedMesh(geo, mat, skeleton, skin_indices, skin_weights;
                           morph_target_influences=morph_weights)
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

    function add_node!(parent, node_idx)
        node = gltf["nodes"][node_idx + 1]
        obj = node_objects[node_idx]
        add!(parent, obj)
        if haskey(node, "mesh")
            mesh_def = gltf["meshes"][Int(node["mesh"]) + 1]
            morph_weights = Float64.(get(node, "weights", get(mesh_def, "weights", Float64[])))
            for prim in mesh_def["primitives"]
                add!(obj, build_primitive(prim, get(node, "skin", nothing), morph_weights))
            end
        end
        for child in get(node, "children", Any[])
            add_node!(obj, Int(child))
        end
    end

    scene_def = gltf["scenes"][Int(get(gltf, "scene", 0.0)) + 1]
    for n in scene_def["nodes"]
        add_node!(scene, Int(n))
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
    dir = dirname(path)
    buffers = [_gltf_read_buffer(b, dir) for b in _gltf_document_buffers(gltf)]
    return _gltf_build_asset(gltf, buffers; dir=dir)
end

# Resolve a glTF buffer that may reference the GLB binary chunk. A buffer with no
# `uri` is the embedded GLB binary buffer (buffer 0 by spec); otherwise behave
# exactly like `_gltf_read_buffer`.
function _glb_read_buffer(buf::Dict, dir::String, bin::Vector{UInt8})
    uri = get(buf, "uri", nothing)
    data = if uri === nothing
        bin
    elseif startswith(uri, "data:")
        base64_decode(split(uri, ",", limit=2)[2])
    else
        read(joinpath(dir, uri))
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
