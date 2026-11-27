# --------------------------------------------------------------------------
# Image-space loss functions for inverse rendering.
# All pure Julia, ForwardDiff compatible.
# --------------------------------------------------------------------------

function _checked_loss_image_size(image::AbstractArray, target::AbstractArray, label::String)
    size(image) == size(target) ||
        throw(ArgumentError("$label: image and target sizes must match; got $(size(image)) and $(size(target))"))
    H, W, C = size(image)
    (H > 0 && W > 0 && C > 0) ||
        throw(ArgumentError("$label: image dimensions must be positive; got $(size(image))"))
    return H, W, C
end

function _checked_ssim_window_size(window_size)
    window_size isa Bool &&
        throw(ArgumentError("loss_ssim: window_size must be an odd integer >= 3 (got $window_size)"))
    window_size isa Integer ||
        throw(ArgumentError("loss_ssim: window_size must be an odd integer >= 3 (got $window_size)"))
    (window_size >= 3 && isodd(window_size)) ||
        throw(ArgumentError("loss_ssim: window_size must be an odd integer >= 3 (got $window_size)"))
    return window_size
end

function _checked_ssim_constant(value, label::String)
    value isa Bool &&
        throw(ArgumentError("loss_ssim: $label must be positive and finite"))
    scalar = _primal_value(value)
    (isfinite(scalar) && scalar > zero(scalar)) ||
        throw(ArgumentError("loss_ssim: $label must be positive and finite"))
    return value
end

function _checked_silhouette_threshold(threshold)
    threshold isa Real && !(threshold isa Bool) ||
        throw(ArgumentError("loss_silhouette_iou: threshold must be finite and in [0, 1]"))
    scalar = _primal_value(threshold)
    (isfinite(scalar) && 0 <= scalar <= 1) ||
        throw(ArgumentError("loss_silhouette_iou: threshold must be finite and in [0, 1]"))
    return threshold
end

@inline _loss_accumulator_type(::Type{T}, ::Type{S}) where {T, S} =
    promote_type(Float32, float(promote_type(T, S)))

@inline _loss_computation_type(::Type{R}) where {R} =
    R <: Union{Float16,Float32} ? Float64 : R

@noinline function _loss_precise_average(
        image::Array{T,3}, target::Array{S,3}, ::Type{R}, squared::Bool
    ) where {T,S,R<:AbstractFloat}
    return setprecision(BigFloat, 512) do
        total = zero(BigFloat)
        @inbounds for index in eachindex(image, target)
            difference = BigFloat(image[index]) - BigFloat(target[index])
            total += squared ? difference * difference : abs(difference)
        end
        return convert(R, total / BigFloat(length(image)))
    end
end

"""
    loss_mse(image, target)

Mean squared error `sum((image - target)^2) / length(image)` between two
`(H, W, C)` image arrays of equal size, accumulated with compensated summation.
The result type is `promote_type(Float32, float(promote_type(T, S)))`;
`Float16` and `Float32` data are accumulated in `Float64`.
"""
function loss_mse(image::Array{T, 3}, target::Array{S, 3}) where {T, S}
    H, W, C = _checked_loss_image_size(image, target, "loss_mse")
    R = _loss_accumulator_type(T, S)
    A = _loss_computation_type(R)
    total = zero(A)
    correction = zero(A)
    for c in 1:C
        for j in 1:W
            for i in 1:H
                d = convert(A, image[i, j, c]) -
                    convert(A, target[i, j, c])
                term = d * d
                if A <: AbstractFloat && !isfinite(term)
                    return _loss_precise_average(
                        image, target, R, true)
                end
                adjusted = term - correction
                next_total = total + adjusted
                if A <: AbstractFloat && !isfinite(next_total)
                    return _loss_precise_average(
                        image, target, R, true)
                end
                correction = (next_total - total) - adjusted
                total = next_total
            end
        end
    end
    return convert(R, total / length(image))
end

"""
    loss_l1(image, target)

Mean absolute error `sum(abs(image - target)) / length(image)` between two
`(H, W, C)` image arrays of equal size, with the accumulation and result type
of [`loss_mse`](@ref).
"""
function loss_l1(image::Array{T, 3}, target::Array{S, 3}) where {T, S}
    H, W, C = _checked_loss_image_size(image, target, "loss_l1")
    R = _loss_accumulator_type(T, S)
    A = _loss_computation_type(R)
    total = zero(A)
    correction = zero(A)
    for c in 1:C
        for j in 1:W
            for i in 1:H
                term = abs(convert(A, image[i, j, c]) -
                           convert(A, target[i, j, c]))
                if A <: AbstractFloat && !isfinite(term)
                    return _loss_precise_average(
                        image, target, R, false)
                end
                adjusted = term - correction
                next_total = total + adjusted
                if A <: AbstractFloat && !isfinite(next_total)
                    return _loss_precise_average(
                        image, target, R, false)
                end
                correction = (next_total - total) - adjusted
                total = next_total
            end
        end
    end
    return convert(R, total / length(image))
end

