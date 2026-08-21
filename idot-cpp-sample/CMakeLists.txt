cmake_minimum_required(VERSION 3.16)

project(otel-sample LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Keep packaged OpenTelemetry headers ahead of any system installation.
set(CMAKE_INCLUDE_DIRECTORIES_BEFORE ON)

find_package(opentelemetry-cpp CONFIG REQUIRED COMPONENTS ext_so)

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