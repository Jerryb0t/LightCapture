// The test predicates must execute even in an optimized Zig build.
#ifdef NDEBUG
#undef NDEBUG
#endif
// SPDX-License-Identifier: MIT
#include "lightcapture_stitch.hpp"
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>

using namespace lightcapture;

constexpr int W = 120;
constexpr int H = 160;
constexpr int STRIDE = W * 4 + 16;
using Bytes = std::vector<std::uint8_t>;

static int pattern(int y, int x, int channel) {
    std::uint32_t code = std::uint32_t(y) * 0x1AB27F31u + std::uint32_t(x) * 30319u + channel * 69427u;
    code ^= code >> 15;
    code *= 0x45D9F3Bu;
    code ^= code >> 16;
    return 16 + int(code % 224);
}

static Bytes frame(int offset, int noise = 0, int repeat = 0, int top = 0, int bottom = 0) {
    Bytes result(STRIDE * H, 0xA5);
    for (int y = 0; y < H; ++y) {
        int doc = offset + y;
        if (repeat) doc %= repeat;
        if (y < top || y >= H - bottom) doc = 7000 + y;
        for (int x = 0; x < W; ++x) {
            for (int ch = 0; ch < 3; ++ch)
                result[y * STRIDE + x * 4 + ch] =
                    std::uint8_t(pattern(doc, x, ch) + ((y + x + ch) % 2 ? noise : -noise));
            result[y * STRIDE + x * 4 + 3] = noise ? 255 : 0;
        }
    }
    return result;
}
static StitchResult append(VerticalStitch& stitch, const Bytes& frame_bytes) {
    return stitch.append({frame_bytes.data(), W, H, STRIDE});
}
static void check_document(const VerticalStitch& stitch, int top = 0, int bottom = 0) {
    for (int y = 0; y < stitch.height(); ++y) {
        const auto* p = stitch.data() + y * stitch.stride();
        int doc = y;
        if (y < top) doc = 7000 + y;
        if (y >= stitch.height() - bottom) doc = 7000 + H - (stitch.height() - y);
        for (int x = 0; x < W; ++x)
            for (int ch = 0; ch < 3; ++ch)
                assert(p[x * 4 + ch] == pattern(doc, x, ch));
    }
}

