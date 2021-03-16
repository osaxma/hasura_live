import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:hasura_simple/src/util.dart';
import 'package:hasura_simple/src/request.dart';

import 'message.dart';

// The default web socket protocl WebSocketChannel.connect
const _websocketProtocol = 'graphql-ws';

// TODO: general
// - Reconnect:
//   Implement the reconnect process properly. This will require closing the subscription of jwtStream
//   and re-subsribing. That means if the user choose `reconnect: true` once provided, they jwtStream
//   needs to be a broadcast stream since we will need to subscribe to it multiple times.
//
// - Timeout:
//   Implement the timeout properly.
//
//
// - Handling error:
//   Handle error properly and redirect errors to proper subscriptions.
//
// - Clean up:
//   There's some reptitive code and invalid comments left out from the experimentation phase. Also, this
//   includes spell-check and grammar check for comments :/

class HasuraSimpleWS {
  /// The websocket endpoint
  final String wsURL;

  /// The number of retry attempts for connecting to the websocket endpoint
  ///
  /// this number will be used for both the initial connection and when reconnecting (e.g., refershing the jwt token)
  final int retryAttempts;

  /// The connection headers
  ///
  /// These headers are only used during handshake (ie when the connection is initialized).
  /// if `jwtTokenProvider` is given, the headers will be used when reconnecting with the new token.
  final Map<String, dynamic>? headers;

  /// Requests timeout in seconds
  ///
  /// default value is 5 seconds
  final Duration requestsTimeout;

  /// JWT changes notifier
  ///
  /// A stream that emits events whenever the JWT needs to be updated. The events emitted by the stream can be of any
  /// type since they'll not be read, but they will be use as an indicator to refresh the websocket. Whenever an event
  /// is received by the stream, `jwtTokenProvider` is called to retrieve the new jwt token.
  ///
  /// The stream is only useful when the token expires during the lifetime of the connection.
  final Stream<String>? jwtStream;
  late final StreamSubscription<Object?>? _jwtTokenProviderSubscription;

  late final _HasuraConnection _hasuraConnection = _HasuraConnection(wsURL);

  // a map that keeps track of active subscriptions where the key is the request.key.
  // the map is mainly used to recreate subscription when restablishing the websocket connection.
  final _activeSubscriptions = <String, GQLRequest>{};

  HasuraSimpleWS({
    required this.wsURL,
    this.jwtStream,
    this.headers,
    this.retryAttempts = 3,
    this.requestsTimeout = const Duration(seconds: 5),
  }) {
    if (jwtStream != null) {
      _jwtTokenProviderSubscription = jwtStream!.distinct().listen((jwtToken) {
        logger.info('jwt event received');
        _connect(jwtToken);
      });
    } else {
      // connect with the provided headers only
      _connect();
    }
  }

  bool _isConnected = false;
  // consolidate the two below and check `_reconnecting.isComplete` instead of _isReconnecting
  bool _isReconnecting = false;
  Completer<bool> _reconnecting = Completer<bool>()..complete(true);

  void _connect([String? jwtToken]) async {
    if (!_isConnected) {
      try {
        final initMessage = _buildInitMessage(headers, jwtToken);
        await _hasuraConnection.start(initMessage: initMessage);
        _isConnected = true;
      } catch (e) {
        // await close();
        print('error when connecting $e');
      }
    } else {
      _refreshConnection(jwtToken);
    }
  }

  void _refreshConnection(String? jwtToken) async {
    _isReconnecting = true;
    _reconnecting = Completer<bool>();
    try {
      final initMessage = _buildInitMessage(headers, jwtToken);
      await _hasuraConnection.restart(
        initMessage: initMessage,
        stopMessage: const Message(type: MessageTypes.connectionTerminate),
      );
      _activeSubscriptions.values.forEach((element) {
        _sendMessage(element.toStartMessage());
      });
      _reconnecting.complete(true);
    } catch (e, s) {
      _reconnecting.completeError(false);
      _hasuraConnection.addError(e, s);
    } finally {
      _isReconnecting = false;
    }
  }

