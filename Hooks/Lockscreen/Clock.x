#import "Common.h"
#import "../../Shared/LGHookSupport.h"
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static void *kLGClockOverlayKey = &kLGClockOverlayKey;
static void *kLGClockOriginalAlphaKey = &kLGClockOriginalAlphaKey;
static void *kLGClockOriginalLayerOpacityKey = &kLGClockOriginalLayerOpacityKey;
static void *kLGClockScrollObserverKey = &kLGClockScrollObserverKey;
static void *kLGClockScrollKVOContext = &kLGClockScrollKVOContext;

static void LGSetLayerTreeOpacity(CALayer *layer, float opacity) {
    if (!layer) return;
    layer.opacity = opacity;
    for (CALayer *sub in layer.sublayers) {
        LGSetLayerTreeOpacity(sub, opacity);
    }
}

static BOOL LGClockEnabled(void) {
    return LGLockscreenEnabled()
        && LGIsAtLeastiOS16()
        && LG_prefBool(@"Lockscreen.Clock.Enabled", NO);
}

static BOOL LGIsClockHost(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"CSProminentTimeView");
    return cls && [view isKindOfClass:cls];
}

static BOOL LGIsClockSourceLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"_UIAnimatingLabel"]
        && LGHasAncestorClassNamed(view, @"CSProminentTimeView");
}

static NSArray<UILabel *> *LGClockSourceLabelsForHost(UIView *host) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LGTraverseViews(host, ^(UIView *view) {
        if (LGIsClockSourceLabel(view))
            [labels addObject:(UILabel *)view];
    });
    return labels;
}

static UIImage *LGClockWallpaperSource(void) {
    UIImage *raw = LG_getRawLockscreenWallpaperImage();
    if (raw) return raw;
    return LGGetLockscreenSnapshotCached();
}

static UIScrollView *LGClockAncestorScrollView(UIView *view) {
    UIView *cursor = view.superview;
    while (cursor) {
        if ([cursor isKindOfClass:[UIScrollView class]])
            return (UIScrollView *)cursor;
        cursor = cursor.superview;
    }
    return nil;
}

@interface LGClockGlassView : UIView
@property (nonatomic, strong) LiquidGlassView *glassView;
@property (nonatomic, copy) NSString *displayText;
@property (nonatomic, copy) NSAttributedString *displayAttributedText;
@property (nonatomic, strong) UIFont *displayFont;
@property (nonatomic, assign) NSTextAlignment displayAlignment;
- (void)syncFromSourceLabel:(UILabel *)label;
@end

@interface LGClockScrollObserver : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) LGClockGlassView *overlay;
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, assign) BOOL observing;
- (instancetype)initWithScrollView:(UIScrollView *)scrollView
                              host:(UIView *)host
                           overlay:(LGClockGlassView *)overlay;
- (void)invalidate;
@end

@implementation LGClockGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;

    UIImage *wallpaper = LGClockWallpaperSource();
    CGPoint origin = LG_getLockscreenWallpaperOrigin();
    _glassView = [[LiquidGlassView alloc] initWithFrame:self.bounds wallpaper:wallpaper wallpaperOrigin:origin];
    _glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glassView.cornerRadius = 0.0;
    _glassView.bezelWidth = 24.0;
    _glassView.glassThickness = 150.0;
    _glassView.refractionScale = 1.5;
    _glassView.refractiveIndex = 1.5;
    _glassView.specularOpacity = 0.8;
    _glassView.blur = 3;
    _glassView.wallpaperScale = 1.0;
    _glassView.releasesWallpaperAfterUpload = YES;
    _glassView.updateGroup = LGUpdateGroupLockscreen;
    [self addSubview:_glassView];
    return self;
}

