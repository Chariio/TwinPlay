// TwinPlay 3DS present surface: a CAMetalLayer for Azahar's Vulkan/MoltenVK
// swapchain (VK_EXT_metal_surface). The swapchain stays at the native stacked
// size (400x240 top + 320x240 bottom in a 400x480 framebuffer). A hidden
// UIWindow hosts the layer *before* Vulkan init so MoltenVK never creates a
// (0, 0) swapchain. The visible host view composites the two screen regions
// into the skin cutouts (correcting the bottom source rect) instead of
// resizing Azahar's swapchain to the skin union.
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <TargetConditionals.h>
#include <atomic>

static constexpr int kSrcW = 400, kSrcH = 480;
static constexpr int kTopW = 400, kTopH = 240, kBotW = 320, kBotH = 240, kBotX = 40, kBotY = 240;

@interface TP3DSMetalLayer : CAMetalLayer
@property (atomic, strong) id<CAMetalDrawable> lastDrawable;
@end
@implementation TP3DSMetalLayer
- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> d = [super nextDrawable];
    self.lastDrawable = d;
    return d;
}
@end

static TP3DSMetalLayer* g_layer = nil;
static UIWindow* g_hiddenWin = nil;
static id<MTLDevice> g_device = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLRenderPipelineState> g_pipe = nil;

extern "C" void twinplay_3ds_set_present_ready(int ready);

static void ensure_pipeline() {
    if (g_pipe) return;
    if (!g_device) g_device = MTLCreateSystemDefaultDevice();
    if (!g_device) return;
    if (!g_queue) g_queue = [g_device newCommandQueue];
    NSString* src = @"#include <metal_stdlib>\n"
                     "using namespace metal;\n"
                     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
                     "vertex VOut tp_v(uint vid [[vertex_id]], constant float4 *q [[buffer(0)]]) {\n"
                     "  VOut o; o.pos = float4(q[vid].x, q[vid].y, 0, 1); o.uv = q[vid].zw; return o;\n"
                     "}\n"
                     "fragment float4 tp_f(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
                     "  constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
                     "  return tex.sample(s, in.uv);\n"
                     "}\n";
    NSError* err = nil;
    id<MTLLibrary> lib = [g_device newLibraryWithSource:src options:nil error:&err];
    if (!lib) {
        NSLog(@"TwinPlay 3DS composite shader failed: %@", err);
        return;
    }
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"tp_v"];
    d.fragmentFunction = [lib newFunctionWithName:@"tp_f"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    g_pipe = [g_device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!g_pipe) NSLog(@"TwinPlay 3DS composite pipeline failed: %@", err);
}

static void attach_hidden_window() {
    if (g_hiddenWin || !g_layer) return;
    UIWindowScene* scene = nil;
    for (UIScene* sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene* ws = (UIWindowScene*)sc;
            if (ws.activationState == UISceneActivationStateForegroundActive || !scene)
                scene = ws;
            if (ws.activationState == UISceneActivationStateForegroundActive) break;
        }
    }
    UIWindow* w = nil;
    if (scene) w = [[UIWindow alloc] initWithWindowScene:scene];
    else w = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, kSrcW, kSrcH)];
    // Park the window off-screen so the layer has a real screen/view but is not visible.
    w.frame = CGRectMake(-4000, 0, kSrcW, kSrcH);
    w.windowLevel = UIWindowLevelNormal - 1000;
    w.hidden = NO;
    UIViewController* vc = [UIViewController new];
    UIView* v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kSrcW, kSrcH)];
    v.backgroundColor = UIColor.blackColor;
    [v.layer addSublayer:g_layer];
    g_layer.frame = v.bounds;
    vc.view = v;
    w.rootViewController = vc;
    g_hiddenWin = w;
    NSLog(@"TwinPlay 3DS metal: hidden 400x480 window attached (scene=%@)", scene);
}

extern "C" void* twinplay_3ds_metal_layer(void) {
    @autoreleasepool {
        void (^create)(void) = ^{
            if (!g_layer) {
                g_layer = [TP3DSMetalLayer layer];
                g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                // Must be NO so the host compositor can sample lastDrawable.
                g_layer.framebufferOnly = NO;
                g_layer.opaque = YES;
                g_layer.contentsScale = 1;
                g_layer.drawableSize = CGSizeMake(kSrcW, kSrcH);
                g_layer.frame = CGRectMake(0, 0, kSrcW, kSrcH);
                if (!g_device) g_device = MTLCreateSystemDefaultDevice();
                if (g_device) g_layer.device = g_device;
            }
            attach_hidden_window();
        };
        if ([NSThread isMainThread]) create();
        else dispatch_sync(dispatch_get_main_queue(), create);
        return (__bridge void*)g_layer;
    }
}

