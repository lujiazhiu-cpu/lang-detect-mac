cmake_minimum_required(VERSION 3.16)
project(FastTextBridge LANGUAGES CXX OBJCXX)

# =============================================================================
# CMakeLists.txt — 编译 fastText 静态库 + FastTextBridge 封装
# （任务B 方式1：C++ 静态库 + Swift bridging header）
#
# 前置：把 facebookresearch/fastText 源码放到 third_party/fastText
#   git clone --depth 1 https://github.com/facebookresearch/fastText third_party/fastText
#
# 构建：
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build -j
# 产物：build/libfasttext_bridge.a （连同 fastText 的目标一起归档）
# 之后在 swiftc/Xcode 里链接该静态库并引入 bridging header 即可。
# =============================================================================

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Universal binary")

set(FASTTEXT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/fastText")
if(NOT EXISTS "${FASTTEXT_DIR}/src/fasttext.cc")
    message(FATAL_ERROR "未找到 fastText 源码，请先: git clone --depth 1 https://github.com/facebookresearch/fastText ${FASTTEXT_DIR}")
endif()

# fastText 核心源文件
file(GLOB FASTTEXT_SRC "${FASTTEXT_DIR}/src/*.cc")

add_library(fasttext_bridge STATIC
    ${FASTTEXT_SRC}
    FastTextBridge.mm
)

# 头文件搜索：让 #include <fasttext.h> 生效（include 根 = fastText/src）
target_include_directories(fasttext_bridge PUBLIC
    "${FASTTEXT_DIR}/src"
    "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_compile_options(fasttext_bridge PRIVATE -O2 -fobjc-arc)
