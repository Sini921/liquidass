#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSInteger kDockTintTag       = 0xD0CC;
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");

typedef NS_ENUM(NSInteger, LGDockMode) {
    LGDockModeNone = 0,
    LGDockModeRegular,
    LGDockModeFloating,
};

static void stopDockDisplayLink(void);
static void LGDockRefreshAllHosts(void);

@interface LGDockTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end

@implementation LGDockTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupDock);
}
@end

static CADisplayLink *sDockLink = nil;
static LGDockTicker *sDockTicker = nil;
static NSInteger sDockCount = 0;

static BOOL LGDockEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"Dock.Enabled", YES); }
static CGFloat LGDockCornerRadiusHomeButton(void) { return LG_prefFloat(@"Dock.CornerRadiusHomeButton", 0.0); }
static CGFloat LGDockCornerRadiusFullScreen(void) { return LG_prefFloat(@"Dock.CornerRadiusFullScreen", 34.0); }
static CGFloat LGDockCornerRadiusFloating(void) { return LG_prefFloat(@"Dock.CornerRadiusFloating", 30.5); }
static CGFloat LGDockBezelWidth(void) { return LG_prefFloat(@"Dock.BezelWidth", 30.0); }
static CGFloat LGDockGlassThickness(void) { return LG_prefFloat(@"Dock.GlassThickness", 150.0); }
static CGFloat LGDockRefractionScale(void) { return LG_prefFloat(@"Dock.RefractionScale", 1.5); }
static CGFloat LGDockRefractiveIndex(void) { return LG_prefFloat(@"Dock.RefractiveIndex", 1.5); }
static CGFloat LGDockSpecularOpacity(void) { return LG_prefFloat(@"Dock.SpecularOpacity", 0.5); }
static CGFloat LGDockBlur(void) { return LG_prefFloat(@"Dock.Blur", 10.0); }
static CGFloat LGDockWallpaperScale(void) { return LG_prefFloat(@"Dock.WallpaperScale", 0.25); }
static CGFloat LGDockLightTintAlpha(void) { return LG_prefFloat(@"Dock.LightTintAlpha", 0.1); }
static CGFloat LGDockDarkTintAlpha(void) { return LG_prefFloat(@"Dock.DarkTintAlpha", 0.0); }

static NSInteger LGDockPreferredFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fps = LG_prefInteger(@"Homescreen.FPS", maxFPS >= 120 ? 120 : 60);
    if (fps < 30) fps = 30;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

