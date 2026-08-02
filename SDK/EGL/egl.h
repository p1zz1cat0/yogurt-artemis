#ifndef __egl_h_
#define __egl_h_

#include "eglplatform.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef EGLDisplay (*PFNEGLGETDISPLAYPROC)(EGLNativeDisplayType display_id);
typedef EGLBoolean (*PFNEGLINITIALIZEPROC)(EGLDisplay dpy, EGLint *major, EGLint *minor);
typedef EGLBoolean (*PFNEGLCHOOSECONFIGPROC)(EGLDisplay dpy, const EGLint *attrib_list, EGLConfig *configs, EGLint config_size, EGLint *num_config);
typedef EGLContext (*PFNEGLCREATECONTEXTPROC)(EGLDisplay dpy, EGLConfig config, EGLContext share_context, const EGLint *attrib_list);
typedef EGLSurface (*PFNEGLCREATEWINDOWSURFACEPROC)(EGLDisplay dpy, EGLConfig config, EGLNativeWindowType win, const EGLint *attrib_list);
typedef EGLSurface (*PFNEGLCREATEPBUFFERSURFACEPROC)(EGLDisplay dpy, EGLConfig config, const EGLint *attrib_list);
typedef EGLBoolean (*PFNEGLMAKECURRENTPROC)(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx);
typedef EGLBoolean (*PFNEGLSWAPBUFFERSPROC)(EGLDisplay dpy, EGLSurface surface);
typedef EGLContext (*PFNEGLGETCURRENTCONTEXTPROC)(void);
typedef EGLDisplay (*PFNEGLGETCURRENTDISPLAYPROC)(void);
typedef EGLBoolean (*PFNEGLDESTROYCONTEXTPROC)(EGLDisplay dpy, EGLContext ctx);
typedef EGLBoolean (*PFNEGLDESTROYSURFACEPROC)(EGLDisplay dpy, EGLSurface surface);
typedef EGLBoolean (*PFNEGLTERMINATEPROC)(EGLDisplay dpy);
typedef const char* (*PFNEGLQUERYSTRINGPROC)(EGLDisplay dpy, EGLint name);
typedef void* (*PFNEGLGETPROCADDRESSPROC)(const char *procname);

#define EGL_SUCCESS             0x3000
#define EGL_NOT_INITIALIZED     0x3001
#define EGL_BAD_ACCESS          0x3002
#define EGL_BAD_ALLOC           0x3003
#define EGL_BAD_ATTRIBUTE       0x3004
#define EGL_BAD_CONFIG          0x3005
#define EGL_BAD_CONTEXT         0x3006
#define EGL_BAD_CURRENT_SURFACE 0x3007
#define EGL_BAD_DISPLAY         0x3008
#define EGL_BAD_MATCH           0x3009
#define EGL_BAD_NATIVE_PIXMAP   0x300A
#define EGL_BAD_NATIVE_WINDOW   0x300B
#define EGL_BAD_PARAMETER       0x300C
#define EGL_BAD_SURFACE         0x300D
#define EGL_CONTEXT_LOST        0x300E

#define EGL_BUFFER_SIZE         0x3020
#define EGL_ALPHA_SIZE          0x3021
#define EGL_BLUE_SIZE           0x3022
#define EGL_GREEN_SIZE          0x3023
#define EGL_RED_SIZE            0x3024
#define EGL_DEPTH_SIZE          0x3025
#define EGL_STENCIL_SIZE        0x3026
#define EGL_CONFIG_CAVEAT       0x3027
#define EGL_CONFIG_ID           0x3028
#define EGL_LEVEL               0x3029
#define EGL_MAX_PBUFFER_HEIGHT  0x302A
#define EGL_MAX_PBUFFER_PIXELS  0x302B
#define EGL_MAX_PBUFFER_WIDTH   0x302C
#define EGL_NATIVE_RENDERABLE   0x302D
#define EGL_NATIVE_VISUAL_ID    0x302E
#define EGL_NATIVE_VISUAL_TYPE  0x302F
#define EGL_SAMPLES             0x3031
#define EGL_SAMPLE_BUFFERS      0x3032
#define EGL_SURFACE_TYPE        0x3033
#define EGL_TRANSPARENT_TYPE    0x3034
#define EGL_TRANSPARENT_BLUE_VALUE 0x3035
#define EGL_TRANSPARENT_GREEN_VALUE 0x3036
#define EGL_TRANSPARENT_RED_VALUE 0x3037
#define EGL_NONE                0x3038
#define EGL_BIND_TO_TEXTURE_RGB 0x3039
#define EGL_BIND_TO_TEXTURE_RGBA 0x303A
#define EGL_MIN_SWAP_INTERVAL   0x303B
#define EGL_MAX_SWAP_INTERVAL   0x303C

#define EGL_RENDERABLE_TYPE     0x3040
#define EGL_CONFORMANT          0x3042
#define EGL_OPENGL_ES_BIT       0x0001
#define EGL_OPENGL_ES2_BIT      0x0004
#define EGL_WINDOW_BIT          0x0004
#define EGL_PBUFFER_BIT         0x0001

#define EGL_COLOR_BUFFER_TYPE   0x303F
#define EGL_RGB_BUFFER          0x308E
#define EGL_LUMINANCE_BUFFER    0x308F

#define EGL_VENDOR              0x3053
#define EGL_VERSION             0x3054
#define EGL_EXTENSIONS          0x3055
#define EGL_CLIENT_APIS         0x308D

#define EGL_HEIGHT              0x3056
#define EGL_WIDTH               0x3057

#define EGL_CONTEXT_CLIENT_VERSION 0x3098

#ifdef __cplusplus
}
#endif

#endif
