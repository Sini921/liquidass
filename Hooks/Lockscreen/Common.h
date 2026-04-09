#import "../../LiquidGlass.h"

BOOL LGLockscreenEnabled(void);
BOOL LGIsAtLeastiOS16(void);
CGFloat LGLockscreenCornerRadius(void);
UIImage *LGGetLockscreenSnapshotCached(void);
void LGInvalidateLockscreenSnapshotCache(void);
void LGRefreshLockSnapshotAfterDelay(NSTimeInterval delay);
void LGRemoveLockscreenGlass(UIView *host);
void LGCleanupLockscreenHost(UIView *host);
CGFloat LGLockscreenResolvedCornerRadius(UIView *view, CGFloat fallback);
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
                                         CGFloat darkTintAlpha);
void LGLockscreenInjectGlass(UIView *host, CGFloat cornerRadius);
void LGAttachLockHostIfNeeded(UIView *view);
void LGDetachLockHostIfNeeded(UIView *view);
void LGLockscreenRefreshAllHosts(void);
