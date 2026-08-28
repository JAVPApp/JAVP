import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:javp/services/background/interactive_work_gate.dart';

/// HTTP wrapper that holds back background requests while [InteractiveWorkGate]
/// is running user-facing work (and caps background concurrency otherwise).
///
/// Interactive vs background is inferred from [InteractiveWorkGate.inInteractiveZone]
/// — callers wrap browse/details/playback in [InteractiveWorkGate.run] rather
/// than tagging individual URLs.
///
/// The background slot is held until the response **body** completes (not just
/// headers), so a large catalog/EPG download still counts against the cap.
///
/// Does not close [_inner]; [LibraryProvider] owns the real client.
class PrioritizedHttpClient extends http.BaseClient {
  PrioritizedHttpClient(this._inner, {required this.gate});

  final http.Client _inner;
  final InteractiveWorkGate gate;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final interactive = InteractiveWorkGate.inInteractiveZone;
    if (!interactive) {
      await gate.acquireBackgroundHttp();
    }
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (_) {
      if (!interactive) gate.releaseBackgroundHttp();
      rethrow;
    }
    if (interactive) return response;
    return _holdSlotUntilBodyDone(response);
  }

  http.StreamedResponse _holdSlotUntilBodyDone(http.StreamedResponse response) {
    var released = false;
    void release() {
      if (released) return;
      released = true;
      gate.releaseBackgroundHttp();
    }

    final controller = StreamController<List<int>>();
    final sub = response.stream.listen(
      controller.add,
      onError: (Object error, StackTrace stack) {
        release();
        controller.addError(error, stack);
      },
      onDone: () {
        release();
        if (!controller.isClosed) unawaited(controller.close());
      },
      cancelOnError: true,
    );
    controller.onCancel = () async {
      release();
      await sub.cancel();
    };

    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {}
}
