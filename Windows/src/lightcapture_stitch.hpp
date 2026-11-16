// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>

namespace lightcapture {

// Top-down BGRA. Caller owns at least stride * height readable bytes.
// Alpha is intentionally not compared (Win32 capture may leave it undefined).
struct BgraView {
    const std::uint8_t* pixels;
    int width;
    int height;
    std::ptrdiff_t stride;
};
enum class StitchResult { Started, Added, Unchanged, Ambiguous, Invalid, Limit };

// Expects the same viewport/scaling each time. On an uncertain result, leaves
// both the composite and prior accepted alignment untouched so users can retry.
class VerticalStitch {
public:
    static constexpr std::size_t default_budget = 24'000'000 * std::size_t{4};
    static constexpr int max_dimension = 32'768;
    explicit VerticalStitch(std::size_t budget_bytes = default_budget) noexcept
        : budget_(std::min(budget_bytes, default_budget)) {}
    ~VerticalStitch() { std::free(pixels_); }
    VerticalStitch(const VerticalStitch&) = delete;
    VerticalStitch& operator=(const VerticalStitch&) = delete;

    const std::uint8_t* data() const noexcept { return pixels_; }
    int width() const noexcept { return width_; }
    int height() const noexcept { return height_; }
    std::ptrdiff_t stride() const noexcept { return std::ptrdiff_t(width_) * 4; }
    int last_added_rows() const noexcept { return last_added_; }
    std::size_t retained_bytes() const noexcept { return capacity_; }
    void reset() noexcept {
        std::free(pixels_);
        pixels_ = nullptr;
        capacity_ = 0;
        signature_ = 0;
        width_ = height_ = viewport_ = top_ = bottom_ = last_added_ = 0;
    }

    StitchResult append(BgraView view) noexcept {
        last_added_ = 0;
        if (!view.pixels || view.width < 16 || view.height < 32 ||
            view.width > max_dimension || view.height > max_dimension ||
            view.stride < std::ptrdiff_t(view.width) * 4 ||
            view.stride > std::numeric_limits<std::ptrdiff_t>::max() / view.height)
            return StitchResult::Invalid;
        // A borrowed view may not point back into our reallocatable buffer.
        if (pixels_) {
            const auto start = reinterpret_cast<std::uintptr_t>(pixels_);
            const auto input = reinterpret_cast<std::uintptr_t>(view.pixels);
            if (input >= start && input - start < capacity_) return StitchResult::Invalid;
        }
        const auto row_bytes = std::size_t(view.width) * 4;
        if (!pixels_) {
            if (std::size_t(view.height) > budget_ / row_bytes ||
                !ensure(row_bytes * std::size_t(view.height))) return StitchResult::Limit;
            for (int y = 0; y < view.height; ++y)
                std::memcpy(pixels_ + row_bytes * y, row(view, y), row_bytes);
            width_ = view.width; height_ = viewport_ = view.height;
            signature_ = signature(view);
            return StitchResult::Started;
        }
        if (view.width != width_ || view.height != viewport_) return StitchResult::Invalid;
        const std::uint64_t current_signature = signature(view);
        if (current_signature == signature_) return StitchResult::Unchanged;
        const BgraView previous{pixels_, width_, height_, stride()};
        const int start = height_ - viewport_;
        if (difference(previous, start + top_, view, top_,
                       viewport_ - top_ - bottom_, 160, 96) <= 0.12)
            return StitchResult::Unchanged;

        int top = top_, bottom = bottom_;
        if (height_ == viewport_) {
            // Only consider a contiguous, unchanged anchored band near an edge.
            // Matching still has to prove that the moving region is continuous.
            const int max_band = viewport_ / 4;
            while (top < max_band &&
                   difference(previous, top, view, top, 1, 1, 72) <= 0.30) ++top;
            while (bottom < max_band) {
                const int y = viewport_ - 1 - bottom;
                if (difference(previous, y, view, y, 1, 1, 72) > 0.30) break;
                ++bottom;
            }
        } else {
            if ((top && difference(previous, 0, view, 0, top, 48, 72) > 3) ||
                (bottom && difference(previous, height_ - bottom, view,
                            viewport_ - bottom, bottom, 48, 72) > 3))
                return StitchResult::Ambiguous;
        }

        // A long flat coincident margin is common; do not trim it when
        // the full viewport establishes a reliable alignment without trimming.
        int best = 0;
        if (height_ == viewport_ && (top || bottom)) {
            best = find_offset(previous, view, 0, 0);
            if (best) top = bottom = 0;
        }
        if (!best) best = find_offset(previous, view, top, bottom);
        if (!best) return StitchResult::Ambiguous;

        const int new_height = height_ + best;
        if (new_height > max_dimension || std::size_t(new_height) > budget_ / row_bytes ||
            !ensure(row_bytes * std::size_t(new_height))) return StitchResult::Limit;
        // Replace the old footer with the new tail (new rows followed by one footer).
        for (int y = 0; y < best + bottom; ++y)
            std::memcpy(pixels_ + row_bytes * (height_ - bottom + y),
                        row(view, viewport_ - bottom - best + y), row_bytes);
        height_ = new_height;
        top_ = top; bottom_ = bottom; last_added_ = best;
        signature_ = current_signature;
        return StitchResult::Added;
    }

private:
    int find_offset(BgraView previous, BgraView view, int top, int bottom) const noexcept {
        const int moving = viewport_ - top - bottom;
        const int minimum = std::max(24, moving / 8);
        if (moving <= minimum) return 0;
        const int prev = height_ - viewport_ + top;
        // Both directions are scored to avoid falsely appending a reverse scroll.
        // Use the same sampled positions for all candidates with equal overlap.
        int best = 0;
        double best_error = 256;
        for (int d = 1; d <= moving - minimum; ++d) {
            const double e = difference(previous, prev + d, view, top, moving - d, 32, 24, 4.0);
            if (e < best_error) { best_error = e; best = d; }
        }
        if (!best || best_error > 3.0) return 0;
        for (int d = 1; d <= moving - minimum; ++d) {
            if (std::abs(d - best) > 2 &&
                difference(previous, prev + d, view, top, moving - d, 32, 24, best_error + 0.85) <= best_error + 0.85)
                return 0;
            if (difference(previous, prev, view, top + d, moving - d, 32, 24, best_error + 0.85) <= best_error + 0.85)
                return 0;
        }
        const int overlap = moving - best;
        if (difference(previous, prev + best, view, top, overlap, 160, 96) > 4.0 ||
            vertical_texture(view, top, overlap) < 2.4)
            return 0;
        // A narrow low-error winner next to d=0 can otherwise turn small dynamic
        // changes in a smooth page into repeated tiny appends.
        if (difference(previous, prev, view, top, moving, 32, 24) <= best_error + 0.35)
            return 0;

        return best;
    }

