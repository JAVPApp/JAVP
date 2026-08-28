import 'package:flutter_test/flutter_test.dart';
import 'package:javp/services/catalog/catalog_play_headers.dart';

void main() {
  test('userAgent aliases become canonical User-Agent', () {
    expect(
      catalogPlaybackHeadersFromJson({'ua': 'Bridge/1'}),
      {'User-Agent': 'Bridge/1'},
    );
    expect(
      catalogPlaybackHeadersFromJson({'user-agent': 'Bridge/2'}),
      {'User-Agent': 'Bridge/2'},
    );
    expect(
      catalogPlaybackHeadersFromJson({
        'httpHeaders': {'user-agent': 'from-map', 'Referer': 'https://x/'},
        'userAgent': 'from-field',
      }),
      {'User-Agent': 'from-field', 'Referer': 'https://x/'},
    );
  });

  test('inherit then overlay; User-Agent is case-canonical', () {
    final merged = catalogPlaybackHeadersFromJson(
      {
        'headers': {'X-Token': 'b', 'User-Agent': 'item'},
      },
      inherit: {'Referer': 'https://root/', 'User-Agent': 'root'},
    );
    expect(merged['Referer'], 'https://root/');
    expect(merged['X-Token'], 'b');
    expect(merged['User-Agent'], 'item');
    expect(merged.keys.where((k) => k.toLowerCase() == 'user-agent'), hasLength(1));
  });

  test('userAgentFromHttpHeaders is case-insensitive', () {
    expect(userAgentFromHttpHeaders({'user-agent': 'x'}), 'x');
    expect(userAgentFromHttpHeaders({'User-Agent': 'y'}), 'y');
    expect(userAgentFromHttpHeaders({'Accept': '*/*'}), isNull);
  });
}
