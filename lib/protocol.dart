// Phone side of docs/protocol.md (v1). Pure Dart so it can be unit-tested.
import 'dart:typed_data';

const serviceUuid = '3f66b6a2-8fd5-423c-9ef1-494e6f3b9100';
const rxUuid = '3f66b6a2-8fd5-423c-9ef1-494e6f3b9101';
const txUuid = '3f66b6a2-8fd5-423c-9ef1-494e6f3b9102';

const opGetStatus = 0x01, opSetTime = 0x02, opList = 0x03, opPull = 0x04;
const opAck = 0x05, opSetMute = 0x06, opSetWakeWord = 0x07;
const frameResp = 0x01, frameData = 0x02, frameEvent = 0x03;
const eventChunkReady = 0x01, eventBookmark = 0x02;
const statusOk = 0, errNotFound = 0x04, errUnsupported = 0x08;
const statusNames = [
  'OK', 'ERR_UNKNOWN_OP', 'ERR_BAD_LENGTH', 'ERR_BAD_VALUE', 'ERR_NOT_FOUND',
  'ERR_RANGE', 'ERR_CRC', 'ERR_IO', 'ERR_UNSUPPORTED', 'ERR_MTU', //
];

const headerSize = 512, blockSize = 256, samplesPerBlock = 505, sampleRate = 16000;
const maxBlocks = 1901, maxPull = 65536, minMtu = 247;
const flagSpeech = 1, flagBookmarked = 2, flagTimeSynced = 4, flagRecovered = 8;

class DeviceError implements Exception {
  DeviceError(this.status);
  final int status;
  @override
  String toString() => status < statusNames.length ? statusNames[status] : 'status 0x${status.toRadixString(16)}';
}

ByteData _le(Uint8List b) => ByteData.sublistView(b);

Uint8List u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List u64(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little);

Uint8List requestFrame(int op, int reqId, [List<int> payload = const []]) =>
    Uint8List.fromList([op, reqId, ...payload]);

String seqHex(int seq) => seq.toRadixString(16).toUpperCase().padLeft(7, '0');

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

/// zlib-compatible crc32; pass the previous result to continue over another piece.
int crc32(List<int> bytes, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

class DeviceStatus {
  factory DeviceStatus.parse(Uint8List p, int receivedAtMs) {
    if (p.length < 32) throw const FormatException('status too short');
    return DeviceStatus._(p, receivedAtMs);
  }

  DeviceStatus._(Uint8List p, this.receivedAtMs)
      : protoVersion = _le(p).getUint16(0, Endian.little),
        state = p[2],
        batteryPct = p[3],
        storeId = _le(p).getUint32(4, Endian.little),
        bootId = _le(p).getUint32(8, Endian.little),
        uptimeMs = _le(p).getUint64(12, Endian.little),
        freeKib = _le(p).getUint32(20, Endian.little),
        totalKib = _le(p).getUint32(24, Endian.little),
        pendingChunks = _le(p).getUint32(28, Endian.little);

  final int protoVersion, state, batteryPct, storeId, bootId, uptimeMs;
  final int freeKib, totalKib, pendingChunks, receivedAtMs;
  bool get recording => state & 1 != 0;
  bool get muted => state & 2 != 0;
  bool get wakeWord => state & 4 != 0;
  bool get timeSynced => state & 8 != 0;
  bool get storageFull => state & 16 != 0;
  bool get sdError => state & 32 != 0;
  bool get pairingWindowOpen => state & 64 != 0;
}

class ListEntry {
  ListEntry(this.seq, this.size, this.flags);
  final int seq, size, flags;
}

/// LIST response payload -> (total_pending, entries).
(int, List<ListEntry>) parseList(Uint8List p) {
  if (p.length < 5) throw const FormatException('LIST too short');
  final d = _le(p);
  final count = p[4];
  if (p.length < 5 + count * 9) throw const FormatException('LIST truncated');
  return (
    d.getUint32(0, Endian.little),
    [
      for (var i = 0; i < count; i++)
        ListEntry(d.getUint32(5 + i * 9, Endian.little), d.getUint32(9 + i * 9, Endian.little), p[13 + i * 9]),
    ],
  );
}

class ChunkHeader {
  ChunkHeader._(this.flags, this.storeId, this.seq, this.bootId, this.startUptimeMs, this.epochOffsetMs, this.crc,
      this.bookmarksMs, this.dataSize);

  final int flags, storeId, seq, bootId, startUptimeMs, epochOffsetMs, crc, dataSize;
  final List<int> bookmarksMs;
  int get durationMs => dataSize ~/ blockSize * samplesPerBlock * 1000 ~/ sampleRate;

  /// Parses and checks a complete chunk file received from the device (trust boundary):
  /// format fields, seq, length and CRC must all match the contract. store_id is taken from the header (1.3).
  static ChunkHeader verify(Uint8List f, {required int seq}) {
    if (f.length < headerSize + blockSize) throw const FormatException('chunk too short');
    final d = _le(f);
    String tag(int o) => String.fromCharCodes(f, o, o + 4);
    int u16(int o) => d.getUint16(o, Endian.little);
    int u32at(int o) => d.getUint32(o, Endian.little);
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE' || tag(12) != 'fmt ' || tag(52) != 'tkmd' || tag(504) != 'data' ||
        u16(20) != 0x11 || u16(22) != 1 || u32at(24) != sampleRate || u16(32) != blockSize || u16(38) != samplesPerBlock) {
      throw const FormatException('not a v1 chunk');
    }
    final dataSize = u32at(508);
    if (dataSize == 0 || dataSize % blockSize != 0 || dataSize > maxBlocks * blockSize ||
        f.length != headerSize + dataSize) {
      throw const FormatException('bad data size');
    }
    if (u32at(68) != seq) throw const FormatException('chunk identity mismatch');
    final header = Uint8List.fromList(f.sublist(0, headerSize))..fillRange(92, 96, 0);
    final crc = crc32(header, crc32(Uint8List.sublistView(f, headerSize)));
    if (crc != u32at(92)) throw const FormatException('crc mismatch');
    final count = f[96] > 16 ? 16 : f[96];
    return ChunkHeader._(
      u16(62),
      u32at(64),
      seq,
      u32at(72),
      d.getUint64(76, Endian.little),
      d.getInt64(84, Endian.little),
      crc,
      [for (var i = 0; i < count; i++) u32at(100 + i * 4)],
      dataSize,
    );
  }
}
