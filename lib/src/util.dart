// keep here to avoid exporting to the users namespace 
// since it's not possible to make it private (used in two files). 
import 'package:logging/logging.dart';


/// to listen to the logger:
/// ```dart
/// Logger.root.level = Level.ALL; 
/// Logger.root.onRecord.listen((record) {
///   // remove microseconds
///   final timeString = record.time.toString().split('.')[0];
///   print('${record.level.name}: $timeString: ${record.message}');
/// });
/// ```
final logger = Logger('hasura_live.dart');

// a handy method for retrying a future
Future<T> retry<T>(
  int retries,
  Future<T> Function() aFuture, {
  Duration delay = Duration.zero,
}) async {
  try {
    return await aFuture();
  } catch (e) {
    if (retries > 1) {
      await Future.delayed(delay);
      return retry(retries - 1, aFuture, delay: delay);
    }
    rethrow;
  }
}