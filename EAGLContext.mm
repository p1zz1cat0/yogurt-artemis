#import "EAGLContext.h"
#include "NativeIOTrace.h"
#include <IOSurfaceRing.h>
#include <IOSurfaceRingComponentTest.h>
#include <YoghourtSpatialPresenter.h>
#define GL_APICALL
#define GL_APIENTRY
#include <GLES2/gl2.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#include <cstdlib>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <algorithm>
#include <vector>

// Used only by --renderer-self-test to inspect the drawable actually acquired
// by the production Presenter. It does not replace the presentation path.
@interface ArtemisSelfTestMetalLayer : CAMetalLayer
@property(nonatomic, strong) id<MTLTexture> submittedTexture;
@end
@implementation ArtemisSelfTestMetalLayer
- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> drawable = [super nextDrawable];
    self.submittedTexture = drawable.texture;
    return drawable;
}
@end

#ifndef GL_RGBA8_OES
#define GL_RGBA8_OES 0x8058
#endif

static EGLDisplay  s_display   = EGL_NO_DISPLAY;
static EGLConfig   s_config    = nullptr;
static EGLContext  s_shareCtx  = EGL_NO_CONTEXT;
static EGLSurface  s_windowSurface = EGL_NO_SURFACE;  // shared CAMetalLayer surface
static GLuint      s_engineFramebuffer = 0;
static GLuint      s_engineRenderbuffer = 0;
static GLsizei     s_engineWidth = 0;
static GLsizei     s_engineHeight = 0;
static id<MTLDevice> s_metalDevice = nil;
static id<MTLCommandQueue> s_spatialQueue = nil;
// Store an unretained opaque pointer: ARC does not permit a strong Objective-C
// object in a C thread-local slot. EAGLContext is owned by its view.
static __thread void* s_currentContext = nullptr;

// Function pointers — match exact names from libEGL.dylib
static PFNEGLGETDISPLAYPROC           eglGetDisplay_ptr;
static PFNEGLGETPLATFORMDISPLAYEXTPROC eglGetPlatformDisplayEXT_ptr;
static PFNEGLINITIALIZEPROC           eglInitialize_ptr;
static PFNEGLQUERYSTRINGPROC          eglQueryString_ptr;
static PFNEGLQUERYDISPLAYATTRIBEXTPROC eglQueryDisplayAttribEXT_ptr;
static PFNEGLQUERYDEVICEATTRIBEXTPROC eglQueryDeviceAttribEXT_ptr;
static PFNEGLQUERYDEVICESTRINGEXTPROC eglQueryDeviceStringEXT_ptr;
static PFNEGLCHOOSECONFIGPROC         eglChooseConfig_ptr;
static PFNEGLCREATECONTEXTPROC        eglCreateContext_ptr;
static PFNEGLCREATEWINDOWSURFACEPROC  eglCreateWindowSurface_ptr;
static PFNEGLCREATEPBUFFERSURFACEPROC eglCreatePbufferSurface_ptr;
static PFNEGLMAKECURRENTPROC          eglMakeCurrent_ptr;
static PFNEGLSWAPBUFFERSPROC          eglSwapBuffers_ptr;
static PFNEGLGETCURRENTCONTEXTPROC    eglGetCurrentContext_ptr;
static PFNEGLGETCURRENTDISPLAYPROC    eglGetCurrentDisplay_ptr;
typedef EGLSurface (*PFNEGLGETCURRENTSURFACEPROC)(EGLint);
static PFNEGLGETCURRENTSURFACEPROC    eglGetCurrentSurface_ptr;
static PFNEGLDESTROYCONTEXTPROC       eglDestroyContext_ptr;
static PFNEGLDESTROYSURFACEPROC       eglDestroySurface_ptr;
static PFNEGLTERMINATEPROC            eglTerminate_ptr;
typedef EGLint (*PFNEGLGETERRORPROC)(void);
static PFNEGLGETERRORPROC             eglGetError_ptr;
static PFNEGLCREATESYNCPROC           eglCreateSync_ptr;
static PFNEGLDESTROYSYNCPROC          eglDestroySync_ptr;
static PFNEGLWAITSYNCPROC             eglWaitSync_ptr;
static PFNEGLCOPYMETALSHAREDEVENTANGLEPROC eglCopyMetalSharedEventANGLE_ptr;
typedef void (*PFNGLBLITFRAMEBUFFERANGLEPROC)(GLint, GLint, GLint, GLint,
                                              GLint, GLint, GLint, GLint,
                                              GLbitfield, GLenum);
static PFNGLBLITFRAMEBUFFERANGLEPROC  glBlitFramebufferANGLE_ptr;
static PFNGLBLITFRAMEBUFFERANGLEPROC  glBlitFramebuffer_ptr;
static GLuint s_presentTexture = 0;
static GLsizei s_presentTextureWidth = 0;
static GLsizei s_presentTextureHeight = 0;
static GLuint s_presentProgram = 0;
static GLint s_presentPosition = -1;
static GLint s_presentSampler = -1;

// GL_ANGLE_framebuffer_blit is exposed by the bundled ANGLE GLES library but
// the small compatibility header in this project intentionally only contains
// GLES2 core declarations.
#ifndef GL_READ_FRAMEBUFFER_ANGLE
#define GL_READ_FRAMEBUFFER_ANGLE 0x8CA8
#define GL_DRAW_FRAMEBUFFER_ANGLE 0x8CA9
#endif
#ifndef EGL_DRAW
#define EGL_DRAW 0x3059
#define EGL_READ 0x305A
#endif

static void* s_eglHandle = nullptr;
static bool s_testForceStateRestoreFailure = false;

static yoghourt_spatial::ScalerMode spatialScalerMode() {
    const char* value = getenv("YOGHOURT_SPATIAL_SCALER");
    if (!value || !value[0]) {
        value = getenv("YOGHOURT_ARTEMIS_SPATIAL_SCALER");
    }
    if (value && strcmp(value, "cunny") == 0) {
        return yoghourt_spatial::ScalerMode::cuNNy;
    }
    if (value && strcmp(value, "cunny+metalfx") == 0) {
        return yoghourt_spatial::ScalerMode::cuNNyPlusMetalFX;
    }
    return yoghourt_spatial::ScalerMode::metalFX;
}

static bool spatialPresentationRequested() {
    const char* value = getenv("YOGHOURT_SPATIAL_SCALER");
    if (!value || !value[0]) {
        value = getenv("YOGHOURT_ARTEMIS_SPATIAL_SCALER");
    }
    return value && value[0] && strcmp(value, "0") != 0;
}

static bool rendererDebugEnabled() {
    const char *value = getenv("YOGHOURT_ARTEMIS_RENDERER_DEBUG");
    return value && strcmp(value, "1") == 0;
}

static const char* findEGLPath() {
    static const char* paths[] = {
        "libs/libEGL.dylib",
        "../libs/libEGL.dylib",
        "./libEGL.dylib",
        "Frameworks/libEGL.dylib",       // inside .app bundle
        "../Frameworks/libEGL.dylib",     // in build dir
        nullptr
    };
    for (int i = 0; paths[i]; i++) {
        void* h = dlopen(paths[i], RTLD_LAZY | RTLD_NOLOAD);
        if (h) { dlclose(h); return paths[i]; }
        h = dlopen(paths[i], RTLD_LAZY);
        if (h) { dlclose(h); return paths[i]; }
    }
    return nullptr;
}

