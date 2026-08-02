#pragma once

#ifdef __OBJC__

#import <Cocoa/Cocoa.h>

// UIFoundation on macOS contains a private class named UIFont. Keep the SDK
// compatibility class out of that namespace; the locked static archive is
// rewritten to the equal-length YGFont symbol before linking.
#define UIFont YGFont

// =============== Types ===============
typedef NSInteger UIInterfaceOrientation;
typedef NS_ENUM(NSInteger, UIAlertViewStyle) { UIAlertViewStyleDefault = 0, UIAlertViewStylePlainTextInput = 1 };

// =============== UIAlertView ===============
@interface UIAlertView : NSObject
- (instancetype)initWithTitle:(NSString*)title message:(NSString*)message
                     delegate:(id)delegate cancelButtonTitle:(NSString*)cancel
            otherButtonTitles:(NSString*)other, ...;
- (void)setAlertViewStyle:(UIAlertViewStyle)style;
- (void)show;
@property (nonatomic, weak) id delegate;
@property (nonatomic, readonly) NSInteger cancelButtonIndex;
@end

@protocol UIAlertViewDelegate <NSObject>
@optional
- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex;
@end

// =============== UIAlertController ===============
@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString*)title style:(NSInteger)style handler:(void(^)(UIAlertAction*))handler;
@property (nonatomic, readonly) NSString* title;
- (void(^)(UIAlertAction*))handlerBlock;
@end

@interface UIAlertController : NSObject
+ (instancetype)alertControllerWithTitle:(NSString*)title message:(NSString*)message preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction*)action;
- (void)addTextFieldWithConfigurationHandler:(void(^)(id textField))handler;
@property (nonatomic, readonly) NSArray* textFields;
@end

// =============== UIView (standalone wrapper) ===============
@interface UIView : NSObject
- (instancetype)initWithFrame:(NSRect)frame;
- (instancetype)initWithNativeView:(NSView*)nativeView;
- (void)addSubview:(UIView*)view;
- (void)removeFromSuperview;
- (void)setBackgroundColor:(NSColor*)color;
- (void)setMultipleTouchEnabled:(BOOL)enabled;
@property (nonatomic) NSRect frame;
@property (nonatomic) NSRect bounds;
@property (nonatomic, readonly) CALayer* layer;
@property (nonatomic, assign) id superview;
- (void)setTransform:(CGAffineTransform)t;
- (CGAffineTransform)transform;

// Native NSView accessor for AppKit integration
@property (nonatomic, readonly) NSView* nativeView;
@end

// =============== UIViewController ===============
@interface UIViewController : NSObject
- (instancetype)init;
- (void)presentViewController:(UIViewController*)vc animated:(BOOL)flag completion:(void(^)(void))block;
@property (nonatomic, strong) UIView* view;
@property (nonatomic, weak) NSWindow* nativeWindow;
@property (nonatomic, readonly) UIInterfaceOrientation interfaceOrientation;
@end

// =============== UIWindow ===============
@interface UIWindow : NSObject
- (instancetype)initWithFrame:(NSRect)frame;
- (instancetype)initWithNativeWindow:(NSWindow*)window;
- (void)makeKeyAndVisible;
- (void)setRootViewController:(UIViewController*)vc;
@property (nonatomic, readonly) UIViewController* rootViewController;
@property (nonatomic, assign) BOOL multipleTouchEnabled;
@property (nonatomic, readonly) NSWindow* nativeWindow;
@end

// =============== UIScreen ===============
@interface UIScreen : NSObject
+ (UIScreen*)mainScreen;
- (CGFloat)scale;
@property (nonatomic, readonly) NSRect bounds;
@end

// =============== UIDevice ===============
@interface UIDevice : NSObject
+ (UIDevice*)currentDevice;
@property (nonatomic, readonly) NSString* systemVersion;
@property (nonatomic, readonly) NSInteger orientation;
@end

// =============== UIApplication ===============
@interface UIApplication : NSObject
+ (UIApplication*)sharedApplication;
- (BOOL)openURL:(NSURL*)url;
- (void)setStatusBarHidden:(BOOL)hidden;
- (void)setNetworkActivityIndicatorVisible:(BOOL)visible;
@property (nonatomic, readonly) UIWindow* keyWindow;
@property (nonatomic) BOOL idleTimerDisabled;
- (void)setArtemisKeyWindow:(UIWindow*)window;
@end

// =============== UIColor ===============
@interface UIColor : NSObject
+ (UIColor*)whiteColor;
+ (UIColor*)systemBlueColor;
- (CGColorRef)CGColor;
@end

// =============== UIImage ===============
@interface UIImage : NSObject
+ (UIImage*)imageNamed:(NSString*)name;
- (NSImage*)nativeImage;
@end

// =============== UIFont ===============
@interface UIFont : NSObject
+ (UIFont*)systemFontOfSize:(CGFloat)size;
+ (UIFont*)fontWithName:(NSString*)name size:(CGFloat)size;
- (CGFloat)ascender;
- (CGFloat)lineHeight;
- (CGFloat)leading;
- (NSFont*)nativeFont;
@end

// =============== UITextField ===============
@interface UITextField : NSObject
- (instancetype)initWithFrame:(NSRect)frame;
- (BOOL)becomeFirstResponder;
- (BOOL)resignFirstResponder;
- (void)setBorderStyle:(NSInteger)style;
- (void)setFont:(UIFont*)font;
- (void)setText:(NSString*)text;
@property (nonatomic, copy) NSString* text;
@property (nonatomic, readonly) NSTextField* nativeTextField;
@end

// =============== NSString additions ===============
@interface NSString (ArtemisCompat)
- (CGSize)sizeWithFont:(UIFont*)font;
@end

#endif
