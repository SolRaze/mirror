#ifndef SC_MIRROR_FRAME_H
#define SC_MIRROR_FRAME_H

#include "common.h"

#include <stdint.h>

#include "coords.h"

// iPhone Mirroring's window frame and menus for the SDL window (macOS only).
// Both run on the main thread.

// serial is the device the Device menu's adb items act on, NULL for adb's
// default; turn_screen_off is the device panel's state at start.
void
sc_mirror_frame_init(uint16_t sdl_shortcut_mods, const char *serial,
                     bool turn_screen_off);

void
sc_mirror_frame_set_content_size(struct sc_size size);

#endif
