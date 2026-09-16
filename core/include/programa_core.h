#ifndef PROGRAMA_CORE_H
#define PROGRAMA_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProgramaBuffer {
    uint8_t *data;
    size_t len;
    size_t capacity;
} ProgramaBuffer;

uint32_t programa_core_abi_version(void);
void *programa_core_create(void);
void programa_core_destroy(void *core);
int32_t programa_core_dispatch(
    void *core,
    const uint8_t *request,
    size_t len,
    ProgramaBuffer *result
);
int32_t programa_core_snapshot(void *core, ProgramaBuffer *result);
void programa_core_buffer_free(ProgramaBuffer buffer);

#ifdef __cplusplus
}
#endif

#endif
