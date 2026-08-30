# --------------------------------------------------------------------------
# Utah teapot Bezier patch geometry, matching the three.js example add-on data
# and constructor options.
# --------------------------------------------------------------------------

const _TEAPOT_PATCHES = let data = """
0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 3 16 17 18 7 19 20 21 11 22 23 24 15 25 26 27
18 28 29 30 21 31 32 33 24 34 35 36 27 37 38 39 30 40 41 0 33 42 43 4 36 44 45 8 39 46 47 12
12 13 14 15 48 49 50 51 52 53 54 55 56 57 58 59 15 25 26 27 51 60 61 62 55 63 64 65 59 66 67 68
27 37 38 39 62 69 70 71 65 72 73 74 68 75 76 77 39 46 47 12 71 78 79 48 74 80 81 52 77 82 83 56
56 57 58 59 84 85 86 87 88 89 90 91 92 93 94 95 59 66 67 68 87 96 97 98 91 99 100 101 95 102 103 104
68 75 76 77 98 105 106 107 101 108 109 110 104 111 112 113 77 82 83 56 107 114 115 84 110 116 117 88 113 118 119 92
120 121 122 123 124 125 126 127 128 129 130 131 132 133 134 135 123 136 137 120 127 138 139 124 131 140 141 128 135 142 143 132
132 133 134 135 144 145 146 147 148 149 150 151 68 152 153 154 135 142 143 132 147 155 156 144 151 157 158 148 154 159 160 68
161 162 163 164 165 166 167 168 169 170 171 172 173 174 175 176 164 177 178 161 168 179 180 165 172 181 182 169 176 183 184 173
173 174 175 176 185 186 187 188 189 190 191 192 193 194 195 196 176 183 184 173 188 197 198 185 192 199 200 189 196 201 202 193
203 203 203 203 204 205 206 207 208 208 208 208 209 210 211 212 203 203 203 203 207 213 214 215 208 208 208 208 212 216 217 218
203 203 203 203 215 219 220 221 208 208 208 208 218 222 223 224 203 203 203 203 221 225 226 204 208 208 208 208 224 227 228 209
209 210 211 212 229 230 231 232 233 234 235 236 237 238 239 240 212 216 217 218 232 241 242 243 236 244 245 246 240 247 248 249
218 222 223 224 243 250 251 252 246 253 254 255 249 256 257 258 224 227 228 209 252 259 260 229 255 261 262 233 258 263 264 237
265 265 265 265 266 267 268 269 270 271 272 273 92 119 118 113 265 265 265 265 269 274 275 276 273 277 278 279 113 112 111 104
265 265 265 265 276 280 281 282 279 283 284 285 104 103 102 95 265 265 265 265 282 286 287 266 285 288 289 270 95 94 93 92
"""
    values = parse.(Int, split(data))
    length(values) == 32 * 16 ||
        error("internal teapot patch table must contain 32 patches")
    values
end

