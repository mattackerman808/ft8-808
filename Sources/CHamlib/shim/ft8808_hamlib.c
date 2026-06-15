// ft8808_hamlib.c — implementation of the FT8-808 Hamlib shim.
//
// All Hamlib API use (function-like macros, 64-bit mode flags, opaque RIG*)
// lives here in C, where it behaves as Hamlib intends.

#include "ft8808_hamlib.h"

#include <hamlib/rig.h>
#include <hamlib/riglist.h>

#include <stdlib.h>
#include <string.h>

struct ft8808_rig {
    RIG* rig;
};

static rmode_t mode_to_hamlib(ft8808_mode m) {
    switch (m) {
        case FT8808_MODE_USB:  return RIG_MODE_USB;
        case FT8808_MODE_LSB:  return RIG_MODE_LSB;
        case FT8808_MODE_CW:   return RIG_MODE_CW;
        case FT8808_MODE_DATA: return RIG_MODE_PKTUSB;
        default:               return RIG_MODE_USB;
    }
}

static ft8808_mode mode_from_hamlib(rmode_t m) {
    switch (m) {
        case RIG_MODE_USB:    return FT8808_MODE_USB;
        case RIG_MODE_LSB:    return FT8808_MODE_LSB;
        case RIG_MODE_CW:     return FT8808_MODE_CW;
        case RIG_MODE_PKTUSB: return FT8808_MODE_DATA;
        default:              return FT8808_MODE_UNKNOWN;
    }
}

ft8808_rig* ft8808_rig_open(int model, const char* device, int serial_speed, int* err_out) {
    // Keep Hamlib quiet unless something goes wrong.
    rig_set_debug(RIG_DEBUG_ERR);

    RIG* rig = rig_init((rig_model_t)model);
    if (rig == NULL) {
        if (err_out) *err_out = -RIG_EINVAL;
        return NULL;
    }

    if (device != NULL && device[0] != '\0') {
        hamlib_token_t t = rig_token_lookup(rig, "rig_pathname");
        if (t != RIG_CONF_END) rig_set_conf(rig, t, device);
    }
    if (serial_speed > 0) {
        char speed[16];
        snprintf(speed, sizeof(speed), "%d", serial_speed);
        hamlib_token_t t = rig_token_lookup(rig, "serial_speed");
        if (t != RIG_CONF_END) rig_set_conf(rig, t, speed);
    }

    int rc = rig_open(rig);
    if (rc != RIG_OK) {
        if (err_out) *err_out = rc;
        rig_cleanup(rig);
        return NULL;
    }

    ft8808_rig* wrapper = (ft8808_rig*)calloc(1, sizeof(ft8808_rig));
    if (wrapper == NULL) {
        if (err_out) *err_out = -RIG_ENOMEM;
        rig_close(rig);
        rig_cleanup(rig);
        return NULL;
    }
    wrapper->rig = rig;
    if (err_out) *err_out = RIG_OK;
    return wrapper;
}

void ft8808_rig_close(ft8808_rig* r) {
    if (r == NULL) return;
    if (r->rig != NULL) {
        rig_close(r->rig);
        rig_cleanup(r->rig);
    }
    free(r);
}

int ft8808_rig_get_state(ft8808_rig* r, ft8808_rig_state* out) {
    if (r == NULL || r->rig == NULL || out == NULL) return -RIG_EINVAL;

    freq_t freq = 0;
    int rc = rig_get_freq(r->rig, RIG_VFO_CURR, &freq);
    if (rc != RIG_OK) return rc;

    rmode_t mode = RIG_MODE_NONE;
    pbwidth_t width = 0;
    rc = rig_get_mode(r->rig, RIG_VFO_CURR, &mode, &width);
    if (rc != RIG_OK) return rc;

    ptt_t ptt = RIG_PTT_OFF;
    // PTT read is optional; ignore failures (some backends don't report it).
    rig_get_ptt(r->rig, RIG_VFO_CURR, &ptt);

    out->freq_hz = (double)freq;
    out->mode = mode_from_hamlib(mode);
    out->ptt = (ptt != RIG_PTT_OFF) ? 1 : 0;
    return RIG_OK;
}

int ft8808_rig_set_freq(ft8808_rig* r, double hz) {
    if (r == NULL || r->rig == NULL) return -RIG_EINVAL;
    return rig_set_freq(r->rig, RIG_VFO_CURR, (freq_t)hz);
}

int ft8808_rig_set_mode(ft8808_rig* r, ft8808_mode mode) {
    if (r == NULL || r->rig == NULL) return -RIG_EINVAL;
    return rig_set_mode(r->rig, RIG_VFO_CURR, mode_to_hamlib(mode), RIG_PASSBAND_NORMAL);
}

int ft8808_rig_set_ptt(ft8808_rig* r, int on) {
    if (r == NULL || r->rig == NULL) return -RIG_EINVAL;
    return rig_set_ptt(r->rig, RIG_VFO_CURR, on ? RIG_PTT_ON : RIG_PTT_OFF);
}

int ft8808_rig_get_meters(ft8808_rig* r, ft8808_meters* out) {
    if (r == NULL || r->rig == NULL || out == NULL) return -RIG_EINVAL;
    memset(out, 0, sizeof(*out));

    value_t v;
    if (rig_get_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_RFPOWER_METER_WATTS, &v) == RIG_OK) {
        out->has_power_watts = 1; out->power_watts = v.f;
    }
    if (rig_get_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_RFPOWER_METER, &v) == RIG_OK) {
        out->has_power_pct = 1; out->power_pct = v.f;
    }
    if (rig_get_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_ALC, &v) == RIG_OK) {
        out->has_alc = 1; out->alc = v.f;
    }
    if (rig_get_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_SWR, &v) == RIG_OK) {
        out->has_swr = 1; out->swr = v.f;
    }
    if (rig_get_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_RFPOWER, &v) == RIG_OK) {
        out->has_rfpower_set = 1; out->rfpower_set = v.f;
    }
    return RIG_OK;
}

int ft8808_rig_get_rf_power(ft8808_rig* r, float* out) {
    if (r == NULL || r->rig == NULL || out == NULL) return -RIG_EINVAL;
    value_t v;
    int rc = rig_get_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_RFPOWER, &v);
    if (rc == RIG_OK) *out = v.f;
    return rc;
}

int ft8808_rig_set_rf_power(ft8808_rig* r, float frac) {
    if (r == NULL || r->rig == NULL) return -RIG_EINVAL;
    value_t v;
    v.f = frac;
    return rig_set_level(r->rig, RIG_VFO_CURR, RIG_LEVEL_RFPOWER, v);
}

const char* ft8808_rig_strerror(int errcode) {
    return rigerror(errcode);
}