static bool loadEGL() {
    if (s_eglHandle) return true;

    const char* path = findEGLPath();
    if (!path) {
        // Try with full bundle path
        NSString* bundlePath = [[NSBundle mainBundle] privateFrameworksPath];
        if (bundlePath) {
            path = [[bundlePath stringByAppendingPathComponent:@"libEGL.dylib"] UTF8String];
        }
    }

    s_eglHandle = dlopen(path, RTLD_LAZY);
    if (!s_eglHandle) {
        fprintf(stderr, "FATAL: Cannot load libEGL.dylib. %s\n", dlerror());
        fprintf(stderr, "Tried paths relative to cwd. Ensure libEGL.dylib is next to the executable or in Frameworks/\n");
        return false;
    }

    #define BIND(fn) fn##_ptr = (decltype(fn##_ptr))dlsym(s_eglHandle, #fn); \
                      if (!fn##_ptr) { fprintf(stderr, "EGL: missing %s\n", #fn); return false; }

    BIND(eglGetDisplay);
    BIND(eglGetPlatformDisplayEXT);
    BIND(eglInitialize);
    BIND(eglQueryString);
    BIND(eglQueryDisplayAttribEXT);
    BIND(eglQueryDeviceAttribEXT);
    BIND(eglQueryDeviceStringEXT);
    BIND(eglChooseConfig);
    BIND(eglCreateContext);
    BIND(eglCreateWindowSurface);
    BIND(eglCreatePbufferSurface);
    BIND(eglMakeCurrent);
    BIND(eglSwapBuffers);
    BIND(eglGetCurrentContext);
    BIND(eglGetCurrentDisplay);
    BIND(eglGetCurrentSurface);
    BIND(eglDestroyContext);
    BIND(eglDestroySurface);
    BIND(eglTerminate);
    BIND(eglGetError);
    BIND(eglCreateSync);
    BIND(eglDestroySync);
    BIND(eglWaitSync);
    BIND(eglCopyMetalSharedEventANGLE);
    #undef BIND

    void* gles = dlopen("@executable_path/../Frameworks/libGLESv2.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (!gles) gles = dlopen("libs/libGLESv2.dylib", RTLD_LAZY | RTLD_NOLOAD);
    if (gles) {
        glBlitFramebuffer_ptr = (PFNGLBLITFRAMEBUFFERANGLEPROC)dlsym(gles, "glBlitFramebuffer");
        glBlitFramebufferANGLE_ptr = (PFNGLBLITFRAMEBUFFERANGLEPROC)dlsym(gles, "glBlitFramebufferANGLE");
        dlclose(gles);
    }
    if (glBlitFramebufferANGLE_ptr) {
        NSLog(@"[compat] ANGLE framebuffer blit available");
    } else {
        NSLog(@"[compat] ANGLE framebuffer blit unavailable; presenting default surface only");
    }

    return true;
}

static bool initEGL() {
    static bool attempted = false;
    static bool succeeded = false;
    if (attempted) return succeeded;
    attempted = true;

    if (!loadEGL()) return false;

    const char *clientExtensions = eglQueryString_ptr(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    if (!clientExtensions || !strstr(clientExtensions, "EGL_ANGLE_platform_angle_metal")) {
        fprintf(stderr, "EGL: ANGLE Metal platform unavailable\n");
        return false;
    }
    const EGLint displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE,
    };
    s_display = eglGetPlatformDisplayEXT_ptr(
        EGL_PLATFORM_ANGLE_ANGLE,
        EGL_DEFAULT_DISPLAY,
        displayAttributes
    );
    if (s_display == EGL_NO_DISPLAY) {
        fprintf(stderr, "EGL: no display\n");
        return false;
    }

    EGLint major, minor;
    if (!eglInitialize_ptr(s_display, &major, &minor)) {
        fprintf(stderr, "EGL: init failed\n");
        return false;
    }
    printf("EGL %d.%d initialized\n", major, minor);

    const char *displayExtensions = eglQueryString_ptr(s_display, EGL_EXTENSIONS);
    if (!displayExtensions ||
        !strstr(displayExtensions, "EGL_ANGLE_iosurface_client_buffer") ||
        !strstr(displayExtensions, "EGL_ANGLE_metal_shared_event_sync")) {
        fprintf(stderr, "EGL: required ANGLE Metal IOSurface/shared-event extensions unavailable\n");
        return false;
    }
    EGLAttrib deviceAttribute = 0;
    EGLAttrib metalAttribute = 0;
    if (!eglQueryDisplayAttribEXT_ptr(s_display, EGL_DEVICE_EXT, &deviceAttribute)) {
        fprintf(stderr, "EGL: could not query ANGLE device\n");
        return false;
    }
    EGLDeviceEXT eglDevice = reinterpret_cast<EGLDeviceEXT>(deviceAttribute);
    const char *deviceExtensions = eglQueryDeviceStringEXT_ptr(eglDevice, EGL_EXTENSIONS);
    if (!deviceExtensions || !strstr(deviceExtensions, "EGL_ANGLE_device_metal") ||
        !eglQueryDeviceAttribEXT_ptr(eglDevice, EGL_METAL_DEVICE_ANGLE, &metalAttribute)) {
        fprintf(stderr, "EGL: could not query ANGLE Metal device\n");
        return false;
    }
    s_metalDevice = (__bridge id<MTLDevice>)(reinterpret_cast<void *>(metalAttribute));
    s_spatialQueue = [s_metalDevice newCommandQueue];
    if (!s_metalDevice || !s_spatialQueue) {
        fprintf(stderr, "EGL: ANGLE Metal device or SpatialPresenter queue unavailable\n");
        return false;
    }

    EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_STENCIL_SIZE, 8,
        EGL_NONE
    };

    EGLint numConfigs;
    if (!eglChooseConfig_ptr(s_display, attrs, &s_config, 1, &numConfigs) || numConfigs == 0) {
        fprintf(stderr, "EGL: no config found\n");
        return false;
    }

    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    s_shareCtx = eglCreateContext_ptr(s_display, s_config, EGL_NO_CONTEXT, ctxAttrs);
    if (s_shareCtx == EGL_NO_CONTEXT) {
        fprintf(stderr, "EGL: share context creation failed\n");
        return false;
    }
    printf("EGL: share context created\n");
    succeeded = true;
    return true;
}

static bool ensurePresentationProgram() {
    if (s_presentProgram != 0) return true;
    const char* vertexSource =
        "attribute vec2 position;"
        "varying vec2 textureCoordinate;"
        "void main(){"
        "gl_Position=vec4(position,0.0,1.0);"
        "textureCoordinate=(position+1.0)*0.5;"
        "}";
    const char* fragmentSource =
        "precision mediump float;"
        "varying vec2 textureCoordinate;"
        "uniform sampler2D surface;"
        "void main(){gl_FragColor=texture2D(surface,textureCoordinate);}";
    GLuint vertex = glCreateShader(GL_VERTEX_SHADER);
    GLuint fragment = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(vertex, 1, &vertexSource, nullptr);
    glShaderSource(fragment, 1, &fragmentSource, nullptr);
    glCompileShader(vertex);
    glCompileShader(fragment);
    GLint vertexOK = 0, fragmentOK = 0;
    glGetShaderiv(vertex, GL_COMPILE_STATUS, &vertexOK);
    glGetShaderiv(fragment, GL_COMPILE_STATUS, &fragmentOK);
    if (!vertexOK || !fragmentOK) return false;
    s_presentProgram = glCreateProgram();
    glAttachShader(s_presentProgram, vertex);
    glAttachShader(s_presentProgram, fragment);
    glLinkProgram(s_presentProgram);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(s_presentProgram, GL_LINK_STATUS, &linked);
    if (!linked) return false;
    s_presentPosition = glGetAttribLocation(s_presentProgram, "position");
    s_presentSampler = glGetUniformLocation(s_presentProgram, "surface");
    glGenTextures(1, &s_presentTexture);
    return s_presentTexture != 0;
}

static bool copyFramebufferToWindow(
    GLuint sourceFramebuffer,
    GLsizei sourceWidth,
    GLsizei sourceHeight,
    GLsizei targetWidth,
    GLsizei targetHeight
) {
    if (!ensurePresentationProgram()) return false;

    GLint previousFramebuffer = 0;
    GLint previousRenderbuffer = 0;
    GLint previousProgram = 0;
    GLint previousActiveTexture = 0;
    GLint previousTexture0 = 0;
    GLint previousArrayBuffer = 0;
    GLint previousViewport[4] = {0, 0, 0, 0};
    GLboolean previousColorMask[4] = {
        GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE
    };
    const GLboolean blendWasEnabled = glIsEnabled(GL_BLEND);
    const GLboolean depthWasEnabled = glIsEnabled(GL_DEPTH_TEST);
    const GLboolean stencilWasEnabled = glIsEnabled(GL_STENCIL_TEST);
    const GLboolean scissorWasEnabled = glIsEnabled(GL_SCISSOR_TEST);
    GLint previousPositionEnabled = GL_FALSE;
    GLint previousPositionSize = 4;
    GLint previousPositionStride = 0;
    GLint previousPositionType = GL_FLOAT;
    GLint previousPositionNormalized = GL_FALSE;
    GLint previousPositionBuffer = 0;
    void* previousPositionPointer = nullptr;

    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &previousRenderbuffer);
    glGetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &previousArrayBuffer);
    glGetIntegerv(GL_VIEWPORT, previousViewport);
    glGetBooleanv(GL_COLOR_WRITEMASK, previousColorMask);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture0);
    if (s_presentPosition >= 0) {
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_ENABLED,
            &previousPositionEnabled
        );
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_SIZE,
            &previousPositionSize
        );
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_STRIDE,
            &previousPositionStride
        );
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_TYPE,
            &previousPositionType
        );
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_NORMALIZED,
            &previousPositionNormalized
        );
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING,
            &previousPositionBuffer
        );
        glGetVertexAttribPointerv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_POINTER,
            &previousPositionPointer
        );
    }

    const auto restoreState = [&]() {
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previousFramebuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)previousRenderbuffer);
        glUseProgram((GLuint)previousProgram);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, (GLuint)previousTexture0);
        if (s_presentPosition >= 0) {
            glBindBuffer(
                GL_ARRAY_BUFFER,
                (GLuint)previousPositionBuffer
            );
            glVertexAttribPointer(
                (GLuint)s_presentPosition,
                previousPositionSize,
                (GLenum)previousPositionType,
                (GLboolean)previousPositionNormalized,
                previousPositionStride,
                previousPositionPointer
            );
            if (previousPositionEnabled) {
                glEnableVertexAttribArray((GLuint)s_presentPosition);
            } else {
                glDisableVertexAttribArray((GLuint)s_presentPosition);
            }
        }
        glBindBuffer(GL_ARRAY_BUFFER, (GLuint)previousArrayBuffer);
        glActiveTexture((GLenum)previousActiveTexture);
        glViewport(
            previousViewport[0],
            previousViewport[1],
            previousViewport[2],
            previousViewport[3]
        );
        glColorMask(
            previousColorMask[0],
            previousColorMask[1],
            previousColorMask[2],
            previousColorMask[3]
        );
        blendWasEnabled ? glEnable(GL_BLEND) : glDisable(GL_BLEND);
        depthWasEnabled ? glEnable(GL_DEPTH_TEST) : glDisable(GL_DEPTH_TEST);
        stencilWasEnabled
            ? glEnable(GL_STENCIL_TEST)
            : glDisable(GL_STENCIL_TEST);
        scissorWasEnabled
            ? glEnable(GL_SCISSOR_TEST)
            : glDisable(GL_SCISSOR_TEST);
    };

    while (glGetError() != GL_NO_ERROR) {}
    glBindFramebuffer(GL_FRAMEBUFFER, sourceFramebuffer);
    const GLenum sourceStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (sourceStatus != GL_FRAMEBUFFER_COMPLETE) {
        static bool reportedIncomplete = false;
        if (!reportedIncomplete) {
            reportedIncomplete = true;
            NSLog(@"[compat] source FBO %u is incomplete: 0x%x",
                  sourceFramebuffer, sourceStatus);
        }
        restoreState();
        return false;
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, s_presentTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    const bool needsTextureStorage =
        s_presentTextureWidth != sourceWidth
        || s_presentTextureHeight != sourceHeight;
    if (needsTextureStorage) {
        glTexImage2D(
            GL_TEXTURE_2D,
            0,
            GL_RGBA,
            sourceWidth,
            sourceHeight,
            0,
            GL_RGBA,
            GL_UNSIGNED_BYTE,
            nullptr
        );
    }
    glCopyTexSubImage2D(
        GL_TEXTURE_2D,
        0,
        0,
        0,
        0,
        0,
        sourceWidth,
        sourceHeight
    );
    const GLenum copyError = glGetError();
    if (copyError != GL_NO_ERROR) {
        static bool reportedCopyError = false;
        if (!reportedCopyError) {
            reportedCopyError = true;
            NSLog(@"[compat] presentation texture copy failed: 0x%x",
                  copyError);
        }
        restoreState();
        return false;
    }
    if (needsTextureStorage) {
        s_presentTextureWidth = sourceWidth;
        s_presentTextureHeight = sourceHeight;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, targetWidth, targetHeight);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glUseProgram(s_presentProgram);
    glUniform1i(s_presentSampler, 0);
    const GLfloat vertices[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f,
    };
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glEnableVertexAttribArray((GLuint)s_presentPosition);
    glVertexAttribPointer(
        (GLuint)s_presentPosition,
        2,
        GL_FLOAT,
        GL_FALSE,
        0,
        vertices
    );
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray((GLuint)s_presentPosition);
    const GLenum drawError = glGetError();
    if (drawError != GL_NO_ERROR) {
        static bool reportedDrawError = false;
        if (!reportedDrawError) {
            reportedDrawError = true;
            NSLog(@"[compat] presentation quad failed: 0x%x", drawError);
        }
    }
    const bool succeeded = drawError == GL_NO_ERROR;
    restoreState();
    return succeeded;
}

