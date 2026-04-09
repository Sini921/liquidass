#import "LiquidGlass.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

static NSString *LGLogFilePath(void) {
    static NSString *sPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sPath = @"/tmp/LiquidAss.log";
    });
    return sPath;
}

static void LGAppendLogLine(NSString *line) {
    NSString *path = LGLogFilePath();
    if (!path.length || !line.length) return;

    static dispatch_queue_t sLogQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sLogQueue = dispatch_queue_create("dylv.liquidass.logfile", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(sLogQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) return;
        @try {
            [handle seekToEndOfFile];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length) [handle writeData:data];
        } @catch (__unused NSException *exception) {
        }
        @try {
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    });
}

void LGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[LiquidAss] %@", message);
    LGAppendLogLine([NSString stringWithFormat:@"[LiquidAss] %@\n", message]);
}

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone = 0,
    SBSRelaunchActionOptionsRestartRenderServer = 1 << 0,
    SBSRelaunchActionOptionsSnapshotTransition = 1 << 1,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 2,
};

@interface SBSRelaunchAction : NSObject
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

@interface UIView (LGHierarchyCapture)
- (BOOL)drawHierarchyInRect:(CGRect)rect afterScreenUpdates:(BOOL)afterUpdates;
@end

static NSString * const kMetalSource = @"// fullscreen quad + glass shading\n"
    "// kept as a string so the tweak can compile it at runtime\n"
    "\n"
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct Uniforms {\n"
    "    float2 resolution;\n"
    "    float2 screenResolution;\n"
    "    float2 cardOrigin;\n"
    "    float2 wallpaperResolution;\n"
    "    float  radius;\n"
    "    float  bezelWidth;\n"
    "    float  glassThickness;\n"
    "    float  refractionScale;\n"
    "    float  refractiveIndex;\n"
    "    float  specularOpacity;\n"
    "    float  specularAngle;\n"
    "    float  blur;\n"
    "    float2 wallpaperOrigin;\n"
    "};\n"
    "\n"
    "\n"
    "kernel void blurH(texture2d<float, access::read>  src    [[texture(0)]],\n"
    "                  texture2d<float, access::write> dst    [[texture(1)]],\n"
    "                  constant float&                 radius [[buffer(0)]],\n"
    "                  uint2 gid [[thread_position_in_grid]]) {\n"
    "    uint W = src.get_width(), H = src.get_height();\n"
    "    if (gid.x >= W || gid.y >= H) return;\n"
    "    // skip the blur pass if radius is basically off\n"
    "    if (radius < 0.5) { dst.write(src.read(gid), gid); return; }\n"
    "\n"
    "    // wider blur means a wider gaussian sample window\n"
    "    float sigma = max(radius / 2.0, 0.1);\n"
    "    int   r     = min(int(ceil(radius * 2.0)), 60);\n"
    "    float4 acc  = float4(0.0);\n"
    "    float  wsum = 0.0;\n"
    "    for (int x = -r; x <= r; x++) {\n"
    "        int sx = clamp(int(gid.x) + x, 0, int(W) - 1);\n"
    "        float w = exp(-float(x * x) / (2.0 * sigma * sigma));\n"
    "        acc  += src.read(uint2(sx, gid.y)) * w;\n"
    "        wsum += w;\n"
    "    }\n"
    "    dst.write(acc / wsum, gid);\n"
    "}\n"
    "\n"
    "kernel void blurV(texture2d<float, access::read>  src    [[texture(0)]],\n"
    "                  texture2d<float, access::write> dst    [[texture(1)]],\n"
    "                  constant float&                 radius [[buffer(0)]],\n"
    "                  uint2 gid [[thread_position_in_grid]]) {\n"
    "    uint W = src.get_width(), H = src.get_height();\n"
    "    if (gid.x >= W || gid.y >= H) return;\n"
    "    // same as blurH, just on y\n"
    "    if (radius < 0.5) { dst.write(src.read(gid), gid); return; }\n"
    "\n"
    "    float sigma = max(radius / 2.0, 0.1);\n"
    "    int   r     = min(int(ceil(radius * 2.0)), 60);\n"
    "    float4 acc  = float4(0.0);\n"
    "    float  wsum = 0.0;\n"
    "    for (int y = -r; y <= r; y++) {\n"
    "        int sy = clamp(int(gid.y) + y, 0, int(H) - 1);\n"
    "        float w = exp(-float(y * y) / (2.0 * sigma * sigma));\n"
    "        acc  += src.read(uint2(gid.x, sy)) * w;\n"
    "        wsum += w;\n"
    "    }\n"
    "    dst.write(acc / wsum, gid);\n"
    "}\n"
    "\n"
    "float surfaceConvexSquircle(float x) {\n"
    "    return pow(1.0 - pow(1.0 - x, 4.0), 0.25);\n"
    "}\n"
    "\n"
    "float2 refractRay(float2 normal, float eta) {\n"
    "    float cosI = -normal.y;\n"
    "    float k    = 1.0 - eta * eta * (1.0 - cosI * cosI);\n"
    "    if (k < 0.0) return float2(0.0);\n"
    "    float kSqrt = sqrt(k);\n"
    "    return float2(\n"
    "        -(eta * cosI + kSqrt) * normal.x,\n"
    "         eta - (eta * cosI + kSqrt) * normal.y\n"
    "    );\n"
    "}\n"
    "\n"
    "float rawRefraction(float bezelRatio, float glassThickness, float bezelWidth, float eta) {\n"
    "    float x     = clamp(bezelRatio, 0.05, 0.95);\n"
    "    float y     = surfaceConvexSquircle(x);\n"
    "    // tiny offset to estimate the curve slope\n"
    "    float y2    = surfaceConvexSquircle(x + 0.001);\n"
    "    float deriv = (y2 - y) / 0.001;\n"
    "    float mag   = sqrt(deriv * deriv + 1.0);\n"
    "    // normal of the fake glass edge\n"
    "    float2 n    = float2(-deriv / mag, -1.0 / mag);\n"
    "    float2 r    = refractRay(n, eta);\n"
    "    if (length(r) < 0.0001 || abs(r.y) < 0.0001) return 0.0;\n"
    "    // project the refracted ray through the remaining edge depth\n"
    "    float remaining = y * bezelWidth + glassThickness;\n"
    "    return r.x * (remaining / r.y);\n"
    "}\n"
    "\n"
    "float displacementAtRatio(float bezelRatio, float glassThickness,\n"
    "                          float bezelWidth, float eta) {\n"
    "    float peak = rawRefraction(0.05, glassThickness, bezelWidth, eta);\n"
    "    if (abs(peak) < 0.0001) return 0.0;\n"
    "    float raw     = rawRefraction(bezelRatio, glassThickness, bezelWidth, eta);\n"
    "    float norm    = raw / peak;\n"
    "    float falloff = 1.0 - smoothstep(0.0, 1.0, bezelRatio);\n"
    "    return norm * falloff;\n"
    "}\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 localUV;\n"
    "};\n"
    "\n"
    "vertex VertexOut vertexShader(uint vid [[vertex_id]]) {\n"
    "    // 2 triangles that cover the whole card\n"
    "    float2 pos[6] = {\n"
    "        float2(-1,-1), float2(1,-1), float2(-1,1),\n"
    "        float2(-1, 1), float2(1,-1), float2(1, 1)\n"
    "    };\n"
    "    float2 uv[6] = {\n"
    "        float2(0,1), float2(1,1), float2(0,0),\n"
    "        float2(0,0), float2(1,1), float2(1,0)\n"
    "    };\n"
    "    VertexOut out;\n"
    "    out.position = float4(pos[vid], 0, 1);\n"
    "    out.localUV  = uv[vid];\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 fragmentShader(VertexOut              in          [[stage_in]],\n"
    "                               texture2d<float>       blurredTex  [[texture(0)]],\n"
    "                               constant Uniforms&     u           [[buffer(0)]]) {\n"
    "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
    "\n"
    "    float2 px = in.localUV * u.resolution;\n"
    "    float W = u.resolution.x, H = u.resolution.y;\n"
    "    float R = u.radius, bezel = u.bezelWidth;\n"
    "    float eta = 1.0 / u.refractiveIndex;\n"
    "\n"
    "    // find whether this pixel lives in one of the rounded corners\n"
    "    bool inLeft   = px.x < R,      inRight  = px.x > W - R;\n"
    "    bool inTop    = px.y < R,      inBottom = px.y > H - R;\n"
    "    bool inCorner = (inLeft || inRight) && (inTop || inBottom);\n"
    "\n"
    "    float cx = inLeft ? px.x - R : inRight  ? px.x - (W - R) : 0.0;\n"
    "    float cy = inTop  ? px.y - R : inBottom ? px.y - (H - R) : 0.0;\n"
    "    float distFromCenter = length(float2(cx, cy));\n"
    "\n"
    "    // hard clip outside the rounded shape\n"
    "    if (inCorner && distFromCenter > R + 1.0) discard_fragment();\n"
    "\n"
    "    float distFromSide;\n"
    "    float2 dir;\n"
    "    if (inCorner) {\n"
    "        // corner distance is radial\n"
    "        distFromSide = max(0.0, R - distFromCenter);\n"
    "        dir = distFromCenter > 0.001 ? normalize(float2(cx, cy)) : float2(0);\n"
    "    } else {\n"
    "        // straight edges just use the closest side\n"
    "        float dL = px.x, dR = W - px.x, dT = px.y, dB = H - px.y;\n"
    "        float dMin = min(min(dL, dR), min(dT, dB));\n"
    "        distFromSide = dMin;\n"
    "        dir = float2(\n"
    "            (dL < dR  && dL == dMin) ? -1.0 : (dR <= dL && dR == dMin) ?  1.0 : 0.0,\n"
    "            (dT < dB  && dT == dMin) ? -1.0 : (dB <= dT && dB == dMin) ?  1.0 : 0.0\n"
    "        );\n"
    "    }\n"
    "\n"
    "    float edgeOpacity = inCorner ? clamp(1.0 - max(0.0, distFromCenter - R), 0.0, 1.0) : 1.0;\n"
    "    float bezelRatio  = clamp(distFromSide / bezel, 0.0, 1.0);\n"
    "\n"
    "    // only bend pixels near the edge\n"
    "    float normDisp = (distFromSide < bezel)\n"
    "        ? displacementAtRatio(bezelRatio, u.glassThickness, bezel, eta)\n"
    "        : 0.0;\n"
    "    float2 dispPx = -dir * normDisp * bezel * u.refractionScale * edgeOpacity;\n"
    "\n"
    "    // move from local card space into screen space\n"
    "    float2 screenPx = u.cardOrigin + px + dispPx;\n"
    "\n"
    "    float2 imgPx    = screenPx - u.wallpaperOrigin;\n"
    "    // sample from the real wallpaper size even if the texture was downscaled\n"
    "    float2 sampleUV = clamp(imgPx / u.wallpaperResolution, 0.0, 1.0);\n"
    "\n"
    "    float4 bgColor = blurredTex.sample(s, sampleUV);\n"
    "\n"
    "    // thin highlight around the edge\n"
    "    float2 lightDir   = float2(cos(u.specularAngle), -sin(u.specularAngle));\n"
    "    float  specDot    = dot(dir, lightDir);\n"
    "    float  strokePx   = 1.5;\n"
    "    float  strokeMask = clamp(1.0 - (distFromSide / strokePx), 0.0, 1.0);\n"
    "\n"
    "    float  lobeStart  = 0.66;\n"
    "    float  lobeWidth  = 0.14;\n"
    "    float  primary    = smoothstep(lobeStart, lobeStart + lobeWidth, specDot);\n"
    "    float  secondary  = smoothstep(lobeStart, lobeStart + lobeWidth, -specDot);\n"
    "    // corners need a broader match or the arc dies too fast\n"
    "    float  cornerSpec = smoothstep(0.52, 0.88, abs(specDot));\n"
    "    float  specLobe   = inCorner ? cornerSpec : (primary + secondary);\n"
    "\n"
    "    float  specular   = specLobe * strokeMask * u.specularOpacity * edgeOpacity;\n"
    "    bgColor.rgb += specular;\n"
    "\n"
    "    return float4(bgColor.rgb, edgeOpacity);\n"
    "}\n"
    "";

typedef struct {
    vector_float2 resolution;
    vector_float2 screenResolution;
    vector_float2 cardOrigin;
    vector_float2 wallpaperResolution;
    float         radius;
    float         bezelWidth;
    float         glassThickness;
    float         refractionScale;
    float         refractiveIndex;
    float         specularOpacity;
    float         specularAngle;
    float         blur;
    vector_float2 wallpaperOrigin;
} LGUniforms;

UIView *LG_findSubviewOfClass(UIView *root, Class cls) {
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = LG_findSubviewOfClass(sub, cls);
        if (r) return r;
    }
    return nil;
}

