cmake_minimum_required(VERSION 3.20)
project(Artemis LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.6")

set(YOGHOURT_SPATIAL_PRESENTER_DIR "" CACHE PATH
    "Path to Yoghourt's shared SpatialPresenter sources")
if(NOT YOGHOURT_SPATIAL_PRESENTER_DIR OR
   NOT EXISTS "${YOGHOURT_SPATIAL_PRESENTER_DIR}/YoghourtSpatialPresenter.mm")
    message(FATAL_ERROR
        "Set YOGHOURT_SPATIAL_PRESENTER_DIR to RuntimeSupport/SpatialPresenter")
endif()

# ANGLE — GLES2+EGL (Metal backend)
set(ARTEMIS_SDK_DIR "" CACHE PATH "Directory containing the user-supplied native Artemis SDK libraries")
if(NOT ARTEMIS_SDK_DIR)
    message(FATAL_ERROR "Set ARTEMIS_SDK_DIR to Vendor/ArtemisNative")
endif()
set(LIBS_DIR "${ARTEMIS_SDK_DIR}")
add_library(ANGLE_EGL SHARED IMPORTED)
set_target_properties(ANGLE_EGL PROPERTIES IMPORTED_LOCATION "${LIBS_DIR}/libEGL.dylib")
add_library(ANGLE_GLESv2 SHARED IMPORTED)
set_target_properties(ANGLE_GLESv2 PROPERTIES IMPORTED_LOCATION "${LIBS_DIR}/libGLESv2.dylib")

# FreeType
find_package(Freetype REQUIRED)

# Source files
set(SOURCES
    main.mm
    AppDelegate.mm
    MetalGLView.mm
    EAGLContext.mm
    UICompat.mm
    PlatformStub.mm
    NativeIOTrace.mm
    "${YOGHOURT_SPATIAL_PRESENTER_DIR}/YoghourtSpatialPresenter.mm"
)

# Artemis static library (patched for macOS)
set(ARTEMIS_STATIC_ORIGINAL "${LIBS_DIR}/libartemis_static_macos.a")
set(ARTEMIS_STATIC_PATCHED "${CMAKE_BINARY_DIR}/libartemis_static_native_io.a")
add_custom_command(
    OUTPUT "${ARTEMIS_STATIC_PATCHED}"
    COMMAND /usr/bin/perl
        "${CMAKE_SOURCE_DIR}/patch_static_io_symbols.pl"
        "${ARTEMIS_STATIC_ORIGINAL}"
        "${ARTEMIS_STATIC_PATCHED}"
    DEPENDS
        "${ARTEMIS_STATIC_ORIGINAL}"
        "${CMAKE_SOURCE_DIR}/patch_static_io_symbols.pl"
    VERBATIM
)
add_custom_target(artemis_static_native_io DEPENDS "${ARTEMIS_STATIC_PATCHED}")
add_library(artemis_static STATIC IMPORTED)
set_target_properties(artemis_static PROPERTIES
    IMPORTED_LOCATION "${ARTEMIS_STATIC_PATCHED}"
)

# Main executable
add_executable(ArtemisPlayer MACOSX_BUNDLE ${SOURCES})
add_dependencies(ArtemisPlayer artemis_static_native_io)

target_include_directories(ArtemisPlayer PRIVATE
    "${CMAKE_SOURCE_DIR}"
    "${YOGHOURT_SPATIAL_PRESENTER_DIR}"
    "${LIBS_DIR}"
    ${FREETYPE_INCLUDE_DIRS}
)

target_link_libraries(ArtemisPlayer
    artemis_static
    ANGLE_GLESv2
    ANGLE_EGL
    ${FREETYPE_LIBRARIES}
    "-framework Metal"
    "-framework MetalFX"
    "-framework QuartzCore"
    "-framework AppKit"
    "-framework Foundation"
    "-framework CoreVideo"
    "-framework AVFoundation"
    "-framework AudioToolbox"
    "-framework CoreAudio"
    "-framework IOKit"
    "-framework IOSurface"
    "-lz"
    "-lbz2"
    "-lc++"
)

# iOS static lib converted via vtool: LC_VERSION_MIN_IPHONEOS → macos

# Objective-C++ flags
set_target_properties(ArtemisPlayer PROPERTIES
    COMPILE_FLAGS "-fobjc-arc -fobjc-weak"
    BUILD_RPATH "@executable_path/../Frameworks"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
)

# Copy dylibs into bundle
add_custom_command(TARGET ArtemisPlayer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_CONTENT_DIR:ArtemisPlayer>/Frameworks"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${LIBS_DIR}/libEGL.dylib"
        "$<TARGET_BUNDLE_CONTENT_DIR:ArtemisPlayer>/Frameworks/libEGL.dylib"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${LIBS_DIR}/libGLESv2.dylib"
        "$<TARGET_BUNDLE_CONTENT_DIR:ArtemisPlayer>/Frameworks/libGLESv2.dylib"
    COMMAND install_name_tool -change "./libGLESv2.dylib"
        "@executable_path/../Frameworks/libGLESv2.dylib"
        "$<TARGET_FILE:ArtemisPlayer>"
    COMMAND install_name_tool -change "./libEGL.dylib"
        "@executable_path/../Frameworks/libEGL.dylib"
        "$<TARGET_FILE:ArtemisPlayer>"
)

# Set bundle Info.plist
set_target_properties(ArtemisPlayer PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "ArtemisPlayer"
    MACOSX_BUNDLE_BUNDLE_VERSION "2.0"
)
