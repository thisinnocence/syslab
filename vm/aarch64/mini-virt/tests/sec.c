/* SEC 多 VF 的功能、所有权、并发和 SMMU fault 测试 */
#include <errno.h>
#include <fcntl.h>
#include <linux/sec.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#define VF_COUNT 4
#define LOOPS 200

#define CHECK(expr) do { \
	if (!(expr)) { \
		fprintf(stderr, "FAIL line %d: %s (errno=%d: %s)\n", \
			__LINE__, #expr, errno, strerror(errno)); \
		exit(1); \
	} \
} while (0)

static int open_vf(unsigned vf)
{
	char path[32];
	int fd;
	struct sec_vf_info info;

	snprintf(path, sizeof(path), "/dev/sec%u", vf);
	fd = open(path, O_RDWR | O_CLOEXEC);
	CHECK(fd >= 0);
	CHECK(ioctl(fd, SEC_IOC_GET_INFO, &info) == 0);
	CHECK(info.vf_id == vf && info.sid == vf + 1);
	CHECK(info.max_dma_len == SEC_DMA_MAX_LEN);
	return fd;
}

static uint32_t irq_count(int fd)
{
	uint32_t count;

	CHECK(ioctl(fd, SEC_IOC_GET_IRQ_COUNT, &count) == 0);
	return count;
}

static void result_is(int fd, uint32_t expected)
{
	uint32_t result;

	CHECK(read(fd, &result, sizeof(result)) == sizeof(result));
	CHECK(result == expected);
}

static uint32_t do_xor(int fd, unsigned vf, unsigned iteration)
{
	struct sec_operands operands = {
		.data1 = 0x12345678u ^ (vf << 24) ^ iteration,
		.data2 = 0xa5a5ffffu + iteration,
	};
	uint32_t expected = operands.data1 ^ operands.data2;

	CHECK(write(fd, &operands, sizeof(operands)) == sizeof(operands));
	result_is(fd, expected);
	return expected;
}

static void do_dma(int fd, unsigned vf, unsigned iteration)
{
	struct sec_dma_copy tx = { .len = 1 + iteration % SEC_DMA_MAX_LEN };

	for (unsigned j = 0; j < tx.len; j++)
		tx.src[j] = (uint8_t)(vf * 67 + iteration * 13 + j);
	CHECK(ioctl(fd, SEC_IOC_DMA_COPY, &tx) == 0);
	CHECK(memcmp(tx.src, tx.dst, tx.len) == 0);
}

static void expect_busy(unsigned vf)
{
	char path[32];
	int fd;

	snprintf(path, sizeof(path), "/dev/sec%u", vf);
	errno = 0;
	fd = open(path, O_RDWR);
	if (fd >= 0)
		close(fd);
	CHECK(fd == -1 && errno == EBUSY);
}

static void do_fault(int fd)
{
	uint32_t before = irq_count(fd);

	CHECK(ioctl(fd, SEC_IOC_TEST_FAULT) == 0);
	/* 一次有效 copy 预热 IOTLB，一次旧 IOVA fault，各有完成 IRQ */
	CHECK(irq_count(fd) == before + 2);
}

static void basic(unsigned vf, int fault)
{
	int fd = open_vf(vf);
	struct sec_vf_info info;
	struct sec_dma_copy invalid = { .len = 0 };
	uint32_t before = irq_count(fd);
	int duplicate;

	CHECK(ioctl(fd, SEC_IOC_GET_INFO, &info) == 0);
	expect_busy(vf);
	result_is(fd, 0);
	do_xor(fd, vf, 0);
	CHECK(irq_count(fd) == before + 1);
	CHECK(ioctl(fd, SEC_IOC_CLEAR) == 0);
	result_is(fd, 0);
	for (unsigned i = 0; i < SEC_DMA_MAX_LEN; i++)
		do_dma(fd, vf, i);
	CHECK(irq_count(fd) == before + 1 + SEC_DMA_MAX_LEN);
	CHECK(ioctl(fd, SEC_IOC_DMA_COPY, &invalid) == -1 && errno == EINVAL);
	invalid.len = SEC_DMA_MAX_LEN + 1;
	CHECK(ioctl(fd, SEC_IOC_DMA_COPY, &invalid) == -1 && errno == EINVAL);
	CHECK(ioctl(fd, _IO(SEC_IOC_MAGIC, 127)) == -1 && errno == ENOTTY);
	before = irq_count(fd);
	if (fault) {
		CHECK(info.flags & SEC_VF_F_FAULT_TEST);
		do_fault(fd);
		before += 2;
	} else if (!(info.flags & SEC_VF_F_FAULT_TEST)) {
		CHECK(ioctl(fd, SEC_IOC_TEST_FAULT) == -1 && errno == EOPNOTSUPP);
	}
	CHECK(ioctl(fd, SEC_IOC_RESET) == 0);
	result_is(fd, 0);
	CHECK(irq_count(fd) == before);
	do_dma(fd, vf, 63);
	CHECK(irq_count(fd) == before + 1);
	/* dup 共用同一 open file，最后一个引用关闭后才释放 VF */
	duplicate = dup(fd);
	CHECK(duplicate >= 0);
	CHECK(close(fd) == 0);
	expect_busy(vf);
	CHECK(close(duplicate) == 0);
	fd = open_vf(vf);
	result_is(fd, 0);
	CHECK(close(fd) == 0);
	printf("VF%u SID%u: XOR/DMA(1..64)/IRQ/reset/exclusive/dup%s PASS\n",
	       vf, info.sid, fault ? "/fault/recovery" : "");
}