extern "C" void twinplay_3ds_set_drawable_size(int w, int h, float scale) {
    // The Vulkan swapchain stays at the native 400x480 stack. Host resizes
    // must not change it (a 0x0 or skin-union extent presented black).
    (void)w; (void)h; (void)scale;
    CAMetalLayer* layer = (__bridge CAMetalLayer*)twinplay_3ds_metal_layer();
    void (^apply)(void) = ^{
        layer.contentsScale = 1;
        layer.drawableSize = CGSizeMake(kSrcW, kSrcH);
        if (layer.frame.size.width < 8 || layer.frame.size.height < 8)
            layer.frame = CGRectMake(0, 0, kSrcW, kSrcH);
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

extern "C" void twinplay_3ds_set_layer_frame(float x, float y, float w, float h) {
    (void)x; (void)y; (void)w; (void)h;
    // Keep the source layer at 400x480 in the hidden window.
}

static void fill_quad(float* q, float x0, float y0, float x1, float y1,
                      float u0, float v0, float u1, float v1, float dw, float dh) {
    // Convert dest pixels (top-left origin) to NDC (y-up). UVs are top-left in the texture.
    auto ndc_x = [&](float x) { return (dw > 0) ? (2.f * x / dw - 1.f) : 0.f; };
    auto ndc_y = [&](float y) { return (dh > 0) ? (1.f - 2.f * y / dh) : 0.f; };
    // triangle strip: tl, tr, bl, br
    q[0] = ndc_x(x0); q[1] = ndc_y(y0); q[2] = u0; q[3] = v0;
    q[4] = ndc_x(x1); q[5] = ndc_y(y0); q[6] = u1; q[7] = v0;
    q[8] = ndc_x(x0); q[9] = ndc_y(y1); q[10] = u0; q[11] = v1;
    q[12] = ndc_x(x1); q[13] = ndc_y(y1); q[14] = u1; q[15] = v1;
}

extern "C" void twinplay_3ds_composite_to_layer(void* dest_layer,
                                              float scale,
                                              float top_dx, float top_dy, float top_dw, float top_dh,
                                              float bot_dx, float bot_dy, float bot_dw, float bot_dh) {
    if (!dest_layer) return;
    CAMetalLayer* dest = (__bridge CAMetalLayer*)dest_layer;
    TP3DSMetalLayer* src = g_layer;
    if (!src) return;
    id<CAMetalDrawable> srcDraw = src.lastDrawable;
    if (!srcDraw) return;
    ensure_pipeline();
    if (!g_pipe || !g_queue) return;
    if (!dest.device) dest.device = g_device ?: src.device;
    id<CAMetalDrawable> out = [dest nextDrawable];
    if (!out) return;
    const float dw = (float)dest.drawableSize.width;
    const float dh = (float)dest.drawableSize.height;
    if (dw < 16 || dh < 16) {
        // Never present into a zero/tiny swapchain.
        return;
    }
    if (scale < 1) scale = 1;
    const float tx = top_dx * scale, ty = top_dy * scale, tw = top_dw * scale, th = top_dh * scale;
    const float bx = bot_dx * scale, by = bot_dy * scale, bw = bot_dw * scale, bh = bot_dh * scale;
    const float u0t = 0, v0t = 0, u1t = 1, v1t = (float)kTopH / (float)kSrcH;
    const float u0b = (float)kBotX / (float)kSrcW, v0b = (float)kBotY / (float)kSrcH;
    const float u1b = (float)(kBotX + kBotW) / (float)kSrcW, v1b = (float)(kBotY + kBotH) / (float)kSrcH;

    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = out.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLCommandBuffer> cmd = [g_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:g_pipe];
    [enc setFragmentTexture:srcDraw.texture atIndex:0];
    float q[16];
    if (tw >= 8 && th >= 8) {
        fill_quad(q, tx, ty, tx + tw, ty + th, u0t, v0t, u1t, v1t, dw, dh);
        [enc setVertexBytes:q length:sizeof(q) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    if (bw >= 8 && bh >= 8) {
        fill_quad(q, bx, by, bx + bw, by + bh, u0b, v0b, u1b, v1b, dw, dh);
        [enc setVertexBytes:q length:sizeof(q) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [enc endEncoding];
    [cmd presentDrawable:out];
    [cmd commit];
}
