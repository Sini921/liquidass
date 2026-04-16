#pragma once

#import <UIKit/UIKit.h>

@class LiquidGlassView;

void LGRemoveLiveBackdropCaptureView(UIView *host, const void *associationKey);
BOOL LGCaptureLiveBackdropTextureForHost(UIView *host,
                                         LiquidGlassView *glass,
                                         const void *associationKey,
                                         CGPoint *outOrigin,
                                         CGSize *outSamplingResolution);
