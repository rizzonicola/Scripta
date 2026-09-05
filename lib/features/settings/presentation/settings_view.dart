import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/color_schemes.dart';
import '../providers/settings_provider.dart';
import 'about_credits_dialog.dart';
import 'account_sync_section.dart';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const FractionallySizedBox(
        heightFactor: 0.85,
        child: SettingsView(),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.settings),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        children: [
          // Section: Account & Sync Toggles
          const AccountSyncSection(),
          const SizedBox(height: 24),

          // Section: Appearance & Theme
          _buildSectionHeader(theme, l10n.theme),
          Card(
            child: RadioGroup<ThemeMode>(
              groupValue: settings.themeMode,
              onChanged: (mode) {
                if (mode != null) {
                  ref.read(settingsProvider.notifier).setThemeMode(mode);
                }
              },
              child: Column(
                children: [
                  RadioListTile<ThemeMode>(
                    title: Text(l10n.themeSystem),
                    secondary: const Icon(Icons.brightness_auto_rounded),
                    value: ThemeMode.system,
                  ),
                  RadioListTile<ThemeMode>(
                    title: Text(l10n.themeLight),
                    secondary: const Icon(Icons.light_mode_rounded),
                    value: ThemeMode.light,
                  ),
                  RadioListTile<ThemeMode>(
                    title: Text(l10n.themeDark),
                    secondary: const Icon(Icons.dark_mode_rounded),
                    value: ThemeMode.dark,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Section: Color Palette (including Dark Teal and OLED Black)
          _buildSectionHeader(theme, l10n.themePalette),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 2.2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: AppThemePalettes.all.length,
            itemBuilder: (context, index) {
              final palette = AppThemePalettes.all[index];
              final isSelected = settings.selectedThemeId == palette.id;

              return InkWell(
                onTap: () {
                  ref.read(settingsProvider.notifier).setThemeId(palette.id);
                  ref.read(settingsProvider.notifier).setThemeMode(
                        palette.brightness == Brightness.dark
                            ? ThemeMode.dark
                            : ThemeMode.light,
                      );
                },
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: palette.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected
                          ? palette.primary
                          : palette.border.withValues(alpha: 0.8),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      // Palette color swatches
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: palette.background,
                              shape: BoxShape.circle,
                              border: Border.all(color: palette.border, width: 1),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: palette.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              palette.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: palette.textPrimary,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              palette.brightness == Brightness.dark
                                  ? 'Scuro'
                                  : 'Chiaro',
                              style: TextStyle(
                                color: palette.textSecondary,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isSelected)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 16,
                          color: palette.primary,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),

          const SizedBox(height: 24),

          // Section: Language
          _buildSectionHeader(theme, l10n.language),
          Card(
            child: RadioGroup<String?>(
              groupValue: settings.locale?.languageCode,
              onChanged: (val) {
                if (val == null) {
                  ref.read(settingsProvider.notifier).setLocale(null);
                } else {
                  ref.read(settingsProvider.notifier).setLocale(Locale(val));
                }
              },
              child: Column(
                children: [
                  RadioListTile<String?>(
                    title: Text(l10n.languageSystem),
                    subtitle: const Text('Rileva automaticamente / Auto detect'),
                    value: null,
                  ),
                  RadioListTile<String?>(
                    title: Text(l10n.languageIt),
                    value: 'it',
                  ),
                  RadioListTile<String?>(
                    title: Text(l10n.languageEn),
                    value: 'en',
                  ),
                  RadioListTile<String?>(
                    title: Text(l10n.languageFr),
                    value: 'fr',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Section: Typography
          _buildSectionHeader(theme, l10n.typography),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Font family dropdown
                  Text(
                    l10n.fontFamily,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: settings.fontFamily,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'Inter',
                        child: Text('Inter (Clean Modern Sans)'),
                      ),
                      DropdownMenuItem(
                        value: 'JetBrains Mono',
                        child: Text('JetBrains Mono (Monospace)'),
                      ),
                      DropdownMenuItem(
                        value: 'Merriweather',
                        child: Text('Merriweather (Classic Serif)'),
                      ),
                      DropdownMenuItem(
                        value: 'Roboto',
                        child: Text('Roboto (Standard Sans)'),
                      ),
                    ],
                    onChanged: (family) {
                      if (family != null) {
                        ref
                            .read(settingsProvider.notifier)
                            .setFontFamily(family);
                      }
                    },
                  ),

                  const SizedBox(height: 20),

                  // Font size slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.fontSize,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text('${settings.fontSize.toInt()} pt'),
                    ],
                  ),
                  Slider(
                    value: settings.fontSize,
                    min: 13,
                    max: 24,
                    divisions: 11,
                    onChanged: (val) {
                      ref.read(settingsProvider.notifier).setFontSize(val);
                    },
                  ),

                  const SizedBox(height: 12),

                  // Line height slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.lineHeight,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(settings.lineHeight.toStringAsFixed(1)),
                    ],
                  ),
                  Slider(
                    value: settings.lineHeight,
                    min: 1.2,
                    max: 2.2,
                    divisions: 10,
                    onChanged: (val) {
                      ref.read(settingsProvider.notifier).setLineHeight(val);
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Section: About
          _buildSectionHeader(theme, l10n.about),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(l10n.about),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                AboutCreditsDialog.show(context);
              },
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}
