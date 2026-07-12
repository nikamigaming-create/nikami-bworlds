cmake_minimum_required(VERSION 3.18...4.0.2)

project(nikami_starfield_oracle LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../sfse_common" "${CMAKE_CURRENT_BINARY_DIR}/sfse_common")

add_library(nikami_starfield_oracle SHARED
    src/main.cpp
    exports.def
)

target_compile_features(nikami_starfield_oracle PRIVATE cxx_std_17)
target_compile_definitions(nikami_starfield_oracle PRIVATE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    RUNTIME
    RUNTIME_VERSION=0x01100F40
)
target_include_directories(nikami_starfield_oracle PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_link_libraries(nikami_starfield_oracle PRIVATE sfse::sfse_common)
set_target_properties(nikami_starfield_oracle PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL"
    PREFIX ""
)
