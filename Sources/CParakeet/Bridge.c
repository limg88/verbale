#include "CParakeet.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include "../../native/parakeet.cpp/include/parakeet_capi.h"

struct vb_engine {
    void *library;
    parakeet_ctx *context;
    int (*abi)(void);
    parakeet_ctx *(*load)(const char *);
    void (*release)(parakeet_ctx *);
    char *(*transcribe)(parakeet_ctx *, const float *, const int *, int, int, int);
    char *(*vad)(parakeet_ctx *, const float *, int, int, const char *);
    char *(*diarize)(parakeet_ctx *, const float *, int, int);
    const char *(*error)(parakeet_ctx *);
    const char *(*load_error)(void);
    void (*free_string)(char *);
    void (*shutdown)(void);
};
static pthread_mutex_t lifecycle = PTHREAD_MUTEX_INITIALIZER;
static int live_contexts = 0;

vb_engine *vb_open(const char *path, const char *model, char *error, size_t size) {
    vb_engine *e = calloc(1, sizeof(*e));
    if (!e) { snprintf(error, size, "Memoria insufficiente"); return NULL; }
    e->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!e->library) { snprintf(error, size, "%s", dlerror()); free(e); return NULL; }
    pthread_mutex_lock(&lifecycle);
#define RESOLVE(field, symbol) do { *(void **)(&e->field) = dlsym(e->library, symbol); \
    if (!e->field) { snprintf(error, size, "Simbolo richiesto assente: %s", symbol); goto fail; } } while(0)
    RESOLVE(abi, "parakeet_capi_abi_version");
    RESOLVE(load, "parakeet_capi_load");
    RESOLVE(release, "parakeet_capi_free");
    RESOLVE(transcribe, "parakeet_capi_transcribe_pcm_batch_json");
    RESOLVE(vad, "parakeet_capi_vad_pcm_json");
    RESOLVE(diarize, "parakeet_capi_diarize_pcm");
    RESOLVE(error, "parakeet_capi_last_error");
    RESOLVE(load_error, "parakeet_capi_load_error");
    RESOLVE(free_string, "parakeet_capi_free_string");
    // Private lifecycle hook of the exact locked source revision. The global
    // backend must die before ggml's Metal registry, and after all model buffers.
    RESOLVE(shutdown, "_ZN2pk16shutdown_backendEv");
    if (e->abi() != 11) { snprintf(error, size, "ABI Parakeet incompatibile: %d (richiesta 11)", e->abi()); goto fail; }
    e->context = e->load(model);
    if (!e->context) { snprintf(error, size, "%s", e->load_error()); goto fail; }
    live_contexts++; pthread_mutex_unlock(&lifecycle); return e;
fail:
    if (live_contexts == 0 && e->shutdown) e->shutdown();
    pthread_mutex_unlock(&lifecycle);
    dlclose(e->library); free(e); return NULL;
}
void vb_close(vb_engine *e) {
    if (!e) return;
    pthread_mutex_lock(&lifecycle);
    e->release(e->context);
    if (--live_contexts == 0) e->shutdown();
    dlclose(e->library);
    pthread_mutex_unlock(&lifecycle); free(e);
}
char *vb_transcribe(vb_engine *e, const float *p, int n) { return e->transcribe(e->context,p,&n,1,16000,0); }
char *vb_vad(vb_engine *e, const float *p, int n) { return e->vad(e->context,p,n,16000,"{\"mode\":\"speech\",\"max_segment\":20}"); }
char *vb_diarize(vb_engine *e, const float *p, int n) { return e->diarize(e->context,p,n,16000); }
const char *vb_error(vb_engine *e) { return e->error(e->context); }
void vb_free(vb_engine *e, char *p) { e->free_string(p); }
int vb_abi(vb_engine *e) { return e->abi(); }
