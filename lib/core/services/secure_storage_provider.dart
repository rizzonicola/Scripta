import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'secure_storage_service.dart';

/// Provider del servizio di storage sicuro. Vive accanto al servizio, non
/// dentro la feature di sync: è un servizio del core usato anche altrove.
final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageService();
});
