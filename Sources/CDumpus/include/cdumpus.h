#ifndef CDUMPUS_H
#define CDUMPUS_H

#include <stdint.h>

// Receive a file descriptor sent with SCM_RIGHTS (authopen -stdoutpipe).
int recv_fd(int sock);

// Block size and block count of a disk device (DKIOCGETBLOCKSIZE / DKIOCGETBLOCKCOUNT).
int disk_geometry(int fd, uint32_t *block_size, uint64_t *block_count);

#endif
