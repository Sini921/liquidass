#import "LGBannerCaptureSupport.h"
#import "../LiquidGlass.h"
#import "../Runtime/LGSnapshotCaptureSupport.h"
#import "LGSharedSupport.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

void LGLog(NSString *format, ...);

@interface LGLiveBackdropCaptureView : UIView
@end

@implementation LGLiveBackdropCaptureView

+ (Class)layerClass {
    return NSClassFromString(@"CABackdropLayer") ?: [CALayer class];
}

- (void)lg_configureBackdropLayerIfNeeded {
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    CALayer *layer = self.layer;
    if (!backdropCls || ![layer isKindOfClass:backdropCls]) return;
    @try {
        [layer setValue:@NO forKey:@"layerUsesCoreImageFilters"];
        [layer setValue:@YES forKey:@"windowServerAware"];
        [layer setValue:NSUUID.UUID.UUIDString forKey:@"groupName"];
    } @catch (__unused NSException *exception) {
        LGLog(@"banner backdrop layer configuration failed");
    }
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    [self lg_configureBackdropLayerIfNeeded];
    return self;
}

@end

void LGRemoveLiveBackdropCaptureView(UIView *host, const void *associationKey) {
    LGAssertMainThread();
    if (!host || !associationKey) return;
    UIView *backdropView = objc_getAssociatedObject(host, associationKey);
    [backdropView removeFromSuperview];
    objc_setAssociatedObject(host, associationKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

BOOL LGCaptureLiveBackdropTextureForHost(UIView *host,
                                         LiquidGlassView *glass,
                                         const void *associationKey,
                                         CGPoint *outOrigin,
                                         CGSize *outSamplingResolution) {
    LGAssertMainThread();
    UIView *superview = host.superview;
    if (!host || !superview || !host.window || !glass || !associationKey) return NO;

    CALayer *hostLayer = host.layer.presentationLayer ?: host.layer;
    CGRect hostFrame = [hostLayer convertRect:hostLayer.bounds toLayer:superview.layer];
    CGSize captureSize = hostFrame.size;
    CGPoint captureOrigin = hostFrame.origin;
    if (!isfinite(captureSize.width) || !isfinite(captureSize.height) ||
        !isfinite(captureOrigin.x) || !isfinite(captureOrigin.y) ||
        captureSize.width <= 1.0f || captureSize.height <= 1.0f) {
        return NO;
    }

    CGRect captureRect = (CGRect){ captureOrigin, captureSize };
    CGRect captureRectInScreen = [superview convertRect:captureRect toView:nil];
    if (!isfinite(CGRectGetMinX(captureRectInScreen)) ||
        !isfinite(CGRectGetMinY(captureRectInScreen)) ||
        !isfinite(CGRectGetWidth(captureRectInScreen)) ||
        !isfinite(CGRectGetHeight(captureRectInScreen)) ||
        CGRectGetWidth(captureRectInScreen) <= 1.0f ||
        CGRectGetHeight(captureRectInScreen) <= 1.0f) {
        return NO;
    }
    LGLiveBackdropCaptureView *backdropView = objc_getAssociatedObject(host, associationKey);
    if (!backdropView) {
        backdropView = [[LGLiveBackdropCaptureView alloc] initWithFrame:captureRect];
        objc_setAssociatedObject(host, associationKey, backdropView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    backdropView.frame = captureRect;
    if (backdropView.superview != superview) {
        [superview insertSubview:backdropView belowSubview:host];
    } else {
        NSInteger hostIndex = [superview.subviews indexOfObjectIdenticalTo:host];
        NSInteger backdropIndex = [superview.subviews indexOfObjectIdenticalTo:backdropView];
        if (hostIndex != NSNotFound && backdropIndex != NSNotFound && backdropIndex >= hostIndex) {
            [superview insertSubview:backdropView belowSubview:host];
        }
    }

    CGFloat screenScale = host.window.screen.scale ?: UIScreen.mainScreen.scale ?: 2.0f;
    CGFloat captureScale = MAX(0.7f, MIN(screenScale, screenScale * 0.5f));
    size_t pixelWidth = MAX((size_t)1, (size_t)lrint(CGRectGetWidth(captureRect) * captureScale));
    size_t pixelHeight = MAX((size_t)1, (size_t)lrint(CGRectGetHeight(captureRect) * captureScale));

    __block BOOL ok = NO;
    [glass updateWallpaperTextureWithPixelWidth:pixelWidth
                                         height:pixelHeight
                                 sourcePixelSize:CGSizeMake((CGFloat)pixelWidth, (CGFloat)pixelHeight)
                                        actions:^(CGContextRef ctx) {
        CGContextSaveGState(ctx);
        CGContextTranslateCTM(ctx, 0.0f, (CGFloat)pixelHeight);
        CGContextScaleCTM(ctx, captureScale, -captureScale);
        UIGraphicsPushContext(ctx);
        ok = LGDrawViewHierarchyIntoCurrentContext(backdropView, backdropView.bounds, NO);
        UIGraphicsPopContext();
        CGContextRestoreGState(ctx);
    }];
    if (!ok) return NO;

    if (outOrigin) *outOrigin = captureRectInScreen.origin;
    if (outSamplingResolution) {
        *outSamplingResolution = CGSizeMake(CGRectGetWidth(captureRectInScreen) * screenScale,
                                            CGRectGetHeight(captureRectInScreen) * screenScale);
    }
    return YES;
}