- (NSAttributedString *)lg_maskAttributedString {
    if (self.displayAttributedText.length > 0) {
        NSMutableAttributedString *copy = [self.displayAttributedText mutableCopy];
        [copy beginEditing];
        [copy enumerateAttribute:NSFontAttributeName
                         inRange:NSMakeRange(0, copy.length)
                         options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *font = [value isKindOfClass:[UIFont class]] ? (UIFont *)value : self.displayFont;
            if (!font) font = [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
            CTFontRef ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                              font.pointSize,
                                                              NULL);
            if (ctFont) {
                [copy removeAttribute:NSFontAttributeName range:range];
                [copy addAttribute:(__bridge NSString *)kCTFontAttributeName value:(__bridge id)ctFont range:range];
                CFRelease(ctFont);
            }
        }];
        [copy removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, copy.length)];
        [copy removeAttribute:(__bridge NSString *)kCTForegroundColorAttributeName range:NSMakeRange(0, copy.length)];
        [copy addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName
                     value:(id)UIColor.whiteColor.CGColor
                     range:NSMakeRange(0, copy.length)];
        [copy endEditing];
        return copy;
    }

    UIFont *font = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CTFontRef ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                      font.pointSize,
                                                      NULL);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)ctFont,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:self.displayText ?: @"" attributes:attrs];
    if (ctFont) CFRelease(ctFont);
    return string;
}

- (UIImage *)lg_maskImageForBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds) || self.displayText.length == 0 || !self.displayFont) return nil;

    CGFloat scale = UIScreen.mainScreen.scale ?: 1.0;
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    CGContextTranslateCTM(ctx, 0.0, bounds.size.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    NSAttributedString *attributed = [self lg_maskAttributedString];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

    CGFloat x = 0.0;
    switch (self.displayAlignment) {
        case NSTextAlignmentCenter:
            x = floor((bounds.size.width - width) * 0.5);
            break;
        case NSTextAlignmentRight:
            x = floor(bounds.size.width - width);
            break;
        default:
            x = 0.0;
            break;
    }
    CGFloat lineHeight = ascent + descent + leading;
    CGFloat baseline = floor((bounds.size.height - lineHeight) * 0.5 + descent);
    CGContextSetTextPosition(ctx, x, baseline);
    CTLineDraw(line, ctx);

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (line) CFRelease(line);
    return image;
}

- (void)lg_updateMask {
    UIImage *maskImage = [self lg_maskImageForBounds:self.bounds];
    if (!maskImage) {
        self.glassView.shapeMaskImage = nil;
        self.hidden = YES;
        return;
    }
    self.glassView.shapeMaskImage = maskImage;
    self.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glassView.frame = self.bounds;
    self.glassView.wallpaperImage = LGClockWallpaperSource();
    self.glassView.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
    [self.glassView updateOrigin];
    [self lg_updateMask];
}

- (void)syncFromSourceLabel:(UILabel *)label {
    if (!label) return;
    self.frame = label.frame;
    self.displayText = label.text ?: @"";
    self.displayAttributedText = label.attributedText;
    self.displayFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    self.displayAlignment = label.textAlignment;
    self.hidden = !self.displayText.length;
    [self setNeedsLayout];
}

@end

@implementation LGClockScrollObserver

