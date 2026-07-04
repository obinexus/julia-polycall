#ifndef JULIA_POLYCALL_H
#define JULIA_POLYCALL_H

#if defined(_WIN32) && defined(JULIA_POLYCALL_BUILD_SHARED)
#define JULIA_POLYCALL_API __declspec(dllexport)
#elif defined(__GNUC__) && defined(JULIA_POLYCALL_BUILD_SHARED)
#define JULIA_POLYCALL_API __attribute__((visibility("default")))
#else
#define JULIA_POLYCALL_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

JULIA_POLYCALL_API int julia_polycall_run_config(const char *config_path);

#ifdef __cplusplus
}
#endif

#endif
