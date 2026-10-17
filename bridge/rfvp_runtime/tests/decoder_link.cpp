#include <cstddef>
#include <cstdint>

// Stand in for the legacy C exports embedded by Siglus. Linking must preserve
// these alongside RFVP's decoder, even when all four RFVP exports are used.
extern "C" {
void* wmv2_decoder_create(uint32_t, uint32_t, const uint8_t*, size_t) { return nullptr; }
void wmv2_decoder_destroy(void*) {}
int wmv2_decoder_decode(void*, const uint8_t*, size_t, int) { return 0; }
int wmv2_decoder_get_frame(void*, void*) { return 0; }

void* aether_rfvp_wmv2_decoder_create(uint32_t, uint32_t, const uint8_t*, size_t);
void aether_rfvp_wmv2_decoder_destroy(void*);
int aether_rfvp_wmv2_decoder_decode(void*, const uint8_t*, size_t, int);
int aether_rfvp_wmv2_decoder_get_frame(void*, void*);
}

int main() {
    auto* decoder = aether_rfvp_wmv2_decoder_create(16, 16, nullptr, 0);
    if (!decoder) return 1;
    const bool valid = aether_rfvp_wmv2_decoder_decode(decoder, nullptr, 0, 0) == -1
        && aether_rfvp_wmv2_decoder_get_frame(decoder, nullptr) == -1;
    aether_rfvp_wmv2_decoder_destroy(decoder);
    return valid ? 0 : 1;
}
