#if defined(_WIN32)

#include <time.h>
#include <string.h>

#include <iomanip>
#include <locale>
#include <sstream>

extern "C" char *strptime(const char *s, const char *f, struct tm *tm) {
    if (!s || !f || !tm) {
        return nullptr;
    }
    std::istringstream in(s);
    in.imbue(std::locale::classic());
    in >> std::get_time(tm, f);
    if (in.fail()) {
        return nullptr;
    }
    const auto pos = in.tellg();
    if (pos < 0) {
        return const_cast<char *>(s + strlen(s));
    }
    return const_cast<char *>(s + static_cast<size_t>(pos));
}

extern "C" char *strptime_l(const char *s, const char *f, struct tm *tm, void *) {
    return strptime(s, f, tm);
}

#endif
