#import "../LiquidGlass.h"
#import <objc/runtime.h>

static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");

static void startAppLibDisplayLink(void);
static void stopAppLibDisplayLink(void);
static void LGAppLibraryRefreshAllHosts(void);
static void LGRemoveAppLibraryGlass(UIView *view);
static BOOL isInsideSearchTextField(UIView *view);
static UIView *LGAppLibraryPodHostView(UIView *view);
static void LGAppLibraryPreparePodChildren(UIView *host);
static void LGEnsureAppLibraryTintOverlay(UIView *host, CGFloat cornerRadius, UIColor *tintColor);

@interface LGAppLibTicker : NSObject
- (void)tick:(CADisplayLink *)dl;
@end
@implementation LGAppLibTicker
- (void)tick:(CADisplayLink *)dl {
    LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
}
@end

static CADisplayLink  *sAppLibLink   = nil;
static LGAppLibTicker *sAppLibTicker = nil;
static void *kAppLibRetryKey = &kAppLibRetryKey;
static void *kAppLibOriginalAlphaKey = &kAppLibOriginalAlphaKey;
static void *kAppLibOriginalCornerRadiusKey = &kAppLibOriginalCornerRadiusKey;
static void *kAppLibOriginalClipsKey = &kAppLibOriginalClipsKey;
static void *kAppLibGlassKey = &kAppLibGlassKey;
static void *kAppLibTintKey = &kAppLibTintKey;
static BOOL LGAppLibraryEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"AppLibrary.Enabled", YES); }
static CGFloat LGAppLibCornerRadius(void) { return LG_prefFloat(@"AppLibrary.CornerRadius", 20.2); }
static CGFloat LGAppLibBezelWidth(void) { return LG_prefFloat(@"AppLibrary.BezelWidth", 18.0); }
static CGFloat LGAppLibGlassThickness(void) { return LG_prefFloat(@"AppLibrary.GlassThickness", 150.0); }
static CGFloat LGAppLibRefractionScale(void) { return LG_prefFloat(@"AppLibrary.RefractionScale", 1.8); }
static CGFloat LGAppLibRefractiveIndex(void) { return LG_prefFloat(@"AppLibrary.RefractiveIndex", 1.2); }
static CGFloat LGAppLibSpecularOpacity(void) { return LG_prefFloat(@"AppLibrary.SpecularOpacity", 0.8); }
static CGFloat LGAppLibBlur(void) { return LG_prefFloat(@"AppLibrary.Blur", 25.0); }
static CGFloat LGAppLibWallpaperScale(void) { return LG_prefFloat(@"AppLibrary.WallpaperScale", 0.1); }
static CGFloat LGAppLibLightTintAlpha(void) { return LG_prefFloat(@"AppLibrary.LightTintAlpha", 0.1); }
static CGFloat LGAppLibDarkTintAlpha(void) { return LG_prefFloat(@"AppLibrary.DarkTintAlpha", 0.0); }
static CGFloat LGAppLibSearchCornerRadius(void) { return LG_prefFloat(@"AppLibrary.SearchCornerRadius", 24.0); }
static CGFloat LGAppLibSearchBezelWidth(void) { return LG_prefFloat(@"AppLibrary.SearchBezelWidth", 16.0); }
static CGFloat LGAppLibSearchGlassThickness(void) { return LG_prefFloat(@"AppLibrary.SearchGlassThickness", 100.0); }
static CGFloat LGAppLibSearchRefractionScale(void) { return LG_prefFloat(@"AppLibrary.SearchRefractionScale", 1.5); }
static CGFloat LGAppLibSearchRefractiveIndex(void) { return LG_prefFloat(@"AppLibrary.SearchRefractiveIndex", 1.5); }
static CGFloat LGAppLibSearchSpecularOpacity(void) { return LG_prefFloat(@"AppLibrary.SearchSpecularOpacity", 0.8); }
static CGFloat LGAppLibSearchBlur(void) { return LG_prefFloat(@"AppLibrary.SearchBlur", 25.0); }
static CGFloat LGAppLibSearchWallpaperScale(void) { return LG_prefFloat(@"AppLibrary.SearchWallpaperScale", 0.1); }
static CGFloat LGAppLibSearchLightTintAlpha(void) { return LG_prefFloat(@"AppLibrary.SearchLightTintAlpha", 0.1); }
static CGFloat LGAppLibSearchDarkTintAlpha(void) { return LG_prefFloat(@"AppLibrary.SearchDarkTintAlpha", 0.0); }

