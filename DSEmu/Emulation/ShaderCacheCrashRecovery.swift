// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
// Host-side helper around Azahar's leftover `{titleId}-loading.flag`.
// A mid-load kill leaves that file, and the next launch black-screens the title
// until the flag is deleted. The 3DS core still uses the disk shader cache.

enum ShaderCacheCrashRecovery {
    /// 16 uppercase hex digits, or nil if the buffer is not a 3DS image / has no ID.
    static func titleId(from3DSImage data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var hex = [CChar](repeating: 0, count: 17)
            guard TPTitleIDFrom3DSImage(base, raw.count, &hex, hex.count) != 0 else { return nil }
            return String(cString: hex)
        }
    }

    static func titleId(from3DSFile url: URL) -> String? {
        var hex = [CChar](repeating: 0, count: 17)
        guard TPTitleIDFrom3DSPath(url.path, &hex, hex.count) != 0 else { return nil }
        return String(cString: hex)
    }

    /// Parses "The 3DS core reported an error. 0004000000054000".
    static func titleId(fromCoreError message: String) -> String? {
        var hex = [CChar](repeating: 0, count: 17)
        guard TPTitleIDFrom3DSCoreError(message, &hex, hex.count) != 0 else { return nil }
        return String(cString: hex)
    }

    static func flagPath(titleId: String, userDir: URL) -> URL? {
        var buf = [CChar](repeating: 0, count: 1024)
        guard TPShaderCacheFlagPath(userDir.path, titleId, &buf, buf.count) != 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf))
    }

    /// Deletes only `{titleId}-loading.flag` under that Azahar user dir.
    /// Returns true if a regular file was removed. Never deletes `.bin` caches.
    @discardableResult
    static func clearStaleFlag(titleId: String, userDir: URL) -> Bool {
        TPClearStaleShaderCacheFlag(userDir.path, titleId) != 0
    }
}
