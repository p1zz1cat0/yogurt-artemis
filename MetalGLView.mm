#import "MetalGLView.h"
#import "EAGLContext.h"
#include "ArtemisStatic.h"
#define GL_APICALL
#define GL_APIENTRY
#include <GLES2/gl2.h>
#include <Metal/Metal.h>

@interface MetalGLView () {
    CAMetalLayer*    _metalLayer;
    CGSize           _renderSize;
    EAGLContext*     _context;
    NSTimer*         _frameTimer;
    BOOL             _initialized;
    BOOL             _running;
    std::vector<int>    _touchesX;
    std::vector<int>    _touchesY;
    std::vector<double> _touchesTime;
    BOOL             _touchActive;
}
- (void)drawFrame;
@end

@implementation MetalGLView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    self.wantsLayer = YES;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = NO;
    _metalLayer.opaque = YES;
    _metalLayer.contentsScale = 2.0;
    _renderSize = CGSizeMake(frameRect.size.width * 2.0, frameRect.size.height * 2.0);
    _metalLayer.drawableSize = _renderSize;
    self.layer = _metalLayer;

    _initialized = NO;
    _running = NO;
    _touchActive = NO;

    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (int)engineXForPoint:(NSPoint)point {
    CGFloat width = MAX(self.bounds.size.width, 1.0);
    return (int)llround(point.x * _renderSize.width / width);
}

- (int)engineYForPoint:(NSPoint)point {
    CGFloat height = MAX(self.bounds.size.height, 1.0);
    return (int)llround((height - point.y) * _renderSize.height / height);
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        _metalLayer.contentsScale = self.window.backingScaleFactor;
        _metalLayer.drawableSize = CGSizeMake(
            self.bounds.size.width * _metalLayer.contentsScale,
            self.bounds.size.height * _metalLayer.contentsScale
        );
    }
}

- (void)layout {
    [super layout];
    _metalLayer.drawableSize = CGSizeMake(
        self.bounds.size.width * _metalLayer.contentsScale,
        self.bounds.size.height * _metalLayer.contentsScale
    );
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    _metalLayer.drawableSize = CGSizeMake(
        newSize.width * _metalLayer.contentsScale,
        newSize.height * _metalLayer.contentsScale
    );
}

- (BOOL)startAnimation {
    if (_running) return YES;

    if (!_initialized) {
        // CGpuRenderer owns EAGLContext creation. Creating a bootstrap context
        // here gives ANGLE two unrelated FBO namespaces: the engine then
        // renders into one context while the host presents the other.
        ArtemisStatic::Initialize((__bridge void*)_metalLayer);

        _context = [EAGLContext currentContext];
        if (!_context || ![EAGLContext setCurrentContext:_context]) {
            NSLog(@"[Yoghourt] ERROR renderer initialization failed: Artemis did not create a drawable EAGLContext");
            return NO;
        }

        GLint framebuffer = 0, renderbuffer = 0, viewport[4] = {0, 0, 0, 0};
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
        glGetIntegerv(GL_VIEWPORT, viewport);
        const GLenum framebufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        NSLog(@"[gl] after Initialize fbo=%d rbo=%d viewport=%d,%d %dx%d status=0x%x error=0x%x vendor=%s renderer=%s",
              framebuffer, renderbuffer, viewport[0], viewport[1], viewport[2], viewport[3],
              framebufferStatus, glGetError(),
              glGetString(GL_VENDOR), glGetString(GL_RENDERER));
        if (framebuffer == 0 || framebufferStatus != GL_FRAMEBUFFER_COMPLETE) {
            NSLog(@"[Yoghourt] ERROR renderer initialization failed: incomplete framebuffer status=0x%x",
                  framebufferStatus);
            return NO;
        }
        _initialized = YES;
    }

    // Keep Execute on the same main thread that owns the EGL context.  The
    // original iOS host uses CADisplayLink on the main run loop; a
    // CVDisplayLink callback runs on a worker thread and leaves ANGLE with no
    // current context, producing an apparently valid but empty framebuffer.
    _frameTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                            target:self
                                          selector:@selector(frameTimerFired:)
                                          userInfo:nil
                                           repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_frameTimer forMode:NSRunLoopCommonModes];
    _running = YES;
    return YES;
}

- (void)stopAnimation {
    if (!_running) return;
    [_frameTimer invalidate];
    _frameTimer = nil;
    _running = NO;
}

