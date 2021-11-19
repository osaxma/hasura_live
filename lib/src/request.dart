import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hasura_live/src/message.dart';

/// Defines a GraphQL request.
///
/// A request can be one of the following operations:
/// - Query
/// - Mutation
/// - Subscription
class GQLRequest {
  /// The GraphQL operation of this request in a string format.
  final String operation;

  /// Include any variables related to the operation if required
  final Map<String, dynamic> variables;

  /// A unique key to identify this request and its subsequent message(s)
  /// if no key is provided, an MD5 hash of the operation and variables
  /// will be used as a key.
  final String key;

  GQLRequest({
    required this.operation,
    Map<String, dynamic>? variables,
    String? key,
  })  : key = (key != null) ? key : _gnerateKey(operation + (variables?.toString() ?? '')),
        variables = (variables != null) ? (variables..removeWhere((key, value) => value == null)) : const {};

  Message toStartMessage() => Message(
        id: key,
        payload: {
          'query': operation,
          'variables': variables,
        },
        type: MessageTypes.start,
      );

  Message toStopMessage() => Message(
        id: key,
        type: MessageTypes.stop,
      );
}

/// Generate an MD5 hash of the [input] string.
String _gnerateKey(String input) {
  return md5.convert(utf8.encode(input)).toString();
}