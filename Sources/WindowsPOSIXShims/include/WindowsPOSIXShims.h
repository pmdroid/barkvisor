#ifndef WINDOWS_POSIX_SHIMS_H
#define WINDOWS_POSIX_SHIMS_H

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#include <time.h>
#ifndef locale_t
typedef void *locale_t;
#endif
char *strptime(const char *s, const char *f, struct tm *tm);
char *strptime_l(const char *s, const char *f, struct tm *tm, locale_t loc);
#endif

#ifdef __cplusplus
}
#endif

#endif
