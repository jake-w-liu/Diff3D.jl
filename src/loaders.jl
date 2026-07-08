# --------------------------------------------------------------------------
# Mesh loaders/writers: STL (binary + ASCII) and OBJ, plus smooth-normal
# computation. Loaders return a BufferGeometry usable by the rasterizer.
# Pure Julia, no external dependencies.
# --------------------------------------------------------------------------

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
        fill!(geo.normals, 0.0)
    else
        zeros(Float64, nv * 3)
    end
    @inbounds for fi in 1:geo.n_faces
        i1, i2, i3 = get_face(geo, fi)
        v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
        # Cross product is proportional to face area, giving area weighting.
        fn = cross(v2 - v1, v3 - v1)
        for idx in (i1, i2, i3)
            base = (idx - 1) * 3
            acc[base+1] += fn.x; acc[base+2] += fn.y; acc[base+3] += fn.z
        end
    end
    @inbounds for vi in 1:nv
        base = (vi - 1) * 3
        nx, ny, nz = acc[base+1], acc[base+2], acc[base+3]
        len = sqrt(nx*nx + ny*ny + nz*nz)
        if len > 1e-20
            acc[base+1] = nx/len; acc[base+2] = ny/len; acc[base+3] = nz/len
        else
            acc[base+1] = 0.0; acc[base+2] = 0.0; acc[base+3] = 1.0
        end
    end
    geo.normals = acc
    return geo
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

