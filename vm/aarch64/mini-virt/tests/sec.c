/*
 * sec Linux driver 最小 userspace 测试
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SEC_PATH "/sys/bus/platform/devices/a000000.sec/"

static int write_value(const char *name, const char *value)
{
    char path[128];
    size_t length = strlen(value);
    ssize_t written;
    int fd;

    snprintf(path, sizeof(path), "%s%s", SEC_PATH, name);
    fd = open(path, O_WRONLY);
    if (fd < 0) {
        perror(path);
        return -1;
    }

    written = write(fd, value, length);
    if (written < 0) {
        perror(path);
        close(fd);
        return -1;
    }
    if (written != (ssize_t)length) {
        fprintf(stderr, "%s: short write\n", path);
        close(fd);
        return -1;
    }

    close(fd);
    return 0;
}

static int expect_result(const char *expected)
{
    char value[32] = { 0 };
    int fd;

    fd = open(SEC_PATH "result", O_RDONLY);
    if (fd < 0) {
        perror(SEC_PATH "result");
        return -1;
    }

    if (read(fd, value, sizeof(value) - 1) < 0) {
        perror(SEC_PATH "result");
        close(fd);
        return -1;
    }

    close(fd);
    if (strcmp(value, expected) != 0) {
        fprintf(stderr, "sec test: expected %s, got %s", expected, value);
        return -1;
    }

    return 0;
}

int main(void)
{
    if (write_value("data1", "0x12345678\n") ||
        write_value("data2", "0xa5a5ffff\n") ||
        write_value("cmd", "1\n") ||
        expect_result("0xb791a987\n") ||
        write_value("cmd", "0\n") ||
        expect_result("0x00000000\n")) {
        return 1;
    }

    puts("sec test: PASS");
    return 0;
}
