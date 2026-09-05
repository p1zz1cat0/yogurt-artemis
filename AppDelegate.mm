#import "AppDelegate.h"

#import "YoghourtDockIcon.h"
#import "MetalGLView.h"
#import "UICompat.h"
#include "ArtemisStatic.h"

@interface ArtemisContainerView : NSView {
    NSView* _gameView;
}
@property(nonatomic, strong) NSView* gameView;
@end

@implementation ArtemisContainerView
- (void)layoutGameView {
    if (!self.gameView) return;
    NSRect available = self.bounds;
    const CGFloat aspect = 16.0 / 9.0;
    CGFloat width = available.size.width;
    CGFloat height = width / aspect;
    if (height > available.size.height) {
        height = available.size.height;
        width = height * aspect;
    }
    self.gameView.frame = NSMakeRect(
        floor((available.size.width - width) * 0.5),
        floor((available.size.height - height) * 0.5),
        floor(width),
        floor(height)
    );
}

- (void)setGameView:(NSView*)gameView {
    _gameView = gameView;
    [self layoutGameView];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutGameView];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layoutGameView];
}

- (void)layout {
    [super layout];
    [self layoutGameView];
}
@end

@implementation AppDelegate {
    NSWindow*    _window;
    MetalGLView* _view;
    NSString*    _gameRoot;
    BOOL         _fullscreen;
}

- (instancetype)initWithGameRoot:(NSString*)gameRoot
                       fullscreen:(BOOL)fullscreen {
    self = [super init];
    if (self) {
        _gameRoot = [gameRoot copy];
        _fullscreen = fullscreen;
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    NSLog(@"=== Artemis macOS: didFinishLaunching ===");

    // ArtemisStatic resolves root.pfs and system.ini relative to cwd. Select
    // the user game directory before the first (and only) Launch call.
    NSString* exePath = [[NSBundle mainBundle] executablePath];
    NSString* exeDir = [exePath stringByDeletingLastPathComponent];
    NSString* workingDirectory = _gameRoot.length ? _gameRoot : exeDir;
    if (![[NSFileManager defaultManager] changeCurrentDirectoryPath:workingDirectory]) {
        NSLog(@"FATAL: could not change working directory to %@", workingDirectory);
        [NSApp terminate:nil];
        return;
    }
    NSLog(@"Working directory: %@", workingDirectory);
    
    NSRect frame = NSMakeRect(0, 0, 1280, 720);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.delegate = self;
    NSString* gameTitle = NSProcessInfo.processInfo.environment[@"YOGHOURT_GAME_TITLE"];
    _window.title = gameTitle.length ? gameTitle : @"Artemis";
    NSString* iconPath = NSProcessInfo.processInfo.environment[@"YOGHOURT_GAME_ICON"];
    if (iconPath.length) {
        NSImage* icon = YoghourtLoadDockIcon(iconPath);
        if (icon) NSApp.applicationIconImage = icon;
    }
    [_window center];

    ArtemisContainerView* container = [[ArtemisContainerView alloc] initWithFrame:frame];
    container.autoresizesSubviews = YES;
    container.wantsLayer = YES;
    container.layer.backgroundColor = NSColor.blackColor.CGColor;
    _view = [[MetalGLView alloc] initWithFrame:frame];
    container.gameView = _view;
    [container addSubview:_view];
    [container layoutGameView];
    _window.contentView = container;

    [_window makeKeyAndOrderFront:nil];

    // CGpuRenderer is shared with the iOS build and discovers its drawable
    // through UIApplication.keyWindow.rootViewController.view.layer. Bind
    // that compatibility chain to the real AppKit window and CAMetalLayer.
    UIWindow* compatWindow = [[UIWindow alloc] initWithNativeWindow:_window];
    UIViewController* compatController = [[UIViewController alloc] init];
    [compatController setView:[[UIView alloc] initWithNativeView:_view]];
    [compatWindow setRootViewController:compatController];
    [[UIApplication sharedApplication] setArtemisKeyWindow:compatWindow];

    NSLog(@"=== Artemis macOS: starting animation ===");
    if (![_view startAnimation]) {
        NSLog(@"[Yoghourt] ERROR renderer initialization failed");
        std::fputs("[Yoghourt] ERROR renderer initialization failed\n", stderr);
        std::fflush(stderr);
        [NSApp terminate:nil];
        return;
    }
    NSString* sessionID = NSProcessInfo.processInfo.environment[@"YOGHOURT_SESSION_ID"];
    sessionID = sessionID.length ? sessionID.lowercaseString : @"unknown";
    NSLog(@"[Yoghourt] READY engine=artemis session=%@", sessionID);
    // EngineLauncher captures the child process' stdout/stderr pipes. NSLog is
    // routed to Unified Logging on current macOS and therefore cannot satisfy
    // the launch readiness rule by itself.
    std::fprintf(stdout, "[Yoghourt] READY engine=artemis session=%s\n", sessionID.UTF8String);
    std::fflush(stdout);

    [NSApp activateIgnoringOtherApps:YES];
    if (_fullscreen) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_window toggleFullScreen:nil];
        });
    }
}

- (void)windowWillEnterFullScreen:(NSNotification*)notification {
    // A titled macOS window keeps its titlebar layout region even after the
    // controls fade out. Without FullSizeContentView that becomes a black
    // strip above the 16:9 game view and shifts every AppKit mouse coordinate.
    // Extend the content only while in native fullscreen so windowed mode
    // keeps its normal titlebar and traffic lights.
    _window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    [_window.contentView setNeedsLayout:YES];
    [_window.contentView layoutSubtreeIfNeeded];
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification {
    [_window.contentView setNeedsLayout:YES];
    [_window.contentView layoutSubtreeIfNeeded];
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
    _window.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
    _window.titlebarAppearsTransparent = NO;
    _window.titleVisibility = NSWindowTitleVisible;
    [_window.contentView setNeedsLayout:YES];
    [_window.contentView layoutSubtreeIfNeeded];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    [_view stopAnimation];
    ArtemisStatic::Finalize();
}

- (void)applicationDidBecomeActive:(NSNotification*)notification {
    NSLog(@"=== Artemis macOS: became active ===");
    ArtemisStatic::SetAllSound(1);
}

- (void)applicationDidResignActive:(NSNotification*)notification {
    NSLog(@"=== Artemis macOS: resigned active ===");
    ArtemisStatic::SetAllSound(0);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

@end
