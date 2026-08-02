#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "NativeIOTrace.h"
#include "ArtemisStatic.h"

int main(int argc, char* argv[]) {
    @autoreleasepool {
        NSString* gameRoot = nil;
        BOOL fullscreen = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--fullscreen") == 0) {
                fullscreen = YES;
                continue;
            }
            if (argv[i][0] == '-') continue;
            NSString* candidate = [NSString stringWithUTF8String:argv[i]];
            BOOL isDirectory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDirectory]
                && isDirectory) {
                gameRoot = [candidate stringByStandardizingPath];
                break;
            }
        }

        // Match the iOS sample's lifecycle: Launch happens before the app
        // event loop and before Initialize.  It reads the game configuration
        // and PFS roots, so make the selected game directory the cwd first.
        if (gameRoot.length) {
            if (![[NSFileManager defaultManager] changeCurrentDirectoryPath:gameRoot]) {
                NSLog(@"FATAL: could not change working directory before ArtemisStatic::Launch: %@", gameRoot);
                return 2;
            }
            NSLog(@"Pre-launch working directory: %@", gameRoot);
            ArtemisSetGameRoot(gameRoot.fileSystemRepresentation);
        }
        // Match the iOS sample's no-option invocation. The selected game
        // directory is already the process cwd; passing it as an extra option
        // makes Artemis treat the path as a command-line setting instead of
        // the content root.
        char* engineArgv[] = { argv[0], nullptr };
        ArtemisStatic::Launch(1, engineArgv, nullptr);

        NSApplication* app = [NSApplication sharedApplication];
        if ([NSProcessInfo.processInfo.environment[@"YOGHOURT_DISPLAY_MODE"]
                isEqualToString:@"fullscreen"]) {
            fullscreen = YES;
        }
        AppDelegate* delegate = [[AppDelegate alloc] initWithGameRoot:gameRoot
                                                           fullscreen:fullscreen];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Artemis"];
        NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
        [menu addItem:appMenuItem];
        NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Artemis"];
        [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];
        [app setMainMenu:menu];

        [app run];
    }
    return 0;
}
