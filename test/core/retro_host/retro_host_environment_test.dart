import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:test/test.dart';

void main() {
  test('on Windows an added variable replaces one whose name differs only in case', () {
    expect(
      retroHostEnvironment({'PATH': r'C:\old', 'TEMP': r'C:\t'}, {'Path': r'C:\new'}, windows: true),
      unorderedEquals([r'TEMP=C:\t', r'Path=C:\new']),
    );
  });

  test('on Windows the last of two added names that differ only in case is kept', () {
    expect(retroHostEnvironment({'PATH': r'C:\old'}, {'PATH': r'C:\first', 'Path': r'C:\second'}, windows: true), [
      r'Path=C:\second',
    ]);
  });

  test('on Windows the entries are sorted by name without regard to case', () {
    expect(
      retroHostEnvironment({'PATH': r'C:\p', 'TEMP': r'C:	'}, {'aaa': '1', 'Zed': '2', 'Path': r'C:\q'}, windows: true),
      ['aaa=1', r'Path=C:\q', r'TEMP=C:	', 'Zed=2'],
    );
  });

  test('elsewhere names that differ in case are different variables', () {
    expect(
      retroHostEnvironment({'PATH': '/old'}, {'Path': '/new'}, windows: false),
      unorderedEquals(['PATH=/old', 'Path=/new']),
    );
  });

  test('an added variable replaces one of the same name', () {
    expect(retroHostEnvironment({'A': '1', 'B': '2'}, {'A': '3'}, windows: false), unorderedEquals(['A=3', 'B=2']));
  });
}