static void LG_updateAllGlassViewsInTreeImpl(UIView *root, int depth) {
    if (!root || depth > 64) return;
    if (root.hidden || root.alpha <= 0.01f || root.layer.opacity <= 0.01f) return;
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        [(LiquidGlassView *)root updateOrigin];
        return;
    }
    NSArray *subviews = root.subviews;
    for (UIView *sub in subviews)
        LG_updateAllGlassViewsInTreeImpl(sub, depth + 1);
}

void LG_updateAllGlassViewsInTree(UIView *root) {
    LG_updateAllGlassViewsInTreeImpl(root, 0);
}

static NSHashTable *sRegisteredGlassViews[LGUpdateGroupWidgets + 1] = { nil };

void LG_registerGlassView(UIView *view, LGUpdateGroup group) {
    if (!view) return;
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    if (!sRegisteredGlassViews[group])
        sRegisteredGlassViews[group] = [NSHashTable weakObjectsHashTable];
    [sRegisteredGlassViews[group] addObject:view];
}

void LG_unregisterGlassView(UIView *view, LGUpdateGroup group) {
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    [sRegisteredGlassViews[group] removeObject:view];
}

static void LG_updateGlassHashTable(NSHashTable *table) {
    if (!table.count) return;
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    for (LiquidGlassView *glass in table) {
        if (!glass.superview) continue;
        if (!glass.window) continue;
        if (glass.hidden || glass.alpha <= 0.01f || glass.layer.opacity <= 0.01f) continue;
        if (CGRectIsEmpty(glass.bounds)) continue;
        if (glass.updateGroup != LGUpdateGroupLockscreen) {
            CGRect approxRect = [glass convertRect:glass.bounds toView:nil];
            if (!CGRectIntersectsRect(CGRectInset(screenBounds, -64.0, -64.0), approxRect)) continue;
        }
        [glass updateOrigin];
    }
}

void LG_updateRegisteredGlassViews(LGUpdateGroup group) {
    if (group == LGUpdateGroupAll) {
        for (NSInteger i = LGUpdateGroupDock; i <= LGUpdateGroupWidgets; i++)
            LG_updateGlassHashTable(sRegisteredGlassViews[i]);
        return;
    }
    if (group <= LGUpdateGroupAll || group > LGUpdateGroupWidgets) return;
    LG_updateGlassHashTable(sRegisteredGlassViews[group]);
}

UIWindow *LG_getHomescreenWindow(void) {
    static __weak UIWindow *sCachedWindow = nil;
    static Class sceneCls, homeCls;
    UIWindow *cached = sCachedWindow;
    if (cached.windowScene) return cached;

    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!homeCls) homeCls = NSClassFromString(@"SBHomeScreenWindow");

    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:sceneCls]) continue;
        for (UIWindow *win in ((UIWindowScene *)sc).windows) {
            if ([win isKindOfClass:homeCls]) {
                sCachedWindow = win;
                return win;
            }
        }
    }
    return nil;
}

BOOL LG_isFullScreenDevice(void) {
    static BOOL sCached = NO;
    static BOOL sResult = NO;
    if (!sCached) {
        CGFloat h = UIScreen.mainScreen.bounds.size.height;
        CGFloat w = UIScreen.mainScreen.bounds.size.width;
        CGFloat longerSide = MAX(h, w);
        sResult = (longerSide >= 812.0);
        sCached = YES;
    }
    return sResult;
}

static UIWindow *LG_getWallpaperWindow(BOOL secureOnly) {
    static Class wCls, wsCls2, sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    if (!wCls)    wCls    = NSClassFromString(@"_SBWallpaperWindow");
    if (!wsCls2)  wsCls2  = NSClassFromString(@"_SBWallpaperSecureWindow");
    UIWindow *secureFallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (secureOnly) {
                if ([w isKindOfClass:wsCls2]) return w;
            } else {
                if ([w isKindOfClass:wCls]) return w;
                if (!secureFallback && [w isKindOfClass:wsCls2]) secureFallback = w;
            }
        }
    }
    return secureOnly ? nil : secureFallback;
}

static UIImageView *LG_getWallpaperImageView(UIWindow *win) {
    static Class replicaCls, staticWpCls, ivCls;
    if (!replicaCls)  replicaCls  = NSClassFromString(@"PBUISnapshotReplicaView");
    if (!staticWpCls) staticWpCls = NSClassFromString(@"SBFStaticWallpaperImageView");
    if (!ivCls)       ivCls       = [UIImageView class];
    UIView *replica = LG_findSubviewOfClass(win, replicaCls);
    if (replica) {
        for (UIView *sub in replica.subviews)
            if ([sub isKindOfClass:ivCls] && ((UIImageView *)sub).image) {
                CGRect screenRect = [((UIImageView *)sub) convertRect:((UIImageView *)sub).bounds toView:nil];
                LGLog(@"homescreen wallpaper imageView source=%@ rect=%@",
                      NSStringFromClass(sub.class),
                      NSStringFromCGRect(screenRect));
                return (UIImageView *)sub;
            }
    }
    UIImageView *iv = (UIImageView *)LG_findSubviewOfClass(win, staticWpCls);
    if (iv.image) {
        CGRect screenRect = [iv convertRect:iv.bounds toView:nil];
        LGLog(@"homescreen wallpaper imageView source=%@ rect=%@",
              NSStringFromClass(iv.class),
              NSStringFromCGRect(screenRect));
        return iv;
    }
    return nil;
}

static CGPoint LG_centeredWallpaperOriginForImage(UIImage *image) {
    if (!image) return CGPointZero;
    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    return CGPointMake((screenSize.width - image.size.width) * 0.5,
                       (screenSize.height - image.size.height) * 0.5);
}

static CGRect LG_imageViewDisplayedImageRect(UIImageView *imageView) {
    if (!imageView || !imageView.image) return CGRectZero;
    CGRect bounds = imageView.bounds;
    CGSize imageSize = imageView.image.size;
    if (CGRectIsEmpty(bounds) || imageSize.width <= 0.0 || imageSize.height <= 0.0) return CGRectZero;

    UIViewContentMode mode = imageView.contentMode;
    if (mode == UIViewContentModeScaleToFill) return bounds;

    CGFloat scaleX = bounds.size.width / imageSize.width;
    CGFloat scaleY = bounds.size.height / imageSize.height;
    CGFloat scale = 1.0;

    switch (mode) {
        case UIViewContentModeScaleAspectFit:
            scale = MIN(scaleX, scaleY);
            break;
        case UIViewContentModeScaleAspectFill:
        default:
            scale = MAX(scaleX, scaleY);
            break;
    }

    CGSize fitted = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
    CGFloat originX = (bounds.size.width - fitted.width) * 0.5;
    CGFloat originY = (bounds.size.height - fitted.height) * 0.5;
    return CGRectMake(originX, originY, fitted.width, fitted.height);
}

static CGPoint LG_getHomescreenWallpaperOriginForImage(UIImage *image) {
    return LG_centeredWallpaperOriginForImage(image);
}

static UIImage *sCachedSnapshot = nil;
static UIImage *sCachedContextMenuSnapshot = nil;
static UIImage *sCachedFolderSnapshot = nil;
static UIImage *sCachedSpringBoardHomeImage = nil;
static UIImage *sCachedSpringBoardLockImage = nil;
static NSDate *sCachedSpringBoardHomeMTime = nil;
static NSDate *sCachedSpringBoardLockMTime = nil;
static NSString *sCachedSpringBoardHomePath = nil;
static NSString *sCachedSpringBoardLockPath = nil;
static NSString * const kLGPrefsDomain = @"dylv.liquidassprefs";
static CFStringRef const kLGPrefsChangedNotification = CFSTR("dylv.liquidassprefs/Reload");
static CFStringRef const kLGPrefsRespringNotification = CFSTR("dylv.liquidassprefs/Respring");
static void LG_trySnapshotWithRetry(void);
static void LG_handlePrefsChanged(void);
static void LG_requestRespring(void);
static CGColorSpaceRef LGSharedRGBColorSpace(void);

