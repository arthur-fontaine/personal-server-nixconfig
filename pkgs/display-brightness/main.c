// Set the backlight of the built-in display, e.g. `display-brightness 0`.
// DisplayServices is private, so it is opened at run time instead of linked.
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*SetBrightness)(CGDirectDisplayID, float);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: display-brightness <0..1>\n");
    return 2;
  }
  float level = strtof(argv[1], NULL);

  void *lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
  SetBrightness set = lib ? (SetBrightness)dlsym(lib, "DisplayServicesSetBrightness") : NULL;
  if (!set) {
    fprintf(stderr, "display-brightness: DisplayServicesSetBrightness unavailable\n");
    return 1;
  }

  CGDirectDisplayID displays[16];
  uint32_t count = 0;
  if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) {
    fprintf(stderr, "display-brightness: no display list (is there a GUI session?)\n");
    return 1;
  }
  int failed = 0;
  for (uint32_t i = 0; i < count; i++) {
    if (CGDisplayIsBuiltin(displays[i]) && set(displays[i], level) != 0) failed = 1;
  }
  return failed;
}
