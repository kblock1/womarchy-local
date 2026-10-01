/*
 * WDP — womarchy display protocol, version 1.
 *
 * Carries frames, cursor, outputs and input between the compositor's "wsl" backend
 * (aquamarine, inside the WSL2 VM) and the Windows viewer (omarchy.exe) over a stream
 * socket (AF_VSOCK in Linux <-> AF_HYPERV on Windows; AF_UNIX/TCP for testing).
 *
 * Framing: every message is a wdp_header followed by `size` payload bytes. All integers
 * are little-endian, structs are packed. Unknown message types must be skipped (use size).
 *
 * Pixel transport:
 *   WDP_TRANSPORT_SECTION — output buffers live in files on WSLg's section-backed virtio-fs
 *     share (DAX). The viewer maps them with OpenFileMappingW("WSL\<vmid>\wslg\<name>").
 *     WDP_FRAME carries only damage rectangles. Zero copies between Linux and Windows.
 *   WDP_TRANSPORT_INLINE — pixels for each damage rectangle follow the WDP_FRAME payload
 *     (tightly packed rows, 4 bytes per pixel, rect order). Works everywhere.
 *
 * Pixel format of output buffers: DRM_FORMAT_XRGB8888 (== DXGI_FORMAT_B8G8R8A8_UNORM bytes
 * B,G,R,X in memory). Cursor images: DRM_FORMAT_ARGB8888, premultiplied.
 */
#pragma once
#include <stdint.h>

#define WDP_VERSION     1u
#define WDP_TOKEN_BYTES 32u
#define WDP_NAME_BYTES  96u

enum wdp_msg_type : uint32_t {
    /* viewer -> compositor */
    WDP_HELLO          = 1,  /* wdp_hello: must be first; wrong token => disconnect */
    WDP_MONITORS       = 2,  /* wdp_monitors + wdp_monitor[count]: desired outputs */
    WDP_FRAME_DONE     = 3,  /* wdp_frame_done: viewer consumed (uploaded) a frame; compositor may render the next */
    WDP_KEY            = 10, /* wdp_key */
    WDP_POINTER_ABS    = 11, /* wdp_pointer_abs */
    WDP_POINTER_REL    = 12, /* wdp_pointer_rel */
    WDP_POINTER_BUTTON = 13, /* wdp_pointer_button */
    WDP_POINTER_AXIS   = 14, /* wdp_pointer_axis */
    WDP_POINTER_FRAME  = 15, /* no payload: groups preceding pointer events */
    WDP_FOCUS          = 16, /* wdp_focus: keyboard focus of the viewer changed */
    WDP_QUIT           = 20, /* wdp_quit: user closed the viewer; end the session */

    /* compositor -> viewer */
    WDP_WELCOME        = 100, /* wdp_welcome */
    WDP_OUTPUT         = 101, /* wdp_output: output created or reconfigured */
    WDP_OUTPUT_REMOVED = 102, /* wdp_output_removed */
    WDP_FRAME          = 103, /* wdp_frame + wdp_rect[nrects] (+ pixels if INLINE) */
    WDP_CURSOR         = 104, /* wdp_cursor (+ width*height*4 bytes if has_image) */
    WDP_BYE            = 110, /* wdp_bye: compositor is exiting */

    /* clipboard channel: a second connection, to womarchy-clipd on the compositor's port + 1
     * (WDP_CLIP_PORT_OFFSET), not to the compositor. Same framing. */
    WDP_CLIP_HELLO     = 200, /* viewer -> clipd: wdp_clip_hello */
    WDP_CLIP_TEXT      = 201, /* both ways: UTF-8 text with LF line endings, the whole payload */
};

#define WDP_CLIP_PORT_OFFSET 1u

enum wdp_transport : uint32_t {
    WDP_TRANSPORT_INLINE  = 1,
    WDP_TRANSPORT_SECTION = 2,
};