static BOOL LG_isAtLeastiOS16(void) {
    static BOOL sCachedResult = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sCachedResult = [[NSProcessInfo processInfo]
            isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}];
    });
    return sCachedResult;
}

static NSString *LG_springBoardWallpaperDirectory(void) {
    static NSString *sResolved = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        [candidates addObject:@"/var/mobile/Library/SpringBoard"];

        NSString *home = NSHomeDirectory();
        if (home.length) {
            [candidates addObject:[home stringByAppendingPathComponent:@"Library/SpringBoard"]];

            NSRange containersRange = [home rangeOfString:@"/data/Containers/"];
            if (containersRange.location != NSNotFound) {
                NSString *deviceDataRoot = [home substringToIndex:containersRange.location + @"/data".length];
                [candidates addObject:[deviceDataRoot stringByAppendingPathComponent:@"Library/SpringBoard"]];
            }
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in candidates) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
                sResolved = [path copy];
                break;
            }
        }
    });
    return sResolved;
}

static NSArray<NSString *> *LG_springBoardWallpaperCandidatePaths(BOOL lockscreen) {
    NSString *root = LG_springBoardWallpaperDirectory();
    if (LG_isAtLeastiOS16()) {
        return @[];
    }
    if (lockscreen) {
        return @[
            [root stringByAppendingPathComponent:@"LockBackground.cpbitmap"],
            [root stringByAppendingPathComponent:@"LockBackgroundThumbnail.jpg"],
        ];
    }
    return @[
        [root stringByAppendingPathComponent:@"HomeBackground.cpbitmap"],
        [root stringByAppendingPathComponent:@"HomeBackgroundThumbnail.jpg"],
    ];
}

static NSString *LG_preferredSpringBoardWallpaperPath(BOOL lockscreen) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in LG_springBoardWallpaperCandidatePaths(lockscreen)) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

BOOL LG_hasHomescreenWallpaperAsset(void) {
    return LG_preferredSpringBoardWallpaperPath(NO) != nil;
}

static UIImage *LG_decodeCPBitmapAtPath(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (![data isKindOfClass:[NSData class]] || data.length < 24) return nil;

    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;

    uint32_t widthLE = 0;
    uint32_t heightLE = 0;
    memcpy(&widthLE, bytes + length - (4 * 5), sizeof(uint32_t));
    memcpy(&heightLE, bytes + length - (4 * 4), sizeof(uint32_t));
    size_t width = CFSwapInt32LittleToHost(widthLE);
    size_t height = CFSwapInt32LittleToHost(heightLE);
    if (width == 0 || height == 0 || width > 10000 || height > 10000) return nil;

    static const size_t kAlignments[] = { 16, 8, 4 };
    size_t payloadBytes = 0;
    size_t chosenAlignment = 0;
    for (size_t i = 0; i < sizeof(kAlignments) / sizeof(kAlignments[0]); i++) {
        size_t align = kAlignments[i];
        size_t lineSize = ((width + align - 1) / align) * align;
        size_t bytesNeeded = lineSize * height * 4;
        if (bytesNeeded <= length - 20) {
            payloadBytes = bytesNeeded;
            chosenAlignment = align;
            break;
        }
    }
    if (payloadBytes == 0 || chosenAlignment == 0) return nil;

    NSMutableData *rgba = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *dst = rgba.mutableBytes;
    size_t lineSize = ((width + chosenAlignment - 1) / chosenAlignment) * chosenAlignment;

    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t srcOffset = (x * 4) + (y * lineSize * 4);
            size_t dstOffset = (x * 4) + (y * width * 4);
            if (srcOffset + 3 >= length) return nil;
            // cpbitmap stores BGRA; UIKit wants RGBA here.
            dst[dstOffset + 0] = bytes[srcOffset + 2];
            dst[dstOffset + 1] = bytes[srcOffset + 1];
            dst[dstOffset + 2] = bytes[srcOffset + 0];
            dst[dstOffset + 3] = bytes[srcOffset + 3];
        }
    }

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    if (!provider) return nil;
    CGColorSpaceRef colorSpace = LGSharedRGBColorSpace();
    CGImageRef cgImage = CGImageCreate(width,
                                       height,
                                       8,
                                       32,
                                       width * 4,
                                       colorSpace,
                                       kCGBitmapByteOrderDefault | kCGImageAlphaLast,
                                       provider,
                                       NULL,
                                       NO,
                                       kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!cgImage) return nil;

    CGFloat screenScale = UIScreen.mainScreen.scale ?: 1.0;
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:screenScale orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static UIImage *LG_decodeSpringBoardWallpaperPath(NSString *path) {
    if (!path.length) return nil;
    if ([[path pathExtension].lowercaseString isEqualToString:@"jpg"] ||
        [[path pathExtension].lowercaseString isEqualToString:@"jpeg"] ||
        [[path pathExtension].lowercaseString isEqualToString:@"png"]) {
        return [UIImage imageWithContentsOfFile:path];
    }
    if ([[path pathExtension].lowercaseString isEqualToString:@"cpbitmap"]) {
        return LG_decodeCPBitmapAtPath(path);
    }
    return nil;
}

static BOOL LG_isCPBitmapPath(NSString *path) {
    return [[[path pathExtension] lowercaseString] isEqualToString:@"cpbitmap"];
}

static UIImage *LG_loadSpringBoardWallpaperImage(BOOL lockscreen) {
    NSString *path = LG_preferredSpringBoardWallpaperPath(lockscreen);
    if (!path) return nil;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];

    if (lockscreen) {
        if (sCachedSpringBoardLockImage &&
            [sCachedSpringBoardLockPath isEqualToString:path] &&
            ((!mtime && !sCachedSpringBoardLockMTime) || [sCachedSpringBoardLockMTime isEqualToDate:mtime])) {
            return sCachedSpringBoardLockImage;
        }
    } else {
        if (sCachedSpringBoardHomeImage &&
            [sCachedSpringBoardHomePath isEqualToString:path] &&
            ((!mtime && !sCachedSpringBoardHomeMTime) || [sCachedSpringBoardHomeMTime isEqualToDate:mtime])) {
            return sCachedSpringBoardHomeImage;
        }
    }

    UIImage *image = LG_decodeSpringBoardWallpaperPath(path);
    if (lockscreen) {
        sCachedSpringBoardLockImage = image;
        sCachedSpringBoardLockMTime = mtime;
        sCachedSpringBoardLockPath = [path copy];
    } else {
        sCachedSpringBoardHomeImage = image;
        sCachedSpringBoardHomeMTime = mtime;
        sCachedSpringBoardHomePath = [path copy];
    }

    if (image) {
        LGLog(@"loaded %@ wallpaper from %@", lockscreen ? @"lockscreen" : @"homescreen", path.lastPathComponent);
    }

    return image;
}

BOOL LG_prefBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kLGPrefsDomain);
    id obj = CFBridgingRelease(value);
    if ([obj isKindOfClass:[NSNumber class]]) return [obj boolValue];
    return fallback;
}

CGFloat LG_prefFloat(NSString *key, CGFloat fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kLGPrefsDomain);
    id obj = CFBridgingRelease(value);
    if ([obj isKindOfClass:[NSNumber class]]) return (CGFloat)[obj doubleValue];
    return fallback;
}

NSInteger LG_prefInteger(NSString *key, NSInteger fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kLGPrefsDomain);
    id obj = CFBridgingRelease(value);
    if ([obj isKindOfClass:[NSNumber class]]) return [obj integerValue];
    return fallback;
}

BOOL LG_globalEnabled(void) {
    return LG_prefBool(@"Global.Enabled", NO);
}

UIImage *LG_getWallpaperImage(CGPoint *outOriginInScreenPts) {
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }
    NSString *assetPath = LG_preferredSpringBoardWallpaperPath(NO);
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        if (outOriginInScreenPts) {
            *outOriginInScreenPts = LG_isCPBitmapPath(assetPath)
                ? LG_centeredWallpaperOriginForImage(asset)
                : LG_getHomescreenWallpaperOriginForImage(asset);
        }
        return asset;
    }
    UIWindow *win = LG_getWallpaperWindow(NO);
    if (!win) return nil;
    UIImageView *iv = LG_getWallpaperImageView(win);
    if (!iv.image) return nil;
    if (outOriginInScreenPts)
        *outOriginInScreenPts = [iv convertPoint:CGPointZero toView:nil];
    return iv.image;
}

static UIImage *sInterceptedWallpaperImage = nil;
static void *kLGSnapshotOriginalOpacityKey = &kLGSnapshotOriginalOpacityKey;

static CGColorSpaceRef LGSharedRGBColorSpace(void) {
    static CGColorSpaceRef sColorSpace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sColorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return sColorSpace;
}

