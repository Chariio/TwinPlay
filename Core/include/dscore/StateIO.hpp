// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Symmetric save-state serializer: the same serialize() code writes and reads.
#pragma once
#include "dscore/Types.hpp"
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <type_traits>
#include <vector>

namespace dscore {

class StateIO {
public:
    StateIO() : writing_(true) {}                                   // writer
    explicit StateIO(const std::vector<u8>& in) : writing_(false), in_(&in) {}  // reader
    bool writing() const { return writing_; }
    bool ok() const { return ok_; }
    void fail() { ok_ = false; }
    std::vector<u8>& output() { return out_; }

    void bytes(void* p, size_t n) {
        if (writing_) { const u8* b = static_cast<const u8*>(p); out_.insert(out_.end(), b, b + n); return; }
        if (!ok_ || pos_ + n > in_->size()) { ok_ = false; std::memset(p, 0, n); return; }
        std::memcpy(p, in_->data() + pos_, n); pos_ += n;
    }
    template <class T> void pod(T& v) {
        static_assert(std::is_trivially_copyable<T>::value, "pod only");
        bytes(&v, sizeof v);
    }
    template <class T> void vec(std::vector<T>& v) {               // fixed-size buffers keep their size
        u32 n = u32(v.size()); pod(n);
        if (!writing_) { if (n != v.size()) { if (n > (64u << 20)) { ok_ = false; return; } v.resize(n); } }
        if (n) bytes(v.data(), n * sizeof(T));
    }
    template <class T> void deque(std::deque<T>& d) {
        u32 n = u32(d.size()); pod(n);
        if (writing_) { for (auto& x : d) { T c = x; pod(c); } return; }
        if (n > 4096) { ok_ = false; return; }
        d.clear(); for (u32 i = 0; i < n; ++i) { T c{}; pod(c); d.push_back(c); }
    }
    void map(std::map<u32, u32>& m) {
        u32 n = u32(m.size()); pod(n);
        if (writing_) { for (auto& kv : m) { u32 k = kv.first, v = kv.second; pod(k); pod(v); } return; }
        if (n > 4096) { ok_ = false; return; }
        m.clear(); for (u32 i = 0; i < n; ++i) { u32 k = 0, v = 0; pod(k); pod(v); m[k] = v; }
    }
    void str(std::string& s) {
        u32 n = u32(s.size()); pod(n);
        if (!writing_) { if (n > 4096) { ok_ = false; return; } s.resize(n); }
        if (n) bytes(&s[0], n);
    }
    // Section tag; mismatches mark the stream invalid.
    void tag(u32 t) { u32 v = t; pod(v); if (v != t) ok_ = false; }

private:
    bool writing_;
    bool ok_ = true;
    std::vector<u8> out_;
    const std::vector<u8>* in_ = nullptr;
    size_t pos_ = 0;
};

} // namespace dscore
