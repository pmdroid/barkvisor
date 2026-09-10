#ifndef BV_INFLATE_H
#define BV_INFLATE_H

int bv_inflate_raw(
    const unsigned char *src,
    unsigned src_len,
    unsigned char *dst,
    unsigned dst_len,
    unsigned *written);

#endif
