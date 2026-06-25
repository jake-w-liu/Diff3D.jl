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
    nv = geo.n_vertices
    acc = zeros(Float64, nv * 3)
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

"""
    save_stl_binary(path, geo) -> path

Write `geo` as a binary STL file (per-triangle facet normals computed from
geometry).  Round-trips with [`load_stl`](@ref).
"""
function save_stl_binary(path::String, geo::BufferGeometry)
    open(path, "w") do io
        write(io, zeros(UInt8, 80))                 # 80-byte header
        write(io, UInt32(geo.n_faces))
        for fi in 1:geo.n_faces
            i1, i2, i3 = get_face(geo, fi)
            v1 = get_vertex(geo, i1); v2 = get_vertex(geo, i2); v3 = get_vertex(geo, i3)
            n = compute_face_normal(geo, fi)
            for c in (Float32(n.x), Float32(n.y), Float32(n.z))
                write(io, c)
            end
            for v in (v1, v2, v3)
                write(io, Float32(v.x)); write(io, Float32(v.y)); write(io, Float32(v.z))
            end
            write(io, UInt16(0))                     # attribute byte count
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
        head[off+1:off+5] == b"solid" && return false
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
            for _v in 1:3
                x = Float64(read(io, Float32)); y = Float64(read(io, Float32)); z = Float64(read(io, Float32))
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
    value = tryparse(Float64, String(tok))
    value === nothing && error("ASCII STL $context must be a number")
    return value
end

function _load_stl_ascii(path::String)
    positions = Float64[]; normals = Float64[]; indices = Int[]
    cur_n = (0.0, 0.0, 0.0); vi = 0; vertices_in_facet = 0; in_facet = false
    for raw in eachline(path)
        line = strip(raw)
        if startswith(line, "facet normal")
            !in_facet || error("ASCII STL nested facet is invalid")
            t = split(line)
            length(t) >= 5 || error("ASCII STL facet normal requires 3 components")
            cur_n = (
                _stl_parse_ascii_float(t[3], "facet normal x"),
                _stl_parse_ascii_float(t[4], "facet normal y"),
                _stl_parse_ascii_float(t[5], "facet normal z"),
            )
            in_facet = true
            vertices_in_facet = 0
        elseif startswith(line, "vertex")
            in_facet || error("ASCII STL vertex appears outside a facet")
            t = split(line)
            length(t) >= 4 || error("ASCII STL vertex requires 3 coordinates")
            vertices_in_facet < 3 || error("ASCII STL facet has more than 3 vertices")
            push!(positions,
                  _stl_parse_ascii_float(t[2], "vertex x"),
                  _stl_parse_ascii_float(t[3], "vertex y"),
                  _stl_parse_ascii_float(t[4], "vertex z"))
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
    label = String(kind)
    raw = tryparse(Int, String(tok))
    raw === nothing && error("OBJ $label index must be an integer")
    raw == 0 && error("OBJ $label index 0 is invalid")
    idx = raw < 0 ? count + raw + 1 : raw
    1 <= idx <= count ||
        error("OBJ $label index $raw out of bounds for $count $(_obj_index_count_label(kind))")
    return idx
end

function _obj_require_values(tokens, count::Int, label::String)
    length(tokens) >= count + 1 ||
        error("OBJ $label requires $count $(count == 1 ? "value" : "values")")
end

function _obj_parse_float(tok, label::String)
    value = tryparse(Float64, String(tok))
    value === nothing && error("OBJ $label must be a number")
    return value
end

function _obj_parse_vec3(tokens, label::String)
    _obj_require_values(tokens, 3, label)
    return (_obj_parse_float(tokens[2], "$label x"),
            _obj_parse_float(tokens[3], "$label y"),
            _obj_parse_float(tokens[4], "$label z"))
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
    out_vi = 0

    for raw in eachline(path)
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        t = split(line)
        tag = t[1]
        if tag == "v"
            x, y, z = _obj_parse_vec3(t, "v")
            push!(verts, x, y, z)
        elseif tag == "vt"
            _obj_require_values(t, 1, "vt")
            # A 1-D texture coordinate (`vt u`) is valid; treat the missing
            # second component as 0.0 (matching three.js OBJLoader) instead of
            # indexing past the end of the token list with a BoundsError.
            push!(file_uvs, _obj_parse_float(t[2], "vt u"),
                  length(t) >= 3 ? _obj_parse_float(t[3], "vt v") : 0.0)
        elseif tag == "vn"
            x, y, z = _obj_parse_vec3(t, "vn")
            push!(file_normals, x, y, z)
            have_normals = true
        elseif tag == "f"
            nverts_v = length(verts) ÷ 3
            nverts_uv = length(file_uvs) ÷ 2
            nverts_n = length(file_normals) ÷ 3
            corners = t[2:end]
            length(corners) >= 3 || error("OBJ face requires at least 3 vertices")
            # Fan-triangulate polygon (corner 1, k, k+1).
            for k in 2:(length(corners) - 1)
                for c in (corners[1], corners[k], corners[k+1])
                    sub = split(c, '/')
                    vidx = _obj_checked_index(sub[1], nverts_v, :vertex)
                    base = (vidx - 1) * 3
                    push!(out_pos, verts[base+1], verts[base+2], verts[base+3])
                    if length(sub) >= 2 && !isempty(sub[2])
                        uidx = _obj_checked_index(sub[2], nverts_uv, :uv)
                        ub = (uidx - 1) * 2
                        push!(out_uvs, file_uvs[ub+1], file_uvs[ub+2])
                        have_uvs = true
                    else
                        push!(out_uvs, 0.0, 0.0)
                    end
                    if have_normals && length(sub) >= 3 && !isempty(sub[3])
                        nidx = _obj_checked_index(sub[3], nverts_n, :normal)
                        nb = (nidx - 1) * 3
                        push!(out_nrm, file_normals[nb+1], file_normals[nb+2], file_normals[nb+3])
                    else
                        push!(out_nrm, 0.0, 0.0, 0.0)
                    end
                    out_vi += 1; push!(indices, out_vi)
                end
            end
        end
    end
    nfaces = length(indices) ÷ 3
    geo = BufferGeometry(out_pos, out_nrm, have_uvs ? out_uvs : Float64[],
                         indices, out_vi, nfaces)
    # Recompute smooth normals when the file had none, or when ANY emitted vertex
    # normal is zero-length (e.g. a face lacked vn) — otherwise those vertices
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
    return geo
