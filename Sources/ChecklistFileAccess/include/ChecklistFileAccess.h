#ifndef CHECKLIST_FILE_ACCESS_H
#define CHECKLIST_FILE_ACCESS_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
// Serialized by Core's folder queue. At most two retired generations per call.
int checklist_open_bounded(const char *path, int timeout_ms, int barrier_fd, pid_t retired[2], pid_t *worker);
void checklist_reap_idle_folder_helper(void);
// Lexical skip after complete JSON validation. Returns 1 and the exclusive end
// offset on success, 0 on missing/truncated input. Reads only within count.
int checklist_json_value_end(const uint8_t *bytes, size_t count, size_t start, size_t *end);
#endif
