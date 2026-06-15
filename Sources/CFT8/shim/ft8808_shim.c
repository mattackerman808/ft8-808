// ft8808_shim.c — implementation of the FT8-808 C entry point.
//
// Wraps kgoba/ft8_lib (MIT). The decode pipeline and the callsign hashtable
// below are adapted from ft8_lib's demo/decode_ft8.c (MIT, (c) Kārlis Goba),
// reduced to a reentrant, device-free form suitable for offline sample blocks.

#include "ft8808_shim.h"

#include <ft8/decode.h>
#include <ft8/message.h>
#include <common/monitor.h>
#include <common/wave.h>

#include <string.h>
#include <stdint.h>
#include <stdbool.h>

// ---- Decode tuning (mirrors ft8_lib demo defaults) ------------------------
#define FT8808_MIN_SCORE      10
#define FT8808_MAX_CANDIDATES 140
#define FT8808_LDPC_ITERS     25
#define FT8808_MAX_DECODED    50
#define FT8808_FREQ_OSR       2
#define FT8808_TIME_OSR       2

// ---- Callsign hashtable (adapted from ft8_lib demo) -----------------------
// FT8 can transmit hashed (non-standard) callsigns; decoding those requires a
// table of previously-seen calls. For a single offline slot this is mostly a
// no-op, but we keep it so hashed-callsign messages render correctly once we
// feed it a live stream of slots.
#define CALLSIGN_HASHTABLE_SIZE 256

static struct {
    char     callsign[12];
    uint32_t hash; // 8 MSB = age, 22 LSB = hash
} g_callsign_hashtable[CALLSIGN_HASHTABLE_SIZE];

static int g_callsign_hashtable_size;

static void hashtable_init(void) {
    g_callsign_hashtable_size = 0;
    memset(g_callsign_hashtable, 0, sizeof(g_callsign_hashtable));
}

