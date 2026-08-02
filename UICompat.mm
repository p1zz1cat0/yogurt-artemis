#import "UICompat.h"
#import <AppKit/AppKit.h>
#include <objc/message.h>
#include <cstdio>
#include <cstring>

// ============================================================
// UIAlertView
// ============================================================
@implementation UIAlertView {
    NSAlert* _alert;
    __weak id _delegate;
}
- (instancetype)initWithTitle:(NSString*)title message:(NSString*)message
                     delegate:(id)delegate cancelButtonTitle:(NSString*)cancel
            otherButtonTitles:(NSString*)other, ... {
    self = [super init];
    _alert = [[NSAlert alloc] init];
    _alert.messageText = title ?: @"";
    _alert.informativeText = message ?: @"";
    _delegate = delegate;
    if (cancel) [_alert addButtonWithTitle:cancel];
    if (other) {
        va_list args;
        va_start(args, other);
        [_alert addButtonWithTitle:other];
        NSString* btn; while ((btn = va_arg(args, NSString*))) [_alert addButtonWithTitle:btn];
        va_end(args);
    }
    return self;
}
- (void)setAlertViewStyle:(UIAlertViewStyle)style {}
- (void)show {
    NSModalResponse r = [_alert runModal];
    NSInteger idx = r - NSAlertFirstButtonReturn;
    if (_delegate && [_delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)])
        ((void(*)(id,SEL,id,NSInteger))objc_msgSend)(_delegate, @selector(alertView:clickedButtonAtIndex:), self, idx);
}
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)d { _delegate = d; }
- (NSInteger)cancelButtonIndex { return 0; }
@end

// ============================================================
// UIAlertAction
// ============================================================
@implementation UIAlertAction {
    NSString* _title;
    void(^_handler)(UIAlertAction*);
}
+ (instancetype)actionWithTitle:(NSString*)title style:(NSInteger)style handler:(void(^)(UIAlertAction*))handler {
    UIAlertAction* a = [[UIAlertAction alloc] init];
    a->_title = title;
    a->_handler = [handler copy];
    return a;
}
- (NSString*)title { return _title; }
- (void(^)(UIAlertAction*))handlerBlock { return _handler; }
@end

// ============================================================
// UIAlertController
// ============================================================
@implementation UIAlertController {
    NSMutableArray* _actions;
    NSMutableArray* _textFields;
}
+ (instancetype)alertControllerWithTitle:(NSString*)title message:(NSString*)message preferredStyle:(NSInteger)style {
    UIAlertController* a = [[UIAlertController alloc] init];
    a->_actions = [NSMutableArray array];
    a->_textFields = [NSMutableArray array];
    return a;
}
- (void)addAction:(UIAlertAction*)action { [_actions addObject:action]; }
- (void)addTextFieldWithConfigurationHandler:(void(^)(id))handler {
    NSTextField* tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,200,24)];
    if (handler) handler(tf);
    [_textFields addObject:tf];
}
- (NSArray*)textFields { return _textFields; }
@end

// ============================================================
// UIView
// ============================================================
@implementation UIView {
    NSView* _view;
    __weak UIView* _superview;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super init];
    _view = [[NSView alloc] initWithFrame:frame];
    return self;
}
- (instancetype)initWithNativeView:(NSView*)nativeView {
    self = [super init];
    _view = nativeView;
    return self;
}
- (NSView*)nativeView { return _view; }
- (void)addSubview:(UIView*)v { [_view addSubview:v.nativeView]; v->_superview = self; }
- (void)removeFromSuperview { [_view removeFromSuperview]; _superview = nil; }
- (void)setBackgroundColor:(NSColor*)c { _view.wantsLayer = YES; _view.layer.backgroundColor = [c CGColor]; }
- (void)setMultipleTouchEnabled:(BOOL)e {}
- (NSRect)frame { return _view.frame; }
- (void)setFrame:(NSRect)f { _view.frame = f; }
- (NSRect)bounds { return _view.bounds; }
- (CALayer*)layer { return _view.layer; }
- (id)superview { return _superview; }
- (void)setSuperview:(id)s { _superview = s; }
- (CGAffineTransform)transform { CGAffineTransform t; memset(&t,0,sizeof(t)); t.a = t.d = 1; return t; }
- (void)setTransform:(CGAffineTransform)t {}
@end

// ============================================================
// UIViewController
// ============================================================
@implementation UIViewController {
    UIView* _view;
    __weak NSWindow* _nativeWindow;
}
- (instancetype)init { self = [super init]; _view = [[UIView alloc] initWithFrame:NSZeroRect]; return self; }
- (UIView*)view { return _view; }
- (void)setView:(UIView*)v { _view = v; }
- (UIInterfaceOrientation)interfaceOrientation { return 3; }
- (void)presentViewController:(UIViewController*)vc animated:(BOOL)flag completion:(void(^)(void))block {
    if (block) block();
}
@end

