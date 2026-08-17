import 'package:flutter_test/flutter_test.dart';
import 'package:synapse_auto/screens/hud/hud_screen.dart';

void main() {
  group('headingCompassAbbreviation', () {
    test('a null heading reads as "--", never a guessed direction', () {
      expect(headingCompassAbbreviation(null), '--');
    });

    test('cardinal directions map exactly', () {
      expect(headingCompassAbbreviation(0), 'N');
      expect(headingCompassAbbreviation(90), 'E');
      expect(headingCompassAbbreviation(180), 'S');
      expect(headingCompassAbbreviation(270), 'W');
    });

    test('intercardinal directions map exactly', () {
      expect(headingCompassAbbreviation(45), 'NE');
      expect(headingCompassAbbreviation(135), 'SE');
      expect(headingCompassAbbreviation(225), 'SW');
      expect(headingCompassAbbreviation(315), 'NW');
    });

    test('a heading just past 360 wraps back to N (circular, not out of range)', () {
      expect(headingCompassAbbreviation(359), 'N');
      expect(headingCompassAbbreviation(361), 'N');
    });

    test('a heading well inside a sector reads that sector, not a neighbor', () {
      expect(headingCompassAbbreviation(10), 'N');
      expect(headingCompassAbbreviation(80), 'E');
    });
  });
}