static void hashtable_add(const char* callsign, uint32_t hash) {
    uint16_t hash10 = (hash >> 12) & 0x3FFu;
    int idx = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (g_callsign_hashtable[idx].callsign[0] != '\0') {
        if (((g_callsign_hashtable[idx].hash & 0x3FFFFFu) == hash) &&
            (0 == strcmp(g_callsign_hashtable[idx].callsign, callsign))) {
            g_callsign_hashtable[idx].hash &= 0x3FFFFFu; // reset age
            return;
        }
        idx = (idx + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    g_callsign_hashtable_size++;
    strncpy(g_callsign_hashtable[idx].callsign, callsign, 11);
    g_callsign_hashtable[idx].callsign[11] = '\0';
    g_callsign_hashtable[idx].hash = hash;
}

static bool hashtable_lookup(ftx_callsign_hash_type_t hash_type, uint32_t hash, char* callsign) {
    uint8_t hash_shift = (hash_type == FTX_CALLSIGN_HASH_10_BITS) ? 12
                       : (hash_type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0);
    uint16_t hash10 = (hash >> (12 - hash_shift)) & 0x3FFu;
    int idx = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (g_callsign_hashtable[idx].callsign[0] != '\0') {
        if (((g_callsign_hashtable[idx].hash & 0x3FFFFFu) >> hash_shift) == hash) {
            strcpy(callsign, g_callsign_hashtable[idx].callsign);
            return true;
        }
        idx = (idx + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    callsign[0] = '\0';
    return false;
}

static ftx_callsign_hash_interface_t g_hash_if = {
    .lookup_hash = hashtable_lookup,
    .save_hash   = hashtable_add,
};

// ---------------------------------------------------------------------------
int ft8808_decode_samples(const float* samples,
                          int num_samples,
                          int sample_rate,
                          ft8808_protocol_t protocol,
                          ft8808_decoded_t* out,
                          int max_out) {
    if (samples == NULL || out == NULL || max_out <= 0 || num_samples <= 0) {
        return -2;
    }

    hashtable_init();

    monitor_config_t mon_cfg = {
        .f_min       = 200,
        .f_max       = 3000,
        .sample_rate = sample_rate,
        .time_osr    = FT8808_TIME_OSR,
        .freq_osr    = FT8808_FREQ_OSR,
        .protocol    = (protocol == FT8808_PROTOCOL_FT4) ? FTX_PROTOCOL_FT4 : FTX_PROTOCOL_FT8,
    };

    monitor_t mon;
    monitor_init(&mon, &mon_cfg);

    // Accumulate the whole sample block into the waterfall, block by block.
    for (int pos = 0; pos + mon.block_size <= num_samples; pos += mon.block_size) {
        monitor_process(&mon, samples + pos);
    }

    const ftx_waterfall_t* wf = &mon.wf;

    ftx_candidate_t candidates[FT8808_MAX_CANDIDATES];
    int num_candidates = ftx_find_candidates(wf, FT8808_MAX_CANDIDATES, candidates, FT8808_MIN_SCORE);

    // De-duplication table of decoded messages.
    ftx_message_t  decoded[FT8808_MAX_DECODED];
    ftx_message_t* decoded_hashtable[FT8808_MAX_DECODED];
    for (int i = 0; i < FT8808_MAX_DECODED; ++i) decoded_hashtable[i] = NULL;

    int num_out = 0;

    for (int idx = 0; idx < num_candidates && num_out < max_out; ++idx) {
        const ftx_candidate_t* cand = &candidates[idx];

        float freq_hz  = (mon.min_bin + cand->freq_offset + (float)cand->freq_sub / wf->freq_osr) / mon.symbol_period;
        float time_sec = (cand->time_offset + (float)cand->time_sub / wf->time_osr) * mon.symbol_period;

        ftx_message_t message;
        ftx_decode_status_t status;
        if (!ftx_decode_candidate(wf, cand, FT8808_LDPC_ITERS, &message, &status)) {
            continue; // LDPC failure or CRC mismatch
        }

        // Linear-probe de-dup, identical to the upstream demo.
        int idx_hash = message.hash % FT8808_MAX_DECODED;
        bool found_empty = false, found_dup = false;
        do {
            if (decoded_hashtable[idx_hash] == NULL) {
                found_empty = true;
            } else if ((decoded_hashtable[idx_hash]->hash == message.hash) &&
                       (0 == memcmp(decoded_hashtable[idx_hash]->payload, message.payload, sizeof(message.payload)))) {
                found_dup = true;
            } else {
                idx_hash = (idx_hash + 1) % FT8808_MAX_DECODED;
            }
        } while (!found_empty && !found_dup);

        if (!found_empty) continue; // duplicate

        memcpy(&decoded[idx_hash], &message, sizeof(message));
        decoded_hashtable[idx_hash] = &decoded[idx_hash];

        char text[FTX_MAX_MESSAGE_LENGTH];
        ftx_message_offsets_t offsets;
        ftx_message_rc_t rc = ftx_message_decode(&message, &g_hash_if, text, &offsets);
        if (rc != FTX_MESSAGE_RC_OK) continue;

        ft8808_decoded_t* o = &out[num_out++];
        strncpy(o->text, text, sizeof(o->text) - 1);
        o->text[sizeof(o->text) - 1] = '\0';
        o->freq_hz  = freq_hz;
        o->time_sec = time_sec;
        o->score    = cand->score;
        o->snr_db   = cand->score * 0.5f; // TODO: real SNR estimate
    }

    monitor_free(&mon);
    return num_out;
}

int ft8808_decode_wav(const char* path,
                      ft8808_protocol_t protocol,
                      ft8808_decoded_t* out,
                      int max_out) {
    // FT8 is ~15 s; allow a generous ceiling. 12 kHz * 30 s.
    static float signal[12000 * 30];
    int num_samples = sizeof(signal) / sizeof(signal[0]);
    int sample_rate = 0;

    if (load_wav(signal, &num_samples, &sample_rate, path) < 0) {
        return -1;
    }
    return ft8808_decode_samples(signal, num_samples, sample_rate, protocol, out, max_out);
}
