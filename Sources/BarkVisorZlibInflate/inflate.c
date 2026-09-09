#include "bv_inflate.h"

#include <string.h>

#if defined(_WIN32)

int bv_inflate_raw(
    const unsigned char *src,
    unsigned src_len,
    unsigned char *dst,
    unsigned dst_len,
    unsigned *written)
{
    (void)src;
    (void)src_len;
    (void)dst;
    (void)dst_len;
    if (written) {
        *written = 0;
    }
    return -1;
}

#else

#include <zlib.h>

int bv_inflate_raw(
    const unsigned char *src,
    unsigned src_len,
    unsigned char *dst,
    unsigned dst_len,
    unsigned *written)
{
    z_stream stream;
    int status;

    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)src;
    stream.avail_in = src_len;
    stream.next_out = dst;
    stream.avail_out = dst_len;
    status = inflateInit2(&stream, -MAX_WBITS);
    if (status != Z_OK) {
        return -1;
    }
    status = inflate(&stream, Z_FINISH);
    if (written) {
        *written = (unsigned)stream.total_out;
    }
    inflateEnd(&stream);
    return status == Z_STREAM_END ? 0 : -1;
}

#endif
