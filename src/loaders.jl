# --------------------------------------------------------------------------
# Mesh loaders/writers: STL (binary + ASCII) and OBJ, plus smooth-normal
# computation. Loaders return a BufferGeometry usable by the rasterizer.
# Pure Julia, no external dependencies.
# --------------------------------------------------------------------------

function _compute_vertex_normals_scaled!(
        acc::Vector{Float64}, geo::BufferGeometry, degenerate_normal::Vec3)
    fill!(acc, 0.0)
    no_exponent = typemin(Int)
    normal_exponents = fill(no_exponent, geo.n_vertices)
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1)
        v2 = get_vertex(geo, i2)
        v3 = get_vertex(geo, i3)
        face_normal = _float_representation_cross(
            _float_vector_difference(v1, v2),
            _float_vector_difference(v1, v3),
        )
        face_exponent = no_exponent
        for component in face_normal
            component.nonzero &&
                (face_exponent = max(
                    face_exponent, component.exponent))
        end
        face_exponent == no_exponent && continue

        for idx in (i1, i2, i3)
            base = (idx - 1) * 3
            vertex_exponent = normal_exponents[idx]
            if vertex_exponent == no_exponent
                vertex_exponent = face_exponent
                normal_exponents[idx] = vertex_exponent
            elseif face_exponent > vertex_exponent
                rescale = ldexp(
                    1.0, vertex_exponent - face_exponent)
                acc[base+1] *= rescale
                acc[base+2] *= rescale
                acc[base+3] *= rescale
                vertex_exponent = face_exponent
                normal_exponents[idx] = vertex_exponent
            end
            for axis in 1:3
                component = face_normal[axis]
                component.nonzero || continue
                acc[base+axis] += ldexp(
                    component.mantissa,
                    component.exponent - vertex_exponent)
            end
        end
    end

    @inbounds for vi in 1:geo.n_vertices
        base = (vi - 1) * 3
        nx, ny, nz = acc[base+1], acc[base+2], acc[base+3]
        len = _norm3(nx, ny, nz)
        if !iszero(len)
            acc[base+1] = nx / len
            acc[base+2] = ny / len
            acc[base+3] = nz / len
        else
            acc[base+1] = degenerate_normal.x
            acc[base+2] = degenerate_normal.y
            acc[base+3] = degenerate_normal.z
        end
    end
    return acc
end

"""
    compute_vertex_normals!(geo) -> geo

Recompute per-vertex normals as the area-weighted average of adjacent face
normals (smooth normals).  Overwrites `geo.normals`.
"""
function compute_vertex_normals!(geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "compute_vertex_normals!")
    nv = geo.n_vertices
    acc = if length(geo.normals) == nv * 3 &&
             geo.normals !== geo.positions && geo.normals !== geo.uvs
        geo.normals
    else
        Vector{Float64}(undef, nv * 3)
    end
    _compute_vertex_normals!(acc, geo, Vec3(0.0, 0.0, 1.0))
    geo.normals = acc
    return geo
end

function _compute_vertex_normals!(acc::Vector{Float64}, geo::BufferGeometry,
                                   degenerate_normal::Vec3)
    fill!(acc, 0.0)
    needs_scaled_fallback = false
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        (isfinite(v1.x) && isfinite(v1.y) && isfinite(v1.z) &&
         isfinite(v2.x) && isfinite(v2.y) && isfinite(v2.z) &&
         isfinite(v3.x) && isfinite(v3.y) && isfinite(v3.z)) ||
            throw(ArgumentError(
                "compute_vertex_normals! positions must be finite"))
        # Cross product is proportional to face area, giving area weighting.
        fn = cross(v2 - v1, v3 - v1)
        needs_scaled_fallback |=
            !(isfinite(fn.x) && isfinite(fn.y) && isfinite(fn.z))
        if max(abs(fn.x), abs(fn.y), abs(fn.z)) < floatmin(Float64)
            # Subnormal areas lose relative precision, and a nondegenerate
            # face may round completely to zero. Test the scaled cross product
            # so ordinary degenerate triangles do not allocate a fallback.
            area = _float_representation_cross(
                _float_vector_difference(v1, v2),
                _float_vector_difference(v1, v3))
            needs_scaled_fallback |= any(component -> component.nonzero, area)
        end
        for idx in (i1, i2, i3)
            base = (idx - 1) * 3
            nx = acc[base+1] + fn.x
            ny = acc[base+2] + fn.y
            nz = acc[base+3] + fn.z
            needs_scaled_fallback |=
                !(isfinite(nx) && isfinite(ny) && isfinite(nz))
            acc[base+1] = nx
            acc[base+2] = ny
            acc[base+3] = nz
        end
    end

    if needs_scaled_fallback
        # A face cross product, or the area-weighted sum of several faces, can
        # exceed or underflow Float64 although its direction is representable. Keep
        # one shared binary exponent per vertex and accumulate scaled mantissas
        # only on this exceptional path. Ordinary meshes retain the allocation-
        # free buffer-reuse path above.
        return _compute_vertex_normals_scaled!(acc, geo, degenerate_normal)
    end

    @inbounds for vi in 1:geo.n_vertices
        base = (vi - 1) * 3
        nx, ny, nz = acc[base+1], acc[base+2], acc[base+3]
        n = iszero(nx) && iszero(ny) && iszero(nz) ? degenerate_normal :
            normalize(Vec3(nx, ny, nz))
        acc[base+1] = n.x; acc[base+2] = n.y; acc[base+3] = n.z
    end
    return acc
end

# ========================== STL ==========================

const _STL_BINARY_ZERO_HEADER = zeros(UInt8, 80)
const _STL_BINARY_FACET_BYTES = 50

@inline function _stl_header_solid_at(head::Vector{UInt8}, off::Int)
    @inbounds return head[off + 1] == UInt8('s') &&
                      head[off + 2] == UInt8('o') &&
                      head[off + 3] == UInt8('l') &&
                      head[off + 4] == UInt8('i') &&
                      head[off + 5] == UInt8('d')
end

@inline function _stl_put_u16_le!(buf::Vector{UInt8}, off::Int, x::UInt16)
    @inbounds begin
        buf[off] = UInt8(x & 0xff)
        buf[off + 1] = UInt8((x >> 8) & 0xff)
    end
    return nothing
end

@inline function _stl_put_u32_le!(buf::Vector{UInt8}, off::Int, x::UInt32)
    @inbounds begin
        buf[off] = UInt8(x & 0xff)
        buf[off + 1] = UInt8((x >> 8) & 0xff)
        buf[off + 2] = UInt8((x >> 16) & 0xff)
        buf[off + 3] = UInt8((x >> 24) & 0xff)
    end
    return nothing
end

@inline _stl_put_f32_le!(buf::Vector{UInt8}, off::Int, x::Real) =
    _stl_put_u32_le!(buf, off, reinterpret(UInt32, Float32(x)))

@inline function _stl_fill_facet_record!(buf::Vector{UInt8}, n::Vec3, v1::Vec3, v2::Vec3, v3::Vec3)
    _stl_put_f32_le!(buf, 1, n.x)
    _stl_put_f32_le!(buf, 5, n.y)
    _stl_put_f32_le!(buf, 9, n.z)
    _stl_put_f32_le!(buf, 13, v1.x)
    _stl_put_f32_le!(buf, 17, v1.y)
    _stl_put_f32_le!(buf, 21, v1.z)
    _stl_put_f32_le!(buf, 25, v2.x)
    _stl_put_f32_le!(buf, 29, v2.y)
    _stl_put_f32_le!(buf, 33, v2.z)
    _stl_put_f32_le!(buf, 37, v3.x)
    _stl_put_f32_le!(buf, 41, v3.y)
    _stl_put_f32_le!(buf, 45, v3.z)
    _stl_put_u16_le!(buf, 49, UInt16(0))
    return nothing
end

@inline function _stl_facet_data(geo::BufferGeometry, fi::Int)
    i1, i2, i3 = get_face(geo, fi)
    v1 = get_vertex(geo, i1)
    v2 = get_vertex(geo, i2)
    v3 = get_vertex(geo, i3)
    n = normalize(cross(v2 - v1, v3 - v1))
    return n, v1, v2, v3
end

@inline _stl_finite_f32(value::Float64) = isfinite(Float32(value))

@noinline function _throw_stl_position_f32(fi::Int, corner::Int, axis::Symbol)
    throw(ArgumentError(
        "save_stl_binary face $fi vertex $corner $axis must be representable as finite Float32"))
end

@noinline function _throw_stl_normal_f32(fi::Int, axis::Symbol)
    throw(ArgumentError(
        "save_stl_binary face $fi normal $axis must be representable as finite Float32"))
end

@inline function _validate_stl_position_f32(v::Vec3{Float64}, fi::Int,
                                            corner::Int)
    _stl_finite_f32(v.x) || _throw_stl_position_f32(fi, corner, :x)
    _stl_finite_f32(v.y) || _throw_stl_position_f32(fi, corner, :y)
    _stl_finite_f32(v.z) || _throw_stl_position_f32(fi, corner, :z)
    return nothing
end

function _validate_stl_binary_payload(geo::BufferGeometry)
    @inbounds for fi in 1:geo.n_faces
        n, v1, v2, v3 = _stl_facet_data(geo, fi)
        _validate_stl_position_f32(v1, fi, 1)
        _validate_stl_position_f32(v2, fi, 2)
        _validate_stl_position_f32(v3, fi, 3)
        _stl_finite_f32(n.x) || _throw_stl_normal_f32(fi, :x)
        _stl_finite_f32(n.y) || _throw_stl_normal_f32(fi, :y)
        _stl_finite_f32(n.z) || _throw_stl_normal_f32(fi, :z)
    end
    return nothing
end

"""
    save_stl_binary(path, geo) -> path

Write `geo` as a binary STL file (per-triangle facet normals computed from
geometry).  Round-trips with [`load_stl`](@ref).
"""
function save_stl_binary(path::String, geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "save_stl_binary")
    geo.n_faces <= typemax(UInt32) ||
        throw(ArgumentError("save_stl_binary supports at most $(typemax(UInt32)) faces"))
    _validate_stl_binary_payload(geo)
    record = Vector{UInt8}(undef, _STL_BINARY_FACET_BYTES)
    open(path, "w") do io
        write(io, _STL_BINARY_ZERO_HEADER)          # 80-byte header
        _stl_put_u32_le!(record, 1, UInt32(geo.n_faces))
        unsafe_write(io, pointer(record), UInt(4))
        @inbounds for fi in 1:geo.n_faces
            n, v1, v2, v3 = _stl_facet_data(geo, fi)
            _stl_fill_facet_record!(record, n, v1, v2, v3)
            write(io, record)
        end
    end
    return path