BOOL LG_imageLooksBlack(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;
    unsigned char px[9 * 4] = {0};
    CGContextRef ctx = CGBitmapContextCreate(px, 3, 3, 8, 3 * 4, LGSharedRGBColorSpace(),
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return YES;
    CGContextDrawImage(ctx, CGRectMake(0, 0, 3, 3), cg);
    CGContextRelease(ctx);
    int nonBlack = 0;
    for (int i = 0; i < 9; i++)
        if (px[i*4] + px[i*4+1] + px[i*4+2] > 30) nonBlack++;
    return nonBlack < 3;
}

static NSInteger LG_defaultPreferredFPS(void) {
    NSInteger maxFPS = 60;
    if ([UIScreen mainScreen].maximumFramesPerSecond > 0) {
        maxFPS = [UIScreen mainScreen].maximumFramesPerSecond >= 120 ? 120 : 60;
    }
    return (30 + maxFPS) / 2;
}

static NSInteger LG_preferredFPSForUpdateGroup(LGUpdateGroup group) {
    NSInteger maxFPS = 60;
    if ([UIScreen mainScreen].maximumFramesPerSecond > 0) {
        maxFPS = [UIScreen mainScreen].maximumFramesPerSecond >= 120 ? 120 : 60;
    }
    NSString *key = nil;
    switch (group) {
        case LGUpdateGroupDock:
        case LGUpdateGroupFolderIcon:
        case LGUpdateGroupFolderOpen:
        case LGUpdateGroupContextMenu:
        case LGUpdateGroupWidgets:
        case LGUpdateGroupAppIcons:
            key = @"Homescreen.FPS";
            break;
        case LGUpdateGroupLockscreen:
            key = @"Lockscreen.FPS";
            break;
        case LGUpdateGroupAppLibrary:
            key = @"AppLibrary.FPS";
            break;
        default:
            break;
    }
    NSInteger stored = LG_prefInteger(key ?: @"", LG_defaultPreferredFPS());
    if (stored < 30) stored = 30;
    if (stored > maxFPS) stored = maxFPS;
    return stored;
}

static BOOL LG_contextSnapshotLooksIncomplete(UIImage *img) {
    if (!img) return YES;
    CGImageRef cg = img.CGImage;
    if (!cg) return YES;

    const size_t sampleSize = 8;
    unsigned char px[sampleSize * sampleSize * 4];
    memset(px, 0, sizeof(px));
    CGContextRef ctx = CGBitmapContextCreate(px, sampleSize, sampleSize, 8, sampleSize * 4,
        LGSharedRGBColorSpace(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) return YES;
    CGContextDrawImage(ctx, CGRectMake(0, 0, sampleSize, sampleSize), cg);
    CGContextRelease(ctx);

    int brightCount = 0;
    for (size_t i = 0; i < sampleSize * sampleSize; i++) {
        if (px[i * 4] + px[i * 4 + 1] + px[i * 4 + 2] > 30)
            brightCount++;
    }
    if (brightCount < 6) return YES;

    const int cornerIndices[] = {
        0,
        (int)(sampleSize - 1),
        (int)((sampleSize - 1) * sampleSize),
        (int)(sampleSize * sampleSize - 1)
    };
    int blackCorners = 0;
    for (int i = 0; i < 4; i++) {
        int idx = cornerIndices[i];
        int sum = px[idx * 4] + px[idx * 4 + 1] + px[idx * 4 + 2];
        if (sum <= 36) blackCorners++;
    }
    return blackCorners >= 3;
}

static void LG_drawWallpaperImageInContext(UIImage *image, CGPoint origin) {
    if (!image) return;
    [image drawInRect:CGRectMake(origin.x, origin.y, image.size.width, image.size.height)];
}

static BOOL LG_drawHomescreenWallpaperInContext(CGSize screenSize) {
    CGRect bounds = CGRectMake(0, 0, screenSize.width, screenSize.height);
    NSString *assetPath = LG_preferredSpringBoardWallpaperPath(NO);
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        CGPoint origin = LG_isCPBitmapPath(assetPath)
            ? LG_centeredWallpaperOriginForImage(asset)
            : LG_getHomescreenWallpaperOriginForImage(asset);
        LG_drawWallpaperImageInContext(asset, origin);
        return YES;
    }

    if (sInterceptedWallpaperImage) {
        [sInterceptedWallpaperImage drawInRect:bounds];
        return YES;
    }

    UIWindow *win = LG_getWallpaperWindow(NO);
    if (!win) return NO;
    UIImageView *iv = LG_getWallpaperImageView(win);
    if (iv.image) {
        [win drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
        return YES;
    }

    static Class secureCls;
    if (!secureCls) secureCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    if (![win isKindOfClass:secureCls]) {
        [win.layer renderInContext:UIGraphicsGetCurrentContext()];
        return YES;
    }

    [win drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
    return YES;
}

static BOOL LG_drawLockscreenWallpaperInContext(CGSize screenSize) {
    CGRect bounds = CGRectMake(0, 0, screenSize.width, screenSize.height);
    UIWindow *win = LG_getWallpaperWindow(YES);
    if (!win) return NO;
    UIImageView *iv = LG_getWallpaperImageView(win);
    if (LG_isAtLeastiOS16() && iv.image) {
        CGRect displayedRect = LG_imageViewDisplayedImageRect(iv);
        CGRect screenRect = [iv convertRect:displayedRect toView:nil];
        [iv.image drawInRect:screenRect];
        return YES;
    }
    [win drawViewHierarchyInRect:bounds afterScreenUpdates:NO];
    return YES;
}

void LG_refreshHomescreenSnapshot(void) {
    if (!LG_globalEnabled()) {
        sCachedSnapshot = nil;
        return;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset) {
        UIWindow *win = LG_getWallpaperWindow(NO);
        UIImageView *iv = win ? LG_getWallpaperImageView(win) : nil;
        LGLog(@"refresh homescreen snapshot source=asset file=%@ imageView=%d",
              LG_preferredSpringBoardWallpaperPath(NO).lastPathComponent ?: @"(unknown)",
              iv ? 1 : 0);
        sCachedSnapshot = asset;
        return;
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LGLog(@"refresh homescreen snapshot source=live-window");
    BOOL ok = LG_drawHomescreenWallpaperInContext(screenSize);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!ok || LG_imageLooksBlack(img)) return;
    sCachedSnapshot = img;
}

static void hideGlassViews(UIView *root, NSMutableArray *list) {
    if ([root isKindOfClass:[LiquidGlassView class]]) {
        objc_setAssociatedObject(root, kLGSnapshotOriginalOpacityKey,
                                 @(root.layer.opacity),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        root.layer.opacity = 0.0f;
        [CATransaction commit];
        [list addObject:root];
        return;
    }
    for (UIView *sub in root.subviews) hideGlassViews(sub, list);
}

static BOOL LG_isContextMenuWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) containsString:@"Context"] ||
           [NSStringFromClass(window.class) containsString:@"Menu"];
}

static BOOL LG_isWallpaperWindow(UIWindow *window) {
    static Class wallpaperCls, secureCls;
    if (!wallpaperCls) wallpaperCls = NSClassFromString(@"_SBWallpaperWindow");
    if (!secureCls) secureCls = NSClassFromString(@"_SBWallpaperSecureWindow");
    return [window isKindOfClass:wallpaperCls] || [window isKindOfClass:secureCls];
}

static void LG_collectSnapshotWindows(NSMutableArray<UIWindow *> *hiddenWindows,
                                      NSMutableArray<UIWindow *> *renderWindows) {
    [hiddenWindows removeAllObjects];
    [renderWindows removeAllObjects];

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.01f || window.layer.opacity <= 0.01f) continue;
            if (LG_isContextMenuWindow(window)) {
                window.hidden = YES;
                [hiddenWindows addObject:window];
                continue;
            }
            if (!LG_isWallpaperWindow(window))
                [renderWindows addObject:window];
        }
    }

    [renderWindows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static void LG_hideGlassViewsInWindows(NSArray<UIWindow *> *windows, NSMutableArray<UIView *> *hiddenViews) {
    [hiddenViews removeAllObjects];
    for (UIWindow *window in windows)
        hideGlassViews(window, hiddenViews);
}

static void LG_restoreSnapshotVisibility(NSArray<UIView *> *hiddenViews, NSArray<UIWindow *> *hiddenWindows) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *view in hiddenViews) {
        NSNumber *originalOpacity = objc_getAssociatedObject(view, kLGSnapshotOriginalOpacityKey);
        view.layer.opacity = originalOpacity ? (float)[originalOpacity doubleValue] : 1.0f;
        objc_setAssociatedObject(view, kLGSnapshotOriginalOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    [CATransaction commit];
    for (UIWindow *window in hiddenWindows) window.hidden = NO;
}

static UIViewController *LG_topPresentedViewController(UIViewController *controller) {
    UIViewController *top = controller;
    while (top.presentedViewController)
        top = top.presentedViewController;
    return top;
}

static BOOL sTodayViewVisible = NO;

static BOOL LG_isTodayViewControllerVisible(void) {
    if (sTodayViewVisible) return YES;

    static Class todayCls;
    if (!todayCls) todayCls = NSClassFromString(@"SBTodayViewController");
    if (!todayCls) return NO;

    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha <= 0.01f) continue;
                UIViewController *root = window.rootViewController;
                if (!root) continue;
                UIViewController *top = LG_topPresentedViewController(root);
                if ([top isKindOfClass:todayCls]) return YES;
            }
        }
        return NO;
    }

    for (UIWindow *window in [app valueForKey:@"windows"]) {
        if (window.hidden || window.alpha <= 0.01f) continue;
        UIViewController *root = window.rootViewController;
        if (!root) continue;
        UIViewController *top = LG_topPresentedViewController(root);
        if ([top isKindOfClass:todayCls]) return YES;
    }
    return NO;
}

static UIView *LG_contextSnapshotTargetView(UIWindow *homescreenWindow) {
    if (!homescreenWindow) return nil;
    static Class rootFolderCls, homeScreenCls, folderContainerCls;
    if (!rootFolderCls) rootFolderCls = NSClassFromString(@"SBRootFolderView");
    if (!homeScreenCls) homeScreenCls = NSClassFromString(@"SBHomeScreenView");
    if (!folderContainerCls) folderContainerCls = NSClassFromString(@"SBFolderContainerView");

    UIView *rootFolderView = rootFolderCls ? LG_findSubviewOfClass(homescreenWindow, rootFolderCls) : nil;
    if (rootFolderView) return rootFolderView;
    UIView *homeScreenView = homeScreenCls ? LG_findSubviewOfClass(homescreenWindow, homeScreenCls) : nil;
    if (homeScreenView) return homeScreenView;
    return folderContainerCls ? LG_findSubviewOfClass(homescreenWindow, folderContainerCls) : nil;
}

static UIImage *LG_captureTargetViewSnapshot(UIView *targetView, CGSize screenSize, CGFloat scale) {
    if (!targetView || !targetView.window) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, NO, scale);
    CGRect targetRect = [targetView.window convertRect:targetView.bounds fromView:targetView];
    BOOL ok = [targetView drawViewHierarchyInRect:targetRect afterScreenUpdates:YES];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!ok || LG_imageLooksBlack(snapshot)) return nil;
    return snapshot;
}