const _TEAPOT_VERTICES = let data = """
1.4 0.0 2.4 1.4 -0.784 2.4 0.784 -1.4 2.4 0.0 -1.4 2.4 1.3375 0.0 2.53125 1.3375 -0.749 2.53125 0.749 -1.3375 2.53125 0.0 -1.3375 2.53125
1.4375 0.0 2.53125 1.4375 -0.805 2.53125 0.805 -1.4375 2.53125 0.0 -1.4375 2.53125 1.5 0.0 2.4 1.5 -0.84 2.4 0.84 -1.5 2.4 0.0 -1.5 2.4
-0.784 -1.4 2.4 -1.4 -0.784 2.4 -1.4 0.0 2.4 -0.749 -1.3375 2.53125 -1.3375 -0.749 2.53125 -1.3375 0.0 2.53125 -0.805 -1.4375 2.53125 -1.4375 -0.805 2.53125
-1.4375 0.0 2.53125 -0.84 -1.5 2.4 -1.5 -0.84 2.4 -1.5 0.0 2.4 -1.4 0.784 2.4 -0.784 1.4 2.4 0.0 1.4 2.4 -1.3375 0.749 2.53125
-0.749 1.3375 2.53125 0.0 1.3375 2.53125 -1.4375 0.805 2.53125 -0.805 1.4375 2.53125 0.0 1.4375 2.53125 -1.5 0.84 2.4 -0.84 1.5 2.4 0.0 1.5 2.4
0.784 1.4 2.4 1.4 0.784 2.4 0.749 1.3375 2.53125 1.3375 0.749 2.53125 0.805 1.4375 2.53125 1.4375 0.805 2.53125 0.84 1.5 2.4 1.5 0.84 2.4
1.75 0.0 1.875 1.75 -0.98 1.875 0.98 -1.75 1.875 0.0 -1.75 1.875 2.0 0.0 1.35 2.0 -1.12 1.35 1.12 -2.0 1.35 0.0 -2.0 1.35
2.0 0.0 0.9 2.0 -1.12 0.9 1.12 -2.0 0.9 0.0 -2.0 0.9 -0.98 -1.75 1.875 -1.75 -0.98 1.875 -1.75 0.0 1.875 -1.12 -2.0 1.35
-2.0 -1.12 1.35 -2.0 0.0 1.35 -1.12 -2.0 0.9 -2.0 -1.12 0.9 -2.0 0.0 0.9 -1.75 0.98 1.875 -0.98 1.75 1.875 0.0 1.75 1.875
-2.0 1.12 1.35 -1.12 2.0 1.35 0.0 2.0 1.35 -2.0 1.12 0.9 -1.12 2.0 0.9 0.0 2.0 0.9 0.98 1.75 1.875 1.75 0.98 1.875
1.12 2.0 1.35 2.0 1.12 1.35 1.12 2.0 0.9 2.0 1.12 0.9 2.0 0.0 0.45 2.0 -1.12 0.45 1.12 -2.0 0.45 0.0 -2.0 0.45
1.5 0.0 0.225 1.5 -0.84 0.225 0.84 -1.5 0.225 0.0 -1.5 0.225 1.5 0.0 0.15 1.5 -0.84 0.15 0.84 -1.5 0.15 0.0 -1.5 0.15
-1.12 -2.0 0.45 -2.0 -1.12 0.45 -2.0 0.0 0.45 -0.84 -1.5 0.225 -1.5 -0.84 0.225 -1.5 0.0 0.225 -0.84 -1.5 0.15 -1.5 -0.84 0.15
-1.5 0.0 0.15 -2.0 1.12 0.45 -1.12 2.0 0.45 0.0 2.0 0.45 -1.5 0.84 0.225 -0.84 1.5 0.225 0.0 1.5 0.225 -1.5 0.84 0.15
-0.84 1.5 0.15 0.0 1.5 0.15 1.12 2.0 0.45 2.0 1.12 0.45 0.84 1.5 0.225 1.5 0.84 0.225 0.84 1.5 0.15 1.5 0.84 0.15
-1.6 0.0 2.025 -1.6 -0.3 2.025 -1.5 -0.3 2.25 -1.5 0.0 2.25 -2.3 0.0 2.025 -2.3 -0.3 2.025 -2.5 -0.3 2.25 -2.5 0.0 2.25
-2.7 0.0 2.025 -2.7 -0.3 2.025 -3.0 -0.3 2.25 -3.0 0.0 2.25 -2.7 0.0 1.8 -2.7 -0.3 1.8 -3.0 -0.3 1.8 -3.0 0.0 1.8
-1.5 0.3 2.25 -1.6 0.3 2.025 -2.5 0.3 2.25 -2.3 0.3 2.025 -3.0 0.3 2.25 -2.7 0.3 2.025 -3.0 0.3 1.8 -2.7 0.3 1.8
-2.7 0.0 1.575 -2.7 -0.3 1.575 -3.0 -0.3 1.35 -3.0 0.0 1.35 -2.5 0.0 1.125 -2.5 -0.3 1.125 -2.65 -0.3 0.9375 -2.65 0.0 0.9375
-2.0 -0.3 0.9 -1.9 -0.3 0.6 -1.9 0.0 0.6 -3.0 0.3 1.35 -2.7 0.3 1.575 -2.65 0.3 0.9375 -2.5 0.3 1.125 -1.9 0.3 0.6
-2.0 0.3 0.9 1.7 0.0 1.425 1.7 -0.66 1.425 1.7 -0.66 0.6 1.7 0.0 0.6 2.6 0.0 1.425 2.6 -0.66 1.425 3.1 -0.66 0.825
3.1 0.0 0.825 2.3 0.0 2.1 2.3 -0.25 2.1 2.4 -0.25 2.025 2.4 0.0 2.025 2.7 0.0 2.4 2.7 -0.25 2.4 3.3 -0.25 2.4
3.3 0.0 2.4 1.7 0.66 0.6 1.7 0.66 1.425 3.1 0.66 0.825 2.6 0.66 1.425 2.4 0.25 2.025 2.3 0.25 2.1 3.3 0.25 2.4
2.7 0.25 2.4 2.8 0.0 2.475 2.8 -0.25 2.475 3.525 -0.25 2.49375 3.525 0.0 2.49375 2.9 0.0 2.475 2.9 -0.15 2.475 3.45 -0.15 2.5125
3.45 0.0 2.5125 2.8 0.0 2.4 2.8 -0.15 2.4 3.2 -0.15 2.4 3.2 0.0 2.4 3.525 0.25 2.49375 2.8 0.25 2.475 3.45 0.15 2.5125
2.9 0.15 2.475 3.2 0.15 2.4 2.8 0.15 2.4 0.0 0.0 3.15 0.8 0.0 3.15 0.8 -0.45 3.15 0.45 -0.8 3.15 0.0 -0.8 3.15
0.0 0.0 2.85 0.2 0.0 2.7 0.2 -0.112 2.7 0.112 -0.2 2.7 0.0 -0.2 2.7 -0.45 -0.8 3.15 -0.8 -0.45 3.15 -0.8 0.0 3.15
-0.112 -0.2 2.7 -0.2 -0.112 2.7 -0.2 0.0 2.7 -0.8 0.45 3.15 -0.45 0.8 3.15 0.0 0.8 3.15 -0.2 0.112 2.7 -0.112 0.2 2.7
0.0 0.2 2.7 0.45 0.8 3.15 0.8 0.45 3.15 0.112 0.2 2.7 0.2 0.112 2.7 0.4 0.0 2.55 0.4 -0.224 2.55 0.224 -0.4 2.55
0.0 -0.4 2.55 1.3 0.0 2.55 1.3 -0.728 2.55 0.728 -1.3 2.55 0.0 -1.3 2.55 1.3 0.0 2.4 1.3 -0.728 2.4 0.728 -1.3 2.4
0.0 -1.3 2.4 -0.224 -0.4 2.55 -0.4 -0.224 2.55 -0.4 0.0 2.55 -0.728 -1.3 2.55 -1.3 -0.728 2.55 -1.3 0.0 2.55 -0.728 -1.3 2.4
-1.3 -0.728 2.4 -1.3 0.0 2.4 -0.4 0.224 2.55 -0.224 0.4 2.55 0.0 0.4 2.55 -1.3 0.728 2.55 -0.728 1.3 2.55 0.0 1.3 2.55
-1.3 0.728 2.4 -0.728 1.3 2.4 0.0 1.3 2.4 0.224 0.4 2.55 0.4 0.224 2.55 0.728 1.3 2.55 1.3 0.728 2.55 0.728 1.3 2.4
1.3 0.728 2.4 0.0 0.0 0.0 1.425 0.0 0.0 1.425 0.798 0.0 0.798 1.425 0.0 0.0 1.425 0.0 1.5 0.0 0.075 1.5 0.84 0.075
0.84 1.5 0.075 0.0 1.5 0.075 -0.798 1.425 0.0 -1.425 0.798 0.0 -1.425 0.0 0.0 -0.84 1.5 0.075 -1.5 0.84 0.075 -1.5 0.0 0.075
-1.425 -0.798 0.0 -0.798 -1.425 0.0 0.0 -1.425 0.0 -1.5 -0.84 0.075 -0.84 -1.5 0.075 0.0 -1.5 0.075 0.798 -1.425 0.0 1.425 -0.798 0.0
0.84 -1.5 0.075 1.5 -0.84 0.075
"""
    values = parse.(Float64, split(data))
    length(values) == 290 * 3 ||
        error("internal teapot vertex table must contain 290 points")
    values