end

function _looks_binary_stl(path::String)
    sz = filesize(path)
    sz < 84 && return false
    head, ntri = open(path, "r") do io
        h = read(io, 80)
        (h, read(io, UInt32))
    end
    sz == 84 + 50 * Int(ntri) && return true       # exact binary STL size
    # Size mismatch (e.g. trailing junk bytes appended by an exporter): mirror
    # three.js STLLoader and classify as ASCII only when the header spells
    # "solid" near the start (offsets 0-4 tolerate a BOM); otherwise binary.
    for off in 0:4
        _stl_header_solid_at(head, off) && return false
    end
    return true
end

"""
    load_stl(path) -> BufferGeometry

Load an STL mesh, auto-detecting binary vs ASCII.  Each triangle contributes
three independent vertices; call [`compute_vertex_normals!`](@ref) afterward
for smooth shading.

A binary file whose header contains a `COLOR=rgba` sequence gets a per-vertex
`:color` attribute, as in three.js `STLLoader`: each facet uses its own 5-bit
RGB from the attribute word when bit 15 is clear, and the header colour
otherwise. Colours are converted from sRGB to linear. The header alpha byte is
not stored.
"""
function load_stl(path::String)
    _looks_binary_stl(path) && return _load_stl_binary(path)
    geo = _load_stl_ascii(path)
    # Only an ASCII solid may legitimately contain no facets.
    geo.n_faces == 0 &&
        !_stl_keyword(lstrip(c -> isspace(c) || c == '\ufeff', read(path, String)), "solid") &&
        error("$path is not an STL file: no binary layout, solid header, or facets")
    return geo
end

@inline function _stl_keyword(line::AbstractString, word::String)
    startswith(line, word) || return false
    n = ncodeunits(word)
    return ncodeunits(line) == n || isspace(line[nextind(line, n)])
end

# Default facet colour from a Materialise-style "COLOR=rgba" header sequence,
# as STLLoader.js parseBinary scans it: every start offset 0..69 is tested and
# the last match wins. Returns `nothing` when the header has no such sequence.
function _stl_header_default_color(head::Vector{UInt8})
    found = nothing
    @inbounds for off in 0:69
        head[off + 1] == UInt8('C') && head[off + 2] == UInt8('O') &&
            head[off + 3] == UInt8('L') && head[off + 4] == UInt8('O') &&
            head[off + 5] == UInt8('R') && head[off + 6] == UInt8('=') || continue
        found = (head[off + 7], head[off + 8], head[off + 9])
    end
    return found
end

@inline _stl_f32_le(rec::Vector{UInt8}, off::Int) =
    @inbounds Float64(reinterpret(Float32,
        UInt32(rec[off]) | (UInt32(rec[off + 1]) << 8) |
        (UInt32(rec[off + 2]) << 16) | (UInt32(rec[off + 3]) << 24)))

function _load_stl_binary(path::String)
    open(path, "r") do io
        head = read(io, 80)
        ntri = Int(read(io, UInt32))
        # A binary STL is exactly 84 + 50*ntri bytes; reject a truncated/corrupt
        # file (or absurd count) before allocating ntri*9 floats / reading past EOF.
        filesize(path) >= 84 + 50 * ntri ||
            error("binary STL declares $ntri triangles but the file is only $(filesize(path)) bytes (truncated/corrupt)")
        positions = Vector{Float64}(undef, ntri * 9)
        normals = Vector{Float64}(undef, ntri * 9)
        indices = Vector{Int}(undef, ntri * 3)
        default_color = _stl_header_default_color(head)
        colors = default_color === nothing ? Float64[] : Vector{Float64}(undef, ntri * 9)
        rec = Vector{UInt8}(undef, _STL_BINARY_FACET_BYTES)
        p = 1; vi = 0
        for _ in 1:ntri
            readbytes!(io, rec, _STL_BINARY_FACET_BYTES) == _STL_BINARY_FACET_BYTES ||
                error("binary STL ended inside a facet record")
            nx = _stl_f32_le(rec, 1); ny = _stl_f32_le(rec, 5); nz = _stl_f32_le(rec, 9)
            isfinite(nx) || error("binary STL facet normal x must be finite")
            isfinite(ny) || error("binary STL facet normal y must be finite")
            isfinite(nz) || error("binary STL facet normal z must be finite")
            for v in 0:2
                x = _stl_f32_le(rec, 13 + 12v)
                y = _stl_f32_le(rec, 17 + 12v)
                z = _stl_f32_le(rec, 21 + 12v)
                isfinite(x) || error("binary STL vertex x must be finite")
                isfinite(y) || error("binary STL vertex y must be finite")
                isfinite(z) || error("binary STL vertex z must be finite")
                positions[p] = x; positions[p+1] = y; positions[p+2] = z
                normals[p] = nx; normals[p+1] = ny; normals[p+2] = nz
                p += 3; vi += 1; indices[vi] = vi
            end
            if default_color !== nothing
                # STLLoader.js parseBinary: attribute bit 15 clear means the facet
                # carries its own 5-bit RGB (red in bits 0-4); set means the header
                # default. Channels are sRGB and stored linear, like setRGB(...,
                # SRGBColorSpace).
                packed = UInt16(rec[49]) | (UInt16(rec[50]) << 8)
                r, g, b = if packed & 0x8000 == 0
                    ((packed & 0x1f) / 31, ((packed >> 5) & 0x1f) / 31,
                     ((packed >> 10) & 0x1f) / 31)
                else
                    (default_color[1] / 255, default_color[2] / 255,
                     default_color[3] / 255)
                end
                lr = srgb_to_linear(r); lg = srgb_to_linear(g); lb = srgb_to_linear(b)
                for c in (p - 9):3:(p - 3)
                    colors[c] = lr; colors[c + 1] = lg; colors[c + 2] = lb
                end
            end
        end
        geo = BufferGeometry(positions, normals, Float64[], indices, ntri * 3, ntri)
        default_color === nothing || set_attribute!(geo, :color, colors, 3)
        return geo
    end
end

@inline function _stl_token_is(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                               word::String)
    last - first + 1 == ncodeunits(word) || return false
    @inbounds for j in 1:ncodeunits(word)
        bytes[first + j - 1] == codeunit(word, j) || return false
    end
    return true
end

# Keywords of the ASCII STL grammar. A number slot that holds one of these (or
# the end of the file) means the record is short of components.
@inline function _stl_is_keyword(bytes::AbstractVector{UInt8}, first::Int, last::Int)
    for word in ("solid", "endsolid", "facet", "normal", "outer", "loop",
                 "vertex", "endloop", "endfacet")
        _stl_token_is(bytes, first, last, word) && return true
    end
    return false
end

@noinline function _stl_ascii_float_error(context::String, status::UInt8)
    status == UInt8(2) ? error("ASCII STL $context must be finite") :
                         error("ASCII STL $context must be a number")
end

# Read the next whitespace-separated token as a finite number. `short` is the
# error raised when the file ends or a keyword appears instead.
@inline function _stl_ascii_component(bytes::AbstractVector{UInt8}, p::Int, n::Int,
                                      short::String, context::String)
    first, last, p = _ply_next_ascii_token(bytes, p, n)
    (first == 0 || _stl_is_keyword(bytes, first, last)) && error(short)
    value, status = _try_parse_ascii_float(bytes, first, last)
    status == UInt8(0) || _stl_ascii_float_error(context, status)
    return value, p
end

# ASCII STL is parsed as a stream of whitespace-separated tokens, like the
# regular expressions in three.js STLLoader.js parseASCII (`facet`, `normal`
# and `vertex` followed by `\s+` and numbers): any mix of spaces, tabs, CR, LF
# or CRLF separates tokens, and a record may span lines. The text after
# `solid`/`endsolid` up to the end of that line is the solid name.
function _load_stl_ascii(path::String)
    text = read(path, String)
    bytes = codeunits(text)
    n = length(bytes)
    positions = Float64[]; normals = Float64[]; indices = Int[]
    nx = ny = nz = 0.0; vi = 0; vertices_in_facet = 0; in_facet = false
    p = 1
    if n >= 3 && bytes[1] == 0xef && bytes[2] == 0xbb && bytes[3] == 0xbf
        p = 4                                     # UTF-8 byte-order mark
    end
    while true
        first, last, p = _ply_next_ascii_token(bytes, p, n)
        first == 0 && break
        if _stl_token_is(bytes, first, last, "facet")
            !in_facet || error("ASCII STL nested facet is invalid")
            f2, l2, p = _ply_next_ascii_token(bytes, p, n)
            f2 != 0 && _stl_token_is(bytes, f2, l2, "normal") ||
                error("ASCII STL facet must be followed by normal")
            short = "ASCII STL facet normal requires 3 components"
            nx, p = _stl_ascii_component(bytes, p, n, short, "facet normal x")
            ny, p = _stl_ascii_component(bytes, p, n, short, "facet normal y")
            nz, p = _stl_ascii_component(bytes, p, n, short, "facet normal z")
            in_facet = true
            vertices_in_facet = 0
        elseif _stl_token_is(bytes, first, last, "vertex")
            in_facet || error("ASCII STL vertex appears outside a facet")
            vertices_in_facet < 3 || error("ASCII STL facet has more than 3 vertices")
            short = "ASCII STL vertex requires 3 coordinates"
            x, p = _stl_ascii_component(bytes, p, n, short, "vertex x")
            y, p = _stl_ascii_component(bytes, p, n, short, "vertex y")
            z, p = _stl_ascii_component(bytes, p, n, short, "vertex z")
            push!(positions, x, y, z)
            push!(normals, nx, ny, nz)
            vi += 1; push!(indices, vi)
            vertices_in_facet += 1
        elseif _stl_token_is(bytes, first, last, "endfacet")
            in_facet || error("ASCII STL endfacet appears outside a facet")
            vertices_in_facet == 3 ||
                error("ASCII STL facet has $vertices_in_facet vertices; expected 3")
            in_facet = false
            vertices_in_facet = 0
        elseif _stl_token_is(bytes, first, last, "solid") ||
               _stl_token_is(bytes, first, last, "endsolid")
            while p <= n && bytes[p] != UInt8('\n') && bytes[p] != UInt8('\r')
                p += 1
            end
        end
    end
    !in_facet || error("ASCII STL facet is missing endfacet")
    return BufferGeometry(positions, normals, Float64[], indices, vi, vi ÷ 3)