#pragma pack(push, 1)

struct wdp_header {
    uint32_t type;
    uint32_t size; /* payload bytes following this header */
};

struct wdp_hello {
    uint32_t version;
    uint8_t  token[WDP_TOKEN_BYTES];
    uint32_t transports; /* bitmask of (1 << wdp_transport) the viewer supports */
};

struct wdp_monitor {
    uint32_t id;          /* stable id chosen by the viewer */
    int32_t  x, y;        /* position in the Windows virtual desktop, physical pixels */
    uint32_t width;       /* physical pixels */
    uint32_t height;
    uint32_t refresh_mhz; /* e.g. 60000 */
    uint32_t scale_1000;  /* Windows DPI scale * 1000 (1500 = 150 %) */
    uint32_t primary;
    char     name[64];    /* UTF-8, NUL padded (e.g. "DISPLAY1") */
};

struct wdp_monitors {
    uint32_t count;
    /* struct wdp_monitor monitors[count]; */
};

struct wdp_frame_done {
    uint32_t output_id;
    uint32_t reserved;
    uint64_t seq;
    uint64_t present_ns; /* QPC-derived time the frame hit the screen, 0 if unknown */
};

struct wdp_key {
    uint32_t time_ms;
    uint32_t key;     /* Linux evdev keycode (KEY_*) */
    uint32_t pressed; /* 1 = down, 0 = up */
};

struct wdp_pointer_abs {
    uint32_t time_ms;
    uint32_t output_id;
    double   x, y; /* output-local, physical pixels */
};

struct wdp_pointer_rel {
    uint32_t time_ms;
    double   dx, dy; /* unaccelerated device units */
};

struct wdp_pointer_button {
    uint32_t time_ms;
    uint32_t button;  /* BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112, BTN_SIDE, BTN_EXTRA */
    uint32_t pressed;
};

struct wdp_pointer_axis {
    uint32_t time_ms;
    uint32_t axis;        /* 0 = vertical, 1 = horizontal */
    double   delta;       /* logical scroll distance (positive = down/right) */
    int32_t  discrete120; /* wheel clicks * 120 (WHEEL_DELTA units), 0 for smooth */
};

struct wdp_focus {
    uint32_t focused;
};

struct wdp_quit {
    uint32_t reason; /* 0 = user closed window */
};

struct wdp_welcome {
    uint32_t version;
    uint32_t transport; /* chosen wdp_transport */
    char     vm_id[40]; /* WSL VM GUID (for section names), NUL padded */
};

struct wdp_output {
    uint32_t output_id;   /* == wdp_monitor.id it realises */
    uint32_t width, height;
    uint32_t refresh_mhz;
    char     name[32];    /* compositor output name, e.g. "WSL-1" */
};

struct wdp_output_removed {
    uint32_t output_id;
};

struct wdp_rect {
    int32_t x, y, w, h;
};

struct wdp_frame {
    uint32_t output_id;
    uint32_t width, height; /* buffer size in pixels */
    uint32_t stride;        /* bytes per row of the buffer (SECTION) */
    uint32_t format;        /* DRM fourcc, XRGB8888 */
    uint64_t seq;
    char     buffer[WDP_NAME_BYTES]; /* SECTION: section leaf name; viewer caches mappings by name */
    uint32_t nrects;
    /* struct wdp_rect rects[nrects]; then, if INLINE, pixels for each rect in order (w*4 bytes per row) */
};

struct wdp_cursor {
    uint32_t visible;
    uint32_t has_image; /* 0 = only visibility changed */
    uint32_t width, height;
    int32_t  hot_x, hot_y;
    /* uint8_t argb8888[width*height*4] if has_image */
};

struct wdp_bye {
    int32_t code;
};

struct wdp_clip_hello {
    uint32_t version; /* WDP_VERSION */
    uint8_t  token[WDP_TOKEN_BYTES];
};

#pragma pack(pop)
