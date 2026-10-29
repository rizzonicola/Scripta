import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/theme/color_schemes.dart';
import '../../sync/providers/sync_provider.dart';

class AccountSyncSection extends ConsumerStatefulWidget {
  const AccountSyncSection({super.key});

  @override
  ConsumerState<AccountSyncSection> createState() => _AccountSyncSectionState();
}

class _AccountSyncSectionState extends ConsumerState<AccountSyncSection> {
  late final TextEditingController _serverUrlController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _obscurePassword = true;
  bool _loggingOutAll = false;

  @override
  void initState() {
    super.initState();
    final syncConfig = ref.read(syncProvider);
    _serverUrlController = TextEditingController(text: syncConfig.serverUrl);
    _usernameController = TextEditingController(
      text: syncConfig.username ?? '',
    );
    _passwordController = TextEditingController();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _formatTimestamp(DateTime? dateTime, String neverText) {
    if (dateTime == null) return neverText;
    return DateFormat('dd/MM/yyyy HH:mm:ss').format(dateTime);
  }

  Future<void> _confirmLogoutAll(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.logoutAllDevicesConfirmTitle),
        content: Text(l10n.logoutAllDevicesConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).dangerColor,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.logoutAllDevicesConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !context.mounted) return;

    setState(() => _loggingOutAll = true);
    final revoked = await ref.read(syncProvider.notifier).logoutAllDevices();
    if (!mounted || !context.mounted) return;
    setState(() => _loggingOutAll = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          revoked ? l10n.logoutAllDevicesSuccess : l10n.logoutAllDevicesFailed,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final syncConfig = ref.watch(syncProvider);
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);

    // Keep controller updated if state serverUrl changed
    if (_serverUrlController.text.isEmpty && syncConfig.serverUrl.isNotEmpty) {
      _serverUrlController.text = syncConfig.serverUrl;
    }

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Header: Account & Server
          _buildSectionHeader(theme, l10n.accountServerSection),
          _buildAccountCard(context, theme, syncConfig, l10n),

          const SizedBox(height: 24),

