import 'dart:io';

import 'package:crypto/crypto.dart';

/// A model file pinned by URL, size and SHA-256.
typedef ModelFile = ({String name, String url, int size, String sha256});

bool isDownloaded(Directory dir, ModelFile m) {
  // A file only gets its final name after its hash matched, so size is enough to recognise it.
  final f = File('${dir.path}/${m.name}');
  return f.existsSync() && f.lengthSync() == m.size;
}

/// Downloads [m] into [dir] unless present, reporting bytes received to [onBytes].
/// The file is used only after its size and SHA-256 match: a changed upstream file is rejected, not run.
Future<void> downloadVerified(HttpClient client, Directory dir, ModelFile m, void Function(int got) onBytes) async {
  if (isDownloaded(dir, m)) return onBytes(m.size);
  await dir.create(recursive: true);
  final part = File('${dir.path}/${m.name}.part');
  final res = await (await client.getUrl(Uri.parse(m.url))).close();
  if (res.statusCode != HttpStatus.ok) throw HttpException('${m.name}: HTTP ${res.statusCode}');
  final sink = part.openWrite();
  var got = 0;
  try {
    await for (final bytes in res) {
      got += bytes.length;
      if (got > m.size) throw FormatException('${m.name}: larger than expected');
      sink.add(bytes);
      onBytes(got);
    }
  } finally {
    await sink.close();
  }
  final digest = await sha256.bind(part.openRead()).first;
  if (got != m.size || digest.toString() != m.sha256) {
    await part.delete();
    throw FormatException('${m.name}: size or checksum mismatch');
  }
  await part.rename('${dir.path}/${m.name}');
}
