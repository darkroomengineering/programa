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
PROGRAMA_TERMINAL_API int32_t programa_terminal_kill(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API bool programa_terminal_is_hosted(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_write(ProgramaTerminalSession *session, const uint8_t *data, size_t len);
PROGRAMA_TERMINAL_API int32_t programa_terminal_resize(ProgramaTerminalSession *session, uint16_t cols, uint16_t rows, uint16_t cell_width, uint16_t cell_height);
PROGRAMA_TERMINAL_API int32_t programa_terminal_scroll(ProgramaTerminalSession *session, int32_t lines);
PROGRAMA_TERMINAL_API int32_t programa_terminal_snapshot_json(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API uint64_t programa_terminal_generation(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API uint64_t programa_terminal_program_status_generation(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_program_status_json(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
enum ProgramaTerminalMode { PROGRAMA_TERMINAL_MODE_APP_CURSOR = 1, PROGRAMA_TERMINAL_MODE_MOUSE_REPORTING = 2, PROGRAMA_TERMINAL_MODE_FOCUS_EVENTS = 4, PROGRAMA_TERMINAL_MODE_KITTY_DISAMBIGUATE = 8, PROGRAMA_TERMINAL_MODE_ALT_SCREEN = 16 };
enum ProgramaTerminalMouseAction { PROGRAMA_TERMINAL_MOUSE_PRESS = 0, PROGRAMA_TERMINAL_MOUSE_RELEASE = 1, PROGRAMA_TERMINAL_MOUSE_MOTION = 2 };
enum ProgramaTerminalMouseModifier { PROGRAMA_TERMINAL_MOUSE_SHIFT = 1, PROGRAMA_TERMINAL_MOUSE_ALT = 2, PROGRAMA_TERMINAL_MOUSE_CTRL = 4 };
PROGRAMA_TERMINAL_API uint32_t programa_terminal_mode(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API bool programa_terminal_mouse(ProgramaTerminalSession *session, uint32_t button, uint32_t action, size_t col, size_t row, uint32_t mods);
PROGRAMA_TERMINAL_API int32_t programa_terminal_focus(ProgramaTerminalSession *session, bool focused);
PROGRAMA_TERMINAL_API int32_t programa_terminal_wheel(ProgramaTerminalSession *session, int32_t lines, size_t col, size_t row, uint32_t mods);
PROGRAMA_TERMINAL_API int32_t programa_terminal_text(ProgramaTerminalSession *session, uint32_t max_lines, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API uint32_t programa_terminal_shell_pid(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API uint64_t programa_terminal_cwd_generation(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_cwd(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API int32_t programa_terminal_link_at(ProgramaTerminalSession *session, size_t column, size_t row, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_clear(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API bool programa_terminal_find(ProgramaTerminalSession *session, const uint8_t *text, size_t len, bool forward);
PROGRAMA_TERMINAL_API int32_t programa_terminal_clear_scrollback(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_take_notifications(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API int32_t programa_terminal_set_colors(ProgramaTerminalSession *session, const uint8_t *colors_json, size_t len);
PROGRAMA_TERMINAL_API int32_t programa_terminal_take_clipboard(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API void *programa_terminal_event_handle(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_acknowledge_generation(ProgramaTerminalSession *session, uint64_t generation);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_begin(ProgramaTerminalSession *session, size_t col, size_t row, uint32_t mode);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_update(ProgramaTerminalSession *session, size_t col, size_t row);
PROGRAMA_TERMINAL_API int32_t programa_terminal_selection_end(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_copy_selection(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API int32_t programa_terminal_paste(ProgramaTerminalSession *session, const uint8_t *data, size_t len, bool bracketed);
PROGRAMA_TERMINAL_API bool programa_terminal_is_terminated(ProgramaTerminalSession *session);
PROGRAMA_TERMINAL_API int32_t programa_terminal_last_error(ProgramaTerminalSession *session, ProgramaTerminalBuffer *out);
PROGRAMA_TERMINAL_API void programa_terminal_buffer_free(uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
#endif