end

# ========================== XYZ ==========================

function _xyz_parse_float(tok::AbstractString, line_no::Int, field::String)
    value = try
        parse(Float64, tok)
    catch err
        throw(ArgumentError("XYZ line $line_no has invalid $field value $(repr(tok))"))
    end
    isfinite(value) || throw(ArgumentError("XYZ line $line_no has non-finite $field value"))
    return value
end

function _xyz_parse_color(tok::AbstractString, line_no::Int, field::String)
    value = _xyz_parse_float(tok, line_no, field)
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
    colors = Float64[]
    layout = nothing
    line_no = 0
    for raw in split(text, '\n'; keepempty=true)
        line_no += 1
        line = strip(raw)
        (isempty(line) || startswith(line, "#")) && continue
        toks = split(line)
        record_layout = if length(toks) == 3
            :xyz
        elseif length(toks) == 6
            :xyzrgb
        else
            throw(ArgumentError("XYZ line $line_no in $source has $(length(toks)) fields; expected 3 or 6"))
        end
        if layout === nothing
            layout = record_layout
        elseif layout !== record_layout
            throw(ArgumentError("XYZ line $line_no in $source mixes XYZ and XYZRGB records"))
        end
        push!(positions,
              _xyz_parse_float(toks[1], line_no, "x"),
              _xyz_parse_float(toks[2], line_no, "y"),
              _xyz_parse_float(toks[3], line_no, "z"))
        if record_layout === :xyzrgb
            push!(colors,
                  _xyz_parse_color(toks[4], line_no, "red"),
                  _xyz_parse_color(toks[5], line_no, "green"),
                  _xyz_parse_color(toks[6], line_no, "blue"))
        end
    end
    nverts = length(positions) ÷ 3
    geo = BufferGeometry(positions, Float64[], Float64[], Int[], nverts, 0)
    layout === :xyzrgb && set_attribute!(geo, :color, colors, 3)
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
    value = tryparse(Float64, String(tok))
    value === nothing && error("PLY $context must be a number")
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
                    toks = split(strip(next_line()))
                    length(toks) >= length(props) ||
                        error("PLY vertex data is truncated: expected $ecount vertices, row $(v+1) has $(length(toks)) of $(length(props)) values")
                    row = [
                        _ply_parse_ascii_float(tok, "vertex row $(v+1) $(j <= length(props) ? "property $(props[j][2])" : "value $j")")
                        for (j, tok) in enumerate(toks)
                    ]
                    b3 = v * 3
                    positions[b3+1] = row[ix]; positions[b3+2] = row[iy]; positions[b3+3] = row[iz]
                    if have_normals
                        normals[b3+1] = row[inx]; normals[b3+2] = row[iny]; normals[b3+3] = row[inz]
                    end
                    if have_color
                        colors[b3+1] = row[ir]/cnorm; colors[b3+2] = row[ig]/cnorm; colors[b3+3] = row[ib]/cnorm
                    end
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
            if format == :ascii
                nverts = length(positions) ÷ 3
                for face_row in 1:ecount
                    toks = split(strip(next_line()))
                    !isempty(toks) || error("PLY face data is truncated: row $face_row has no list count")
                    nidx = checked_list_count(_ply_parse_ascii_float(toks[1], "face row $face_row list count"))
                    length(toks) >= 1 + nidx ||
                        error("PLY face data is truncated: row $face_row declares $nidx indices but has $(length(toks) - 1)")
                    fan = [
                        checked_vertex_index(
                            _ply_parse_ascii_float(toks[1+k], "face row $face_row vertex index $k"),
                            nverts,
                        )
                        for k in 1:nidx
                    ]   # 0-based vertex indices
                    for k in 2:(nidx - 1)
                        push!(indices, fan[1] + 1, fan[k] + 1, fan[k+1] + 1)
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
                    fan = Vector{Int}(undef, nidx)
                    for k in 1:nidx
                        val, i = read_binary(bytes, i, it)
                        fan[k] = checked_vertex_index(val, nverts)        # 0-based
                    end
                    for k in 2:(nidx - 1)
                        push!(indices, fan[1] + 1, fan[k] + 1, fan[k+1] + 1)
                    end
                end
            end
        else
            # Unknown element: skip its rows so the byte cursor stays aligned.
            if format == :ascii
                for _ in 0:ecount-1; next_line(); end
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