namespace {

using yoghourt_spatial::FrameOrigin;
using yoghourt_spatial::MetalTextureFrame;
using yoghourt_spatial::Options;
using yoghourt_spatial::PixelFormat;
using yoghourt_spatial::Presenter;
using yoghourt_surface_relay::EGLSharedEventAPI;
using yoghourt_surface_relay::IOSurfaceRing;
using yoghourt_surface_relay::IOSurfaceRingConfig;

struct VertexAttributeState {
    GLint index = -1;
    GLint enabled = GL_FALSE;
    GLint size = 4;
    GLint type = GL_FLOAT;
    GLint normalized = GL_FALSE;
    GLint stride = 0;
    GLint buffer = 0;
    void *pointer = nullptr;
};

class ScopedEGLGLState {
public:
    ScopedEGLGLState(const ScopedEGLGLState &) = delete;
    ScopedEGLGLState &operator=(const ScopedEGLGLState &) = delete;
    ScopedEGLGLState() {
        display_ = eglGetCurrentDisplay_ptr();
        context_ = eglGetCurrentContext_ptr();
        drawSurface_ = eglGetCurrentSurface_ptr(EGL_DRAW);
        readSurface_ = eglGetCurrentSurface_ptr(EGL_READ);
        valid_ = display_ != EGL_NO_DISPLAY && context_ != EGL_NO_CONTEXT;
        if (!valid_) return;

        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer_);
        // Explicit ANGLE Metal currently exposes GLES 3, which has separate
        // read/draw FBO bindings. Preserve the read binding independently.
        glGetIntegerv(0x8CAA /* GL_READ_FRAMEBUFFER_BINDING */, &readFramebuffer_);
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer_);
        glGetIntegerv(GL_VIEWPORT, viewport_);
        glGetIntegerv(GL_SCISSOR_BOX, scissorBox_);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program_);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &activeTexture_);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &arrayBuffer_);
        glGetBooleanv(GL_COLOR_WRITEMASK, colorMask_);
        blend_ = glIsEnabled(GL_BLEND);
        depth_ = glIsEnabled(GL_DEPTH_TEST);
        stencil_ = glIsEnabled(GL_STENCIL_TEST);
        scissor_ = glIsEnabled(GL_SCISSOR_TEST);

        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture0_);
        if (activeTexture_ != GL_TEXTURE0) {
            glActiveTexture((GLenum)activeTexture_);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &activeTextureBinding_);
        } else {
            activeTextureBinding_ = texture0_;
        }

        attribute_.index = s_presentPosition;
        if (attribute_.index >= 0) {
            glGetVertexAttribiv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &attribute_.enabled);
            glGetVertexAttribiv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_SIZE, &attribute_.size);
            glGetVertexAttribiv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_TYPE, &attribute_.type);
            glGetVertexAttribiv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &attribute_.normalized);
            glGetVertexAttribiv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &attribute_.stride);
            glGetVertexAttribiv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &attribute_.buffer);
            glGetVertexAttribPointerv(attribute_.index, GL_VERTEX_ATTRIB_ARRAY_POINTER, &attribute_.pointer);
        }
        glActiveTexture((GLenum)activeTexture_);
    }

    ~ScopedEGLGLState() {
        if (!restored_) (void)restore();
    }

    bool isValid() const { return valid_; }

    bool restore() {
        if (restored_) return restoreSucceeded_;
        restored_ = true;
        if (s_testForceStateRestoreFailure) {
            restoreSucceeded_ = false;
            return false;
        }
        if (!valid_ || !eglMakeCurrent_ptr(display_, drawSurface_, readSurface_, context_)) {
            restoreSucceeded_ = false;
            return false;
        }

        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)framebuffer_);
        glBindFramebuffer(GL_READ_FRAMEBUFFER_ANGLE, (GLuint)readFramebuffer_);
        glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)renderbuffer_);
        glUseProgram((GLuint)program_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, (GLuint)texture0_);
        if (activeTexture_ != GL_TEXTURE0) {
            glActiveTexture((GLenum)activeTexture_);
            glBindTexture(GL_TEXTURE_2D, (GLuint)activeTextureBinding_);
        }
        if (attribute_.index >= 0) {
            glBindBuffer(GL_ARRAY_BUFFER, (GLuint)attribute_.buffer);
            if (attribute_.enabled || attribute_.buffer != 0 || attribute_.pointer != nullptr) {
                glVertexAttribPointer(
                    (GLuint)attribute_.index,
                    attribute_.size,
                    (GLenum)attribute_.type,
                    (GLboolean)attribute_.normalized,
                    attribute_.stride,
                    attribute_.pointer
                );
            }
            attribute_.enabled
                ? glEnableVertexAttribArray((GLuint)attribute_.index)
                : glDisableVertexAttribArray((GLuint)attribute_.index);
        }
        glBindBuffer(GL_ARRAY_BUFFER, (GLuint)arrayBuffer_);
        glActiveTexture((GLenum)activeTexture_);
        glViewport(viewport_[0], viewport_[1], viewport_[2], viewport_[3]);
        glScissor(scissorBox_[0], scissorBox_[1], scissorBox_[2], scissorBox_[3]);
        glColorMask(colorMask_[0], colorMask_[1], colorMask_[2], colorMask_[3]);
        blend_ ? glEnable(GL_BLEND) : glDisable(GL_BLEND);
        depth_ ? glEnable(GL_DEPTH_TEST) : glDisable(GL_DEPTH_TEST);
        stencil_ ? glEnable(GL_STENCIL_TEST) : glDisable(GL_STENCIL_TEST);
        scissor_ ? glEnable(GL_SCISSOR_TEST) : glDisable(GL_SCISSOR_TEST);
        restoreSucceeded_ = glGetError() == GL_NO_ERROR;
        return restoreSucceeded_;
    }

private:
    EGLDisplay display_ = EGL_NO_DISPLAY;
    EGLContext context_ = EGL_NO_CONTEXT;
    EGLSurface drawSurface_ = EGL_NO_SURFACE;
    EGLSurface readSurface_ = EGL_NO_SURFACE;
    GLint framebuffer_ = 0;
    GLint readFramebuffer_ = 0;
    GLint renderbuffer_ = 0;
    GLint viewport_[4] = {};
    GLint scissorBox_[4] = {};
    GLint program_ = 0;
    GLint activeTexture_ = GL_TEXTURE0;
    GLint texture0_ = 0;
    GLint activeTextureBinding_ = 0;
    GLint arrayBuffer_ = 0;
    GLboolean colorMask_[4] = {};
    GLboolean blend_ = GL_FALSE;
    GLboolean depth_ = GL_FALSE;
    GLboolean stencil_ = GL_FALSE;
    GLboolean scissor_ = GL_FALSE;
    VertexAttributeState attribute_;
    bool valid_ = false;
    bool restored_ = false;
    bool restoreSucceeded_ = false;
};

struct ArtemisSpatialGeneration {
    uint64_t identifier = 0;
    int width = 0;
    int height = 0;
    std::unique_ptr<IOSurfaceRing> ring;
    std::unique_ptr<Presenter> presenter;
    std::atomic<size_t> inFlight{0};
    std::atomic_bool asyncFailed{false};
    ~ArtemisSpatialGeneration() {
        // Coordinator releases generations on the EGL producer thread only,
        // after both the callback token and its submission group are finished.
        presenter.reset();
        if (ring) ring->reset();
    }
};

struct ArtemisSpatialCompletionToken {
    std::shared_ptr<ArtemisSpatialGeneration> generation;
    IOSurfaceRing::Slot *slot = nullptr;
};

struct ArtemisPresenterSelfTestCompletion {
    IOSurfaceRing *ring = nullptr;
    IOSurfaceRing::Slot *slot = nullptr;
    std::atomic_bool completed{false};
    std::atomic_bool succeeded{false};
};

struct ArtemisSpatialCoordinator {
    CAMetalLayer *overlayLayer = nil;
    std::shared_ptr<ArtemisSpatialGeneration> active;
    std::vector<std::shared_ptr<ArtemisSpatialGeneration>> retired;
    uint64_t nextGeneration = 1;
    uint64_t submittedFrames = 0;
    uint64_t droppedScalingFrames = 0;
    uint64_t ringSaturations = 0;
    uint64_t fallbacks = 0;
    std::array<double, 256> submitSamples{};
    size_t submitSampleCount = 0;
    size_t submitSampleCursor = 0;
    std::chrono::steady_clock::time_point metricsEpoch;
    uint64_t metricsSubmittedBase = 0;
    uint64_t metricsDroppedBase = 0;
    bool logged = false;
    bool disabled = false;
};

