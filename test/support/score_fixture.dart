import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<int> syntheticPdf(int count) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${List.generate(count, (i) => '${3 + i * 2} 0 R').join(' ')}] /Count $count >>',
  ];
  for (var page = 1; page <= count; page++) {
    final stream = StringBuffer('1 1 1 rg 0 0 707 1000 re f\n0 g\n');
    stream.write(
      'BT /F1 11 Tf 55 956 Td (The Quiet Rehearsal - Synthetic page $page) Tj ET\n',
    );
    for (var system = 0; system < 11; system++) {
      final y = 900 - system * 72;
      stream.write('0 G 0.6 w\n');
      for (var line = 0; line < 5; line++) {
        stream.write('48 ${y - line * 5} m 660 ${y - line * 5} l S\n');
      }
      for (var note = 0; note < 20; note++) {
        final x = 62 + note * 29, ny = y - ((note * 3 + page) % 9) * 2.5;
        stream.write(
          '0 g $x $ny 7 4 re f ${x + 7} $ny m ${x + 7} ${ny + 22} l S\n',
        );
      }
    }
    stream.write('BT /F1 11 Tf 350 30 Td ($page) Tj ET\n');
    final data = stream.toString();
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 707 1000] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents ${4 + (page - 1) * 2} 0 R >>',
    );
    objects.add(
      '<< /Length ${ascii.encode(data).length} >>\nstream\n${data}endstream',
    );
  }
  final output = StringBuffer('%PDF-1.4\n'), offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(ascii.encode(output.toString()).length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = ascii.encode(output.toString()).length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(output.toString());
}

Future<void> deleteFixture(WidgetTester tester, Directory directory) async {
  var deleted = false;
  for (var i = 0; i < 200 && !deleted; i++) {
    deleted = (await tester.runAsync(() async {
      try {
        await directory.delete(recursive: true);
        return true;
      } on PathAccessException {
        return false;
      }
    }))!;
    if (!deleted) {
      await tester.pump(const Duration(milliseconds: 16));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
  }
  expect(
    deleted,
    isTrue,
    reason: 'synthetic fixture watchers and writes released',
  );
}
