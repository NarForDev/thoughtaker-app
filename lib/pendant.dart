// BLE link and sync loop for the pendant (docs/protocol.md sections 2 and 3).
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:universal_ble/universal_ble.dart';

import 'db.dart';
import 'protocol.dart';

const _deviceIdKey = 'device_id';
const _lastSyncKey = 'last_sync_ms';
const _power = MethodChannel('thoughtaker/power');
const _minBackoff = Duration(seconds: 30), _maxBackoff = Duration(minutes: 10);

class PendantController extends ChangeNotifier {
  PendantController(this.db, this.onChunkCommitted, {required this.chunksDir, required this.partialDir});

  final AppDb db;
  final void Function() onChunkCommitted;
  final Directory chunksDir, partialDir;

  String? _deviceId;
  bool connected = false, busy = false, syncing = false;
  String message = 'Not connected';
  DeviceStatus? status;
  double? pullProgress; // 0..1 of the chunk being pulled
  int chunksStored = 0; // bumps on every commit so listeners re-query the DB
  List<BleDevice> found = []; // pendants seen by the last scan, for the user to pick from
  String? _picked;

  final _subs = <StreamSubscription>[];
  Future<void> _tail = Future.value();
  int _reqId = 0, _pendingOp = 0, _pendingReq = 0;
  Completer<Uint8List>? _pending;
  void Function(int offset, Uint8List bytes)? _onData;
  Timer? _timer, _auto;
  void Function()? _rearm;
  Duration _backoff = _minBackoff;

  bool get hasDevice => db.setting(_deviceIdKey) != null;

  /// Tells listeners the stored chunks changed outside a sync (e.g. the user deleted some).
  void dataChanged() {
    chunksStored++;
    notifyListeners();
  }

  int? get lastSyncMs => int.tryParse(db.setting(_lastSyncKey) ?? '');

  /// Pair once, then this keeps reconnecting and syncing in the background, backing off while the pendant is away.
  void startAutoSync([Duration delay = Duration.zero]) {
    _auto?.cancel();
    _auto = Timer(delay, () async {
      if (hasDevice) {
        _keepAlive(true);
        if (!connected && !busy) await syncNow();
        _backoff = connected ? _minBackoff : (_backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2);
      }
      startAutoSync(_backoff);
    });
  }

  // The foreground service keeps the process alive; a failure here only means sync pauses with the app.
  void _keepAlive(bool on) => _power.invokeMethod<void>('keepAlive', on).catchError((_) {});

  void _say(String m) {
    message = m;
    notifyListeners();
  }

