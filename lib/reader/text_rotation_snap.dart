import 'dart:math' as math;

/// Quarter-turn rotation with separate entry/release thresholds. Angular
/// distance is circular, so the +/-pi boundary has the same hysteresis.
class TextRotationSnap {
  double? _locked;
  double? guideAngle;
  static const enter = 4 * math.pi / 180;
  static const release = 7 * math.pi / 180;
  static double normalize(double angle) =>
      (angle + math.pi) % (2 * math.pi) - math.pi;
  static double distance(double a, double b) => normalize(a - b).abs();
  void reset() {
    _locked = null;
    guideAngle = null;
  }

  double update(double angle) {
    angle = normalize(angle);
    if (_locked != null && distance(angle, _locked!) <= release) {
      guideAngle = _locked;
      return _locked!;
    }
    _locked = null;
    final nearest = normalize((angle / (math.pi / 2)).round() * (math.pi / 2));
    final delta = distance(angle, nearest);
    guideAngle = delta <= release ? nearest : null;
    if (delta <= enter) {
      _locked = nearest;
      return nearest;
    }
    return angle;
  }
}
