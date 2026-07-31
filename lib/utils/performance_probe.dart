import 'package:flutter/foundation.dart';

const bool performanceHudEnabled = bool.fromEnvironment(
  'PILI_PERF_HUD',
  defaultValue: false,
);

enum RcmdRenderMode {
  memoryImage('内存图'),
  diskCachedImage('磁盘图'),
  noImage('无图'),
  lightweight('轻卡');

  const RcmdRenderMode(this.label);

  final String label;
}

abstract final class PerformanceProbe {
  static final ValueNotifier<RcmdRenderMode> rcmdRenderMode = ValueNotifier(
    RcmdRenderMode.memoryImage,
  );

  static int _cardBuilds = 0;
  static int _imageBuilds = 0;

  static void recordCardBuild() {
    if (performanceHudEnabled) _cardBuilds++;
  }

  static void recordImageBuild() {
    if (performanceHudEnabled) _imageBuilds++;
  }

  static ({int cards, int images}) takeBuildCounts() {
    final result = (cards: _cardBuilds, images: _imageBuilds);
    _cardBuilds = 0;
    _imageBuilds = 0;
    return result;
  }

  static RcmdRenderMode cycleRcmdRenderMode() {
    final values = RcmdRenderMode.values;
    final next = values[(rcmdRenderMode.value.index + 1) % values.length];
    rcmdRenderMode.value = next;
    return next;
  }
}
