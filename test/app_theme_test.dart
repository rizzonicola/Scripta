import 'package:flutter_test/flutter_test.dart';
import 'package:scripta/core/constants/app_constants.dart';
import 'package:scripta/core/theme/app_theme.dart';

void main() {
  test('i font supportati sono quelli inclusi negli asset', () {
    expect(AppConstants.supportedFontFamilies, ['Inter', 'JetBrains Mono']);
    expect(
      AppTheme.getTextStyleForFont('Inter').fontFamily,
      AppTheme.defaultFontFamily,
    );
    expect(
      AppTheme.getTextStyleForFont('JetBrains Mono').fontFamily,
      AppTheme.monospaceFontFamily,
    );
  });

  test('una famiglia non più supportata ripiega su Inter', () {
    expect(
      AppTheme.getTextStyleForFont('Roboto').fontFamily,
      AppTheme.defaultFontFamily,
    );
  });

  test('il tema globale usa Inter', () {
    expect(
      AppTheme.lightTheme().textTheme.bodyMedium?.fontFamily,
      AppTheme.defaultFontFamily,
    );
    expect(
      AppTheme.darkTheme().textTheme.bodyMedium?.fontFamily,
      AppTheme.defaultFontFamily,
    );
  });
}
