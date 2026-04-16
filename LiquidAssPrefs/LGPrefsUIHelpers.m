#import "LGPrefsUIHelpers.h"
#import "LGPrefsDataSupport.h"
#import "../Shared/LGSharedSupport.h"
#import <notify.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

void * const kLGDefaultValueKey = (void *)&kLGDefaultValueKey;
void * const kLGValueLabelKey = (void *)&kLGValueLabelKey;
void * const kLGDecimalsKey = (void *)&kLGDecimalsKey;
void * const kLGSliderAnimatorKey = (void *)&kLGSliderAnimatorKey;
void * const kLGSliderKey = (void *)&kLGSliderKey;
void * const kLGPreferenceKeyKey = (void *)&kLGPreferenceKeyKey;
void * const kLGMinValueKey = (void *)&kLGMinValueKey;
void * const kLGMaxValueKey = (void *)&kLGMaxValueKey;
void * const kLGControlTitleKey = (void *)&kLGControlTitleKey;
void * const kLGControlSubtitleKey = (void *)&kLGControlSubtitleKey;
void * const kLGControlledByEnabledKey = (void *)&kLGControlledByEnabledKey;

@interface LGTopFadeView : UIView
@end

@interface LGSliderResetAnimator : NSObject
@property (nonatomic, weak) UISlider *slider;
@property (nonatomic, weak) UILabel *valueLabel;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) CGFloat startValue;
@property (nonatomic, assign) CGFloat targetValue;
@property (nonatomic, assign) NSInteger decimals;
@end

@implementation LGSliderResetAnimator

- (void)tick:(CADisplayLink *)link {
    if (!self.slider) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }
    CFTimeInterval elapsed = CACurrentMediaTime() - self.startTime;
    CGFloat t = MIN(MAX(elapsed / 0.42, 0.0), 1.0);
    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);
    CGFloat value = self.startValue + ((self.targetValue - self.startValue) * eased);
    self.slider.value = value;
    if (self.valueLabel) {
        self.valueLabel.text = LGFormatSliderValue(value, self.decimals);
    }
    if (t >= 1.0) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        objc_setAssociatedObject(self.slider, kLGSliderAnimatorKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

@end

@interface LGPrefsSpringBackButton : UIButton
@property (nonatomic, weak) UIView *animatedView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval lastTimestamp;
@property (nonatomic, assign) CGFloat springValue;
@property (nonatomic, assign) CGFloat springTarget;
@property (nonatomic, assign) CGFloat springVelocity;
@end

@implementation LGPrefsSpringBackButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _springValue = 1.0;
    _springTarget = 1.0;
    _springVelocity = 0.0;
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (void)setHighlighted:(BOOL)highlighted {
    BOOL changed = (self.highlighted != highlighted);
    [super setHighlighted:highlighted];
    if (!changed) return;
    self.springTarget = highlighted ? 0.82 : 1.0;
    [self lg_startSpringIfNeeded];
}

- (void)lg_startSpringIfNeeded {
    if (self.displayLink) return;
    self.lastTimestamp = 0.0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(lg_tick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)lg_tick:(CADisplayLink *)link {
    UIView *targetView = self.animatedView ?: self;
    if (!targetView.superview) {
        [self.displayLink invalidate];
        self.displayLink = nil;
        return;
    }

    if (self.lastTimestamp <= 0.0) {
        self.lastTimestamp = link.timestamp;
        return;
    }

    CFTimeInterval dt = MIN(MAX(link.timestamp - self.lastTimestamp, 1.0 / 240.0), 1.0 / 30.0);
    self.lastTimestamp = link.timestamp;

    CGFloat stiffness = 340.0;
    CGFloat damping = 14.0;
    CGFloat force = (self.springTarget - self.springValue) * stiffness;
    CGFloat dampingForce = self.springVelocity * damping;
    self.springVelocity += (force - dampingForce) * dt;
    self.springValue += self.springVelocity * dt;

    if (fabs(self.springTarget - self.springValue) < 0.0005 &&
        fabs(self.springVelocity) < 0.001) {
        self.springValue = self.springTarget;
        self.springVelocity = 0.0;
    }

    targetView.transform = CGAffineTransformMakeScale(self.springValue, self.springValue);

    if (self.springValue == self.springTarget && self.springVelocity == 0.0) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
}

@end

static UIView *LGMakeRespringBar(id target, SEL respringAction, SEL laterAction);
static NSNumber *LGParseLocalizedDecimalString(NSString *rawText);
static void LGDismissOverlayPanel(UIView *overlay, UIView *panel);

void LGApplyNavigationBarAppearance(UINavigationItem *navigationItem) {
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.shadowColor = UIColor.clearColor;
    navigationItem.standardAppearance = appearance;
    navigationItem.scrollEdgeAppearance = appearance;
    navigationItem.compactAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        navigationItem.compactScrollEdgeAppearance = appearance;
    }
}

void LGInstallScrollableStack(UIViewController *controller,
                              CGFloat topInset,
                              CGFloat stackSpacing,
                              UIScrollView *__strong *scrollViewOut,
                              UIStackView *__strong *stackViewOut) {
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:controller.view.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:scrollView];

    LGTopFadeView *fadeView = [[LGTopFadeView alloc] initWithFrame:CGRectZero];
    fadeView.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:fadeView];

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.axis = UILayoutConstraintAxisVertical;
    stackView.spacing = stackSpacing;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;
    [scrollView addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:topInset],
        [stackView.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16.0],
        [stackView.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16.0],
        [stackView.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-112.0],
        [fadeView.topAnchor constraintEqualToAnchor:controller.view.topAnchor],
        [fadeView.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor],
        [fadeView.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor],
        [fadeView.heightAnchor constraintEqualToConstant:150.0],
    ]];

    if (scrollViewOut) *scrollViewOut = scrollView;
    if (stackViewOut) *stackViewOut = stackView;
}

