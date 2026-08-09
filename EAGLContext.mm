#import "EAGLContext.h"
#include "NativeIOTrace.h"
#include <YoghourtSpatialPresenter.h>
#define GL_APICALL
#define GL_APIENTRY
#include <GLES2/gl2.h>
#include <EGL/egl.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

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
static std::unique_ptr<yoghourt_spatial::Presenter> s_spatialPresenter;
static GLsizei s_spatialWidth = 0;
static GLsizei s_spatialHeight = 0;
static std::vector<unsigned char> s_spatialRGBA;
static std::vector<unsigned char> s_spatialBGRA;
// Store an unretained opaque pointer: ARC does not permit a strong Objective-C
// object in a C thread-local slot. EAGLContext is owned by its view.
static __thread void* s_currentContext = nullptr;

// Function pointers — match exact names from libEGL.dylib
static PFNEGLGETDISPLAYPROC           eglGetDisplay_ptr;
static PFNEGLINITIALIZEPROC           eglInitialize_ptr;
static PFNEGLCHOOSECONFIGPROC         eglChooseConfig_ptr;
static PFNEGLCREATECONTEXTPROC        eglCreateContext_ptr;
static PFNEGLCREATEWINDOWSURFACEPROC  eglCreateWindowSurface_ptr;
static PFNEGLCREATEPBUFFERSURFACEPROC eglCreatePbufferSurface_ptr;
static PFNEGLMAKECURRENTPROC          eglMakeCurrent_ptr;
static PFNEGLSWAPBUFFERSPROC          eglSwapBuffers_ptr;
static PFNEGLGETCURRENTCONTEXTPROC    eglGetCurrentContext_ptr;
static PFNEGLDESTROYCONTEXTPROC       eglDestroyContext_ptr;
static PFNEGLDESTROYSURFACEPROC       eglDestroySurface_ptr;
static PFNEGLTERMINATEPROC            eglTerminate_ptr;
typedef EGLint (*PFNEGLGETERRORPROC)(void);
static PFNEGLGETERRORPROC             eglGetError_ptr;
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

static void* s_eglHandle = nullptr;

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

static bool presentFramebufferWithSpatialScaler(
    CAMetalLayer* layer,
    GLuint framebuffer,
    GLsizei width,
    GLsizei height
) {
    if (!spatialPresentationRequested() || !layer || framebuffer == 0 ||
        width <= 0 || height <= 0) {
        return false;
    }

    const size_t rowBytes = (size_t)width * 4;
    const size_t byteCount = rowBytes * (size_t)height;
    s_spatialRGBA.resize(byteCount);
    s_spatialBGRA.resize(byteCount);

    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    while (glGetError() != GL_NO_ERROR) {}
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, s_spatialRGBA.data());
    const GLenum readError = glGetError();
    if (readError != GL_NO_ERROR) {
        static bool reportedReadFailure = false;
        if (!reportedReadFailure) {
            reportedReadFailure = true;
            NSLog(@"[SpatialPresenter] Artemis framebuffer readback failed: 0x%x", readError);
        }
        return false;
    }

    // GLES readback is bottom-up RGBA; the shared presenter consumes top-down
    // BGRA. Convert in one pass while the data is already CPU-resident.
    for (GLsizei y = 0; y < height; ++y) {
        const unsigned char* source = s_spatialRGBA.data() +
            (size_t)(height - 1 - y) * rowBytes;
        unsigned char* destination = s_spatialBGRA.data() + (size_t)y * rowBytes;
        for (GLsizei x = 0; x < width; ++x) {
            destination[x * 4 + 0] = source[x * 4 + 2];
            destination[x * 4 + 1] = source[x * 4 + 1];
            destination[x * 4 + 2] = source[x * 4 + 0];
            destination[x * 4 + 3] = source[x * 4 + 3];
        }
    }

    if (!s_spatialPresenter || s_spatialWidth != width || s_spatialHeight != height) {
        yoghourt_spatial::Options options;
        options.scaler = spatialScalerMode();
        options.enableOverlayMask = false;
        s_spatialPresenter = std::make_unique<yoghourt_spatial::Presenter>(
            (__bridge void*)layer, width, height, options);
        s_spatialWidth = width;
        s_spatialHeight = height;
        NSLog(@"[SpatialPresenter] Artemis adapter source=%dx%d drawable=%.0fx%.0f scaler=%s readback=cpu",
              width, height, layer.drawableSize.width, layer.drawableSize.height,
              getenv("YOGHOURT_SPATIAL_SCALER") ?: getenv("YOGHOURT_ARTEMIS_SPATIAL_SCALER"));
    }
    if (!s_spatialPresenter->isActive()) {
        return false;
    }

    const yoghourt_spatial::CPUFrame frame = {
        s_spatialBGRA.data(),
        width,
        height,
        rowBytes,
        yoghourt_spatial::PixelFormat::bgra8Unorm,
    };
    return s_spatialPresenter->present(frame);
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
    BIND(eglInitialize);
    BIND(eglChooseConfig);
    BIND(eglCreateContext);
    BIND(eglCreateWindowSurface);
    BIND(eglCreatePbufferSurface);
    BIND(eglMakeCurrent);
    BIND(eglSwapBuffers);
    BIND(eglGetCurrentContext);
    BIND(eglDestroyContext);
    BIND(eglDestroySurface);
    BIND(eglTerminate);
    BIND(eglGetError);
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

static void initEGL() {
    static bool done = false;
    if (done) return;
    done = true;

    if (!loadEGL()) std::abort();

    s_display = eglGetDisplay_ptr(EGL_DEFAULT_DISPLAY);
    if (s_display == EGL_NO_DISPLAY) {
        fprintf(stderr, "EGL: no display\n");
        std::abort();
    }

    EGLint major, minor;
    if (!eglInitialize_ptr(s_display, &major, &minor)) {
        fprintf(stderr, "EGL: init failed\n");
        std::abort();
    }
    printf("EGL %d.%d initialized\n", major, minor);

    EGLint attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
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
        std::abort();
    }

    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    s_shareCtx = eglCreateContext_ptr(s_display, s_config, EGL_NO_CONTEXT, ctxAttrs);
    printf("EGL: share context created\n");
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

    initEGL();

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
    if (presentFramebufferWithSpatialScaler(
            layer,
            framebufferToPresent,
            sourceWidth,
            sourceHeight)) {
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
        if (swapCount <= 3) {
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
