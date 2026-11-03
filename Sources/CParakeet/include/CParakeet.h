#pragma once
#include <stddef.h>
typedef struct vb_engine vb_engine;
vb_engine *vb_open(const char *library, const char *model, char *error, size_t capacity);
void vb_close(vb_engine *engine);
char *vb_transcribe(vb_engine *engine, const float *samples, int count);
char *vb_vad(vb_engine *engine, const float *samples, int count);
char *vb_diarize(vb_engine *engine, const float *samples, int count);
const char *vb_error(vb_engine *engine);
void vb_free(vb_engine *engine, char *text);
int vb_abi(vb_engine *engine);