"""
    loss_ssim(image, target; window_size=7, C1=0.01^2, C2=0.03^2)

Structural-similarity loss `1 - mean(SSIM)`, so minimizing it maximizes SSIM.
SSIM is evaluated per channel on every fully contained `window_size` x
`window_size` uniform window (no padding), using window means, unbiased
(`n - 1`) variances and covariance, and the stabilizing constants `C1`, `C2`;
the mean runs over all windows of all channels. `window_size` must be an odd
integer `>= 3` no larger than either image dimension.

With several Julia threads, at least 1024 windows and an isbits accumulator
(`Float32`, `Float64`, ForwardDiff duals), windows are evaluated in parallel
and summed in the serial order, so the result does not depend on the thread
count; that path allocates one buffer of window values.
"""
function loss_ssim(image::Array{T, 3}, target::Array{S, 3};
                   window_size=7, C1=0.01^2, C2=0.03^2) where {T, S}
    H, W, C = _checked_loss_image_size(image, target, "loss_ssim")
    # A 1-pixel window (window_size ≤ 1 ⇒ hw=0 ⇒ n=1) has zero local variance and
    # divides the (n-1) Bessel correction by zero, silently returning NaN.
    window_size = _checked_ssim_window_size(window_size)
    C1 = _checked_ssim_constant(C1, "C1")
    C2 = _checked_ssim_constant(C2, "C2")
    # A Float16 sum stops resolving unit-sized SSIM contributions after 2048
    # windows.  Include the constants in numeric promotion and accumulate in
    # at least Float32 so the result does not depend on image dimensions.
    R = promote_type(
        Float32, float(promote_type(T, S, typeof(C1), typeof(C2))))
    C1 = convert(R, C1)
    C2 = convert(R, C2)
    hw = window_size ÷ 2
    if min(H, W) < 2*hw + 1
        throw(ArgumentError("loss_ssim: image of size $(H)x$(W) is smaller than the SSIM window (window_size=$(window_size))"))
    end
    windows_i = (hw + 1):(H - hw)
    windows_j = (hw + 1):(W - hw)
    if _ssim_parallel(R, length(windows_i) * length(windows_j) * C)
        ssim_sum, count = _ssim_parallel_sum(image, target, windows_i,
                                             windows_j, C, hw, C1, C2)
    else
        ssim_sum = zero(R)
        count = 0
        for c in 1:C, j in windows_j, i in windows_i
            ssim_sum += _ssim_window(image, target, i, j, c, hw, C1, C2)
            count += 1
        end
    end

    mean_ssim = ssim_sum / count
    return one(R) - mean_ssim
end

# Window evaluation is threaded only for isbits accumulators (no shared heap
# state or reverse tape) when Julia has several threads and enough windows.
_ssim_parallel(::Type{R}, windows::Int) where {R} =
    Threads.nthreads() > 1 && isbitstype(R) && windows >= 1024

# Windows are independent: evaluate them in parallel tasks, then sum in the
# serial (channel, column, row) order, so the result is bit-identical for any
# thread count. A separate function keeps the task closure from capturing (and
# boxing) the caller's reassigned locals.
function _ssim_parallel_sum(image, target, windows_i, windows_j, C::Int,
                            hw::Int, C1::R, C2::R) where {R}
    values = Array{R}(undef, length(windows_i), length(windows_j), C)
    columns = length(windows_j)
    Threads.@threads for column in 1:(C * columns)
        c = (column - 1) ÷ columns + 1
        jj = (column - 1) % columns + 1
        j = windows_j[jj]
        for (ii, i) in enumerate(windows_i)
            values[ii, jj, c] = _ssim_window(image, target, i, j, c, hw, C1, C2)
        end
    end
    ssim_sum = zero(R)
    for value in values
        ssim_sum += value
    end
    return ssim_sum, length(values)
end

