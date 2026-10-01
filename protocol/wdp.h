/*
 * WDP - womarchy display protocol, version 2.
 *
 * Carries frames, cursor, outputs and input between a compositor's "wsl" backend (aquamarine, inside
 * the WSL2 VM) and the Windows viewer (omarchy.exe) over a stream socket (AF_VSOCK in Linux <->
 * AF_HYPERV on Windows; AF_UNIX for testing). A second connection carries the clipboard (see below).
 *
 * Framing: every message is a wdp_header followed by `size` payload bytes. Integers are little-endian,
 * structs are packed. Receivers skip unknown message types (using `size`) and ignore trailing bytes of
 * known ones, so later versions can append fields.
 *
 * Authentication (mutual): the launcher creates a random 32-byte token per session and gives it to
 * both ends out of band (environment / WSLENV). The viewer proves it knows the token by sending its
 * first half in WDP_HELLO; the compositor proves it by answering WDP_WELCOME with the second half.
 * The viewer sends no input and no clipboard before it has checked that proof, so a process that
 * grabbed the port first learns only a useless half of a one-time token. Anything else before a valid
 * HELLO is a protocol error and closes the connection.
 *
 * Pixel transport:
 *   WDP_TRANSPORT_SECTION: output buffers live in files on WSLg's section-backed virtio-fs share (DAX).
 *     The viewer maps them with OpenFileMappingW("WSL\<vm id>\wslg\<name>"); WDP_FRAME carries only
 *     the damage. Zero copies between Linux and Windows.
 *   WDP_TRANSPORT_INLINE: pixels for each damage rectangle follow the WDP_FRAME payload (tightly
 *     packed rows, 4 bytes per pixel, rectangle order). Works everywhere.
 *
 * Pacing: after WDP_FRAME the compositor renders the next frame for that output only after the viewer's
 * WDP_FRAME_DONE (it has consumed the buffer and presented). A frame with no rectangles means "nothing
 * changed" and is acknowledged like any other. Hidden outputs (WDP_OUTPUT_VISIBLE) are throttled.
 *
 * Pixel format of output buffers: DRM_FORMAT_XRGB8888 (bytes B,G,R,X in memory, which is
 * DXGI_FORMAT_B8G8R8A8_UNORM). Cursor images: DRM_FORMAT_ARGB8888, premultiplied alpha.
 *
 * Clipboard channel: womarchy-clipd listens on the compositor's port + WDP_CLIP_PORT_OFFSET with its own
 * 32-byte token and the same handshake (WDP_CLIP_HELLO / WDP_CLIP_WELCOME), then both sides send
 * WDP_CLIP_TEXT, or WDP_CLIP_IMAGE when the clipboard holds an image and no text, whenever their
 * clipboard changes. (WDP_CLIP_IMAGE was added without a version bump: older peers skip it.)
 */
#ifndef WDP_H
#define WDP_H
#include <stdint.h>

#define WDP_VERSION          2u
#define WDP_TOKEN_BYTES      32u /* per-session secret; each side proves one half */
#define WDP_PROOF_BYTES      16u
#define WDP_NAME_BYTES       96u
#define WDP_CLIP_PORT_OFFSET 1u

/* limits both sides enforce */
#define WDP_MAX_MONITORS  16u
#define WDP_MAX_DIMENSION 16384u     /* output width/height in pixels */
#define WDP_MAX_RECTS     64u        /* per frame; more damage is sent as its bounding box */
#define WDP_MAX_CURSOR    256u       /* cursor image width/height */
#define WDP_MAX_MESSAGE   (64u << 20) /* payload bytes; a full inline 4K frame is 33 MB */
#define WDP_MAX_CLIP_TEXT  (16u << 20) /* clipboard text, bytes */
#define WDP_MAX_CLIP_IMAGE (32u << 20) /* clipboard image (PNG), bytes */

/* message types: viewer -> compositor */
#define WDP_HELLO          1u  /* wdp_hello: must be first */
#define WDP_MONITORS       2u  /* wdp_monitors + wdp_monitor[count]: the outputs the viewer shows */
#define WDP_FRAME_DONE     3u  /* wdp_frame_done: frame consumed and presented; render the next */
#define WDP_OUTPUT_VISIBLE 4u  /* wdp_output_visible: an output's window was hidden/minimised or shown */
#define WDP_REFRESH        5u  /* wdp_refresh: send the next frame of an output with full damage */
#define WDP_KEY            10u /* wdp_key */
#define WDP_POINTER_ABS    11u /* wdp_pointer_abs */
#define WDP_POINTER_REL    12u /* wdp_pointer_rel */
#define WDP_POINTER_BUTTON 13u /* wdp_pointer_button */
#define WDP_POINTER_AXIS   14u /* wdp_pointer_axis */
#define WDP_POINTER_FRAME  15u /* no payload: groups the preceding pointer events */
#define WDP_FOCUS          16u /* wdp_focus: the viewer gained/lost keyboard focus */
#define WDP_QUIT           20u /* wdp_quit: the user closed the viewer; end the session */

/* message types: compositor -> viewer */
#define WDP_WELCOME        100u /* wdp_welcome: answer to a valid HELLO, proves the compositor */
#define WDP_OUTPUT         101u /* wdp_output: output created or reconfigured */
#define WDP_OUTPUT_REMOVED 102u /* wdp_output_removed */
#define WDP_FRAME          103u /* wdp_frame + wdp_rect[nrects] (+ pixels if INLINE) */
#define WDP_CURSOR         104u /* wdp_cursor (+ width*height*4 bytes if has_image) */
#define WDP_BYE            110u /* wdp_bye: the compositor is exiting */

