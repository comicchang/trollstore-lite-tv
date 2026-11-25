// shot —— Stage 2 的只读截屏助手（tvOS 17.0）。
//
// 优先 IOMobileFramebuffer 复制当前显示 surface；失败时回退 CARenderServerRenderDisplay。
// 只把 PNG 写到调用方给出的 /var/tmp/tsltv-verify-* 路径，不修改系统状态。
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

typedef void (*CARenderServerRenderDisplayFn)(kern_return_t a, CFStringRef display,
                                              IOSurfaceRef surface, int x, int y);

static BOOL SaveSurface(IOSurfaceRef surf, const char *outPath, size_t *nonZeroOut) {
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surf);
    size_t width = IOSurfaceGetWidth(surf);
    size_t height = IOSurfaceGetHeight(surf);
    size_t bpr = IOSurfaceGetBytesPerRow(surf);
    const uint32_t *px = (const uint32_t *)base;
    size_t nonZero = 0;
    size_t step = (width * height) / 4000;
    if (step < 1) step = 1;
    for (size_t i = 0; i < width * height; i += step) {
        if ((px[i] & 0x00FFFFFF) != 0) nonZero++;
    }
    if (nonZeroOut) *nonZeroOut = nonZero;
    fprintf(stderr, "surface %zux%zu bpr=%zu nonBlackSamples=%zu\n",
            width, height, bpr, nonZero);

    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, base, bpr * height, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate(width, height, 8, 32, bpr, cs,
                                   kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                   prov, NULL, false, kCGRenderingIntentDefault);
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:outPath]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    BOOL ok = NO;
    if (dst && img) {
        CGImageDestinationAddImage(dst, img, NULL);
        ok = CGImageDestinationFinalize(dst);
    }
    if (dst) CFRelease(dst);
    if (img) CGImageRelease(img);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, NULL);
    return ok;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *outPath = (argc > 1) ? argv[1] : "/var/tmp/tsltv-verify-shot.png";
        int width = 1920, height = 1080;
        NSString *dispName = @"TVOut";

        Class caDisplayCls = NSClassFromString(@"CADisplay");
        if (caDisplayCls && [caDisplayCls respondsToSelector:@selector(displays)]) {
            NSArray *displays = [caDisplayCls performSelector:@selector(displays)];
            for (id d in displays) {
                NSString *name = [d valueForKey:@"name"];
                NSValue *bv = [d valueForKey:@"bounds"];
                CGRect b = CGRectZero;
                if ([bv isKindOfClass:[NSValue class]]) [bv getValue:&b];
                fprintf(stderr, "display: %s bounds=%.0fx%.0f\n",
                        name.UTF8String, b.size.width, b.size.height);
                if (name.length > 0 && b.size.width > 0 && b.size.height > 0) {
                    dispName = name;
                    width = (int)b.size.width;
                    height = (int)b.size.height;
                }
            }
        }
        if (argc > 2) dispName = [NSString stringWithUTF8String:argv[2]];

        void *iomfb = dlopen(
            "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            RTLD_LAZY);
        if (!iomfb) {
            iomfb = dlopen(
                "/rootfs/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
                RTLD_LAZY);
        }
        if (iomfb) {
            typedef int (*GetMainDisplayFn)(void **conn);
            typedef int (*CopyLayerSurfFn)(void *conn, int layer, IOSurfaceRef *surf);
            GetMainDisplayFn getMain =
                (GetMainDisplayFn)dlsym(iomfb, "IOMobileFramebufferGetMainDisplay");
            CopyLayerSurfFn copySurf =
                (CopyLayerSurfFn)dlsym(iomfb, "IOMobileFramebufferCopyLayerDisplayedSurface");
            if (getMain) {
                void *conn = NULL;
                int kr = getMain(&conn);
                fprintf(stderr, "IOMFB GetMainDisplay kr=0x%x conn=%p\n", kr, conn);
                if (kr == 0 && conn && copySurf) {
                    IOSurfaceRef s = NULL;
                    kr = copySurf(conn, 0, &s);
                    fprintf(stderr, "IOMFB CopyLayerDisplayedSurface kr=0x%x surf=%p\n", kr, s);
                    if (s) {
                        size_t nz = 0;
                        BOOL ok = SaveSurface(s, outPath, &nz);
                        fprintf(stderr, "IOMFB wrote %s ok=%d nz=%zu\n", outPath, ok, nz);
                        if (ok && nz > 0) return 0;
                    }
                }
            }
        }

        void *qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
        if (!qc) {
            qc = dlopen("/rootfs/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
        }
        CARenderServerRenderDisplayFn renderFn = qc
            ? (CARenderServerRenderDisplayFn)dlsym(qc, "CARenderServerRenderDisplay") : NULL;
        fprintf(stderr, "CARenderServerRenderDisplay=%p disp=%s %dx%d\n",
                renderFn, dispName.UTF8String, width, height);
        if (!renderFn) return 2;

        int bpe = 4, bpr = width * bpe;
        NSDictionary *props = @{
            (__bridge NSString *)kIOSurfaceWidth: @(width),
            (__bridge NSString *)kIOSurfaceHeight: @(height),
            (__bridge NSString *)kIOSurfaceBytesPerElement: @(bpe),
            (__bridge NSString *)kIOSurfaceBytesPerRow: @(bpr),
            (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241),
            (__bridge NSString *)kIOSurfaceAllocSize: @(bpr * height),
        };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surf) return 3;
        renderFn(0, (__bridge CFStringRef)dispName, surf, 0, 0);
        size_t nz = 0;
        BOOL ok = SaveSurface(surf, outPath, &nz);
        fprintf(stderr, "CARender wrote %s ok=%d nz=%zu\n", outPath, ok, nz);
        CFRelease(surf);
        return (ok && nz > 0) ? 0 : 1;
    }
}