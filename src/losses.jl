# --------------------------------------------------------------------------
# Image-space loss functions for inverse rendering.
# All pure Julia, ForwardDiff compatible.
# --------------------------------------------------------------------------

"""
L2 (MSE) loss between two images.
Images are Array{T, 3} of size (H, W, C).
"""
function loss_mse(image::Array{T, 3}, target::Array{S, 3}) where {T, S}
    @assert size(image) == size(target)
    H, W, C = size(image)
    total = zero(promote_type(T, S))
    n = H * W * C
    for c in 1:C
        for j in 1:W
            for i in 1:H
                d = image[i, j, c] - target[i, j, c]
                total += d * d
            end
        end
    end
    return total / n
end

"""
L1 loss between two images.
"""
function loss_l1(image::Array{T, 3}, target::Array{S, 3}) where {T, S}
    @assert size(image) == size(target)
    H, W, C = size(image)
    total = zero(promote_type(T, S))
    n = H * W * C
    for c in 1:C
        for j in 1:W
            for i in 1:H
                total += abs(image[i, j, c] - target[i, j, c])
            end
        end
    end
    return total / n
end

"""
Structural Similarity Index (SSIM) loss.
Returns 1 - SSIM (so that minimizing this maximizes SSIM).
Simplified single-channel average SSIM.
"""
function loss_ssim(image::Array{T, 3}, target::Array{S, 3};
                   window_size=7, C1=0.01^2, C2=0.03^2) where {T, S}
    @assert size(image) == size(target)   # parity with loss_mse/loss_l1 (else silently wrong)
    R = promote_type(T, S)
    H, W, C = size(image)
    # A 1-pixel window (window_size ≤ 1 ⇒ hw=0 ⇒ n=1) has zero local variance and
    # divides the (n-1) Bessel correction by zero, silently returning NaN.
    window_size >= 2 ||
        throw(ArgumentError("loss_ssim: window_size must be >= 2 (got $window_size)"))
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
                n = 0
                for dj in -hw:hw
                    for di in -hw:hw
                        μx += image[i+di, j+dj, c]
                        μy += target[i+di, j+dj, c]
                        n += 1
                    end
                end
                μx /= n
                μy /= n

                # Local variances and covariance
                σx2 = zero(R)
                σy2 = zero(R)
                σxy = zero(R)
                for dj in -hw:hw
                    for di in -hw:hw
                        dx = image[i+di, j+dj, c] - μx
                        dy = target[i+di, j+dj, c] - μy
                        σx2 += dx * dx
                        σy2 += dy * dy
                        σxy += dx * dy
                    end
                end
                σx2 /= (n - 1)
                σy2 /= (n - 1)
                σxy /= (n - 1)

                ssim_val = (2*μx*μy + C1) * (2*σxy + C2) /
                           ((μx^2 + μy^2 + C1) * (σx2 + σy2 + C2))
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
    C = size(img, 3)
    C == 1 && return img[i, j, 1]
    C == 2 && return max(img[i, j, 1], img[i, j, 2])
    return max(img[i, j, 1], img[i, j, 2], img[i, j, 3])
end

"""
Silhouette IoU loss (Intersection over Union).
Compares binary silhouettes extracted from images.
`threshold` separates foreground from background.
"""
function loss_silhouette_iou(image::Array{T, 3}, target::Array{S, 3};
                              threshold=0.05) where {T, S}
    @assert size(image) == size(target)   # parity with loss_mse/loss_l1 (else silently wrong)
    R = promote_type(T, S)
    H, W, _ = size(image)

    # Convert to grayscale silhouettes via soft thresholding
    intersection = zero(R)
    union_val = zero(R)

    # Residual occupancy of a true-black pixel; subtracted below so exact
    # background reads occupancy 0 and empty silhouettes give union ~ 0.
    occ0 = sigmoid_approx(-R(threshold) * 200)

    for j in 1:W
        for i in 1:H
            # Brightness as max over the available channels (handles grayscale).
            img_val = _silhouette_brightness(image, i, j)
            tgt_val = _silhouette_brightness(target, i, j)

            # Soft occupancy. The slope must be steep enough that a true-black
            # background (brightness 0) reads ~0 occupancy: at slope 200 and
            # threshold 0.05, background -> sigmoid(-10) ~ 5e-5, while any lit
            # object pixel (>~0.08) -> ~1, so disjoint silhouettes give IoU ~ 0.
            img_occ = (sigmoid_approx((img_val - threshold) * 200) - occ0) / (1 - occ0)
            tgt_occ = (sigmoid_approx((tgt_val - threshold) * 200) - occ0) / (1 - occ0)

            intersection += img_occ * tgt_occ
            union_val += img_occ + tgt_occ - img_occ * tgt_occ
        end
    end

    # Smoothed IoU: two empty silhouettes give eps/eps = 1, i.e. loss 0.
    eps = R(1e-8)
    iou = (intersection + eps) / (union_val + eps)
    return one(R) - iou
end
