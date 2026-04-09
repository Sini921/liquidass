#import "Common.h"
#import <objc/runtime.h>

static UIImage *sCachedLockSnapshot = nil;
static void *kLockAttachedKey = &kLockAttachedKey;
static void *kLockTintKey = &kLockTintKey;

@interface LGLockTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end

@implementation LGLockTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
}
@end

static CADisplayLink *sLockLink = nil;
static LGLockTicker *sLockTicker = nil;
static NSInteger sLockCount = 0;

static UIView *LGLockscreenHostContainer(UIView *host) {
    if (![host isKindOfClass:[UIVisualEffectView class]]) return host;
    return ((UIVisualEffectView *)host).contentView;
}

BOOL LGLockscreenEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"Lockscreen.Enabled", YES); }
CGFloat LGLockscreenCornerRadius(void) { return LG_prefFloat(@"Lockscreen.CornerRadius", 18.5); }
static CGFloat LGLockscreenBezelWidth(void) { return LG_prefFloat(@"Lockscreen.BezelWidth", 12.0); }
static CGFloat LGLockscreenGlassThickness(void) { return LG_prefFloat(@"Lockscreen.GlassThickness", 80.0); }
static CGFloat LGLockscreenRefractionScale(void) { return LG_prefFloat(@"Lockscreen.RefractionScale", 1.2); }
static CGFloat LGLockscreenRefractiveIndex(void) { return LG_prefFloat(@"Lockscreen.RefractiveIndex", 1.0); }
static CGFloat LGLockscreenSpecularOpacity(void) { return LG_prefFloat(@"Lockscreen.SpecularOpacity", 0.8); }
static CGFloat LGLockscreenBlur(void) { return LG_prefFloat(@"Lockscreen.Blur", 8.0); }
static CGFloat LGLockscreenWallpaperScale(void) { return LG_prefFloat(@"Lockscreen.WallpaperScale", 0.5); }
static CGFloat LGLockscreenLightTintAlpha(void) { return LG_prefFloat(@"Lockscreen.LightTintAlpha", 0.1); }
static CGFloat LGLockscreenDarkTintAlpha(void) { return LG_prefFloat(@"Lockscreen.DarkTintAlpha", 0.0); }

static UIColor *LGLockscreenTintColorForHost(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:darkAlpha];
    }
    return [UIColor colorWithWhite:1.0 alpha:lightAlpha];
}

static void LGEnsureLockscreenTintOverlay(UIView *host,
                                          CGFloat cornerRadius,
                                          CGFloat lightTintAlpha,
                                          CGFloat darkTintAlpha) {
    UIView *container = LGLockscreenHostContainer(host);
    if (!container) return;
    UIView *tint = objc_getAssociatedObject(host, kLockTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:container.bounds];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, kLockTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:tint];
    }
    tint.frame = container.bounds;
    tint.backgroundColor = LGLockscreenTintColorForHost(container, lightTintAlpha, darkTintAlpha);
    tint.layer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = container.layer.cornerCurve;
    tint.hidden = (tint.backgroundColor == nil);
    [container bringSubviewToFront:tint];
}

static NSInteger LGLockscreenPreferredFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fps = LG_prefInteger(@"Lockscreen.FPS", maxFPS >= 120 ? 120 : 60);
    if (fps < 30) fps = 30;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