int main() {
    {
        VerticalStitch s;
        assert(append(s, frame(0)) == StitchResult::Started);
        assert(append(s, frame(0)) == StitchResult::Unchanged);
        assert(append(s, frame(17)) == StitchResult::Added);
        assert(s.last_added_rows() == 17);
        assert(append(s, frame(45)) == StitchResult::Added);
        assert(s.last_added_rows() == 28);
        assert(s.height() == H + 45);
        check_document(s);
        const auto* before = s.data();
        assert(append(s, frame(3)) == StitchResult::Ambiguous); // reverse
        assert(append(s, frame(310)) == StitchResult::Ambiguous); // no overlap
        assert(append(s, frame(45)) == StitchResult::Unchanged); // prior state intact
        assert(s.data() == before && s.height() == H + 45);
        assert(append(s, frame(46)) == StitchResult::Added); // exactly one new row
        check_document(s);
    }
    {
        VerticalStitch s;
        assert(append(s, frame(0, 0, 0, 15, 19)) == StitchResult::Started);
        assert(append(s, frame(29, 0, 0, 15, 19)) == StitchResult::Added);
        assert(append(s, frame(29, 0, 0, 15, 19)) == StitchResult::Unchanged);
        assert(append(s, frame(69, 0, 0, 15, 19)) == StitchResult::Added);
        assert(s.height() == H + 69);
        check_document(s, 15, 19);
    }
    {
        VerticalStitch s;
        assert(append(s, frame(0)) == StitchResult::Started);
        assert(append(s, frame(24, 1)) == StitchResult::Added);
        assert(s.height() == H + 24);
        assert(append(s, frame(59, 1)) == StitchResult::Added);
        assert(s.height() == H + 59);
        auto same_rgb = frame(59, 1);
        for (std::size_t p = 3; p < same_rgb.size(); p += 4) same_rgb[p] ^= 0xFF;
        assert(append(s, same_rgb) == StitchResult::Unchanged);
    }
    {
        VerticalStitch s;
        assert(append(s, frame(0, 0, 9)) == StitchResult::Started);
        assert(append(s, frame(17, 0, 9)) == StitchResult::Ambiguous);
        assert(s.height() == H);
    }
    {
        VerticalStitch s;
        Bytes flat(STRIDE * H, 137);
        assert(append(s, flat) == StitchResult::Started);
        assert(append(s, flat) == StitchResult::Unchanged);
        std::fill(flat.begin(), flat.end(), 138);
        assert(append(s, flat) == StitchResult::Ambiguous);
        assert(s.height() == H);
    }
    {
        constexpr std::size_t budget = std::size_t(W) * (H + 14) * 4;
        VerticalStitch s(budget);
        assert(append(s, frame(0)) == StitchResult::Started);
        assert(s.retained_bytes() <= budget);
        assert(append(s, frame(14)) == StitchResult::Added);
        assert(s.retained_bytes() <= budget);
        assert(append(s, frame(15)) == StitchResult::Limit);
        assert(s.height() == H + 14 && s.last_added_rows() == 0);
        auto bytes = frame(14);
        assert(s.append({bytes.data(), W + 1, H, STRIDE}) == StitchResult::Invalid);
        assert(s.append({bytes.data(), W, H, W * 4 - 1}) == StitchResult::Invalid);
        assert(s.append({s.data(), W, H, s.stride()}) == StitchResult::Invalid);
        assert(s.append({nullptr, W, H, STRIDE}) == StitchResult::Invalid);
        check_document(s);
        s.reset();
        assert(!s.data() && !s.retained_bytes() && !s.height() && !s.width());
        assert(append(s, frame(0)) == StitchResult::Started);
        VerticalStitch tiny(100);
        assert(append(tiny, frame(0)) == StitchResult::Limit);
        assert(!tiny.data() && !tiny.retained_bytes());
    }
    {
        // Document with coincidental white margins at both crop positions.
        // Trimming heuristic must not strip real content or move the seam.
        constexpr int delta = 34;
        auto set_margins = [](Bytes &bytes, int offset) {
            for (int y = 0; y < H; ++y) {
                const int absolute = offset + y;
                if (absolute < 7 || (absolute >= 34 && absolute < 41) ||
                    (absolute >= H - 7 && absolute < H) ||
                    (absolute >= H + 34 - 7 && absolute < H + 34)) {
                    std::fill_n(bytes.data() + y * STRIDE, W * 4, 255);
                }
            }
        };
        auto a = frame(0), b = frame(delta);
        set_margins(a, 0);
        set_margins(b, delta);
        VerticalStitch s;
        assert(append(s, a) == StitchResult::Started);
        assert(append(s, b) == StitchResult::Added);
        assert(s.height() == H + delta);
        for (int y = 0; y < s.height(); ++y) {
            const auto* expected = y < H ? a.data() + y * STRIDE
                                         : b.data() + (y - delta) * STRIDE;
            assert(std::memcmp(s.data() + y * s.stride(), expected, W * 4) == 0);
        }
    }
    {
        // Sparse line art with white page, uneven paragraphs, and an icon.
        auto text_page = [](int offset) {
            Bytes result(STRIDE * H, 255);
            for (int y = 0; y < H; ++y) {
                const int abs = y + offset, line = abs / 13;
                if (abs % 13 > 8 || line % 7 == 4 || line % 11 == 7) continue;
                for (int x = 12; x < 35 + int(std::uint32_t(line) * 17u % 69u); ++x) {
                    if (x % (2 + line % 4) == 0 || (x + line) % 23 < 6) continue;
                    std::fill_n(result.data() + y * STRIDE + x * 4, 3, std::uint8_t(23));
                }
            }
            return result;
        };
        VerticalStitch s;
        assert(append(s, text_page(0)) == StitchResult::Started);
        assert(append(s, text_page(39)) == StitchResult::Added);
        assert(s.last_added_rows() == 39);
        assert(append(s, text_page(71)) == StitchResult::Added);
        assert(s.last_added_rows() == 32);
    }
    std::cout << "8 vertical stitching test groups passed\n";
}
