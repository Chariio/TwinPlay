// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Original clean-room implementation written from public hardware documentation.
#pragma once
#include "dscore/Types.hpp"
#include <atomic>
#include <vector>

namespace dscore {
// Lock-free single-producer / single-consumer stereo ring buffer
// (producer: emulation thread, consumer: realtime audio thread). Neither side ever blocks.
// When full, new samples are dropped (the frontend paces emulation on size()).
class AudioRing {
public:
    explicit AudioRing(size_t frames = 8192) : cap_(frames + 1), buf_((frames + 1) * 2) {}
    size_t push(const s16* stereo, size_t frames) {
        size_t w = write_.load(std::memory_order_relaxed), r = read_.load(std::memory_order_acquire);
        size_t n = 0;
        while (n < frames) {
            size_t next = (w + 1) % cap_;
            if (next == r) break;                               // full
            buf_[w * 2] = stereo[n * 2]; buf_[w * 2 + 1] = stereo[n * 2 + 1];
            w = next; ++n;
        }
        write_.store(w, std::memory_order_release);
        return n;
    }
    size_t pop(s16* out, size_t maxFrames) {
        size_t r = read_.load(std::memory_order_relaxed), w = write_.load(std::memory_order_acquire);
        size_t mark = clearMark_.exchange(kNoMark, std::memory_order_acq_rel);
        if (mark != kNoMark) r = mark;                          // drop what was queued before clear()
        size_t n = 0;
        while (n < maxFrames && r != w) {
            out[n * 2] = buf_[r * 2]; out[n * 2 + 1] = buf_[r * 2 + 1];
            r = (r + 1) % cap_; ++n;
        }
        read_.store(r, std::memory_order_release);
        return n;
    }
    // Frames currently buffered (approximate when called concurrently).
    size_t size() const {
        size_t w = write_.load(std::memory_order_acquire), r = read_.load(std::memory_order_acquire);
        size_t mark = clearMark_.load(std::memory_order_acquire);
        if (mark != kNoMark) r = mark;
        return (w + cap_ - r) % cap_;
    }
    size_t capacity() const { return cap_ - 1; }
    // Called by the producer: the consumer discards everything pushed before this call on its next pop().
    void clear() { clearMark_.store(write_.load(std::memory_order_relaxed), std::memory_order_release); }
private:
    size_t cap_;
    std::vector<s16> buf_;
    std::atomic<size_t> read_{0}, write_{0};
    static constexpr size_t kNoMark = ~size_t(0);
    std::atomic<size_t> clearMark_{kNoMark};
};
} // namespace dscore