    static const std::uint8_t* row(BgraView view, int y) noexcept {
        return view.pixels + std::ptrdiff_t(y) * view.stride;
    }
    static int sample(int i, int n, int span) noexcept {
        return n > 1 ? int(std::int64_t(i) * (span - 1) / (n - 1)) : span / 2;
    }
    static std::uint64_t signature(BgraView view) noexcept {
        const int ny = std::min(149, view.height), nx = std::min(103, view.width);
        std::uint64_t hash = 14695981039346656037ull;
        for (int iy = 0; iy < ny; ++iy) {
            const int y = sample(iy, ny, view.height);
            const auto* p = row(view, y);
            for (int ix = 0; ix < nx; ++ix) {
                const int x = sample(ix, nx, view.width) * 4;
                for (int ch = 0; ch < 3; ++ch) {
                    hash ^= p[x + ch];
                    hash *= 1099511628211ull;
                }
            }
        }
        return hash;
    }
    static double difference(BgraView a, int ay, BgraView b, int by,
                             int rows, int sample_rows, int sample_cols,
                             double cutoff = 255) noexcept {
        const int ny = std::min(rows, sample_rows), nx = std::min(a.width, sample_cols);
        const int samples = ny * nx * 3;
        const auto budget = std::uint32_t(std::ceil(cutoff * samples));
        std::uint32_t sum = 0;
        for (int iy = 0; iy < ny; ++iy) {
            const int y = sample(iy, ny, rows);
            const auto* pa = row(a, ay + y);
            const auto* pb = row(b, by + y);
            for (int ix = 0; ix < nx; ++ix) {
                const int x = sample(ix, nx, a.width) * 4;
                for (int ch = 0; ch < 3; ++ch)
                    sum += unsigned(std::abs(int(pa[x + ch]) - int(pb[x + ch])));
            }
            if (sum > budget) return 256;
        }
        return double(sum) / samples;
    }
    static double vertical_texture(BgraView v, int start, int rows) noexcept {
        // Vertical change, not horizontal variance: repeating columns or a
        // sidebar may be textured without containing any positional evidence.
        const int ny = std::min(rows - 1, 120), nx = std::min(v.width, 80);
        std::uint32_t sum = 0;
        for (int iy = 0; iy < ny; ++iy) {
            const int y = sample(iy, ny, rows - 1);
            const auto* a = row(v, start + y);
            const auto* b = row(v, start + y + 1);
            for (int ix = 0; ix < nx; ++ix) {
                const int x = sample(ix, nx, v.width) * 4;
                for (int ch = 0; ch < 3; ++ch)
                    sum += unsigned(std::abs(int(a[x + ch]) - int(b[x + ch])));
            }
        }
        return double(sum) / (ny * nx * 3);
    }

    bool ensure(std::size_t bytes) noexcept {
        if (bytes <= capacity_) return true;
        if (bytes > budget_) return false;
        const auto cap = std::max(bytes, std::min(budget_, capacity_ + capacity_ / 2));
        auto* next = static_cast<std::uint8_t*>(std::realloc(pixels_, cap));
        if (!next) return false;
        pixels_ = next;
        capacity_ = cap;
        return true;
    }

    std::uint8_t* pixels_{};
    std::size_t capacity_{};
    std::size_t budget_;
    std::uint64_t signature_{};
    int width_{}, height_{}, viewport_{}, top_{}, bottom_{}, last_added_{};
};

} // namespace lightcapture