static UIImage *LG_captureWindowSnapshot(UIWindow *window, CGSize screenSize, CGFloat scale) {
    if (!window) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, NO, scale);
    BOOL ok = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (!ok || LG_imageLooksBlack(snapshot)) return nil;
    return snapshot;
}

static UIImage *LG_composeHomescreenWallpaperAndIcons(UIImage *iconsSnapshot, CGSize screenSize, CGFloat scale) {
    if (!iconsSnapshot) return nil;

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LG_drawWallpaperImageInContext(wallpaper, wallpaperOrigin);
    [iconsSnapshot drawAtPoint:CGPointZero];
    UIImage *composite = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return composite;
}

static UIImage *LG_captureBroadContextComposite(NSArray<UIWindow *> *renderWindows, CGSize screenSize, CGFloat scale) {
    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    LG_drawHomescreenWallpaperInContext(screenSize);
    for (UIWindow *window in renderWindows)
        [window.layer renderInContext:ctx];
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

static UIImage *LG_captureTodayViewComposite(UIWindow *homescreenWindow,
                                             NSArray<UIWindow *> *renderWindows,
                                             CGSize screenSize,
                                             CGFloat scale) {
    UIImage *base = LG_captureWindowSnapshot(homescreenWindow, screenSize, scale);
    if (!base) return nil;

    UIGraphicsBeginImageContextWithOptions(screenSize, NO, scale);
    [base drawAtPoint:CGPointZero];
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (UIWindow *window in renderWindows) {
        if (window == homescreenWindow) continue;
        [window.layer renderInContext:ctx];
    }
    UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snapshot;
}

static BOOL LG_contextSnapshotIsUsable(UIImage *snapshot) {
    if (!snapshot) return NO;
    if (LG_imageLooksBlack(snapshot)) return NO;
    if (!LG_hasHomescreenWallpaperAsset() && LG_contextSnapshotLooksIncomplete(snapshot)) return NO;
    return YES;
}

static UIImage *LG_captureContextMenuSnapshotWithHiddenGlass(BOOL hideGlass) {
    if (!LG_globalEnabled()) return nil;

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    static NSMutableArray *hiddenViews   = nil;
    static NSMutableArray *hiddenWindows = nil;
    static NSMutableArray *renderWindows = nil;
    if (!hiddenViews)   hiddenViews   = [NSMutableArray array];
    if (!hiddenWindows) hiddenWindows = [NSMutableArray array];
    if (!renderWindows) renderWindows = [NSMutableArray array];
    LG_collectSnapshotWindows(hiddenWindows, renderWindows);
    if (hideGlass) {
        LG_hideGlassViewsInWindows(renderWindows, hiddenViews);
    } else {
        [hiddenViews removeAllObjects];
    }

    UIImage *snap = nil;
    BOOL todayViewVisible = LG_isTodayViewControllerVisible();
    if (todayViewVisible) {
        UIWindow *homescreenWindow = LG_getHomescreenWindow();
        if (homescreenWindow) {
            snap = LG_captureTodayViewComposite(homescreenWindow, renderWindows, screenSize, scale);
        }
    } else {
        UIWindow *homescreenWindow = LG_getHomescreenWindow();
        UIView *targetView = LG_contextSnapshotTargetView(homescreenWindow);
        if (targetView && targetView.window) {
            UIImage *iconsSnap = LG_captureTargetViewSnapshot(targetView, screenSize, scale);
            snap = LG_composeHomescreenWallpaperAndIcons(iconsSnap, screenSize, scale);
        }
    }

    if (!snap) {
        NSMutableArray<NSString *> *windowNames = [NSMutableArray array];
        for (UIWindow *window in renderWindows) {
            [windowNames addObject:NSStringFromClass(window.class)];
        }
        snap = LG_captureBroadContextComposite(renderWindows, screenSize, scale);
    }

    if (hideGlass || hiddenWindows.count > 0)
        LG_restoreSnapshotVisibility(hiddenViews, hiddenWindows);
    return snap;
}

void LG_cacheContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return;
    if (sCachedContextMenuSnapshot) return;
    // hold a menu-safe snapshot only while the menu is coming in
    UIImage *snapshot = LG_captureContextMenuSnapshotWithHiddenGlass(YES);
    if (LG_contextSnapshotIsUsable(snapshot)) {
        sCachedContextMenuSnapshot = snapshot;
    }
}

void LG_invalidateContextMenuSnapshot(void) {
    sCachedContextMenuSnapshot = nil;
}

UIImage *LG_getCachedContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    if (sCachedContextMenuSnapshot) return sCachedContextMenuSnapshot;
    return sCachedSnapshot ?: LG_getContextMenuSnapshot();
}

UIImage *LG_getStrictCachedContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return sCachedContextMenuSnapshot;
}

UIImage *LG_getContextMenuSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return LG_captureContextMenuSnapshotWithHiddenGlass(YES);
}

UIImage *LG_getHomescreenSnapshot(CGPoint *outOriginInScreenPts) {
    if (!LG_globalEnabled()) {
        if (outOriginInScreenPts) *outOriginInScreenPts = CGPointZero;
        return nil;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(NO);
    if (asset && outOriginInScreenPts) {
        *outOriginInScreenPts = LG_isCPBitmapPath(LG_preferredSpringBoardWallpaperPath(NO))
            ? LG_centeredWallpaperOriginForImage(asset)
            : LG_getHomescreenWallpaperOriginForImage(asset);
    } else if (outOriginInScreenPts) {
        *outOriginInScreenPts = CGPointZero;
    }
    if (!sCachedSnapshot) LG_refreshHomescreenSnapshot();
    return sCachedSnapshot;
}

void LG_cacheFolderSnapshot(void) {
    if (!LG_globalEnabled()) return;
    UIImage *snapshot = LG_captureContextMenuSnapshotWithHiddenGlass(NO);
    sCachedFolderSnapshot = LG_contextSnapshotIsUsable(snapshot) ? snapshot : nil;
}

void LG_invalidateFolderSnapshot(void) {
    sCachedFolderSnapshot = nil;
    LG_invalidateContextMenuSnapshot();
}

UIImage *LG_getFolderSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    return sCachedFolderSnapshot;
}

UIImage *LG_getLockscreenSnapshot(void) {
    if (!LG_globalEnabled()) return nil;
    if (!LG_isAtLeastiOS16()) {
        UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
        if (asset) return asset;

        UIWindow *win = LG_getWallpaperWindow(YES);
        UIImageView *iv = win ? LG_getWallpaperImageView(win) : nil;
        if (iv.image) {
            LGLog(@"loaded lockscreen wallpaper from imageView fallback");
            return iv.image;
        }
    }

    CGSize screenSize = UIScreen.mainScreen.bounds.size;
    CGFloat scale     = UIScreen.mainScreen.scale;

    UIGraphicsBeginImageContextWithOptions(screenSize, YES, scale);
    LG_drawLockscreenWallpaperInContext(screenSize);
    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return snap;
}

CGPoint LG_getLockscreenWallpaperOrigin(void) {
    if (!LG_globalEnabled()) return CGPointZero;
    if (LG_isAtLeastiOS16()) {
        return CGPointZero;
    }
    UIImage *asset = LG_loadSpringBoardWallpaperImage(YES);
    if (asset) {
        return LG_centeredWallpaperOriginForImage(asset);
    }
    UIWindow *win = LG_getWallpaperWindow(YES);
    UIImageView *iv = win ? LG_getWallpaperImageView(win) : nil;
    if (iv.image) {
        CGRect displayedRect = LG_imageViewDisplayedImageRect(iv);
        CGRect screenRect = [iv convertRect:displayedRect toView:nil];
        return screenRect.origin;
    }
    return CGPointZero;
}


static id<MTLDevice>               sDevice;
static id<MTLRenderPipelineState>  sPipeline;
static id<MTLComputePipelineState> sBlurHPipeline;
static id<MTLComputePipelineState> sBlurVPipeline;
static id<MTLCommandQueue>         sSharedCommandQueue;
static MTLComputePassDescriptor   *sComputePassDesc;

@interface LGTextureCache : NSObject
@property (nonatomic, strong) id<MTLTexture> bgTexture;
@property (nonatomic, strong) id<MTLTexture> blurTmpTexture;
@property (nonatomic, strong) id<MTLTexture> blurredTexture;
@property (nonatomic, strong) id bridge;
@property (nonatomic, assign) float          bakedBlurRadius;
@end
@implementation LGTextureCache @end

@interface LGZeroCopyBridge : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, assign) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;
@property (nonatomic, assign) CVMetalTextureRef cvTexture;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height;
- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions;
@end

@implementation LGZeroCopyBridge

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _device = device;
    CVMetalTextureCacheRef cache = NULL;
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache);
    if (status == kCVReturnSuccess) {
        _textureCache = cache;
    }
    return self;
}

- (void)dealloc {
    if (_cvTexture) {
        CFRelease(_cvTexture);
        _cvTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (BOOL)setupBufferWithWidth:(size_t)width height:(size_t)height {
    if (!_textureCache || !width || !height) return NO;

    if (_cvTexture) {
        CFRelease(_cvTexture);
        _cvTexture = NULL;
    }
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }

    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)attrs,
                                          &_pixelBuffer);
    if (status != kCVReturnSuccess || !_pixelBuffer) return NO;

    CVMetalTextureRef cvTexture = NULL;
    status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _textureCache,
                                                       _pixelBuffer,
                                                       nil,
                                                       MTLPixelFormatBGRA8Unorm,
                                                       width,
                                                       height,
                                                       0,
                                                       &cvTexture);
    if (status != kCVReturnSuccess || !cvTexture) return NO;
    _cvTexture = cvTexture;
    return YES;
}

