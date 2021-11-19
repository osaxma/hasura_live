import 'dart:convert';

import 'package:collection/collection.dart';

/// Representation of a Message for the client-server communication
///
/// for more info, see: [Apollo Subscriptions Transport Protocol for Websocket](https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md)
class Message {
  /// A key to identify each response from the server.
  ///
  /// The id must be unique for each subscription.
  final String? id;

  /// The Message Type as defined in [MessageTypes]
  ///
  /// the type can be used to identify the server response (e.g., error or data),
  /// and also used to send requests to the server.
  final MessageTypes? type;

  /// Client or Server payload
  ///
  /// The payload can be a string, map, or null. In case of [MessageTypes.data],
  /// it'll contain a `Map<String, dynamic>` of the data where the key is 'data'.
  /// In the case of [MessageTypes.error], it'll contain an error either as a string
  /// or as a Map<String, dynamic> where the key is 'errors' or 'extentions' (hasura specific).
  final Object? payload;

  const Message({
    this.id,
    this.type,
    this.payload,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type?.toMap(),
      'payload': payload,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    print('map = $map \n\n');

    final messageType = MessageTypes.fromMap(map['type']);

    // keep alive message has no id nor payload, and it's being called every 5 seconds
    // so we just return a const object.
    if (messageType == MessageTypes.connectionKeepAlive) {
      return const Message(type: MessageTypes.connectionKeepAlive);
    }
    // the payload can be:
    // - a map with data, errors, or extentions errors
    // - a string -- when there's a connection error
    //   e.g. {type: connection_error, payload: parsing ClientMessage failed: Error in $: key "type" not found}
    //        {type: connection_error, connectionError: invalid x-hasura-admin-secret/x-hasura-access-key}
    // - null -- when there's no payload such in keepAlive message
    // the user of the message can know there's an error based on the messageType (see MessagesTypes)
    return Message(
      id: map['id'],
      type: messageType,
      payload: map['payload'],
    );
  }

  String toJson() => json.encode(toMap());

  bool get hasError => type == MessageTypes.error || type == MessageTypes.connectionError;

  factory Message.fromJson(String source) => Message.fromMap(json.decode(source));

  @override
  String toString() => 'Message(id: $id, type: $type, payload: $payload)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    // mapEquals will work on any type since it has a fallback for DefaultEquality (see constructor).
    final mapEquals = const DeepCollectionEquality().equals;

    return other is Message && other.id == id && other.type == type && mapEquals(payload, other.payload);
  }

  @override
  int get hashCode => id.hashCode ^ type.hashCode ^ payload.hashCode;
}

/// An enum like class represneting the message types and their code value as a string
///
/// Message types in accordance to `Apollo Subscriptions Transport Protocol for Websocket`, which is used by Hasura.
///
/// For more information, visit:
///
/// [Protocol Document](https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md)
///
/// [Message Types](https://github.com/apollographql/subscriptions-transport-ws/blob/master/src/message-types.ts)
class MessageTypes {
  final String code;

  const MessageTypes._internal(this.code);

  static const connectionInit = MessageTypes._internal('connection_init'); // Client -> Server
  static const connectionAck = MessageTypes._internal('connection_ack'); // Server -> Client
  static const connectionError = MessageTypes._internal('connection_error'); // Server -> Client

  // NOTE: The keep alive message type does not follow the standard due to connection optimizations
  static const connectionKeepAlive = MessageTypes._internal('ka'); // Server -> Client

  static const connectionTerminate = MessageTypes._internal('connection_terminate'); // Client -> Server

  static const start = MessageTypes._internal('start'); // Client -> Server
  static const data = MessageTypes._internal('data'); // Server -> Client
  static const error = MessageTypes._internal('error'); // Server -> Client
  static const complete = MessageTypes._internal('complete'); // Server -> Client
  static const stop = MessageTypes._internal('stop'); // Client -> Server

  static List<MessageTypes> get values => const [
        connectionInit,
        connectionAck,
        connectionError,
        connectionKeepAlive,
        connectionTerminate,
        start,
        data,
        error,
        complete,
        stop,
      ];

  @override
  String toString() => code;

  // for serilization.
  String toMap() => toString();

  // for deserilization.
  static MessageTypes? fromMap(String string) {
    for (var val in values) {
      if (val.code == string) {
        return val;
      }
    }
    return null;
  }
}
