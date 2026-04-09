#import "Common.h"

static BOOL LGLockscreenQuickActionsEnabled(void) { return LGLockscreenEnabled() && LG_prefBool(@"LockscreenQuickActions.Enabled", YES); }
static CGFloat LGLockscreenQuickActionsBezelWidth(void) { return LG_prefFloat(@"LockscreenQuickActions.BezelWidth", 12.0); }
static CGFloat LGLockscreenQuickActionsGlassThickness(void) { return LG_prefFloat(@"LockscreenQuickActions.GlassThickness", 80.0); }
static CGFloat LGLockscreenQuickActionsRefractionScale(void) { return LG_prefFloat(@"LockscreenQuickActions.RefractionScale", 1.2); }
static CGFloat LGLockscreenQuickActionsRefractiveIndex(void) { return LG_prefFloat(@"LockscreenQuickActions.RefractiveIndex", 1.0); }
static CGFloat LGLockscreenQuickActionsSpecularOpacity(void) { return LG_prefFloat(@"LockscreenQuickActions.SpecularOpacity", 0.8); }
static CGFloat LGLockscreenQuickActionsBlur(void) { return LG_prefFloat(@"LockscreenQuickActions.Blur", 8.0); }
static CGFloat LGLockscreenQuickActionsWallpaperScale(void) { return LG_prefFloat(@"LockscreenQuickActions.WallpaperScale", 0.5); }
static CGFloat LGLockscreenQuickActionsLightTintAlpha(void) { return LG_prefFloat(@"LockscreenQuickActions.LightTintAlpha", 0.1); }
static CGFloat LGLockscreenQuickActionsDarkTintAlpha(void) { return LG_prefFloat(@"LockscreenQuickActions.DarkTintAlpha", 0.0); }

static void LGLockscreenQuickActionsResetHost(UIView *view) {
    LGCleanupLockscreenHost(view);
}

BOOL LGIsLockscreenQuickActionsHost(UIView *view) {
    if (![view isKindOfClass:[UIVisualEffectView class]]) return NO;
    if (!view.window) return NO;
    if (@available(iOS 11.0, *)) {
        if (view.window.safeAreaInsets.bottom <= 0.0f) return NO;
    }

    static Class quickActionsCls, effectCls;
    if (!quickActionsCls) quickActionsCls = NSClassFromString(@"CSQuickActionsButton");
    if (!effectCls) effectCls = [UIVisualEffectView class];

    UIView *ancestor = view.superview;
    while (ancestor) {
        if (quickActionsCls && [ancestor isKindOfClass:quickActionsCls]) return YES;
        if (effectCls && [ancestor isKindOfClass:effectCls]) return NO;
        ancestor = ancestor.superview;
    }
    return NO;
}

CGFloat LGLockscreenQuickActionsCornerRadius(UIView *view) {
    CGFloat configured = LG_prefFloat(@"LockscreenQuickActions.CornerRadius", 25.0);
    if (configured > 0.0f) return configured;
    return LGLockscreenResolvedCornerRadius(view, 25.0f);
}

static void LGLockscreenQuickActionsApplyIfNeeded(UIView *view) {
    if (!view.window || !LGLockscreenQuickActionsEnabled() || !LGIsLockscreenQuickActionsHost(view)) {
        LGLockscreenQuickActionsResetHost(view);
        return;
    }

    LGLockscreenInjectGlassWithSettings(view,
                                        LGLockscreenQuickActionsCornerRadius(view),
                                        LGLockscreenQuickActionsBezelWidth(),
                                        LGLockscreenQuickActionsGlassThickness(),
                                        LGLockscreenQuickActionsRefractionScale(),
                                        LGLockscreenQuickActionsRefractiveIndex(),
                                        LGLockscreenQuickActionsSpecularOpacity(),
                                        LGLockscreenQuickActionsBlur(),
                                        LGLockscreenQuickActionsWallpaperScale(),
                                        LGLockscreenQuickActionsLightTintAlpha(),
                                        LGLockscreenQuickActionsDarkTintAlpha());
    LGAttachLockHostIfNeeded(view);
}

%hook UIVisualEffectView

- (void)didMoveToWindow {
    %orig;
    LGLockscreenQuickActionsApplyIfNeeded((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGLockscreenQuickActionsApplyIfNeeded((UIView *)self);
}

%end
