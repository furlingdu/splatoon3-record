import 'dart:async';

class ExternalLinkBus {
  static final StreamController<Uri> Controller = StreamController<Uri>.broadcast();
  static Uri? Pending;

  static void Add(Uri Link) {
    if (Link.scheme.isEmpty) return;
    Controller.add(Link);
  }
}