static BOOL hasAncestorClass(UIView *view, Class cls) {
    if (!cls) return NO;
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isInsideCategoryStackBackground(UIView *view) {
    UIView *v = view;
    while (v) {
        NSString *name = NSStringFromClass(v.class);
        if (name && [name containsString:@"StackViewBackground"]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL LGHasFloatingDockWindow(void) {
    static Class floatingWindowCls;
    if (!floatingWindowCls) floatingWindowCls = NSClassFromString(@"SBFloatingDockWindow");
    if (!floatingWindowCls) return NO;

    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if ([window isKindOfClass:floatingWindowCls]) return YES;
            }
        }
        return NO;
    }

    for (UIWindow *window in [app valueForKey:@"windows"])
        if ([window isKindOfClass:floatingWindowCls]) return YES;
    return NO;
}

static BOOL isInsideRegularDock(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBDockView");
    return hasAncestorClass(view, cls);
}

static BOOL isInsideFloatingDock(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFloatingDockPlatterView");
    return hasAncestorClass(view, cls);
}

static BOOL isReasonableDockMaterialBounds(CGRect bounds) {
    return bounds.size.width >= 60.0 && bounds.size.height >= 40.0;
}

static void *kDockRetryKey = &kDockRetryKey;
static void *kDockAttachedKey = &kDockAttachedKey;
static void *kDockModeKey = &kDockModeKey;
static void *kDockTintKey = &kDockTintKey;
static void *kDockGlassKey = &kDockGlassKey;

static LGDockMode LGResolveDockModeForView(UIView *view) {
    if (isInsideCategoryStackBackground(view)) return LGDockModeNone;
    if (!isReasonableDockMaterialBounds(view.bounds)) return LGDockModeNone;
    BOOL insideFloating = isInsideFloatingDock(view);
    BOOL insideRegular = isInsideRegularDock(view);
    if (!insideFloating && !insideRegular) return LGDockModeNone;
    if (insideFloating && LGHasFloatingDockWindow()) return LGDockModeFloating;
    if (insideRegular) return LGDockModeRegular;
    if (insideFloating) return LGDockModeFloating;
    return LGDockModeNone;
}

static void startDockDisplayLink(void) {
    if (sDockLink) return;
    sDockTicker = [LGDockTicker new];
    sDockLink = [CADisplayLink displayLinkWithTarget:sDockTicker selector:@selector(tick:)];
    if ([sDockLink respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        sDockLink.preferredFramesPerSecond = LGDockPreferredFPS();
    [sDockLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

static void stopDockDisplayLink(void) {
    [sDockLink invalidate];
    sDockLink = nil;
    sDockTicker = nil;
}

static UIColor *dockTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        if (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [[UIColor blackColor] colorWithAlphaComponent:LGDockDarkTintAlpha()];
    }
    return [[UIColor whiteColor] colorWithAlphaComponent:LGDockLightTintAlpha()];
}

static void ensureDockTintOverlay(UIView *host) {
    if (!host) return;
    UIView *tint = objc_getAssociatedObject(host, kDockTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:host.bounds];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.tag = kDockTintTag;
        objc_setAssociatedObject(host, kDockTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:tint];
    }
    tint.frame = host.bounds;
    tint.layer.cornerRadius = host.layer.cornerRadius;
    tint.layer.cornerCurve = host.layer.cornerCurve;
    tint.backgroundColor = dockTintColorForView(host);
    tint.hidden = (tint.backgroundColor == nil);
    [host bringSubviewToFront:tint];
}

static void removeDockOverlays(UIView *host) {
    if (!host) return;
    UIView *tint = objc_getAssociatedObject(host, kDockTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(host, kDockTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LiquidGlassView *glass = objc_getAssociatedObject(host, kDockGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kDockGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void injectIntoDock(UIView *self_) {
    if (!LGDockEnabled()) {
        removeDockOverlays(self_);
        return;
    }
    NSNumber *modeNumber = objc_getAssociatedObject(self_, kDockModeKey);
    LGDockMode mode = (LGDockMode)modeNumber.integerValue;
    if (mode == LGDockModeNone) return;

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper) {
        if ([objc_getAssociatedObject(self_, kDockRetryKey) boolValue]) return;
        objc_setAssociatedObject(self_, kDockRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self_, kDockRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoDock(self_);
        });
        return;
    }

    LiquidGlassView *glass = objc_getAssociatedObject(self_, kDockGlassKey);

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:self_.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        [self_ addSubview:glass];
        objc_setAssociatedObject(self_, kDockGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = wallpaper;
    }

    glass.cornerRadius    = (mode == LGDockModeFloating)
        ? LGDockCornerRadiusFloating()
        : (LG_isFullScreenDevice() ? LGDockCornerRadiusFullScreen() : LGDockCornerRadiusHomeButton());
    glass.bezelWidth      = LGDockBezelWidth();
    glass.glassThickness  = LGDockGlassThickness();
    glass.refractionScale = LGDockRefractionScale();
    glass.refractiveIndex = LGDockRefractiveIndex();
    glass.specularOpacity = LGDockSpecularOpacity();
    glass.blur            = LGDockBlur();
    glass.wallpaperScale  = LGDockWallpaperScale();
    glass.updateGroup     = LGUpdateGroupDock;
    [glass updateOrigin];
    ensureDockTintOverlay(self_);
    objc_setAssociatedObject(self_, kDockRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGDockTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGDockTraverseViews(sub, block);
}

static void LGDockRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                LGDockTraverseViews(window, ^(UIView *view) {
                    if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                    if (isInsideCategoryStackBackground(view)) {
                        removeDockOverlays(view);
                        return;
                    }
                    LGDockMode mode = LGResolveDockModeForView(view);
                    if (mode == LGDockModeNone) return;
                    objc_setAssociatedObject(view, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    injectIntoDock(view);
                    ensureDockTintOverlay(view);
                });
            }
        }
    } else {
        for (UIWindow *window in [app valueForKey:@"windows"]) {
            LGDockTraverseViews(window, ^(UIView *view) {
                if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
                if (isInsideCategoryStackBackground(view)) {
                    removeDockOverlays(view);
                    return;
                }
                LGDockMode mode = LGResolveDockModeForView(view);
                if (mode == LGDockModeNone) return;
                objc_setAssociatedObject(view, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                injectIntoDock(view);
                ensureDockTintOverlay(view);
            });
        }
    }
}

static void LGDockPrefsChanged(CFNotificationCenterRef center,
                               void *observer,
                               CFStringRef name,
                               const void *object,
                               CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGDockRefreshAllHosts();
    });
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGDockEnabled()) {
        removeDockOverlays(self_);
        return;
    }
    if (isInsideCategoryStackBackground(self_)) {
        removeDockOverlays(self_);
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    if (!self_.window) {
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    LGDockMode mode = LGResolveDockModeForView(self_);
    if (mode == LGDockModeNone) return;
    objc_setAssociatedObject(self_, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self_.backgroundColor       = [UIColor clearColor];
    self_.layer.backgroundColor = nil;
    self_.layer.contents        = nil;
    injectIntoDock(self_);
    ensureDockTintOverlay(self_);
    dispatch_async(dispatch_get_main_queue(), ^{
        ensureDockTintOverlay(self_);
    });
    if (![objc_getAssociatedObject(self_, kDockAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kDockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sDockCount++;
        startDockDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGDockEnabled()) {
        removeDockOverlays(self_);
        return;
    }
    if (isInsideCategoryStackBackground(self_)) {
        removeDockOverlays(self_);
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    LGDockMode mode = (LGDockMode)[objc_getAssociatedObject(self_, kDockModeKey) integerValue];
    if (mode == LGDockModeNone) {
        mode = LGResolveDockModeForView(self_);
        if (mode != LGDockModeNone) {
            objc_setAssociatedObject(self_, kDockModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            self_.backgroundColor = [UIColor clearColor];
            self_.layer.backgroundColor = nil;
            self_.layer.contents = nil;
            injectIntoDock(self_);
            ensureDockTintOverlay(self_);
            if (![objc_getAssociatedObject(self_, kDockAttachedKey) boolValue]) {
                objc_setAssociatedObject(self_, kDockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                sDockCount++;
                startDockDisplayLink();
            }
        }
    }
    if (mode == LGDockModeNone) return;
    self_.backgroundColor       = [UIColor clearColor];
    self_.layer.backgroundColor = nil;
    for (UIView *sub in self_.subviews)
        if ([sub isKindOfClass:[LiquidGlassView class]])
            [(LiquidGlassView *)sub updateOrigin];
    ensureDockTintOverlay(self_);
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    UIView *self_ = (UIView *)self;
    if (!newWindow && [objc_getAssociatedObject(self_, kDockAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kDockAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(self_, kDockModeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        sDockCount = MAX(0, sDockCount - 1);
        if (sDockCount == 0) stopDockDisplayLink();
    }
    %orig;
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGDockPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