end

# ========================== OBJ ==========================

function _obj_index_count_label(kind::Symbol)
    kind === :vertex && return "vertices"
    kind === :uv && return "texture coordinates"
    kind === :normal && return "normals"
    return string(kind, "s")
end

function _obj_checked_index(tok, count::Int, kind::Symbol)
    label = _obj_index_label(kind)
    raw = _obj_parse_index_token(tok, kind)
    raw == 0 && error("OBJ $label index 0 is invalid")
    idx = raw < 0 ? count + raw + 1 : raw
    1 <= idx <= count ||
        error("OBJ $label index $raw out of bounds for $count $(_obj_index_count_label(kind))")
    return idx
end

function _obj_index_label(kind::Symbol)
    kind === :vertex && return "vertex"
    kind === :uv && return "uv"
    kind === :normal && return "normal"
    return String(kind)
end

function _obj_parse_index_token(tok, kind::Symbol)
    return _obj_parse_index_range(tok, firstindex(tok), lastindex(tok), kind)
end

function _obj_parse_index_range(tok::AbstractString, first_i::Int, last_i::Int, kind::Symbol)
    label = _obj_index_label(kind)
    first_i <= last_i || error("OBJ $label index must be an integer")
    i = first_i
    sign = 1
    ch = tok[i]
    if ch == '+' || ch == '-'
        sign = ch == '-' ? -1 : 1
        i = nextind(tok, i)
        i <= last_i || error("OBJ $label index must be an integer")
    end
    value = 0
    digits = false
    while i <= last_i
        ch = tok[i]
        '0' <= ch <= '9' || error("OBJ $label index must be an integer")
        digit = Int(ch - '0')
        value <= (typemax(Int) - digit) ÷ 10 ||
            error("OBJ $label index must be an integer")
        value = value * 10 + digit
        digits = true
        i = nextind(tok, i)
    end
    digits || error("OBJ $label index must be an integer")
    return sign < 0 ? -value : value
end

function _obj_checked_index_range(tok::AbstractString, first_i::Int, last_i::Int,
                                  count::Int, kind::Symbol)
    raw = _obj_parse_index_range(tok, first_i, last_i, kind)
    raw == 0 && error("OBJ $(_obj_index_label(kind)) index 0 is invalid")
    idx = raw < 0 ? count + raw + 1 : raw
    1 <= idx <= count ||
        error("OBJ $(_obj_index_label(kind)) index $raw out of bounds for $count $(_obj_index_count_label(kind))")
    return idx
end

function _obj_parse_corner(c::AbstractString, nverts_v::Int, nverts_uv::Int, nverts_n::Int)
    first_i = firstindex(c)
    last_i = lastindex(c)
    slash1 = findnext(==('/'), c, first_i)
    if slash1 === nothing
        return (_obj_checked_index_range(c, first_i, last_i, nverts_v, :vertex), 0, 0)
    end
    vidx = _obj_checked_index_range(c, first_i, prevind(c, slash1), nverts_v, :vertex)
    after1 = nextind(c, slash1)
    slash2 = after1 <= last_i ? findnext(==('/'), c, after1) : nothing
    if slash2 === nothing
        uidx = after1 <= last_i ? _obj_checked_index_range(c, after1, last_i, nverts_uv, :uv) : 0
        return (vidx, uidx, 0)
    end
    uidx = after1 < slash2 ? _obj_checked_index_range(c, after1, prevind(c, slash2), nverts_uv, :uv) : 0
    after2 = nextind(c, slash2)
    slash3 = after2 <= last_i ? findnext(==('/'), c, after2) : nothing
    normal_last = slash3 === nothing ? last_i : prevind(c, slash3)
    nidx = after2 <= normal_last ?
           _obj_checked_index_range(c, after2, normal_last, nverts_n, :normal) : 0
    return (vidx, uidx, nidx)
end

function _obj_find_slash_range(c::AbstractString, first_i::Int, last_i::Int)
    i = first_i
    while i <= last_i
        c[i] == '/' && return i
        i = nextind(c, i)
    end
    return nothing
end

function _obj_parse_corner_range(c::AbstractString, first_i::Int, last_i::Int,
                                 nverts_v::Int, nverts_uv::Int, nverts_n::Int)
    slash1 = _obj_find_slash_range(c, first_i, last_i)
    if slash1 === nothing
        return (_obj_checked_index_range(c, first_i, last_i, nverts_v, :vertex), 0, 0)
    end
    vidx = _obj_checked_index_range(c, first_i, prevind(c, slash1), nverts_v, :vertex)
    after1 = nextind(c, slash1)
    slash2 = after1 <= last_i ? _obj_find_slash_range(c, after1, last_i) : nothing
    if slash2 === nothing
        uidx = after1 <= last_i ? _obj_checked_index_range(c, after1, last_i, nverts_uv, :uv) : 0
        return (vidx, uidx, 0)
    end
    uidx = after1 < slash2 ? _obj_checked_index_range(c, after1, prevind(c, slash2), nverts_uv, :uv) : 0
    after2 = nextind(c, slash2)
    slash3 = after2 <= last_i ? _obj_find_slash_range(c, after2, last_i) : nothing
    normal_last = slash3 === nothing ? last_i : prevind(c, slash3)
    nidx = after2 <= normal_last ?
           _obj_checked_index_range(c, after2, normal_last, nverts_n, :normal) : 0
    return (vidx, uidx, nidx)
end

function _obj_next_token_range(line::AbstractString, i::Int, last_i::Int)
    while i <= last_i && isspace(line[i])
        i = nextind(line, i)
    end
    i <= last_i || return (0, 0, i, false)
    first_i = i
    while i <= last_i && !isspace(line[i])
        i = nextind(line, i)
    end
    return (first_i, prevind(line, i), i, true)
end

_obj_emit_corner!(out_pos::Vector{Float64}, out_uvs::Vector{Float64},
                  out_nrm::Vector{Float64}, indices::Vector{Int},
                  verts::Vector{Float64}, file_uvs::Vector{Float64},
                  file_normals::Vector{Float64}, corner::NTuple{3,Int},
                  out_vi::Int, have_uvs::Bool, have_normals::Bool,
                  missing_normals::Bool) =
    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts, file_uvs,
                      file_normals, corner, out_vi, have_uvs, have_normals,
                      missing_normals, nothing)

# `corner_vertices`, when a vector, receives the file vertex index of every
# emitted corner (load_obj uses it to expand per-vertex colours).
function _obj_emit_corner!(out_pos::Vector{Float64}, out_uvs::Vector{Float64},
                           out_nrm::Vector{Float64}, indices::Vector{Int},
                           verts::Vector{Float64}, file_uvs::Vector{Float64},
                           file_normals::Vector{Float64}, corner::NTuple{3,Int},
                           out_vi::Int, have_uvs::Bool, have_normals::Bool,
                           missing_normals::Bool,
                           corner_vertices::Union{Nothing,Vector{Int}})
    vidx, uidx, nidx = corner
    corner_vertices === nothing || push!(corner_vertices, vidx)
    @inbounds begin
        base = (vidx - 1) * 3
        push!(out_pos, verts[base + 1], verts[base + 2], verts[base + 3])
        if uidx != 0
            ub = (uidx - 1) * 2
            have_uvs || _obj_backfill_uvs!(out_uvs, out_vi)
            push!(out_uvs, file_uvs[ub + 1], file_uvs[ub + 2])
            have_uvs = true
        elseif have_uvs
            push!(out_uvs, 0.0, 0.0)
        end
        if nidx != 0
            nb = (nidx - 1) * 3
            have_normals || _obj_backfill_normals!(out_nrm, out_vi)
            push!(out_nrm, file_normals[nb + 1], file_normals[nb + 2], file_normals[nb + 3])
            have_normals = true
        else
            missing_normals = true
            have_normals && push!(out_nrm, 0.0, 0.0, 0.0)
        end
    end
    out_vi += 1
    push!(indices, out_vi)
    return out_vi, have_uvs, have_normals, missing_normals
end

_obj_emit_face_record_range!(out_pos::Vector{Float64}, out_uvs::Vector{Float64},
                             out_nrm::Vector{Float64}, indices::Vector{Int},
                             verts::Vector{Float64}, file_uvs::Vector{Float64},
                             file_normals::Vector{Float64}, line::AbstractString,
                             nverts_v::Int, nverts_uv::Int, nverts_n::Int,
                             out_vi::Int, have_uvs::Bool, have_normals::Bool,
                             missing_normals::Bool) =
    _obj_emit_face_record_range!(out_pos, out_uvs, out_nrm, indices, verts,
                                 file_uvs, file_normals, line, nverts_v,
                                 nverts_uv, nverts_n, out_vi, have_uvs,
                                 have_normals, missing_normals, nothing)

function _obj_emit_face_record_range!(out_pos::Vector{Float64}, out_uvs::Vector{Float64},
                                      out_nrm::Vector{Float64}, indices::Vector{Int},
                                      verts::Vector{Float64}, file_uvs::Vector{Float64},
                                      file_normals::Vector{Float64}, line::AbstractString,
                                      nverts_v::Int, nverts_uv::Int, nverts_n::Int,
                                      out_vi::Int, have_uvs::Bool, have_normals::Bool,
                                      missing_normals::Bool,
                                      corner_vertices::Union{Nothing,Vector{Int}})
    last_i = lastindex(line)
    i = nextind(line, firstindex(line))
    first_first, first_last, i, have_first = _obj_next_token_range(line, i, last_i)
    second_first, second_last, i, have_second = _obj_next_token_range(line, i, last_i)
    third_first, third_last, i, have_third = _obj_next_token_range(line, i, last_i)
    (have_first && have_second && have_third) ||
        error("OBJ face requires at least 3 vertices")
    first_corner = _obj_parse_corner_range(line, first_first, first_last,
                                           nverts_v, nverts_uv, nverts_n)
    prev_corner = _obj_parse_corner_range(line, second_first, second_last,
                                          nverts_v, nverts_uv, nverts_n)
    corner = _obj_parse_corner_range(line, third_first, third_last,
                                     nverts_v, nverts_uv, nverts_n)
    while true
        out_vi, have_uvs, have_normals, missing_normals =
            _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                              file_uvs, file_normals, first_corner, out_vi,
                              have_uvs, have_normals, missing_normals,
                              corner_vertices)
        out_vi, have_uvs, have_normals, missing_normals =
            _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                              file_uvs, file_normals, prev_corner, out_vi,
                              have_uvs, have_normals, missing_normals,
                              corner_vertices)
        out_vi, have_uvs, have_normals, missing_normals =
            _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                              file_uvs, file_normals, corner, out_vi,
                              have_uvs, have_normals, missing_normals,
                              corner_vertices)
        prev_corner = corner
        next_first, next_last, i, have_next = _obj_next_token_range(line, i, last_i)
        have_next || break
        corner = _obj_parse_corner_range(line, next_first, next_last,
                                         nverts_v, nverts_uv, nverts_n)
    end
    return out_vi, have_uvs, have_normals, missing_normals