end

function _teapot_segments(segments::Real)
    sf = Float64(segments)
    isfinite(sf) || throw(ArgumentError("TeapotGeometry segments must be finite"))
    sf <= _GEOMETRY_MAX_SUBDIVISIONS ||
        throw(ArgumentError(
            "TeapotGeometry segments must not exceed " *
            "$_GEOMETRY_MAX_SUBDIVISIONS"))
    return max(2, floor(Int, sf))
end

function _teapot_size(size::Real)
    sf = Float64(size)
    isfinite(sf) && sf >= 0.0 ||
        throw(ArgumentError("TeapotGeometry size must be finite and non-negative"))
    return sf
end

function _teapot_vertex(index0::Int)
    base = 3index0 + 1
    return Vec3(_TEAPOT_VERTICES[base],
                _TEAPOT_VERTICES[base + 1],
                _TEAPOT_VERTICES[base + 2])
end

function _teapot_basis(u::Float64)
    om = 1.0 - u
    return (om^3, 3.0 * u * om^2, 3.0 * u^2 * om, u^3)
end

function _teapot_basis_derivative(u::Float64)
    om = 1.0 - u
    return (-3.0 * om^2,
            3.0 * om^2 - 6.0 * u * om,
            6.0 * u * om - 3.0 * u^2,
            3.0 * u^2)
