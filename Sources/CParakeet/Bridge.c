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
    void (*set_threads)(int);
    void (*shutdown_voice)(void);
    int (*embed)(parakeet_ctx *, const float *, int, int, float **, int *);
    void (*free_floats)(float *);
    const char *(*identity)(const parakeet_ctx *);
    const char *(*family)(const parakeet_ctx *);
    int (*dimension)(const parakeet_ctx *);
    parakeet_diar_stream *(*diar_begin)(parakeet_ctx *);
    int (*diar_feed)(parakeet_diar_stream *, const float *, int, int, parakeet_diar_segment **, int *);
    void (*diar_end)(parakeet_diar_stream *);
    void (*free_regions)(parakeet_diar_segment *);
};
static pthread_mutex_t lifecycle = PTHREAD_MUTEX_INITIALIZER;
static int live_contexts = 0;

vb_engine *vb_open(const char *path, const char *model, char *error, size_t size) {
    vb_engine *e = calloc(1, sizeof(*e));
    if (!e) { snprintf(error, size, "Memoria insufficiente"); return NULL; }
    e->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!e->library) { const char *reason = dlerror(); snprintf(error, size, "%s", reason ? reason : "Libreria Parakeet non caricabile"); free(e); return NULL; }
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
    RESOLVE(set_threads, "_ZN2pk15set_num_threadsEi");
    // Leave compute capacity for conferencing; upstream's desktop default is 8.
    e->set_threads(2);
    RESOLVE(embed, "parakeet_capi_speaker_embed_pcm");
    RESOLVE(free_floats, "parakeet_capi_free_floats");
    RESOLVE(identity, "parakeet_capi_speaker_identity");
    RESOLVE(family, "parakeet_capi_speaker_encoder_family");
    RESOLVE(dimension, "parakeet_capi_speaker_dim");
    RESOLVE(diar_begin, "parakeet_capi_diarize_stream_begin");
    RESOLVE(diar_feed, "parakeet_capi_diarize_stream_feed");
    RESOLVE(diar_end, "parakeet_capi_diarize_stream_free");
    RESOLVE(free_regions, "parakeet_capi_free_diar_segments");
    *(void **)(&e->shutdown_voice) = dlsym(e->library, "_ZN2vd16shutdown_backendEv");
    if (e->abi() != 11) { snprintf(error, size, "ABI Parakeet incompatibile: %d (richiesta 11)", e->abi()); goto fail; }
    e->context = e->load(model);
    if (!e->context) { const char *reason = e->load_error(); snprintf(error, size, "%s", reason ? reason : "Modello non caricabile"); goto fail; }
    live_contexts++; pthread_mutex_unlock(&lifecycle); return e;
fail:
    if (live_contexts == 0) { if (e->shutdown_voice) e->shutdown_voice(); if (e->shutdown) e->shutdown(); }
    pthread_mutex_unlock(&lifecycle);
    dlclose(e->library); free(e); return NULL;
}
void vb_close(vb_engine *e) {
    if (!e) return;
    pthread_mutex_lock(&lifecycle);
    e->release(e->context);
    if (--live_contexts == 0) { if (e->shutdown_voice) e->shutdown_voice(); e->shutdown(); }
    dlclose(e->library);
    pthread_mutex_unlock(&lifecycle); free(e);
}
char *vb_transcribe(vb_engine *e, const float *p, int n) { return e->transcribe(e->context,p,&n,1,16000,0); }
char *vb_vad(vb_engine *e, const float *p, int n) { return e->vad(e->context,p,n,16000,"{\"mode\":\"speech\",\"max_segment\":20}"); }
char *vb_vad_refinement(vb_engine *e, const float *p, int n) { return e->vad(e->context,p,n,16000,"{\"mode\":\"speech\",\"max_segment\":29.6,\"speech_pad\":0}"); }
char *vb_diarize(vb_engine *e, const float *p, int n) { return e->diarize(e->context,p,n,16000); }
const char *vb_error(vb_engine *e) { return e->error(e->context); }
void vb_free(vb_engine *e, char *p) { e->free_string(p); }
int vb_abi(vb_engine *e) { return e->abi(); }

int vb_embed(vb_engine *e, const float *p, int n, float **out, int *dim) { return e->embed(e->context,p,n,16000,out,dim); }
void vb_free_embedding(vb_engine *e, float *p) { e->free_floats(p); }
const char *vb_voice_identity(vb_engine *e) { return e->identity(e->context); }
const char *vb_voice_family(vb_engine *e) { return e->family(e->context); }
int vb_voice_dimension(vb_engine *e) { return e->dimension(e->context); }
void *vb_diar_begin(vb_engine *e) { return e->diar_begin(e->context); }
int vb_diar_feed(vb_engine *e, void *s, const float *p, int n, int last, vb_voice_region **out, int *count) {
    parakeet_diar_segment *regions = NULL; int size = 0;
    *out = NULL; *count = 0;
    int status = e->diar_feed((parakeet_diar_stream *)s,p,n,last,&regions,&size);
    if (status != 0) { if (regions) e->free_regions(regions); return status; }
    if (size > 0) {
        vb_voice_region *copy = calloc((size_t)size,sizeof(*copy));
        if (!copy) { e->free_regions(regions); return -1; }
        for (int i=0;i<size;i++) { copy[i].speaker=regions[i].speaker; copy[i].start=regions[i].start; copy[i].end=regions[i].end; }
        *out=copy; *count=size;
    }
    if (regions) e->free_regions(regions);
    return 0;
}
void vb_diar_end(vb_engine *e, void *s) { if (s) e->diar_end((parakeet_diar_stream *)s); }
void vb_free_regions(vb_voice_region *p) { free(p); }
