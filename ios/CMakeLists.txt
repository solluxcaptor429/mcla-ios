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
set(MCLA_GAME_VERSION "0.3.14" CACHE STRING "CFBundleShortVersionString: the mcla-recomp release built")

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

# Third-party headers the SDK's public headers include. An installed SDK has
# them in its include folder; a source tree has them here.
set(MCLA_SDK_THIRDPARTY_INCLUDES
    "${REXSDK_DIR}/thirdparty/imgui"
    "${REXSDK_DIR}/thirdparty/renderdoc"
    "${REXSDK_DIR}/thirdparty/xxHash"
    "${REXSDK_DIR}/thirdparty/utfcpp/source"
    "${REXSDK_DIR}/thirdparty/o1heap/o1heap"
    "${REXSDK_DIR}/thirdparty/disruptorplus/include")

# --- The recompiled game code ---------------------------------------------------------
include("${MCLA_GENERATED_DIR}/sources.cmake")

add_library(mcla_recomp OBJECT ${GENERATED_SOURCES})
target_include_directories(mcla_recomp PRIVATE
    "${MCLA_FORK_DIR}"
    "${MCLA_FORK_DIR}/src"
    "${MCLA_GENERATED_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/include")
target_include_directories(mcla_recomp SYSTEM PRIVATE ${MCLA_SDK_THIRDPARTY_INCLUDES})
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
# The fork's host, exactly the sources its own CMakeLists.txt builds (read from
# it, so a new release's new files come along), plus what only iOS needs.
file(READ "${MCLA_FORK_DIR}/CMakeLists.txt" _mcla_fork_cmake)
# The block runs from "set(MCLA_SOURCES" to the first line that is only ")"
# (its comments have parentheses of their own).
string(FIND "${_mcla_fork_cmake}" "set(MCLA_SOURCES" _mcla_begin)
if(_mcla_begin LESS 0)
    message(FATAL_ERROR "No set(MCLA_SOURCES ...) in ${MCLA_FORK_DIR}/CMakeLists.txt")
endif()
string(SUBSTRING "${_mcla_fork_cmake}" ${_mcla_begin} -1 _mcla_sources_block)
string(FIND "${_mcla_sources_block}" "\n)" _mcla_end)
string(SUBSTRING "${_mcla_sources_block}" 0 ${_mcla_end} _mcla_sources_block)
string(REGEX MATCHALL "src/[A-Za-z0-9_]+[.]cpp" _mcla_host_relative "${_mcla_sources_block}")
set(MCLA_HOST_SOURCES)
foreach(_rel IN LISTS _mcla_host_relative)
    list(APPEND MCLA_HOST_SOURCES "${MCLA_FORK_DIR}/${_rel}")
endforeach()
list(LENGTH MCLA_HOST_SOURCES _mcla_host_count)
message(STATUS "mcla host: ${_mcla_host_count} sources from the fork")

# The save sync (sync/mclasync.go, built as a C archive by the workflow).
set(MCLA_SYNC_LIB "" CACHE FILEPATH "libmclasync.a (empty: no save sync)")

add_executable(mcla MACOSX_BUNDLE
    ${MCLA_HOST_SOURCES}
    ios_support.mm
    ios_sync.mm)
target_include_directories(mcla PRIVATE
    "${MCLA_FORK_DIR}"
    "${MCLA_FORK_DIR}/src"
    "${MCLA_GENERATED_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}/include")
target_include_directories(mcla SYSTEM PRIVATE ${MCLA_SDK_THIRDPARTY_INCLUDES})
target_compile_options(mcla PRIVATE -fno-strict-aliasing -fno-char8_t -ffp-contract=off)
set_source_files_properties(ios_support.mm ios_sync.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
if(MCLA_SYNC_LIB)
    get_filename_component(_mcla_sync_dir "${MCLA_SYNC_LIB}" DIRECTORY)
    target_compile_definitions(mcla PRIVATE MCLA_HAVE_SYNC=1)
    target_include_directories(mcla PRIVATE "${_mcla_sync_dir}")
    # The Go runtime's own needs: the system's TLS roots (Security), name
    # resolution (resolv).
    target_link_libraries(mcla PRIVATE "${MCLA_SYNC_LIB}"
        "-framework Security" "-framework CoreFoundation" "-framework SystemConfiguration" resolv)
    message(STATUS "mcla: save sync from ${MCLA_SYNC_LIB}")
else()
    message(STATUS "mcla: no save sync")
endif()

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