          // Section Header: Sync Toggles
          _buildSectionHeader(theme, l10n.syncTogglesSection),
          _buildSyncTogglesCard(context, theme, syncConfig, l10n),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.1,
        ),
      ),
    );
  }

  Widget _buildAccountCard(
    BuildContext context,
    ThemeData theme,
    dynamic syncConfig,
    AppLocalizations l10n,
  ) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.25),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status bar: Connection badge & Last sync
            Row(
              children: [
                _buildStatusBadge(theme, syncConfig, l10n),
                const Spacer(),
                Icon(
                  Icons.history_rounded,
                  size: 15,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 4),
                Text(
                  '${l10n.lastSync}: ${_formatTimestamp(syncConfig.lastSyncTime, l10n.never)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.mutedTextColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ),

            if (syncConfig.lastSyncMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        syncConfig.lastSyncMessage!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            if (syncConfig.lastError != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.dangerColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.dangerColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 14,
                      color: theme.dangerColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        syncConfig.lastError!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.dangerColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),

            if (syncConfig.isAuthenticated) ...[
              // Logged in state
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primary.withValues(
                      alpha: 0.2,
                    ),
                    radius: 20,
                    child: Text(
                      (syncConfig.username?.isNotEmpty == true
                              ? syncConfig.username![0]
                              : 'U')
                          .toUpperCase(),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          syncConfig.username ?? 'Utente',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          syncConfig.serverUrl,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.logout_rounded, size: 16),
                    label: Text(l10n.disconnect),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.dangerColor,
                      side: BorderSide(
                        color: theme.dangerColor.withValues(alpha: 0.5),
                      ),
                    ),
                    onPressed: () {
                      ref.read(syncProvider.notifier).logout();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _loggingOutAll
                      ? null
                      : () => _confirmLogoutAll(context, l10n),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.dangerColor,
                    disabledForegroundColor: theme.dangerColor.withValues(
                      alpha: 0.45,
                    ),
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: Text(l10n.logoutAllDevices),
                ),
              ),
            ] else ...[
              // Login Form
              TextField(
                controller: _serverUrlController,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.url],
                decoration: InputDecoration(
                  labelText: l10n.serverUrlLabel,
                  hintText: AppConstants.serverUrlPlaceholder,
                  prefixIcon: const Icon(Icons.dns_outlined, size: 20),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameController,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.none,
                autofillHints: const [AutofillHints.username],
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: l10n.usernameLabel,
                  hintText: 'mario.rossi',
                  // Il testo di esempio deve leggersi chiaramente come
                  // placeholder (non come un valore già inserito): usiamo
                  // il colore semantico `hintColor` del tema attivo, che si
                  // adatta automaticamente a ciascuna delle palette
                  // chiare/scure dell'app, invece di ereditare lo stesso
                  // colore/peso del testo digitato dall'utente.
                  hintStyle: TextStyle(color: theme.hintColor),
                  prefixIcon: const Icon(
                    Icons.person_outline_rounded,
                    size: 20,
                  ),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: l10n.passwordLabel,
                  prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscurePassword = !_obscurePassword;
                      });
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: syncConfig.isSyncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.login_rounded, size: 18),
                  label: Text(
                    syncConfig.isSyncing ? l10n.syncing : l10n.connectLogin,
                  ),
                  onPressed: syncConfig.isSyncing
                      ? null
                      : () async {
                          final serverUrl = _serverUrlController.text.trim();
                          final username = _usernameController.text.trim();
                          final password = _passwordController.text;

                          if (serverUrl.isEmpty ||
                              username.isEmpty ||
                              password.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l10n.fillRequiredFields),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                            return;
                          }

                          final success = await ref
                              .read(syncProvider.notifier)
                              .login(
                                serverUrl: serverUrl,
                                username: username,
                                password: password,
                              );

                          if (!context.mounted) return;
                          if (success) {
                            TextInput.finishAutofillContext();
                            _passwordController.clear();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l10n.syncSuccess),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          } else {
                            final error = ref.read(syncProvider).lastError;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(error ?? l10n.syncFailed),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(
    ThemeData theme,
    dynamic syncConfig,
    AppLocalizations l10n,
  ) {
    final bool isOnline = syncConfig.isOnline;
    final bool isSyncing = syncConfig.isSyncing;

    final Color badgeColor = isSyncing
        ? theme.colorScheme.primary
        : (isOnline ? theme.successColor : theme.warningColor);

    final String statusText = isSyncing
        ? l10n.syncing
        : (isOnline ? l10n.online : l10n.offline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: badgeColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            statusText,
            style: TextStyle(
              color: badgeColor,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncTogglesCard(
    BuildContext context,
    ThemeData theme,
    dynamic syncConfig,
    AppLocalizations l10n,
  ) {
    final notifier = ref.read(syncProvider.notifier);

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.25),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            // Manual Sync Button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.manualSync,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          l10n.manualSyncDesc,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    icon: syncConfig.isSyncing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded, size: 16),
                    label: Text(l10n.syncNow),
                    onPressed:
                        (syncConfig.isAuthenticated && !syncConfig.isSyncing)
                        ? () async {
                            final success = await notifier.triggerSync();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    success
                                        ? l10n.syncSuccess
                                        : l10n.syncFailed,
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        : null,
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Toggle: App Launch
            SwitchListTile(
              secondary: const Icon(Icons.power_settings_new_rounded),
              title: Text(l10n.syncOnAppLaunch),
              subtitle: Text(
                l10n.syncOnAppLaunchDesc,
                style: const TextStyle(fontSize: 12),
              ),
              value: syncConfig.syncOnAppLaunch,
              onChanged: (val) => notifier.setSyncOnAppLaunch(val),
            ),

            const Divider(height: 1),

            // Toggle: App Lifecycle / Exit
            SwitchListTile(
              secondary: const Icon(Icons.pause_circle_outline_rounded),
              title: Text(l10n.syncOnAppLifecycle),
              subtitle: Text(
                l10n.syncOnAppLifecycleDesc,
                style: const TextStyle(fontSize: 12),
              ),
              value: syncConfig.syncOnAppLifecycle,
              onChanged: (val) => notifier.setSyncOnAppLifecycle(val),
            ),

            const Divider(height: 1),

            // Toggle: Note Switch / Editor Close
            SwitchListTile(
              secondary: const Icon(Icons.swap_horiz_rounded),
              title: Text(l10n.syncOnNoteSwitch),
              subtitle: Text(
                l10n.syncOnNoteSwitchDesc,
                style: const TextStyle(fontSize: 12),
              ),
              value: syncConfig.syncOnNoteSwitch,
              onChanged: (val) => notifier.setSyncOnNoteSwitch(val),
            ),

            const Divider(height: 1),

            // Toggle: Inactivity Debounce
            SwitchListTile(
              secondary: const Icon(Icons.timer_outlined),
              title: Text(l10n.syncOnInactivity),
              subtitle: Text(
                l10n.syncOnInactivityDesc,
                style: const TextStyle(fontSize: 12),
              ),
              value: syncConfig.syncOnInactivity,
              onChanged: (val) => notifier.setSyncOnInactivity(val),
            ),

            if (syncConfig.syncOnInactivity) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${l10n.inactivityInterval}:',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${syncConfig.inactivitySeconds} ${l10n.seconds}',
                            style: TextStyle(
                              color: theme.colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: syncConfig.inactivitySeconds.toDouble(),
                      min: 10,
                      max: 120,
                      divisions: 22,
                      label: '${syncConfig.inactivitySeconds}s',
                      onChanged: (val) {
                        notifier.setInactivitySeconds(val.round());
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        l10n.inactivityMinDefault,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.mutedTextColor,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