static std::unique_ptr<ArtemisSpatialCoordinator> s_spatialCoordinator;
constexpr size_t kMaximumRetiredGenerations = 4;

enum class SpatialPresentResult {
    notRequested,
    presented,
    backpressure,
    failed,
};

void RecordSpatialSubmitTime(ArtemisSpatialCoordinator &coordinator, double milliseconds) {
    coordinator.submitSamples[coordinator.submitSampleCursor] = milliseconds;
    coordinator.submitSampleCursor =
        (coordinator.submitSampleCursor + 1) % coordinator.submitSamples.size();
    coordinator.submitSampleCount = std::min(
        coordinator.submitSampleCount + 1,
        coordinator.submitSamples.size());
}

void LogSpatialMetricsIfDue(ArtemisSpatialCoordinator &coordinator) {
    const auto now = std::chrono::steady_clock::now();
    if (coordinator.metricsEpoch.time_since_epoch().count() == 0) {
        coordinator.metricsEpoch = now;
        return;
    }
    const double seconds = std::chrono::duration<double>(now - coordinator.metricsEpoch).count();
    if (seconds < 1.0) return;
    auto sorted = coordinator.submitSamples;
    std::sort(sorted.begin(), sorted.begin() + coordinator.submitSampleCount);
    const auto percentile = [&](double fraction) {
        if (coordinator.submitSampleCount == 0) return 0.0;
        const size_t index = std::min(
            coordinator.submitSampleCount - 1,
            static_cast<size_t>((coordinator.submitSampleCount - 1) * fraction));
        return sorted[index];
    };
    fprintf(stdout,
            "[Yoghourt] Artemis spatial metrics submitCPU.p50=%.3fms submitCPU.p95=%.3fms submittedFPS=%.1f droppedScalingFPS=%.1f droppedScalingFrames=%llu ringSaturation=%llu fallback=%llu activeInFlight=%zu retired=%zu\n",
            percentile(0.50), percentile(0.95),
            (coordinator.submittedFrames - coordinator.metricsSubmittedBase) / seconds,
            (coordinator.droppedScalingFrames - coordinator.metricsDroppedBase) / seconds,
            (unsigned long long)coordinator.droppedScalingFrames,
            (unsigned long long)coordinator.ringSaturations,
            (unsigned long long)coordinator.fallbacks,
            coordinator.active
                ? coordinator.active->inFlight.load(std::memory_order_relaxed)
                : 0,
            coordinator.retired.size());
    fflush(stdout);
    coordinator.metricsEpoch = now;
    coordinator.metricsSubmittedBase = coordinator.submittedFrames;
    coordinator.metricsDroppedBase = coordinator.droppedScalingFrames;
}

void SpatialCompletion(void *context, bool succeeded) {
    std::unique_ptr<ArtemisSpatialCompletionToken> token(
        static_cast<ArtemisSpatialCompletionToken *>(context));
    if (!token || !token->generation || !token->slot) return;
    token->generation->ring->complete(token->slot, succeeded);
    if (!succeeded) {
        token->generation->asyncFailed.store(true, std::memory_order_release);
    }
    token->generation->inFlight.fetch_sub(1, std::memory_order_acq_rel);
}

void PresenterSelfTestCompletion(void *context, bool succeeded) {
    auto *completion = static_cast<ArtemisPresenterSelfTestCompletion *>(context);
    if (!completion || !completion->ring || !completion->slot) return;
    completion->ring->complete(completion->slot, succeeded);
    completion->succeeded.store(succeeded, std::memory_order_release);
    completion->completed.store(true, std::memory_order_release);
}

void ReapRetiredGenerations(ArtemisSpatialCoordinator &coordinator) {
    coordinator.retired.erase(
        std::remove_if(
            coordinator.retired.begin(),
            coordinator.retired.end(),
            [](const auto &generation) {
                return generation->inFlight.load(std::memory_order_acquire) == 0 &&
                    generation.use_count() == 1 &&
                    (!generation->presenter || generation->presenter->isIdle());
            }
        ),
        coordinator.retired.end()
    );
}

CAMetalLayer *EnsureSpatialOverlay(CAMetalLayer *baseLayer) {
    if (!baseLayer || !s_metalDevice) return nil;
    if (!s_spatialCoordinator) {
        s_spatialCoordinator = std::make_unique<ArtemisSpatialCoordinator>();
    }
    auto &coordinator = *s_spatialCoordinator;
    if (!coordinator.overlayLayer) {
        coordinator.overlayLayer = [CAMetalLayer layer];
        coordinator.overlayLayer.device = s_metalDevice;
        coordinator.overlayLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        coordinator.overlayLayer.framebufferOnly = NO;
        coordinator.overlayLayer.maximumDrawableCount = 3;
        coordinator.overlayLayer.opaque = YES;
        coordinator.overlayLayer.hidden = YES;
        [baseLayer addSublayer:coordinator.overlayLayer];
    } else if (coordinator.overlayLayer.superlayer != baseLayer) {
        [coordinator.overlayLayer removeFromSuperlayer];
        [baseLayer addSublayer:coordinator.overlayLayer];
    }
    coordinator.overlayLayer.device = s_metalDevice;
    coordinator.overlayLayer.frame = baseLayer.bounds;
    coordinator.overlayLayer.contentsScale = baseLayer.contentsScale;
    coordinator.overlayLayer.drawableSize = baseLayer.drawableSize;
    return coordinator.overlayLayer;
}

std::shared_ptr<ArtemisSpatialGeneration> CreateSpatialGeneration(
    ArtemisSpatialCoordinator &coordinator,
    CAMetalLayer *overlayLayer,
    int width,
    int height
) {
    EGLSharedEventAPI syncAPI;
    syncAPI.createSync = eglCreateSync_ptr;
    syncAPI.destroySync = eglDestroySync_ptr;
    syncAPI.waitSync = eglWaitSync_ptr;
    syncAPI.copyMetalSharedEvent = eglCopyMetalSharedEventANGLE_ptr;

    IOSurfaceRingConfig config;
    config.display = s_display;
    config.config = s_config;
    config.metalDevice = (__bridge void *)s_metalDevice;
    config.width = width;
    config.height = height;
    config.syncAPI = syncAPI;

    auto generation = std::make_shared<ArtemisSpatialGeneration>();
    generation->identifier = coordinator.nextGeneration++;
    generation->width = width;
    generation->height = height;
    generation->ring = std::make_unique<IOSurfaceRing>();
    if (!generation->ring->rebuild(config)) return nullptr;

    Options options;
    options.scaler = spatialScalerMode();
    options.metalDevice = (__bridge void *)s_metalDevice;
    options.commandQueue = (__bridge void *)s_spatialQueue;
    options.enableOverlayMask = false;
    generation->presenter = std::make_unique<Presenter>(
        (__bridge void *)overlayLayer,
        width,
        height,
        options
    );
    if (!generation->presenter->isActive()) return nullptr;
    return generation;
}

bool CopyFramebufferToRingSlot(
    IOSurfaceRing &ring,
    IOSurfaceRing::Slot &slot,
    GLuint sourceFramebuffer,
    int width,
    int height
) {
    if (!ensurePresentationProgram()) return false;
    ScopedEGLGLState state;
    if (!state.isValid() || !ring.waitPreviousMetalDone(&slot)) return false;
    const EGLContext producerContext = eglGetCurrentContext_ptr();

    while (glGetError() != GL_NO_ERROR) {}
    glBindFramebuffer(GL_FRAMEBUFFER, sourceFramebuffer);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        return false;
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, s_presentTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (s_presentTextureWidth != width || s_presentTextureHeight != height) {
        glTexImage2D(
            GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
            GL_RGBA, GL_UNSIGNED_BYTE, nullptr
        );
        s_presentTextureWidth = width;
        s_presentTextureHeight = height;
    }
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, width, height);
    if (glGetError() != GL_NO_ERROR ||
        !eglMakeCurrent_ptr(s_display, ring.pbufferOf(&slot), ring.pbufferOf(&slot), producerContext)) {
        return false;
    }

    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, width, height);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glUseProgram(s_presentProgram);
    glUniform1i(s_presentSampler, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, s_presentTexture);
    const GLfloat vertices[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f,
    };
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glEnableVertexAttribArray((GLuint)s_presentPosition);
    glVertexAttribPointer((GLuint)s_presentPosition, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray((GLuint)s_presentPosition);
    const bool copied = glGetError() == GL_NO_ERROR && ring.signalAngleReady(&slot);
    return copied && state.restore();
}

