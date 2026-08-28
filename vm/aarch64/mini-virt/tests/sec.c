/*
 * sec Linux 字符设备驱动最小 userspace 测试
 */

#include <fcntl.h>
#include <linux/sec.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define SEC_DEVICE "/dev/sec"

static int read_result(int fd, uint32_t expected)
{
	uint32_t result;
	ssize_t count;

	count = read(fd, &result, sizeof(result));
	if (count < 0) {
		perror("read " SEC_DEVICE);
		return -1;
	}
	if (count != sizeof(result)) {
		fprintf(stderr, "sec test: short read: %zd\n", count);
		return -1;
	}
	if (result != expected) {
		fprintf(stderr, "sec test: expected 0x%08x, got 0x%08x\n",
			expected, result);
		return -1;
	}

	return 0;
}

int main(void)
{
	const struct sec_operands operands = {
		.data1 = 0x12345678,
		.data2 = 0xa5a5ffff,
	};
	ssize_t count;
	int fd;
	int ret = 1;

	fd = open(SEC_DEVICE, O_RDWR);
	if (fd < 0) {
		perror("open " SEC_DEVICE);
		return 1;
	}

	count = write(fd, &operands, sizeof(operands));
	if (count < 0) {
		perror("write " SEC_DEVICE);
		goto out;
	}
	if (count != sizeof(operands)) {
		fprintf(stderr, "sec test: short write: %zd\n", count);
		goto out;
	}
	if (read_result(fd, 0xb791a987))
		goto out;

	if (ioctl(fd, SEC_IOC_CLEAR) < 0) {
		perror("ioctl SEC_IOC_CLEAR");
		goto out;
	}
	if (read_result(fd, 0))
		goto out;

	puts("sec test: PASS");
	ret = 0;

out:
	close(fd);
	return ret;
}
