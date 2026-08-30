# --------------------------------------------------------------------------
# Image-space loss functions for inverse rendering.
# All pure Julia, ForwardDiff compatible.
# --------------------------------------------------------------------------

"""
L2 (MSE) loss between two images.
Images are Array{T, 3} of size (H, W, C).
"""
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
    (isfinite(value) && value > zero(value)) ||
        throw(ArgumentError("loss_ssim: $label must be positive and finite"))
    return value
end

function _checked_silhouette_threshold(threshold)
    threshold isa Real && !(threshold isa Bool) ||
        throw(ArgumentError("loss_silhouette_iou: threshold must be finite and in [0, 1]"))
    (isfinite(threshold) && 0 <= threshold <= 1) ||
        throw(ArgumentError("loss_silhouette_iou: threshold must be finite and in [0, 1]"))
    return threshold
end

function loss_mse(image::Array{T, 3}, target::Array{S, 3}) where {T, S}
    H, W, C = _checked_loss_image_size(image, target, "loss_mse")
    average = zero(promote_type(T, S))
    count = 0
    for c in 1:C
        for j in 1:W
            for i in 1:H
                d = image[i, j, c] - target[i, j, c]
                term = d * d
                count += 1
                average = count == 1 ? term :
                    _stable_lerp(average, term, one(term) / count)
            end
        end
    end
    return average
end

"""
L1 loss between two images.
"""
function loss_l1(image::Array{T, 3}, target::Array{S, 3}) where {T, S}
    H, W, C = _checked_loss_image_size(image, target, "loss_l1")
    average = zero(promote_type(T, S))
    count = 0
    for c in 1:C
        for j in 1:W
            for i in 1:H
                term = abs(image[i, j, c] - target[i, j, c])
                count += 1
                average = count == 1 ? term :
                    _stable_lerp(average, term, one(term) / count)
            end
        end
    end
    return average
end

"""
Structural Similarity Index (SSIM) loss.
Returns 1 - SSIM (so that minimizing this maximizes SSIM).
Simplified single-channel average SSIM.
"""
function loss_ssim(image::Array{T, 3}, target::Array{S, 3};
                   window_size=7, C1=0.01^2, C2=0.03^2) where {T, S}
    R = promote_type(T, S)
    H, W, C = _checked_loss_image_size(image, target, "loss_ssim")
    # A 1-pixel window (window_size ≤ 1 ⇒ hw=0 ⇒ n=1) has zero local variance and
    # divides the (n-1) Bessel correction by zero, silently returning NaN.
    window_size = _checked_ssim_window_size(window_size)
    C1 = _checked_ssim_constant(C1, "C1")
    C2 = _checked_ssim_constant(C2, "C2")
    hw = window_size ÷ 2
    if min(H, W) < 2*hw + 1
        throw(ArgumentError("loss_ssim: image of size $(H)x$(W) is smaller than the SSIM window (window_size=$(window_size))"))
    end
    ssim_sum = zero(R)
    count = 0

    for c in 1:C
        for j in (hw+1):(W-hw)
            for i in (hw+1):(H-hw)
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
                            μx = _stable_lerp(
                                μx, x, one(x) / n)
                            μy = _stable_lerp(
                                μy, y, one(y) / n)
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
                ssim_sum += ssim_val
                count += 1
            end
        end
    end

    mean_ssim = ssim_sum / count
    return one(R) - mean_ssim
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
Silhouette IoU loss (Intersection over Union).
Compares binary silhouettes extracted from images.
`threshold` separates foreground from background.
"""
function loss_silhouette_iou(image::Array{T, 3}, target::Array{S, 3};
                              threshold=0.05) where {T, S}
    H, W, _ = _checked_loss_image_size(image, target, "loss_silhouette_iou")
    threshold = _checked_silhouette_threshold(threshold)
    R = float(promote_type(T, S, typeof(threshold)))
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
            img_occ = (sigmoid_approx((img_val - threshold_r) * slope) - occ0) /
                      (one(R) - occ0)
            tgt_occ = (sigmoid_approx((tgt_val - threshold_r) * slope) - occ0) /
                      (one(R) - occ0)

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