void LGInstallBottomRespringBar(UIViewController *controller, UIView *__strong *respringBarOut) {
    UIView *respringBar = LGMakeRespringBar(controller, @selector(handleRespringPressed), @selector(handleLaterPressed));
    [controller.view addSubview:respringBar];
    UILayoutGuide *guide = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [respringBar.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [respringBar.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [respringBar.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor constant:-12.0],
    ]];
    if (respringBarOut) *respringBarOut = respringBar;
}

void LGPresentSliderValuePrompt(UIViewController *controller, UILabel *valueLabel) {
    if (![valueLabel isKindOfClass:[UILabel class]]) return;

    UISlider *slider = objc_getAssociatedObject(valueLabel, kLGSliderKey);
    NSString *preferenceKey = objc_getAssociatedObject(valueLabel, kLGPreferenceKeyKey);
    NSNumber *minNumber = objc_getAssociatedObject(valueLabel, kLGMinValueKey);
    NSNumber *maxNumber = objc_getAssociatedObject(valueLabel, kLGMaxValueKey);
    NSNumber *decimalsNumber = objc_getAssociatedObject(valueLabel, kLGDecimalsKey);
    NSString *controlTitle = objc_getAssociatedObject(valueLabel, kLGControlTitleKey);
    if (!slider || !preferenceKey.length || !minNumber || !maxNumber || !decimalsNumber) return;

    NSInteger decimals = decimalsNumber.integerValue;
    CGFloat minValue = minNumber.doubleValue;
    CGFloat maxValue = maxNumber.doubleValue;
    NSString *message = [NSString stringWithFormat:LGLocalized(@"prefs.value_prompt.message"),
                         LGFormatSliderValue(minValue, decimals),
                         LGFormatSliderValue(maxValue, decimals)];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(controlTitle.length ? controlTitle : LGLocalized(@"prefs.value_prompt.title"))
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.keyboardType = UIKeyboardTypeDecimalPad;
        textField.placeholder = LGFormatSliderValue(slider.value, decimals);
        textField.text = LGFormatSliderValue(slider.value, decimals);
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:LGLocalized(@"prefs.button.cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LGLocalized(@"prefs.button.apply")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction * _Nonnull action) {
        UITextField *textField = alert.textFields.firstObject;
        NSNumber *parsedNumber = LGParseLocalizedDecimalString(textField.text ?: @"");
        if (!parsedNumber) return;

        CGFloat value = MIN(MAX(parsedNumber.doubleValue, minValue), maxValue);
        slider.value = value;
        valueLabel.text = LGFormatSliderValue(value, decimals);
        LGWritePreference(preferenceKey, @(value));
    }]];

    [controller presentViewController:alert animated:YES completion:nil];
}