end

function _obj_require_values(tokens, count::Int, label::String)
    length(tokens) >= count + 1 ||
        error("OBJ $label requires $count $(count == 1 ? "value" : "values")")
end

function _obj_parse_float(tok, label::String)
    value = tryparse(Float64, tok)
    value === nothing && error("OBJ $label must be a number")
    isfinite(value) || error("OBJ $label must be finite")
    return value
end

function _obj_backfill_zeros!(out::Vector{Float64}, required_len::Int)
    old_len = length(out)
    old_len >= required_len && return out
    resize!(out, required_len)
    @inbounds for i in (old_len + 1):required_len
        out[i] = 0.0
    end
    return out
end

_obj_backfill_uvs!(out::Vector{Float64}, emitted_vertices::Int) =
    _obj_backfill_zeros!(out, 2 * emitted_vertices)

_obj_backfill_normals!(out::Vector{Float64}, emitted_vertices::Int) =
    _obj_backfill_zeros!(out, 3 * emitted_vertices)

function _obj_is_face_record(line::AbstractString)
    isempty(line) && return false
    i = firstindex(line)
    line[i] == 'f' || return false
    j = nextind(line, i)
    return j <= lastindex(line) && isspace(line[j])
end

const _OBJ_SCAN_BUFFER_SIZE = 16 * 1024

@inline _obj_scan_space(b::UInt8) =
    b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\r') ||
    b == UInt8('\v') || b == UInt8('\f')

@inline function _obj_scan_tag_code(tag1::UInt8, tag2::UInt8, tag_len::Int)
    if tag_len == 1
        tag1 == UInt8('v') && return UInt8(1)
        tag1 == UInt8('f') && return UInt8(4)
    elseif tag_len == 2 && tag1 == UInt8('v')
        tag2 == UInt8('t') && return UInt8(2)
        tag2 == UInt8('n') && return UInt8(3)
    end
    return UInt8(0)
end

@inline function _obj_scan_finish_line(tag_code::UInt8, face_corners::Int,
                                       n_triangles::Int)
    if tag_code == UInt8(4) && face_corners >= 3
        n_triangles += face_corners - 2
    end
    return n_triangles
end

_obj_scan_counts(path::String) = open(_obj_scan_counts, path, "r")

# The scan state lives in this function's locals rather than in variables a
# `do` block captures and reassigns, which Julia would box.
function _obj_scan_counts(io::IO)
    buf = Vector{UInt8}(undef, _OBJ_SCAN_BUFFER_SIZE)
    n_vertices = 0
    n_uvs = 0
    n_normals = 0
    n_triangles = 0

    token_no = 0
    tag_len = 0
    tag1 = UInt8(0)
    tag2 = UInt8(0)
    tag_code = UInt8(0)
    face_corners = 0
    in_token = false
    skip_line = false

    while !eof(io)
        nread = readbytes!(io, buf)
        @inbounds for k in 1:nread
            b = buf[k]
            if b == UInt8('\n')
                if in_token && token_no == 1
                    tag_code = _obj_scan_tag_code(tag1, tag2, tag_len)
                    tag_code == UInt8(1) ? (n_vertices += 1) :
                    tag_code == UInt8(2) ? (n_uvs += 1) :
                    tag_code == UInt8(3) && (n_normals += 1)
                end
                n_triangles = skip_line ? n_triangles :
                              _obj_scan_finish_line(tag_code, face_corners,
                                                    n_triangles)
                token_no = 0
                tag_len = 0
                tag1 = UInt8(0)
                tag2 = UInt8(0)
                tag_code = UInt8(0)
                face_corners = 0
                in_token = false
                skip_line = false
            elseif skip_line
                continue
            elseif _obj_scan_space(b)
                if in_token && token_no == 1
                    tag_code = _obj_scan_tag_code(tag1, tag2, tag_len)
                    tag_code == UInt8(1) ? (n_vertices += 1) :
                    tag_code == UInt8(2) ? (n_uvs += 1) :
                    tag_code == UInt8(3) && (n_normals += 1)
                end
                in_token = false
            elseif !in_token
                if token_no == 0 && b == UInt8('#')
                    skip_line = true
                else
                    token_no += 1
                    in_token = true
                    if token_no == 1
                        tag_len = 1
                        tag1 = b
                        tag2 = UInt8(0)
                    elseif tag_code == UInt8(4)
                        face_corners += 1
                    end
                end
            elseif token_no == 1
                tag_len += 1
                tag_len == 2 && (tag2 = b)
            end
        end
    end
    if in_token && token_no == 1
        tag_code = _obj_scan_tag_code(tag1, tag2, tag_len)
        tag_code == UInt8(1) ? (n_vertices += 1) :
        tag_code == UInt8(2) ? (n_uvs += 1) :
        tag_code == UInt8(3) && (n_normals += 1)
    end
    n_triangles = skip_line ? n_triangles :
                  _obj_scan_finish_line(tag_code, face_corners, n_triangles)
    return n_vertices, n_uvs, n_normals, n_triangles
end

function _obj_parse_vec3(tokens, label::String)
    _obj_require_values(tokens, 3, label)
    return (_obj_parse_float(tokens[2], "$label x"),
            _obj_parse_float(tokens[3], "$label y"),
            _obj_parse_float(tokens[4], "$label z"))
end

@noinline function _obj_require_values_error(count::Int, label::String)
    error("OBJ $label requires $count $(count == 1 ? "value" : "values")")
end

@inline function _obj_required_token(parts, state, count::Int, label::String)
    token_state = iterate(parts, state)
    token_state === nothing && _obj_require_values_error(count, label)
    return token_state
end

function _obj_parse_vec3_tokens(parts, state, label::String,
                                x_label::String, y_label::String, z_label::String)
    x, y, z, _ = _obj_parse_vec3_tokens_state(parts, state, label,
                                              x_label, y_label, z_label)
    return (x, y, z)
end

# Like `_obj_parse_vec3_tokens`, also returning the iterator state after z.
function _obj_parse_vec3_tokens_state(parts, state, label::String, x_label::String,
                                      y_label::String, z_label::String)
    x_state = _obj_required_token(parts, state, 3, label)
    y_state = _obj_required_token(parts, x_state[2], 3, label)
    z_state = _obj_required_token(parts, y_state[2], 3, label)
    return (_obj_parse_float(x_state[1], x_label),
            _obj_parse_float(y_state[1], y_label),
            _obj_parse_float(z_state[1], z_label), z_state[2])
end

_obj_parse_vec3_tokens(parts, state, label::String) =
    _obj_parse_vec3_tokens(parts, state, label, string(label, " x"),
                           string(label, " y"), string(label, " z"))

function _obj_parse_vt_tokens(parts, state)
    u_state = _obj_required_token(parts, state, 1, "vt")
    v_state = iterate(parts, u_state[2])
    return (_obj_parse_float(u_state[1], "vt u"),
            v_state === nothing ? 0.0 : _obj_parse_float(v_state[1], "vt v"))
end

@inline function _obj_required_arg(parts, state, message::String)
    token_state = iterate(parts, state)
    token_state === nothing && error(message)
    return token_state
end

