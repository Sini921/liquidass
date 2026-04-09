#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSInteger kFolderOpenMaxAttempts = 6;
static const NSTimeInterval kFolderOpenDisplayLinkGrace = 0.18;
static const NSInteger kFolderOpenTintTag = 0xF0D0;
static void *kFolderOpenOriginalAlphaKey = &kFolderOpenOriginalAlphaKey;
static void *kFolderOpenAttachedKey = &kFolderOpenAttachedKey;
static void *kFolderOpenGlassKey = &kFolderOpenGlassKey;
static void *kFolderOpenTintKey = &kFolderOpenTintKey;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");

static BOOL isInsideOpenFolder(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFolderBackgroundView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static void stopFolderDisplayLink(void);
static void LGFolderOpenRefreshAllHosts(void);
static void LGFolderOpenTraverseViews(UIView *root, void (^block)(UIView *view));
static void LGRestoreFolderOpenHost(UIView *view);

static NSInteger sFolderCount = 0;
static NSUInteger sFolderStopGeneration = 0;
static BOOL LGFolderOpenEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"FolderOpen.Enabled", YES); }
static CGFloat LGFolderOpenCornerRadius(void) { return LG_prefFloat(@"FolderOpen.CornerRadius", 38.0); }
static CGFloat LGFolderOpenBezelWidth(void) { return LG_prefFloat(@"FolderOpen.BezelWidth", 24.0); }
static CGFloat LGFolderOpenGlassThickness(void) { return LG_prefFloat(@"FolderOpen.GlassThickness", 100.0); }
static CGFloat LGFolderOpenRefractionScale(void) { return LG_prefFloat(@"FolderOpen.RefractionScale", 1.8); }
static CGFloat LGFolderOpenRefractiveIndex(void) { return LG_prefFloat(@"FolderOpen.RefractiveIndex", 1.2); }
static CGFloat LGFolderOpenSpecularOpacity(void) { return LG_prefFloat(@"FolderOpen.SpecularOpacity", 0.8); }
static CGFloat LGFolderOpenBlur(void) { return LG_prefFloat(@"FolderOpen.Blur", 25.0); }
static CGFloat LGFolderOpenWallpaperScale(void) { return LG_prefFloat(@"FolderOpen.WallpaperScale", 0.1); }
static CGFloat LGFolderOpenLightTintAlpha(void) { return LG_prefFloat(@"FolderOpen.LightTintAlpha", 0.1); }
static CGFloat LGFolderOpenDarkTintAlpha(void) { return LG_prefFloat(@"FolderOpen.DarkTintAlpha", 0.0); }

static UIColor *folderOpenTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:LGFolderOpenDarkTintAlpha()];
    }
    return [UIColor colorWithWhite:1.0 alpha:LGFolderOpenLightTintAlpha()];
}

static void ensureFolderOpenTintOverlay(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kFolderOpenTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:view.bounds];
        tint.tag = kFolderOpenTintTag;
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [view addSubview:tint];
        objc_setAssociatedObject(view, kFolderOpenTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tint.frame = view.bounds;
    tint.backgroundColor = folderOpenTintColorForView(view);
    tint.layer.cornerRadius = LGFolderOpenCornerRadius();
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = view.layer.cornerCurve;
    [view bringSubviewToFront:tint];
}

@interface LGFolderTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end

@implementation LGFolderTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupFolderOpen);
}
@end

static CADisplayLink *sFolderLink = nil;
static LGFolderTicker *sFolderTicker = nil;

static void startFolderDisplayLink(void) {
    sFolderStopGeneration++;
    if (sFolderLink) return;
    sFolderTicker = [LGFolderTicker new];
    sFolderLink = [CADisplayLink displayLinkWithTarget:sFolderTicker selector:@selector(tick:)];
    if ([sFolderLink respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        sFolderLink.preferredFramesPerSecond = LG_prefInteger(@"Homescreen.FPS", 60);
    }
    [sFolderLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void stopFolderDisplayLink(void) {
    sFolderStopGeneration++;
    [sFolderLink invalidate];
    sFolderLink = nil;
    sFolderTicker = nil;
}

static void scheduleFolderDisplayLinkStopIfIdle(void) {
    NSUInteger generation = ++sFolderStopGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderOpenDisplayLinkGrace * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderStopGeneration) return;
        if (sFolderCount != 0) return;
        stopFolderDisplayLink();
    });
}