SpatialPresentResult PresentFramebufferWithSpatialScaler(
    CAMetalLayer *baseLayer,
    GLuint framebuffer,
    int width,
    int height
) {
    if (!spatialPresentationRequested()) {
        if (s_spatialCoordinator && s_spatialCoordinator->overlayLayer) {
            s_spatialCoordinator->overlayLayer.hidden = YES;
        }
        return SpatialPresentResult::notRequested;
    }
    if (!baseLayer || framebuffer == 0 || width <= 0 || height <= 0 ||
        !s_metalDevice || !s_spatialQueue) {
        if (s_spatialCoordinator) {
            auto &coordinator = *s_spatialCoordinator;
            coordinator.overlayLayer.hidden = YES;
            if (!coordinator.disabled) ++coordinator.fallbacks;
            coordinator.disabled = true;
        }
        return SpatialPresentResult::failed;
    }
    CAMetalLayer *overlay = EnsureSpatialOverlay(baseLayer);
    if (!overlay) return SpatialPresentResult::failed;
    auto &coordinator = *s_spatialCoordinator;
    const auto submitStart = std::chrono::steady_clock::now();
    ReapRetiredGenerations(coordinator);
    if (coordinator.disabled) return SpatialPresentResult::failed;

    if (coordinator.active &&
        coordinator.active->asyncFailed.exchange(false, std::memory_order_acq_rel)) {
        coordinator.disabled = true;
        coordinator.fallbacks++;
        overlay.hidden = YES;
        return SpatialPresentResult::failed;
    }

    if (!coordinator.active || coordinator.active->width != width ||
        coordinator.active->height != height) {
        if (coordinator.retired.size() >= kMaximumRetiredGenerations) {
            overlay.hidden = YES;
            return SpatialPresentResult::backpressure;
        }
        auto next = CreateSpatialGeneration(coordinator, overlay, width, height);
        if (!next) {
            coordinator.disabled = true;
            coordinator.fallbacks++;
            overlay.hidden = YES;
            return SpatialPresentResult::failed;
        }
        if (coordinator.active) coordinator.retired.push_back(coordinator.active);
        coordinator.active = std::move(next);
    }

    auto generation = coordinator.active;
    IOSurfaceRing::Slot *slot = generation->ring->acquire();
    if (!slot) {
        coordinator.droppedScalingFrames++;
        coordinator.ringSaturations++;
        LogSpatialMetricsIfDue(coordinator);
        return SpatialPresentResult::backpressure;
    }
    if (!CopyFramebufferToRingSlot(*generation->ring, *slot, framebuffer, width, height) ||
        !generation->ring->assignMetalDone(slot)) {
        generation->ring->forceFree(slot);
        coordinator.disabled = true;
        coordinator.fallbacks++;
        overlay.hidden = YES;
        return SpatialPresentResult::failed;
    }

    auto *token = new ArtemisSpatialCompletionToken{generation, slot};
    generation->inFlight.fetch_add(1, std::memory_order_acq_rel);
    MetalTextureFrame frame(
        generation->ring->textureOf(slot),
        width,
        height,
        PixelFormat::bgra8Unorm,
        generation->ring->angleReadyEvent(),
        generation->ring->angleReadyValueOf(slot),
        generation->ring->metalDoneEvent(),
        generation->ring->metalDoneValueOf(slot),
        SpatialCompletion,
        token,
        FrameOrigin::bottomLeft
    );
    if (!generation->presenter->present(frame)) {
        generation->inFlight.fetch_sub(1, std::memory_order_acq_rel);
        delete token;
        generation->ring->forceFree(slot);
        coordinator.disabled = true;
        coordinator.fallbacks++;
        overlay.hidden = YES;
        return SpatialPresentResult::failed;
    }
    coordinator.submittedFrames++;
    RecordSpatialSubmitTime(
        coordinator,
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - submitStart).count());
    LogSpatialMetricsIfDue(coordinator);
    if (!coordinator.logged) {
        fprintf(stdout,
                "[Yoghourt] SPATIAL engine=artemis bridge=iosurface-metal sync=metal-shared-event buffers=3 readback=none glFinish=none externalWait=none scaler=%s\n",
                getenv("YOGHOURT_SPATIAL_SCALER") ?: "metalfx");
        fflush(stdout);
        coordinator.logged = true;
    }
    overlay.hidden = NO;
    return SpatialPresentResult::presented;
}

void ShutdownSpatialPresentation() {
    if (!s_spatialCoordinator) return;
    if (s_spatialCoordinator->active && s_spatialCoordinator->active->presenter) {
        s_spatialCoordinator->active->presenter->drain();
    }
    for (const auto &generation : s_spatialCoordinator->retired) {
        if (generation->presenter) generation->presenter->drain();
    }
    if (s_spatialCoordinator->overlayLayer) {
        [s_spatialCoordinator->overlayLayer removeFromSuperlayer];
    }
    s_spatialCoordinator.reset();
}

} // namespace

