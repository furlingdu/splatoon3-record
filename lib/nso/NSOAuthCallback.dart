class NSOAuthCallback {
  const NSOAuthCallback({required this.State, required this.Code, required this.Error});

  final String State;
  final String Code;
  final String Error;

  static NSOAuthCallback? Parse(Uri Link) {
    if (!Link.scheme.startsWith('npf') || Link.host != 'auth') return null;
    final Values = <String, String>{};
    Values.addAll(Link.queryParameters);
    if (Link.fragment.isNotEmpty) {
      try {
        Values.addAll(Uri.splitQueryString(Link.fragment));
      } catch (_) {}
    }
    return NSOAuthCallback(
      State: Values['state'] ?? '',
      Code: Values['session_token_code'] ?? '',
      Error: Values['error_description'] ?? Values['error'] ?? '',
    );
  }
}
