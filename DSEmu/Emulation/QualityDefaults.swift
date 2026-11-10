// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Foundation

/// Best-looking defaults the device can hold at 60 fps. Registered at launch, so they apply
/// until the user changes a setting. High-end devices (6+ cores, 8+ GB, e.g. iPhone 17 Pro Max)
/// get 3x 3D; others 2x. Sharp bilinear screen filter, Smooth 3D textures and frame blending off
/// (tested best on iPhone 17 Pro Max: 60 fps, clean image). Supersampling is never a default (its frame-time spikes).
enum QualityDefaults {
    /// Bump to re-apply new defaults once to existing installs.
    private static let version = 3   // 3: 2x default on high-end (auto quality steps up/down)

    static var isHighEnd: Bool {
        let p = ProcessInfo.processInfo
        return p.activeProcessorCount >= 6 && p.physicalMemory >= 7_500_000_000
    }
    static var renderScale: Int { 2 }   // start at 2x everywhere; auto quality adapts

    static func register() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "renderScale": renderScale,
            "displayFilter": DisplayFilter.sharpBilinear.rawValue,
            "antiAlias": 1,                 // edge smoothing
            "textureFilter": false,         // Smooth 3D textures: opt-in (slower, can blur atlases)
            "frameBlend": false,
            "autoQuality": true,            // lower 3D resolution if frames take too long
        ])
        if d.integer(forKey: "qualityDefaultsVersion") < version {
            // Older builds stored the 2x / nearest values on every launch; reset video keys once
            // so the new defaults apply. Other settings are untouched.
            for k in ["renderScale", "displayFilter", "antiAlias", "textureFilter", "frameBlend"] { d.removeObject(forKey: k) }
            d.set(version, forKey: "qualityDefaultsVersion")
        }
    }
}
