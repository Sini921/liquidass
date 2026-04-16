#pragma once

#import <UIKit/UIKit.h>

extern void * const kLGDefaultValueKey;
extern void * const kLGValueLabelKey;
extern void * const kLGDecimalsKey;
extern void * const kLGSliderAnimatorKey;
extern void * const kLGSliderKey;
extern void * const kLGPreferenceKeyKey;
extern void * const kLGMinValueKey;
extern void * const kLGMaxValueKey;
extern void * const kLGControlTitleKey;
extern void * const kLGControlSubtitleKey;
extern void * const kLGControlledByEnabledKey;

UIView *LGMakeNavCardGlyphView(NSString *symbolName, UIColor *tintColor);
UIColor *LGSubpageCardBackgroundColor(void);
UIView *LGMakeSectionDivider(void);
void LGApplyNavigationBarAppearance(UINavigationItem *navigationItem);
void LGInstallScrollableStack(UIViewController *controller,
                              CGFloat topInset,
                              CGFloat stackSpacing,
                              UIScrollView *__strong *scrollViewOut,
                              UIStackView *__strong *stackViewOut);
void LGInstallBottomRespringBar(UIViewController *controller, UIView *__strong *respringBarOut);
void LGPresentSliderValuePrompt(UIViewController *controller, UILabel *valueLabel);
void LGAnimateSliderToDefault(UISlider *slider, CGFloat targetValue, UILabel *valueLabel, NSInteger decimals);
UIBarButtonItem *LGMakeCircularBackItem(id target, SEL action);
UIBarButtonItem *LGMakeResetTextItem(id target, SEL action);
void LGPresentResetConfirmation(UIViewController *controller);
void LGPresentRespringConfirmation(UIViewController *controller);
void LGPresentReopenSettingsConfirmation(UIViewController *controller);
void LGPresentInfoSheet(UIViewController *controller, NSString *title, NSString *message);