extern "C" int YoghourtRunArtemisRendererSelfTest(void) {
    @autoreleasepool {
        if (!initEGL()) {
            fprintf(stderr, "[Yoghourt] ERROR Artemis renderer self-test: ANGLE Metal initialization failed\n");
            return 1;
        }
        const EGLint pbufferAttributes[] = {
            EGL_WIDTH, 8,
            EGL_HEIGHT, 8,
            EGL_NONE,
        };
        const EGLint contextAttributes[] = {
            EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL_NONE,
        };
        EGLSurface surface = eglCreatePbufferSurface_ptr(
            s_display, s_config, pbufferAttributes);
        EGLContext context = eglCreateContext_ptr(
            s_display, s_config, s_shareCtx, contextAttributes);
        if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT ||
            !eglMakeCurrent_ptr(s_display, surface, surface, context)) {
            fprintf(stderr, "[Yoghourt] ERROR Artemis renderer self-test: context/pbuffer setup failed\n");
            return 1;
        }

        const char *renderer = reinterpret_cast<const char *>(glGetString(GL_RENDERER));
        const bool backendOK = renderer && strstr(renderer, "ANGLE Metal Renderer");
        const bool deviceOK = s_metalDevice && s_spatialQueue &&
            s_spatialQueue.device == s_metalDevice;
        const bool componentOK = backendOK && deviceOK &&
            yoghourt_surface_relay::RunIOSurfaceRingComponentTest(
                s_display,
                s_config,
                (__bridge void *)s_metalDevice
            );

        bool retirementOK = false;
        {
            EGLSharedEventAPI lifecycleSyncAPI;
            lifecycleSyncAPI.createSync = eglCreateSync_ptr;
            lifecycleSyncAPI.destroySync = eglDestroySync_ptr;
            lifecycleSyncAPI.waitSync = eglWaitSync_ptr;
            lifecycleSyncAPI.copyMetalSharedEvent = eglCopyMetalSharedEventANGLE_ptr;
            IOSurfaceRingConfig lifecycleConfig;
            lifecycleConfig.display = s_display;
            lifecycleConfig.config = s_config;
            lifecycleConfig.metalDevice = (__bridge void *)s_metalDevice;
            lifecycleConfig.width = 8;
            lifecycleConfig.height = 8;
            lifecycleConfig.syncAPI = lifecycleSyncAPI;
            auto lifecycleGeneration = std::make_shared<ArtemisSpatialGeneration>();
            lifecycleGeneration->ring = std::make_unique<IOSurfaceRing>();
            if (lifecycleGeneration->ring->rebuild(lifecycleConfig)) {
                IOSurfaceRing::Slot *lifecycleSlot = lifecycleGeneration->ring->acquire();
                if (lifecycleSlot) {
                    lifecycleGeneration->inFlight.store(1, std::memory_order_release);
                    std::weak_ptr<ArtemisSpatialGeneration> weakGeneration = lifecycleGeneration;
                    ArtemisSpatialCoordinator lifecycleCoordinator;
                    lifecycleCoordinator.retired.push_back(lifecycleGeneration);
                    auto *token = new ArtemisSpatialCompletionToken{
                        lifecycleGeneration,
                        lifecycleSlot,
                    };
                    id<MTLSharedEvent> hold = [s_metalDevice newSharedEvent];
                    id<MTLCommandBuffer> pending = [s_spatialQueue commandBuffer];
                    [pending encodeWaitForEvent:hold value:1];
                    id<MTLTexture> retainedTexture =
                        (__bridge id<MTLTexture>)lifecycleGeneration->ring->textureOf(lifecycleSlot);
                    id<MTLTexture> copyTexture = [s_metalDevice newTextureWithDescriptor:
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                            width:8 height:8 mipmapped:NO]];
                    id<MTLBlitCommandEncoder> copy = [pending blitCommandEncoder];
                    [copy copyFromTexture:retainedTexture sourceSlice:0 sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                        toTexture:copyTexture destinationSlice:0 destinationLevel:0
                        destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [copy endEncoding];
                    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
                    [pending addCompletedHandler:^(id<MTLCommandBuffer> result) {
                        SpatialCompletion(token, result.status == MTLCommandBufferStatusCompleted);
                        dispatch_semaphore_signal(finished);
                    }];
                    [pending commit];
                    lifecycleGeneration.reset();
                    ReapRetiredGenerations(lifecycleCoordinator);
                    const bool aliveBeforeCompletion = !weakGeneration.expired() &&
                        lifecycleCoordinator.retired.size() == 1;
                    hold.signaledValue = 1;
                    const bool callbackFinished = dispatch_semaphore_wait(finished,
                        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
                    if (!callbackFinished) {
                        fprintf(stderr, "Artemis retirement self-test timed out\n");
                        std::_Exit(1);
                    }
                    auto completedGeneration = weakGeneration.lock();
                    const bool completed = pending.status == MTLCommandBufferStatusCompleted && completedGeneration &&
                        completedGeneration->inFlight.load(std::memory_order_acquire) == 0;
                    completedGeneration.reset();
                    ReapRetiredGenerations(lifecycleCoordinator);
                    retirementOK = aliveBeforeCompletion && completed &&
                        lifecycleCoordinator.retired.empty() && weakGeneration.expired();
                }
            }
        }

        EGLSharedEventAPI syncAPI;
        syncAPI.createSync = eglCreateSync_ptr;
        syncAPI.destroySync = eglDestroySync_ptr;
        syncAPI.waitSync = eglWaitSync_ptr;
        syncAPI.copyMetalSharedEvent = eglCopyMetalSharedEventANGLE_ptr;
        IOSurfaceRingConfig ringConfig;
        ringConfig.display = s_display;
        ringConfig.config = s_config;
        ringConfig.metalDevice = (__bridge void *)s_metalDevice;
        ringConfig.width = 8;
        ringConfig.height = 8;
        ringConfig.syncAPI = syncAPI;
        IOSurfaceRing ring;
        bool mappingOK = componentOK && ring.rebuild(ringConfig);

        GLuint sourceTexture = 0;
        GLuint sourceFramebuffer = 0;
        glGenTextures(1, &sourceTexture);
        glBindTexture(GL_TEXTURE_2D, sourceTexture);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 8, 8, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glGenFramebuffers(1, &sourceFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, sourceFramebuffer);
        glFramebufferTexture2D(
            GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, sourceTexture, 0);
        mappingOK = mappingOK && glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
        glDisable(GL_BLEND);
        glEnable(GL_SCISSOR_TEST);
        glViewport(0, 0, 8, 8);
        const auto clearQuadrant = [](int x, int y, float r, float g, float b) {
            glScissor(x, y, 4, 4);
            glClearColor(r, g, b, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT);
        };
        clearQuadrant(0, 0, 1, 0, 0);
        clearQuadrant(4, 0, 0, 1, 0);
        clearQuadrant(0, 4, 0, 0, 1);
        clearQuadrant(4, 4, 1, 1, 1);

        ensurePresentationProgram();
        glUseProgram(0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, sourceTexture);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, 0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glDisableVertexAttribArray((GLuint)s_presentPosition);
        glViewport(1, 2, 5, 6);
        glScissor(2, 1, 4, 5);
        glEnable(GL_BLEND);
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_STENCIL_TEST);
        glColorMask(GL_TRUE, GL_FALSE, GL_TRUE, GL_FALSE);
        GLint expectedViewport[4] = {};
        GLint expectedScissor[4] = {};
        glGetIntegerv(GL_VIEWPORT, expectedViewport);
        glGetIntegerv(GL_SCISSOR_BOX, expectedScissor);

        IOSurfaceRing::Slot *slot = mappingOK ? ring.acquire() : nullptr;
        mappingOK = mappingOK && slot && CopyFramebufferToRingSlot(
            ring, *slot, sourceFramebuffer, 8, 8);
        mappingOK = mappingOK && glIsEnabled(GL_BLEND) &&
            !glIsEnabled(GL_DEPTH_TEST) && glIsEnabled(GL_STENCIL_TEST);
        GLint restoredViewport[4] = {};
        GLint restoredScissor[4] = {};
        GLboolean restoredMask[4] = {};
        GLint restoredFramebuffer = 0;
        GLint restoredProgram = 0;
        GLint restoredActiveTexture = 0;
        GLint restoredArrayBuffer = 0;
        GLint restoredAttributeEnabled = GL_TRUE;
        glGetIntegerv(GL_VIEWPORT, restoredViewport);
        glGetIntegerv(GL_SCISSOR_BOX, restoredScissor);
        glGetBooleanv(GL_COLOR_WRITEMASK, restoredMask);
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &restoredFramebuffer);
        glGetIntegerv(GL_CURRENT_PROGRAM, &restoredProgram);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &restoredActiveTexture);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &restoredArrayBuffer);
        glGetVertexAttribiv(
            (GLuint)s_presentPosition,
            GL_VERTEX_ATTRIB_ARRAY_ENABLED,
            &restoredAttributeEnabled);
        const bool stateOK = mappingOK &&
            eglGetCurrentContext_ptr() == context &&
            eglGetCurrentSurface_ptr(EGL_DRAW) == surface &&
            eglGetCurrentSurface_ptr(EGL_READ) == surface &&
            restoredFramebuffer == (GLint)sourceFramebuffer &&
            restoredProgram == 0 && restoredActiveTexture == GL_TEXTURE1 &&
            restoredArrayBuffer == 0 && restoredAttributeEnabled == GL_FALSE &&
            memcmp(expectedViewport, restoredViewport, sizeof(expectedViewport)) == 0 &&
            memcmp(expectedScissor, restoredScissor, sizeof(expectedScissor)) == 0 &&
            restoredMask[0] && !restoredMask[1] && restoredMask[2] && !restoredMask[3];

        if (mappingOK) mappingOK = ring.assignMetalDone(slot);
        id<MTLBuffer> readback = [s_metalDevice newBufferWithLength:8 * 8 * 4
                                                            options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> commandBuffer = [s_spatialQueue commandBuffer];
        if (mappingOK && readback && commandBuffer) {
            [commandBuffer encodeWaitForEvent:(__bridge id<MTLSharedEvent>)ring.angleReadyEvent()
                                        value:ring.angleReadyValueOf(slot)];
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:(__bridge id<MTLTexture>)ring.textureOf(slot)
                      sourceSlice:0
                      sourceLevel:0
                     sourceOrigin:MTLOriginMake(0, 0, 0)
                       sourceSize:MTLSizeMake(8, 8, 1)
                         toBuffer:readback
                destinationOffset:0
           destinationBytesPerRow:8 * 4
         destinationBytesPerImage:8 * 8 * 4];
            [blit endEncoding];
            [commandBuffer encodeSignalEvent:(__bridge id<MTLSharedEvent>)ring.metalDoneEvent()
                                        value:ring.metalDoneValueOf(slot)];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
            mappingOK = commandBuffer.status == MTLCommandBufferStatusCompleted;
        } else {
            mappingOK = false;
        }
        if (slot) ring.complete(slot, mappingOK);

        if (mappingOK) {
            const uint8_t *bytes = static_cast<const uint8_t *>(readback.contents);
            const auto pixelMatches = [bytes](int x, int y, uint8_t b, uint8_t g, uint8_t r) {
                const size_t offset = ((size_t)y * 8 + (size_t)x) * 4;
                return bytes[offset] == b && bytes[offset + 1] == g &&
                    bytes[offset + 2] == r && bytes[offset + 3] == 255;
            };
            // IOSurface row zero is the EGL bottom row. The external frame is
            // therefore explicitly tagged bottomLeft for SpatialPresenter.
            mappingOK = pixelMatches(1, 1, 0, 0, 255) &&
                pixelMatches(6, 1, 0, 255, 0) &&
                pixelMatches(1, 6, 255, 0, 0) &&
                pixelMatches(6, 6, 255, 255, 255);
        }

        ArtemisSelfTestMetalLayer *presenterLayer = [ArtemisSelfTestMetalLayer layer];
        presenterLayer.device = s_metalDevice;
        presenterLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        presenterLayer.framebufferOnly = NO;
        presenterLayer.drawableSize = CGSizeMake(8, 8);
        presenterLayer.maximumDrawableCount = 3;
        Options presenterOptions;
        presenterOptions.scaler = yoghourt_spatial::ScalerMode::metalFX;
        presenterOptions.metalDevice = (__bridge void *)s_metalDevice;
        presenterOptions.commandQueue = (__bridge void *)s_spatialQueue;
        Presenter presenter((__bridge void *)presenterLayer, 8, 8, presenterOptions);
        IOSurfaceRing::Slot *presenterSlot = presenter.isActive() ? ring.acquire() : nullptr;
        bool presenterOK = presenterSlot && CopyFramebufferToRingSlot(
            ring, *presenterSlot, sourceFramebuffer, 8, 8) &&
            ring.assignMetalDone(presenterSlot);
        ArtemisPresenterSelfTestCompletion presenterCompletion;
        if (presenterOK) {
            presenterCompletion.ring = &ring;
            presenterCompletion.slot = presenterSlot;
            MetalTextureFrame presenterFrame(
                ring.textureOf(presenterSlot),
                8,
                8,
                PixelFormat::bgra8Unorm,
                ring.angleReadyEvent(),
                ring.angleReadyValueOf(presenterSlot),
                ring.metalDoneEvent(),
                ring.metalDoneValueOf(presenterSlot),
                PresenterSelfTestCompletion,
                &presenterCompletion,
                FrameOrigin::bottomLeft
            );
            presenterOK = presenter.present(presenterFrame) && presenter.drain() &&
                presenterCompletion.completed.load(std::memory_order_acquire) &&
                presenterCompletion.succeeded.load(std::memory_order_acquire) &&
                ring.inFlight() == 0;
        }
        if (!presenterOK && presenterSlot &&
            !presenterCompletion.completed.load(std::memory_order_acquire)) {
            ring.forceFree(presenterSlot);
        }

        bool drawablePixelsOK = presenterOK && presenterLayer.submittedTexture != nil;
        if (drawablePixelsOK) {
            id<MTLCommandBuffer> inspect = [s_spatialQueue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [inspect blitCommandEncoder];
            [blit copyFromTexture:presenterLayer.submittedTexture sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                toBuffer:readback destinationOffset:0 destinationBytesPerRow:32
                destinationBytesPerImage:256];
            [blit endEncoding];
            [inspect commit];
            [inspect waitUntilCompleted];
            const uint8_t *pixels = static_cast<const uint8_t *>(readback.contents);
            const auto matches = [pixels](int x, int y, int b, int g, int r) {
                const uint8_t *p = pixels + (y * 8 + x) * 4;
                return p[0] == b && p[1] == g && p[2] == r && p[3] == 255;
            };
            drawablePixelsOK = inspect.status == MTLCommandBufferStatusCompleted &&
                matches(1, 1, 255, 0, 0) && matches(6, 1, 255, 255, 255) &&
                matches(1, 6, 0, 0, 255) && matches(6, 6, 0, 255, 0);
        }

        setenv("YOGHOURT_SPATIAL_SCALER", "metalfx", 1);
        s_spatialCoordinator = std::make_unique<ArtemisSpatialCoordinator>();
        CAMetalLayer *backpressureOverlay = EnsureSpatialOverlay(presenterLayer);
        auto backpressureGeneration = std::make_shared<ArtemisSpatialGeneration>();
        backpressureGeneration->width = 8;
        backpressureGeneration->height = 8;
        backpressureGeneration->ring = std::make_unique<IOSurfaceRing>();
        bool backpressureOK = backpressureOverlay &&
            backpressureGeneration->ring->rebuild(ringConfig);
        IOSurfaceRing::Slot *heldSlots[3] = {};
        if (backpressureOK) {
            for (auto &heldSlot : heldSlots) {
                heldSlot = backpressureGeneration->ring->acquire();
                backpressureOK = backpressureOK && heldSlot;
            }
        }
        s_spatialCoordinator->active = backpressureGeneration;
        backpressureOverlay.hidden = NO;
        const uint64_t fallbackBefore = s_spatialCoordinator->fallbacks;
        const SpatialPresentResult backpressureResult = PresentFramebufferWithSpatialScaler(
            presenterLayer, sourceFramebuffer, 8, 8);
        backpressureOK = backpressureOK &&
            backpressureResult == SpatialPresentResult::backpressure &&
            !backpressureOverlay.hidden &&
            s_spatialCoordinator->fallbacks == fallbackBefore &&
            s_spatialCoordinator->droppedScalingFrames == 1 &&
            s_spatialCoordinator->ringSaturations == 1;
        for (auto *heldSlot : heldSlots) {
            if (heldSlot) backpressureGeneration->ring->complete(heldSlot);
        }
        const bool invalidInputRejected = PresentFramebufferWithSpatialScaler(
            presenterLayer, 0, 8, 8) == SpatialPresentResult::failed &&
            backpressureOverlay.hidden && s_spatialCoordinator->fallbacks == fallbackBefore + 1;
        const bool failureCountStable = PresentFramebufferWithSpatialScaler(
            presenterLayer, 0, 8, 8) == SpatialPresentResult::failed &&
            s_spatialCoordinator->fallbacks == fallbackBefore + 1;
        backpressureOK = backpressureOK && invalidInputRejected && failureCountStable;
        ShutdownSpatialPresentation();

        IOSurfaceRingConfig invalidSyncConfig = ringConfig;
        invalidSyncConfig.syncAPI.createSync = nullptr;
        IOSurfaceRing invalidSyncRing;
        const bool sharedEventFailureOK = !invalidSyncRing.rebuild(invalidSyncConfig);

        IOSurfaceRing restoreFailureRing;
        bool stateFailureOK = restoreFailureRing.rebuild(ringConfig);
        IOSurfaceRing::Slot *restoreFailureSlot =
            stateFailureOK ? restoreFailureRing.acquire() : nullptr;
        if (restoreFailureSlot) {
            s_testForceStateRestoreFailure = true;
            stateFailureOK = !CopyFramebufferToRingSlot(
                restoreFailureRing, *restoreFailureSlot, sourceFramebuffer, 8, 8);
            s_testForceStateRestoreFailure = false;
            stateFailureOK = stateFailureOK &&
                eglMakeCurrent_ptr(s_display, surface, surface, context);
            restoreFailureRing.forceFree(restoreFailureSlot);
        } else {
            stateFailureOK = false;
        }
        restoreFailureRing.reset();

        s_spatialCoordinator = std::make_unique<ArtemisSpatialCoordinator>();
        CAMetalLayer *failureOverlay = EnsureSpatialOverlay(presenterLayer);
        auto failedGeneration = std::make_shared<ArtemisSpatialGeneration>();
        failedGeneration->width = 8;
        failedGeneration->height = 8;
        failedGeneration->asyncFailed.store(true, std::memory_order_release);
        s_spatialCoordinator->active = failedGeneration;
        failureOverlay.hidden = NO;
        const bool asyncFailureOK = PresentFramebufferWithSpatialScaler(
            presenterLayer, sourceFramebuffer, 8, 8) == SpatialPresentResult::failed &&
            s_spatialCoordinator->disabled && failureOverlay.hidden &&
            s_spatialCoordinator->fallbacks == 1;
        ShutdownSpatialPresentation();

        s_spatialCoordinator = std::make_unique<ArtemisSpatialCoordinator>();
        CAMetalLayer *resizeOverlay = EnsureSpatialOverlay(presenterLayer);
        auto oldActive = std::make_shared<ArtemisSpatialGeneration>();
        oldActive->width = 16;
        oldActive->height = 16;
        s_spatialCoordinator->active = oldActive;
        for (size_t index = 0; index < kMaximumRetiredGenerations; ++index) {
            auto retired = std::make_shared<ArtemisSpatialGeneration>();
            retired->inFlight.store(1, std::memory_order_release);
            s_spatialCoordinator->retired.push_back(retired);
        }
        resizeOverlay.hidden = NO;
        const uint64_t resizeFallbackBefore = s_spatialCoordinator->fallbacks;
        const bool resizeBackpressure = PresentFramebufferWithSpatialScaler(
            presenterLayer, sourceFramebuffer, 8, 8) == SpatialPresentResult::backpressure &&
            resizeOverlay.hidden &&
            s_spatialCoordinator->fallbacks == resizeFallbackBefore &&
            s_spatialCoordinator->active == oldActive;
        s_spatialCoordinator->retired.front()->inFlight.store(0, std::memory_order_release);
        ReapRetiredGenerations(*s_spatialCoordinator);
        const bool reclaimedOne =
            s_spatialCoordinator->retired.size() == kMaximumRetiredGenerations - 1;
        const bool resumedAfterResize = PresentFramebufferWithSpatialScaler(
            presenterLayer, sourceFramebuffer, 8, 8) == SpatialPresentResult::presented &&
            !resizeOverlay.hidden && s_spatialCoordinator->active != oldActive;
        const bool resizeRetirementOK = resizeBackpressure && reclaimedOne && resumedAfterResize;
        ShutdownSpatialPresentation();
        unsetenv("YOGHOURT_SPATIAL_SCALER");

        EGLContext secondContext = eglCreateContext_ptr(
            s_display, s_config, s_shareCtx, contextAttributes);
        EGLSurface secondSurface = eglCreatePbufferSurface_ptr(
            s_display, s_config, pbufferAttributes);
        bool multiContextOK = secondContext != EGL_NO_CONTEXT &&
            secondSurface != EGL_NO_SURFACE &&
            eglMakeCurrent_ptr(s_display, secondSurface, secondSurface, secondContext);
        IOSurfaceRing::Slot *secondSlot = multiContextOK ? ring.acquire() : nullptr;
        if (secondSlot) {
            multiContextOK = ring.waitPreviousMetalDone(secondSlot) &&
                eglMakeCurrent_ptr(s_display, ring.pbufferOf(secondSlot), ring.pbufferOf(secondSlot), secondContext);
            if (multiContextOK) {
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
                glViewport(0, 0, 8, 8);
                glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
                glClear(GL_COLOR_BUFFER_BIT);
                multiContextOK = ring.signalAngleReady(secondSlot) && ring.assignMetalDone(secondSlot);
            }
            if (multiContextOK) {
                id<MTLCommandBuffer> secondCommand = [s_spatialQueue commandBuffer];
                [secondCommand encodeWaitForEvent:(__bridge id<MTLSharedEvent>)ring.angleReadyEvent()
                                            value:ring.angleReadyValueOf(secondSlot)];
                [secondCommand encodeSignalEvent:(__bridge id<MTLSharedEvent>)ring.metalDoneEvent()
                                            value:ring.metalDoneValueOf(secondSlot)];
                [secondCommand commit];
                [secondCommand waitUntilCompleted];
                multiContextOK = secondCommand.status == MTLCommandBufferStatusCompleted;
            }
            ring.complete(secondSlot, multiContextOK);
        } else {
            multiContextOK = false;
        }

        eglMakeCurrent_ptr(s_display, surface, surface, context);
        if (secondSurface != EGL_NO_SURFACE) eglDestroySurface_ptr(s_display, secondSurface);
        if (secondContext != EGL_NO_CONTEXT) eglDestroyContext_ptr(s_display, secondContext);
        glDeleteFramebuffers(1, &sourceFramebuffer);
        glDeleteTextures(1, &sourceTexture);
        ring.reset();
        eglMakeCurrent_ptr(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface_ptr(s_display, surface);
        eglDestroyContext_ptr(s_display, context);

        const bool passed = backendOK && deviceOK && componentOK && retirementOK &&
            stateOK && mappingOK && presenterOK && drawablePixelsOK && backpressureOK &&
            sharedEventFailureOK && stateFailureOK && asyncFailureOK &&
            resizeRetirementOK && multiContextOK;
        fprintf(stdout, "[Yoghourt] Artemis finalDrawablePixels=%s\n", drawablePixelsOK ? "passed" : "FAILED");
        fprintf(stdout,
                "[Yoghourt] ARTEMIS_RENDERER selfTest=%s backend=angle-metal deviceIdentity=%s queueIdentity=%s bgra=%s origin=bottom-left stateRestore=%s presenterSubmission=%s backpressure=%s sharedEventFailure=%s stateRestoreFailure=%s asyncFailure=%s resizeRetirement=%s multiContext=%s retiredGeneration=%s surfaceRelay=%s readback=test-only productionReadback=none glFinish=none externalWait=none\n",
                passed ? "passed" : "FAILED",
                deviceOK ? "passed" : "FAILED",
                deviceOK ? "passed" : "FAILED",
                mappingOK ? "passed" : "FAILED",
                stateOK ? "passed" : "FAILED",
                presenterOK ? "passed" : "FAILED",
                backpressureOK ? "passed" : "FAILED",
                sharedEventFailureOK ? "passed" : "FAILED",
                stateFailureOK ? "passed" : "FAILED",
                asyncFailureOK ? "passed" : "FAILED",
                resizeRetirementOK ? "passed" : "FAILED",
                multiContextOK ? "passed" : "FAILED",
                retirementOK ? "passed" : "FAILED",
                componentOK ? "passed" : "FAILED");
        fflush(stdout);
        return passed ? 0 : 1;
    }
}