- (id<MTLTexture>)renderWithActions:(void (^)(CGContextRef context))actions {
    if (!_pixelBuffer || !_textureCache || !_cvTexture) return nil;

    CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
    void *data = CVPixelBufferGetBaseAddress(_pixelBuffer);
    size_t width = CVPixelBufferGetWidth(_pixelBuffer);
    size_t height = CVPixelBufferGetHeight(_pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(_pixelBuffer);

    CGContextRef context = CGBitmapContextCreate(data,
                                                 width,
                                                 height,
                                                 8,
                                                 bytesPerRow,
                                                 LGSharedRGBColorSpace(),
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!context) {
        CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
        return nil;
    }

    if (actions) actions(context);

    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVMetalTextureCacheFlush(_textureCache, 0);
    return CVMetalTextureGetTexture(_cvTexture);
}

@end

static NSMapTable *sTextureCache = nil;

static NSNumber *LGTextureScaleKey(CGFloat scale) {
    NSInteger milli = (NSInteger)lrint(scale * 1000.0);
    return @(MAX(milli, 1));
}

static LGTextureCache *LG_getCacheForImage(UIImage *image, CGFloat scale) {
    NSDictionary *variants = [sTextureCache objectForKey:image];
    return variants[LGTextureScaleKey(scale)];
}

static void LG_setCacheForImage(UIImage *image, CGFloat scale, LGTextureCache *cache) {
    NSMutableDictionary *variants = [sTextureCache objectForKey:image];
    if (!variants) {
        variants = [NSMutableDictionary dictionary];
        [sTextureCache setObject:variants forKey:image];
    }
    variants[LGTextureScaleKey(scale)] = cache;
}

static void LG_prewarmPipelines(void) {
    sDevice = MTLCreateSystemDefaultDevice();
    if (!sDevice) { return; }

    NSError *err = nil;
    id<MTLLibrary> lib = [sDevice newLibraryWithSource:kMetalSource
                                               options:[MTLCompileOptions new]
                                                 error:&err];
    if (!lib) { return; }

    id<MTLFunction> vert = [lib newFunctionWithName:@"vertexShader"];
    id<MTLFunction> frag = [lib newFunctionWithName:@"fragmentShader"];

    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction   = vert;
    desc.fragmentFunction = frag;
    MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[0];
    ca.pixelFormat                 = MTLPixelFormatBGRA8Unorm;
    ca.blendingEnabled             = YES;
    ca.rgbBlendOperation           = MTLBlendOperationAdd;
    ca.alphaBlendOperation         = MTLBlendOperationAdd;
    ca.sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
    ca.destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
    ca.sourceAlphaBlendFactor      = MTLBlendFactorOne;
    ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    sPipeline = [sDevice newRenderPipelineStateWithDescriptor:desc error:&err];

    id<MTLFunction> blurH = [lib newFunctionWithName:@"blurH"];
    id<MTLFunction> blurV = [lib newFunctionWithName:@"blurV"];
    sBlurHPipeline = [sDevice newComputePipelineStateWithFunction:blurH error:&err];
    sBlurVPipeline = [sDevice newComputePipelineStateWithFunction:blurV error:&err];
    sSharedCommandQueue = [sDevice newCommandQueue];
    sComputePassDesc    = [MTLComputePassDescriptor computePassDescriptor];
    sTextureCache       = [NSMapTable weakToStrongObjectsMapTable];
}


@implementation LiquidGlassView {
    id<MTLTexture> _bgTexture;
    id<MTLTexture> _blurTmpTexture;
    id<MTLTexture> _blurredTexture;
    LGTextureCache *_cacheEntry;
    MTKView        *_mtkView;
    BOOL             _needsBlurBake;
    float            _lastBakedBlurRadius;
    CGPoint          _wallpaperOriginPt;
    CGSize           _sourceWallpaperPixelSize;
    CGRect           _cachedVisualRectPx;
    CGSize           _cachedDrawableSizePx;
    float            _cachedVisualScale;
    BOOL             _hasCachedVisualMetrics;
    BOOL             _drawScheduled;
    CGFloat          _effectiveTextureScale;
    CGSize           _lastLayoutBounds;
    CFTimeInterval   _lastDrawSubmissionTime;
}

- (instancetype)initWithFrame:(CGRect)frame wallpaper:(UIImage *)wallpaper wallpaperOrigin:(CGPoint)origin {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _cornerRadius        = 13.5;
    _bezelWidth          = 14;
    _glassThickness      = 80;
    _refractionScale     = 1.2;
    _refractiveIndex     = 1.0;
    _specularOpacity     = 0.8;
    _blur                = 8;
    _wallpaperScale      = 1.0;
    _updateGroup         = LGUpdateGroupAll;
    _wallpaperOriginPt   = origin;
    _needsBlurBake       = YES;
    _lastBakedBlurRadius = -1;
    _effectiveTextureScale = -1;
    _lastLayoutBounds = CGSizeZero;
    _lastDrawSubmissionTime = 0;

    if (!sDevice) { return nil; }

    _mtkView = [[MTKView alloc] initWithFrame:self.bounds device:sDevice];
    _mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _mtkView.clearColor       = MTLClearColorMake(0, 0, 0, 0);
    _mtkView.framebufferOnly  = NO;
    _mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    _mtkView.paused           = YES;
    _mtkView.enableSetNeedsDisplay = NO;
    _mtkView.opaque           = NO;
    _mtkView.layer.opaque = NO;
    _mtkView.delegate     = self;
    [self addSubview:_mtkView];

    self.clipsToBounds      = YES;
    self.layer.cornerRadius = _cornerRadius;
    if (@available(iOS 13.0, *))
        self.layer.cornerCurve = kCACornerCurveContinuous;

    _wallpaperImage = wallpaper;
    return self;
}
- (void)setReleasesWallpaperAfterUpload:(BOOL)releases {
    _releasesWallpaperAfterUpload = releases;
    if (releases && (_bgTexture || _cacheEntry))
        _wallpaperImage = nil;
}

- (void)setCornerRadius:(CGFloat)r {
    if (fabs(_cornerRadius - r) < 0.001f) return;
    _cornerRadius = r;
    self.layer.cornerRadius = r;
    [self scheduleDraw];
}

- (void)setBlur:(CGFloat)b {
    if (fabs(_blur - b) < 0.001f) return;
    _blur = b;
    _needsBlurBake = YES;
    [self scheduleDraw];
}

- (void)setBezelWidth:(CGFloat)value {
    if (fabs(_bezelWidth - value) < 0.001f) return;
    _bezelWidth = value;
    [self scheduleDraw];
}

- (void)setGlassThickness:(CGFloat)value {
    if (fabs(_glassThickness - value) < 0.001f) return;
    _glassThickness = value;
    [self scheduleDraw];
}

- (void)setRefractionScale:(CGFloat)value {
    if (fabs(_refractionScale - value) < 0.001f) return;
    _refractionScale = value;
    [self scheduleDraw];
}

- (void)setRefractiveIndex:(CGFloat)value {
    if (fabs(_refractiveIndex - value) < 0.001f) return;
    _refractiveIndex = value;
    [self scheduleDraw];
}

- (void)setSpecularOpacity:(CGFloat)value {
    if (fabs(_specularOpacity - value) < 0.001f) return;
    _specularOpacity = value;
    [self scheduleDraw];
}

- (void)setWallpaperImage:(UIImage *)img {
    if (_wallpaperImage == img) return;
    _wallpaperImage = img;
    [self _reloadTexture];
}

- (CGPoint)wallpaperOrigin {
    return _wallpaperOriginPt;
}

- (void)setWallpaperOrigin:(CGPoint)origin {
    if (fabs(_wallpaperOriginPt.x - origin.x) < 0.001f &&
        fabs(_wallpaperOriginPt.y - origin.y) < 0.001f) {
        return;
    }
    _wallpaperOriginPt = origin;
    [self scheduleDraw];
}

- (void)setWallpaperScale:(CGFloat)scale {
    CGFloat clamped = fmax(0.1, fmin(scale, 1.0));
    if (fabs(_wallpaperScale - clamped) < 0.001f) return;
    CGFloat previousEffectiveScale = _effectiveTextureScale;
    _wallpaperScale = clamped;
    _effectiveTextureScale = -1;
    if (self.wallpaperImage) {
        NSUInteger srcW = (NSUInteger)(self.wallpaperImage.size.width  * self.wallpaperImage.scale);
        NSUInteger srcH = (NSUInteger)(self.wallpaperImage.size.height * self.wallpaperImage.scale);
        CGFloat nextEffectiveScale = [self _recommendedInternalTextureScaleForSourceWidth:srcW height:srcH];
        if (fabs(previousEffectiveScale - nextEffectiveScale) > 0.001f || !_bgTexture) {
            [self _reloadTexture];
        }
    } else {
        [self _reloadTexture];
    }
    [self scheduleDraw];
}

- (void)setUpdateGroup:(LGUpdateGroup)group {
    if (_updateGroup == group) return;
    if (_updateGroup != LGUpdateGroupAll)
        LG_unregisterGlassView(self, _updateGroup);
    _updateGroup = group;
    if (_updateGroup != LGUpdateGroupAll)
        LG_registerGlassView(self, _updateGroup);
}

- (void)updateOrigin {
    if (!_mtkView.superview) return;
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
    BOOL metricsChanged = [self _refreshVisualMetrics];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect screenBoundsPx = CGRectMake(0, 0,
                                       UIScreen.mainScreen.bounds.size.width * scale,
                                       UIScreen.mainScreen.bounds.size.height * scale);
    if (!CGRectIntersectsRect(_cachedVisualRectPx, screenBoundsPx)) return;
    if (!metricsChanged && !_needsBlurBake) return;
    [self scheduleDraw];
}

- (void)scheduleDraw {
    if (!_mtkView.superview) return;
    if (_drawScheduled) return;
    _drawScheduled = YES;
    CFTimeInterval now = CACurrentMediaTime();
    NSInteger preferredFPS = MAX(30, LG_preferredFPSForUpdateGroup(_updateGroup));
    CFTimeInterval earliest = _lastDrawSubmissionTime + (1.0 / (CFTimeInterval)preferredFPS);
    CFTimeInterval delay = MAX(0.0, earliest - now);
    __weak typeof(self) weakSelf = self;
    dispatch_block_t block = ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_drawScheduled = NO;
        if (!self->_mtkView.superview) return;
        if (self.hidden || self.alpha <= 0.01f || self.layer.opacity <= 0.01f) return;
        self->_lastDrawSubmissionTime = CACurrentMediaTime();
        [self->_mtkView draw];
    };
    if (delay > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), block);
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (BOOL)_refreshVisualMetrics {
    CGFloat scale = UIScreen.mainScreen.scale;
    CGRect visualRect;
    if (_updateGroup == LGUpdateGroupLockscreen && self.window) {
        CALayer *pres = self.layer.presentationLayer ?: self.layer;
        CALayer *windowLayer = self.window.layer.presentationLayer ?: self.window.layer;
        CGRect windowScreenRect = self.window.windowScene
            ? [self.window convertRect:self.window.bounds
                     toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
            : [self.window convertRect:self.window.bounds toView:nil];
        if (pres != windowLayer) {
            CGRect vr = pres.bounds;
            CALayer *cur = pres;
            while (cur && cur != windowLayer) {
                CALayer *up = cur.superlayer;
                if (!up) break;
                CALayer *upPres = up.presentationLayer ?: up;
                vr = [cur convertRect:vr toLayer:upPres];
                cur = upPres;
            }
            visualRect = CGRectMake((windowScreenRect.origin.x + vr.origin.x) * scale,
                                    (windowScreenRect.origin.y + vr.origin.y) * scale,
                                    vr.size.width * scale,
                                    vr.size.height * scale);
        } else {
            CGRect screenRect = self.window.windowScene
                ? [self convertRect:self.bounds toCoordinateSpace:UIScreen.mainScreen.coordinateSpace]
                : [self convertRect:self.bounds toView:nil];
            visualRect = CGRectMake(screenRect.origin.x * scale,
                                    screenRect.origin.y * scale,
                                    screenRect.size.width * scale,
                                    screenRect.size.height * scale);
        }
    } else {
        // use presentation layers so close animations stay anchored right
        CALayer *pres = self.layer.presentationLayer ?: self.layer;
        CALayer *root = pres;
        while (root.superlayer)
            root = root.superlayer.presentationLayer ?: root.superlayer;

        if (root != pres) {
            CGRect vr = pres.bounds;
            CALayer *cur = pres;
            while (cur && cur != root) {
                CALayer *up = cur.superlayer;
                if (!up) break;
                CALayer *upPres = up.presentationLayer ?: up;
                vr = [cur convertRect:vr toLayer:upPres];
                cur = upPres;
            }
            visualRect = CGRectMake(vr.origin.x * scale,
                                    vr.origin.y * scale,
                                    vr.size.width * scale,
                                    vr.size.height * scale);
        } else {
            CGPoint orig = [self convertPoint:CGPointZero toView:nil];
            visualRect = CGRectMake(orig.x * scale,
                                    orig.y * scale,
                                    self.bounds.size.width * scale,
                                    self.bounds.size.height * scale);
        }
    }

    CGSize drawableSize = _mtkView.drawableSize;
    float drawableW = self.bounds.size.width * scale;
    float visualScale = (drawableW > 0.0f) ? (CGRectGetWidth(visualRect) / drawableW) : 1.0f;

    if (_hasCachedVisualMetrics
        && fabs(CGRectGetMinX(_cachedVisualRectPx) - CGRectGetMinX(visualRect)) < 0.5f
        && fabs(CGRectGetMinY(_cachedVisualRectPx) - CGRectGetMinY(visualRect)) < 0.5f
        && fabs(CGRectGetWidth(_cachedVisualRectPx) - CGRectGetWidth(visualRect)) < 0.5f
        && fabs(CGRectGetHeight(_cachedVisualRectPx) - CGRectGetHeight(visualRect)) < 0.5f
        && fabs(_cachedDrawableSizePx.width - drawableSize.width) < 0.5f
        && fabs(_cachedDrawableSizePx.height - drawableSize.height) < 0.5f
        && fabs(_cachedVisualScale - visualScale) < 0.001f) {
        return NO;
    }

    _cachedVisualRectPx = visualRect;
    _cachedDrawableSizePx = drawableSize;
    _cachedVisualScale = visualScale;
    _hasCachedVisualMetrics = YES;
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = UIScreen.mainScreen.scale;
    CGSize boundsSize = self.bounds.size;
    CGSize drawableSize = CGSizeMake(MAX(1.0, floor(boundsSize.width * scale)),
                                     MAX(1.0, floor(boundsSize.height * scale)));
    if (!CGSizeEqualToSize(_mtkView.drawableSize, drawableSize)) {
        _mtkView.drawableSize = drawableSize;
        _hasCachedVisualMetrics = NO;
    }
    if (!CGSizeEqualToSize(_lastLayoutBounds, boundsSize)) {
        _lastLayoutBounds = boundsSize;
        [self scheduleDraw];
    }
}

- (CGFloat)_recommendedInternalTextureScaleForSourceWidth:(NSUInteger)srcW height:(NSUInteger)srcH {
    CGFloat userScale = fmax(0.1, fmin(_wallpaperScale, 1.0));
    CGFloat screenScale = UIScreen.mainScreen.scale;
    CGFloat viewMaxPx = MAX(self.bounds.size.width, self.bounds.size.height) * screenScale;
    CGFloat sourceMaxPx = MAX((CGFloat)srcW, (CGFloat)srcH);
    if (viewMaxPx <= 1.0 || sourceMaxPx <= 1.0) return userScale;

    // Small surfaces do not benefit from full-size wallpaper textures.
    CGFloat adaptiveScale = (viewMaxPx * 2.4) / sourceMaxPx;
    adaptiveScale = fmax(0.16, fmin(adaptiveScale, 1.0));
    CGFloat groupCap = 1.0;
    switch (_updateGroup) {
        case LGUpdateGroupAppIcons: groupCap = 0.28; break;
        case LGUpdateGroupFolderIcon: groupCap = 0.35; break;
        case LGUpdateGroupWidgets: groupCap = 0.40; break;
        case LGUpdateGroupAppLibrary: groupCap = 0.35; break;
        case LGUpdateGroupDock: groupCap = 0.50; break;
        case LGUpdateGroupContextMenu: groupCap = 0.50; break;
        case LGUpdateGroupFolderOpen: groupCap = 0.50; break;
        case LGUpdateGroupLockscreen: groupCap = 0.75; break;
        default: break;
    }
    return fmin(fmin(userScale, adaptiveScale), groupCap);
}

- (void)_reloadTexture {
    UIImage *image = self.wallpaperImage;
    if (!image) return;
    NSUInteger srcW = (NSUInteger)(image.size.width  * image.scale);
    NSUInteger srcH = (NSUInteger)(image.size.height * image.scale);
    CGFloat textureScale = [self _recommendedInternalTextureScaleForSourceWidth:srcW height:srcH];
    _effectiveTextureScale = textureScale;
    // keep the real wallpaper size for uv math even if the texture is downscaled
    _sourceWallpaperPixelSize = CGSizeMake(srcW, srcH);
    NSUInteger w = MAX((NSUInteger)1, (NSUInteger)lrint(srcW * textureScale));
    NSUInteger h = MAX((NSUInteger)1, (NSUInteger)lrint(srcH * textureScale));
    if (!w || !h) return;

    LGTextureCache *cached = LG_getCacheForImage(image, textureScale);
    if (cached) {
        // blur textures get reused per image + scale
        _cacheEntry      = cached;
        _bgTexture      = cached.bgTexture;
        _blurTmpTexture = cached.blurTmpTexture;
        _blurredTexture = cached.blurredTexture;
        if (cached.bakedBlurRadius == _blur) {
            _needsBlurBake       = NO;
            _lastBakedBlurRadius = cached.bakedBlurRadius;
        } else {
            _needsBlurBake       = YES;
            _lastBakedBlurRadius = -1;
        }
        if (_releasesWallpaperAfterUpload)
            _wallpaperImage = nil;
        return;
    }

    LGZeroCopyBridge *bridge = [[LGZeroCopyBridge alloc] initWithDevice:sDevice];
    if (![bridge setupBufferWithWidth:w height:h]) return;

    _bgTexture = [bridge renderWithActions:^(CGContextRef ctx) {
        CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image.CGImage);
    }];
    if (!_bgTexture) return;

    MTLTextureDescriptor *rd =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:w height:h mipmapped:NO];
    rd.usage        = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    _blurTmpTexture = [sDevice newTextureWithDescriptor:rd];
    _blurredTexture = [sDevice newTextureWithDescriptor:rd];

    LGTextureCache *entry   = [LGTextureCache new];
    entry.bgTexture         = _bgTexture;
    entry.blurTmpTexture    = _blurTmpTexture;
    entry.blurredTexture    = _blurredTexture;
    entry.bridge            = bridge;
    entry.bakedBlurRadius   = -1;
    _cacheEntry             = entry;
    LG_setCacheForImage(image, textureScale, entry);

    _needsBlurBake       = YES;
    _lastBakedBlurRadius = -1;
    if (_releasesWallpaperAfterUpload)
        _wallpaperImage = nil;
}

