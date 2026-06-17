// miniaudio implementation translation unit + a tiny device-plumbing glue.
//
// The header is compiled once here. We only use the low-level playback *device*
// API, so the decoder/encoder/engine/resource-manager layers are disabled to
// cut compile time and binary size (mirrors ztrax's vendor/miniaudio.c).
//
// The data callback does nothing but hand control to the V function
// `vtrax_fill` — all real-time work (decode, peak, FFT push, atomics) lives in
// V. This file is just the device boilerplate that can't live in V without
// redeclaring miniaudio's large config structs.
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "miniaudio.h"

#include <stdlib.h>

// Implemented in V (see audio.v), exported under this symbol.
extern void vtrax_fill(void *userdata, float *output, unsigned int frames,
                       unsigned int sample_rate);

static void vtrax_ma_callback(ma_device *device, void *output,
                              const void *input, ma_uint32 frame_count) {
  (void)input;
  vtrax_fill(device->pUserData, (float *)output, frame_count,
             device->sampleRate);
}

// Create + start a playback device. Returns the ma_device* (heap-allocated so
// its address is stable for miniaudio's backend threads) or NULL on failure;
// writes the negotiated sample rate to *out_rate.
void *vtrax_device_create(void *userdata, unsigned int *out_rate) {
  ma_device *device = (ma_device *)malloc(sizeof(ma_device));
  if (device == NULL) {
    return NULL;
  }
  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_f32;
  config.playback.channels = 2;
  config.sampleRate = 0; // 0 = device's native rate
  config.dataCallback = vtrax_ma_callback;
  config.pUserData = userdata;

  if (ma_device_init(NULL, &config, device) != MA_SUCCESS) {
    free(device);
    return NULL;
  }
  if (out_rate != NULL) {
    *out_rate = device->sampleRate;
  }
  if (ma_device_start(device) != MA_SUCCESS) {
    ma_device_uninit(device);
    free(device);
    return NULL;
  }
  return device;
}

// Stop the device and join its backend thread, then free it. After this returns
// no callback can run.
void vtrax_device_destroy(void *dev) {
  if (dev == NULL) {
    return;
  }
  ma_device_uninit((ma_device *)dev);
  free(dev);
}
