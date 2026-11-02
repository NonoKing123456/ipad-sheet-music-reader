import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:score_reader/reader/text_rotation_snap.dart';

void main() {
  double degrees(double value) => value * math.pi / 180;
  test('orthogonal snap enters at four degrees and releases after seven', () {
    final snap = TextRotationSnap();
    expect(snap.update(degrees(3)), 0);
    expect(snap.update(degrees(6)), 0);
    expect(snap.update(degrees(8)), closeTo(degrees(8), 1e-12));
    expect(snap.update(degrees(5)), closeTo(degrees(5), 1e-12));
    expect(snap.update(degrees(3)), 0);
    snap.reset();
    expect(snap.update(degrees(88)), math.pi / 2);
    expect(snap.update(degrees(96)), math.pi / 2);
    expect(snap.update(degrees(98)), closeTo(degrees(98), 1e-12));
  });
  test('quarter turn snap is continuous across the signed pi boundary', () {
    final snap = TextRotationSnap();
    expect(snap.update(degrees(179)), -math.pi);
    expect(snap.update(degrees(-179)), -math.pi);
    expect(snap.update(degrees(-174)), -math.pi);
    expect(snap.update(degrees(-171)), closeTo(degrees(-171), 1e-12));
    snap.reset();
    expect(snap.update(degrees(-89)), -math.pi / 2);
  });
}
