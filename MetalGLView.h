#pragma once

#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>

@interface MetalGLView : NSView

- (BOOL)startAnimation;
- (void)stopAnimation;

@end
