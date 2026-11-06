#include "CEcho.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
struct ve_library {
    void* handle;
    int (*clean)(const float*, const float*, const uint8_t*, float*, int);
};
ve_library* ve_open(const char* path, char* error, size_t error_size) {
    ve_library* library = calloc(1, sizeof(*library));
    if (!library) return NULL;
    library->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (library->handle) library->clean = dlsym(library->handle, "ve_clean");
    if (!library->handle || !library->clean) {
        const char* message = dlerror();
        if (error && error_size) snprintf(error, error_size, "%s", message ? message : "AEC3 ABI non disponibile");
        ve_close(library); return NULL;
    }
    return library;
}
int ve_process(ve_library* library, const float* mic, const float* ref, const uint8_t* mask, float* out, int count) {
    return library ? library->clean(mic, ref, mask, out, count) : -1;
}
void ve_close(ve_library* library) {
    if (!library) return;
    if (library->handle) dlclose(library->handle);
    free(library);
}
