#import "../LiquidGlass.h"
#import <objc/runtime.h>

static const NSInteger kAppIconTintTag = 0xA110;

static void *kAppIconRetryKey = &kAppIconRetryKey;
static void *kAppIconGlassKey = &kAppIconGlassKey;
static void *kAppIconTintKey = &kAppIconTintKey;
static void *kAppIconOriginalTransformKey = &kAppIconOriginalTransformKey;
static void *kAppIconLastGlassFrameKey = &kAppIconLastGlassFrameKey;
static const CGFloat kAppIconImageScale = 0.99;

static BOOL LGAppIconsEnabled(void) { return LG_globalEnabled() && LG_prefBool(@"AppIcons.Enabled", NO); }
static CGFloat LGAppIconCornerRadius(void) { return LG_prefFloat(@"AppIcons.CornerRadius", 13.5); }
static CGFloat LGAppIconBezelWidth(void) { return LG_prefFloat(@"AppIcons.BezelWidth", 14.0); }
static CGFloat LGAppIconGlassThickness(void) { return LG_prefFloat(@"AppIcons.GlassThickness", 80.0); }
static CGFloat LGAppIconRefractionScale(void) { return LG_prefFloat(@"AppIcons.RefractionScale", 1.2); }
static CGFloat LGAppIconRefractiveIndex(void) { return LG_prefFloat(@"AppIcons.RefractiveIndex", 1.0); }
static CGFloat LGAppIconSpecularOpacity(void) { return LG_prefFloat(@"AppIcons.SpecularOpacity", 0.8); }
static CGFloat LGAppIconBlur(void) { return LG_prefFloat(@"AppIcons.Blur", 8.0); }
static CGFloat LGAppIconWallpaperScale(void) { return LG_prefFloat(@"AppIcons.WallpaperScale", 0.5); }
static CGFloat LGAppIconLightTintAlpha(void) { return LG_prefFloat(@"AppIcons.LightTintAlpha", 0.1); }
static CGFloat LGAppIconDarkTintAlpha(void) { return LG_prefFloat(@"AppIcons.DarkTintAlpha", 0.0); }

static BOOL LGIsHomescreenIconImageView(UIView *view) {
    if (!view.window) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"SBIconImageView"]) return NO;

    UIView *parent = view.superview;
    UIView *grandparent = parent.superview;
    if (!parent || !grandparent) return NO;
    if (![NSStringFromClass(parent.class) isEqualToString:@"SBFTouchPassThroughView"]) return NO;
    if (![NSStringFromClass(grandparent.class) isEqualToString:@"SBIconView"]) return NO;
    return YES;
}

static UIView *LGAppIconHostView(UIView *view) {
    UIView *host = view.superview;
    return host ?: view;
}

static CGRect LGAppIconGlassFrameInHost(UIView *iconView, UIView *host) {
    if (!iconView || !host) return CGRectZero;
    return [iconView convertRect:iconView.bounds toView:host];
}

static UIColor *appIconTintColorForView(UIView *view) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
            return [UIColor colorWithWhite:0.0 alpha:LGAppIconDarkTintAlpha()];
    }
    return [UIColor colorWithWhite:1.0 alpha:LGAppIconLightTintAlpha()];
}

static void removeAppIconOverlays(UIView *view) {
    UIView *host = LGAppIconHostView(view);
    UIView *tint = objc_getAssociatedObject(host, kAppIconTintKey);
    if (tint) [tint removeFromSuperview];
    objc_setAssociatedObject(host, kAppIconTintKey, nil, OBJC_ASSOCIATION_ASSIGN);

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kAppIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);

    NSValue *originalTransform = objc_getAssociatedObject(view, kAppIconOriginalTransformKey);
    if (originalTransform) {
        view.transform = originalTransform.CGAffineTransformValue;
    } else {
        view.transform = CGAffineTransformIdentity;
    }
}

