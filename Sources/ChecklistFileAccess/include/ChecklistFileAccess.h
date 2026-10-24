#ifndef CHECKLIST_FILE_ACCESS_H
#define CHECKLIST_FILE_ACCESS_H
#include <stdint.h>
#include <sys/types.h>
// Serialized by Core's folder queue. At most two retired generations per call.
int checklist_open_bounded(const char *path, int timeout_ms, int barrier_fd, pid_t retired[2], pid_t *worker);
void checklist_reap_idle_folder_helper(void);
#endif