BOOL LGIsAtLeastiOS16(void) {
    static BOOL cached;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cached = [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return cached;
}

static void LGStartLockDisplayLink(void) {
    if (!LGLockscreenEnabled()) return;
    if (sLockLink) return;
    sLockTicker = [LGLockTicker new];
    sLockLink = [CADisplayLink displayLinkWithTarget:sLockTicker selector:@selector(tick:)];
    if ([sLockLink respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        sLockLink.preferredFramesPerSecond = LGLockscreenPreferredFPS();
    [sLockLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void LGStopLockDisplayLink(void) {
    [sLockLink invalidate];
    sLockLink = nil;
    sLockTicker = nil;
}

void LGInvalidateLockscreenSnapshotCache(void) {
    sCachedLockSnapshot = nil;
}

UIImage *LGGetLockscreenSnapshotCached(void) {
    if (!sCachedLockSnapshot)
        sCachedLockSnapshot = LG_getLockscreenSnapshot();
    return sCachedLockSnapshot;
}

void LGRefreshLockSnapshotAfterDelay(NSTimeInterval delay) {
    sCachedLockSnapshot = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sCachedLockSnapshot = LG_getLockscreenSnapshot();
        if (sCachedLockSnapshot)
            LGLockscreenRefreshAllHosts();
    });
}

void LGDetachLockHostIfNeeded(UIView *view) {
    if (![objc_getAssociatedObject(view, kLockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kLockAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    sLockCount = MAX(0, sLockCount - 1);
    if (sLockCount == 0) LGStopLockDisplayLink();
}

void LGRemoveLockscreenGlass(UIView *host) {
    UIView *container = LGLockscreenHostContainer(host);
    if (!container) return;
    UIView *tint = objc_getAssociatedObject(host, kLockTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(host, kLockTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    for (UIView *sub in [container.subviews copy]) {
        if ([sub isKindOfClass:[LiquidGlassView class]]) [sub removeFromSuperview];
    }
}

void LGCleanupLockscreenHost(UIView *host) {
    LGRemoveLockscreenGlass(host);
    LGDetachLockHostIfNeeded(host);
}

void LGAttachLockHostIfNeeded(UIView *view) {
    if ([objc_getAssociatedObject(view, kLockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kLockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sLockCount++;
    LGStartLockDisplayLink();
}

CGFloat LGLockscreenResolvedCornerRadius(UIView *view, CGFloat fallback) {
    if (!view) return fallback;
    if (view.layer.cornerRadius > 0.0f) return view.layer.cornerRadius;
    if (view.superview.layer.cornerRadius > 0.0f) return view.superview.layer.cornerRadius;
    return fallback;
}

void LGLockscreenInjectGlassWithSettings(UIView *host,
                                         CGFloat cornerRadius,
                                         CGFloat bezelWidth,
                                         CGFloat glassThickness,
                                         CGFloat refractionScale,
                                         CGFloat refractiveIndex,
                                         CGFloat specularOpacity,
                                         CGFloat blur,
                                         CGFloat wallpaperScale,
                                         CGFloat lightTintAlpha,
                                         CGFloat darkTintAlpha) {
    UIView *container = LGLockscreenHostContainer(host);
    if (!container) return;

    if (!LGLockscreenEnabled()) {
        LGCleanupLockscreenHost(host);
        return;
    }

    UIImage *wallpaper = LGGetLockscreenSnapshotCached();
    if (!wallpaper) return;
    CGPoint wallpaperOrigin = LG_getLockscreenWallpaperOrigin();

    LiquidGlassView *glass = nil;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[LiquidGlassView class]]) {
            glass = (LiquidGlassView *)sub;
            break;
        }
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:container.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [container insertSubview:glass atIndex:0];
    } else {
        glass.wallpaperImage = wallpaper;
        glass.wallpaperOrigin = wallpaperOrigin;
        glass.userInteractionEnabled = NO;
    }

    glass.cornerRadius    = cornerRadius;
    glass.bezelWidth      = bezelWidth;
    glass.glassThickness  = glassThickness;
    glass.refractionScale = refractionScale;
    glass.refractiveIndex = refractiveIndex;
    glass.specularOpacity = specularOpacity;
    glass.blur            = blur;
    glass.wallpaperScale  = wallpaperScale;
    glass.updateGroup     = LGUpdateGroupLockscreen;
    LGEnsureLockscreenTintOverlay(host, cornerRadius, lightTintAlpha, darkTintAlpha);

    [glass updateOrigin];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [glass updateOrigin]; });
}

void LGLockscreenInjectGlass(UIView *host, CGFloat cornerRadius) {
    LGLockscreenInjectGlassWithSettings(host,
                                        cornerRadius,
                                        LGLockscreenBezelWidth(),
                                        LGLockscreenGlassThickness(),
                                        LGLockscreenRefractionScale(),
                                        LGLockscreenRefractiveIndex(),
                                        LGLockscreenSpecularOpacity(),
                                        LGLockscreenBlur(),
                                        LGLockscreenWallpaperScale(),
                                        LGLockscreenLightTintAlpha(),
                                        LGLockscreenDarkTintAlpha());
}