"""
    save_stl_binary(path, geo) -> path

Write `geo` as a binary STL file (per-triangle facet normals computed from
geometry).  Round-trips with [`load_stl`](@ref).
"""
function save_stl_binary(path::String, geo::BufferGeometry)
    _validate_triangle_geometry_indices(geo, "save_stl_binary")
    geo.n_faces <= typemax(UInt32) ||
        throw(ArgumentError("save_stl_binary supports at most $(typemax(UInt32)) faces"))
    record = Vector{UInt8}(undef, _STL_BINARY_FACET_BYTES)
    open(path, "w") do io
        write(io, _STL_BINARY_ZERO_HEADER)          # 80-byte header
        _stl_put_u32_le!(record, 1, UInt32(geo.n_faces))
        unsafe_write(io, pointer(record), UInt(4))
        @inbounds for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
            n = normalize(cross(v2 - v1, v3 - v1))
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
"""
function load_stl(path::String)
    _looks_binary_stl(path) && return _load_stl_binary(path)
    geo = _load_stl_ascii(path)
    # Defense in depth: a non-empty file yielding zero faces was almost
    # certainly misdetected as ASCII (or is corrupt) — warn instead of
    # silently returning an empty mesh.
    geo.n_faces == 0 && filesize(path) > 0 &&
        @warn "load_stl: parsed zero faces from non-empty file" path
    return geo
end

function _load_stl_binary(path::String)
    open(path, "r") do io
        seek(io, 80)
        ntri = Int(read(io, UInt32))
        # A binary STL is exactly 84 + 50*ntri bytes; reject a truncated/corrupt
        # file (or absurd count) before allocating ntri*9 floats / reading past EOF.
        filesize(path) >= 84 + 50 * ntri ||
            error("binary STL declares $ntri triangles but the file is only $(filesize(path)) bytes (truncated/corrupt)")
        positions = Vector{Float64}(undef, ntri * 9)
        normals = Vector{Float64}(undef, ntri * 9)
        indices = Vector{Int}(undef, ntri * 3)
        p = 1; vi = 0
        for _ in 1:ntri
            nx = Float64(read(io, Float32)); ny = Float64(read(io, Float32)); nz = Float64(read(io, Float32))
            isfinite(nx) || error("binary STL facet normal x must be finite")
            isfinite(ny) || error("binary STL facet normal y must be finite")
            isfinite(nz) || error("binary STL facet normal z must be finite")
            for _v in 1:3
                x = Float64(read(io, Float32)); y = Float64(read(io, Float32)); z = Float64(read(io, Float32))
                isfinite(x) || error("binary STL vertex x must be finite")
                isfinite(y) || error("binary STL vertex y must be finite")
                isfinite(z) || error("binary STL vertex z must be finite")
                positions[p] = x; positions[p+1] = y; positions[p+2] = z
                normals[p] = nx; normals[p+1] = ny; normals[p+2] = nz
                p += 3; vi += 1; indices[vi] = vi
            end
            read(io, UInt16)                         # attribute byte count
        end
        return BufferGeometry(positions, normals, Float64[], indices, ntri * 3, ntri)
    end
end

function _stl_parse_ascii_float(tok, context::String)
    value = tryparse(Float64, tok)
    value === nothing && error("ASCII STL $context must be a number")
    isfinite(value) || error("ASCII STL $context must be finite")
    return value
end

@inline function _stl_required_token(parts, state, message::String)
    token_state = iterate(parts, state)
    token_state === nothing && error(message)
    return token_state
end

function _load_stl_ascii(path::String)
    positions = Float64[]; normals = Float64[]; indices = Int[]
    cur_n = (0.0, 0.0, 0.0); vi = 0; vertices_in_facet = 0; in_facet = false
    for raw in eachline(path)
        line = strip(raw)
        if startswith(line, "facet normal")
            !in_facet || error("ASCII STL nested facet is invalid")
            parts = eachsplit(line)
            first_state = iterate(parts)
            first_state === nothing && error("ASCII STL facet normal requires 3 components")
            second_state = _stl_required_token(parts, first_state[2],
                                               "ASCII STL facet normal requires 3 components")
            nx_state = _stl_required_token(parts, second_state[2],
                                           "ASCII STL facet normal requires 3 components")
            ny_state = _stl_required_token(parts, nx_state[2],
                                           "ASCII STL facet normal requires 3 components")
            nz_state = _stl_required_token(parts, ny_state[2],
                                           "ASCII STL facet normal requires 3 components")
            cur_n = (
                _stl_parse_ascii_float(nx_state[1], "facet normal x"),
                _stl_parse_ascii_float(ny_state[1], "facet normal y"),
                _stl_parse_ascii_float(nz_state[1], "facet normal z"),
            )
            in_facet = true
            vertices_in_facet = 0
        elseif startswith(line, "vertex")
            in_facet || error("ASCII STL vertex appears outside a facet")
            parts = eachsplit(line)
            first_state = iterate(parts)
            first_state === nothing && error("ASCII STL vertex requires 3 coordinates")
            x_state = _stl_required_token(parts, first_state[2],
                                          "ASCII STL vertex requires 3 coordinates")
            y_state = _stl_required_token(parts, x_state[2],
                                          "ASCII STL vertex requires 3 coordinates")
            z_state = _stl_required_token(parts, y_state[2],
                                          "ASCII STL vertex requires 3 coordinates")
            vertices_in_facet < 3 || error("ASCII STL facet has more than 3 vertices")
            push!(positions,
                  _stl_parse_ascii_float(x_state[1], "vertex x"),
                  _stl_parse_ascii_float(y_state[1], "vertex y"),
                  _stl_parse_ascii_float(z_state[1], "vertex z"))
            push!(normals, cur_n[1], cur_n[2], cur_n[3])
            vi += 1; push!(indices, vi)
            vertices_in_facet += 1
        elseif startswith(line, "endfacet")
            in_facet || error("ASCII STL endfacet appears outside a facet")
            vertices_in_facet == 3 ||
                error("ASCII STL facet has $vertices_in_facet vertices; expected 3")
            in_facet = false
            vertices_in_facet = 0
        end
    end
    !in_facet || error("ASCII STL facet is missing endfacet")
    rem(length(indices), 3) == 0 ||
        error("ASCII STL vertex count $(length(indices)) is not divisible by 3")
    nfaces = length(indices) ÷ 3
    return BufferGeometry(positions, normals, Float64[], indices, vi, nfaces)
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

function _obj_emit_corner!(out_pos::Vector{Float64}, out_uvs::Vector{Float64},
                           out_nrm::Vector{Float64}, indices::Vector{Int},
                           verts::Vector{Float64}, file_uvs::Vector{Float64},
                           file_normals::Vector{Float64}, corner::NTuple{3,Int},
                           out_vi::Int, have_uvs::Bool, have_normals::Bool,
                           missing_normals::Bool)
    vidx, uidx, nidx = corner
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

function _obj_scan_counts(path::String)
    n_vertices = 0
    n_uvs = 0
    n_normals = 0
    n_triangles = 0
    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        parts = eachsplit(line)
        state = iterate(parts)
        state === nothing && continue
        tag = state[1]
        if tag == "v"
            n_vertices += 1
        elseif tag == "vt"
            n_uvs += 1
        elseif tag == "vn"
            n_normals += 1
        elseif tag == "f"
            corners = 0
            next_state = iterate(parts, state[2])
            while next_state !== nothing
                corners += 1
                next_state = iterate(parts, next_state[2])
            end
            corners >= 3 && (n_triangles += corners - 2)
        end
    end
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

function _obj_parse_vec3_tokens(parts, state, label::String)
    x_state = _obj_required_token(parts, state, 3, label)
    y_state = _obj_required_token(parts, x_state[2], 3, label)
    z_state = _obj_required_token(parts, y_state[2], 3, label)
    return (_obj_parse_float(x_state[1], "$label x"),
            _obj_parse_float(y_state[1], "$label y"),
            _obj_parse_float(z_state[1], "$label z"))
end

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
polygons fan-triangulated). Normals are taken from the file when present,
otherwise computed smoothly. Materials are ignored.
"""
function load_obj(path::String)
    verts = Float64[]            # v
    file_uvs = Float64[]         # vt
    file_normals = Float64[]     # vn
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

    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        if _obj_is_face_record(line)
            nverts_v = length(verts) ÷ 3
            nverts_uv = length(file_uvs) ÷ 2
            nverts_n = length(file_normals) ÷ 3
            parts = eachsplit(line)
            tag_state = iterate(parts)
            first_state = iterate(parts, tag_state[2])
            second_state = first_state === nothing ? nothing : iterate(parts, first_state[2])
            third_state = second_state === nothing ? nothing : iterate(parts, second_state[2])
            third_state === nothing && error("OBJ face requires at least 3 vertices")
            first_corner = _obj_parse_corner(first_state[1], nverts_v, nverts_uv, nverts_n)
            prev_corner = _obj_parse_corner(second_state[1], nverts_v, nverts_uv, nverts_n)
            corner = _obj_parse_corner(third_state[1], nverts_v, nverts_uv, nverts_n)
            while true
                out_vi, have_uvs, have_normals, missing_normals =
                    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                                      file_uvs, file_normals, first_corner, out_vi,
                                      have_uvs, have_normals, missing_normals)
                out_vi, have_uvs, have_normals, missing_normals =
                    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                                      file_uvs, file_normals, prev_corner, out_vi,
                                      have_uvs, have_normals, missing_normals)
                out_vi, have_uvs, have_normals, missing_normals =
                    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                                      file_uvs, file_normals, corner, out_vi,
                                      have_uvs, have_normals, missing_normals)
                prev_corner = corner
                next_state = iterate(parts, third_state[2])
                next_state === nothing && break
                corner = _obj_parse_corner(next_state[1], nverts_v, nverts_uv, nverts_n)
                third_state = next_state
            end
            continue
        end
        parts = eachsplit(line)
        tag_state = iterate(parts)
        tag_state === nothing && continue
        tag = tag_state[1]
        if tag == "v"
            x, y, z = _obj_parse_vec3_tokens(parts, tag_state[2], "v")
            push!(verts, x, y, z)
        elseif tag == "vt"
            # A 1-D texture coordinate (`vt u`) is valid; treat the missing
            # second component as 0.0 (matching three.js OBJLoader) instead of
            # indexing past the end of the token list with a BoundsError.
            u, v = _obj_parse_vt_tokens(parts, tag_state[2])
            push!(file_uvs, u, v)
        elseif tag == "vn"
            x, y, z = _obj_parse_vec3_tokens(parts, tag_state[2], "vn")
            push!(file_normals, x, y, z)
        elseif tag == "f"
            nverts_v = length(verts) ÷ 3
            nverts_uv = length(file_uvs) ÷ 2
            nverts_n = length(file_normals) ÷ 3
            first_state = iterate(parts, tag_state[2])
            second_state = first_state === nothing ? nothing : iterate(parts, first_state[2])
            third_state = second_state === nothing ? nothing : iterate(parts, second_state[2])
            third_state === nothing && error("OBJ face requires at least 3 vertices")
            first_corner = _obj_parse_corner(first_state[1], nverts_v, nverts_uv, nverts_n)
            prev_corner = _obj_parse_corner(second_state[1], nverts_v, nverts_uv, nverts_n)
            corner = _obj_parse_corner(third_state[1], nverts_v, nverts_uv, nverts_n)
            # Fan-triangulate polygon (corner 1, k, k+1).
            while true
                out_vi, have_uvs, have_normals, missing_normals =
                    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                                      file_uvs, file_normals, first_corner, out_vi,
                                      have_uvs, have_normals, missing_normals)
                out_vi, have_uvs, have_normals, missing_normals =
                    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                                      file_uvs, file_normals, prev_corner, out_vi,
                                      have_uvs, have_normals, missing_normals)
                out_vi, have_uvs, have_normals, missing_normals =
                    _obj_emit_corner!(out_pos, out_uvs, out_nrm, indices, verts,
                                      file_uvs, file_normals, corner, out_vi,
                                      have_uvs, have_normals, missing_normals)
                prev_corner = corner
                next_state = iterate(parts, third_state[2])
                next_state === nothing && break
                corner = _obj_parse_corner(next_state[1], nverts_v, nverts_uv, nverts_n)
                third_state = next_state
            end
        end
    end
    nfaces = length(indices) ÷ 3
    geo = BufferGeometry(out_pos, out_nrm, have_uvs ? out_uvs : Float64[],
                         indices, out_vi, nfaces)
    # Recompute smooth normals when the file had none, or when ANY emitted vertex
    # normal is zero-length (e.g. a face lacked vn) — otherwise those vertices
    # keep a degenerate (0,0,0) normal and shade black.
    needs_recompute = !have_normals || missing_normals
    if !needs_recompute
        @inbounds for b in 1:3:length(out_nrm)
            if out_nrm[b] == 0.0 && out_nrm[b+1] == 0.0 && out_nrm[b+2] == 0.0
                needs_recompute = true
                break
            end
        end
    end
    needs_recompute && compute_vertex_normals!(geo)
    return geo
