import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/models/widget_size_bounds.dart';

void main() {
  group('universalBounds', () {
    const landscape = (columns: 6, rows: 4);
    const portrait = (columns: 4, rows: 6);

    test('landscape (6x4) needs no clamping — the base 6x4 max already fits', () {
      final bounds = universalBounds(landscape);
      expect(bounds.minWidth, 2);
      expect(bounds.minHeight, 2);
      expect(bounds.maxWidth, 6);
      expect(bounds.maxHeight, 4);
    });

    test('portrait (4x6) clamps max width down to the grid\'s own 4 columns', () {
      final bounds = universalBounds(portrait);
      expect(bounds.minWidth, 2);
      expect(bounds.minHeight, 2);
      expect(bounds.maxWidth, 4);
      // Height's base max (4) is already <= the grid's 6 rows: unclamped.
      expect(bounds.maxHeight, 4);
    });
  });
}