"""
    load_obj(path) -> BufferGeometry

Load a Wavefront OBJ mesh (vertices, texture coordinates, normals, and faces;
polygons fan-triangulated). Normals are taken from the file when present;
a corner without a usable file normal (no `vn` reference, or a zero `vn`)
gets its face normal, and a file without normals gets
[`compute_vertex_normals!`](@ref). Materials are ignored.

As in three.js `OBJLoader`, a line ending in a backslash continues on the
next line, and vertex records written as `v x y z r g b` add a per-vertex
`:color` attribute, with the sRGB channels converted to linear. Colours are
kept only when every `v` record carries them.
"""
function load_obj(path::String)
    verts = Float64[]            # v
    file_uvs = Float64[]         # vt
    file_normals = Float64[]     # vn
    file_colors = Float64[]      # optional r g b after v x y z (linear)
    colors_ok = true             # every v record so far carried a colour
    corner_vertices = Int[]      # file vertex index of each emitted corner
    out_pos = Float64[]
    out_uvs = Float64[]
    out_nrm = Float64[]
    indices = Int[]
    have_normals = false
    have_uvs = false
    missing_normals = false
    out_vi = 0
    n_v_hint, n_uv_hint, n_n_hint, n_tri_hint = _obj_scan_counts(path)
    emitted_hint = 3 * n_tri_hint
    sizehint!(verts, 3 * n_v_hint)
    sizehint!(file_uvs, 2 * n_uv_hint)
    sizehint!(file_normals, 3 * n_n_hint)
    sizehint!(out_pos, 3 * emitted_hint)
    sizehint!(out_uvs, n_uv_hint == 0 ? 0 : 2 * emitted_hint)
    sizehint!(out_nrm, n_n_hint == 0 ? 0 : 3 * emitted_hint)
    sizehint!(indices, emitted_hint)

    # try/finally instead of a `do` block: the loop reassigns out_vi,
    # have_uvs, ... which a closure would box.
    io = open(path, "r")
    try
    continued = ""
    while true
        if eof(io)
            # A continuation on the last line joins with nothing.
            isempty(continued) && break
            raw = ""
        else
            raw = readline(io)
        end
        # OBJLoader.js parse: text.replace(/\\\n/g, '') joins a line that ends
        # in a backslash with the next one.
        if endswith(raw, '\\')
            continued = string(continued, chop(raw))
            continue
        elseif !isempty(continued)
            raw = string(continued, raw)
            continued = ""
        end
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        if _obj_is_face_record(line)
            nverts_v = length(verts) ÷ 3
            nverts_uv = length(file_uvs) ÷ 2
            nverts_n = length(file_normals) ÷ 3
            out_vi, have_uvs, have_normals, missing_normals =
                _obj_emit_face_record_range!(out_pos, out_uvs, out_nrm, indices,
                                             verts, file_uvs, file_normals, line,
                                             nverts_v, nverts_uv, nverts_n, out_vi,
                                             have_uvs, have_normals, missing_normals,
                                             colors_ok && !isempty(file_colors) ?
                                                 corner_vertices : nothing)
            continue
        end
        parts = eachsplit(line)
        tag_state = iterate(parts)
        tag_state === nothing && continue
        tag = tag_state[1]
        if tag == "v"
            x, y, z, state = _obj_parse_vec3_tokens_state(parts, tag_state[2],
                                                          "v", "v x", "v y", "v z")
            push!(verts, x, y, z)
            if colors_ok
                # OBJLoader.js: `v x y z r g b` (data.length >= 7) carries an
                # sRGB colour; `v x y z [w]` does not.
                r_state = iterate(parts, state)
                g_state = r_state === nothing ? nothing : iterate(parts, r_state[2])
                b_state = g_state === nothing ? nothing : iterate(parts, g_state[2])
                if b_state === nothing
                    colors_ok = false
                else
                    push!(file_colors,
                          srgb_to_linear(_obj_parse_float(r_state[1], "v red")),
                          srgb_to_linear(_obj_parse_float(g_state[1], "v green")),
                          srgb_to_linear(_obj_parse_float(b_state[1], "v blue")))
                end
            end
        elseif tag == "vt"
            # A 1-D texture coordinate (`vt u`) is valid; treat the missing
            # second component as 0.0 (three.js OBJLoader stores
            # parseFloat(undefined), i.e. NaN).
            u, v = _obj_parse_vt_tokens(parts, tag_state[2])
            push!(file_uvs, u, v)
        elseif tag == "vn"
            x, y, z = _obj_parse_vec3_tokens(parts, tag_state[2],
                                             "vn", "vn x", "vn y", "vn z")
            push!(file_normals, x, y, z)
        elseif tag == "f"
            # Every `f` with corners took the face-record path above; only a
            # bare `f` reaches here.
            error("OBJ face requires at least 3 vertices")
        end
    end
    finally
        close(io)
    end
    nfaces = length(indices) ÷ 3
    geo = BufferGeometry(out_pos, out_nrm, have_uvs ? out_uvs : Float64[],
                         indices, out_vi, nfaces)
    if !have_normals
        compute_vertex_normals!(geo)
    else
        # OBJLoader.js addFace keeps the file normals of a face and gives a face
        # without `vn` its face normal (addFaceNormal). Emitted corners never
        # share a vertex, so compute_vertex_normals! yields exactly those face
        # normals; copy them into the corners left at (0,0,0), which also
        # covers an explicit zero `vn` that would otherwise shade black.
        face_normals = Float64[]
        @inbounds for b in 1:3:length(out_nrm)
            out_nrm[b] == 0.0 && out_nrm[b+1] == 0.0 && out_nrm[b+2] == 0.0 || continue
            if isempty(face_normals)
                _validate_triangle_geometry_indices(geo, "load_obj")
                resize!(face_normals, length(out_nrm))
                _compute_vertex_normals!(face_normals, geo, Vec3(0.0, 0.0, 1.0))
            end
            out_nrm[b] = face_normals[b]
            out_nrm[b+1] = face_normals[b+1]
            out_nrm[b+2] = face_normals[b+2]
        end
    end
    if colors_ok && !isempty(file_colors)
        colors = Vector{Float64}(undef, 3 * out_vi)
        @inbounds for (k, vidx) in enumerate(corner_vertices)
            b = 3 * (vidx - 1)
            colors[3k-2] = file_colors[b+1]
            colors[3k-1] = file_colors[b+2]
            colors[3k] = file_colors[b+3]
        end
        set_attribute!(geo, :color, colors, 3)
    end
    return geo
end

# ========================== XYZ ==========================

@noinline _xyz_invalid_float(line_no::Int, field::String) =
    throw(ArgumentError("XYZ line $line_no has invalid $field value"))
@noinline _xyz_nonfinite_float(line_no::Int, field::String) =
    throw(ArgumentError("XYZ line $line_no has non-finite $field value"))

function _xyz_parse_float(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                          line_no::Int, field::String)
    value, status = _try_parse_ascii_float(bytes, first, last)
    status == UInt8(2) && _xyz_nonfinite_float(line_no, field)
    status == UInt8(0) || _xyz_invalid_float(line_no, field)
    return value
end

function _xyz_parse_color(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                          line_no::Int, field::String)
    value = _xyz_parse_float(bytes, first, last, line_no, field)
    0.0 <= value <= 255.0 ||
        throw(ArgumentError("XYZ line $line_no has $field outside 0-255"))
    return srgb_to_linear(value / 255.0)
end

"""
    parse_xyz(text; source="<string>") -> BufferGeometry

Parse XYZ point-cloud text using the same two record layouts as three.js
`XYZLoader`: `x y z` and `x y z r g b`. RGB channels are interpreted as sRGB
bytes in `[0,255]` and stored as a linear `:color` vertex attribute. Empty lines
and full-line `#` comments are ignored. Unlike the current three.js parser,
malformed field counts, mixed XYZ/XYZRGB records, non-finite values, and
out-of-range RGB bytes throw `ArgumentError` with line context instead of being
silently ignored or propagated into geometry buffers.
"""
function parse_xyz(text::AbstractString; source::AbstractString="<string>")
    positions = Float64[]
    colors = nothing
    bytes = codeunits(String(text))
    n = length(bytes)
    row_hint = count(==(UInt8('\n')), bytes) + 1
    sizehint!(positions, 3 * row_hint)
    layout = nothing
    line_no = 0
    i = 1
    while i <= n
        line_no += 1
        line_start, line_stop, next_i = _ply_line_bounds(bytes, i, n)
        i = next_i
        ntoks = 0
        skip_line = false
        f1 = l1 = f2 = l2 = f3 = l3 = f4 = l4 = f5 = l5 = f6 = l6 = 0
        p = line_start
        while true
            first, last, p = _ply_next_ascii_token(bytes, p, line_stop)
            first == 0 && break
            if ntoks == 0 && bytes[first] == UInt8('#')
                skip_line = true
                break
            end
            ntoks += 1
            ntoks == 1 ? (f1 = first; l1 = last) :
            ntoks == 2 ? (f2 = first; l2 = last) :
            ntoks == 3 ? (f3 = first; l3 = last) :
            ntoks == 4 ? (f4 = first; l4 = last) :
            ntoks == 5 ? (f5 = first; l5 = last) :
            ntoks == 6 && (f6 = first; l6 = last)
        end
        (skip_line || ntoks == 0) && continue
        record_layout = if ntoks == 3
            :xyz
        elseif ntoks == 6
            :xyzrgb
        else
            throw(ArgumentError("XYZ line $line_no in $source has $ntoks fields; expected 3 or 6"))
        end
        if layout === nothing
            layout = record_layout
            if record_layout === :xyzrgb
                colors = Float64[]
                sizehint!(colors, 3 * row_hint)
            end
        elseif layout !== record_layout
            throw(ArgumentError("XYZ line $line_no in $source mixes XYZ and XYZRGB records"))
        end
        push!(positions,
              _xyz_parse_float(bytes, f1, l1, line_no, "x"),
              _xyz_parse_float(bytes, f2, l2, line_no, "y"),
              _xyz_parse_float(bytes, f3, l3, line_no, "z"))
        if record_layout === :xyzrgb
            out_colors = colors::Vector{Float64}
            push!(out_colors,
                  _xyz_parse_color(bytes, f4, l4, line_no, "red"),
                  _xyz_parse_color(bytes, f5, l5, line_no, "green"),
                  _xyz_parse_color(bytes, f6, l6, line_no, "blue"))
        end
    end
    nverts = length(positions) ÷ 3
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], nverts, 0)
    layout === :xyzrgb && set_attribute!(geo, :color, colors::Vector{Float64}, 3)
    return geo
end

"""
    load_xyz(path) -> BufferGeometry

Load an `.xyz` point cloud from disk. Supports plain XYZ records and XYZRGB
records with sRGB byte colors, returning a [`BufferGeometry`](@ref) suitable for
[`PointsObject`](@ref).
"""
load_xyz(path::String) = parse_xyz(read(path, String); source=path)

# ========================== PLY ==========================

# Size in bytes and binary readers for each Stanford-PLY scalar type. Type aliases
# (char/int8, uchar/uint8, short/int16, ushort/uint16, int/int32, uint/uint32,
# float/float32, double/float64) are normalised to a canonical token.
const _PLY_TYPE = Dict(
    "char"=>:i8, "int8"=>:i8, "uchar"=>:u8, "uint8"=>:u8,
    "short"=>:i16, "int16"=>:i16, "ushort"=>:u16, "uint16"=>:u16,
    "int"=>:i32, "int32"=>:i32, "uint"=>:u32, "uint32"=>:u32,
    "float"=>:f32, "float32"=>:f32, "double"=>:f64, "float64"=>:f64,
)
const _PLY_SIZE = Dict(:i8=>1, :u8=>1, :i16=>2, :u16=>2, :i32=>4, :u32=>4, :f32=>4, :f64=>8)
# Integer scalar types: PLY colour channels stored as integers are normalised to [0,1].
_ply_is_int(t::Symbol) = t in (:i8, :u8, :i16, :u16, :i32, :u32)

@inline function _ply_integer_bounds(t::Symbol)
    t === :i8 && return (-128.0, 127.0)
    t === :u8 && return (0.0, 255.0)
    t === :i16 && return (-32_768.0, 32_767.0)
    t === :u16 && return (0.0, 65_535.0)
    t === :i32 && return (-2_147_483_648.0, 2_147_483_647.0)
    return (0.0, 4_294_967_295.0) # :u32
end

@noinline function _ply_ascii_declared_type_error(element::String, row::Int,
                                                   prop::String, item::Int,
                                                   t::Symbol)
    location = item == 0 ?
               "PLY $element row $row property $prop" :
               "PLY $element row $row property $prop item $item"
    error("$location is not representable as declared $t")
end

@inline function _ply_ascii_typed_value(value::Float64, t::Symbol,
                                        element::String, row::Int,
                                        prop::String, item::Int=0)
    if _ply_is_int(t)
        lo, hi = _ply_integer_bounds(t)
        (value == trunc(value) && lo <= value <= hi) ||
            _ply_ascii_declared_type_error(element, row, prop, item, t)
        return value
    elseif t === :f32
        rounded = Float32(value)
        isfinite(rounded) ||
            _ply_ascii_declared_type_error(element, row, prop, item, t)
        return Float64(rounded)
    end
    return value
