// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Clears a leftover Azahar `{titleId}-loading.flag` without touching the disk
// shader cache or any other file in the pipeline directory.
#include "dscore/ShaderCacheFlag.hpp"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace dscore {
namespace {

constexpr size_t kHeader = 0x200;
constexpr size_t kMagicOff = 0x100;
constexpr size_t kProgramIdOff = 0x118;
constexpr size_t kPartitionTable = 0x120;
constexpr size_t kMediaUnit = 0x200;

u32 readU32LE(const u8* p) {
    return u32(p[0]) | (u32(p[1]) << 8) | (u32(p[2]) << 16) | (u32(p[3]) << 24);
}

u64 readU64LE(const u8* p) {
    return u64(readU32LE(p)) | (u64(readU32LE(p + 4)) << 32);
}

std::string trimCopy(std::string_view s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return std::string(s.substr(a, b - a));
}

std::string stripTrailingSlashes(std::string s) {
    while (s.size() > 1 && s.back() == '/') s.pop_back();
    return s;
}

bool isNCCH(const u8* d, size_t n) {
    return d && n >= kProgramIdOff + 8 && std::memcmp(d + kMagicOff, "NCCH", 4) == 0;
}

bool isNCSD(const u8* d, size_t n) {
    return d && n >= kHeader && std::memcmp(d + kMagicOff, "NCSD", 4) == 0;
}

std::optional<u64> titleIdFromNCCH(const u8* d, size_t n) {
    if (!isNCCH(d, n)) return std::nullopt;
    const u64 id = readU64LE(d + kProgramIdOff);
    if (id == 0) return std::nullopt;
    return id;
}

// First non-empty NCSD partition offset and length, in bytes.
bool ncsdMainPartition(const u8* d, size_t n, u64& offset, u64& length) {
    if (!isNCSD(d, n)) return false;
    for (int i = 0; i < 8; ++i) {
        const u8* ent = d + kPartitionTable + size_t(i) * 8;
        const u64 off = u64(readU32LE(ent)) * kMediaUnit;
        const u64 len = u64(readU32LE(ent + 4)) * kMediaUnit;
        if (len == 0) continue;
        offset = off;
        length = len;
        return true;
    }
    return false;
}

} // namespace

std::string formatTitleId(u64 title_id) {
    char buf[17];
    std::snprintf(buf, sizeof buf, "%016llX", static_cast<unsigned long long>(title_id));
    return buf;
}

