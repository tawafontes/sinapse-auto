/// The 2 selectable typography options. Persisted as a plain id string in
/// [ThemeConfig.fontFamily] rather than an enum, so new options can be added
/// without a Hive migration.
class FontFamilyOption {
  FontFamilyOption._();

  static const mono = 'mono';
  static const humanist = 'humanist';
}

const String defaultFontFamilyId = FontFamilyOption.humanist;

const Map<String, String> fontFamilyLabels = {
  FontFamilyOption.mono: 'Monoespaçada',
  FontFamilyOption.humanist: 'Humanizada',
};

/// Resolves a persisted font id to the `fontFamily` value [ThemeData]
/// expects. `null` means "use the platform default", which is already a
/// humanist sans (Roboto/San Francisco) — no bundled font asset needed.
/// `'monospace'` is a generic family name Flutter/Skia resolves to a
/// monospace fallback on both Android and iOS.
String? resolveFontFamily(String id) {
  return id == FontFamilyOption.mono ? 'monospace' : null;
}
