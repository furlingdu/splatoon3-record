class NSOAuthCallback {
  const NSOAuthCallback({required this.State, required this.Code, required this.Error});

  final String State;
  final String Code;
  final String Error;

  static NSOAuthCallback? Parse(Uri Link) {
    if (!Link.scheme.startsWith('npf') || Link.host != 'auth') return null;
    return _Build(_Values(Link));
  }

  static NSOAuthCallback? ParseInput(String Text) {
    final Trimmed = Text.trim();
    if (Trimmed.isEmpty) return null;
    final Npf = Trimmed.contains('npf') ? Trimmed.substring(Trimmed.indexOf('npf')).trim() : '';
    final Decoded = _Decode(Npf.isNotEmpty ? Npf : Trimmed);
    final Candidates = <String>{
      Trimmed,
      Trimmed.replaceAll('&amp;', '&'),
      Npf,
      Decoded,
      Decoded.replaceAll('&amp;', '&'),
      if (Decoded.contains('npf')) Decoded.substring(Decoded.indexOf('npf')).trim(),
    };
    for (final Candidate in Candidates) {
      if (Candidate.isEmpty) continue;
      final Callback = _ParseText(Candidate);
      if (Callback != null) return Callback;
    }
    return null;
  }

  static NSOAuthCallback? _ParseText(String Text) {
    final Link = Uri.tryParse(Text);
    if (Link != null) {
      final Direct = Parse(Link);
      if (Direct != null) return Direct;
      final Values = _Values(Link);
      if (Values.containsKey('session_token_code') || Values.containsKey('error')) return _Build(Values);
    }
    if (Text.contains('session_token_code=') || Text.contains('error=')) {
      try {
        return _Build(Uri.splitQueryString(Text.replaceFirst(RegExp(r'^[?#]'), '')));
      } catch (_) {}
    }
    return null;
  }

  static Map<String, String> _Values(Uri Link) {
    final Values = <String, String>{};
    Values.addAll(Link.queryParameters);
    if (Link.fragment.isNotEmpty) {
      try {
        Values.addAll(Uri.splitQueryString(Link.fragment));
      } catch (_) {}
    }
    return Values;
  }

  static NSOAuthCallback? _Build(Map<String, String> Values) {
    final Code = Values['session_token_code'] ?? '';
    final State = Values['state'] ?? '';
    final Error = Values['error_description'] ?? Values['error'] ?? '';
    if (Code.isEmpty && State.isEmpty && Error.isEmpty) return null;
    return NSOAuthCallback(State: State, Code: Code, Error: Error);
  }

  static String _Decode(String Value) {
    try {
      return Uri.decodeFull(Value);
    } catch (_) {
      return '';
    }
  }
}