- (void)_runBlurPassesWithRadius:(float)radius commandBuffer:(id<MTLCommandBuffer>)cmdBuf {
    if (!_bgTexture || !_blurredTexture) return;

    if (radius < 0.5f) {
        id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
        if (!blit) return;
        [blit copyFromTexture:_bgTexture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(_bgTexture.width, _bgTexture.height, 1)
                    toTexture:_blurredTexture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        return;
    }

    float sigma = MAX(radius * 0.5f, 0.1f);
    MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:sDevice sigma:sigma];
    blur.edgeMode = MPSImageEdgeModeClamp;
    [blur encodeToCommandBuffer:cmdBuf sourceTexture:_bgTexture destinationTexture:_blurredTexture];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    _hasCachedVisualMetrics = NO;
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_bgTexture && self.wallpaperImage) [self _reloadTexture];
    if (!sPipeline || !_bgTexture || !_blurredTexture) return;
    [self _refreshVisualMetrics];
    CGSize drawableSize = _cachedDrawableSizePx;
    if (drawableSize.width < 1 || drawableSize.height < 1) return;
    id<CAMetalDrawable>     drawable = view.currentDrawable;
    MTLRenderPassDescriptor *passDesc = view.currentRenderPassDescriptor;
    if (!drawable || !passDesc) return;
    id<MTLCommandBuffer> cmdBuf = [sSharedCommandQueue commandBuffer];
    if (!cmdBuf) return;

    CGFloat scale = UIScreen.mainScreen.scale;
    static CGFloat screenW = 0, screenH = 0;
    if (!screenW || !screenH) {
        screenW = UIScreen.mainScreen.bounds.size.width  * scale;
        screenH = UIScreen.mainScreen.bounds.size.height * scale;
    }

    float visOriginX = CGRectGetMinX(_cachedVisualRectPx);
    float visOriginY = CGRectGetMinY(_cachedVisualRectPx);
    float visW = CGRectGetWidth(_cachedVisualRectPx);
    float visH = CGRectGetHeight(_cachedVisualRectPx);
    float visualScale = _cachedVisualScale;

    float imgW      = (float)_bgTexture.width;
    float imgH      = (float)_bgTexture.height;
    float fillScale = fmaxf((float)screenW / imgW, (float)screenH / imgH);
    // smaller textures need less blur work
    float blurPx    = (float)_blur * (float)scale / fillScale;

    if (_needsBlurBake || blurPx != _lastBakedBlurRadius) {
        [self _runBlurPassesWithRadius:blurPx commandBuffer:cmdBuf];
        _lastBakedBlurRadius = blurPx;
        _needsBlurBake       = NO;
        LGTextureCache *entry = _cacheEntry;
        if (entry) entry.bakedBlurRadius = _blur;
    }

    id<MTLRenderCommandEncoder> enc =
        [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    LGUniforms u = {
        .resolution       = { visW,   visH   },
        .screenResolution = { (float)screenW,  (float)screenH  },
        .cardOrigin       = { visOriginX, visOriginY },
        .wallpaperResolution = { (float)_sourceWallpaperPixelSize.width,
                                 (float)_sourceWallpaperPixelSize.height },
        .radius           = (float)(_cornerRadius * scale * visualScale),
        .bezelWidth       = (float)(_bezelWidth   * scale * visualScale),
        .glassThickness   = (float)_glassThickness,
        .refractionScale  = (float)_refractionScale,
        .refractiveIndex  = (float)_refractiveIndex,
        .specularOpacity  = (float)_specularOpacity,
        .specularAngle    = 2.2689280f,
        .blur             = blurPx,
        .wallpaperOrigin  = { (float)(_wallpaperOriginPt.x * scale),
                              (float)(_wallpaperOriginPt.y * scale) },
    };
    [enc setRenderPipelineState:sPipeline];
    [enc setVertexBytes:&u   length:sizeof(u) atIndex:0];
    [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:_blurredTexture atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
}

- (void)dealloc {
    if (_updateGroup != LGUpdateGroupAll)
        LG_unregisterGlassView(self, _updateGroup);
}

@end

static void LG_preferencesChanged(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_handlePrefsChanged();
    });
}

