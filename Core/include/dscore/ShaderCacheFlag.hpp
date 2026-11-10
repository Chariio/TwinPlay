// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
#pragma once

#include "dscore/ShaderCacheFlag.h"
#include "dscore/Types.hpp"
#include <optional>
#include <string>
#include <string_view>

namespace dscore {

/// Program ID from an NCSD (.3ds/.cci) or NCCH (.cxi) image. For NCSD, `data`
/// must include the first used partition's NCCH header, or use titleIdFrom3DSPath.
std::optional<u64> titleIdFrom3DSImage(const u8* data, size_t size);
std::optional<u64> titleIdFrom3DSPath(const std::string& path);

/// 16 uppercase hex digits when `message` is an ErrorShaderCacheCrash status.
std::optional<u64> titleIdFromCoreError(std::string_view message);

std::string formatTitleId(u64 title_id);
std::optional<u64> parseTitleId(std::string_view hex);

/// `{userDir}/shaders/vulkan/pipeline/{TITLEID}-loading.flag`.
std::string shaderCacheFlagPath(const std::string& user_dir, u64 title_id);

/// `$HOME/Documents/Azahar` — the path Azahar uses on iOS / the iOS Simulator.
std::string defaultAzaharUserDir();

/// True if `path` looks like an Azahar user directory (`…/Azahar`).
bool isAzaharUserDir(const std::string& path);

/// Deletes only `{titleId}-loading.flag` under that user dir's pipeline folder.
/// Returns true if a regular file was removed.
bool clearStaleShaderCacheFlag(const std::string& user_dir, u64 title_id);

} // namespace dscore