# SSIM of the window centred at (i, j) in channel c, in accumulator type R.
function _ssim_window(image, target, i::Int, j::Int, c::Int, hw::Int,
                      C1::R, C2::R) where {R}
    # Local means
    μx = zero(R)
    μy = zero(R)
    raw_scale = sqrt(C2)
    n = 0
    for dj in -hw:hw
        for di in -hw:hw
            n += 1
            x = convert(R, image[i+di, j+dj, c])
            y = convert(R, target[i+di, j+dj, c])
            raw_scale =
                max(raw_scale, abs(x), abs(y))
            if n == 1
                μx = x
                μy = y
            else
                μx = _stable_lerp(μx, x, one(x) / n)
                μy = _stable_lerp(μy, y, one(y) / n)
            end
        end
    end

    # Local variances and covariance. Keep the accumulators scaled
    # to the largest deviation seen so squared HDR values cannot
    # overflow before the bounded SSIM ratio is formed.
    σx2 = zero(R)
    σy2 = zero(R)
    σxy = zero(R)
    deviation_scale = sqrt(C2)
    for dj in -hw:hw
        for di in -hw:hw
            x = convert(R, image[i+di, j+dj, c])
            y = convert(R, target[i+di, j+dj, c])
            dx = x - μx
            dy = y - μy
            finite_dx = isfinite(dx)
            finite_dy = isfinite(dy)
            next_scale =
                finite_dx && finite_dy ?
                max(deviation_scale, abs(dx), abs(dy)) :
                max(deviation_scale, raw_scale)
            if next_scale > deviation_scale
                ratio = deviation_scale / next_scale
                ratio2 = ratio * ratio
                σx2 *= ratio2
                σy2 *= ratio2
                σxy *= ratio2
                deviation_scale = next_scale
            end
            scaled_dx = finite_dx ?
                dx / deviation_scale :
                x / deviation_scale -
                μx / deviation_scale
            scaled_dy = finite_dy ?
                dy / deviation_scale :
                y / deviation_scale -
                μy / deviation_scale
            σx2 += scaled_dx * scaled_dx
            σy2 += scaled_dy * scaled_dy
            σxy += scaled_dx * scaled_dy
        end
    end
    σx2 /= (n - 1)
    σy2 /= (n - 1)
    σxy /= (n - 1)

    mean_scale = max(abs(μx), abs(μy), sqrt(C1))
    scaled_μx = μx / mean_scale
    scaled_μy = μy / mean_scale
    scaled_C1 = (C1 / mean_scale) / mean_scale
    luminance = (
        2 * scaled_μx * scaled_μy + scaled_C1
    ) / (
        scaled_μx * scaled_μx +
        scaled_μy * scaled_μy + scaled_C1
    )

    scaled_C2 =
        (C2 / deviation_scale) / deviation_scale
    structure = (2 * σxy + scaled_C2) /
                (σx2 + σy2 + scaled_C2)
    ssim_val = luminance * structure
    return ssim_val
end

# Per-pixel brightness as the max over the channels that exist, so a grayscale
# (H×W×1) or 2-channel silhouette/mask is handled instead of indexing past the
# end of the array with a BoundsError (the sibling losses accept any channel
# count too).
@inline function _silhouette_brightness(img, i, j)
    value = img[i, j, 1]
    @inbounds for channel in 2:size(img, 3)
        value = max(value, img[i, j, channel])
    end
    return value
end

"""
    loss_silhouette_iou(image, target; threshold=0.05)

Soft silhouette intersection-over-union loss `1 - IoU`. Each pixel's
occupancy is a steep sigmoid (slope 200) of its brightest channel minus
`threshold`, rescaled so a black pixel has occupancy 0; the intersection and
union sum the per-pixel minimum and maximum occupancies. A `1e-8` smoothing term
makes two empty silhouettes give loss 0. `threshold` must lie in `[0, 1]`.
"""
function loss_silhouette_iou(image::Array{T, 3}, target::Array{S, 3};
                              threshold=0.05) where {T, S}
    H, W, _ = _checked_loss_image_size(image, target, "loss_silhouette_iou")
    threshold = _checked_silhouette_threshold(threshold)
    # Accumulating a large mask in Float16 stops changing once the running
    # count reaches 2048, which can turn a valid IoU into an image-size-
    # dependent result.  Keep the public numeric promotion behavior, but use
    # at least Float32 for the occupancy sums.
    R = promote_type(Float32,
                     float(promote_type(T, S, typeof(threshold))))
    threshold_r = convert(R, threshold)
    slope = convert(R, 200)

    # Convert to grayscale silhouettes via soft thresholding
    intersection = zero(R)
    union_val = zero(R)

    # Residual occupancy of a true-black pixel; subtracted below so exact
    # background reads occupancy 0 and empty silhouettes give union ~ 0.
    occ0 = sigmoid_approx(-threshold_r * slope)

    for j in 1:W
        for i in 1:H
            # Brightness as max over the available channels (handles grayscale).
            img_val = convert(R, _silhouette_brightness(image, i, j))
            tgt_val = convert(R, _silhouette_brightness(target, i, j))

            # Soft occupancy. The slope must be steep enough that a true-black
            # background (brightness 0) reads ~0 occupancy: at slope 200 and
            # threshold 0.05, background -> sigmoid(-10) ~ 5e-5, while any lit
            # object pixel (>~0.08) -> ~1, so disjoint silhouettes give IoU ~ 0.
            img_occ = clamp(
                (sigmoid_approx((img_val - threshold_r) * slope) - occ0) /
                (one(R) - occ0), zero(R), one(R))
            tgt_occ = clamp(
                (sigmoid_approx((tgt_val - threshold_r) * slope) - occ0) /
                (one(R) - occ0), zero(R), one(R))

            intersection += min(img_occ, tgt_occ)
            union_val += max(img_occ, tgt_occ)
        end
    end

    # Smoothed IoU: two empty silhouettes give ε/ε = 1, i.e. loss 0. The
    # decimal guard rounds to zero in Float16, so fall back to that type's
    # smallest positive value when conversion underflows.
    smoothing = convert(R, 1e-8)
    smoothing > zero(R) || (smoothing = nextfloat(zero(R)))
    iou = (intersection + smoothing) / (union_val + smoothing)
    return one(R) - iou
end