- (instancetype)initWithScrollView:(UIScrollView *)scrollView
                              host:(UIView *)host
                           overlay:(LGClockGlassView *)overlay {
    self = [super init];
    if (!self) return nil;
    _scrollView = scrollView;
    _host = host;
    _overlay = overlay;
    if (scrollView) {
        [scrollView addObserver:self
                     forKeyPath:@"contentOffset"
                        options:NSKeyValueObservingOptionNew
                        context:kLGClockScrollKVOContext];
        [scrollView addObserver:self
                     forKeyPath:@"bounds"
                        options:NSKeyValueObservingOptionNew
                        context:kLGClockScrollKVOContext];
        _observing = YES;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (!_observing) return;
    UIScrollView *scrollView = _scrollView;
    _observing = NO;
    if (!scrollView) return;
    @try {
        [scrollView removeObserver:self forKeyPath:@"contentOffset" context:kLGClockScrollKVOContext];
        [scrollView removeObserver:self forKeyPath:@"bounds" context:kLGClockScrollKVOContext];
    } @catch (__unused NSException *exception) {
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != kLGClockScrollKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    UIView *host = self.host;
    LGClockGlassView *overlay = self.overlay;
    if (!host.window || !overlay || !overlay.superview) return;

    overlay.glassView.wallpaperImage = LGClockWallpaperSource();
    overlay.glassView.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
    [overlay.glassView updateOrigin];
    [overlay setNeedsLayout];
}

@end

static void LGRestoreClockSourceLabel(UILabel *label) {
    if (!label) return;
    NSNumber *originalAlpha = objc_getAssociatedObject(label, kLGClockOriginalAlphaKey);
    NSNumber *originalLayerOpacity = objc_getAssociatedObject(label, kLGClockOriginalLayerOpacityKey);
    label.alpha = originalAlpha ? originalAlpha.doubleValue : 1.0;
    label.layer.opacity = originalLayerOpacity ? originalLayerOpacity.floatValue : 1.0f;
    LGSetLayerTreeOpacity(label.layer, label.layer.opacity);
    objc_setAssociatedObject(label, kLGClockOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(label, kLGClockOriginalLayerOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGDetachClockScrollObserver(UIView *host) {
    LGClockScrollObserver *observer = objc_getAssociatedObject(host, kLGClockScrollObserverKey);
    [observer invalidate];
    objc_setAssociatedObject(host, kLGClockScrollObserverKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGEnsureClockScrollObserver(UIView *host, LGClockGlassView *overlay) {
    UIScrollView *scrollView = LGClockAncestorScrollView(host);
    LGClockScrollObserver *observer = objc_getAssociatedObject(host, kLGClockScrollObserverKey);
    if (observer && observer.scrollView == scrollView) {
        observer.overlay = overlay;
        return;
    }

    [observer invalidate];
    if (!scrollView) {
        objc_setAssociatedObject(host, kLGClockScrollObserverKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    observer = [[LGClockScrollObserver alloc] initWithScrollView:scrollView host:host overlay:overlay];
    objc_setAssociatedObject(host, kLGClockScrollObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGApplyClockReplacement(UIView *host) {
    if (!LGIsClockHost(host)) return;

    NSArray<UILabel *> *sourceLabels = LGClockSourceLabelsForHost(host);
    UILabel *sourceLabel = sourceLabels.firstObject;
    LGClockGlassView *overlay = objc_getAssociatedObject(host, kLGClockOverlayKey);

    if (!LGClockEnabled() || !host.window || !sourceLabel) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, kLGClockOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
        LGDetachClockScrollObserver(host);
        LGDetachLockHostIfNeeded(host);
        for (UILabel *label in sourceLabels) LGRestoreClockSourceLabel(label);
        return;
    }

    for (UILabel *label in sourceLabels) {
        if (!objc_getAssociatedObject(label, kLGClockOriginalAlphaKey)) {
            objc_setAssociatedObject(label, kLGClockOriginalAlphaKey, @(label.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(label, kLGClockOriginalLayerOpacityKey, @(label.layer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        label.alpha = 0.0;
        LGSetLayerTreeOpacity(label.layer, 0.0f);
    }

    if (!overlay) {
        overlay = [[LGClockGlassView alloc] initWithFrame:sourceLabel.frame];
        objc_setAssociatedObject(host, kLGClockOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:overlay];
    }

    LGAttachLockHostIfNeeded(host);
    LGEnsureClockScrollObserver(host, overlay);
    [overlay syncFromSourceLabel:sourceLabel];
    [host bringSubviewToFront:overlay];
}

static void LGRefreshClockHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            if (LGIsClockHost(view)) LGApplyClockReplacement(view);
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

%group LGClockSpringBoard

%hook CSProminentTimeView

- (void)didMoveToWindow {
    %orig;
    LGApplyClockReplacement((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyClockReplacement((UIView *)self);
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    %orig;
    if (LGIsClockSourceLabel((UIView *)self)) {
        UIView *host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
        if (host) LGApplyClockReplacement(host);
    }
}

- (void)setFont:(UIFont *)font {
    %orig;
    if (LGIsClockSourceLabel((UIView *)self)) {
        UIView *host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
        if (host) LGApplyClockReplacement(host);
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        dispatch_async(dispatch_get_main_queue(), ^{
            LGRefreshClockHosts();
        });
    });
    %init(LGClockSpringBoard);
}