/* message types: clipboard channel */
#define WDP_CLIP_HELLO     200u /* viewer -> clipd: wdp_clip_hello */
#define WDP_CLIP_TEXT      201u /* both ways: UTF-8 text with LF line endings; the whole payload */
#define WDP_CLIP_WELCOME   202u /* clipd -> viewer: wdp_clip_welcome, proves clipd */
#define WDP_CLIP_IMAGE     203u /* both ways: a PNG image; the whole payload (at most WDP_MAX_CLIP_IMAGE) */

/* transports (bit numbers in wdp_hello.transports) */
#define WDP_TRANSPORT_INLINE  1u
#define WDP_TRANSPORT_SECTION 2u

#pragma pack(push, 1)

struct wdp_header {
    uint32_t type;
    uint32_t size; /* payload bytes following this header */
};

struct wdp_hello {
    uint32_t version;                /* WDP_VERSION */
    uint8_t  proof[WDP_PROOF_BYTES]; /* token[0..16) */
    uint32_t transports;             /* bitmask of (1 << WDP_TRANSPORT_*) the viewer supports */
};

struct wdp_monitor {
    uint32_t id;          /* stable for the monitor while it stays connected; output name WSL-<id> */
    int32_t  x, y;        /* position in the Windows virtual desktop, physical pixels */
    uint32_t width;       /* physical pixels, 1..WDP_MAX_DIMENSION */
    uint32_t height;
    uint32_t refresh_mhz; /* e.g. 60000 */
    uint32_t scale_1000;  /* Windows DPI scale * 1000 (1500 = 150 %) */
    uint32_t primary;
    char     name[64];    /* UTF-8, NUL padded (e.g. "DISPLAY1") */
};

struct wdp_monitors {
    uint32_t count; /* <= WDP_MAX_MONITORS */
    /* struct wdp_monitor monitors[count]; */
};

struct wdp_frame_done {
    uint32_t output_id;
    uint32_t reserved;
    uint64_t seq;
    uint64_t present_ns; /* when the frame reached the screen (QPC-based), 0 if unknown */
};

struct wdp_output_visible {
    uint32_t output_id;
    uint32_t visible; /* 0 = minimised/hidden: the compositor throttles this output */
};

struct wdp_refresh {
    uint32_t output_id;
};

struct wdp_key {
    uint32_t time_ms;
    uint32_t key;     /* Linux evdev keycode (KEY_*) */
    uint32_t pressed; /* 1 = down, 0 = up */
};

struct wdp_pointer_abs {
    uint32_t time_ms;
    uint32_t output_id;
    double   x, y; /* output-local physical pixels */
};

struct wdp_pointer_rel {
    uint32_t time_ms;
    double   dx, dy; /* unaccelerated device units */
};

struct wdp_pointer_button {
    uint32_t time_ms;
    uint32_t button; /* BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112, BTN_SIDE, BTN_EXTRA */
    uint32_t pressed;
};

struct wdp_pointer_axis {
    uint32_t time_ms;
    uint32_t axis;        /* 0 = vertical, 1 = horizontal */
    double   delta;       /* logical scroll distance (positive = down/right) */
    int32_t  discrete120; /* wheel clicks * 120 (WHEEL_DELTA units), 0 for smooth scrolling */
};

struct wdp_focus {
    uint32_t focused;
};

struct wdp_quit {
    uint32_t reason; /* 0 = the user closed the window */
};

struct wdp_welcome {
    uint32_t version;                /* WDP_VERSION */
    uint32_t transport;              /* the chosen WDP_TRANSPORT_* */
    char     vm_id[40];              /* WSL VM GUID (for section names), NUL padded */
    uint8_t  proof[WDP_PROOF_BYTES]; /* token[16..32) */
};

struct wdp_output {
    uint32_t output_id; /* the wdp_monitor.id it realises */
    uint32_t width, height;
    uint32_t refresh_mhz;
    char     name[32];  /* compositor output name, e.g. "WSL-1" */
};

struct wdp_output_removed {
    uint32_t output_id;
};

struct wdp_rect {
    int32_t x, y, w, h; /* inside the buffer; w, h > 0 */
};

struct wdp_frame {
    uint32_t output_id;
    uint32_t width, height; /* buffer size in pixels */
    uint32_t stride;        /* bytes per row of the buffer (SECTION), >= width * 4 */
    uint32_t format;        /* DRM fourcc, XRGB8888 */
    uint64_t seq;
    char     buffer[WDP_NAME_BYTES]; /* SECTION: leaf name of the buffer file ([A-Za-z0-9._-]) */
    uint32_t nrects;                 /* <= WDP_MAX_RECTS; 0 = nothing changed */
    /* struct wdp_rect rects[nrects]; then, if INLINE, the pixels of each rect in order (w * 4 bytes per row) */
};

struct wdp_cursor {
    uint32_t visible;
    uint32_t has_image; /* 0 = only the visibility changed */
    uint32_t width, height;
    int32_t  hot_x, hot_y;
    /* uint8_t argb8888[width * height * 4] if has_image */
};

struct wdp_bye {
    int32_t code;
};

struct wdp_clip_hello {
    uint32_t version;                /* WDP_VERSION */
    uint8_t  proof[WDP_PROOF_BYTES]; /* clipboard token[0..16) */
};

struct wdp_clip_welcome {
    uint32_t version;
    uint8_t  proof[WDP_PROOF_BYTES]; /* clipboard token[16..32) */
};

#pragma pack(pop)
#endif