- (void)frameTimerFired:(NSTimer*)timer {
    [self drawFrame];
}

- (void)drawFrame {
    if (!_initialized) return;
    [EAGLContext setCurrentContext:_context];

    @autoreleasepool {
        static int frameCount = 0;
        frameCount++;
        if (frameCount <= 3) {
            GLint framebuffer = 0, renderbuffer = 0, viewport[4] = {0, 0, 0, 0};
            glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
            glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
            glGetIntegerv(GL_VIEWPORT, viewport);
            NSLog(@"[gl] before Execute frame=%d fbo=%d rbo=%d viewport=%d,%d %dx%d status=0x%x error=0x%x",
                  frameCount, framebuffer, renderbuffer, viewport[0], viewport[1], viewport[2], viewport[3],
                  glCheckFramebufferStatus(GL_FRAMEBUFFER), glGetError());
        }
        const bool shouldStop = ArtemisStatic::Execute();
        if (frameCount <= 5 || frameCount % 120 == 0) {
            NSLog(@"Frame %d, Execute=%d", frameCount, shouldStop);
        }
        if (frameCount <= 3) {
            GLint framebuffer = 0, renderbuffer = 0, viewport[4] = {0, 0, 0, 0};
            GLint currentProgram = 0, scissorBox[4] = {0, 0, 0, 0};
            GLboolean colorMask[4] = {GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE};
            glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
            glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
            glGetIntegerv(GL_VIEWPORT, viewport);
            glGetIntegerv(GL_CURRENT_PROGRAM, &currentProgram);
            glGetIntegerv(GL_SCISSOR_BOX, scissorBox);
            glGetBooleanv(GL_COLOR_WRITEMASK, colorMask);
            const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            const GLenum error = glGetError();
            unsigned char pixel[4] = {0, 0, 0, 0};
            glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
            NSLog(@"[gl] after Execute frame=%d fbo=%d rbo=%d viewport=%d,%d %dx%d status=0x%x error=0x%x program=%d scissor=%d box=%d,%d %dx%d mask=%d%d%d%d pixel=%02x%02x%02x%02x",
                  frameCount, framebuffer, renderbuffer, viewport[0], viewport[1], viewport[2], viewport[3],
                  status, error, currentProgram, glIsEnabled(GL_SCISSOR_TEST), scissorBox[0], scissorBox[1],
                  scissorBox[2], scissorBox[3], colorMask[0], colorMask[1], colorMask[2], colorMask[3],
                  pixel[0], pixel[1], pixel[2], pixel[3]);
        }
    }
}

- (void)postTouchBegan:(NSEvent*)event {
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];

    _touchesX.clear(); _touchesY.clear(); _touchesTime.clear();
    _touchesX.push_back([self engineXForPoint:loc]);
    _touchesY.push_back([self engineYForPoint:loc]);
    _touchesTime.push_back([event timestamp]);
    _touchActive = YES;

    ArtemisStatic::TouchesBegan(_touchesX, _touchesY, _touchesTime, 1);
}

- (void)mouseDown:(NSEvent*)event { [self postTouchBegan:event]; }

- (void)mouseDragged:(NSEvent*)event {
    if (!_touchActive) return;
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];

    std::vector<int> prevX(_touchesX), prevY(_touchesY);
    _touchesX.clear(); _touchesY.clear(); _touchesTime.clear();
    _touchesX.push_back([self engineXForPoint:loc]);
    _touchesY.push_back([self engineYForPoint:loc]);
    _touchesTime.push_back([event timestamp]);

    ArtemisStatic::TouchesMoved(_touchesX, _touchesY, _touchesTime, prevX, prevY);
}

- (void)mouseUp:(NSEvent*)event {
    if (!_touchActive) return;
    NSPoint loc = [self convertPoint:[event locationInWindow] fromView:nil];

    _touchesX.clear(); _touchesY.clear(); _touchesTime.clear();
    _touchesX.push_back([self engineXForPoint:loc]);
    _touchesY.push_back([self engineYForPoint:loc]);
    _touchesTime.push_back([event timestamp]);

    ArtemisStatic::TouchesEnded(_touchesX, _touchesY, _touchesTime);
    _touchActive = NO;
}

- (void)dealloc {
    [self stopAnimation];
    _context = nil;
}

@end
