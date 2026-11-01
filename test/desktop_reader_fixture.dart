import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

List<int> desktopPdf(int count) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(count, (i) => '${3 + i * 2} 0 R').join(' ')}] /Count $count >>',
  ];
  for (var i = 0; i < count; i++) {
    final stream =
        '${i.isEven ? '.96 .96 .96' : '.9 .94 .98'} rg 0 0 600 800 re f\n0 g BT /F1 24 Tf 60 720 Td (Synthetic page ${i + 1}) Tj ET\n';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add(
      '<< /Length ${ascii.encode(stream).length} >>\nstream\n${stream}endstream',
    );
  }
  final out = StringBuffer('%PDF-1.4\n'), offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = ascii.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(out.toString());
}

Future<void> desktopUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 650 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  expect(done(), isTrue, reason: 'bounded desktop render/persistence');
  await tester.pump();
}

Future<void> desktopSettle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
}
