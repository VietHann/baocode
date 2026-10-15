import '../upstream.dart';

/// Google Antigravity OAuth client configuration supplied by the BaoCode
/// build. Keep credentials out of the repository; desktop OAuth clients can
/// be injected with --dart-define when packaging the app.
const geminiOAuthClientId = String.fromEnvironment(
  'BAOCODE_GOOGLE_OAUTH_CLIENT_ID',
);
const geminiOAuthClientSecret = String.fromEnvironment(
  'BAOCODE_GOOGLE_OAUTH_CLIENT_SECRET',
);

const geminiOAuthScopes = [
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile',
];

/// Match the Antigravity client surface used by cursor-byok's current
/// built-in Antigravity provider.
const antigravityUserAgent =
    'antigravity/hub/2.12.2 (aidev_client; os_type=windows; arch=x64; cl=975423596)';

const antigravityEndpoints = [
  'https://daily-cloudcode-pa.googleapis.com',
  'https://cloudcode-pa.googleapis.com',
  'https://daily-cloudcode-pa.sandbox.googleapis.com',
];

const antigravityDefaultProject = 'bamboo-precept-lgxtn';

class GeminiEndpoints {
  const GeminiEndpoints({
    this.authorizeBase = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.tokenBase = 'https://oauth2.googleapis.com/token',
    this.userInfoBase =
        'https://www.googleapis.com/oauth2/v1/userinfo?alt=json',
  });

  final String authorizeBase;
  final String tokenBase;
  final String userInfoBase;

  Uri get authorize => Uri.parse(authorizeBase);
  Uri get token => Uri.parse(tokenBase);
  Uri get userInfo => Uri.parse(userInfoBase);

  Uri method(String base, String name, {Map<String, String>? query}) =>
      Uri.parse('$base/v1internal:$name').replace(queryParameters: query);

  String redirectUri(int port) => 'http://127.0.0.1:$port/oauth2callback';
}

Map<String, String> geminiHeaders(String accessToken, {bool events = false}) =>
    {
      'authorization': 'Bearer $accessToken',
      'user-agent': antigravityUserAgent,
      'content-type': 'application/json',
      'accept': events ? 'text/event-stream' : 'application/json',
    };

/// Parse exactly the model catalog Google returns from Antigravity's
/// fetchAvailableModels. No locally invented/static model catalog is merged in.
List<RemoteModel> parseAntigravityModels(Object? json) {
  if (json is! Map || json['models'] is! Map) return const [];
  final raw = json['models'] as Map;
  const deny = {'chat_20706', 'chat_23310'};
  final models = <RemoteModel>[];
  final seen = <String>{};

  for (final entry in raw.entries) {
    final id = '${entry.key}'.trim();
    if (id.isEmpty || deny.contains(id) || !seen.add(id)) continue;
    if (entry.value is! Map) continue;
    final info = entry.value as Map;
    final display = switch (info['displayName']) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => null,
    };
    final thinking = info['supportsThinking'] == true;
    final lower = id.toLowerCase();
    final images =
        info['supportsImages'] == true ||
        lower.contains('gemini') ||
        lower.contains('claude');

    models.add(
      RemoteModel(
        id,
        label: display,
        efforts: thinking ? const ['low', 'medium', 'high'] : const [],
        images: images,
      ),
    );
  }

  return models;
}
