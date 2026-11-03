/* Compiler/platform glue for lwIP on Darwin (docs/design/direct-link.md §2.4).
 * Included from lwip/arch.h through the include path. */
#ifndef PD_LWIP_ARCH_CC_H
#define PD_LWIP_ARCH_CC_H

#include <machine/endian.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

/* The helper's own log sink (pdlwip.c); states, counts and codes only. */
void pdl_diag(const char *fmt, ...);

#ifndef BYTE_ORDER
#define BYTE_ORDER LITTLE_ENDIAN
#endif

#define LWIP_PLATFORM_BYTESWAP 0
#define LWIP_NO_UNISTD_H 0
#define LWIP_NO_STDDEF_H 0
#define LWIP_NO_STDINT_H 0
#define LWIP_NO_INTTYPES_H 0
#define LWIP_NO_CTYPE_H 0

typedef uint8_t u8_t;
typedef int8_t s8_t;
typedef uint16_t u16_t;
typedef int16_t s16_t;
typedef uint32_t u32_t;
typedef int32_t s32_t;
typedef uintptr_t mem_ptr_t;

#define U16_F "hu"
#define S16_F "hd"
#define X16_F "hx"
#define U32_F "u"
#define S32_F "d"
#define X32_F "x"
#define SZT_F "zu"

#endif /* PD_LWIP_ARCH_CC_H */