end

# ========================== XYZ ==========================

@noinline _xyz_invalid_float(line_no::Int, field::String) =
    throw(ArgumentError("XYZ line $line_no has invalid $field value"))
@noinline _xyz_nonfinite_float(line_no::Int, field::String) =
    throw(ArgumentError("XYZ line $line_no has non-finite $field value"))

function _xyz_parse_float(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                          line_no::Int, field::String)
    sign = 1.0
    p = first
    if p <= last && (bytes[p] == UInt8('+') || bytes[p] == UInt8('-'))
        bytes[p] == UInt8('-') && (sign = -1.0)
        p += 1
    end
    if p <= last
        if _ply_ascii_token_eq(bytes, p, last, "nan")
            _xyz_nonfinite_float(line_no, field)
        elseif _ply_ascii_token_eq(bytes, p, last, "inf") ||
               _ply_ascii_token_eq(bytes, p, last, "infinity")
            _xyz_nonfinite_float(line_no, field)
        end
    end

    value = 0.0
    digits = 0
    @inbounds while p <= last && _ply_ascii_digit(bytes[p])
        value = value * 10.0 + Float64(bytes[p] - UInt8('0'))
        p += 1
        digits += 1
    end
    if p <= last && bytes[p] == UInt8('.')
        p += 1
        scale = 0.1
        @inbounds while p <= last && _ply_ascii_digit(bytes[p])
            value += Float64(bytes[p] - UInt8('0')) * scale
            scale *= 0.1
            p += 1
            digits += 1
        end
    end
    digits > 0 || _xyz_invalid_float(line_no, field)
    if p <= last && (bytes[p] == UInt8('e') || bytes[p] == UInt8('E'))
        p += 1
        exp_sign = 1
        if p <= last && (bytes[p] == UInt8('+') || bytes[p] == UInt8('-'))
            bytes[p] == UInt8('-') && (exp_sign = -1)
            p += 1
        end
        exp_value = 0
        exp_digits = 0
        @inbounds while p <= last && _ply_ascii_digit(bytes[p])
            exp_value = min(exp_value * 10 + Int(bytes[p] - UInt8('0')), 10_000)
            p += 1
            exp_digits += 1
        end
        exp_digits > 0 || _xyz_invalid_float(line_no, field)
        exp_value *= exp_sign
        value = exp_value > 308 ? Inf :
                exp_value < -324 ? 0.0 :
                value * (10.0 ^ exp_value)
    end
    p == last + 1 || _xyz_invalid_float(line_no, field)
    value *= sign
    isfinite(value) || _xyz_nonfinite_float(line_no, field)
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
    bytes = codeunits(text)
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
    b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\r') || b == UInt8('\n')
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