end

function _teapot_patch_control(surf0::Int; fit_lid::Bool, blinn::Bool)
    blinn_scale = 1.3
    control = Array{Vec3{Float64}}(undef, 4, 4)
    for r in 1:4, c in 1:4
        patch_index = surf0 * 16 + (r - 1) * 4 + c
        p = _teapot_vertex(_TEAPOT_PATCHES[patch_index])
        x = p.x
        y = p.y
        z = p.z
        if fit_lid && 20 <= surf0 < 28
            x *= 1.077
            y *= 1.077
        end
        !blinn && (z *= blinn_scale)
        control[r, c] = Vec3(x, y, z)
    end
    return control
end

function _teapot_eval(control, bs, bt)
    p = Vec3(0.0, 0.0, 0.0)
    for r in 1:4, c in 1:4
        p += control[r, c] * (bs[r] * bt[c])
    end
    return p
end

function _teapot_transformed_point(p::Vec3, true_size::Float64,
                                   max_height2::Float64)
    return Vec3(true_size * p.x,
                true_size * (p.z - max_height2),
                -true_size * p.y)
end

function _teapot_output_normal(p::Vec3, sdir::Vec3, tdir::Vec3,
                               max_height2::Float64)
    if abs(p.x) <= 1e-12 && abs(p.y) <= 1e-12
        return Vec3(0.0, p.z > max_height2 ? 1.0 : -1.0, 0.0)
    end
    n = normalize(cross(tdir, sdir))
    return Vec3(n.x, n.z, -n.y)
end

_teapot_degenerate(a::Vec3, b::Vec3, c::Vec3, eps::Float64) =
    norm(a - b) <= eps || norm(a - c) <= eps || norm(b - c) <= eps

function _teapot_output_vertex(positions::Vector{Float64}, index::Int)
    base = 3index - 2
    return Vec3(positions[base], positions[base + 1], positions[base + 2])
end

