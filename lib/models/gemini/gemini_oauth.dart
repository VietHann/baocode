import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'gemini_api.dart';

class GeminiPkce {
  const GeminiPkce(this.verifier, this.challenge);

  factory GeminiPkce.generate([Random? random]) {
    final source = random ?? Random.secure();
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final verifier = [
      for (var i = 0; i < 96; i++) chars[source.nextInt(chars.length)],
    ].join();
    final digest = sha256.convert(ascii.encode(verifier)).bytes;
    final challenge = base64Url.encode(digest).replaceAll('=', '');
    return GeminiPkce(verifier, challenge);
  }

  final String verifier;
  final String challenge;
}

String geminiState([Random? random]) {
  final source = random ?? Random.secure();
  return [
    for (var i = 0; i < 32; i++)
      source.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

Uri geminiAuthorizeUrl(
  GeminiEndpoints endpoints, {
  required int port,
  required String state,
  required String challenge,
}) => endpoints.authorize.replace(
  queryParameters: {
    'client_id': geminiOAuthClientId,
    'response_type': 'code',
    'redirect_uri': endpoints.redirectUri(port),
    'scope': geminiOAuthScopes.join(' '),
    'access_type': 'offline',
    'include_granted_scopes': 'true',
    // BaoCode does not share Gemini CLI's credential file, so force an
    // offline refresh token to be returned for this local account entry.
    'prompt': 'consent select_account',
    'state': state,
    'code_challenge': challenge,
    'code_challenge_method': 'S256',
  },
);

Map<String, String> geminiCodeForm(
  GeminiEndpoints endpoints, {
  required int port,
  required String code,
  required String verifier,
}) => {
  'grant_type': 'authorization_code',
  'client_id': geminiOAuthClientId,
  'code': code,
  'redirect_uri': endpoints.redirectUri(port),
  'code_verifier': verifier,
};

Map<String, String> geminiRefreshForm(String refreshToken) => {
  'grant_type': 'refresh_token',
  'client_id': geminiOAuthClientId,
  'refresh_token': refreshToken,
};

class GeminiTokens {
  const GeminiTokens({
    required this.access,
    required this.expiresAt,
    this.refresh,
    this.idToken,
  });

  final String access;
  final String? refresh;
  final String? idToken;
  final DateTime expiresAt;

  static GeminiTokens? fromJson(Object? json, DateTime now) {
    if (json is! Map) return null;
    final access = json['access_token'];
    if (access is! String || access.isEmpty) return null;
    String? read(String key) => switch (json[key]) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => null,
    };
    final expiresIn = switch (json['expires_in']) {
      final num seconds when seconds > 0 => seconds.toInt(),
      _ => 3600,
    };
    return GeminiTokens(
      access: access,
      refresh: read('refresh_token'),
      idToken: read('id_token'),
      expiresAt: now.add(Duration(seconds: expiresIn)),
    );
  }
}

String geminiAccountKey(String email) =>
    '${sha256.convert(utf8.encode(email.trim().toLowerCase()))}'.substring(0, 12);
