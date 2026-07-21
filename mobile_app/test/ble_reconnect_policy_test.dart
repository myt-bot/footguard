import 'package:flutter_test/flutter_test.dart';
import 'package:footguard/services/ble_reconnect_policy.dart';

void main() {
  test('uses capped exponential delays between reconnect attempts', () {
    const policy = BleReconnectPolicy();

    expect(policy.delayForAttempt(1), const Duration(seconds: 2));
    expect(policy.delayForAttempt(2), const Duration(seconds: 4));
    expect(policy.delayForAttempt(3), const Duration(seconds: 8));
    expect(policy.delayForAttempt(4), const Duration(seconds: 16));
    expect(policy.delayForAttempt(5), const Duration(seconds: 30));
    expect(policy.delayForAttempt(20), const Duration(seconds: 30));
  });
}
