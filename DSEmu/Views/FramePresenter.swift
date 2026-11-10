// Copyright (c) 2026 Charlie Rodriguez Garcia. All rights reserved.
import Metal
import QuartzCore
import UIKit

/// Presents emulated frames with Metal, paced by one CADisplayLink.
///
/// On every display refresh it checks whether the core finished a new frame. If so it copies
/// both screens at once (they always come from the same emulated frame) into a shared staging
/// buffer, blits it into one private 256x384 texture on the GPU queue, and redraws every
/// attached screen view from it. Three staging buffers rotate so the CPU never overwrites one
/// a pending blit still reads; GPU queue order keeps the texture consistent. (Private texture +
/// blit also works in the iOS Simulator, which lacks shared-storage textures.) The display link
/// also wakes the emulation thread (`onVSync`) so emulation is paced by the display.
/// How the DS pixels are scaled onto the display.
enum DisplayFilter: String, CaseIterable, Identifiable {
    case nearest, linear, scanlines, sharpBilinear, edgeDirected
    var id: String { rawValue }
    var label: String { englishLabel.loc }
    /// English source text (the String Catalog key).
    var englishLabel: String {
        switch self {
        case .nearest: return "Sharp (nearest)"
        case .linear: return "Smooth (linear)"
        case .scanlines: return "LCD / CRT scanlines"
        case .sharpBilinear: return "Sharp bilinear"
        case .edgeDirected: return "Smart 2D (edge-directed)"
        }
    }
    var shaderMode: Float {
        switch self {
        case .nearest: return 0
        case .linear: return 1
        case .scanlines: return 2
        case .sharpBilinear: return 3
        case .edgeDirected: return 4
        }
    }
}

/// Colour adjustments applied after the filter. Neutral = brightness 0, contrast 1, saturation 1, gamma 1.
struct ColorAdjust: Equatable {
    var brightness: Float = 0      // -0.5 ... 0.5
    var contrast: Float = 1        // 0.5 ... 1.5
    var saturation: Float = 1      // 0 ... 2
    var gamma: Float = 1           // 0.5 ... 2
    var lcdCorrection = false

    static func load() -> ColorAdjust {
        let d = UserDefaults.standard
        var c = ColorAdjust()
        if let v = d.object(forKey: "colorBrightness") as? Double { c.brightness = Float(v) }
        if let v = d.object(forKey: "colorContrast") as? Double { c.contrast = Float(v) }
        if let v = d.object(forKey: "colorSaturation") as? Double { c.saturation = Float(v) }
        if let v = d.object(forKey: "colorGamma") as? Double { c.gamma = Float(v) }
        c.lcdCorrection = d.bool(forKey: "lcdCorrection")
        return c
    }
}

private struct ShaderParams { var range: SIMD4<Float>; var color: SIMD4<Float>; var crop: SIMD4<Float> }

final class FramePresenter {
    static let width = 256, height = 384            // top screen rows 0-191, bottom rows 192-383 (at 1x)
    static let maxScale = 4

    let device: MTLDevice
    private let core: DSCoreBridge
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private var texture: MTLTexture
    private var prevTexture: MTLTexture
    /// Frame blending (main thread): mix each frame 50/50 with the previous one.
    var frameBlend = false { didSet { redrawAll() } }
    private var textureScale = 1
    /// Display filter (main thread).
    var filter: DisplayFilter = .nearest { didSet { redrawAll() } }
    /// Colour adjustments (main thread).
    var color = ColorAdjust() { didSet { redrawAll() } }
    private let staging: [MTLBuffer]
    private var stagingIndex = 0
    private var lastSequence: UInt64 = .max
    private var link: CADisplayLink?
    private let views = NSHashTable<MetalScreenLayerView>.weakObjects()
    private let inFlight = DispatchSemaphore(value: 3)

    /// Called on the main thread at every display refresh.
    var onVSync: (() -> Void)?
    /// Single-screen systems (GBA): the used fraction (width, height) of the top 256x192 screen.
    var singleScreenCrop: CGSize?
    /// Frames shown during the last second (main thread).
    private(set) var displayedFPS: Double = 0
    private var fpsCount = 0
    private var fpsStart = CACurrentMediaTime()

