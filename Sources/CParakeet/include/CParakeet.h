#pragma once
#include <stddef.h>
typedef struct vb_engine vb_engine;
vb_engine *vb_open(const char *library, const char *model, char *error, size_t capacity);
void vb_close(vb_engine *engine);
char *vb_transcribe(vb_engine *engine, const float *samples, int count);
char *vb_vad(vb_engine *engine, const float *samples, int count);
char *vb_vad_refinement(vb_engine *engine, const float *samples, int count);
char *vb_diarize(vb_engine *engine, const float *samples, int count);
const char *vb_error(vb_engine *engine);
void vb_free(vb_engine *engine, char *text);
int vb_abi(vb_engine *engine);
/* Local voice identity: caller owns the returned vector and frees it with vb_free_embedding. */
int vb_embed(vb_engine *, const float *, int, float **, int *);
void vb_free_embedding(vb_engine *, float *);
const char *vb_voice_identity(vb_engine *);
const char *vb_voice_family(vb_engine *);
int vb_voice_dimension(vb_engine *);
typedef struct vb_voice_region { int speaker; float start; float end; } vb_voice_region;
void *vb_diar_begin(vb_engine *);
int vb_diar_feed(vb_engine *, void *, const float *, int, int, vb_voice_region **, int *);
void vb_diar_end(vb_engine *, void *);
void vb_free_regions(vb_voice_region *);