end

@inline function _ply_color_integer_max(t::Symbol)
    t === :u8 && return 255.0
    t === :i8 && return 127.0
    t === :u16 && return 65_535.0
    t === :i16 && return 32_767.0
    t === :u32 && return 4_294_967_295.0
    t === :i32 && return 2_147_483_647.0
    return 1.0
end

@noinline function _ply_color_range_error(row::Int, channel::String, t::Symbol)
    error("PLY vertex row $row color channel $channel is outside the non-negative $t range")
end

@inline function _ply_normalize_color(value::Float64, t::Symbol, row::Int,
                                      channel::String)
    _ply_is_int(t) || return value
    max_value = _ply_color_integer_max(t)
    (value == floor(value) && 0.0 <= value <= max_value) ||
        _ply_color_range_error(row, channel, t)
    return value / max_value
end

@inline function _ply_checked_add(a::Int, b::Int, context::String)
    (a >= 0 && b >= 0 && a <= typemax(Int) - b) ||
        error("PLY $context is too large")
    return a + b
end

@inline function _ply_checked_mul(a::Int, b::Int, context::String)
    (a >= 0 && b >= 0 && (a == 0 || b <= typemax(Int) ÷ a)) ||
        error("PLY $context is too large")
    return a * b
end

@inline _ply_available_bytes(n::Int, offset::Int) = offset <= n ? n - offset + 1 : 0

function _ply_binary_min_row_bytes(props)
    total = 0
    for prop in props
        # A list may be empty, but its count scalar is always present.
        ty = prop[3]
        total = _ply_checked_add(total, _PLY_SIZE[ty], "binary row size")
    end
    return total
end

function _ply_preflight_element(ecount::Int, props, format::Symbol,
                                remaining::Int, ename::String)
    min_row_bytes = format === :ascii ? (isempty(props) ? 0 : 1) :
                    _ply_binary_min_row_bytes(props)
    required = _ply_checked_mul(ecount, min_row_bytes, "element byte count")
    required <= remaining ||
        error("PLY $format element $ename declares $ecount rows, but the file " *
              "has only $remaining body bytes remaining")
    return nothing
end

function _ply_parse_type(tok, context::String)
    ty = get(_PLY_TYPE, String(tok), nothing)
    ty === nothing && error("unsupported PLY $context type $(String(tok))")
    return ty
end

function _ply_parse_element_count(tok)
    count = tryparse(Int, String(tok))
    (count !== nothing && count >= 0) ||
        error("PLY element count must be a non-negative integer")
    return count
end

function _ply_parse_ascii_float(tok, context::String)
    value = tryparse(Float64, tok)
    value === nothing && error("PLY $context must be a number")
    isfinite(value) || error("PLY $context must be finite")
    return value
end

@inline _ply_ascii_space(b::UInt8) =
    b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\r') || b == UInt8('\n') ||
    b == UInt8('\v') || b == UInt8('\f')
@inline _ply_ascii_digit(b::UInt8) = UInt8('0') <= b <= UInt8('9')
@inline _ply_ascii_lower(b::UInt8) =
    UInt8('A') <= b <= UInt8('Z') ? UInt8(b + 0x20) : b

function _ply_ascii_token_eq(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                             word::String)
    n = last - first + 1
    n == ncodeunits(word) || return false
    @inbounds for j in 1:n
        _ply_ascii_lower(bytes[first + j - 1]) == codeunit(word, j) ||
            return false
    end
    return true
end

@inline function _ascii_float64(bytes::Base.CodeUnits{UInt8,String},
                                first::Int, last::Int)
    # This is Base's bounded decimal converter. It inspects the character just
    # after the token, so pass NUL-terminated String storage, never a raw vector.
    return ccall(:jl_try_substrtod, Tuple{Bool,Float64},
                 (Ptr{UInt8}, Csize_t, Csize_t), getfield(bytes, :s),
                 first - 1, last - first + 1)
end

function _ascii_float64(bytes::AbstractVector{UInt8}, first::Int, last::Int)
    text = String(bytes[first:last])
    return _ascii_float64(codeunits(text), 1, ncodeunits(text))
end

@inline function _try_parse_ascii_float(bytes::AbstractVector{UInt8},
                                        first::Int, last::Int)
    1 <= first <= last <= length(bytes) || return 0.0, UInt8(1)
    p = first
    if p <= last && (bytes[p] == UInt8('+') || bytes[p] == UInt8('-'))
        p += 1
    end
    if p <= last
        if _ply_ascii_token_eq(bytes, p, last, "nan")
            return 0.0, UInt8(2)
        elseif _ply_ascii_token_eq(bytes, p, last, "inf") ||
               _ply_ascii_token_eq(bytes, p, last, "infinity")
            return 0.0, UInt8(2)
        end
    end

    digits = 0
    @inbounds while p <= last && _ply_ascii_digit(bytes[p])
        p += 1
        digits += 1
    end
    if p <= last && bytes[p] == UInt8('.')
        p += 1
        @inbounds while p <= last && _ply_ascii_digit(bytes[p])
            p += 1
            digits += 1
        end
    end
    digits > 0 || return 0.0, UInt8(1)
    if p <= last && (bytes[p] == UInt8('e') || bytes[p] == UInt8('E'))
        p += 1
        if p <= last && (bytes[p] == UInt8('+') || bytes[p] == UInt8('-'))
            p += 1
        end
        exp_digits = 0
        @inbounds while p <= last && _ply_ascii_digit(bytes[p])
            p += 1
            exp_digits += 1
        end
        exp_digits > 0 || return 0.0, UInt8(1)
    end
    p == last + 1 || return 0.0, UInt8(1)
    hasvalue, value = _ascii_float64(bytes, first, last)
    isfinite(value) || return 0.0, UInt8(2)
    # The grammar above excludes failed conversions. ERANGE with signed zero
    # denotes rounded underflow, which these loaders have always accepted.
    hasvalue || iszero(value) || return 0.0, UInt8(1)
    return value, UInt8(0)
end

@noinline function _ply_ascii_float_context_error(context::String, status::UInt8)
    status == UInt8(2) ? error("PLY $context must be finite") :
                         error("PLY $context must be a number")
end

function _ply_parse_ascii_float(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                                context::String)
    value, status = _try_parse_ascii_float(bytes, first, last)
    status == UInt8(0) || _ply_ascii_float_context_error(context, status)
    return value
end

@noinline function _ply_vertex_ascii_float_error(row::Int, col::Int, props, status::UInt8)
    reason = status == UInt8(2) ? "finite" : "a number"
    if col <= length(props)
        error("PLY vertex row $row property $(props[col][2]) must be $reason")
    else
        error("PLY vertex row $row value $col must be $reason")
    end
end

@inline function _ply_parse_ascii_vertex_float(bytes::AbstractVector{UInt8},
                                               first::Int, last::Int,
                                               row::Int, col::Int, props)
    value, status = _try_parse_ascii_float(bytes, first, last)
    status == UInt8(0) || _ply_vertex_ascii_float_error(row, col, props, status)
    return value
end

@noinline function _ply_face_ascii_float_error(row::Int, role::Symbol, k::Int, status::UInt8)
    reason = status == UInt8(2) ? "finite" : "a number"
    if role === :count
        error("PLY face row $row list count must be $reason")
    else
        error("PLY face row $row vertex index $k must be $reason")
    end
end

@inline function _ply_parse_ascii_face_float(bytes::AbstractVector{UInt8},
                                             first::Int, last::Int,
                                             row::Int, role::Symbol, k::Int=0)
    value, status = _try_parse_ascii_float(bytes, first, last)
    status == UInt8(0) || _ply_face_ascii_float_error(row, role, k, status)
    return value
end

@noinline function _ply_ascii_property_value_error(element::String, row::Int,
                                                    prop::String, item::Int,
                                                    status::UInt8)
    reason = status == UInt8(2) ? "finite" : "a number"
    item == 0 &&
        error("PLY $element row $row property $prop must be $reason")
    error("PLY $element row $row property $prop item $item must be $reason")
end

@inline function _ply_validate_ascii_property_value(bytes::AbstractVector{UInt8},
                                                    first::Int, last::Int,
                                                    element::String, row::Int,
                                                    prop::String, t::Symbol,
                                                    item::Int=0)
    value, status = _try_parse_ascii_float(bytes, first, last)
    status == UInt8(0) ||
        _ply_ascii_property_value_error(element, row, prop, item, status)
    return _ply_ascii_typed_value(value, t, element, row, prop, item)
end

@noinline _ply_ascii_missing_property_error(element::String, row::Int, prop::String) =
    error("PLY $element row $row is missing property $prop")

function _ply_line_bounds(bytes::AbstractVector{UInt8}, i::Int, n::Int)
    i <= n || error("PLY ASCII element data is truncated")
    j = i
    while j <= n && bytes[j] != UInt8('\n')
        j += 1
    end
    last = j - 1
    last >= i && bytes[last] == UInt8('\r') && (last -= 1)
    return i, last, j + 1
end

function _ply_next_ascii_token(bytes::AbstractVector{UInt8}, p::Int, line_stop::Int)
    while p <= line_stop && _ply_ascii_space(bytes[p])
        p += 1
    end
    p > line_stop && return 0, -1, p
    first = p
    while p <= line_stop && !_ply_ascii_space(bytes[p])
        p += 1
    end
    return first, p - 1, p
end

function _ply_checked_finite(value, context::String)
    isfinite(value) || error("PLY $context must be finite")
    return value
end

@noinline _ply_vertex_finite_error(row::Int, prop) =
    error("PLY vertex row $row property $prop must be finite")

@inline function _ply_checked_finite_vertex(value, row::Int, prop)
    isfinite(value) || _ply_vertex_finite_error(row, prop)
    return value
end

