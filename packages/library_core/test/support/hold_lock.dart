import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final handle = await File(arguments.single).open(mode: FileMode.append);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();
  try {
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  } finally {
    await handle.unlock();
    await handle.close();
  }
}
