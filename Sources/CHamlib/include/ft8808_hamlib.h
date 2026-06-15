// ft8808_hamlib.h — clean C entry point over Hamlib (LGPL) for FT8-808.
//
// As with CFT8, this header is self-contained: no Hamlib types leak through, so
// the Swift wrapper imports a tiny, stable surface and all of Hamlib's macro /
// 64-bit-flag / opaque-pointer machinery stays on the C side.

#ifndef FT8808_HAMLIB_H
#define FT8808_HAMLIB_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ft8808_rig ft8808_rig; // opaque handle wrapping a Hamlib RIG*

typedef enum {
    FT8808_MODE_USB = 0,
    FT8808_MODE_LSB,
    FT8808_MODE_CW,
    FT8808_MODE_DATA, // PKTUSB — the usual FT8 mode
    FT8808_MODE_UNKNOWN
} ft8808_mode;

typedef struct {
    double      freq_hz;
    ft8808_mode mode;
    int         ptt; // 0 = receive, 1 = transmit
} ft8808_rig_state;

// Well-known Hamlib model numbers, surfaced so callers needn't include riglist.h.
#define FT8808_RIG_MODEL_DUMMY     1 // software-simulated rig (no hardware)
#define FT8808_RIG_MODEL_NETRIGCTL 2 // talk to a remote rigctld over TCP

// Open a rig. `model` is a Hamlib rig model number (e.g. FT8808_RIG_MODEL_DUMMY).
// `device` is a serial path (e.g. "/dev/cu.usbserial-1410"), a "host:port" for
// NETRIGCTL, or NULL. `serial_speed` is baud (0 = backend default).
// On failure returns NULL and, if `err_out` is non-NULL, sets it to the Hamlib
// error code.
ft8808_rig* ft8808_rig_open(int model, const char* device, int serial_speed, int* err_out);

// Release the rig (closes the port and frees Hamlib state).
void ft8808_rig_close(ft8808_rig* r);

// Read current VFO frequency, mode, and PTT. Returns 0 on success, else a
// negative Hamlib error code.
int ft8808_rig_get_state(ft8808_rig* r, ft8808_rig_state* out);

int ft8808_rig_set_freq(ft8808_rig* r, double hz);   // 0 ok, else Hamlib error
int ft8808_rig_set_mode(ft8808_rig* r, ft8808_mode mode);
int ft8808_rig_set_ptt(ft8808_rig* r, int on);

// Transmit meters read over CAT. Each `has_*` flag indicates whether the rig
// supplied that reading. `alc` is the rig's ALC level (≈0 means no ALC action);
// `power_watts` is forward power; `power_pct` is 0..1 of max; `swr` is SWR.
typedef struct {
    int   has_power_watts;  float power_watts;
    int   has_power_pct;    float power_pct;
    int   has_alc;          float alc;
    int   has_swr;          float swr;
    int   has_rfpower_set;  float rfpower_set; // RF PWR ceiling setting, 0..1
} ft8808_meters;

// Read TX meters. Returns 0 on success (individual has_* flags say what was
// available), or a negative Hamlib error code.
int ft8808_rig_get_meters(ft8808_rig* r, ft8808_meters* out);

// Get/set the rig's RF power ceiling (0..1 of max). Returns 0 on success.
int ft8808_rig_get_rf_power(ft8808_rig* r, float* out);
int ft8808_rig_set_rf_power(ft8808_rig* r, float frac);

// Human-readable text for a Hamlib error code.
const char* ft8808_rig_strerror(int errcode);

#ifdef __cplusplus
}
#endif

#endif // FT8808_HAMLIB_H