"""
    TeapotGeometry(size=50, segments=10; bottom=true, lid=true, body=true,
                   fit_lid=true, blinn=true)

Build a Utah teapot triangle `BufferGeometry` from the same cubic Bezier patch
database used by the three.js `TeapotGeometry` example add-on.
"""
function TeapotGeometry(size::Real=50.0, segments::Real=10;
                        bottom::Bool=true, lid::Bool=true, body::Bool=true,
                        fit_lid::Bool=true, blinn::Bool=true)
    segs = _teapot_segments(segments)
    sizef = _teapot_size(size)
    blinn_scale = 1.3
    max_height = 3.15 * (blinn ? 1.0 : blinn_scale)
    max_height2 = max_height / 2
    true_size = max_height2 == 0.0 ? 0.0 : sizef / max_height2
    min_patch = body ? 0 : 20
    max_patch = bottom ? 32 : 28
    row = segs + 1
    patch_count = 0
    max_planar_control = 0.0
    for surf0 in min_patch:(max_patch - 1)
        if lid || (surf0 < 20 || surf0 >= 28)
            patch_count += 1
            for slot in 1:16
                point = _teapot_vertex(
                    _TEAPOT_PATCHES[surf0 * 16 + slot])
                fit_scale = fit_lid && 20 <= surf0 < 28 ? 1.077 : 1.0
                max_planar_control = max(
                    max_planar_control,
                    abs(point.x * fit_scale), abs(point.y * fit_scale))
            end
        end
    end
    if max_planar_control > 0.0
        planar_scale = max_planar_control / max_height2
        sizef <= floatmax(Float64) / planar_scale ||
            throw(ArgumentError(
                "TeapotGeometry generated positions exceed the Float64 range"))
    end
    vertices_per_patch = _geometry_checked_mul(
        row, row, "TeapotGeometry vertices per patch")
    nvertices = _geometry_checked_mul(
        patch_count, vertices_per_patch, "TeapotGeometry vertex count")
    faces_per_patch = _geometry_checked_mul(
        2 * segs, segs, "TeapotGeometry faces per patch")
    nfaces = _geometry_checked_mul(
        patch_count, faces_per_patch, "TeapotGeometry face count")
    position_len, uv_len, index_len =
        _geometry_mesh_buffer_lengths(nvertices, nfaces, "TeapotGeometry")
    positions = Vector{Float64}(undef, position_len)
    normals = Vector{Float64}(undef, position_len)
    uvs = Vector{Float64}(undef, uv_len)
    indices = Vector{Int}(undef, index_len)
    vi = 0
    iout = 1

    for surf0 in min_patch:(max_patch - 1)
        if lid || (surf0 < 20 || surf0 >= 28)
            control = _teapot_patch_control(surf0; fit_lid=fit_lid, blinn=blinn)
            first_vertex = vi + 1

            for sstep in 0:segs
                s = sstep / segs
                bs = _teapot_basis(s)
                dbs = _teapot_basis_derivative(s)
                for tstep in 0:segs
                    t = tstep / segs
                    bt = _teapot_basis(t)
                    dbt = _teapot_basis_derivative(t)
                    p = _teapot_eval(control, bs, bt)
                    sdir = _teapot_eval(control, dbs, bt)
                    tdir = _teapot_eval(control, bs, dbt)
                    transformed = _teapot_transformed_point(p, true_size, max_height2)
                    n = _teapot_output_normal(p, sdir, tdir, max_height2)
                    vi += 1
                    pbase = 3vi - 2
                    positions[pbase] = transformed.x
                    positions[pbase + 1] = transformed.y
                    positions[pbase + 2] = transformed.z
                    normals[pbase] = n.x
                    normals[pbase + 1] = n.y
                    normals[pbase + 2] = n.z
                    ubase = 2vi - 1
                    uvs[ubase] = 1.0 - t
                    uvs[ubase + 1] = 1.0 - s
                end
            end

            eps_pos = abs(sizef) * 1e-12
            for sstep in 0:(segs - 1), tstep in 0:(segs - 1)
                v1 = first_vertex + sstep * row + tstep
                v2 = v1 + 1
                v3 = v2 + row
                v4 = v1 + row
                p1 = _teapot_output_vertex(positions, v1)
                p2 = _teapot_output_vertex(positions, v2)
                p3 = _teapot_output_vertex(positions, v3)
                p4 = _teapot_output_vertex(positions, v4)
                degenerate123 = _teapot_degenerate(p1, p2, p3, eps_pos)
                degenerate134 = _teapot_degenerate(p1, p3, p4, eps_pos)
                if !iszero(sizef) && (degenerate123 || degenerate134)
                    s0 = sstep / segs
                    s1 = (sstep + 1) / segs
                    t0 = tstep / segs
                    t1 = (tstep + 1) / segs
                    model1 = _teapot_eval(
                        control, _teapot_basis(s0), _teapot_basis(t0))
                    model2 = _teapot_eval(
                        control, _teapot_basis(s0), _teapot_basis(t1))
                    model3 = _teapot_eval(
                        control, _teapot_basis(s1), _teapot_basis(t1))
                    model4 = _teapot_eval(
                        control, _teapot_basis(s1), _teapot_basis(t0))
                    model_eps = max_height2 * 1e-12
                    degenerate123 &&
                        (degenerate123 = _teapot_degenerate(
                            model1, model2, model3, model_eps))
                    degenerate134 &&
                        (degenerate134 = _teapot_degenerate(
                            model1, model3, model4, model_eps))
                end
                if !degenerate123
                    indices[iout] = v1
                    indices[iout + 1] = v2
                    indices[iout + 2] = v3
                    iout += 3
                end
                if !degenerate134
                    indices[iout] = v1
                    indices[iout + 1] = v3
                    indices[iout + 2] = v4
                    iout += 3
                end
            end
        end
    end

    resize!(indices, iout - 1)
    return BufferGeometry(positions, normals, uvs, indices,
                          nvertices, length(indices) ÷ 3)
end
