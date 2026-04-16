#import "LGHookSupport.h"
#import "LGSharedSupport.h"
#import <objc/runtime.h>

BOOL LGHasAncestorClass(UIView *view, Class cls) {
    if (!view || !cls) return NO;
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([ancestor isKindOfClass:cls]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

BOOL LGHasAncestorClassNamed(UIView *view, NSString *className) {
    if (!view || !className.length) return NO;
    UIView *ancestor = view.superview;
    while (ancestor) {
        if ([NSStringFromClass(ancestor.class) isEqualToString:className]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

BOOL LGResponderChainContainsClassNamed(UIResponder *responder, NSString *className) {
    if (!className.length) return NO;
    UIResponder *current = responder;
    while (current) {
        if ([NSStringFromClass(current.class) isEqualToString:className]) return YES;
        current = current.nextResponder;
    }
    return NO;
}

void LGTraverseViews(UIView *root, void (^block)(UIView *view)) {
    if (!root || !block) return;
    block(root);
    for (UIView *subview in root.subviews) {
        LGTraverseViews(subview, block);
    }
}

UIColor *LGDefaultTintColorForView(UIView *view, CGFloat lightAlpha, CGFloat darkAlpha) {
    if (@available(iOS 12.0, *)) {
        UITraitCollection *traits = view.traitCollection ?: UIScreen.mainScreen.traitCollection;
        if (traits.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [UIColor colorWithWhite:0.0 alpha:darkAlpha];
        }
    }
    return [UIColor colorWithWhite:1.0 alpha:lightAlpha];
}

NSInteger LGPreferredFramesPerSecondForKey(NSString *key, NSInteger minFPS) {
    NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond > 0
        ? UIScreen.mainScreen.maximumFramesPerSecond
        : 60;
    NSInteger fallback = maxFPS >= 120 ? 120 : 60;
    NSInteger fps = LG_prefInteger(key, fallback);
    if (fps < minFPS) fps = minFPS;
    if (fps > maxFPS) fps = maxFPS;
    return fps;
}

UIView *LGEnsureTintOverlayView(UIView *host,
                                const void *associationKey,
                                NSInteger tag,
                                CGRect frame,
                                UIViewAutoresizing autoresizingMask) {
    if (!host || !associationKey) return nil;
    UIView *overlay = objc_getAssociatedObject(host, associationKey);
    if (!overlay) {
        overlay = [[UIView alloc] initWithFrame:frame];
        overlay.userInteractionEnabled = NO;
        overlay.tag = tag;
        overlay.autoresizingMask = autoresizingMask;
        [host addSubview:overlay];
        objc_setAssociatedObject(host, associationKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    overlay.frame = frame;
    return overlay;
}

void LGConfigureTintOverlayView(UIView *overlay,
                                UIColor *backgroundColor,
                                CGFloat cornerRadius,
                                CALayer *referenceLayer,
                                BOOL masksToBounds) {
    if (!overlay) return;
    overlay.backgroundColor = backgroundColor;
    overlay.hidden = (backgroundColor == nil);
    overlay.layer.cornerRadius = cornerRadius;
    overlay.layer.masksToBounds = masksToBounds;
    if (@available(iOS 13.0, *)) {
        if ([referenceLayer respondsToSelector:@selector(cornerCurve)]) {
            overlay.layer.cornerCurve = referenceLayer.cornerCurve;
        }
    }
}

void LGRemoveAssociatedSubview(UIView *host, const void *associationKey) {
    if (!host || !associationKey) return;
    UIView *view = objc_getAssociatedObject(host, associationKey);
    [view removeFromSuperview];
    objc_setAssociatedObject(host, associationKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

@interface LGDisplayLinkDriver : NSObject
@property (nonatomic, copy) dispatch_block_t tickBlock;
- (instancetype)initWithTickBlock:(dispatch_block_t)tickBlock;
- (void)tick:(CADisplayLink *)displayLink;
@end

@implementation LGDisplayLinkDriver

- (instancetype)initWithTickBlock:(dispatch_block_t)tickBlock {
    self = [super init];
    if (!self) return nil;
    _tickBlock = [tickBlock copy];
    return self;
}

- (void)tick:(__unused CADisplayLink *)displayLink {
    if (self.tickBlock) self.tickBlock();
}

@end

void LGStartDisplayLink(CADisplayLink *__strong *linkStorage,
                        id __strong *driverStorage,
                        NSInteger preferredFPS,
                        dispatch_block_t tickBlock) {
    LGAssertMainThread();
    if (!linkStorage || !driverStorage || *linkStorage) return;
    LGDisplayLinkDriver *driver = [[LGDisplayLinkDriver alloc] initWithTickBlock:tickBlock];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(tick:)];
    if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        link.preferredFramesPerSecond = preferredFPS;
    }
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    *driverStorage = driver;
    *linkStorage = link;
}

void LGStopDisplayLink(CADisplayLink *__strong *linkStorage,
                       id __strong *driverStorage) {
    LGAssertMainThread();
    if (!linkStorage || !*linkStorage) return;
    [*linkStorage invalidate];
    *linkStorage = nil;
    if (driverStorage) *driverStorage = nil;
}
