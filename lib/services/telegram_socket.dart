import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:tg/tg.dart' as tg;

class IoSocket implements tg.SocketAbstraction {
  final Socket _socket;
  late final StreamController<Uint8List> _controller;
  StreamSubscription<Uint8List>? _subscription;

  bool _closed = false;

  IoSocket(this._socket) {
    _controller = StreamController<Uint8List>.broadcast(
      onCancel: () {
        if (!_controller.hasListener) {
          _subscription?.pause();
        }
      },
      onListen: () {
        _subscription?.resume();
      },
    );
    _subscription = _socket.cast<Uint8List>().listen(
      (data) {
        if (!_closed) try { _controller.add(data); } catch (_) {}
      },
      onError: (e) {
        if (!_closed) try { _controller.addError(e); } catch (_) {}
      },
      onDone: () {
        _closed = true;
        try { _controller.close(); } catch (_) {}
      },
    );
  }

  @override
  Stream<Uint8List> get receiver => _controller.stream;

  @override
  Future<void> send(List<int> data) async {
    if (_closed) throw SocketException('Socket is closed');
    _socket.add(data);
    await _socket.flush();
  }

  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    await _controller.close();
    await _socket.close();
  }
}
