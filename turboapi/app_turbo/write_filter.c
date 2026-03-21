#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

static ssize_t (*real_write)(int fd, const void *buf, size_t count) = NULL;

ssize_t write(int fd, const void *buf, size_t count) {
    if (real_write == NULL) {
        real_write = dlsym(RTLD_NEXT, "write");
    }
    
    if (fd == 1 || fd == 2) {
        char *line = malloc(count + 1);
        memcpy(line, buf, count);
        line[count] = '\0';
        
        char *slash3 = strstr(line, "://");
        if (slash3) {
            char *colon2 = strchr(slash3 + 3, ':');
            char *at = strchr(slash3 + 3, '@');
            if (colon2 && at && colon2 < at) {
                size_t prefix_len = colon2 - line + 1;
                size_t suffix_start = at - line;
                
                char *result = malloc(prefix_len + 6 + (count - suffix_start) + 1);
                memcpy(result, line, prefix_len);
                strcpy(result + prefix_len, "****");
                strcpy(result + prefix_len + 4, line + suffix_start);
                
                ssize_t written = real_write(fd, result, strlen(result));
                free(result);
                free(line);
                return count;
            }
        }
        
        free(line);
    }
    
    return real_write(fd, buf, count);
}
