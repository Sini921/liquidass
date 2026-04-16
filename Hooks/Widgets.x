#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kWidgetTintTag       = 0x71D0;

static void LGWidgetsRefreshAllHosts(void);
static void *kWidgetAttachedKey = &kWidgetAttachedKey;
static void *kWidgetGlassKey = &kWidgetGlassKey;
static void *kWidgetTintKey = &kWidgetTintKey;
static void *kWidgetOriginalAlphaKey = &kWidgetOriginalAlphaKey;
static void *kWidgetOriginalCornerRadiusKey = &kWidgetOriginalCornerRadiusKey;
static void *kWidgetOriginalClipsKey = &kWidgetOriginalClipsKey;
static void *kWidgetOriginalCornerCurveKey = &kWidgetOriginalCornerCurveKey;

static CADisplayLink *sWidgetLink = nil;
static id sWidgetTicker = nil;
static NSInteger sWidgetCount = 0;

LG_ENABLED_BOOL_PREF_FUNC(LGWidgetEnabled, "Widgets.Enabled", NO)
LG_FLOAT_PREF_FUNC(LGWidgetCornerRadius, "Widgets.CornerRadius", 20.2)
LG_FLOAT_PREF_FUNC(LGWidgetBezelWidth, "Widgets.BezelWidth", 18.0)
LG_FLOAT_PREF_FUNC(LGWidgetGlassThickness, "Widgets.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGWidgetRefractionScale, "Widgets.RefractionScale", 1.8)
LG_FLOAT_PREF_FUNC(LGWidgetRefractiveIndex, "Widgets.RefractiveIndex", 1.2)
LG_FLOAT_PREF_FUNC(LGWidgetSpecularOpacity, "Widgets.SpecularOpacity", 0.8)
LG_FLOAT_PREF_FUNC(LGWidgetBlur, "Widgets.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGWidgetWallpaperScale, "Widgets.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGWidgetLightTintAlpha, "Widgets.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGWidgetDarkTintAlpha, "Widgets.DarkTintAlpha", 0.3)

static BOOL LGViewBelongsToWidgetStack(UIView *view) {
    if (!view) return NO;

    NSString *selfClassName = NSStringFromClass([view class]);
    if ([selfClassName containsString:@"Widget"] || [selfClassName containsString:@"WG"]) {
        return YES;
    }

    UIView *ancestor = view.superview;
    while (ancestor) {
        NSString *className = NSStringFromClass([ancestor class]);
        if ([className containsString:@"Widget"] || [className containsString:@"WG"])
            return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static void LGStartWidgetDisplayLink(void) {
    LGStartDisplayLink(&sWidgetLink, &sWidgetTicker, LGPreferredFramesPerSecondForKey(@"Homescreen.FPS", 30), ^{
        LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
    });
}

static void LGStopWidgetDisplayLink(void) {
    LGStopDisplayLink(&sWidgetLink, &sWidgetTicker);
}

static UIColor *widgetTintColorForView(UIView *view) {
    return LGDefaultTintColorForView(view, LGWidgetLightTintAlpha(), LGWidgetDarkTintAlpha());
}

static void removeWidgetOverlays(UIView *view) {
    LGRemoveAssociatedSubview(view, kWidgetTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(view, kWidgetGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGRememberWidgetOriginalState(UIView *view) {
    if (!objc_getAssociatedObject(view, kWidgetOriginalAlphaKey))
        objc_setAssociatedObject(view, kWidgetOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalCornerRadiusKey))
        objc_setAssociatedObject(view, kWidgetOriginalCornerRadiusKey, @(view.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalClipsKey))
        objc_setAssociatedObject(view, kWidgetOriginalClipsKey, @(view.clipsToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view, kWidgetOriginalCornerCurveKey)) {
        NSString *curve = nil;
        if (@available(iOS 13.0, *))
            curve = view.layer.cornerCurve;
        if (curve)
            objc_setAssociatedObject(view, kWidgetOriginalCornerCurveKey, curve, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static void LGRestoreWidgetOriginalState(UIView *view) {
    NSNumber *alpha = objc_getAssociatedObject(view, kWidgetOriginalAlphaKey);
    if (alpha) view.alpha = [alpha doubleValue];
    NSNumber *radius = objc_getAssociatedObject(view, kWidgetOriginalCornerRadiusKey);
    if (radius) view.layer.cornerRadius = [radius doubleValue];
    NSNumber *clips = objc_getAssociatedObject(view, kWidgetOriginalClipsKey);
    if (clips) view.clipsToBounds = [clips boolValue];
    NSString *curve = objc_getAssociatedObject(view, kWidgetOriginalCornerCurveKey);
    if (@available(iOS 13.0, *)) {
        if (curve) view.layer.cornerCurve = curve;
    }
}

static void ensureWidgetTintOverlay(UIView *view) {
    UIView *tint = LGEnsureTintOverlayView(view,
                                           kWidgetTintKey,
                                           kWidgetTintTag,
                                           view.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               widgetTintColorForView(view),
                               view.layer.cornerRadius,
                               view.layer,
                               NO);
    [view bringSubviewToFront:tint];
}

static BOOL LGIsWidgetMaterialView(UIView *view) {
    if (!view.window) return NO;
    if (![NSStringFromClass([view class]) isEqualToString:@"MTMaterialView"]) return NO;
    if (!LGResponderChainContainsClassNamed(view, @"SBHWidgetStackViewController")) return NO;

    // Keep this scoped to the large widget material background, not auxiliary controls.
    if (LGHasAncestorClassNamed(view, @"WGShortLookStyleButton")) return NO;
    if ([view isKindOfClass:[UIControl class]]) return NO;
    if ([view isKindOfClass:[UILabel class]]) return NO;
    if ([view isKindOfClass:[UIImageView class]]) return NO;
    if ([view isKindOfClass:[UIScrollView class]]) return NO;
    if (view.bounds.size.width < 120.0 || view.bounds.size.height < 120.0) return NO;

    return YES;
}

static void LGPrepareWidgetMaterialView(UIView *view) {
    LGRememberWidgetOriginalState(view);
    view.layer.cornerRadius = LGWidgetCornerRadius();
    if (@available(iOS 13.0, *))
        view.layer.cornerCurve = kCACornerCurveContinuous;
    view.clipsToBounds = YES;
}

static void LGInjectIntoWidgetMaterialView(UIView *view) {
    if (!LGWidgetEnabled()) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(view, kWidgetGlassKey);

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getWallpaperImage(&wallpaperOrigin);
    if (!wallpaper) {
        removeWidgetOverlays(view);
        LGRestoreWidgetOriginalState(view);
        return;
    }

    LGPrepareWidgetMaterialView(view);

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:view.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask       = UIViewAutoresizingFlexibleWidth |
                                       UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        glass.cornerRadius           = LGWidgetCornerRadius();
        glass.bezelWidth             = LGWidgetBezelWidth();
        glass.glassThickness         = LGWidgetGlassThickness();
        glass.refractionScale        = LGWidgetRefractionScale();
        glass.refractiveIndex        = LGWidgetRefractiveIndex();
        glass.specularOpacity        = LGWidgetSpecularOpacity();
        glass.blur                   = LGWidgetBlur();
        glass.wallpaperScale         = LGWidgetWallpaperScale();
        glass.updateGroup            = LGUpdateGroupWidgets;
        [view insertSubview:glass atIndex:0];
        objc_setAssociatedObject(view, kWidgetGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.cornerRadius = LGWidgetCornerRadius();
    glass.bezelWidth = LGWidgetBezelWidth();
    glass.glassThickness = LGWidgetGlassThickness();
    glass.refractionScale = LGWidgetRefractionScale();
    glass.refractiveIndex = LGWidgetRefractiveIndex();
    glass.specularOpacity = LGWidgetSpecularOpacity();
    glass.blur = LGWidgetBlur();
    glass.wallpaperScale = LGWidgetWallpaperScale();
    [glass updateOrigin];
    ensureWidgetTintOverlay(view);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) ensureWidgetTintOverlay(view);
    });
}

static void LGWidgetsRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            if (!LGIsWidgetMaterialView(view)) return;
            LGPrepareWidgetMaterialView(view);
            LGInjectIntoWidgetMaterialView(view);
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) refreshWindow(window);
    }
}

static void LGWidgetsPrefsChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGWidgetsRefreshAllHosts();
    });
}

%group LGWidgetsSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
        removeWidgetOverlays(self_);
        LGRestoreWidgetOriginalState(self_);
        if ([objc_getAssociatedObject(self_, kWidgetAttachedKey) boolValue]) {
            objc_setAssociatedObject(self_, kWidgetAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
            sWidgetCount = MAX(0, sWidgetCount - 1);
            if (sWidgetCount == 0) LGStopWidgetDisplayLink();
        }
        return;
    }

    if (!LGIsWidgetMaterialView(self_)) return;
    LGInjectIntoWidgetMaterialView(self_);
    if (![objc_getAssociatedObject(self_, kWidgetAttachedKey) boolValue]) {
        objc_setAssociatedObject(self_, kWidgetAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sWidgetCount++;
        LGStartWidgetDisplayLink();
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGIsWidgetMaterialView(self_)) return;
    if (!LGWidgetEnabled()) {
        removeWidgetOverlays(self_);
        LGRestoreWidgetOriginalState(self_);
        return;
    }
    ensureWidgetTintOverlay(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kWidgetGlassKey);
    [glass updateOrigin];
}

%end

%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (!LGViewBelongsToWidgetStack((UIView *)self)) return;
    if (!sWidgetLink) LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    if (!LGViewBelongsToWidgetStack((UIView *)self)) return;
    if (!sWidgetLink) LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGWidgetsPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGWidgetsSpringBoard);
}
