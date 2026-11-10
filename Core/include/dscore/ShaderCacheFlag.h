// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// C API for the stale Azahar Vulkan `{titleId}-loading.flag` guard.
// A mid-load kill leaves that flag, and the next launch black-screens the title
// with ErrorShaderCacheCrash. These helpers delete only that one file.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Writes 16 uppercase hex digits and a NUL to out_hex when the buffer looks
/// like an NCSD (.3ds/.cci) or NCCH (.cxi) and a program ID can be read.
/// Returns 1 on success. out_len must be at least 17.
int TPTitleIDFrom3DSImage(const uint8_t* data, size_t size, char* out_hex, size_t out_len);

/// Same, reading the file (seeks to the first NCSD partition if needed).
int TPTitleIDFrom3DSPath(const char* path, char* out_hex, size_t out_len);

/// True when `message` is the TwinPlay ErrorShaderCacheCrash text:
/// "The 3DS core reported an error." followed by a 16-digit title ID.
int TPTitleIDFrom3DSCoreError(const char* message, char* out_hex, size_t out_len);

/// `{userDir}/shaders/vulkan/pipeline/{TITLEID}-loading.flag`.
int TPShaderCacheFlagPath(const char* user_dir, const char* title_hex, char* out, size_t out_len);

/// The Azahar user dir the iOS core uses: `$HOME/Documents/Azahar`.
int TPDefaultAzaharUserDir(char* out, size_t out_len);

/// Deletes only that regular flag file. Never removes a directory, a `.bin`
/// cache, or any other name. Returns 1 if a file was removed.
int TPClearStaleShaderCacheFlag(const char* user_dir, const char* title_hex);

#ifdef __cplusplus
}
#endif