static void LG_respringRequested(CFNotificationCenterRef center,
                                 void *observer,
                                 CFStringRef name,
                                 const void *object,
                                 CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LG_requestRespring();
    });
}

static void LG_requestRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);

    Class actionClass = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) {
        return;
    }

    SBSRelaunchAction *restartAction =
        [actionClass actionWithReason:@"LiquidAssPrefs"
                              options:(SBSRelaunchActionOptionsRestartRenderServer |
                                       SBSRelaunchActionOptionsFadeToBlackTransition)
                            targetURL:nil];
    if (!restartAction) {
        return;
    }

    LGLog(@"respring requested");
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
}

%ctor {
    LGLog(@"loaded into %@", NSBundle.mainBundle.bundleIdentifier ?: @"(unknown)");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LG_prewarmPipelines();
    });
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_preferencesChanged,
                                    kLGPrefsChangedNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    LG_respringRequested,
                                    kLGPrefsRespringNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void LG_pushWallpaperToTree(UIView *root) {
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        ((LiquidGlassView *)root).wallpaperImage = sCachedSnapshot;
        [(LiquidGlassView *)root updateOrigin];
        return;
    }
    for (UIView *sub in root.subviews) LG_pushWallpaperToTree(sub);
}

static void LG_pushConfiguredBackdropToTree(UIView *root, LGUpdateGroup group, UIImage *image) {
    if (!root || !image) return;
    static Class glassClass;
    if (!glassClass) glassClass = [LiquidGlassView class];
    if ([root isKindOfClass:glassClass]) {
        LiquidGlassView *glass = (LiquidGlassView *)root;
        if (glass.updateGroup == group) {
            glass.wallpaperImage = image;
            if (group == LGUpdateGroupLockscreen)
                glass.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
            [glass updateOrigin];
        }
        return;
    }
    for (UIView *sub in root.subviews)
        LG_pushConfiguredBackdropToTree(sub, group, image);
}

static void LG_pushSnapshotToAllGlassViews(void) {
    if (!sCachedSnapshot) return;
    UIWindow *homescreenWindow = LG_getHomescreenWindow();
    if (homescreenWindow) LG_pushWallpaperToTree(homescreenWindow);
}

static void LG_pushLockscreenSnapshotToAllGlassViews(void) {
    if (!LG_globalEnabled()) return;
    UIImage *lockImage = LG_getLockscreenSnapshot();
    if (!lockImage) return;

    static Class sceneCls;
    if (!sceneCls) sceneCls = [UIWindowScene class];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:sceneCls]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            LG_pushConfiguredBackdropToTree(window, LGUpdateGroupLockscreen, lockImage);
    }
}

static void LG_handlePrefsChanged(void) {
    LGLog(@"preferences changed");
    sCachedSnapshot = nil;
    sCachedFolderSnapshot = nil;
    sCachedContextMenuSnapshot = nil;
    sInterceptedWallpaperImage = nil;
    sCachedSpringBoardHomeImage = nil;
    sCachedSpringBoardLockImage = nil;
    sCachedSpringBoardHomeMTime = nil;
    sCachedSpringBoardLockMTime = nil;
    sCachedSpringBoardHomePath = nil;
    sCachedSpringBoardLockPath = nil;

    if (!LG_globalEnabled()) return;

    LG_refreshHomescreenSnapshot();
    if (sCachedSnapshot) {
        LG_pushSnapshotToAllGlassViews();
    } else {
        LG_trySnapshotWithRetry();
    }
    LG_pushLockscreenSnapshotToAllGlassViews();
    LG_updateRegisteredGlassViews(LGUpdateGroupLockscreen);
    LG_updateRegisteredGlassViews(LGUpdateGroupWidgets);
    LG_updateRegisteredGlassViews(LGUpdateGroupDock);
    LG_updateRegisteredGlassViews(LGUpdateGroupFolderIcon);
    LG_updateRegisteredGlassViews(LGUpdateGroupAppLibrary);
}

static void LG_trySnapshotWithRetry(void) {
    if (!LG_globalEnabled()) return;
    if (sCachedSnapshot) return;
    LG_refreshHomescreenSnapshot();
    if (sCachedSnapshot) {
        LG_pushSnapshotToAllGlassViews();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LG_trySnapshotWithRetry(); });
}

%hook UIImageView

- (void)setImage:(UIImage *)image {
    %orig;
    if (!LG_globalEnabled()) return;
    if (!image) return;
    if (sInterceptedWallpaperImage) return;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (image.size.width < screen.width * 0.5) return;
    static Class replicaCls;
    if (!replicaCls) replicaCls = NSClassFromString(@"PBUISnapshotReplicaView");
    UIView *v = self.superview;
    while (v) {
        if ([v isKindOfClass:replicaCls]) {
            sInterceptedWallpaperImage = image;
            sCachedSnapshot = nil;
            LG_refreshHomescreenSnapshot();
            if (sCachedSnapshot) LG_pushSnapshotToAllGlassViews();
            return;
        }
        v = v.superview;
    }
}

%end

%hook SBHomeScreenViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_trySnapshotWithRetry();
    NSArray<NSNumber *> *delays = @[@0.12, @0.28, @0.55];
    for (NSNumber *delayNumber in delays) {
        NSTimeInterval delay = delayNumber.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!LG_globalEnabled()) return;
            if (!LG_getFolderSnapshot())
                LG_cacheFolderSnapshot();
        });
    }
}
%end

%hook SBTodayViewController
- (void)viewWillAppear:(BOOL)animated {
    sTodayViewVisible = YES;
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sTodayViewVisible = YES;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_invalidateContextMenuSnapshot();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!LG_globalEnabled()) return;
        LG_cacheFolderSnapshot();
        LG_cacheContextMenuSnapshot();
    });
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    sTodayViewVisible = NO;
    if (!LG_globalEnabled()) return;
    LG_invalidateFolderSnapshot();
    LG_invalidateContextMenuSnapshot();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!LG_globalEnabled()) return;
        LG_trySnapshotWithRetry();
        if (!LG_getFolderSnapshot())
            LG_cacheFolderSnapshot();
    });
}
%end

static BOOL LG_shouldCacheSnapshotsForLongPress(UIGestureRecognizer *gesture) {
    UIView *view = gesture.view;
    if (!view || !view.window) return NO;

    static Class sbIconViewCls;
    static Class sbFolderIconImageViewCls;
    static Class sbIconListViewCls;
    if (!sbIconViewCls) sbIconViewCls = NSClassFromString(@"SBIconView");
    if (!sbFolderIconImageViewCls) sbFolderIconImageViewCls = NSClassFromString(@"SBFolderIconImageView");
    if (!sbIconListViewCls) sbIconListViewCls = NSClassFromString(@"SBIconListView");

    UIView *v = view;
    BOOL foundIconishView = NO;
    while (v) {
        if ((sbIconViewCls && [v isKindOfClass:sbIconViewCls]) ||
            (sbFolderIconImageViewCls && [v isKindOfClass:sbFolderIconImageViewCls])) {
            foundIconishView = YES;
        }
        if (foundIconishView && sbIconListViewCls && [v isKindOfClass:sbIconListViewCls])
            return YES;
        v = v.superview;
    }
    return NO;
}

%hook UILongPressGestureRecognizer
- (void)setState:(UIGestureRecognizerState)state {
    %orig;
    if (state != UIGestureRecognizerStateBegan) return;
    if (!LG_shouldCacheSnapshotsForLongPress(self)) return;
    LGLog(@"long press snapshot warmup");
    LG_cacheFolderSnapshot();
    LG_cacheContextMenuSnapshot();
}
%end
