#pragma once

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
- (instancetype)initWithGameRoot:(NSString*)gameRoot
                       fullscreen:(BOOL)fullscreen;
@end
