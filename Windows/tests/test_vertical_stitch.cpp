// The test predicates must execute even in an optimized Zig build.
#ifdef NDEBUG
#undef NDEBUG
#endif
// SPDX-License-Identifier: MIT
#include "lightcapture_stitch.hpp"
#include "long_outline.h"
#include "long_finish.h"
#include "capture_input.h"
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
        const LcOutlineRect snap={-180,55,860,695}, empty={0,0,0,0};
        auto clicked=lc_selection_resolve(210,285,212,285,0,snap);
        assert(clicked.left==snap.left && clicked.top==snap.top && clicked.right==snap.right && clicked.bottom==snap.bottom);
        assert(lc_selection_released(LC_CAPTURE_SCREENSHOT,clicked)==LC_CAPTURE_NONE);
        assert(lc_selection_released(LC_CAPTURE_LONG,clicked)==LC_CAPTURE_START_LONG);
        auto drag=lc_selection_resolve(700,600,200,155,0,snap); // Mouse-up may arrive without a move event.
        assert(drag.left==200 && drag.top==155 && drag.right==700 && drag.bottom==600);
        assert(lc_selection_released(LC_CAPTURE_LONG,drag)==LC_CAPTURE_START_LONG);
        auto returned=lc_selection_resolve(200,155,200,155,1,snap); // Drag back to anchor is not a click.
        assert(lc_selection_released(LC_CAPTURE_LONG,returned)==LC_CAPTURE_NONE);
        assert(lc_selection_released(LC_CAPTURE_LONG,empty)==LC_CAPTURE_NONE);
        assert(lc_selection_key(LC_CAPTURE_LONG,LC_CAPTURE_RETURN,0,empty)==LC_CAPTURE_NONE);
        assert(lc_selection_key(LC_CAPTURE_LONG,LC_CAPTURE_RETURN,1,drag)==LC_CAPTURE_NONE);
        assert(lc_selection_key(LC_CAPTURE_LONG,LC_CAPTURE_RETURN,0,drag)==LC_CAPTURE_START_LONG);
        assert(lc_selection_key(LC_CAPTURE_SCREENSHOT,LC_CAPTURE_RETURN,0,snap)==LC_CAPTURE_SAVE_SCREENSHOT);
        assert(lc_selection_key(LC_CAPTURE_LONG,LC_CAPTURE_ESCAPE,0,snap)==LC_CAPTURE_CANCEL_SELECTION);
        assert(lc_long_key(LC_CAPTURE_RETURN,1,1)==LC_CAPTURE_SAVE_LONG);
        assert(lc_long_key(LC_CAPTURE_ESCAPE,1,1)==LC_CAPTURE_CANCEL_LONG);
        assert(lc_long_key(LC_CAPTURE_RETURN,0,1)==LC_CAPTURE_NONE);
        assert(lc_long_key(LC_CAPTURE_ESCAPE,1,0)==LC_CAPTURE_NONE);
        assert(lc_long_key(LC_CAPTURE_OTHER,1,1)==LC_CAPTURE_NONE);
    }
    {
        // A short full-window selection includes several browser chrome rows.
        // Retain one title/tab/address block and one footer, not one per viewport.
        constexpr int top=55, bottom=21;
        VerticalStitch s;
        assert(append(s, frame(0, 0, 0, top, bottom))==StitchResult::Started);
        assert(append(s, frame(22, 0, 0, top, bottom))==StitchResult::Added);
        assert(append(s, frame(52, 0, 0, top, bottom))==StitchResult::Added);
        assert(s.height()==H+52);
        check_document(s,top,bottom);
    }
    {
        // Finish must not produce a Long Screenshots file without verified growth.
        VerticalStitch s;
        assert(!lc_long_can_save(H, s.height()));
        assert(!lc_long_can_save(0, H));
        assert(append(s, frame(0)) == StitchResult::Started);
        assert(append(s, frame(0)) == StitchResult::Unchanged);
        assert(!lc_long_can_save(H, s.height()));
        assert(append(s, frame(310)) == StitchResult::Ambiguous);
        assert(!lc_long_can_save(H, s.height()));
        assert(append(s, frame(1)) == StitchResult::Added);
        assert(lc_long_can_save(H, s.height()));
        assert(append(s, frame(310)) == StitchResult::Ambiguous);
        assert(lc_long_can_save(H, s.height()));
        check_document(s);
    }
    {
        LcOutlineRect edges[4];
        const LcOutlineRect desktop{-1600,-200,1920,1080};
        auto check = [&](LcOutlineRect crop,unsigned count) {
            assert(lc_outline_strips(crop, desktop, edges) == count);
            for(unsigned i=0;i<count;i++) {
                auto e=edges[i];
                assert(e.right>e.left && e.bottom>e.top);
                assert(e.left>=desktop.left && e.top>=desktop.top && e.right<=desktop.right && e.bottom<=desktop.bottom);
                assert(e.right<=crop.left || e.left>=crop.right || e.bottom<=crop.top || e.top>=crop.bottom);
                assert(e.right-e.left<=2 || e.bottom-e.top<=2);
            }
        };
        check({-600,100,700,900},4);     // Signed multi-monitor coordinates.
        check({-1600,150,0,850},3);      // Left edge cannot paint inside.
        check({-1599,-200,1920,800},2);  // One-pixel strip at left and normal bottom.
        check(desktop,0);               // Full virtual screen has no safe outer pixels.
    }
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
        // Touchpad: move down, reverse more than once, return to the previous
        // bottom, then continue. Earlier viewports cannot be duplicated.
        VerticalStitch s;
        assert(append(s, frame(0)) == StitchResult::Started);
        assert(append(s, frame(31)) == StitchResult::Added);
        assert(append(s, frame(58)) == StitchResult::Added);
        assert(append(s, frame(35)) == StitchResult::Ambiguous);
        assert(append(s, frame(12)) == StitchResult::Ambiguous);
        assert(s.height() == H + 58 && s.last_added_rows() == 0);
        assert(append(s, frame(58)) == StitchResult::Unchanged);
        assert(append(s, frame(79)) == StitchResult::Added);
        assert(s.height() == H + 79 && s.last_added_rows() == 21);
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
    std::cout << "Vertical stitching, outline geometry, long-mode routing, and output gating passed\n";
}