@inline function _ply_try_parse_ascii_float(bytes::AbstractVector{UInt8},
                                            first::Int, last::Int)
    sign = 1.0
    p = first
    if p <= last && (bytes[p] == UInt8('+') || bytes[p] == UInt8('-'))
        bytes[p] == UInt8('-') && (sign = -1.0)
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

    value = 0.0
    digits = 0
    @inbounds while p <= last && _ply_ascii_digit(bytes[p])
        value = value * 10.0 + Float64(bytes[p] - UInt8('0'))
        p += 1
        digits += 1
    end
    if p <= last && bytes[p] == UInt8('.')
        p += 1
        scale = 0.1
        @inbounds while p <= last && _ply_ascii_digit(bytes[p])
            value += Float64(bytes[p] - UInt8('0')) * scale
            scale *= 0.1
            p += 1
            digits += 1
        end
    end
    digits > 0 || return 0.0, UInt8(1)
    if p <= last && (bytes[p] == UInt8('e') || bytes[p] == UInt8('E'))
        p += 1
        exp_sign = 1
        if p <= last && (bytes[p] == UInt8('+') || bytes[p] == UInt8('-'))
            bytes[p] == UInt8('-') && (exp_sign = -1)
            p += 1
        end
        exp_value = 0
        exp_digits = 0
        @inbounds while p <= last && _ply_ascii_digit(bytes[p])
            exp_value = min(exp_value * 10 + Int(bytes[p] - UInt8('0')), 10_000)
            p += 1
            exp_digits += 1
        end
        exp_digits > 0 || return 0.0, UInt8(1)
        exp_value *= exp_sign
        value = exp_value > 308 ? Inf :
                exp_value < -324 ? 0.0 :
                value * (10.0 ^ exp_value)
    end
    p == last + 1 || return 0.0, UInt8(1)
    value *= sign
    isfinite(value) || return 0.0, UInt8(2)
    return value, UInt8(0)