static void reset_isolation(void)
{
	int fd[VF_COUNT];
	uint32_t expected[VF_COUNT], counts[VF_COUNT];

	for (unsigned i = 0; i < VF_COUNT; i++) {
		fd[i] = open_vf(i);
		expected[i] = do_xor(fd[i], i, 7);
		counts[i] = irq_count(fd[i]);
	}
	for (unsigned i = 0; i < VF_COUNT; i++) {
		CHECK(ioctl(fd[i], SEC_IOC_RESET) == 0);
		expected[i] = 0;
		for (unsigned j = 0; j < VF_COUNT; j++) {
			result_is(fd[j], expected[j]);
			CHECK(irq_count(fd[j]) == counts[j]);
		}
	}
	for (unsigned i = 0; i < VF_COUNT; i++)
		CHECK(close(fd[i]) == 0);
	puts("VF reset isolation: PASS");
}

static void wait_ok(pid_t pid)
{
	int status;

	CHECK(waitpid(pid, &status, 0) == pid);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void concurrent(int fault)
{
	int ready[2], start[2];
	pid_t children[VF_COUNT];
	char token;

	CHECK(pipe(ready) == 0 && pipe(start) == 0);
	for (unsigned vf = 0; vf < VF_COUNT; vf++) {
		children[vf] = fork();
		CHECK(children[vf] >= 0);
		if (!children[vf]) {
			int fd = open_vf(vf);
			uint32_t before = irq_count(fd), extra = 0;

			alarm(30);
			close(ready[0]);
			close(start[1]);
			CHECK(write(ready[1], "R", 1) == 1);
			close(ready[1]);
			CHECK(read(start[0], &token, 1) == 1);
			close(start[0]);
			for (unsigned i = 0; i < LOOPS; i++) {
				uint32_t expected = do_xor(fd, vf, i);

				do_dma(fd, vf, i);
				result_is(fd, expected);
				if (i % 17 == 0) {
					CHECK(ioctl(fd, SEC_IOC_RESET) == 0);
					result_is(fd, 0);
				}
				if (fault && vf == 0 && i == LOOPS / 2) {
					do_fault(fd);
					extra += 2;
				}
			}
			CHECK(irq_count(fd) == before + 2 * LOOPS + extra);
			CHECK(close(fd) == 0);
			printf("VF%u concurrent: %u iterations, %u IRQs PASS\n",
			       vf, LOOPS, 2 * LOOPS + extra);
			exit(0);
		}
	}
	close(ready[1]);
	close(start[0]);
	for (unsigned i = 0; i < VF_COUNT; i++)
		CHECK(read(ready[0], &token, 1) == 1);
	close(ready[0]);
	CHECK(write(start[1], "GGGG", VF_COUNT) == VF_COUNT);
	close(start[1]);
	for (unsigned i = 0; i < VF_COUNT; i++)
		wait_ok(children[i]);
	puts("Four-process data/IRQ isolation: PASS");
}

static void killed_owner(unsigned vf)
{
	int ready[2], status, fd;
	pid_t child;
	char token;

	CHECK(pipe(ready) == 0);
	child = fork();
	CHECK(child >= 0);
	if (!child) {
		alarm(30);
		close(ready[0]);
		fd = open_vf(vf);
		do_xor(fd, vf, 42);
		do_dma(fd, vf, 42);
		CHECK(write(ready[1], "R", 1) == 1);
		close(ready[1]);
		for (;;)
			pause();
	}
	close(ready[1]);
	CHECK(read(ready[0], &token, 1) == 1);
	close(ready[0]);
	expect_busy(vf);
	CHECK(kill(child, SIGKILL) == 0);
	CHECK(waitpid(child, &status, 0) == child);
	CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
	fd = open_vf(vf);
	result_is(fd, 0);
	do_dma(fd, vf, 42);
	CHECK(close(fd) == 0);
	printf("VF%u killed owner/reopen: PASS\n", vf);
}

int main(int argc, char **argv)
{
	unsigned vf = 0;
	int all = 0, fault = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	/* 防止失败的同步或独占测试无限等待，父子进程均使用有界超时 */
	alarm(60);
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--all")) {
			all = 1;
		} else if (!strcmp(argv[i], "--fault")) {
			fault = 1;
		} else if (!strcmp(argv[i], "--vf") && i + 1 < argc) {
			char *end;
			unsigned long value = strtoul(argv[++i], &end, 10);

			CHECK(*argv[i] && !*end && value < VF_COUNT);
			vf = value;
		} else {
			fprintf(stderr, "Usage: %s [--vf 0..3 | --all] [--fault]\n", argv[0]);
			return 1;
		}
	}
	if (all) {
		for (unsigned i = 0; i < VF_COUNT; i++)
			basic(i, fault);
		reset_isolation();
		concurrent(fault);
		for (unsigned i = 0; i < VF_COUNT; i++)
			killed_owner(i);
	} else {
		basic(vf, fault);
		killed_owner(vf);
	}
	puts("sec test: PASS");
	return 0;
}