# Read one scalar of canonical type `t` from byte vector `b` at 1-based offset
# `p` (little-endian). Returns (value::Float64, next_offset).
@inline function _ply_read_le(b::Vector{UInt8}, p::Int, t::Symbol)
    sz = (t === :u8 || t === :i8) ? 1 : (t === :u16 || t === :i16) ? 2 : t === :f64 ? 8 : 4
    (p >= 1 && sz <= _ply_available_bytes(length(b), p)) ||
        error("PLY binary element data is truncated")
    if t === :u8
        return (Float64(b[p]), p + 1)
    elseif t === :i8
        return (Float64(reinterpret(Int8, b[p])), p + 1)
    elseif t === :u16
        v = UInt16(b[p]) | (UInt16(b[p+1]) << 8); return (Float64(v), p + 2)
    elseif t === :i16
        v = UInt16(b[p]) | (UInt16(b[p+1]) << 8); return (Float64(reinterpret(Int16, v)), p + 2)
    elseif t === :u32
        v = UInt32(b[p]) | (UInt32(b[p+1])<<8) | (UInt32(b[p+2])<<16) | (UInt32(b[p+3])<<24)
        return (Float64(v), p + 4)
    elseif t === :i32
        v = UInt32(b[p]) | (UInt32(b[p+1])<<8) | (UInt32(b[p+2])<<16) | (UInt32(b[p+3])<<24)
        return (Float64(reinterpret(Int32, v)), p + 4)
    elseif t === :f32
        v = UInt32(b[p]) | (UInt32(b[p+1])<<8) | (UInt32(b[p+2])<<16) | (UInt32(b[p+3])<<24)
        return (Float64(reinterpret(Float32, v)), p + 4)
    else  # :f64
        v = UInt64(0)
        @inbounds for k in 0:7
            v |= UInt64(b[p+k]) << (8k)
        end
        return (reinterpret(Float64, v), p + 8)
    end
end

# Read one scalar of canonical type `t` from byte vector `b` at 1-based offset
# `p` (big-endian). Returns (value::Float64, next_offset).
@inline function _ply_read_be(b::Vector{UInt8}, p::Int, t::Symbol)
    sz = (t === :u8 || t === :i8) ? 1 : (t === :u16 || t === :i16) ? 2 : t === :f64 ? 8 : 4
    (p >= 1 && sz <= _ply_available_bytes(length(b), p)) ||
        error("PLY binary element data is truncated")
    if t === :u8
        return (Float64(b[p]), p + 1)
    elseif t === :i8
        return (Float64(reinterpret(Int8, b[p])), p + 1)
    elseif t === :u16
        v = (UInt16(b[p]) << 8) | UInt16(b[p+1]); return (Float64(v), p + 2)
    elseif t === :i16
        v = (UInt16(b[p]) << 8) | UInt16(b[p+1]); return (Float64(reinterpret(Int16, v)), p + 2)
    elseif t === :u32
        v = (UInt32(b[p]) << 24) | (UInt32(b[p+1]) << 16) |
            (UInt32(b[p+2]) << 8) | UInt32(b[p+3])
        return (Float64(v), p + 4)
    elseif t === :i32
        v = (UInt32(b[p]) << 24) | (UInt32(b[p+1]) << 16) |
            (UInt32(b[p+2]) << 8) | UInt32(b[p+3])
        return (Float64(reinterpret(Int32, v)), p + 4)
    elseif t === :f32
        v = (UInt32(b[p]) << 24) | (UInt32(b[p+1]) << 16) |
            (UInt32(b[p+2]) << 8) | UInt32(b[p+3])
        return (Float64(reinterpret(Float32, v)), p + 4)
    else  # :f64
        v = UInt64(0)
        @inbounds for k in 0:7
            v = (v << 8) | UInt64(b[p+k])
        end
        return (reinterpret(Float64, v), p + 8)
    end
end

# Next header line starting at byte `i`, without its `eol` byte or a CR before
# it, and the offset just past the line end.
function _ply_header_line(bytes::Vector{UInt8}, i::Int, n::Int, eol::UInt8)
    j = i
    while j <= n && bytes[j] != eol; j += 1; end
    e = j - 1
    e >= i && bytes[e] == UInt8('\r') && (e -= 1)   # strip CRLF
    line = e >= i ? String(bytes[i:e]) : ""
    return line, j + 1
end

# Triangulate a PLY face one corner at a time (0-based `idx` in, 1-based
# indices out). A quad splits as (0,1,3), (1,2,3), as PLYLoader.js
# handleElement does; larger polygons, which three.js drops, fan from corner 0.
@inline function _ply_polygon_corner!(indices::Vector{Int}, k::Int, nitems::Int,
                                      idx::Int, first_idx::Int, prev_idx::Int,
                                      third_idx::Int)
    if k == 1
        first_idx = idx
    elseif k == 2
        prev_idx = idx
    elseif nitems == 4
        if k == 3
            third_idx = idx
        else
            push!(indices, first_idx + 1, prev_idx + 1, idx + 1,
                  prev_idx + 1, third_idx + 1, idx + 1)
        end
    else
        push!(indices, first_idx + 1, prev_idx + 1, idx + 1)
        prev_idx = idx
    end
    return first_idx, prev_idx, third_idx
end

function _ply_checked_binary_skip(i::Int, n::Int, nbytes::Int)
    nbytes >= 0 || error("PLY binary skip size must be non-negative")
    nbytes <= _ply_available_bytes(n, i) ||
        error("PLY binary element data is truncated")
    return i + nbytes
end

