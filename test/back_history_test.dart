import 'package:moyi/back_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('push and pop restore order', () {
    final history = BackHistory<String>();
    expect(history.isEmpty, isTrue);
    history.push('a');
    history.push('b');
    expect(history.length, 2);
    expect(history.pop(), 'b');
    expect(history.pop(), 'a');
    expect(history.pop(), isNull);
    expect(history.isEmpty, isTrue);
  });

  test('consecutive duplicates are skipped', () {
    final history = BackHistory<String>();
    history.push('a');
    history.push('a');
    expect(history.length, 1);
  });

  test('oldest entries drop past the limit', () {
    final history = BackHistory<int>(limit: 3);
    history.push(1);
    history.push(2);
    history.push(3);
    history.push(4);
    expect(history.length, 3);
    expect(history.pop(), 4);
    expect(history.pop(), 3);
    expect(history.pop(), 2);
  });

  test('clear empties the history', () {
    final history = BackHistory<String>();
    history.push('a');
    history.clear();
    expect(history.isEmpty, isTrue);
  });
}