static NSInteger LGAppLibraryPreferredFPS(void) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fps = LG_prefInteger(@"AppLibrary.FPS", maxFPS >= 120 ? 120 : 60);
    if (fps < 30) fps = 30;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

static void stripFocusMaterialFiltersIfNeeded(UIView *view) {
    NSArray *filters = view.layer.filters;
    if (filters.count) {
        NSMutableArray *cleaned = [NSMutableArray arrayWithCapacity:filters.count];
        BOOL found = NO;
        for (id f in filters) {
            NSString *name = [f valueForKey:@"name"];
            if ([name containsString:@"ibrant"] || [name containsString:@"olorMatrix"])
                found = YES;
            else
                [cleaned addObject:f];
        }
        if (found) view.layer.filters = cleaned;
    }
    view.layer.compositingFilter = nil;
}

static void startAppLibDisplayLink(void) {
    if (!LGAppLibraryEnabled()) return;
    if (sAppLibLink) return;
    sAppLibTicker = [LGAppLibTicker new];
    sAppLibLink   = [CADisplayLink displayLinkWithTarget:sAppLibTicker
                                               selector:@selector(tick:)];
    if ([sAppLibLink respondsToSelector:@selector(setPreferredFramesPerSecond:)])
        sAppLibLink.preferredFramesPerSecond = LGAppLibraryPreferredFPS();
    [sAppLibLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
static void stopAppLibDisplayLink(void) {
    [sAppLibLink invalidate];
    sAppLibLink = nil;
    sAppLibTicker = nil;
}

static void LGSyncAppLibraryDisplayLink(void) {
    if (LGAppLibraryEnabled()) startAppLibDisplayLink();
    else stopAppLibDisplayLink();
}

static void LGAppLibraryRememberOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kAppLibOriginalAlphaKey))
        objc_setAssociatedObject(view, kAppLibOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kAppLibOriginalCornerRadiusKey))
        objc_setAssociatedObject(view, kAppLibOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kAppLibOriginalClipsKey))
        objc_setAssociatedObject(view, kAppLibOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGAppLibraryRestoreOriginalState(UIView *view) {
    NSNumber *alpha = objc_getAssociatedObject(view, kAppLibOriginalAlphaKey);
    if (alpha) view.alpha = [alpha doubleValue];
    NSNumber *radius = objc_getAssociatedObject(view, kAppLibOriginalCornerRadiusKey);
    if (radius) view.layer.cornerRadius = [radius doubleValue];
    NSNumber *clips = objc_getAssociatedObject(view, kAppLibOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
}

static void LGRemoveAppLibraryGlass(UIView *view) {
    UIView *tint = objc_getAssociatedObject(view, kAppLibTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(view, kAppLibTintKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kAppLibGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kAppLibGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static UIColor *LGAppLibraryTintColorForView(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:darkAlpha];
    }
    return [UIColor colorWithWhite:1.0 alpha:lightAlpha];
}

static void LGEnsureAppLibraryTintOverlay(UIView *host, CGFloat cornerRadius, UIColor *tintColor) {
    if (!host) return;
    UIView *tint = objc_getAssociatedObject(host, kAppLibTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:host.bounds];
        tint.userInteractionEnabled = NO;
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, kAppLibTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:tint];
    }
    tint.frame = host.bounds;
    tint.backgroundColor = tintColor;
    tint.layer.cornerRadius = cornerRadius;
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = host.layer.cornerCurve;
    tint.hidden = (tintColor == nil);
    [host bringSubviewToFront:tint];
}

static UIView *LGAppLibraryPodHostView(UIView *view) {
    UIView *host = view.superview;
    if (!host) return view;
    if ([host isKindOfClass:[UIView class]] &&
        CGRectGetWidth(host.bounds) >= CGRectGetWidth(view.bounds) &&
        CGRectGetHeight(host.bounds) >= CGRectGetHeight(view.bounds)) {
        return host;
    }
    return view;
}

static void LGAppLibraryPreparePodChildren(UIView *host) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"SBHLibraryCategoryPodBackgroundView"]) {
            sub.backgroundColor = [UIColor clearColor];
            sub.layer.backgroundColor = nil;
            sub.alpha = 0.01;
            sub.hidden = NO;
        }
    }
}

