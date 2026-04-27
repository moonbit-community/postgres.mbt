#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

#include <moonbit.h>

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>

#pragma comment(lib, "Bcrypt.lib")
#else
#include <fcntl.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/syscall.h>
#endif
#endif

#if !defined(_WIN32) && !defined(__APPLE__) && !defined(__OpenBSD__) && !defined(__FreeBSD__) && !defined(__NetBSD__)
static int32_t read_urandom(uint8_t *buf, size_t len) {
  int fd = open(
    "/dev/urandom",
    O_RDONLY
#ifdef O_CLOEXEC
      | O_CLOEXEC
#endif
  );
  if (fd < 0) {
    return -1;
  }

  while (len > 0) {
    ssize_t n = read(fd, buf, len);
    if (n > 0) {
      buf += n;
      len -= (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n == 0) {
      errno = EIO;
    }
    close(fd);
    return -1;
  }

  close(fd);
  return 0;
}
#endif

MOONBIT_FFI_EXPORT
int32_t moonbit_postgres_client_secure_random_bytes(void *buf, int32_t num) {
  if (num < 0) {
    errno = EINVAL;
    return -1;
  }

#ifdef _WIN32
  return BCryptGenRandom(
    NULL,
    buf,
    (ULONG)num,
    BCRYPT_USE_SYSTEM_PREFERRED_RNG
  ) == STATUS_SUCCESS ? 0 : -1;
#elif defined(__APPLE__) || defined(__OpenBSD__) || defined(__FreeBSD__) || defined(__NetBSD__)
  arc4random_buf(buf, (size_t)num);
  return 0;
#else
  uint8_t *out = (uint8_t *)buf;
  size_t remaining = (size_t)num;

#if defined(__linux__) && defined(SYS_getrandom)
  while (remaining > 0) {
    size_t chunk = remaining > 262144 ? 262144 : remaining;
    ssize_t n = syscall(SYS_getrandom, out, chunk, 0);
    if (n > 0) {
      out += n;
      remaining -= (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n < 0 && errno == ENOSYS) {
      break;
    }
    if (n == 0) {
      errno = EIO;
    }
    return -1;
  }
  if (remaining == 0) {
    return 0;
  }
#endif

  return read_urandom(out, remaining);
#endif
}