std::optional<u64> parseTitleId(std::string_view hex) {
    const std::string s = trimCopy(hex);
    if (s.size() != 16) return std::nullopt;
    u64 v = 0;
    for (char c : s) {
        unsigned d;
        if (c >= '0' && c <= '9') d = unsigned(c - '0');
        else if (c >= 'a' && c <= 'f') d = unsigned(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = unsigned(c - 'A' + 10);
        else return std::nullopt;
        v = (v << 4) | d;
    }
    if (v == 0) return std::nullopt;
    return v;
}

std::optional<u64> titleIdFrom3DSImage(const u8* data, size_t size) {
    if (auto id = titleIdFromNCCH(data, size)) return id;
    u64 off = 0, len = 0;
    if (!ncsdMainPartition(data, size, off, len)) return std::nullopt;
    if (off > size || size - off < kProgramIdOff + 8) return std::nullopt;
    return titleIdFromNCCH(data + off, size - off);
}

std::optional<u64> titleIdFrom3DSPath(const std::string& path) {
    if (path.empty()) return std::nullopt;
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::nullopt;
    std::vector<u8> head(kHeader);
    in.read(reinterpret_cast<char*>(head.data()), std::streamsize(head.size()));
    head.resize(size_t(std::max<std::streamsize>(0, in.gcount())));
    if (auto id = titleIdFromNCCH(head.data(), head.size())) return id;
    u64 off = 0, len = 0;
    if (!ncsdMainPartition(head.data(), head.size(), off, len)) return std::nullopt;
    in.clear();
    if (!in.seekg(std::streamoff(off), std::ios::beg)) return std::nullopt;
    std::vector<u8> ncch(kHeader);
    in.read(reinterpret_cast<char*>(ncch.data()), std::streamsize(ncch.size()));
    ncch.resize(size_t(std::max<std::streamsize>(0, in.gcount())));
    return titleIdFromNCCH(ncch.data(), ncch.size());
}

std::optional<u64> titleIdFromCoreError(std::string_view message) {
    const std::string s = trimCopy(message);
    static constexpr std::string_view kPrefix = "The 3DS core reported an error.";
    if (s.size() < kPrefix.size() || s.compare(0, kPrefix.size(), kPrefix.data(), kPrefix.size()) != 0)
        return std::nullopt;
    return parseTitleId(s.substr(kPrefix.size()));
}

std::string shaderCacheFlagPath(const std::string& user_dir, u64 title_id) {
    return stripTrailingSlashes(user_dir) + "/shaders/vulkan/pipeline/" + formatTitleId(title_id) +
           "-loading.flag";
}

std::string defaultAzaharUserDir() {
    const char* home = std::getenv("HOME");
    if (!home || !home[0]) return {};
    return std::string(home) + "/Documents/Azahar";
}

bool isAzaharUserDir(const std::string& path) {
    const std::string d = stripTrailingSlashes(path);
    return d.size() >= 6 && (d == "Azahar" || d.ends_with("/Azahar"));
}

bool clearStaleShaderCacheFlag(const std::string& user_dir, u64 title_id) {
    if (user_dir.empty() || title_id == 0) return false;
    const std::string path = shaderCacheFlagPath(user_dir, title_id);
    const std::string needle = "/shaders/vulkan/pipeline/" + formatTitleId(title_id) + "-loading.flag";
    if (path.size() < needle.size() || path.compare(path.size() - needle.size(), needle.size(), needle) != 0)
        return false;
    struct stat st {};
    if (lstat(path.c_str(), &st) != 0) return false;
    if (!S_ISREG(st.st_mode)) return false;
    if (unlink(path.c_str()) != 0) return false;
    std::fprintf(stderr, "TwinPlay: cleared a stale 3DS shader-cache flag (%s).\n",
                 formatTitleId(title_id).c_str());
    return true;
}

} // namespace dscore

using dscore::u8;

static int writeHex(char* out, size_t out_len, std::optional<dscore::u64> id) {
    if (!id || !out || out_len < 17) return 0;
    const std::string hex = dscore::formatTitleId(*id);
    std::snprintf(out, out_len, "%s", hex.c_str());
    return 1;
}

int TPTitleIDFrom3DSImage(const uint8_t* data, size_t size, char* out_hex, size_t out_len) {
    return writeHex(out_hex, out_len, dscore::titleIdFrom3DSImage(reinterpret_cast<const u8*>(data), size));
}

int TPTitleIDFrom3DSPath(const char* path, char* out_hex, size_t out_len) {
    if (!path) return 0;
    return writeHex(out_hex, out_len, dscore::titleIdFrom3DSPath(path));
}

int TPTitleIDFrom3DSCoreError(const char* message, char* out_hex, size_t out_len) {
    if (!message) return 0;
    return writeHex(out_hex, out_len, dscore::titleIdFromCoreError(message));
}

int TPShaderCacheFlagPath(const char* user_dir, const char* title_hex, char* out, size_t out_len) {
    if (!user_dir || !title_hex || !out || out_len < 2) return 0;
    const auto id = dscore::parseTitleId(title_hex);
    if (!id) return 0;
    const std::string path = dscore::shaderCacheFlagPath(user_dir, *id);
    if (path.size() + 1 > out_len) return 0;
    std::snprintf(out, out_len, "%s", path.c_str());
    return 1;
}

int TPDefaultAzaharUserDir(char* out, size_t out_len) {
    if (!out || out_len < 2) return 0;
    const std::string dir = dscore::defaultAzaharUserDir();
    if (dir.empty() || dir.size() + 1 > out_len) return 0;
    std::snprintf(out, out_len, "%s", dir.c_str());
    return 1;
}

int TPClearStaleShaderCacheFlag(const char* user_dir, const char* title_hex) {
    if (!user_dir || !title_hex) return 0;
    const auto id = dscore::parseTitleId(title_hex);
    if (!id) return 0;
    return dscore::clearStaleShaderCacheFlag(user_dir, *id) ? 1 : 0;
}