static void injectIntoAppLibrary(UIView *self_) {
    UIView *host = LGAppLibraryPodHostView(self_);
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(host);
        return;
    }
    startAppLibDisplayLink();

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *snapshot = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!snapshot) {
        LGAppLibraryRestoreOriginalState(host);
        // first open can beat the wallpaper cache
        if ([objc_getAssociatedObject(host, kAppLibRetryKey) boolValue]) return;
        objc_setAssociatedObject(host, kAppLibRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(host, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoAppLibrary(self_);
        });
        return;
    }

    LGAppLibraryRememberOriginalState(host);
    host.backgroundColor = [UIColor clearColor];
    host.layer.backgroundColor = nil;
    host.layer.cornerRadius = LGAppLibCornerRadius();
    host.layer.masksToBounds = YES;
    if (@available(iOS 13.0, *))
        host.layer.cornerCurve = kCACornerCurveContinuous;
    host.clipsToBounds = YES;

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppLibGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:host.bounds wallpaper:snapshot wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kAppLibGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = snapshot;
    }
    glass.cornerRadius           = LGAppLibCornerRadius();
    glass.bezelWidth             = LGAppLibBezelWidth();
    glass.glassThickness         = LGAppLibGlassThickness();
    glass.refractionScale        = LGAppLibRefractionScale();
    glass.refractiveIndex        = LGAppLibRefractiveIndex();
    glass.specularOpacity        = LGAppLibSpecularOpacity();
    glass.blur                   = LGAppLibBlur();
    glass.wallpaperScale         = LGAppLibWallpaperScale();
    glass.updateGroup            = LGUpdateGroupAppLibrary;
    LGAppLibraryPreparePodChildren(host);
    LGEnsureAppLibraryTintOverlay(host,
                                  LGAppLibCornerRadius(),
                                  LGAppLibraryTintColorForView(host,
                                                               LGAppLibLightTintAlpha(),
                                                               LGAppLibDarkTintAlpha()));
    objc_setAssociatedObject(host, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [glass updateOrigin];
}

static void injectIntoSearchBar(UIView *self_) {
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        return;
    }
    startAppLibDisplayLink();

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *snapshot = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!snapshot) {
        LGAppLibraryRestoreOriginalState(self_);
        // same deal for the search field path
        if ([objc_getAssociatedObject(self_, kAppLibRetryKey) boolValue]) return;
        objc_setAssociatedObject(self_, kAppLibRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self_, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoSearchBar(self_);
        });
        return;
    }

    LGAppLibraryRememberOriginalState(self_);

    LiquidGlassView *glass = objc_getAssociatedObject(self_, kAppLibGlassKey);
    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:self_.bounds wallpaper:snapshot wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [self_ insertSubview:glass atIndex:0];
        objc_setAssociatedObject(self_, kAppLibGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        glass.wallpaperImage = snapshot;
    }
    glass.cornerRadius           = LGAppLibSearchCornerRadius();
    glass.bezelWidth             = LGAppLibSearchBezelWidth();
    glass.glassThickness         = LGAppLibSearchGlassThickness();
    glass.refractionScale        = LGAppLibSearchRefractionScale();
    glass.refractiveIndex        = LGAppLibSearchRefractiveIndex();
    glass.specularOpacity        = LGAppLibSearchSpecularOpacity();
    glass.blur                   = LGAppLibSearchBlur();
    glass.wallpaperScale         = LGAppLibSearchWallpaperScale();
    glass.updateGroup            = LGUpdateGroupAppLibrary;
    LGEnsureAppLibraryTintOverlay(self_,
                                  LGAppLibSearchCornerRadius(),
                                  LGAppLibraryTintColorForView(self_,
                                                               LGAppLibSearchLightTintAlpha(),
                                                               LGAppLibSearchDarkTintAlpha()));
    objc_setAssociatedObject(self_, kAppLibRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [glass updateOrigin];
}