// -------- EAGLContext implementation --------

@implementation EAGLContext {
    EGLContext _ctx;
    EGLSurface _surface;
    EGLSurface _drawSurface;
    __weak id<EAGLDrawable> _drawable;
}

- (instancetype)initWithAPI:(EAGLRenderingAPI)api {
    return [self initWithAPI:api sharegroup:nil];
}

- (instancetype)initWithAPI:(EAGLRenderingAPI)api sharegroup:(void*)sharegroup {
    self = [super init];
    if (!self) return nil;

    if (!initEGL()) {
        NSLog(@"EAGLContext: explicit ANGLE Metal initialization failed");
        return nil;
    }

    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    _ctx = eglCreateContext_ptr(s_display, s_config, s_shareCtx, ctxAttrs);
    if (_ctx == EGL_NO_CONTEXT) {
        NSLog(@"EAGLContext: failed to create context");
        return nil;
    }

    // CGpuRenderer may construct a replacement context after the drawable was
    // registered. Every engine context must therefore adopt the single window
    // surface rather than becoming current with EGL_NO_SURFACE.
    _drawSurface = s_windowSurface;
    NSLog(@"[compat] created EAGLContext %@ surface=%p", self, _drawSurface);
    return self;
}

+ (BOOL)setCurrentContext:(EAGLContext*)context {
    s_currentContext = (__bridge void*)context;
    if (context) {
        EGLSurface surf = context->_drawSurface ? context->_drawSurface : context->_surface;
        if (surf == EGL_NO_SURFACE) {
            // No surface yet — make current without draw surface (valid EGL, allows resource creation)
            return eglMakeCurrent_ptr(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, context->_ctx);
        }
        return eglMakeCurrent_ptr(s_display, surf, surf, context->_ctx);
    } else {
        return eglMakeCurrent_ptr(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
}

+ (EAGLContext*)currentContext {
    static BOOL reported = NO;
    if (!reported) {
        reported = YES;
        NSLog(@"[compat] EAGLContext.currentContext -> %p", s_currentContext);
    }
    return (__bridge EAGLContext*)s_currentContext;
}

+ (void)shutdownSpatialPresentation {
    ShutdownSpatialPresentation();
}

- (BOOL)presentRenderbuffer:(NSUInteger)target {
    static int swapCount = 0;
    swapCount++;
    GLint sourceFramebuffer = 0;
    GLint sourceRenderbuffer = 0;
    GLint viewport[4] = {0, 0, 0, 0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &sourceFramebuffer);
    glGetIntegerv(GL_RENDERBUFFER_BINDING, &sourceRenderbuffer);
    glGetIntegerv(GL_VIEWPORT, viewport);
    if (swapCount <= 3 || swapCount % 120 == 0) {
        NSLog(@"presentRenderbuffer call #%d sourceFBO=%d sourceRBO=%d viewport=%d,%d %dx%d error=0x%x",
              swapCount, sourceFramebuffer, sourceRenderbuffer,
              viewport[0], viewport[1], viewport[2], viewport[3], glGetError());
    }

    // ANGLE renders framebuffer 0 directly into the EGL window surface. Only
    // copy when the engine is actually presenting a non-default off-screen
    // framebuffer; forcing the initialization FBO here overwrites valid
    // default-surface content with its stale black renderbuffer.
    const GLuint framebufferToPresent = (GLuint)sourceFramebuffer;
    const GLsizei sourceWidth = viewport[2] > 0 ? viewport[2] : s_engineWidth;
    const GLsizei sourceHeight = viewport[3] > 0 ? viewport[3] : s_engineHeight;
    CAMetalLayer* layer = (CAMetalLayer*)_drawable;
    const GLsizei targetWidth = layer
        ? (GLsizei)MAX(1.0, layer.drawableSize.width)
        : sourceWidth;
    const GLsizei targetHeight = layer
        ? (GLsizei)MAX(1.0, layer.drawableSize.height)
        : sourceHeight;
    const SpatialPresentResult spatialResult = PresentFramebufferWithSpatialScaler(
        layer,
        framebufferToPresent,
        sourceWidth,
        sourceHeight
    );
    if (spatialResult == SpatialPresentResult::presented) {
        return YES;
    }
    const BOOL needsPresentationCopy =
        framebufferToPresent != 0
        || sourceWidth != targetWidth
        || sourceHeight != targetHeight;
    if (needsPresentationCopy
        && sourceWidth > 0
        && sourceHeight > 0
        && targetWidth > 0
        && targetHeight > 0) {
        glBindFramebuffer(GL_FRAMEBUFFER, framebufferToPresent);
        if (getenv("ARTEMIS_FORCE_TEST_CLEAR")) {
            glViewport(0, 0, sourceWidth, sourceHeight);
            glClearColor(0.9f, 0.1f, 0.2f, 1.0f);
            glClear(GL_COLOR_BUFFER_BIT);
            NSLog(@"[compat] forced test clear on FBO %u status=0x%x error=0x%x",
                  framebufferToPresent, glCheckFramebufferStatus(GL_FRAMEBUFFER), glGetError());
        }
        // Query and read the engine FBO through the core binding first.  The
        // ANGLE READ_FRAMEBUFFER binding is separate from GL_FRAMEBUFFER, so
        // querying attachments while only READ is bound reports the window
        // surface (and hides the real attachment).
        glBindFramebuffer(GL_FRAMEBUFFER, framebufferToPresent);
        if (rendererDebugEnabled() && swapCount <= 3) {
            GLint attachedRenderbuffer = 0;
            glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                                  GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,
                                                  &attachedRenderbuffer);
            GLint attachedWidth = 0, attachedHeight = 0;
            if (attachedRenderbuffer != 0) {
                glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)attachedRenderbuffer);
                glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &attachedWidth);
                glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &attachedHeight);
            }
            unsigned char sourcePixel[4] = {0, 0, 0, 0};
            glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, sourcePixel);
            NSLog(@"[compat] source FBO %u attachmentRBO=%d size=%dx%d pixel=%02x%02x%02x%02x status=0x%x error=0x%x",
                  framebufferToPresent, attachedRenderbuffer, attachedWidth, attachedHeight,
                  sourcePixel[0], sourcePixel[1], sourcePixel[2], sourcePixel[3],
                  glCheckFramebufferStatus(GL_FRAMEBUFFER), glGetError());
        }
        const bool copied = copyFramebufferToWindow(
            framebufferToPresent,
            sourceWidth,
            sourceHeight,
            targetWidth,
            targetHeight
        );
        if (!copied && (swapCount <= 3 || swapCount % 120 == 0)) {
            NSLog(@"[compat] failed to copy FBO %u to EGL window", framebufferToPresent);
        }
    }
    EGLSurface surf = _drawSurface ? _drawSurface : _surface;
    return eglSwapBuffers_ptr(s_display, surf);
}

