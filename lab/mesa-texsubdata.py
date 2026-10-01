#!/usr/bin/env python3
"""Apply the d3d12 texture_subdata fast path to a Mesa tree (argv[1] = path to d3d12_resource.cpp)."""
import sys

p = sys.argv[1]
s = open(p, encoding="utf-8").read()

func = r'''
static void
d3d12_texture_subdata(struct pipe_context *pctx,
                      struct pipe_resource *pres,
                      unsigned level,
                      unsigned usage,
                      const struct pipe_box *box,
                      const void *data,
                      unsigned stride,
                      uintptr_t layer_stride)
{
   struct d3d12_context *ctx = d3d12_context(pctx);
   struct d3d12_resource *res = d3d12_resource(pres);

   if (pres->target == PIPE_BUFFER || pres->target == PIPE_TEXTURE_3D || box->depth != 1 ||
       can_map_directly(pres) || !res->bo ||
       util_format_is_depth_or_stencil(pres->format) ||
       util_format_is_yuv(res->overall_format) ||
       util_format_get_num_planes(res->overall_format) > 1) {
      u_default_texture_subdata(pctx, pres, level, usage, box, data, stride, layer_stride);
      return;
   }

   const unsigned row_bytes = util_format_get_stride(pres->format, box->width);
   const unsigned rows = util_format_get_nblocksy(pres->format, box->height);
   const unsigned pitch = align(row_bytes, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
   const unsigned size = pitch * rows;

   struct pipe_resource *staging = pipe_buffer_create(pctx->screen, 0, PIPE_USAGE_STREAM, size);
   if (!staging) {
      u_default_texture_subdata(pctx, pres, level, usage, box, data, stride, layer_stride);
      return;
   }

   struct pipe_transfer *xfer = NULL;
   uint8_t *map = (uint8_t *)pipe_buffer_map(pctx, staging,
                                             PIPE_MAP_WRITE | PIPE_MAP_DISCARD_WHOLE_RESOURCE | PIPE_MAP_UNSYNCHRONIZED,
                                             &xfer);
   if (!map) {
      pipe_resource_reference(&staging, NULL);
      u_default_texture_subdata(pctx, pres, level, usage, box, data, stride, layer_stride);
      return;
   }

   util_copy_rect(map, pres->format, pitch, 0, 0, box->width, box->height,
                  (const uint8_t *)data, stride, 0, 0);
   pipe_buffer_unmap(pctx, xfer);

   struct d3d12_transfer trans = {};
   trans.base.b.resource = pres;
   trans.base.b.level = level;
   trans.base.b.usage = (enum pipe_map_flags)(PIPE_MAP_WRITE | PIPE_MAP_DISCARD_RANGE);
   trans.base.b.box = *box;
   trans.base.b.stride = pitch;
   trans.base.b.layer_stride = size;
   transfer_buf_to_image(ctx, res, d3d12_resource(staging), &trans, 0);

   pipe_resource_reference(&staging, NULL);
}

void
d3d12_context_resource_init(struct pipe_context *pctx)
'''

anchor = "\nvoid\nd3d12_context_resource_init(struct pipe_context *pctx)\n"
assert anchor in s, "anchor"
s = s.replace(anchor, func, 1)
s = s.replace("   pctx->texture_subdata = u_default_texture_subdata;", "   pctx->texture_subdata = d3d12_texture_subdata;")
open(p, "w", encoding="utf-8", newline="\n").write(s)
print("patched", p)
