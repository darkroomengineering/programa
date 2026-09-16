#ifndef PROGRAMA_TERMINAL_H
#define PROGRAMA_TERMINAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define PROGRAMA_TERMINAL_API __declspec(dllimport)
#else
#define PROGRAMA_TERMINAL_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ProgramaTerminalSession ProgramaTerminalSession;
typedef struct ProgramaTerminalBuffer { uint8_t *data; size_t len; } ProgramaTerminalBuffer;

enum ProgramaTerminalStatus { PROGRAMA_TERMINAL_OK = 0, PROGRAMA_TERMINAL_INVALID_ARGUMENT = 1, PROGRAMA_TERMINAL_FAILED = 2 };
enum ProgramaTerminalSelectionMode { PROGRAMA_TERMINAL_SELECTION_SIMPLE = 0, PROGRAMA_TERMINAL_SELECTION_BLOCK = 1, PROGRAMA_TERMINAL_SELECTION_WORD = 2, PROGRAMA_TERMINAL_SELECTION_LINE = 3 };

PROGRAMA_TERMINAL_API ProgramaTerminalSession *programa_terminal_create(const uint8_t *config_json, size_t config_len, ProgramaTerminalBuffer *error);
PROGRAMA_TERMINAL_API void programa_terminal_free(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_write(ProgramaTerminalSession *session, const uint8_t *data, size_t len);
PROGRAMA_TERMINAL_API int32_t programa_terminal_resize(ProgramaTerminalSession *session, uint16_t cols, uint16_t rows, uint16_t cell_width, uint16_t cell_height);
PROGRAMA_TERMINAL_API int32_t programa_terminal_scroll(ProgramaTerminalSession *session, int32_t lines);
PROGRAMA_TERMINAL_API int32_t programa_terminal_scroll_to_bottom(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_snapshot_json(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API uint64_t programa_terminal_generation(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API bool programa_terminal_application_cursor(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API void *programa_terminal_event_handle(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_acknowledge_generation(ProgramaTerminalSession *session, uint64_t generation);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_begin(ProgramaTerminalSession *session, size_t col, size_t row, uint32_t mode);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_update(ProgramaTerminalSession *session, size_t col, size_t row);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_end(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_clear(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_copy_selection(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API int32_t programa_terminal_paste(ProgramaTerminalSession *session, const uint8_t *data, size_t len, bool bracketed);
PROGRAMA_TERMINAL_API bool programa_terminal_is_terminated(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_last_error(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API void programa_terminal_buffer_free(uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
#endif