void LGAnimateSliderToDefault(UISlider *slider, CGFloat targetValue, UILabel *valueLabel, NSInteger decimals) {
    LGSliderResetAnimator *existing = objc_getAssociatedObject(slider, kLGSliderAnimatorKey);
    if (existing.displayLink) {
        [existing.displayLink invalidate];
        existing.displayLink = nil;
    }

    LGSliderResetAnimator *animator = [LGSliderResetAnimator new];
    animator.slider = slider;
    animator.valueLabel = valueLabel;
    animator.startValue = slider.value;
    animator.targetValue = targetValue;
    animator.decimals = decimals;
    animator.startTime = CACurrentMediaTime();
    animator.displayLink = [CADisplayLink displayLinkWithTarget:animator selector:@selector(tick:)];
    [animator.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(slider, kLGSliderAnimatorKey, animator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UIView *LGMakeNavCardGlyphView(NSString *symbolName, UIColor *tintColor) {
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.widthAnchor constraintEqualToConstant:20.0],
        [container.heightAnchor constraintEqualToConstant:20.0],
    ]];

    if ([symbolName isEqualToString:@"lg.lockscreen.stacked"]) {
        UIImageSymbolConfiguration *phoneConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
        UIImageView *phoneGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"iphone" withConfiguration:phoneConfig]];
        phoneGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        phoneGlyph.tintColor = tintColor;
        phoneGlyph.contentMode = UIViewContentModeScaleAspectFit;

        UIView *lockBadge = [[UIView alloc] initWithFrame:CGRectZero];
        lockBadge.translatesAutoresizingMaskIntoConstraints = NO;
        lockBadge.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        lockBadge.layer.cornerRadius = 7.0;
        lockBadge.layer.cornerCurve = kCACornerCurveContinuous;

        UIImageSymbolConfiguration *lockConfig =
            [UIImageSymbolConfiguration configurationWithPointSize:8.0 weight:UIImageSymbolWeightBold];
        UIImageView *lockGlyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock.fill" withConfiguration:lockConfig]];
        lockGlyph.translatesAutoresizingMaskIntoConstraints = NO;
        lockGlyph.tintColor = tintColor;
        lockGlyph.contentMode = UIViewContentModeScaleAspectFit;

        [container addSubview:phoneGlyph];
        [container addSubview:lockBadge];
        [lockBadge addSubview:lockGlyph];
        [NSLayoutConstraint activateConstraints:@[
            [phoneGlyph.centerXAnchor constraintEqualToAnchor:container.centerXAnchor constant:-1.0],
            [phoneGlyph.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [phoneGlyph.widthAnchor constraintEqualToConstant:15.0],
            [phoneGlyph.heightAnchor constraintEqualToConstant:15.0],
            [lockBadge.widthAnchor constraintEqualToConstant:14.0],
            [lockBadge.heightAnchor constraintEqualToConstant:14.0],
            [lockBadge.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [lockBadge.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
            [lockGlyph.centerXAnchor constraintEqualToAnchor:lockBadge.centerXAnchor],
            [lockGlyph.centerYAnchor constraintEqualToAnchor:lockBadge.centerYAnchor],
        ]];
        return container;
    }

    UIImageSymbolConfiguration *symbolConfig =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:symbolConfig]];
    glyph.translatesAutoresizingMaskIntoConstraints = NO;
    glyph.tintColor = tintColor;
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    [container addSubview:glyph];
    [NSLayoutConstraint activateConstraints:@[
        [glyph.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [glyph.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    ]];
    return container;
}

UIColor *LGSubpageCardBackgroundColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.07];
        }
        return [[UIColor whiteColor] colorWithAlphaComponent:0.76];
    }];
}