  Future<void> _guard(String what, Future<void> Function() body) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      await body();
    } catch (e) {
      _say('$what failed: $e');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Connects if needed, then syncs everything pending.
  Future<void> syncNow() => _guard('Sync', _sync);

  /// Lists nearby pendants in [found]; the user picks one with [pair].
  Future<void> scan() => _guard('Scan', _scan);

  Future<void> pair(String deviceId) {
    _picked = deviceId;
    return syncNow();
  }

  Future<void> setMute(bool muted) => _guard('Mute', () async {
        await _request(opSetMute, [muted ? 1 : 0]);
        await _refreshStatus();
      });

  Future<void> disconnect() async {
    final id = _deviceId;
    _dropLink('Disconnected');
    if (id != null) await UniversalBle.disconnect(id).catchError((_) {});
  }

  /// Forgets the paired pendant so the next connect scans for one again.
  Future<void> forget() async {
    final id = db.setting(_deviceIdKey);
    await disconnect();
    // Drop Android's bond too, so the next pair() makes a fresh one after the pendant's BOOT hold deletes its own.
    if (id != null) await UniversalBle.unpair(id).catchError((_) {});
    db.setSetting(_deviceIdKey, null);
    _picked = null;
    _keepAlive(false);
    _say("Forgotten. Hold the pendant's BOOT button for 3 s to pair again.");
  }

  Future<void> _connect() async {
    if (connected) return;
    await UniversalBle.requestPermissions();
    final saved = db.setting(_deviceIdKey);
    final id = saved ?? _picked ?? (throw StateError('pick a pendant first'));
    _say('Connecting');
    await UniversalBle.connect(id, timeout: const Duration(seconds: 20));
    _deviceId = id;
    _subs
      ..add(UniversalBle.connectionStream(id).listen((up) {
        if (!up) _dropLink('Connection lost');
      }))
      ..add(UniversalBle.characteristicValueStream(id, txUuid).listen(_onFrame));
    try {
      // Bond before the first GATT operation; RX/TX need an encrypted link.
      var pairedNow = false;
      if (await UniversalBle.isPaired(id) != true) {
        _say('Pairing (accept the prompt)');
        await UniversalBle.pair(id, timeout: const Duration(seconds: 60));
        pairedNow = true;
      }
      await UniversalBle.discoverServices(id);
      final mtu = await UniversalBle.requestMtu(id, 517);
      if (mtu < minMtu) throw StateError('MTU $mtu is below $minMtu');
      await UniversalBle.subscribeNotifications(id, serviceUuid, txUuid);
      connected = true;
      await _request(opSetTime, u64(DateTime.now().millisecondsSinceEpoch));
      final s = await _refreshStatus();
      if (s.protoVersion != 1) throw StateError('pendant speaks protocol v${s.protoVersion}, app needs v1');
      // 2.3: a pendant takes a new bond only in its pairing window, and bonding closes that window,
      // so a fresh bond is the proof; an old bond must come with the window open.
      if (saved == null && !pairedNow && !s.pairingWindowOpen) {
        throw StateError('that pendant is not in pairing mode; hold its BOOT button for 3 s, then pair within 2 minutes');
      }
      db.setSetting(_deviceIdKey, id);
      // Lets chunks recorded earlier in this boot (time_synced clear) get an exact time later.
      db.saveBootOffset(s.storeId, s.bootId, s.receivedAtMs - s.uptimeMs);
      _say('Connected');
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  Future<void> _scan() async {
    await UniversalBle.requestPermissions();
    found = [];
    _say('Scanning for pendants');
    final sub = UniversalBle.scanStream.listen((d) {
      if (found.any((f) => f.deviceId == d.deviceId)) return;
      found = [...found, d];
      notifyListeners();
    });
    try {
      await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [serviceUuid]));
      await Future<void>.delayed(const Duration(seconds: 6));
    } finally {
      await sub.cancel();
      await UniversalBle.stopScan().catchError((_) {});
    }
    _say(found.isEmpty ? 'No pendant found; is it on and in range?' : 'Tap your pendant to pair it');
  }

  void _dropLink(String why) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final wasUp = connected || _deviceId != null;
    connected = false;
    _deviceId = null;
    _fail(StateError(why));
    if (wasUp) _say(why);
  }

  void _fail(Object error) {
    final p = _pending;
    if (p != null && !p.isCompleted) p.completeError(error);
  }

  void _onFrame(Uint8List f) {
    if (f.isEmpty) return;
    final d = ByteData.sublistView(f);
    switch (f[0]) {
      case frameResp when f.length >= 4:
        final p = _pending;
        if (p == null || p.isCompleted || f[1] != _pendingOp || f[2] != _pendingReq) return;
        f[3] == statusOk ? p.complete(Uint8List.sublistView(f, 4)) : p.completeError(DeviceError(f[3]));
      case frameData when f.length >= 5:
        _rearm?.call();
        _onData?.call(d.getUint32(1, Endian.little), Uint8List.sublistView(f, 5));
      case frameEvent when f.length >= 2:
        if (f[1] == eventChunkReady && connected && !busy) syncNow();
        if (f[1] == eventBookmark) _say('Bookmarked on the pendant');
    }
  }

  /// One request at a time (3.1): queued behind the previous one, resolved by its RESP.
  Future<Uint8List> _request(int op, List<int> payload,
      {Duration timeout = const Duration(seconds: 2), void Function(int, Uint8List)? onData}) {
    final run = _tail.then((_) => _send(op, payload, timeout, onData));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Uint8List> _send(int op, List<int> payload, Duration timeout, void Function(int, Uint8List)? onData) async {
    final id = _deviceId;
    if (!connected || id == null) throw StateError('not connected');
    final reply = Completer<Uint8List>();
    _pending = reply;
    _pendingOp = op;
    _pendingReq = _reqId = (_reqId + 1) & 0xFF;
    _onData = onData;
    _rearm = () {
      _timer?.cancel();
      _timer = Timer(timeout, () {
        _fail(TimeoutException('no reply to op $op'));
        // 3.6: on timeout drop the link; the device then forgets the transfer.
        disconnect();
      });
    };
    _rearm!();
    try {
      await UniversalBle.write(id, serviceUuid, rxUuid, requestFrame(op, _pendingReq, payload));
      return await reply.future;
    } finally {
      _timer?.cancel();
      _pending = null;
      _onData = null;
      _rearm = null;
    }
  }

  Future<DeviceStatus> _refreshStatus() async {
    final p = await _request(opGetStatus, const []);
    final s = status = DeviceStatus.parse(p, DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
    return s;
  }

  Future<void> _sync() async {
    // Reconnect and resume on link loss; partial files keep the contiguous offset.
    for (var attempt = 0;; attempt++) {
      try {
        await _connect();
        await _syncPending();
        return;
      } catch (e) {
        if (attempt >= 2 || !hasDevice) rethrow; // no point retrying a scan/pair that failed
        _say('Sync interrupted ($e), retrying');
        await disconnect();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _syncPending() async {
    syncing = true;
    notifyListeners();
    final id = _deviceId!;
    await UniversalBle.requestConnectionPriority(id, BleConnectionPriority.highPerformance).catchError((_) {});
    final failed = <int>{};
    var stalled = false;
    try {
      while (true) {
        final (total, entries) = parseList(await _request(opList, [255], timeout: const Duration(seconds: 10)));
        final todo = entries.where((e) => !failed.contains(e.seq)).toList();
        if (total == 0 || todo.isEmpty) {
          // shortcut: LIST has no start offset, so a full page of failed chunks hides the rest; needs a LIST cursor.
          stalled = total > entries.length;
          break;
        }
        for (final e in todo) {
          bool ok;
          try {
            ok = await _syncChunk(e);
          } on DeviceError {
            ok = false; // e.g. ERR_IO on one bad file: skip it rather than stall every later chunk
          }
          if (!ok) failed.add(e.seq);
        }
      }
      await _refreshStatus();
      if (!stalled) db.setSetting(_lastSyncKey, '${DateTime.now().millisecondsSinceEpoch}');
      _say(stalled
          ? 'Sync stalled: ${failed.length} chunk(s) could not be read and block the rest'
          : failed.isEmpty
              ? 'Synced'
              : 'Synced; ${failed.length} chunk(s) could not be read and stay on the pendant');
    } finally {
      syncing = false;
      pullProgress = null;
      notifyListeners();
      if (connected) {
        await UniversalBle.requestConnectionPriority(id, BleConnectionPriority.balanced).catchError((_) {});
      }
    }
  }

  /// Pulls, verifies, commits and acks one chunk. Returns false if it could not be verified.
  Future<bool> _syncChunk(ListEntry e) async {
    String name(int storeId) => '${storeId.toRadixString(16).padLeft(8, '0')}_${seqHex(e.seq)}';
    // Usually the current store; a chunk recorded before a flash erase carries an older one (1.3).
    final stored = db.chunkCrc(status!.storeId, e.seq);
    if (stored != null) {
      await _request(opAck, [...u32(e.seq), ...u32(stored)]); // committed earlier, ACK reply was lost
      return true;
    }
    // Bounds the memory and disk we give to one device-reported size.
    if (e.size < headerSize + blockSize || e.size > headerSize + maxBlocks * blockSize) return false;
    final part = File('${partialDir.path}/${name(status!.storeId)}.part');
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await _pull(e, part);
      } on DeviceError catch (err) {
        if (err.status != errNotFound) rethrow;
        if (await part.exists()) await part.delete(); // already acked elsewhere
        return true;
      }
      final bytes = await part.readAsBytes();
      final ChunkHeader h;
      try {
        h = ChunkHeader.verify(bytes, seq: e.seq);
      } on FormatException {
        await part.delete(); // 3.5: bad crc -> pull again from offset 0
        continue;
      }
      final known = db.chunkCrc(h.storeId, e.seq); // older-store chunk committed earlier, ACK reply was lost
      if (known != null) {
        await part.delete();
        if (known != h.crc) return false; // never overwrite a committed chunk or ack audio we did not keep
        await _request(opAck, [...u32(e.seq), ...u32(h.crc)]);
        return true;
      }
      final dest = await part.rename('${chunksDir.path}/${name(h.storeId)}.wav');
      final offset = (h.flags & flagTimeSynced) != 0 ? h.epochOffsetMs : db.bootOffset(h.storeId, h.bootId);
      db.insertChunk(
        storeId: h.storeId,
        seq: e.seq,
        bootId: h.bootId,
        flags: h.flags,
        startUptimeMs: h.startUptimeMs,
        startMs: offset == null ? null : h.startUptimeMs + offset,
        durationMs: h.durationMs,
        bookmarksMs: h.bookmarksMs,
        crc: h.crc,
        path: dest.path,
      );
      chunksStored++;
      notifyListeners();
      // Only now, with the file fsynced and the row committed, may the device delete its copy.
      await _request(opAck, [...u32(e.seq), ...u32(h.crc)]);
      onChunkCommitted();
      return true;
    }
    return false;
  }

  Future<void> _pull(ListEntry e, File part) async {
    final raf = await part.open(mode: FileMode.append);
    try {
      var got = await raf.length();
      if (got > e.size) {
        await raf.truncate(0);
        got = 0;
      }
      while (got < e.size) {
        final end = min(got + maxPull, e.size);
        await _request(opPull, [...u32(e.seq), ...u32(got), ...u32(end - got)], timeout: const Duration(seconds: 5),
            onData: (offset, bytes) {
          // Anything but the next contiguous bytes is dropped; the loop re-pulls from `got` (3.6).
          if (offset != got || offset + bytes.length > end) return;
          try {
            raf.writeFromSync(bytes);
          } catch (err) {
            _fail(err); // e.g. phone storage full: fail the PULL instead of re-requesting the same bytes forever
            return;
          }
          got += bytes.length;
        });
        await raf.flush();
        pullProgress = got / e.size;
        notifyListeners();
      }
    } finally {
      await raf.close();
    }
  }
}
