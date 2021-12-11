# Hasura Live Package
A library for connecting to Hasura through websocket only.

In addition to subscriptions (aka live queries), mutations and queries can also be performed through the websocket connection. 

**Important note: the package is still in early development so use it with caution.**

# Motivation
This package is meant to solve the problem of replacing an expired JWT (JSON Web Token) with a new one without closing any live subscriptions. Firebase Authentication service is the main use case for creating this package but the concept should work with other services as long as a stream of JWT can be provided. 

## Issue: 
Using Firebase Authenticationas as an example of a JWT provider, the issue can be summarized as follow:
- The JWT from Firebase Authentication expires every hour. 
- The JWT is provided to Hasura upon establishing the websocket connection.
- Once the connection is established, there is no way to update the JWT after it expires<sup>1</sup>.
- When the JWT expires after an hour, Hasura won't automatically send a connection error and the websocket connection will stay alive<sup>2</sup>.


The obvious solution here is to re-establish the websocket connection with a new JWT token after the previous one expires. However, This brings another problem which is keeping the application's active subscriptions alive during the restart of the websocket connection. 

This package aims to solve the aforementioned issue.  

<sup>1</sup> _Hasura uses [Apollo Subscriptions Transport Protocol for Websocket](https://github.com/apollographql/subscriptions-transport-ws/blob/master/PROTOCOL.md) which does not define a way to update the JWT token of an active connection._ 

<sup>2</sup> _Note that Hasura will send an error to any new request after the JWT expires but any live subscriptions won't receive any error nor will they receive any events._


# Usage
Since the package is not yet published on pub.dev, you can use it by adding the following to your `pubspec.yaml`:

```yaml
dependencies:
  hasura_live:
    git: 
      url: git://github.com/osaxma/hasura_live.git
      ref: main
```

To facilitate the communication, the package uses [`GQLRequest`](lib/src/request.dart) to define requests to the server, and [`Message`](lib/src/message.dart) to carry data and errors between the client and the server. 

* To create a client
```dart
final client = HasuraLive(
          wsURL: url, // the websocket endpoint
          jwtStream: jwtStream, // a stream of JWT token
        );
```
* To send a query:
```dart
  final Message response = await client.execute(
    GQLRequest(
      operation: '''
        query {
            users {
            display_name
            }
        }
      ''',
    ),
  );

  final data = res.payload;
```
* To send a mutation with variables: 
```dart
  final Message response = await client.execute(
    GQLRequest(
      operation: r''' 
        mutation updateUserDisplayName($uid: String!, $display_name: String!) {
          update_users_by_pk(pk_columns: {uid: $uid}, _set: {display_name: $display_name}) {
            display_name
          }
        }
      ''',
      variables: {
        'uid': '42',
        'name': 'Chuck Norris',
      },
    ),
  );

  final data = res.payload;
```
* To subscribe to live query:

```dart
  final Stream<Message> notificationStream = client.subscription(
    GQLRequest(
      key: 'notifications',
      operation: ''' 
        subscription NotificationSub {
          notifications(order_by: {created_at: asc}, limit: 10) {
            notification_id
            notifier_uid
            notification_details
            is_read
          }
        }
      ''',
    ),
  );

  final notificationSub = notificationStream.listen((event) { /* code to handle events */ });
```

# Use Cases

## Creating JWT stream with Firebase Authentication
Firebase Authentication package does not automatically refresh the JWT after its expiration (see discussion [here](https://github.com/FirebaseExtended/flutterfire/issues/7363#event-5617741381)). Taking the following two streams as an example:

```dart
FirebaseAuth.instance.idTokenChanges().listen((event) { 
    /* code handling events */
}
```
OR

```dart
FirebaseAuth.instance.userChanges().listen((event) {  
    /* code handling events */
}
```
Unless another Firebase package (e.g. firestore) is refreshing the token or if the token is being refreshed manually, both streams above will **not** fire events after the JWT expires . 

To work around this issue, the application has to manually refresh the JWT before it expires. The following is a simplified example code for an Authentication class that provides a stream of JWT where the JWT is refreshed before it expires:

```dart
class Authentication {
  // a timer that refreshes the jwt token before it expires.
  Timer _jwtRefreshTimer;

  Authentication() {
    // listen to sign in and sign out event throughout the lifetime of this object
    FirebaseAuth.instance.authStateChanges().distinct().listen((user) {
      if (user == null) {
        _jwtRefreshTimer?.cancel();
      } else {
        _setTimerToRefreshJWT();
      }
    });
  }

  void _setTimerToRefreshJWT() async {
    if (_jwtRefreshTimer != null && _jwtRefreshTimer.isActive) {
      if (FirebaseAuth.instance.currentUser == null) {
        _jwtRefreshTimer.cancel();
      }
      return;
    }

    final idTokenResult = await FirebaseAuth.instance.currentUser.getIdTokenResult();
    final durationToExpiration = idTokenResult.expirationTime.toUtc().difference(DateTime.now().toUtc());

    // refresh the token 2 minutes before it expires
    _jwtRefreshTimer = Timer(durationToExpiration - const Duration(minutes: 2), () async {
      // force a token refresh. 
      // This will cause jwtStream to fire a new event with a new JWT
      await FirebaseAuth.instance.currentUser.getIdToken(true);
      // reset the timer
      _setTimerToRefreshJWT();
    });
  }

  // a stream of JWT 
  Stream<String> jwtStream() {
    // distinct stream because idTokenChanges sometimes fire twice in a row,
    // and prevent a null user since it's possible upon signing out.
    return FirebaseAuth.instance
        .idTokenChanges()
        .where((user) => user != null)
        .asyncMap((_) => FirebaseAuth.instance.currentUser.getIdToken())
        .distinct();
  }
}
```