UIView *LGMakeSectionDivider(void) {
    UIView *divider = [[UIView alloc] initWithFrame:CGRectZero];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.08];
    }];
    divider.layer.cornerRadius = 0.5;
    [NSLayoutConstraint activateConstraints:@[
        [divider.heightAnchor constraintEqualToConstant:1.0]
    ]];
    return divider;
}

UIBarButtonItem *LGMakeCircularBackItem(id target, SEL action) {
    LGPrefsSpringBackButton *button = [LGPrefsSpringBackButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:@"chevron.left" withConfiguration:config];
    [button setImage:image forState:UIControlStateNormal];
    [button setTintColor:[UIColor labelColor]];
    button.imageView.contentMode = UIViewContentModeCenter;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 38, 38)];
    UIVisualEffectView *blurView =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 19.0;
    blurView.layer.cornerCurve = kCACornerCurveContinuous;
    blurView.layer.masksToBounds = YES;
    blurView.layer.borderWidth = 0.75;
    blurView.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.22].CGColor;
    [container addSubview:blurView];
    [blurView.contentView addSubview:button];
    button.animatedView = container;
    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:container.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [button.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor],
        [button.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor],
        [button.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor],
        [button.widthAnchor constraintEqualToConstant:38.0],
        [button.heightAnchor constraintEqualToConstant:38.0],
    ]];
    return [[UIBarButtonItem alloc] initWithCustomView:container];
}

UIBarButtonItem *LGMakeResetTextItem(id target, SEL action) {
    return [[UIBarButtonItem alloc] initWithTitle:LGLocalized(@"prefs.button.reset")
                                            style:UIBarButtonItemStylePlain
                                           target:target
                                           action:action];
}

@implementation LGTopFadeView {
    CAGradientLayer *_gradientLayer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0.5, 0.0);
    _gradientLayer.endPoint = CGPointMake(0.5, 1.0);
    [self.layer addSublayer:_gradientLayer];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _gradientLayer.frame = self.bounds;
    UIColor *baseColor = [UIColor systemBackgroundColor];
    _gradientLayer.colors = @[
        (__bridge id)[baseColor colorWithAlphaComponent:0.98].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.55].CGColor,
        (__bridge id)[baseColor colorWithAlphaComponent:0.0].CGColor
    ];
    _gradientLayer.locations = @[ @0.0, @0.45, @1.0 ];
}

@end