static void ensureAppIconTintOverlay(UIView *view) {
    UIView *host = LGAppIconHostView(view);
    CGRect frame = LGAppIconGlassFrameInHost(view, host);
    UIView *tint = objc_getAssociatedObject(host, kAppIconTintKey);
    if (!tint) {
        tint = [[UIView alloc] initWithFrame:frame];
        tint.tag = kAppIconTintTag;
        tint.userInteractionEnabled = NO;
        [host insertSubview:tint atIndex:0];
        objc_setAssociatedObject(host, kAppIconTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tint.frame = frame;
    tint.backgroundColor = appIconTintColorForView(view);
    tint.layer.cornerRadius = LGAppIconCornerRadius();
    if (@available(iOS 13.0, *))
        tint.layer.cornerCurve = kCACornerCurveContinuous;
    [host insertSubview:tint aboveSubview:objc_getAssociatedObject(host, kAppIconGlassKey)];
}

static void injectIntoAppIcon(UIView *view) {
    if (!LGAppIconsEnabled()) {
        removeAppIconOverlays(view);
        return;
    }

    UIView *host = LGAppIconHostView(view);
    CGRect frame = LGAppIconGlassFrameInHost(view, host);
    if (CGRectIsEmpty(frame)) return;

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper) {
        if ([objc_getAssociatedObject(host, kAppIconRetryKey) boolValue]) return;
        objc_setAssociatedObject(host, kAppIconRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoAppIcon(view);
        });
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:frame
                                             wallpaper:wallpaper
                                       wallpaperOrigin:wallpaperOrigin];
        glass.cornerRadius = LGAppIconCornerRadius();
        glass.bezelWidth = LGAppIconBezelWidth();
        glass.glassThickness = LGAppIconGlassThickness();
        glass.refractionScale = LGAppIconRefractionScale();
        glass.refractiveIndex = LGAppIconRefractiveIndex();
        glass.specularOpacity = LGAppIconSpecularOpacity();
        glass.blur = LGAppIconBlur();
        glass.wallpaperScale = LGAppIconWallpaperScale();
        glass.updateGroup = LGUpdateGroupAppIcons;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kAppIconGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!objc_getAssociatedObject(view, kAppIconOriginalTransformKey)) {
        objc_setAssociatedObject(view, kAppIconOriginalTransformKey,
                                 [NSValue valueWithCGAffineTransform:view.transform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.transform = CGAffineTransformMakeScale(kAppIconImageScale, kAppIconImageScale);

    glass.frame = frame;
    glass.cornerRadius = LGAppIconCornerRadius();
    glass.bezelWidth = LGAppIconBezelWidth();
    glass.glassThickness = LGAppIconGlassThickness();
    glass.refractionScale = LGAppIconRefractionScale();
    glass.refractiveIndex = LGAppIconRefractiveIndex();
    glass.specularOpacity = LGAppIconSpecularOpacity();
    glass.blur = LGAppIconBlur();
    glass.wallpaperScale = LGAppIconWallpaperScale();
    [glass updateOrigin];
    objc_setAssociatedObject(host, kAppIconLastGlassFrameKey,
                             [NSValue valueWithCGRect:frame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ensureAppIconTintOverlay(view);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) ensureAppIconTintOverlay(view);
    });
    objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

%hook SBIconImageView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        removeAppIconOverlays(self_);
        return;
    }
    if (!LGIsHomescreenIconImageView(self_)) return;
    injectIntoAppIcon(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGIsHomescreenIconImageView(self_)) return;
    if (!LGAppIconsEnabled()) {
        removeAppIconOverlays(self_);
        return;
    }
    ensureAppIconTintOverlay(self_);
    if (!objc_getAssociatedObject(self_, kAppIconOriginalTransformKey)) {
        objc_setAssociatedObject(self_, kAppIconOriginalTransformKey,
                                 [NSValue valueWithCGAffineTransform:self_.transform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self_.transform = CGAffineTransformMakeScale(kAppIconImageScale, kAppIconImageScale);
    UIView *host = LGAppIconHostView(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (!glass) {
        injectIntoAppIcon(self_);
        return;
    }
    CGRect frame = LGAppIconGlassFrameInHost(self_, host);
    if (CGRectIsEmpty(frame)) return;
    glass.frame = frame;
    glass.cornerRadius = LGAppIconCornerRadius();
    glass.bezelWidth = LGAppIconBezelWidth();
    glass.glassThickness = LGAppIconGlassThickness();
    glass.refractionScale = LGAppIconRefractionScale();
    glass.refractiveIndex = LGAppIconRefractiveIndex();
    glass.specularOpacity = LGAppIconSpecularOpacity();
    glass.blur = LGAppIconBlur();
    glass.wallpaperScale = LGAppIconWallpaperScale();
    CGRect lastFrame = [objc_getAssociatedObject(host, kAppIconLastGlassFrameKey) CGRectValue];
    if (!CGRectEqualToRect(lastFrame, frame)) {
        [glass updateOrigin];
        objc_setAssociatedObject(host, kAppIconLastGlassFrameKey,
                                 [NSValue valueWithCGRect:frame],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook SBIconScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    LG_updateRegisteredGlassViews(LGUpdateGroupAppIcons);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    LG_updateRegisteredGlassViews(LGUpdateGroupAppIcons);
}

%end
