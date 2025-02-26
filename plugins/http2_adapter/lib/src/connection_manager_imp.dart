part of 'http2_adapter.dart';

/// Default implementation of ConnectionManager
class _ConnectionManager implements ConnectionManager {
  /// Callback when socket created.
  ///
  /// We can set trusted certificates and handler
  /// for unverifiable certificates.
  final void Function(Uri uri, ClientSetting)? onClientCreate;

  /// Sets the idle timeout(milliseconds) of non-active persistent
  /// connections. For the sake of socket reuse feature with http/2,
  /// the value should not be less than 1000 (1s).
  final int _idleTimeout;

  /// Saving the reusable connections
  final _transportsMap = <String, _ClientTransportConnectionState>{};

  /// Saving the connecting futures
  final _connectFutures = <String, Future<_ClientTransportConnectionState>>{};

  bool _closed = false;
  bool _forceClosed = false;

  _ConnectionManager({int? idleTimeout, this.onClientCreate})
      : _idleTimeout = idleTimeout ?? 1000;

  @override
  Future<ClientTransportConnection> getConnection(
      RequestOptions options) async {
    if (_closed) {
      throw Exception(
          "Can't establish connection after [ConnectionManager] closed!");
    }
    var uri = options.uri;
    var domain = '${uri.host}:${uri.port}';
    var transportState = _transportsMap[domain];
    if (transportState == null) {
      var _initFuture = _connectFutures[domain];
      if (_initFuture == null) {
        _connectFutures[domain] = _initFuture = _connect(options);
      }
      transportState = await _initFuture;
      if (_forceClosed) {
        transportState.dispose();
      } else {
        _transportsMap[domain] = transportState;
        var _ = _connectFutures.remove(domain);
      }
    } else {
      // Check whether the connection is terminated, if it is, reconnecting.
      if (!transportState.transport.isOpen) {
        transportState.dispose();
        _transportsMap[domain] = transportState = await _connect(options);
      }
    }
    return transportState.activeTransport;
  }

  Future<_ClientTransportConnectionState> _connect(
      RequestOptions options) async {
    var uri = options.uri;
    var domain = '${uri.host}:${uri.port}';
    var clientConfig = ClientSetting();
    if (onClientCreate != null) {
      onClientCreate!(uri, clientConfig);
    }
    late final SecureSocket socket;
    try {
      // Create socket
      socket = clientConfig.proxy == null
          ? await _createSocket(uri, options, clientConfig)
          : await _createSocketWithProxy(uri, options, clientConfig);
    } on SocketException catch (e) {
      if (e.osError == null) {
        if (e.message.contains('timed out')) {
          throw DioError(
            requestOptions: options,
            error: 'Connecting proxy timed out [${options.connectTimeout}ms]',
            type: DioErrorType.connectTimeout,
          );
        }
      }
      rethrow;
    }
    // Config a ClientTransportConnection and save it
    var transport = ClientTransportConnection.viaSocket(socket);
    var _transportState = _ClientTransportConnectionState(transport);
    transport.onActiveStateChanged = (bool isActive) {
      _transportState.isActive = isActive;
      if (!isActive) {
        _transportState.latestIdleTimeStamp =
            DateTime
                .now()
                .millisecondsSinceEpoch;
      }
    };
    //
    _transportState.delayClose(
      _closed ? 50 : _idleTimeout,
          () {
        _transportsMap.remove(domain);
        _transportState.transport.finish();
      },
    );
    return _transportState;
  }


  Future<SecureSocket> _createSocket(Uri target,
      RequestOptions options,
      ClientSetting clientConfig,) =>
      SecureSocket.connect(
        target.host,
        target.port,
        timeout: options.connectTimeout > 0
            ? Duration(milliseconds: options.connectTimeout)
            : null,
        context: clientConfig.context,
        onBadCertificate: clientConfig.onBadCertificate,
        supportedProtocols: ['h2'],
      );

  Future<SecureSocket> _createSocketWithProxy(
      Uri target,
      RequestOptions options,
      ClientSetting clientConfig,
      ) async {
    final proxySocket = await Socket.connect(
      clientConfig.proxy!.host,
      clientConfig.proxy!.port,
      timeout: options.connectTimeout > 0
          ? Duration(milliseconds: options.connectTimeout)
          : null,
    );

    final String credentialsProxy =
    base64Encode(utf8.encode(clientConfig.proxy!.userInfo));

    //Send proxy headers
    const crlf = '\r\n';

    proxySocket.write('CONNECT ${target.host}:${target.port} HTTP/1.1');
    proxySocket.write(crlf);
    proxySocket.write('Host: ${target.host}:${target.port}');

    if (credentialsProxy.isNotEmpty) {
      proxySocket.write(crlf);
      proxySocket.write('Proxy-Authorization: Basic $credentialsProxy');
    }

    proxySocket.write(crlf);
    proxySocket.write(crlf);

    final completerProxyInitialization = Completer<void>();

    completerProxyInitialization.future.onError((error, stackTrace) => {
      throw DioError(
        requestOptions: options,
        error: error,
        type: DioErrorType.other,
      )
    });

    final proxySubscription = proxySocket.listen(
          (event) {
        final response = ascii.decode(event);
        final lines = response.split(crlf);
        final statusLine = lines.first;

        if (statusLine.startsWith('HTTP/1.1 200')) {
          completerProxyInitialization.complete();
        } else {
          completerProxyInitialization.completeError(
            SocketException('Proxy cannot be initialized'),
          );
        }
      },
      onError: completerProxyInitialization.completeError,
    );

    await completerProxyInitialization.future;

    final socket = await SecureSocket.secure(
      proxySocket,
      host: target.host,
      context: clientConfig.context,
      onBadCertificate: clientConfig.onBadCertificate,
      supportedProtocols: ['h2'],
    );

    proxySubscription.cancel();

    return socket;
  }

  @override
  void removeConnection(ClientTransportConnection transport) {
    _ClientTransportConnectionState? _transportState;
    _transportsMap.removeWhere((_, state) {
      if (state.transport == transport) {
        _transportState = state;
        return true;
      }
      return false;
    });
    _transportState?.dispose();
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _forceClosed = force;
    if (force) {
      _transportsMap.forEach((key, value) => value.dispose());
    }
  }
}

class _ClientTransportConnectionState {
  _ClientTransportConnectionState(this.transport);

  ClientTransportConnection transport;

  ClientTransportConnection get activeTransport {
    isActive = true;
    latestIdleTimeStamp = DateTime
        .now()
        .millisecondsSinceEpoch;
    return transport;
  }

  bool isActive = true;
  late int latestIdleTimeStamp;
  Timer? _timer;

  void delayClose(int idleTimeout, void Function() callback) {
    idleTimeout = idleTimeout < 100 ? 100 : idleTimeout;
    _startTimer(callback, idleTimeout, idleTimeout);
  }

  void dispose() {
    _timer?.cancel();
    transport.finish();
  }

  void _startTimer(void Function() callback, int duration, int idleTimeout) {
    _timer = Timer(Duration(milliseconds: duration), () {
      if (!isActive) {
        var interval =
            DateTime
                .now()
                .millisecondsSinceEpoch - latestIdleTimeStamp;
        if (interval >= duration) {
          return callback();
        }
        return _startTimer(callback, duration - interval, idleTimeout);
      }
      // if active
      _startTimer(callback, idleTimeout, idleTimeout);
    });
  }
}
