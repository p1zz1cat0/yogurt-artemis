#ifndef __eglplatform_h_
#define __eglplatform_h_

#include <stdint.h>

#ifdef __OBJC__
@class CAMetalLayer;
#else
typedef struct objc_object CAMetalLayer;
#endif

typedef void* EGLNativeDisplayType;
typedef CAMetalLayer* EGLNativeWindowType;
typedef uint32_t EGLNativePixmapType;

typedef int32_t EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef intptr_t EGLAttrib;
typedef void* EGLDisplay;
typedef void* EGLConfig;
typedef void* EGLSurface;
typedef void* EGLContext;
typedef void* EGLImage;
typedef void* EGLClientBuffer;
typedef void (*__eglMustCastToProperFunctionPointerType)(void);

#define EGL_DEFAULT_DISPLAY ((EGLNativeDisplayType)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_SURFACE ((EGLSurface)0)
#define EGL_FALSE 0
#define EGL_TRUE 1

#endif
