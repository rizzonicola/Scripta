/// Schemi ammessi per i link aperti da contenuto Markdown (potenzialmente
/// proveniente da altri dispositivi o da file importati, quindi NON fidato).
///
/// Un link come `[clicca](intent://...)`, `file:///...`, `javascript:...`,
/// `content://...` o uno schema custom di un'altra app verrebbe altrimenti
/// passato a `launchUrl` e potrebbe avviare app arbitrarie o esporre file.
const Set<String> kAllowedLinkSchemes = {'http', 'https', 'mailto'};

/// Restituisce un [Uri] sicuro da aprire, oppure `null` se il link non è
/// ammesso (schema non in [kAllowedLinkSchemes], host mancante per http/https,
/// destinatario mancante per mailto, input non parsabile).
Uri? safeExternalUri(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  // Caratteri di controllo (es. "java\nscript:") non ammessi.
  if (RegExp(r'[\u0000-\u001F\u007F]').hasMatch(trimmed)) return null;

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;

  final scheme = uri.scheme.toLowerCase();
  if (!kAllowedLinkSchemes.contains(scheme)) return null;

  if (scheme == 'mailto') {
    return uri.path.isEmpty ? null : uri;
  }
  return uri.host.isEmpty ? null : uri;
}
