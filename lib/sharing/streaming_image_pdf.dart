import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal PDF 1.4 image-page writer. Only xref offsets and page IDs accumulate;
/// RGB conversion and deflate output are drained in 32-row chunks.
class StreamingImagePdf {
  StreamingImagePdf._(this._sink);
  final IOSink _sink;
  final List<int> _offsets = [0, 0, 0];
  final List<int> _pages = [];
  int _position = 0;
  bool _closed = false;

  static Future<StreamingImagePdf> open(File file) async {
    final writer = StreamingImagePdf._(file.openWrite());
    writer._text('%PDF-1.4\n%\u00e2\u00e3\u00cf\u00d3\n');
    writer._object(1, '<< /Type /Catalog /Pages 2 0 R >>');
    return writer;
  }

  void _bytes(List<int> bytes) {
    _position += bytes.length;
    _sink.add(bytes);
  }

  void _text(String value) => _bytes(latin1.encode(value));
  void _start(int id) {
    while (_offsets.length <= id) {
      _offsets.add(0);
    }
    _offsets[id] = _position;
    _text('$id 0 obj\n');
  }

  void _object(int id, String value) {
    _start(id);
    _text('$value\nendobj\n');
  }

  Future<void> addPage({
    required ByteData rgba,
    required int width,
    required int height,
    required double pageWidth,
    required double pageHeight,
    required void Function() checkCancelled,
  }) async {
    if (width < 1 ||
        height < 1 ||
        rgba.lengthInBytes != width * height * 4 ||
        !pageWidth.isFinite ||
        !pageHeight.isFinite ||
        pageWidth <= 0 ||
        pageHeight <= 0) {
      throw const FormatException('Invalid export page dimensions.');
    }
    checkCancelled();
    final page = 3 + _pages.length * 4,
        image = page + 1,
        contents = page + 2,
        length = page + 3;
    _pages.add(page);
    final w = pageWidth.toStringAsFixed(5), h = pageHeight.toStringAsFixed(5);
    _object(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] '
      '/Resources << /XObject << /Im0 $image 0 R >> >> /Contents $contents 0 R >>',
    );
    final commands = 'q $w 0 0 $h 0 0 cm /Im0 Do Q\n';
    _object(
      contents,
      '<< /Length ${commands.length} >>\nstream\n${commands}endstream',
    );
    _start(image);
    _text(
      '<< /Type /XObject /Subtype /Image /Width $width /Height $height '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode '
      '/Length $length 0 R >>\nstream\n',
    );
    final start = _position;
    final compressor = ZLibEncoder().startChunkedConversion(_ChunkSink(_bytes));
    final pixels = rgba.buffer.asUint8List(
      rgba.offsetInBytes,
      rgba.lengthInBytes,
    );
    try {
      for (var row = 0; row < height; row += 32) {
        checkCancelled();
        final rows = (height - row).clamp(0, 32);
        final rgb = Uint8List(width * rows * 3);
        var offset = row * width * 4;
        for (var i = 0; i < rgb.length; i += 3, offset += 4) {
          rgb[i] = pixels[offset];
          rgb[i + 1] = pixels[offset + 1];
          rgb[i + 2] = pixels[offset + 2];
        }
        compressor.add(rgb);
        await _sink.flush();
      }
    } finally {
      compressor.close();
    }
    final size = _position - start;
    _text('\nendstream\nendobj\n');
    _object(length, '$size');
    await _sink.flush();
  }

  Future<void> finish() async {
    _object(
      2,
      '<< /Type /Pages /Count ${_pages.length} /Kids [${_pages.map((id) => '$id 0 R').join(' ')}] >>',
    );
    final xref = _position;
    _text('xref\n0 ${_offsets.length}\n0000000000 65535 f \n');
    for (final offset in _offsets.skip(1)) {
      _text('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    _text(
      'trailer\n<< /Size ${_offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
    );
    await close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sink.close();
  }
}

class _ChunkSink implements Sink<List<int>> {
  _ChunkSink(this.write);
  final void Function(List<int>) write;
  @override
  void add(List<int> data) => write(data);
  @override
  void close() {}
}