static NSNumber *LGParseLocalizedDecimalString(NSString *rawText) {
    NSString *trimmed = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return nil;

    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.locale = [NSLocale currentLocale];
    NSNumber *parsedNumber = [formatter numberFromString:trimmed];
    if (parsedNumber) return parsedNumber;

    NSString *normalized = [trimmed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    return @([normalized doubleValue]);
}

static void LGDismissOverlayPanel(UIView *overlay, UIView *panel) {
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 0.0;
        panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

void LGPresentResetConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1ACE];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1ACE;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.reset_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.reset_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [cancelButton setTitle:LGLocalized(@"prefs.button.cancel") forState:UIControlStateNormal];
    [cancelButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    cancelButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    cancelButton.backgroundColor = [UIColor systemBlueColor];
    cancelButton.layer.cornerRadius = 23.0;
    cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    cancelButton.layer.masksToBounds = YES;

    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [resetButton setTitle:LGLocalized(@"prefs.button.reset") forState:UIControlStateNormal];
    [resetButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    resetButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    resetButton.backgroundColor = [UIColor tertiarySystemFillColor];
    resetButton.layer.cornerRadius = 23.0;
    resetButton.layer.cornerCurve = kCACornerCurveContinuous;
    resetButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[cancelButton, resetButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [cancelButton.heightAnchor constraintEqualToConstant:46.0],
        [resetButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [cancelButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [resetButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGResetAllPreferences();
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentRespringConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1ACF];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1ACF;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.respring_confirm.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.respring_confirm.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor tertiarySystemFillColor];
    laterButton.layer.cornerRadius = 23.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    laterButton.layer.masksToBounds = YES;

    UIButton *respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    respringButton.translatesAutoresizingMaskIntoConstraints = NO;
    [respringButton setTitle:LGLocalized(@"prefs.button.respring") forState:UIControlStateNormal];
    [respringButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    respringButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    respringButton.backgroundColor = [UIColor systemBlueColor];
    respringButton.layer.cornerRadius = 23.0;
    respringButton.layer.cornerCurve = kCACornerCurveContinuous;
    respringButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[laterButton, respringButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [laterButton.heightAnchor constraintEqualToConstant:46.0],
        [respringButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [laterButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [respringButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGSetNeedsRespring(NO);
        notify_post(LGPrefsRespringNotificationCString);
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentReopenSettingsConfirmation(UIViewController *controller) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD2];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD2;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.reopen_settings.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = LGLocalized(@"prefs.reopen_settings.body");
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor tertiarySystemFillColor];
    laterButton.layer.cornerRadius = 23.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    laterButton.layer.masksToBounds = YES;

    UIButton *reopenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    reopenButton.translatesAutoresizingMaskIntoConstraints = NO;
    [reopenButton setTitle:LGLocalized(@"prefs.button.reopen_settings") forState:UIControlStateNormal];
    [reopenButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    reopenButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    reopenButton.backgroundColor = [UIColor systemBlueColor];
    reopenButton.layer.cornerRadius = 23.0;
    reopenButton.layer.cornerCurve = kCACornerCurveContinuous;
    reopenButton.layer.masksToBounds = YES;

    UIStackView *buttonRow = [[UIStackView alloc] initWithArrangedSubviews:@[laterButton, reopenButton]];
    buttonRow.translatesAutoresizingMaskIntoConstraints = NO;
    buttonRow.axis = UILayoutConstraintAxisHorizontal;
    buttonRow.spacing = 12.0;
    buttonRow.distribution = UIStackViewDistributionFillEqually;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:buttonRow];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [buttonRow.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [buttonRow.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [buttonRow.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [buttonRow.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [laterButton.heightAnchor constraintEqualToConstant:46.0],
        [reopenButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [laterButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [reopenButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message) {
    if (!controller.view.window) return;
    UIView *existing = [controller.view viewWithTag:0x1AD0];
    if (existing) [existing removeFromSuperview];

    UIView *overlay = [[UIView alloc] initWithFrame:controller.view.bounds];
    overlay.tag = 0x1AD0;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.24];
    overlay.alpha = 0.0;

    UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
    dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addSubview:dismissControl];

    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.layer.cornerRadius = 32.0;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    panel.transform = CGAffineTransformMakeScale(0.96, 0.96);

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title.length ? title : LGLocalized(@"prefs.info.title");
    titleLabel.font = [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
    titleLabel.numberOfLines = 0;

    UILabel *bodyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    bodyLabel.text = message.length ? message : @"";
    bodyLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    bodyLabel.textColor = [UIColor secondaryLabelColor];
    bodyLabel.numberOfLines = 0;

    UIButton *okButton = [UIButton buttonWithType:UIButtonTypeSystem];
    okButton.translatesAutoresizingMaskIntoConstraints = NO;
    [okButton setTitle:LGLocalized(@"prefs.button.ok") forState:UIControlStateNormal];
    [okButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    okButton.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    okButton.backgroundColor = [UIColor systemBlueColor];
    okButton.layer.cornerRadius = 23.0;
    okButton.layer.cornerCurve = kCACornerCurveContinuous;
    okButton.layer.masksToBounds = YES;

    [overlay addSubview:panel];
    [panel.contentView addSubview:titleLabel];
    [panel.contentView addSubview:bodyLabel];
    [panel.contentView addSubview:okButton];

    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:20.0],
        [panel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-20.0],
        [panel.widthAnchor constraintEqualToConstant:320.0],
        [titleLabel.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:22.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [titleLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [bodyLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10.0],
        [bodyLabel.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:18.0],
        [bodyLabel.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-18.0],
        [okButton.topAnchor constraintEqualToAnchor:bodyLabel.bottomAnchor constant:20.0],
        [okButton.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:16.0],
        [okButton.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-16.0],
        [okButton.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-16.0],
        [okButton.heightAnchor constraintEqualToConstant:46.0],
    ]];

    [dismissControl addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [okButton addAction:[UIAction actionWithHandler:^(__kindof UIAction * _Nonnull _) {
        LGDismissOverlayPanel(overlay, panel);
    }] forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:overlay];
    [UIView animateWithDuration:0.22 animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    }];
}

static UIView *LGMakeRespringBar(id target, SEL respringAction, SEL laterAction) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = 26.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.masksToBounds = YES;
    card.alpha = 0.0;
    card.hidden = YES;
    card.transform = CGAffineTransformMakeTranslation(0.0, 10.0);

    UIBlurEffectStyle blurStyle = UIBlurEffectStyleSystemThinMaterial;
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:blurStyle]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.userInteractionEnabled = NO;
    [card addSubview:blurView];

    UIView *tintView = [[UIView alloc] initWithFrame:CGRectZero];
    tintView.translatesAutoresizingMaskIntoConstraints = NO;
    tintView.userInteractionEnabled = NO;
    tintView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.04];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.01];
    }];
    [card addSubview:tintView];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = LGLocalized(@"prefs.respring_bar.title");
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.text = LGLocalized(@"prefs.respring_bar.subtitle");
    subtitleLabel.textColor = [UIColor secondaryLabelColor];
    subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitleLabel.numberOfLines = 2;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:LGLocalized(@"prefs.button.respring") forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor systemBlueColor];
    button.layer.cornerRadius = 14.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    [button addTarget:target action:respringAction forControlEvents:UIControlEventTouchUpInside];

    UIButton *laterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    laterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [laterButton setTitle:LGLocalized(@"prefs.button.later") forState:UIControlStateNormal];
    [laterButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    laterButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    laterButton.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull trait) {
        if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return [[UIColor whiteColor] colorWithAlphaComponent:0.10];
        }
        return [[UIColor blackColor] colorWithAlphaComponent:0.06];
    }];
    laterButton.layer.cornerRadius = 14.0;
    laterButton.layer.cornerCurve = kCACornerCurveContinuous;
    [laterButton addTarget:target action:laterAction forControlEvents:UIControlEventTouchUpInside];

    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [tintView.topAnchor constraintEqualToAnchor:card.topAnchor],
        [tintView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [tintView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [tintView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    UIStackView *buttonStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    buttonStack.translatesAutoresizingMaskIntoConstraints = NO;
    buttonStack.axis = UILayoutConstraintAxisVertical;
    buttonStack.spacing = 7.0;
    [buttonStack addArrangedSubview:button];
    [buttonStack addArrangedSubview:laterButton];

    [card addSubview:titleLabel];
    [card addSubview:subtitleLabel];
    [card addSubview:buttonStack];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14.0],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:buttonStack.leadingAnchor constant:-12.0],
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4.0],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:buttonStack.leadingAnchor constant:-12.0],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14.0],
        [buttonStack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [buttonStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16.0],
        [buttonStack.widthAnchor constraintEqualToConstant:96.0],
        [button.widthAnchor constraintEqualToConstant:82.0],
        [button.heightAnchor constraintEqualToConstant:28.0],
        [laterButton.widthAnchor constraintEqualToConstant:82.0],
        [laterButton.heightAnchor constraintEqualToConstant:28.0],
    ]];
    return card;
}