- (void)registerEngineFramebuffer:(unsigned int)framebuffer
                     renderbuffer:(unsigned int)renderbuffer
                              size:(CGSize)size {
    s_engineFramebuffer = (GLuint)framebuffer;
    s_engineRenderbuffer = (GLuint)renderbuffer;
    s_engineWidth = (GLsizei)MAX(1.0, size.width);
    s_engineHeight = (GLsizei)MAX(1.0, size.height);

    // Recreate the storage on the exact renderbuffer reported by the static
    // renderer. This is idempotent and repairs the transient default-RBO
    // binding ANGLE can expose around presentRenderbuffer:.
    glBindFramebuffer(GL_FRAMEBUFFER, s_engineFramebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, s_engineRenderbuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, s_engineWidth, s_engineHeight);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                              GL_RENDERBUFFER, s_engineRenderbuffer);
    NSLog(@"[compat] registered engine FBO=%u RBO=%u size=%dx%d status=0x%x error=0x%x",
          s_engineFramebuffer, s_engineRenderbuffer, s_engineWidth, s_engineHeight,
          glCheckFramebufferStatus(GL_FRAMEBUFFER), glGetError());
}

- (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable {
    NSLog(@"[compat] renderbufferStorage target=%lu drawable=%@", (unsigned long)target, [drawable class]);
    if (![drawable isKindOfClass:NSClassFromString(@"CAMetalLayer")]) {
        NSLog(@"EAGLContext: drawable must be CAMetalLayer, got %@", [drawable class]);
        return NO;
    }

    CAMetalLayer* layer = (__bridge CAMetalLayer*)(__bridge void*)drawable;
    _drawable = drawable;
    if (!s_metalDevice) {
        NSLog(@"EAGLContext: ANGLE Metal device unavailable");
        return NO;
    }
    // Use the exact id<MTLDevice> returned by EGL_ANGLE_device_metal before
    // ANGLE creates the window surface. SpatialPresenter receives this same
    // object and creates no independent device.
    layer.device = s_metalDevice;

    // Share the window surface across all contexts (CAMetalLayer can only have one).
    if (s_windowSurface == EGL_NO_SURFACE) {
        EGLint winAttrs[] = { EGL_NONE };
        s_windowSurface = eglCreateWindowSurface_ptr(s_display, s_config, layer, winAttrs);
    } else {
        NSLog(@"EAGLContext: reusing shared window surface");
    }
    _drawSurface = s_windowSurface;

    if (_drawSurface == EGL_NO_SURFACE) {
        EGLint err = eglGetError_ptr();
        NSLog(@"EAGLContext: eglCreateWindowSurface failed. EGL error=0x%x", err);
        NSLog(@"  CAMetalLayer device=%p size=%.0fx%.0f scale=%.1f", (__bridge void*)layer.device, layer.drawableSize.width, layer.drawableSize.height, layer.contentsScale);
        return NO;
    }

    eglMakeCurrent_ptr(s_display, _drawSurface, _drawSurface, _ctx);

    // EAGL's renderbufferStorage:fromDrawable: allocates storage for the
    // renderbuffer that the iOS renderer has already bound and attached to its
    // framebuffer. Creating only an EGL window surface leaves that RBO with
    // zero dimensions, producing GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT.
    if (target == GL_RENDERBUFFER) {
        GLint renderbuffer = 0;
        glGetIntegerv(GL_RENDERBUFFER_BINDING, &renderbuffer);
        GLint framebuffer = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &framebuffer);
        if (renderbuffer != 0) {
            const CGSize size = layer.drawableSize;
            s_engineFramebuffer = framebuffer > 0 ? (GLuint)framebuffer : s_engineFramebuffer;
            s_engineRenderbuffer = (GLuint)renderbuffer;
            s_engineWidth = (GLsizei)MAX(1.0, size.width);
            s_engineHeight = (GLsizei)MAX(1.0, size.height);
            glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES,
                                  s_engineWidth, s_engineHeight);
            NSLog(@"[compat] renderbuffer %d storage=%zux%zu error=0x%x",
                  renderbuffer, (size_t)s_engineWidth, (size_t)s_engineHeight, glGetError());
        }
    }
    NSLog(@"EAGLContext: surface created successfully! device=%p", (__bridge void*)layer.device);
    return YES;
}

- (void)dealloc {
    if (_ctx != EGL_NO_CONTEXT) {
        eglMakeCurrent_ptr(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        // s_windowSurface is shared by every compatibility EAGLContext and is
        // owned for the lifetime of the process. Destroying it from one
        // context invalidates all remaining contexts.
        if (_surface != EGL_NO_SURFACE && _surface != s_windowSurface) {
            eglDestroySurface_ptr(s_display, _surface);
        }
        eglDestroyContext_ptr(s_display, _ctx);
    }
}

@end
