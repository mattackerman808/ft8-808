// ft8808_shim.h — clean C entry point over kgoba/ft8_lib (MIT) for FT8-808.
//
// This header is intentionally self-contained (no ft8_lib types leak through),
// so the Swift side imports a small, stable surface. The implementation in
// shim/ft8808_shim.c drives the full ft8_lib decode pipeline
// (monitor -> find_candidates -> decode_candidate -> message_decode).

#ifndef FT8808_SHIM_H
#define FT8808_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    FT8808_PROTOCOL_FT8 = 0,
    FT8808_PROTOCOL_FT4 = 1
} ft8808_protocol_t;

typedef struct {
    char  text[35];  // decoded message, null-terminated (FTX_MAX_MESSAGE_LENGTH)
    float freq_hz;   // audio frequency offset within the passband
    float time_sec;  // time offset of the message start within the slot
    int   score;     // Costas sync score (higher = stronger candidate)
    float snr_db;    // APPROXIMATE SNR (score*0.5) — TODO: proper power estimate
} ft8808_decoded_t;

// Decode FT8/FT4 from a block of mono float PCM samples in [-1, +1].
// Fills up to `max_out` entries in `out`. Duplicates are removed.
// Returns the number of messages decoded, or a negative value on error.
int ft8808_decode_samples(const float* samples,
                          int num_samples,
                          int sample_rate,
                          ft8808_protocol_t protocol,
                          ft8808_decoded_t* out,
                          int max_out);

// Convenience: load a 16-bit PCM WAV file and decode it.
// Returns the number of messages decoded, or:
//   -1 = failed to load the WAV file.
int ft8808_decode_wav(const char* path,
                      ft8808_protocol_t protocol,
                      ft8808_decoded_t* out,
                      int max_out);

#ifdef __cplusplus
}
#endif

#endif // FT8808_SHIM_H