static void LGAppLibraryTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root) return;
    block(root);
    for (UIView *sub in root.subviews) LGAppLibraryTraverseViews(sub, block);
}

static void LGAppLibraryRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGAppLibraryTraverseViews(window, ^(UIView *view) {
            if ([NSStringFromClass(view.class) isEqualToString:@"SBHLibraryCategoryPodBackgroundView"]) {
                injectIntoAppLibrary(view);
                return;
            }
            if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")] && isInsideSearchTextField(view)) {
                injectIntoSearchBar(view);
            }
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in [app valueForKey:@"windows"]) refreshWindow(window);
    }
}

static void LGAppLibraryPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGSyncAppLibraryDisplayLink();
        LGAppLibraryRefreshAllHosts();
    });
}

static BOOL isInsideSearchTextField(UIView *view) {
    UIView *v = view.superview;
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBHSearchTextField");
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

%hook SBHLibraryCategoryPodBackgroundView

- (void)drawRect:(CGRect)rect {
    if (LGAppLibraryEnabled()) return;
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        self_.clipsToBounds = YES;
        return;
    }
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        self_.clipsToBounds = YES;
        return;
    }

    injectIntoAppLibrary(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGAppLibraryEnabled()) {
        LGRemoveAppLibraryGlass(self_);
        LGAppLibraryRestoreOriginalState(self_);
        self_.clipsToBounds = YES;
        return;
    }
    injectIntoAppLibrary(self_);
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LGAppLibraryPrefsChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    dispatch_async(dispatch_get_main_queue(), ^{
        LGSyncAppLibraryDisplayLink();
    });
}

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (isInsideSearchTextField(self_)) {
        if (!self_.window) {
            LGRemoveAppLibraryGlass(self_);
            LGAppLibraryRestoreOriginalState(self_);
            return;
        }
        if (!LGAppLibraryEnabled()) {
            LGRemoveAppLibraryGlass(self_);
            LGAppLibraryRestoreOriginalState(self_);
            return;
        }
        injectIntoSearchBar(self_);
        self_.layer.cornerRadius = LGAppLibSearchCornerRadius();
        if (@available(iOS 13.0, *))
            self_.layer.cornerCurve = kCACornerCurveContinuous;
        self_.clipsToBounds = YES;
        return;
    }

    if (!self_.window) return;
    if (!LGAppLibraryEnabled()) return;
    static Class focusCls, podCls;
    if (!focusCls) focusCls = NSClassFromString(@"SBFFocusIsolationView");
    if (!podCls)   podCls   = NSClassFromString(@"SBHLibraryCategoryPodBackgroundView");
    UIView *v = self_.superview;
    while (v) {
        if ([v isKindOfClass:focusCls]) {
            stripFocusMaterialFiltersIfNeeded(self_);
            return;
        }
        if ([v isKindOfClass:podCls]) return;
        v = v.superview;
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;

    if (isInsideSearchTextField(self_)) {
        if (!LGAppLibraryEnabled()) {
            LGRemoveAppLibraryGlass(self_);
            LGAppLibraryRestoreOriginalState(self_);
            return;
        }
        LiquidGlassView *glass = objc_getAssociatedObject(self_, kAppLibGlassKey);
        [glass updateOrigin];
        self_.layer.cornerRadius = LGAppLibSearchCornerRadius();
        if (@available(iOS 13.0, *))
            self_.layer.cornerCurve = kCACornerCurveContinuous;
        self_.clipsToBounds = YES;
        return;
    }

    if (!LGAppLibraryEnabled()) return;
    static Class focusCls2, podCls2;
    if (!focusCls2) focusCls2 = NSClassFromString(@"SBFFocusIsolationView");
    if (!podCls2)   podCls2   = NSClassFromString(@"SBHLibraryCategoryPodBackgroundView");
    UIView *v = self_.superview;
    while (v) {
        if ([v isKindOfClass:focusCls2]) {
            stripFocusMaterialFiltersIfNeeded(self_);
            return;
        }
        if ([v isKindOfClass:podCls2]) return;
        v = v.superview;
    }
}

%end

%hook BSUIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!sAppLibLink) LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
}

%end