  Future<void> _sendMessage(Message message) async {
    if (_isReconnecting) {
      await _reconnecting.future;
    }
    await _hasuraConnection.sendMessage(message);
  }

  /// Execute mutations or query requests.
  Future<Message> execute(GQLRequest request) async {
    await _sendMessage(request.toStartMessage());

    final res = await _hasuraConnection.rootStream.firstWhere((element) {
      return element.id == request.key;
    }).timeout(requestsTimeout);

    if (res.type == MessageTypes.error) {
      return Future.error(res);
    } else {
      return res;
    }
  }

  /// Subscribe to live queries.
  Stream<Message> subscription(GQLRequest request) {
    return _StreamWrapper(
      request: request,
      rootStream: _hasuraConnection.rootStream,
      onListen: _startSubscription,
      onCancel: _stopSubscription,
    ).stream;
  }

  Future<void> _startSubscription(GQLRequest request) async {
    await _sendMessage(request.toStartMessage());
    _activeSubscriptions[request.key] = request;
  }

  Future<void> _stopSubscription(GQLRequest request) async {
    _activeSubscriptions.remove(request.key);
    await _sendMessage(request.toStopMessage());
  }

  Message _buildInitMessage([Map<String, dynamic>? headers, String? jwtToken]) {
    return Message(
      payload: {
        'headers': {
          if (headers != null) ...headers,
          if (jwtToken != null) 'Authorization': 'Bearer $jwtToken',
        }
      },
      type: MessageTypes.connectionInit,
    );
  }

  Future<void> close() async {
    await _jwtTokenProviderSubscription?.cancel();
    await _hasuraConnection.close();
  }
}

/// handles connection related communication
class _HasuraConnection {
  final String url;

  WebSocketChannel? _webSocketClient;

  final _hasuraStreamController = StreamController<Message>.broadcast();

  StreamSubscription? _streamSubscription;

  // rootStream stays alive the entire lifecycle of the object. It'll listen to all the events
  // from the websocket connection. The websocket connection is disconnected and reconnected
  // everytime the auth state changes (once an hour for firebase). Hence the two are separate.
  // All the client streams are a filtered-rootStream.
  Stream<Message> get rootStream => _hasuraStreamController.stream;

  // consolidate the two below and check `__connectionAcknowledgedCompleter.isComplete` instead of _connectionAcknowledged
  bool _connectionAcknowledged = false;
  Completer<bool> __connectionAcknowledgedCompleter = Completer<bool>();

  _HasuraConnection(this.url);

  Future<void> sendMessage(Message message) async {
    if (!_connectionAcknowledged && message.type != MessageTypes.connectionInit) {
      // TODO: provide timeout here?
      logger.info('waiting for connection acknowledgement');
      await __connectionAcknowledgedCompleter.future.timeout(const Duration(seconds: 10));
    }
    _webSocketClient?.sink.add(message.toJson());
  }

  void addError(Object error, [StackTrace? stackTrace]) => _hasuraStreamController.addError(error, stackTrace);

  Future<WebSocketChannel> _connect() async {
    logger.info('connecting ...');
    final channel = WebSocketChannel.connect(
      Uri.parse(url),
      protocols: [_websocketProtocol],
    );

    return Future<WebSocketChannel>.value(channel);
  }

  Future<WebSocketChannel> _connectWithRetry([int retryAttempts = 0]) async {
    return await retry<WebSocketChannel>(retryAttempts, _connect);
  }

  Future<void> start({Message? initMessage}) async {
    try {
      _webSocketClient = await _connectWithRetry();
      _subscribe();
    } catch (e, s) {
      __connectionAcknowledgedCompleter.completeError(e, s);
      addError(e, s);
      rethrow;
    }
    if (initMessage != null) {
      await sendMessage(initMessage).catchError(addError);
    }
  }