static void LGRestoreFolderOpenHost(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kFolderOpenTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(view, kFolderOpenTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kFolderOpenGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kFolderOpenGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    NSNumber *originalAlpha = objc_getAssociatedObject(view, kFolderOpenOriginalAlphaKey);
    if (originalAlpha) view.alpha = [originalAlpha doubleValue];
}

static void injectIntoOpenFolder(UIView *host, NSInteger attempt) {
    if (!LGFolderOpenEnabled()) {
        LGRestoreFolderOpenHost(host);
        return;
    }

    LiquidGlassView *glass = objc_getAssociatedObject(host, kFolderOpenGlassKey);
    UIImage *snapshot = LG_getFolderSnapshot();
    if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    if (!snapshot) {
        LG_cacheFolderSnapshot();
        snapshot = LG_getFolderSnapshot();
        if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    }
    if (!snapshot) {
        snapshot = LG_getStrictCachedContextMenuSnapshot();
        if (LG_imageLooksBlack(snapshot)) snapshot = nil;
    }
    if (!snapshot) {
        NSNumber *originalAlpha = objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey);
        if (originalAlpha) host.alpha = [originalAlpha doubleValue];
        if (attempt >= kFolderOpenMaxAttempts) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (host.window) injectIntoOpenFolder(host, attempt + 1);
        });
        return;
    }

    if (!objc_getAssociatedObject(host, kFolderOpenOriginalAlphaKey)) {
        objc_setAssociatedObject(host, kFolderOpenOriginalAlphaKey, @(host.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:host.bounds
                                             wallpaper:snapshot
                                       wallpaperOrigin:CGPointZero];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.updateGroup = LGUpdateGroupFolderOpen;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kFolderOpenGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (glass.wallpaperImage != snapshot) {
        glass.wallpaperImage = snapshot;
    }

    glass.cornerRadius = LGFolderOpenCornerRadius();
    glass.bezelWidth = LGFolderOpenBezelWidth();
    glass.glassThickness = LGFolderOpenGlassThickness();
    glass.refractionScale = LGFolderOpenRefractionScale();
    glass.refractiveIndex = LGFolderOpenRefractiveIndex();
    glass.specularOpacity = LGFolderOpenSpecularOpacity();
    glass.blur = LGFolderOpenBlur();
    glass.wallpaperScale = LGFolderOpenWallpaperScale();
    ensureFolderOpenTintOverlay(host);
    [glass updateOrigin];
    startFolderDisplayLink();
}

static void LGFolderOpenTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGFolderOpenTraverseViews(sub, block);
}

static void LGFolderOpenRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGFolderOpenTraverseViews(window, ^(UIView *view) {
                    if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                    if (!isInsideOpenFolder(view)) return;
                    injectIntoOpenFolder(view, 0);
                });
            }
        }
    } else {
        for (UIWindow *window in [app valueForKey:@"windows"]) {
            LGFolderOpenTraverseViews(window, ^(UIView *view) {
                if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                if (!isInsideOpenFolder(view)) return;
                injectIntoOpenFolder(view, 0);
            });
        }
    }
}

static void LGFolderOpenPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGFolderOpenRefreshAllHosts();
    });
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        LGRestoreFolderOpenHost(self_);
        if ([objc_getAssociatedObject(self_, kFolderOpenAttachedKey) boolValue]) {
            objc_setAssociatedObject(self_, kFolderOpenAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            sFolderCount = MAX(0, sFolderCount - 1);
            if (sFolderCount == 0) scheduleFolderDisplayLinkStopIfIdle();
        }
        return;
    }

    if (!isInsideOpenFolder(self_)) return;
    injectIntoOpenFolder(self_, 0);
    if (![objc_getAssociatedObject(self_, kFolderOpenAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kFolderOpenAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sFolderCount++;
        startFolderDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isInsideOpenFolder(self_)) return;
    if (!LGFolderOpenEnabled()) {
        LGRestoreFolderOpenHost(self_);
        return;
    }
    if (!objc_getAssociatedObject(self_, kFolderOpenOriginalAlphaKey)) {
        objc_setAssociatedObject(self_, kFolderOpenOriginalAlphaKey, @(self_.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderOpenGlassKey);
    ensureFolderOpenTintOverlay(self_);
    if (!glass) {
        injectIntoOpenFolder(self_, 0);
        return;
    }
    [glass updateOrigin];
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGFolderOpenPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
