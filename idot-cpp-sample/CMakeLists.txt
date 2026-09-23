cmake_minimum_required(VERSION 3.16)

project(otel-sample LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Prefer IDOT package headers over any system-installed OpenTelemetry headers.
set(CMAKE_INCLUDE_DIRECTORIES_BEFORE ON)

# Pass -DCMAKE_PREFIX_PATH=/path/to/otel-package to locate the IDOT package.
# Windows ships a DLL build (ext_dll); Linux and AIX ship a shared library (ext_so).
if(WIN32)
  find_package(opentelemetry-cpp CONFIG REQUIRED COMPONENTS ext_dll)
else()
  find_package(opentelemetry-cpp CONFIG REQUIRED COMPONENTS ext_so)
endif()

add_executable(otel-sample
    src/main.cpp
)

target_include_directories(otel-sample
    BEFORE PRIVATE
    ${OPENTELEMETRY_CPP_INCLUDE_DIRS}
)

target_link_libraries(otel-sample PRIVATE
    opentelemetry-cpp::opentelemetry_cpp
)

if(WIN32)
    # gethostname() requires Winsock.
    target_link_libraries(otel-sample PRIVATE ws2_32)

    # Copy opentelemetry_cpp.dll next to the executable after each build.
    add_custom_command(TARGET otel-sample POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:opentelemetry-cpp::opentelemetry_cpp>
            $<TARGET_FILE_DIR:otel-sample>
        COMMENT "Copying opentelemetry_cpp.dll to output directory"
    )
endif()
