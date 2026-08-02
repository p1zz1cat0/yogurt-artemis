#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, EAGLRenderingAPI) {
    kEAGLRenderingAPIOpenGLES1 = 1,
    kEAGLRenderingAPIOpenGLES2 = 2,
    kEAGLRenderingAPIOpenGLES3 = 3,
};

@protocol EAGLDrawable <NSObject>
@end

@interface EAGLContext : NSObject
- (instancetype)initWithAPI:(EAGLRenderingAPI)api;
- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharegroup:(void*)sharegroup;
+ (BOOL)setCurrentContext:(EAGLContext*)context;
+ (EAGLContext*)currentContext;
- (BOOL)presentRenderbuffer:(NSUInteger)target;
- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable;
- (void)registerEngineFramebuffer:(unsigned int)framebuffer
                     renderbuffer:(unsigned int)renderbuffer
                              size:(CGSize)size;
@property (class, readonly) EAGLContext* currentContext;
@end
#else
#error "EAGLContext requires Objective-C"
#endif
