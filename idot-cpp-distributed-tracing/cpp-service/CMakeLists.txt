cmake_minimum_required(VERSION 3.16)

project(cpp-service LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prefer OTel package headers over any system-installed OpenTelemetry headers.
set(CMAKE_INCLUDE_DIRECTORIES_BEFORE ON)

# Set the OpenTelemetry C++ install prefix via -DCMAKE_PREFIX_PATH=<path-to-otelcpp-install>
# or the IDOT_OTEL_CPP_INSTALL environment variable used by build.sh / build.ps1.
# Example: cmake -B build -DCMAKE_PREFIX_PATH=/opt/opentelemetry-cpp
#
# The IDOT package ships different shared-library components per platform:
#   Windows  → ext_dll   (opentelemetry_cpp.dll)
#   Linux    → ext_so    (libopentelemetry_cpp.so  under lib64/)
#   AIX      → ext_so    (libopentelemetry_cpp.so  under lib/)
if(WIN32)
    find_package(opentelemetry-cpp CONFIG REQUIRED COMPONENTS ext_dll)
else()
    find_package(opentelemetry-cpp CONFIG REQUIRED COMPONENTS ext_so)
endif()

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

if(WIN32)
    # gethostname() requires Winsock on Windows.
    target_link_libraries(cpp-service PRIVATE ws2_32)

    # Copy opentelemetry_cpp.dll next to the executable after each build
    # so it is found at run time without adding the SDK bin\ to PATH manually.
    add_custom_command(TARGET cpp-service POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:opentelemetry-cpp::opentelemetry_cpp>
            $<TARGET_FILE_DIR:cpp-service>
        COMMENT "Copying opentelemetry_cpp.dll to output directory"
    )
endif()
