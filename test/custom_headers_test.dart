import 'package:moyi/custom_headers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rules = [
    CustomHeaderRule(host: 'example.com', name: 'Referer', value: 'https://example.com/'),
    CustomHeaderRule(host: '*.cdn.example.com', name: 'User-Agent', value: 'TestUA/1'),
    CustomHeaderRule(host: 'other.com/videos', name: 'X-Test', value: '1'),
  ];

  test('exact host and subdomain match', () {
    expect(
      CustomHeaderRule(host: 'example.com', name: 'A', value: '1')
          .matches('https://example.com/v.m3u8'),
      isTrue,
    );
    expect(
      CustomHeaderRule(host: 'example.com', name: 'A', value: '1')
          .matches('https://sub.example.com/v.m3u8'),
      isTrue,
    );
    expect(
      CustomHeaderRule(host: 'example.com', name: 'A', value: '1')
          .matches('https://notexample.com/v.m3u8'),
      isFalse,
    );
    expect(
      CustomHeaderRule(host: 'example.com', name: 'A', value: '1')
          .matches('https://example.com.evil.com/v.m3u8'),
      isFalse,
    );
  });

  test('wildcard and path match', () {
    expect(
      CustomHeaderRule(host: '*.cdn.example.com', name: 'A', value: '1')
          .matches('https://a.cdn.example.com/x.ts'),
      isTrue,
    );
    expect(
      CustomHeaderRule(host: '*.cdn.example.com', name: 'A', value: '1')
          .matches('https://cdn.example.com/x.ts'),
      isFalse,
    );
    expect(
      CustomHeaderRule(host: 'other.com/videos', name: 'A', value: '1')
          .matches('https://other.com/videos/a.m3u8'),
      isTrue,
    );
    expect(
      CustomHeaderRule(host: 'other.com/videos', name: 'A', value: '1')
          .matches('https://other.com/other/a.m3u8'),
      isFalse,
    );
  });

  test('apply merges only matching rules and never overwrites site headers', () {
    final merged = applyCustomHeaders(
      'https://sub.example.com/v.m3u8',
      {'User-Agent': 'SiteUA'},
      enabled: true,
      rules: rules,
    );
    expect(merged['Referer'], 'https://example.com/');
    expect(merged['User-Agent'], 'SiteUA');
    expect(merged.containsKey('X-Test'), isFalse);
  });

  test('disabled switch leaves headers untouched', () {
    final base = {'User-Agent': 'SiteUA'};
    final merged = applyCustomHeaders(
      'https://example.com/v.m3u8',
      base,
      enabled: false,
      rules: rules,
    );
    expect(merged, base);
  });

  test('parse rules ignores bad entries', () {
    final parsed = parseCustomHeaderRules(
      '[{"host":"example.com","name":"Referer","value":"https://example.com/"},{"host":"","name":"X","value":"1"},42]',
    );
    expect(parsed.length, 1);
    expect(parsed.first.host, 'example.com');
    expect(parseCustomHeaderRules('not json'), isEmpty);
    expect(parseCustomHeaderRules(''), isEmpty);
  });
}
