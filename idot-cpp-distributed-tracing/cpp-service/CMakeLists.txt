cmake_minimum_required(VERSION 3.16)

project(cpp-service LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prefer IDOT package headers over any system-installed OpenTelemetry headers.
set(CMAKE_INCLUDE_DIRECTORIES_BEFORE ON)

# Default IDOT install prefix — override with -DCMAKE_PREFIX_PATH=<path>
if(NOT CMAKE_PREFIX_PATH)
  set(CMAKE_PREFIX_PATH "/tmp/opentelemetry-cpp")
endif()

# Locate the IDOT OpenTelemetry C++ package (ext_so = shared library on Linux).
find_package(opentelemetry-cpp CONFIG REQUIRED COMPONENTS ext_so)

# libcurl is required for outbound HTTP calls to java-receiver.
find_package(CURL REQUIRED)

add_executable(cpp-service
    src/main.cpp
)

# vendor/ holds the single-header cpp-httplib (httplib.h)
target_include_directories(cpp-service
    BEFORE PRIVATE
    ${OPENTELEMETRY_CPP_INCLUDE_DIRS}
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor
)

target_link_libraries(cpp-service PRIVATE
    opentelemetry-cpp::opentelemetry_cpp
    CURL::libcurl
)