    init?(core: DSCoreBridge) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        // range: x,y = vertical texture range of this screen, z = filter mode, w = LCD colour correction
        // color: brightness, contrast, saturation, gamma
        // crop: x = horizontal texture range (1 for DS screens, 240/256 for the GBA picture), y = frame blending
        struct Params { float4 range; float4 color; float4 crop; };
        vertex VOut twinVertex(uint vid [[vertex_id]], constant Params &p [[buffer(0)]]) {
            float x = (vid & 1) ? 1.0 : 0.0, y = (vid & 2) ? 1.0 : 0.0;
            VOut o;
            o.pos = float4(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
            o.uv = float2(x * p.crop.x, mix(p.range.x, p.range.y, y));
            return o;
        }
        constant float2 kDS = float2(256.0, 384.0);   // DS pixel grid of the whole texture (both screens)
        // DS pixel (integer coordinates) -> its centre sample in the (possibly upscaled) texture.
        static float3 px(texture2d<float> t, sampler s, float2 ip) {
            ip = clamp(ip, float2(0.0), kDS - 1.0);
            return t.sample(s, (ip + 0.5) / kDS).rgb;
        }
        static bool same(float3 a, float3 b) { return all(abs(a - b) < 0.02); }
        // Original edge-directed 2D smoothing: in each corner of a DS pixel, when the two
        // neighbours touching that corner match each other (and not the pixel or the other
        // pair), the corner takes their colour along a 45-degree edge, anti-aliased by distance.
        static float3 edgeDirected(texture2d<float> t, sampler s, float2 uv) {
            float2 p = uv * kDS, ip = floor(p), f = p - ip;
            float3 c = px(t, s, ip);
            float3 u = px(t, s, ip + float2(0, -1)), d = px(t, s, ip + float2(0, 1));
            float3 l = px(t, s, ip + float2(-1, 0)), r = px(t, s, ip + float2(1, 0));
            float aa = max(fwidth(p.x), 0.001) * 1.5;
            float3 o = c;
            // corner direction (sx, sy): which neighbours meet there
            float2 g = f - 0.5;
            float3 hv = g.y < 0.0 ? u : d;            // vertical neighbour on this side
            float3 hh = g.x < 0.0 ? l : r;            // horizontal neighbour on this side
            float3 ov = g.y < 0.0 ? d : u, oh = g.x < 0.0 ? r : l;
            if (same(hv, hh) && !same(hv, c) && !same(hv, ov) && !same(hh, oh)) {
                float dist = abs(g.x) + abs(g.y) - 0.5;          // > 0 beyond the diagonal
                float w = smoothstep(-aa, aa, dist);
                o = mix(c, hv, w);
            }
            return o;
        }
        // Sharp bilinear: nearest inside each texel, linear only across a 1-display-pixel seam.
        // Works on the texture's own grid: 2D layers are upscaled by whole texels (so text stays as
        // crisp as at 1x) and the high-resolution 3D keeps its detail (on the DS grid it was
        // sampled back down to 256x192 and looked soft when enlarged).
        static float3 sharpBilinear(texture2d<float> t, sampler lin, float2 uv) {
            float2 ts = float2(t.get_width(), t.get_height());
            float2 p = uv * ts, ip = floor(p), f = p - ip;
            float2 k = 1.0 / max(fwidth(p), float2(0.001));      // display pixels per texel
            f = clamp((f - 0.5) * k + 0.5, 0.0, 1.0);
            return t.sample(lin, (ip + f) / ts).rgb;
        }
        fragment float4 twinFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                     texture2d<float> prev [[texture(1)]],
                                     sampler s [[sampler(0)]], constant Params &p [[buffer(0)]]) {
            constexpr sampler nearestS(filter::nearest, address::clamp_to_edge);
            constexpr sampler linearS(filter::linear, address::clamp_to_edge);
            int mode = int(p.range.z + 0.5);
            float3 c;
            if (mode == 3) c = sharpBilinear(tex, linearS, in.uv);
            else if (mode == 4) c = edgeDirected(tex, nearestS, in.uv);
            else c = tex.sample(s, in.uv).rgb;
            if (p.crop.y > 0.5) {
                // Frame blending: average with the previous emulated frame, which smooths games that
                // flicker objects on alternate frames to fake transparency.
                float3 q;
                if (mode == 3) q = sharpBilinear(prev, linearS, in.uv);
                else if (mode == 4) q = edgeDirected(prev, nearestS, in.uv);
                else q = prev.sample(s, in.uv).rgb;
                c = mix(c, q, 0.5);
            }
            if (mode == 2) {
                // Simple LCD/CRT look: darken the gap between DS pixel rows and, gently, columns.
                float row = fract(in.uv.y * 384.0), col = fract(in.uv.x * 256.0);
                float sl = 0.70 + 0.30 * sin(row * 3.14159265);
                float gr = 0.90 + 0.10 * sin(col * 3.14159265);
                c = c * sl * gr * 1.12;
            }
            if (p.range.w > 0.5) {
                // LCD colour correction (original approximation of a DS-class panel): darker
                // gamma, a little colour bleed between channels, slightly lifted blacks.
                float3 lin = pow(max(c, 0.0), float3(2.2));
                float3x3 m = float3x3(float3(0.84, 0.09, 0.07), float3(0.13, 0.78, 0.13), float3(0.03, 0.13, 0.80));
                lin = m * lin;
                c = pow(max(lin, 0.0), float3(1.0 / 2.0)) * 0.97 + 0.015;
            }
            c = pow(max(c, 0.0), float3(1.0 / max(p.color.w, 0.1)));     // gamma
            c = (c - 0.5) * p.color.y + 0.5 + p.color.x;                   // contrast, brightness
            float luma = dot(c, float3(0.299, 0.587, 0.114));
            c = mix(float3(luma), c, p.color.z);                           // saturation
            return float4(clamp(c, 0.0, 1.0), 1.0);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "twinVertex")
            desc.fragmentFunction = library.makeFunction(name: "twinFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("TwinPlay: Metal pipeline unavailable: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest; sd.magFilter = .nearest
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        guard let nearest = device.makeSamplerState(descriptor: sd) else { return nil }
        sd.minFilter = .linear; sd.magFilter = .linear
        guard let linear = device.makeSamplerState(descriptor: sd) else { return nil }
        guard let tex = Self.makeTexture(device: device, scale: 1) else { return nil }
        let length = Self.width * Self.height * Self.maxScale * Self.maxScale * 4
        var bufs: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            memset(b.contents(), 0, length)
            bufs.append(b)
        }
        self.device = device; self.core = core; self.queue = queue
        self.nearestSampler = nearest; self.linearSampler = linear
        self.texture = tex; self.staging = bufs
        guard let prev = Self.makeTexture(device: device, scale: 1) else { return nil }
        self.prevTexture = prev
        upload(from: bufs[0])                       // start black
    }

    private static func makeTexture(device: MTLDevice, scale: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width * scale,
                                                          height: height * scale, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .private
        return device.makeTexture(descriptor: td)
    }

    private func redrawAll() { for v in views.allObjects { draw(v) } }

    deinit { link?.invalidate() }

    func attach(_ view: MetalScreenLayerView) {
        views.add(view)
        startIfNeeded()
    }

    func detach(_ view: MetalScreenLayerView) {
        views.remove(view)
        if views.allObjects.isEmpty { link?.invalidate(); link = nil }
    }

    func setActive(_ on: Bool) {
        if on { startIfNeeded() }
        else { link?.invalidate(); link = nil }
    }

    private func startIfNeeded() {
        guard link == nil else { return }
        let l = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.tick))
        if #available(iOS 15.0, *) {
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else {
            l.preferredFramesPerSecond = 60
        }
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Queues a GPU copy of a staging buffer into the texture (ordered before later draws).
    private func upload(from buffer: MTLBuffer) {
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        let w = Self.width * textureScale, h = Self.height * textureScale
        if frameBlend, prevTexture.width == texture.width, prevTexture.height == texture.height {
            blit.copy(from: texture, to: prevTexture)       // keep the outgoing frame for blending
        }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: w * 4,
                  sourceBytesPerImage: w * h * 4,
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
    }

    /// Sequence of the last picture actually drawn (for the stall watchdog).
    private(set) var presentedSequence: UInt64 = 0
    /// Last time the display link fired (for the stall watchdog).
    private(set) var lastTick: CFTimeInterval = 0

    /// Watchdog recovery: forget cached state, rebuild textures and restart the display link.
    func recover() {
        lastSequence = .max
        textureScale = 0
        link?.invalidate(); link = nil
        if !views.allObjects.isEmpty { startIfNeeded() }
    }

    fileprivate func tick() {
        lastTick = CACurrentMediaTime()
        onVSync?()
        let seq = core.frameSequence
        guard seq != lastSequence else { return }
        stagingIndex = (stagingIndex + 1) % staging.count
        let buffer = staging[stagingIndex]
        var scale = 0
        let capacity = Self.width * Self.height * Self.maxScale * Self.maxScale
        lastSequence = core.copyHiResFrame(into: buffer.contents().assumingMemoryBound(to: UInt32.self),
                                           capacity: capacity, scale: &scale)
        guard scale > 0 else { return }
        if scale != textureScale, let t = Self.makeTexture(device: device, scale: scale) {
            texture = t; textureScale = scale
            if let p = Self.makeTexture(device: device, scale: scale) { prevTexture = p }
        }
        guard scale == textureScale else { return }
        upload(from: buffer)
        for v in views.allObjects { draw(v) }
        presentedSequence = lastSequence
        fpsCount += 1
        let now = CACurrentMediaTime()
        if now - fpsStart >= 1 {
            displayedFPS = Double(fpsCount) / (now - fpsStart); fpsCount = 0; fpsStart = now
            #if DEBUG
            NSLog("TwinPlay FPS: %.1f (scale=%d seq=%llu)", displayedFPS, textureScale, lastSequence)
            #endif
        }
    }

    /// Draws one screen view from the current texture (also used after a resize).
    /// `synchronous` (resize / rotation): waits briefly for a free GPU slot instead of dropping
    /// the redraw, and with `presentsWithTransaction` the new picture lands in the same Core
    /// Animation transaction as the new size, so no empty / stretched frame flashes at the edges.
    func draw(_ view: MetalScreenLayerView, synchronous: Bool = false) {
        let layer = view.metalLayer
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return }
        // Never queue more than three frames on the GPU; drop this redraw instead of blocking the UI.
        guard inFlight.wait(timeout: .now() + (synchronous ? 0.05 : 0)) == .success else { return }
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { inFlight.signal(); return }
        let mode = filter.shaderMode
        let lcd: Float = color.lcdCorrection ? 1 : 0
        var range = view.screen == 0 ? SIMD4<Float>(0, 0.5, mode, lcd) : SIMD4<Float>(0.5, 1, mode, lcd)
        var cropX: Float = 1
        if let crop = singleScreenCrop {                     // GBA: 240x160 of the top 256x192 area
            cropX = Float(crop.width)
            range = SIMD4<Float>(0, 0.5 * Float(crop.height), mode, lcd)
        }
        var params = ShaderParams(
            range: range,
            color: SIMD4<Float>(color.brightness, color.contrast, color.saturation, color.gamma),
            crop: SIMD4<Float>(cropX, frameBlend ? 1 : 0, 0, 0))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&params, length: MemoryLayout<ShaderParams>.stride, index: 0)
        enc.setFragmentBytes(&params, length: MemoryLayout<ShaderParams>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentTexture(frameBlend ? prevTexture : texture, index: 1)
        enc.setFragmentSamplerState(filter == .linear || filter == .scanlines ? linearSampler : nearestSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        let sem = inFlight
        cb.addCompletedHandler { _ in sem.signal() }
        if layer.presentsWithTransaction {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
    }
}

/// Breaks the CADisplayLink -> target retain cycle.
private final class LinkProxy: NSObject {
    weak var presenter: FramePresenter?
    init(_ p: FramePresenter) { presenter = p }
    @objc func tick() { presenter?.tick() }
}

/// One DS screen drawn by a FramePresenter into a CAMetalLayer.
final class MetalScreenLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }   // swiftlint:disable:this force_cast
    private(set) var screen = 0
    private weak var presenter: FramePresenter?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(presenter: FramePresenter, screen: Int) {
        self.screen = screen
        if self.presenter !== presenter {
            self.presenter?.detach(self)
            self.presenter = presenter
            metalLayer.device = presenter.device
            if window != nil { presenter.attach(self) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let presenter else { return }
        if window != nil { presenter.attach(self) } else { presenter.detach(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            // Resize / rotation: the new drawable starts empty. Draw the current frame into it
            // inside this layout transaction (no black or stretched flash around the screens),
            // then go back to the normal, non-blocking presentation.
            metalLayer.presentsWithTransaction = true
            metalLayer.drawableSize = size
            presenter?.draw(self, synchronous: true)
            DispatchQueue.main.async { [weak self] in self?.metalLayer.presentsWithTransaction = false }
        }
    }

    func detachFromPresenter() { presenter?.detach(self) }
}