// ============================================================
// UIWindow
// ============================================================
@implementation UIWindow {
    NSWindow* _w;
    UIViewController* _rootVC;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super init];
    _w = [[NSWindow alloc] initWithContentRect:frame
                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                       backing:NSBackingStoreBuffered defer:NO];
    _w.title = @"Artemis Engine";
    return self;
}
- (instancetype)initWithNativeWindow:(NSWindow*)window {
    self = [super init];
    _w = window;
    return self;
}
- (NSWindow*)nativeWindow { return _w; }
- (void)makeKeyAndVisible { [_w makeKeyAndOrderFront:nil]; }
- (void)setRootViewController:(UIViewController*)vc {
    _rootVC = vc;
    // The AppKit host owns a letterboxing container. CGpuRenderer only needs
    // this compatibility relationship for drawable discovery; replacing the
    // native content view here would discard the container on fullscreen.
    if (!_w.contentView) {
        _w.contentView = vc.view.nativeView;
    }
}
- (UIViewController*)rootViewController { return _rootVC; }
@end

// ============================================================
// UIScreen
// ============================================================
@implementation UIScreen
+ (UIScreen*)mainScreen { static UIScreen* s; if(!s)s=[[UIScreen alloc]init]; return s; }
- (CGFloat)scale { return [NSScreen mainScreen].backingScaleFactor; }
- (NSRect)bounds { return [NSScreen mainScreen].frame; }
@end

// ============================================================
// UIDevice
// ============================================================
@implementation UIDevice
+ (UIDevice*)currentDevice { static UIDevice* d; if(!d)d=[[UIDevice alloc]init]; return d; }
- (NSString*)systemVersion { return @"15.0"; }
- (NSInteger)orientation { return 3; }
@end

// ============================================================
// UIApplication
// ============================================================
@implementation UIApplication
+ (UIApplication*)sharedApplication { static UIApplication* a; if(!a)a=[[UIApplication alloc]init]; return a; }
- (BOOL)openURL:(NSURL*)url { return [[NSWorkspace sharedWorkspace] openURL:url]; }
- (void)setStatusBarHidden:(BOOL)h {}
- (void)setNetworkActivityIndicatorVisible:(BOOL)v {}
static UIWindow* s_artemisKeyWindow = nil;
- (UIWindow*)keyWindow {
    static BOOL reported = NO;
    if (!reported) {
        reported = YES;
        NSLog(@"[compat] UIApplication.keyWindow -> %@", s_artemisKeyWindow);
    }
    return s_artemisKeyWindow;
}
- (void)setArtemisKeyWindow:(UIWindow*)window { s_artemisKeyWindow = window; }
@end

// ============================================================
// UIColor
// ============================================================
@implementation UIColor {
    NSColor* _nsColor;
}
+ (UIColor*)whiteColor     { UIColor* c = [[UIColor alloc] init]; c->_nsColor = [NSColor whiteColor]; return c; }
+ (UIColor*)systemBlueColor { UIColor* c = [[UIColor alloc] init]; c->_nsColor = [NSColor systemBlueColor]; return c; }
- (CGColorRef)CGColor      { return [_nsColor CGColor]; }
@end

// ============================================================
// UIImage
// ============================================================
@implementation UIImage {
    NSImage* _img;
}
+ (UIImage*)imageNamed:(NSString*)name {
    UIImage* img = [[UIImage alloc] init];
    NSString* path = [[NSBundle mainBundle] pathForResource:name ofType:nil];
    img->_img = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    return img;
}
- (NSImage*)nativeImage { return _img; }
@end

// ============================================================
// UIFont
// ============================================================
@implementation UIFont {
    NSFont* _font;
}
+ (UIFont*)systemFontOfSize:(CGFloat)size { UIFont* f = [[UIFont alloc] init]; f->_font = [NSFont systemFontOfSize:size]; return f; }
+ (UIFont*)fontWithName:(NSString*)name size:(CGFloat)size { UIFont* f = [[UIFont alloc] init]; f->_font = [NSFont fontWithName:name size:size]; return f; }
- (CGFloat)ascender   { return [_font ascender]; }
- (CGFloat)lineHeight { return [_font ascender] + fabs([_font descender]) + [_font leading]; }
- (CGFloat)leading    { return [_font leading]; }
- (NSFont*)nativeFont  { return _font; }
@end

// ============================================================
// UITextField
// ============================================================
@implementation UITextField {
    NSTextField* _tf;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super init];
    _tf = [[NSTextField alloc] initWithFrame:frame];
    return self;
}
- (NSTextField*)nativeTextField { return _tf; }
- (BOOL)becomeFirstResponder { return [_tf becomeFirstResponder]; }
- (BOOL)resignFirstResponder  { return [_tf resignFirstResponder]; }
- (void)setBorderStyle:(NSInteger)s {}
- (void)setFont:(UIFont*)f   { _tf.font = [f nativeFont]; }
- (void)setText:(NSString*)t { _tf.stringValue = t ?: @""; }
- (NSString*)text             { return _tf.stringValue; }
@end

// ============================================================
// NSString additions
// ============================================================
@implementation NSString (ArtemisCompat)
- (CGSize)sizeWithFont:(UIFont*)f {
    NSDictionary* attrs = @{NSFontAttributeName: [f nativeFont]};
    return [self sizeWithAttributes:attrs];
}
@end