  Future<void> restart({Message? stopMessage, Message? initMessage}) async {
    logger.info('restarting connection started');
    _connectionAcknowledged = false;
    __connectionAcknowledgedCompleter = Completer<bool>();
    // for some reason awaiting for _streamSubscription?.cancel() takes few seconds
    // tho this will cancel the _streamSubscription
    // if (stopMessage != null) {
    //   sendMessage(stopMessage);
    // }
    await _webSocketClient?.sink.close();
    logger.info('websocket connection closed');
    _webSocketClient = await _connectWithRetry();
    logger.info('websocket connection restarted');
    _subscribe();
    if (initMessage != null) {
      await sendMessage(initMessage);
    }
  }

  void _subscribe() async {
    _streamSubscription = _webSocketClient?.stream.listen(null);

    _streamSubscription?.onData((data) {
      // TODO maybe close the connection and reconnect once there are listeners?
      // if (!_hasuraStreamController.hasListener) {
      //   return;
      // }
      try {
        final message = Message.fromJson(data);

        if (message.type == MessageTypes.connectionError) {
          _hasuraStreamController.addError(message);
          if (!_connectionAcknowledged) {
            __connectionAcknowledgedCompleter.complete(false);
          }
        } else if (message.type == MessageTypes.connectionAck) {
          _connectionAcknowledged = true;
          __connectionAcknowledgedCompleter.complete(true);
        } else if (message.type == MessageTypes.connectionKeepAlive) {
          return;
        } else {
          _hasuraStreamController.add(message);
        }
      } catch (e, s) {
        // todo log properly
        print('failed to add messages:\n$data  \nerror: \n$e \nstacktrace: \n$s');
      }
    });

    _streamSubscription?.onDone(() {
      // reconnect? .. maybe check if(!streamController.isClosed) {reconnect();}
      // since an open stream controller indicates the connection wasn't closed by the user
      // another option is to check `_webSocketClient.closeReason`, if it was `conneciton_terminate` then
      // don't reconnect.
    });

    _streamSubscription?.onError((error, stackTrace) {
      _hasuraStreamController.addError(error, stackTrace);
    });
  }

  Future<void> close() async {
    await _hasuraStreamController.close();
    // this will cancel the _streamSubscription
    await _webSocketClient?.sink.close();
  }
}

typedef _OnSubscriptionAction = Future<void> Function(GQLRequest request);

// the main reason this wrapper is created is to provide a way to invoke the _whenCancel callback.
// The wrapper includes a controller, that subscribes to the rootStream, and provie the way to invoke the call back.
// The _whenCancel callback is used to notify HasuraWebsocket to remove the snapshot from its active subscription map.
// If we pass the stream directly, the there is no way to know when the stream is no longer being consumed.
class _StreamWrapper {
  final GQLRequest request;
  final _OnSubscriptionAction _whenCancel;
  final _OnSubscriptionAction _whenListen;
  late final Stream<Message> _rootStream;

  late final _controller = StreamController<Message>(onCancel: _onCancel, onListen: _onListen);
  late final StreamSubscription<Message> subscription = _rootStream.listen(null); //, cancelOnError: true);

  _StreamWrapper({
    required this.request,
    required Stream<Message> rootStream,
    required _OnSubscriptionAction onListen,
    required _OnSubscriptionAction onCancel,
  })   : _whenListen = onListen,
        _whenCancel = onCancel {
    _rootStream = rootStream.where((event) => event.id == request.key);
  }

  Stream<Message> get stream => _controller.stream;

  void _onCancel() async {
    // TODO: handle the error properly. The issue arise when `_whenCancel` is called and the rootStream
    //       or the websocket connection is already closed.
    try {
      await subscription.cancel();
      await _whenCancel(request);
    } catch (e) {
      print('error when cancelling stream wrapper: $e');
    }
  }

  void _onListen() {
    subscription.onData(
      (message) {
        if (message.type == MessageTypes.error) {
          _controller.addError(message);
        } else if (message.type == MessageTypes.complete) {
          _controller.close();
        } else /* all other types */ {
          _controller.add(message);
        }
      },
    );

    subscription.onError(_controller.addError);
    subscription.onDone(() {
      _controller.close();
    });

    _whenListen(request).catchError((error, stackTrace) => _controller.addError(error, stackTrace));
  }

  void close() => _controller.close();
}