"""
    load_ply(path) -> BufferGeometry

Load a Stanford `.ply` mesh (ASCII, `binary_little_endian`, or
`binary_big_endian`). Reads the
`vertex` element (`x,y,z`; optional `nx,ny,nz`; optional `red,green,blue`) and
the `face` element (a vertex-index list per face, fan-triangulated). Returns a
[`BufferGeometry`](@ref) with positions, normals (file normals when present,
otherwise smooth normals via [`compute_vertex_normals!`](@ref)), and a `:color`
vertex attribute when colours are present (integer channels normalised to
`[0,1]`).
"""
function load_ply(path::String)
    bytes = read(path)
    n = length(bytes)

    # --- Parse the (always-ASCII) header line by line over the byte stream. ---
    # `i` walks the byte offset; after "end_header" it marks the body start.
    format = :ascii                 # :ascii | :binary_little_endian | :binary_big_endian
    # Per element, in declared order: name, count, and an ordered property list.
    # Vertex/scalar properties are stored as (:scalar, name, type, :none). A
    # face list property is stored as (:list, name, count_type, index_type).
    # One concrete tuple type keeps the per-row loops type-stable.
    elements = Tuple{String,Int,Vector{Tuple{Symbol,String,Symbol,Symbol}}}[]
    i = 1
    # Classic Mac headers end lines with a bare CR, as three.js PLYLoader accepts.
    cr = findfirst(b -> b == UInt8('\r') || b == UInt8('\n'), bytes)
    eol = cr !== nothing && bytes[cr] == UInt8('\r') &&
          (cr == n || bytes[cr + 1] != UInt8('\n')) ? UInt8('\r') : UInt8('\n')
    magic, i = _ply_header_line(bytes, i, n, eol)
    strip(magic) == "ply" || error("not a PLY file")
    while true
        i <= n || error("PLY header has no end_header")
        raw_line, i = _ply_header_line(bytes, i, n, eol)
        line = strip(raw_line)
        (isempty(line) || startswith(line, "comment") || startswith(line, "obj_info")) && continue
        t = split(line)
        tag = t[1]
        if tag == "format"
            length(t) >= 2 || error("PLY format declaration requires a format token")
            fmt = t[2]
            if fmt == "ascii"
                format = :ascii
            elseif fmt == "binary_little_endian"
                format = :binary_little_endian
            elseif fmt == "binary_big_endian"
                format = :binary_big_endian
            else
                error("unsupported PLY format $fmt")
            end
        elseif tag == "element"
            length(t) >= 3 || error("PLY element declaration requires a name and count")
            push!(elements, (String(t[2]), _ply_parse_element_count(t[3]),
                             Tuple{Symbol,String,Symbol,Symbol}[]))
        elseif tag == "property"
            isempty(elements) && error("PLY property before element")
            props = elements[end][3]
            if length(t) >= 2 && t[2] == "list"
                length(t) >= 5 ||
                    error("PLY list property declaration requires count type, index type, and name")
                # property list <count_type> <index_type> <name>
                ct = _ply_parse_type(t[3], "list count")
                it = _ply_parse_type(t[4], "list index")
                push!(props, (:list, String(t[5]), ct, it))
            else
                length(t) >= 3 || error("PLY property declaration requires type and name")
                push!(props, (:scalar, String(t[3]), _ply_parse_type(t[2], "property"), :none))
            end
        elseif tag == "end_header"
            break
        end
    end

    # --- Locate vertex/face elements and column roles. ---
    positions = Float64[]; normals = Float64[]; colors = Float64[]; uvs = Float64[]
    indices = Int[]
    have_normals = false; have_color = false; have_uv = false
    read_binary = format === :binary_big_endian ? _ply_read_be : _ply_read_le
    function checked_list_count(cnt)
        isfinite(cnt) && cnt >= 0 && cnt == floor(cnt) ||
            error("PLY list property count must be a non-negative integer")
        cnt < ldexp(1.0, 8 * sizeof(Int) - 1) ||
            error("PLY list property count exceeds the supported integer range")
        return Int(cnt)
    end
    function checked_vertex_index(idx, nverts::Int)
        isfinite(idx) && idx == floor(idx) ||
            error("PLY face vertex index must be an integer")
        0 <= idx < nverts ||
            error("PLY face vertex index $idx is outside 0:$(nverts - 1)")
        iidx = Int(idx)
        return iidx
    end

    # Transfer owned ASCII bytes to String storage once. Numeric tokens then
    # share its trailing NUL and do not allocate a string per field.
    body = format === :ascii ? codeunits(String(bytes)) : bytes

    for (ename, ecount, props) in elements
        _ply_preflight_element(ecount, props, format, _ply_available_bytes(n, i), ename)
        if ename == "vertex"
            # Map property name -> column index for the roles we read.
            names = String[p[2] for p in props]
            types = Symbol[p[1] === :scalar ? p[3] : :u32 for p in props]
            # First property found among the candidate names, tried in order
            # (PLYLoader.js getAttributeDescriptor findProperty).
            function col(candidates::String...)
                for name in candidates
                    c = findfirst(==(name), names)
                    c === nothing || return c
                end
                return nothing
            end
            ix = col("x", "px", "posx"); iy = col("y", "py", "posy")
            iz = col("z", "pz", "posz")
            (ix === nothing || iy === nothing || iz === nothing) && error("PLY vertex element lacks x/y/z")
            for c in (ix, iy, iz)
                props[c][1] === :scalar ||
                    error("PLY vertex property $(props[c][2]) must be scalar")
            end
            inx = col("nx", "normalx"); iny = col("ny", "normaly")
            inz = col("nz", "normalz")
            have_normals = inx !== nothing && iny !== nothing && inz !== nothing
            if have_normals
                for c in (inx, iny, inz)
                    props[c][1] === :scalar ||
                        error("PLY vertex property $(props[c][2]) must be scalar")
                end
            end
            ir = col("red", "diffuse_red", "r", "diffuse_r")
            ig = col("green", "diffuse_green", "g", "diffuse_g")
            ib = col("blue", "diffuse_blue", "b", "diffuse_b")
            have_color = ir !== nothing && ig !== nothing && ib !== nothing
            if have_color
                for c in (ir, ig, ib)
                    props[c][1] === :scalar ||
                        error("PLY vertex property $(props[c][2]) must be scalar")
                end
            end
            ius = col("s", "u", "texture_u", "tx"); ivt = col("t", "v", "texture_v", "ty")
            have_uv = ius !== nothing && ivt !== nothing
            if have_uv
                for c in (ius, ivt)
                    props[c][1] === :scalar ||
                        error("PLY vertex property $(props[c][2]) must be scalar")
                end
            end
            coord_count = _ply_checked_mul(ecount, 3, "vertex coordinate count")
            positions = Vector{Float64}(undef, coord_count)
            have_normals && (normals = Vector{Float64}(undef, coord_count))
            have_color && (colors = Vector{Float64}(undef, coord_count))
            have_uv && (uvs = Vector{Float64}(undef, 2 * ecount))

            if format == :ascii
                p = i
                for v in 0:ecount-1
                    b3 = v * 3
                    for (c, prop) in enumerate(props)
                        first, last, p = _ply_next_ascii_token(body, p, n)
                        first != 0 ||
                            _ply_ascii_missing_property_error("vertex", v + 1, prop[2])
                        val = _ply_parse_ascii_vertex_float(body, first, last,
                                                            v + 1, c, props)
                        if prop[1] === :list
                            count_value = _ply_ascii_typed_value(
                                val, prop[3], "vertex", v + 1, prop[2])
                            nitems = checked_list_count(count_value)
                            for item in 1:nitems
                                first, last, p = _ply_next_ascii_token(
                                    body, p, n)
                                first != 0 ||
                                    _ply_ascii_missing_property_error(
                                        "vertex", v + 1, prop[2])
                                _ply_validate_ascii_property_value(
                                    body, first, last, "vertex", v + 1,
                                    prop[2], prop[4], item)
                            end
                        else
                            val = _ply_ascii_typed_value(
                                val, types[c], "vertex", v + 1, prop[2])
                            if c == ix
                                positions[b3+1] = val
                            elseif c == iy
                                positions[b3+2] = val
                            elseif c == iz
                                positions[b3+3] = val
                            elseif have_normals && c == inx
                                normals[b3+1] = val
                            elseif have_normals && c == iny
                                normals[b3+2] = val
                            elseif have_normals && c == inz
                                normals[b3+3] = val
                            elseif have_color && c == ir
                                colors[b3+1] = _ply_normalize_color(
                                    val, types[c], v + 1, prop[2])
                            elseif have_color && c == ig
                                colors[b3+2] = _ply_normalize_color(
                                    val, types[c], v + 1, prop[2])
                            elseif have_color && c == ib
                                colors[b3+3] = _ply_normalize_color(
                                    val, types[c], v + 1, prop[2])
                            elseif have_uv && c == ius
                                uvs[2v+1] = val
                            elseif have_uv && c == ivt
                                uvs[2v+2] = val
                            end
                        end
                    end
                end
                i = p
            else
                # Binary: read every property in declared order; keep the roles.
                for v in 0:ecount-1
                    b3 = v * 3
                    for (c, p) in enumerate(props)
                        if p[1] !== :scalar
                            # A list property on the vertex element (rare but
                            # legal) is count + items; consume both so the byte
                            # cursor stays aligned for the next vertex instead of
                            # reading a single value and desyncing every row after.
                            cnt, i = read_binary(body, i, p[3])
                            nitems = checked_list_count(cnt)
                            i = _ply_checked_binary_skip(i, n, _ply_checked_mul(
                                nitems, _PLY_SIZE[p[4]], "list payload byte count"))
                            continue
                        end
                        val, i = read_binary(body, i, types[c])
                        val = _ply_checked_finite_vertex(val, v + 1, p[2])
                        if c == ix; positions[b3+1] = val
                        elseif c == iy; positions[b3+2] = val
                        elseif c == iz; positions[b3+3] = val
                        elseif have_normals && c == inx; normals[b3+1] = val
                        elseif have_normals && c == iny; normals[b3+2] = val
                        elseif have_normals && c == inz; normals[b3+3] = val
                        elseif have_color && c == ir
                            colors[b3+1] = _ply_normalize_color(
                                val, types[c], v + 1, p[2])
                        elseif have_color && c == ig
                            colors[b3+2] = _ply_normalize_color(
                                val, types[c], v + 1, p[2])
                        elseif have_color && c == ib
                            colors[b3+3] = _ply_normalize_color(
                                val, types[c], v + 1, p[2])
                        elseif have_uv && c == ius; uvs[2v+1] = val
                        elseif have_uv && c == ivt; uvs[2v+2] = val
                        end
                    end
                end
            end
        elseif ename == "face"
            # Prefer the conventional named vertex-index list. Fall back to the
            # first list for files that use a non-standard property name.
            list_col = findfirst(
                p -> p[1] === :list &&
                     (p[2] == "vertex_indices" || p[2] == "vertex_index"),
                props,
            )
            list_col === nothing &&
                (list_col = findfirst(p -> p[1] === :list, props))
            list_col === nothing && error("PLY face element has no list property")
            face_hint = _ply_checked_mul(ecount, 3, "face index hint")
            sizehint!(indices, _ply_checked_add(
                length(indices), face_hint, "face index hint"))
            if format == :ascii
                nverts = length(positions) ÷ 3
                p = i
                for face_row in 1:ecount
                    for (prop_col, prop) in enumerate(props)
                        first, last, p = _ply_next_ascii_token(body, p, n)
                        first != 0 ||
                            _ply_ascii_missing_property_error(
                                "face", face_row, prop[2])
                        if prop[1] === :scalar
                            _ply_validate_ascii_property_value(
                                body, first, last, "face", face_row,
                                prop[2], prop[3])
                            continue
                        end
                        raw_count = _ply_parse_ascii_face_float(
                            body, first, last, face_row, :count)
                        count_value = _ply_ascii_typed_value(
                            raw_count, prop[3], "face", face_row, prop[2])
                        nitems = checked_list_count(count_value)
                        first_idx = prev_idx = third_idx = 0
                        for k in 1:nitems
                            first, last, p = _ply_next_ascii_token(body, p, n)
                            first != 0 ||
                                _ply_ascii_missing_property_error(
                                    "face", face_row, prop[2])
                            if prop_col == list_col
                                raw_index = _ply_parse_ascii_face_float(
                                    body, first, last, face_row, :index, k)
                                typed_index = _ply_ascii_typed_value(
                                    raw_index, prop[4], "face", face_row,
                                    prop[2], k)
                                idx = checked_vertex_index(typed_index, nverts)
                                first_idx, prev_idx, third_idx = _ply_polygon_corner!(
                                    indices, k, nitems, idx, first_idx, prev_idx,
                                    third_idx)
                            else
                                _ply_validate_ascii_property_value(
                                    body, first, last, "face", face_row,
                                    prop[2], prop[4], k)
                            end
                        end
                    end
                end
                i = p
            else
                nverts = length(positions) ÷ 3
                for face_row in 1:ecount
                    for (prop_col, prop) in enumerate(props)
                        if prop[1] === :scalar
                            _, i = read_binary(body, i, prop[3])
                            continue
                        end
                        cnt, i = read_binary(body, i, prop[3])
                        # A signed count type (e.g. `char`) can decode negative;
                        # validate before consuming the declared list payload.
                        nitems = checked_list_count(cnt)
                        if prop_col != list_col
                            i = _ply_checked_binary_skip(i, n, _ply_checked_mul(
                                nitems, _PLY_SIZE[prop[4]],
                                "list payload byte count"))
                            continue
                        end
                        first_idx = prev_idx = third_idx = 0
                        for k in 1:nitems
                            val, i = read_binary(body, i, prop[4])
                            idx = checked_vertex_index(val, nverts) # 0-based
                            first_idx, prev_idx, third_idx = _ply_polygon_corner!(
                                indices, k, nitems, idx, first_idx, prev_idx,
                                third_idx)
                        end
                    end
                end
            end
        else
            # Unknown element: skip its rows so the byte cursor stays aligned.
            if format == :ascii
                for row in 1:ecount
                    for prop in props
                        first, last, i = _ply_next_ascii_token(body, i, n)
                        first != 0 ||
                            _ply_ascii_missing_property_error(ename, row, prop[2])
                        if prop[1] === :scalar
                            _ply_validate_ascii_property_value(
                                body, first, last, ename, row, prop[2], prop[3])
                            continue
                        end
                        nitems = checked_list_count(_ply_validate_ascii_property_value(
                            body, first, last, ename, row, prop[2], prop[3]))
                        for item in 1:nitems
                            first, last, i = _ply_next_ascii_token(body, i, n)
                            first != 0 ||
                                _ply_ascii_missing_property_error(ename, row, prop[2])
                            _ply_validate_ascii_property_value(
                                body, first, last, ename, row, prop[2], prop[4], item)
                        end
                    end
                end
            else
                isempty(props) && continue
                for _ in 0:ecount-1
                    for p in props
                        if p[1] === :scalar
                            i = _ply_checked_binary_skip(i, n, _PLY_SIZE[p[3]])
                        else
                            cnt, i = read_binary(body, i, p[3])
                            nitems = checked_list_count(cnt)
                            i = _ply_checked_binary_skip(i, n, _ply_checked_mul(
                                nitems, _PLY_SIZE[p[4]], "list payload byte count"))
                        end
                    end
                end
            end
        end
    end

    nverts = length(positions) ÷ 3
    nfaces = length(indices) ÷ 3
    geo = BufferGeometry(positions, have_normals ? normals : Float64[],
                         have_uv ? uvs : Float64[], indices, nverts, nfaces)
    have_normals || compute_vertex_normals!(geo)
    have_color && set_attribute!(geo, :color, colors, 3)
    return geo
end
