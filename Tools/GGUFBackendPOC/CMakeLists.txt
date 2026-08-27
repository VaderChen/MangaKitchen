cmake_minimum_required(VERSION 3.20)

project(MangaKitchenGGUFBackendPOC LANGUAGES CXX)

set(LLAMA_CPP_ROOT "" CACHE PATH "Path to the llama.cpp checkout")
set(LLAMA_CPP_BUILD "" CACHE PATH "Path to a built llama.cpp directory")

if(NOT EXISTS "${LLAMA_CPP_ROOT}/ggml/include/gguf.h")
    message(FATAL_ERROR "LLAMA_CPP_ROOT must contain ggml/include/gguf.h")
endif()

if(NOT EXISTS "${LLAMA_CPP_BUILD}/bin")
    message(FATAL_ERROR "LLAMA_CPP_BUILD must contain a bin directory")
endif()

find_library(GGML_BASE_LIBRARY
    NAMES ggml-base
    PATHS "${LLAMA_CPP_BUILD}/bin"
    NO_DEFAULT_PATH
)
find_library(GGML_LIBRARY
    NAMES ggml
    PATHS "${LLAMA_CPP_BUILD}/bin"
    NO_DEFAULT_PATH
)
find_library(GGML_CPU_LIBRARY
    NAMES ggml-cpu
    PATHS "${LLAMA_CPP_BUILD}/bin"
    NO_DEFAULT_PATH
)

if(NOT GGML_BASE_LIBRARY OR NOT GGML_LIBRARY OR NOT GGML_CPU_LIBRARY)
    message(FATAL_ERROR "Could not find llama.cpp ggml libraries in ${LLAMA_CPP_BUILD}/bin")
endif()

add_executable(gguf-backend-poc
    main.cpp
)

target_compile_features(gguf-backend-poc PRIVATE cxx_std_17)
target_include_directories(gguf-backend-poc PRIVATE
    "${LLAMA_CPP_ROOT}/ggml/include"
)
target_link_libraries(gguf-backend-poc PRIVATE
    "${GGML_LIBRARY}"
    "${GGML_CPU_LIBRARY}"
    "${GGML_BASE_LIBRARY}"
)

if(APPLE)
    set_target_properties(gguf-backend-poc PROPERTIES
        BUILD_RPATH "${LLAMA_CPP_BUILD}/bin"
        INSTALL_RPATH "@loader_path"
    )
elseif(UNIX)
    set_target_properties(gguf-backend-poc PROPERTIES
        BUILD_RPATH "${LLAMA_CPP_BUILD}/bin"
        INSTALL_RPATH "\$ORIGIN"
    )
endif()
