#pragma once

#include "egl.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef void *EGLSync;
typedef void *EGLDeviceEXT;

#define EGL_NO_SYNC ((EGLSync)0)
#define EGL_DEVICE_EXT 0x322C
#define EGL_SYNC_CONDITION 0x30F8

typedef EGLSync (*PFNEGLCREATESYNCPROC)(EGLDisplay, EGLenum, const EGLAttrib *);
typedef EGLBoolean (*PFNEGLDESTROYSYNCPROC)(EGLDisplay, EGLSync);
typedef EGLBoolean (*PFNEGLWAITSYNCPROC)(EGLDisplay, EGLSync, EGLint);
typedef EGLBoolean (*PFNEGLQUERYDISPLAYATTRIBEXTPROC)(EGLDisplay, EGLint, EGLAttrib *);
typedef EGLBoolean (*PFNEGLQUERYDEVICEATTRIBEXTPROC)(EGLDeviceEXT, EGLint, EGLAttrib *);
typedef const char *(*PFNEGLQUERYDEVICESTRINGEXTPROC)(EGLDeviceEXT, EGLint);
typedef EGLDisplay (*PFNEGLGETPLATFORMDISPLAYEXTPROC)(EGLenum, void *, const EGLint *);

const char *eglQueryString(EGLDisplay display, EGLint name);
EGLSurface eglCreatePbufferFromClientBuffer(
    EGLDisplay display,
    EGLenum bufferType,
    EGLClientBuffer buffer,
    EGLConfig config,
    const EGLint *attributes
);
EGLBoolean eglDestroySurface(EGLDisplay display, EGLSurface surface);
__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name);

#ifdef __cplusplus
}
#endif
