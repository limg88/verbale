#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct ve_library ve_library;
ve_library* ve_open(const char* path, char* error, size_t error_size);
int ve_process(ve_library*, const float* microphone, const float* reference,
               const uint8_t* covered, float* output, int count);
void ve_close(ve_library*);
