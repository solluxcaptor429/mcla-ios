# Midnight Club: Los Angeles (static recompilation) as an iOS app.
#
# One executable: the ReXGlue runtime and its Xenos GPU are linked in, the
# recompiled game code is compiled from sources generated on a PC
# (generated/default of an installed mcla-recomp), and MoltenVK is the only
# framework in the bundle.
#
#   cmake -G Ninja -S ios -B build \
#     -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
#     -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
#     -DREXSDK_DIR=<patched rexglue-sdk> -DMCLA_FORK_DIR=<mcla-recomp checkout> \
#     -DMCLA_GENERATED_DIR=<generated/default>

cmake_minimum_required(VERSION 3.25)
project(mcla LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(REXSDK_DIR "" CACHE PATH "Patched rexglue-sdk source tree")
set(MCLA_FORK_DIR "" CACHE PATH "mcla-recomp checkout (its src/ is the game's host code)")
set(MCLA_GENERATED_DIR "" CACHE PATH "generated/default: the recompiled game code")
set(MCLA_BUNDLE_ID "com.solluxcaptor.mcla" CACHE STRING "CFBundleIdentifier")
set(MCLA_BUNDLE_VERSION "1" CACHE STRING "CFBundleVersion")

foreach(_dir REXSDK_DIR MCLA_FORK_DIR MCLA_GENERATED_DIR)
    if(NOT IS_DIRECTORY "${${_dir}}")
        message(FATAL_ERROR "${_dir} is not a folder: '${${_dir}}'")
    endif()
endforeach()
if(NOT EXISTS "${MCLA_GENERATED_DIR}/sources.cmake")
    message(FATAL_ERROR "No sources.cmake in ${MCLA_GENERATED_DIR}: run codegen on the PC first")
endif()

# The SDK: Vulkan (on MoltenVK) only, no profiler, no FSR runtime.
set(REXGLUE_USE_VULKAN ON CACHE BOOL "" FORCE)
set(REXGLUE_ENABLE_TRACY OFF CACHE BOOL "" FORCE)
set(REXGLUE_ENABLE_FSR OFF CACHE BOOL "" FORCE)
set(REXGLUE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${REXSDK_DIR}" rexglue-sdk)

# --- The recompiled game code ---------------------------------------------------------
include("${MCLA_GENERATED_DIR}/sources.cmake")

add_library(mcla_recomp OBJECT ${GENERATED_SOURCES})
target_include_directories(mcla_recomp PRIVATE
    "${MCLA_FORK_DIR}"
    "${MCLA_FORK_DIR}/src"
    "${MCLA_GENERATED_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/include")
target_link_libraries(mcla_recomp PRIVATE rex::runtime)
rexglue_apply_target_settings(mcla_recomp)
target_precompile_headers(mcla_recomp PRIVATE "${MCLA_GENERATED_DIR}/mcla_pch.h")
# No fused multiply-add: the x86 builds never fuse (SSE4.1), and guest floating
# point (physics, replays) must come out the same here. -w: 130 MB of generated
# code, whose warnings help nobody and would quote it into the build log.
set(MCLA_GUEST_OPTIONS -O3 -fno-strict-aliasing -fno-char8_t -ffp-contract=off -g0 -w)
target_compile_options(mcla_recomp PRIVATE ${MCLA_GUEST_OPTIONS})

# The sources include "generated/default/mcla_init.h" relative to the fork's
# root; the generated folder may be anywhere, so give them that path.
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include/generated")
file(CREATE_LINK "${MCLA_GENERATED_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/include/generated/default"
     SYMBOLIC)

# --- The host ---------------------------------------------------------------------------
# The fork's desktop host as it is (the list of mcla-recomp's CMakeLists.txt),
# plus what only iOS needs.
set(MCLA_HOST_NAMES
    main mcla_app aspect_ratio crash_trace audio_fallback audio_mixer fma_fast
    frame_timing render_perf perf_options poll_wait warp_fix button_prompts
    settings_menu pad_probe save_wait display_gamma render_markers
    vehicle_telemetry vibration stick_deadzone checkpoint_sweep pc_triggers
    sampling_profiler code_pointer_scan shader_prepare shader_storage_files
    dev_pad)
set(MCLA_HOST_SOURCES)
foreach(_name IN LISTS MCLA_HOST_NAMES)
    list(APPEND MCLA_HOST_SOURCES "${MCLA_FORK_DIR}/src/${_name}.cpp")
endforeach()

add_executable(mcla MACOSX_BUNDLE
    ${MCLA_HOST_SOURCES}
    ios_support.mm)
target_include_directories(mcla PRIVATE
    "${MCLA_FORK_DIR}"
    "${MCLA_FORK_DIR}/src"
    "${MCLA_GENERATED_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/include")
target_compile_options(mcla PRIVATE -fno-strict-aliasing -fno-char8_t -ffp-contract=off)
set_source_files_properties(ios_support.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

# Every object of the runtime and the GPU: both register things (kernel
# exports, settings) from static constructors, which a linker taking only the
# referenced members of an archive would drop.
target_link_libraries(mcla PRIVATE
    mcla_recomp
    "$<LINK_LIBRARY:WHOLE_ARCHIVE,rexruntime>"
    "$<LINK_LIBRARY:WHOLE_ARCHIVE,rexgpu-xenos>")
rexglue_configure_target(mcla)

target_link_libraries(mcla PRIVATE
    "-framework UIKit"
    "-framework Foundation"
    "-framework QuartzCore"
    "-framework Metal"
    "-framework GameController"
    "-framework AVFoundation"
    "-framework AudioToolbox"
    "-framework CoreHaptics")

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
               "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)
set_target_properties(mcla PROPERTIES
    OUTPUT_NAME "mcla"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${MCLA_BUNDLE_ID}")
