#ifndef FLUTTER_PLUGIN_LINUX_CAPTURE_PLUGIN_H_
#define FLUTTER_PLUGIN_LINUX_CAPTURE_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

FLUTTER_PLUGIN_EXPORT void linux_capture_plugin_register_with_registrar(FlPluginRegistrar* registrar);

#undef FLUTTER_PLUGIN_EXPORT

G_END_DECLS

#endif