end

@noinline function _ply_ascii_float_context_error(context::String, status::UInt8)
    status == UInt8(2) ? error("PLY $context must be finite") :
                         error("PLY $context must be a number")
end

function _ply_parse_ascii_float(bytes::AbstractVector{UInt8}, first::Int, last::Int,
                                context::String)
    value, status = _ply_try_parse_ascii_float(bytes, first, last)
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
    value, status = _ply_try_parse_ascii_float(bytes, first, last)
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
    value, status = _ply_try_parse_ascii_float(bytes, first, last)
    status == UInt8(0) || _ply_face_ascii_float_error(row, role, k, status)
    return value
end

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
    p + sz - 1 <= length(b) || error("PLY binary element data is truncated")
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
    p + sz - 1 <= length(b) || error("PLY binary element data is truncated")
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
    # Vertex/scalar properties are stored as (:scalar, name, type). A face list
    # property is stored as (:list, name, count_type, index_type).
    elements = Tuple{String,Int,Vector{Any}}[]
    i = 1
    function next_line()
        j = i
        while j <= n && bytes[j] != UInt8('\n'); j += 1; end
        e = j - 1
        e >= i && bytes[e] == UInt8('\r') && (e -= 1)   # strip CRLF
        line = e >= i ? String(bytes[i:e]) : ""
        i = j + 1                   # advance past the newline
        return line
    end

    magic = next_line()
    strip(magic) == "ply" || error("not a PLY file")
    while true
        i <= n || error("PLY header has no end_header")
        line = strip(next_line())
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
            push!(elements, (String(t[2]), _ply_parse_element_count(t[3]), Any[]))
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
                push!(props, (:scalar, String(t[3]), _ply_parse_type(t[2], "property")))
            end
        elseif tag == "end_header"
            break
        end
    end

    # --- Locate vertex/face elements and column roles. ---
    positions = Float64[]; normals = Float64[]; colors = Float64[]
    indices = Int[]
    have_normals = false; have_color = false
    color_is_int = false
    read_binary = format === :binary_big_endian ? _ply_read_be : _ply_read_le
    function checked_binary_skip!(nbytes::Int)
        nbytes >= 0 || error("PLY binary skip size must be non-negative")
        i + nbytes - 1 <= n || error("PLY binary element data is truncated")
        i += nbytes
        return nothing
    end
    function checked_list_count(cnt)
        isfinite(cnt) && cnt >= 0 && cnt == floor(cnt) ||
            error("PLY list property count must be a non-negative integer")
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

    for (ename, ecount, props) in elements
        if ename == "vertex"
            # Map property name -> column index for the roles we read.
            names = String[p[2] for p in props]
            types = Symbol[p[1] === :scalar ? p[3] : :u32 for p in props]
            col(name) = findfirst(==(name), names)
            ix = col("x"); iy = col("y"); iz = col("z")
            (ix === nothing || iy === nothing || iz === nothing) && error("PLY vertex element lacks x/y/z")
            inx = col("nx"); iny = col("ny"); inz = col("nz")
            have_normals = inx !== nothing && iny !== nothing && inz !== nothing
            ir = col("red"); ig = col("green"); ib = col("blue")
            if ir === nothing
                ir = col("r"); ig = col("g"); ib = col("b")
            end
            have_color = ir !== nothing && ig !== nothing && ib !== nothing
            have_color && (color_is_int = _ply_is_int(types[ir]))
            cnorm = color_is_int ? 255.0 : 1.0

            positions = Vector{Float64}(undef, ecount * 3)
            have_normals && (normals = Vector{Float64}(undef, ecount * 3))
            have_color && (colors = Vector{Float64}(undef, ecount * 3))

            if format == :ascii
                for v in 0:ecount-1
                    line_start, line_stop, i = _ply_line_bounds(bytes, i, n)
                    b3 = v * 3
                    p = line_start
                    token_count = 0
                    while true
                        first, last, p = _ply_next_ascii_token(bytes, p, line_stop)
                        first == 0 && break
                        c = (token_count += 1)
                        val = _ply_parse_ascii_vertex_float(bytes, first, last,
                                                            v + 1, c, props)
                        if c == ix; positions[b3+1] = val
                        elseif c == iy; positions[b3+2] = val
                        elseif c == iz; positions[b3+3] = val
                        elseif have_normals && c == inx; normals[b3+1] = val
                        elseif have_normals && c == iny; normals[b3+2] = val
                        elseif have_normals && c == inz; normals[b3+3] = val
                        elseif have_color && c == ir; colors[b3+1] = val / cnorm
                        elseif have_color && c == ig; colors[b3+2] = val / cnorm
                        elseif have_color && c == ib; colors[b3+3] = val / cnorm
                        end
                    end
                    token_count >= length(props) ||
                        error("PLY vertex data is truncated: expected $ecount vertices, row $(v+1) has $token_count of $(length(props)) values")
                end
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
                            cnt, i = read_binary(bytes, i, p[3])
                            nitems = checked_list_count(cnt)
                            checked_binary_skip!(nitems * _PLY_SIZE[p[4]])
                            continue
                        end
                        val, i = read_binary(bytes, i, types[c])
                        val = _ply_checked_finite_vertex(val, v + 1, p[2])
                        if c == ix; positions[b3+1] = val
                        elseif c == iy; positions[b3+2] = val
                        elseif c == iz; positions[b3+3] = val
                        elseif have_normals && c == inx; normals[b3+1] = val
                        elseif have_normals && c == iny; normals[b3+2] = val
                        elseif have_normals && c == inz; normals[b3+3] = val
                        elseif have_color && c == ir; colors[b3+1] = val/cnorm
                        elseif have_color && c == ig; colors[b3+2] = val/cnorm
                        elseif have_color && c == ib; colors[b3+3] = val/cnorm
                        end
                    end
                end
            end
        elseif ename == "face"
            # Find the list property (vertex_indices / vertex_index).
            listp = nothing
            for p in props
                p[1] === :list && (listp = p)
            end
            listp === nothing && error("PLY face element has no list property")
            ct = listp[3]; it = listp[4]
            sizehint!(indices, length(indices) + 3 * ecount)
            if format == :ascii
                nverts = length(positions) ÷ 3
                for face_row in 1:ecount
                    line_start, line_stop, i = _ply_line_bounds(bytes, i, n)
                    p = line_start
                    first, last, p = _ply_next_ascii_token(bytes, p, line_stop)
                    first != 0 || error("PLY face data is truncated: row $face_row has no list count")
                    nidx = checked_list_count(
                        _ply_parse_ascii_face_float(bytes, first, last,
                                                    face_row, :count))
                    first_idx = 0
                    prev_idx = 0
                    for k in 1:nidx
                        first, last, p = _ply_next_ascii_token(bytes, p, line_stop)
                        first != 0 ||
                            error("PLY face data is truncated: row $face_row declares $nidx indices but has $(k - 1)")
                        idx = checked_vertex_index(
                            _ply_parse_ascii_face_float(bytes, first, last,
                                                        face_row, :index, k),
                            nverts,
                        )
                        if k == 1
                            first_idx = idx
                        elseif k == 2
                            prev_idx = idx
                        else
                            push!(indices, first_idx + 1, prev_idx + 1, idx + 1)
                            prev_idx = idx
                        end
                    end
                end
            else
                nverts = length(positions) ÷ 3
                for _ in 0:ecount-1
                    cnt, i = read_binary(bytes, i, ct)
                    # A signed count type (e.g. `char`) can decode negative; validate
                    # before allocating so a corrupt count yields a clear loader
                    # error rather than `invalid GenericMemory size`.
                    nidx = checked_list_count(cnt)
                    first_idx = 0
                    prev_idx = 0
                    for k in 1:nidx
                        val, i = read_binary(bytes, i, it)
                        idx = checked_vertex_index(val, nverts)        # 0-based
                        if k == 1
                            first_idx = idx
                        elseif k == 2
                            prev_idx = idx
                        else
                            push!(indices, first_idx + 1, prev_idx + 1, idx + 1)
                            prev_idx = idx
                        end
                    end
                end
            end
        else
            # Unknown element: skip its rows so the byte cursor stays aligned.
            if format == :ascii
                for _ in 0:ecount-1
                    _, _, i = _ply_line_bounds(bytes, i, n)
                end
            else
                for _ in 0:ecount-1
                    for p in props
                        if p[1] === :scalar
                            checked_binary_skip!(_PLY_SIZE[p[3]])
                        else
                            cnt, i = read_binary(bytes, i, p[3])
                            nitems = checked_list_count(cnt)
                            checked_binary_skip!(nitems * _PLY_SIZE[p[4]])
                        end
                    end
                end
            end
        end
    end

    nverts = length(positions) ÷ 3
    nfaces = length(indices) ÷ 3
    geo = BufferGeometry(positions, have_normals ? normals : Float64[], Float64[],
                         indices, nverts, nfaces)
    have_normals || compute_vertex_normals!(geo)
    have_color && set_attribute!(geo, :color, colors, 3)
    return geo
end
