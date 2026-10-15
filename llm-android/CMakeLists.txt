cmake_minimum_required(VERSION 3.20)
project(rime_llm_android CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(RIME_LLM_REPACK "Enable llama.cpp CPU weight repacking (faster, ~+500 MB private memory)" OFF)
option(RIME_LLM_VULKAN "Build the Vulkan backend (experimental)" OFF)

# llama.cpp：静态链接，不构建示例/测试/服务器；交叉编译不能用 -mcpu=native，指定 ARM 指令集
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH "armv8.6-a+dotprod+i8mm+fp16" CACHE STRING "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_CURL OFF CACHE BOOL "" FORCE)
if(RIME_LLM_VULKAN)
  set(GGML_VULKAN ON CACHE BOOL "" FORCE)
endif()

set(LLAMA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../rime-llm-mac-port/llama.cpp" CACHE PATH "")
set(LUA_INC   "${CMAKE_CURRENT_SOURCE_DIR}/../../rime-llm-mac-port/deps/lua-5.4.6/src" CACHE PATH "")
add_subdirectory(${LLAMA_DIR} llama EXCLUDE_FROM_ALL)

# Lua C 模块。lua_* 符号由宿主（测试用的 lua 可执行文件 / Trime 的 librime_jni.so）在运行时提供。
add_library(rime_llm MODULE ../../rime-llm-mac-port/rime_llm_mac.cpp)
set_target_properties(rime_llm PROPERTIES PREFIX "" SUFFIX ".so")
target_include_directories(rime_llm PRIVATE ${LUA_INC} ${LLAMA_DIR}/include ${LLAMA_DIR}/ggml/include)
target_link_libraries(rime_llm PRIVATE llama log)
# lua_* 由宿主提供：
#  - 测试用的 lua 可执行文件：它导出了 lua_*，运行时解析即可，链接时允许未定义符号（-z undefs）
#  - Trime：链接它的 librime_jni.so（RIME_LLM_HOST_LIB），让加载器把 lua_* 解析到它
set(RIME_LLM_HOST_LIB "" CACHE FILEPATH "Host library that exports lua_* (e.g. Trime's librime_jni.so)")
if(RIME_LLM_HOST_LIB)
  target_link_libraries(rime_llm PRIVATE ${RIME_LLM_HOST_LIB})
else()
  target_link_options(rime_llm PRIVATE -Wl,-z,undefs)
endif()
target_compile_definitions(rime_llm PRIVATE RIME_LLM_REPACK=$<BOOL:${RIME_LLM_REPACK}>)
if(RIME_LLM_VULKAN)
  target_compile_definitions(rime_llm PRIVATE RIME_LLM_GPU_LAYERS=99)
endif()

# ---- 守护进程方案（推荐）：推理在独立进程 rimellmd 里，Trime 里只放一个轻量客户端 ----
# rimellmd：可执行文件，内嵌 Lua 5.4 核心 + 同一份推理引擎；以 shell 身份由 adb/Shizuku 拉起（见 daemon/rimellmctl.sh）
file(GLOB LUA_CORE_SRC ${LUA_INC}/*.c)
list(FILTER LUA_CORE_SRC EXCLUDE REGEX "/(lua|luac)\\.c$")
add_library(lua_core STATIC ${LUA_CORE_SRC})
target_compile_definitions(lua_core PRIVATE LUA_USE_POSIX)
target_include_directories(lua_core PUBLIC ${LUA_INC})
add_executable(rimellmd daemon/rimellmd.cpp ../../rime-llm-mac-port/rime_llm_mac.cpp)
target_include_directories(rimellmd PRIVATE ${LUA_INC} ${LLAMA_DIR}/include ${LLAMA_DIR}/ggml/include)
target_link_libraries(rimellmd PRIVATE lua_core llama log)
target_compile_definitions(rimellmd PRIVATE RIME_LLM_REPACK=$<BOOL:${RIME_LLM_REPACK}>)
target_link_options(rimellmd PRIVATE -Wl,--gc-sections)

# librime_llm.so：Trime 里的客户端（库名 lib*.so，随 APK 打包进 lib/arm64-v8a/，由系统加载器按名字解析）
add_library(rime_llm_client MODULE daemon/rime_llm_client.cpp)
set_target_properties(rime_llm_client PROPERTIES PREFIX "lib" OUTPUT_NAME "rime_llm" SUFFIX ".so")
target_include_directories(rime_llm_client PRIVATE ${LUA_INC})
target_link_libraries(rime_llm_client PRIVATE log)
if(RIME_LLM_HOST_LIB)
  target_link_libraries(rime_llm_client PRIVATE ${RIME_LLM_HOST_LIB})
else()
  target_link_options(rime_llm_client PRIVATE -Wl,-z,undefs)
endif()
