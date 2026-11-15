// What the frame costs at the Metal level, for the performance log.
//
// MoltenVK may turn one Vulkan render pass into several Metal ones (a pass is
// restarted after anything Metal can only do outside one), and on a tile-based
// GPU each Metal pass that loads its attachments reads them back into tile
// memory and each that stores them writes them out again: megapixels moved per
// frame, not draws, are what such a GPU pays for. Vulkan-level counters can't
// see any of that, so with MCLA_METAL_STATS=1 (Documents/mcla-env.txt) the
// command buffer's encoder factories are counted here, with the samples each
// render pass loads and stores.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>

#include <atomic>
#include <stdio.h>
#include <stdlib.h>

namespace {

std::atomic<unsigned long long> g_counts[8];
// 0 render passes, 1 compute passes, 2 blit passes, 3 samples loaded, 4 samples
// stored, 5 render passes that load nothing, 6 command buffers committed,
// 7 render passes with a multisampled attachment.

IMP g_render = nullptr;
IMP g_compute[3] = {nullptr, nullptr, nullptr};
IMP g_blit[2] = {nullptr, nullptr};
IMP g_commit = nullptr;

unsigned long long Samples(MTLRenderPassAttachmentDescriptor* attachment, NSUInteger limit_width,
                           NSUInteger limit_height, bool* multisampled) {
  id<MTLTexture> texture = attachment.texture;
  if (!texture) {
    return 0;
  }
  NSUInteger width = texture.width, height = texture.height;
  if (limit_width && limit_width < width) {
    width = limit_width;
  }
  if (limit_height && limit_height < height) {
    height = limit_height;
  }
  if (texture.sampleCount > 1) {
    *multisampled = true;
  }
  return (unsigned long long)width * height * texture.sampleCount;
}

id CountedRenderEncoder(id self, SEL command, MTLRenderPassDescriptor* descriptor) {
  unsigned long long loaded = 0, stored = 0;
  bool multisampled = false;
  const NSUInteger width = descriptor.renderTargetWidth, height = descriptor.renderTargetHeight;
  auto add = [&](MTLRenderPassAttachmentDescriptor* attachment) {
    const unsigned long long samples = Samples(attachment, width, height, &multisampled);
    if (!samples) {
      return;
    }
    if (attachment.loadAction == MTLLoadActionLoad) {
      loaded += samples;
    }
    const MTLStoreAction store = attachment.storeAction;
    if (store == MTLStoreActionStore || store == MTLStoreActionStoreAndMultisampleResolve ||
        store == MTLStoreActionUnknown) {
      stored += samples;
    }
  };
  for (NSUInteger i = 0; i < 4; ++i) {
    add(descriptor.colorAttachments[i]);
  }
  add(descriptor.depthAttachment);
  // A combined depth and stencil texture is one read and one write.
  if (descriptor.stencilAttachment.texture != descriptor.depthAttachment.texture) {
    add(descriptor.stencilAttachment);
  }
  g_counts[0].fetch_add(1, std::memory_order_relaxed);
  g_counts[3].fetch_add(loaded, std::memory_order_relaxed);
  g_counts[4].fetch_add(stored, std::memory_order_relaxed);
  if (!loaded) {
    g_counts[5].fetch_add(1, std::memory_order_relaxed);
  }
  if (multisampled) {
    g_counts[7].fetch_add(1, std::memory_order_relaxed);
  }
  return ((id (*)(id, SEL, id))g_render)(self, command, descriptor);
}

id CountedCompute0(id self, SEL command) {
  g_counts[1].fetch_add(1, std::memory_order_relaxed);
  return ((id (*)(id, SEL))g_compute[0])(self, command);
}
id CountedCompute1(id self, SEL command, NSUInteger dispatch_type) {
  g_counts[1].fetch_add(1, std::memory_order_relaxed);
  return ((id (*)(id, SEL, NSUInteger))g_compute[1])(self, command, dispatch_type);
}
id CountedCompute2(id self, SEL command, id descriptor) {
  g_counts[1].fetch_add(1, std::memory_order_relaxed);
  return ((id (*)(id, SEL, id))g_compute[2])(self, command, descriptor);
}
id CountedBlit0(id self, SEL command) {
  g_counts[2].fetch_add(1, std::memory_order_relaxed);
  return ((id (*)(id, SEL))g_blit[0])(self, command);
}
id CountedBlit1(id self, SEL command, id descriptor) {
  g_counts[2].fetch_add(1, std::memory_order_relaxed);
  return ((id (*)(id, SEL, id))g_blit[1])(self, command, descriptor);
}
void CountedCommit(id self, SEL command) {
  g_counts[6].fetch_add(1, std::memory_order_relaxed);
  ((void (*)(id, SEL))g_commit)(self, command);
}

// Replaces a method of the class that implements it for cls; returns the
// original, or null when cls has no such method.
IMP Replace(Class cls, SEL selector, IMP replacement) {
  Method method = class_getInstanceMethod(cls, selector);
  return method ? method_setImplementation(method, replacement) : nullptr;
}

bool g_installed = false;

}  // namespace

extern "C" bool MclaIosMetalStatsInstall(void) {
  const char* setting = getenv("MCLA_METAL_STATS");
  if (!setting || setting[0] != '1') {
    return false;
  }
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    Class cls = object_getClass(buffer);
    if (!cls) {
      printf("[mcla-ios] Metal statistics: no command buffer class\n");
      return false;
    }
    g_render = Replace(cls, @selector(renderCommandEncoderWithDescriptor:), (IMP)CountedRenderEncoder);
    g_compute[0] = Replace(cls, @selector(computeCommandEncoder), (IMP)CountedCompute0);
    g_compute[1] = Replace(cls, @selector(computeCommandEncoderWithDispatchType:), (IMP)CountedCompute1);
    g_compute[2] = Replace(cls, @selector(computeCommandEncoderWithDescriptor:), (IMP)CountedCompute2);
    g_blit[0] = Replace(cls, @selector(blitCommandEncoder), (IMP)CountedBlit0);
    g_blit[1] = Replace(cls, @selector(blitCommandEncoderWithDescriptor:), (IMP)CountedBlit1);
    g_commit = Replace(cls, @selector(commit), (IMP)CountedCommit);
    [buffer commit];
    printf("[mcla-ios] Metal statistics on (%s): render %d, compute %d%d%d, blit %d%d, commit %d\n",
           class_getName(cls), g_render != nullptr, g_compute[0] != nullptr, g_compute[1] != nullptr,
           g_compute[2] != nullptr, g_blit[0] != nullptr, g_blit[1] != nullptr, g_commit != nullptr);
    g_installed = g_render != nullptr;
  }
  return g_installed;
}

// The counters so far (8 values, see above); false when they are not installed.
extern "C" bool MclaIosMetalStatsRead(unsigned long long* counts) {
  for (int i = 0; i < 8; ++i) {
    counts[i] = g_counts[i].load(std::memory_order_relaxed);
  }
  return g_installed;
}
