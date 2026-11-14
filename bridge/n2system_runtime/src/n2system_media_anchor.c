/* Keep the managed binding's public entry points reachable without forcing
 * every object in FFmpeg's archives into the runtime image. */
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#if LIBAVCODEC_VERSION_MAJOR != 62 || LIBAVFORMAT_VERSION_MAJOR != 62 || \
    LIBAVUTIL_VERSION_MAJOR != 60 || LIBSWRESAMPLE_VERSION_MAJOR != 6 || \
    LIBSWSCALE_VERSION_MAJOR != 9
#error "N2System's managed media ABI requires FFmpeg 8"
#endif

typedef void (*n2system_media_function)(void);
#define N2SYSTEM_MEDIA_SYMBOL(name) (n2system_media_function)name,
static const n2system_media_function n2system_media_symbols[] = {
#include "n2system_media_symbols.inc"
};
#undef N2SYSTEM_MEDIA_SYMBOL

#if defined(_WIN32)
__declspec(dllexport)
#else
__attribute__((visibility("default")))
#endif
const n2system_media_function *aether_n2system_media_anchor(void)
{
    return n2system_media_symbols;
}
