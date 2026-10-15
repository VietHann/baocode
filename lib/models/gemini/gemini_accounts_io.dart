// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../codex/codex_balancer.dart';
import '../codex/codex_service.dart';
import '../codex/codex_usage.dart';
import '../model_provider.dart';
import '../model_providers.dart';
import '../model_runtime.dart' show UpstreamException;
import '../proxy/translate/gemini_response.dart';
import '../secret_store.dart';
import '../upstream.dart';
import 'gemini_api.dart';
import 'gemini_oauth.dart';

/// Google Antigravity accounts. The class keeps BaoCode's existing account
/// UI/service contract, while authentication, model discovery and inference
/// all use the Antigravity Google endpoints.
class GeminiAccounts extends CodexService {
  GeminiAccounts({
    required ModelProviders Function() providers,
    this.endpoints = const GeminiEndpoints(),
    String Function(Uri url)? findProxy,
    Future<bool> Function(String url)? openBrowser,
    DateTime Function()? now,
    this.loginTimeout = const Duration(minutes: 5),
  }) : _providers = providers,
       _findProxy = findProxy,
       _openBrowser = openBrowser,
       _now = now ?? DateTime.now;

  final ModelProviders Function() _providers;
  final GeminiEndpoints endpoints;
  final String Function(Uri url)? _findProxy;
  final Future<bool> Function(String url)? _openBrowser;
  final DateTime Function() _now;
  final Duration loginTimeout;

  final CodexBalancer _balancer = CodexBalancer();
  final Map<String, ({String access, DateTime expiresAt})> _tokens = {};
  final Map<String, Future<String>> _refreshing = {};
  final Map<String, String> _errors = {};
  final Set<String> _signedOut = {};
  HttpClient? _client;

  static String _key(String providerId, String accountId) =>
      '$providerId/$accountId';

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30)
    ..findProxy = _findProxy ?? (_) => 'DIRECT';

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  @override
  CodexUsage? usage(String providerId, String accountId) => null;

  @override
  String? error(String providerId, String accountId) =>
      _errors[_key(providerId, accountId)];

  @override
  DateTime? limitedUntil(String providerId, String accountId) => null;

  bool signedOut(String providerId, String accountId) =>
      _signedOut.contains(_key(providerId, accountId));

  List<ProviderAccount> available(
    ModelProvider provider, {
    Set<String> exclude = const {},
  }) => [
    for (final account in provider.accounts)
      if (account.enabled &&
          !exclude.contains(account.id) &&
          !signedOut(provider.id, account.id))
        account,
  ];

  ProviderAccount? pick(
    ModelProvider provider, {
    String? session,
    Set<String> exclude = const {},
  }) => _balancer.pick(
    provider.id,
    available(provider, exclude: exclude),
    provider.balance,
    session: session,
  );

  Future<String> accessToken(
    ModelProvider provider,
    ProviderAccount account, {
    String? rejected,
  }) async {
    final key = _key(provider.id, account.id);
    final held = _tokens[key];
    if (held != null &&
        held.access != rejected &&
        held.expiresAt.isAfter(_now().add(const Duration(minutes: 1)))) {
      return held.access;
    }
    if (_refreshing[key] case final running?) return running;
    final refresh = _refresh(provider.id, account).whenComplete(() {
      _refreshing.remove(key);
    });
    _refreshing[key] = refresh;
    return refresh;
  }

  Future<String> _refresh(String providerId, ProviderAccount account) async {
    final key = _key(providerId, account.id);
    final ref = ModelProvider.accountRefFor(providerId, account.id);
    String? refreshToken;
    try {
      refreshToken = await _providers().secrets.read(ref);
    } on SecretStoreException catch (error) {
      throw _fail(key, 'The Google token could not be read: $error');
    }
    if (refreshToken == null || refreshToken.isEmpty) {
      throw _fail(
        key,
        'Signed out: sign in with Google again.',
        signedOut: true,
      );
    }

    final (status, text) = await _postForm(
      endpoints.token,
      geminiRefreshForm(refreshToken),
    );
    if (status >= 400) {
      final refused = status == 400 || status == 401 || status == 403;
      throw _fail(
        key,
        refused
            ? 'Google authorization expired or was revoked: sign in again.'
            : 'The Google token could not be refreshed: ${upstreamErrorMessage(status, text)}',
        signedOut: refused,
      );
    }

    final tokens = GeminiTokens.fromJson(_decode(text), _now());
    if (tokens == null) throw _fail(key, 'Google returned no access token.');
    if (tokens.refresh case final rotated? when rotated != refreshToken) {
      try {
        await _providers().secrets.write(ref, rotated);
      } on SecretStoreException catch (error) {
        debugPrint('Google refresh token of ${account.id} not kept: $error');
      }
    }

    _tokens[key] = (access: tokens.access, expiresAt: tokens.expiresAt);
    _signedOut.remove(key);
    _errors.remove(key);
    notifyListeners();
    return tokens.access;
  }

  CodexException _fail(String key, String message, {bool signedOut = false}) {
    _errors[key] = message;
    if (signedOut) {
      _signedOut.add(key);
      _tokens.remove(key);
    }
    notifyListeners();
    return CodexException(message);
  }

  @override
  Future<CodexLogin> login(String providerId) async {
    if (geminiOAuthClientId.isEmpty) {
      throw const CodexException(
        'Google Antigravity OAuth is not configured in this build.',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final state = geminiState();
    final pkce = GeminiPkce.generate();
    final port = server.port;
    final url = geminiAuthorizeUrl(
      endpoints,
      port: port,
      state: state,
      challenge: pkce.challenge,
    );
    final login = _GeminiLogin(url, server, state, loginTimeout);
    login.resultFuture = login.code.then(
      (code) => _signedIn(providerId, code, port, pkce.verifier),
    );
    if (_openBrowser case final open?) unawaited(open('$url'));
    return login;
  }

  Future<ProviderAccount> _signedIn(
    String providerId,
    String code,
    int port,
    String verifier,
  ) async {
    final (status, text) = await _postForm(
      endpoints.token,
      geminiCodeForm(endpoints, port: port, code: code, verifier: verifier),
    );
    if (status >= 400) {
      throw CodexException(
        'Google sign-in failed: ${upstreamErrorMessage(status, text)}',
      );
    }

    final tokens = GeminiTokens.fromJson(_decode(text), _now());
    final refreshToken = tokens?.refresh;
    if (tokens == null || refreshToken == null || refreshToken.isEmpty) {
      throw const CodexException(
        'Google sign-in returned no refresh token. Revoke the existing app authorization and sign in again.',
      );
    }

    final email = await _email(tokens.access);
    if (email == null || email.isEmpty) {
      throw const CodexException('Google sign-in returned no account email.');
    }
    final profile = await _antigravityProfile(tokens.access);

    final providers = _providers();
    final provider = providers.provider(providerId);
    if (provider == null) {
      throw const CodexException('The provider was removed.');
    }
    final id = geminiAccountKey(email);
    final account = switch (provider.account(id)) {
      final known? => known.copyWith(
        email: email,
        plan: profile.plan,
        accountId: profile.project,
      ),
      null => ProviderAccount(
        id: id,
        email: email,
        plan: profile.plan,
        accountId: profile.project,
      ),
    };

    try {
      await providers.secrets.write(
        ModelProvider.accountRefFor(providerId, account.id),
        refreshToken,
      );
    } on SecretStoreException catch (error) {
      throw CodexException(
        'The Google refresh token could not be kept: $error',
      );
    }

    final key = _key(providerId, account.id);
    _tokens[key] = (access: tokens.access, expiresAt: tokens.expiresAt);
    _signedOut.remove(key);
    _errors.remove(key);
    await providers.save(
      (providers.provider(providerId) ?? provider).withAccount(account),
    );
    notifyListeners();
    return account;
  }

  Future<String?> _email(String token) async {
    final request = await _http.getUrl(endpoints.userInfo);
    geminiHeaders(token).forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decodeStream(response);
    if (response.statusCode >= 400) return null;
    return switch (_decode(text)) {
      {'email': final String email} when email.trim().isNotEmpty =>
        email.trim(),
      _ => null,
    };
  }

  /// Ask Antigravity's loadCodeAssist surface for the account's companion
  /// project and tier. This deliberately does not perform Gemini CLI onboarding.
  Future<({String project, String plan})> _antigravityProfile(
    String token,
  ) async {
    for (final base in antigravityEndpoints) {
      try {
        final result = await _postJson(
          endpoints.method(base, 'loadCodeAssist'),
          token,
          const {
            'metadata': {'ideType': 'ANTIGRAVITY'},
          },
        );
        if (result.status < 200 ||
            result.status >= 300 ||
            result.json is! Map) {
          continue;
        }
        final data = result.json as Map;
        final project = switch (data['cloudaicompanionProject']) {
          final String value when value.trim().isNotEmpty => value.trim(),
          _ => antigravityDefaultProject,
        };
        final tier = data['paidTier'] is Map
            ? data['paidTier'] as Map
            : data['currentTier'];
        final tierText = tier is Map
            ? '${tier['name'] ?? tier['id'] ?? ''}'.toLowerCase()
            : '';
        final plan = tierText.contains('ultra')
            ? 'ULTRA'
            : (tierText.contains('pro') ||
                  tierText.contains('premium') ||
                  tierText.contains('advanced'))
            ? 'PRO'
            : 'FREE';
        return (project: project, plan: plan);
      } on Object {
        // Try Antigravity's next endpoint.
      }
    }
    return (project: antigravityDefaultProject, plan: 'FREE');
  }

  @override
  Future<void> refreshUsage(ModelProvider provider) async {
    // Quota is encoded per model in fetchAvailableModels. BaoCode currently
    // exposes no generic multi-family quota row, so model discovery remains
    // authoritative and we do not invent Codex-style windows here.
  }

  @override
  Future<void> removeAccount(String providerId, String accountId) async {
    final providers = _providers();
    if (providers.provider(providerId) case final provider?) {
      await providers.save(
        provider.copyWith(
          accounts: [
            for (final account in provider.accounts)
              if (account.id != accountId) account,
          ],
        ),
      );
    }
    try {
      await providers.secrets.delete(
        ModelProvider.accountRefFor(providerId, accountId),
      );
    } on SecretStoreException catch (error) {
      debugPrint('Google token of $accountId not removed: $error');
    }
    final key = _key(providerId, accountId);
    _tokens.remove(key);
    _errors.remove(key);
    _signedOut.remove(key);
    _balancer.forget(providerId, accountId);
    notifyListeners();
  }

  /// Fetch the model catalog from Google Antigravity for the signed-in
  /// account. No static/local model list is merged into the response.
  Future<List<RemoteModel>> listModels(ModelProvider provider) async {
    final account = pick(provider);
    if (account == null) {
      throw const UpstreamException('Sign in with Google (Antigravity) first.');
    }
    final token = await accessToken(provider, account);
    final project = account.accountId?.trim().isNotEmpty == true
        ? account.accountId!.trim()
        : antigravityDefaultProject;
    String? lastError;

    for (final base in antigravityEndpoints) {
      for (final body in <Map<String, Object?>>[
        {'project': project},
        const {},
      ]) {
        try {
          final result = await _postJson(
            endpoints.method(base, 'fetchAvailableModels'),
            token,
            body,
          );
          if (result.status >= 200 && result.status < 300) {
            final models = parseAntigravityModels(result.json);
            if (models.isNotEmpty) return models;
            lastError = 'Google returned an empty Antigravity model catalog.';
          } else {
            lastError = upstreamErrorMessage(result.status, result.text);
          }
        } on Object catch (error) {
          lastError = '$error';
        }
      }
    }

    throw UpstreamException(
      lastError ?? 'Google Antigravity did not return any models.',
    );
  }

  /// Opens an Antigravity streaming request and adapts its Google SSE frames
  /// to the OpenAI-shaped stream BaoCode's existing Claude translator consumes.
  Future<Stream<String>> open(
    ModelProvider provider,
    Map<String, Object?> translatedRequest, {
    required String model,
    required bool stream,
    String? session,
  }) async {
    final triedAccounts = <String>{};
    String? lastError;

    while (true) {
      final account = pick(provider, session: session, exclude: triedAccounts);
      if (account == null) {
        throw CodexException(
          lastError ??
              (provider.accounts.isEmpty
                  ? 'Sign in with Google (Antigravity) first.'
                  : 'No signed-in Antigravity account can be used now.'),
        );
      }

      String? rejected;
      for (var authAttempt = 0; authAttempt < 2; authAttempt++) {
        final token = await accessToken(provider, account, rejected: rejected);
        final project = account.accountId?.trim().isNotEmpty == true
            ? account.accountId!.trim()
            : antigravityDefaultProject;

        for (final base in antigravityEndpoints) {
          final request = await _http.postUrl(
            endpoints.method(
              base,
              'streamGenerateContent',
              query: const {'alt': 'sse'},
            ),
          );
          geminiHeaders(token, events: true).forEach(request.headers.set);
          if (model.toLowerCase().contains('claude')) {
            request.headers.set(
              'anthropic-beta',
              'claude-code-20250219,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14',
            );
          }

          final inner = translatedRequest['request'] is Map
              ? Map<String, Object?>.from(translatedRequest['request'] as Map)
              : <String, Object?>{};
          inner.remove('session_id');
          final outgoing = <String, Object?>{
            'project': project,
            'model': model,
            'userAgent': 'antigravity',
            'requestType': 'agent',
            'requestId': _requestId(),
            'enabledCreditTypes': const ['GOOGLE_ONE_AI'],
            'request': inner,
          };
          request.add(utf8.encode(jsonEncode(outgoing)));

          final response = await request.close().timeout(
            const Duration(seconds: 60),
          );
          if (response.statusCode >= 400) {
            final text = await utf8.decodeStream(response);
            final message = upstreamErrorMessage(response.statusCode, text);
            if (response.statusCode == 401 && rejected == null) {
              rejected = token;
              break;
            }
            lastError = '${account.displayName}: $message';
            _errors[_key(provider.id, account.id)] = message;
            notifyListeners();

            if (response.statusCode == 429) {
              triedAccounts.add(account.id);
              break;
            }
            if (response.statusCode == 404 ||
                response.statusCode == 502 ||
                response.statusCode == 503 ||
                response.statusCode == 504) {
              continue;
            }
            throw CodexException(message);
          }

          _errors.remove(_key(provider.id, account.id));
          notifyListeners();
          final adapter = GeminiResponseAdapter(model: model, stream: stream);
          return (() async* {
            await for (final line
                in response
                    .transform(const Utf8Decoder(allowMalformed: true))
                    .transform(const LineSplitter())) {
              for (final converted in adapter.convert(line)) {
                yield converted;
              }
            }
            for (final converted in adapter.finish()) {
              yield converted;
            }
          })();
        }

        if (rejected != null) continue;
        break;
      }

      if (!triedAccounts.contains(account.id)) triedAccounts.add(account.id);
      if (triedAccounts.length >= provider.accounts.length) {
        throw CodexException(lastError ?? 'Antigravity request failed.');
      }
    }
  }

  String _requestId() {
    final random = Random.secure();
    final hex = [
      for (var i = 0; i < 4; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    return 'agent/${DateTime.now().millisecondsSinceEpoch}/$hex';
  }

  Future<(int status, String text)> _postForm(
    Uri url,
    Map<String, String> form,
  ) async {
    try {
      final request = await _http.postUrl(url);
      request.headers
        ..contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        )
        ..set(HttpHeaders.acceptHeader, 'application/json');
      request.write(Uri(queryParameters: form).query);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      return (response.statusCode, await utf8.decodeStream(response));
    } on SocketException catch (error) {
      throw CodexException('Could not reach ${url.host}: ${error.message}');
    } on TimeoutException {
      throw CodexException('${url.host} did not answer in time.');
    }
  }

  Future<({int status, String text, Object? json})> _postJson(
    Uri url,
    String token,
    Object body,
  ) async {
    final request = await _http.postUrl(url);
    geminiHeaders(token).forEach(request.headers.set);
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final text = await utf8.decodeStream(response);
    return (status: response.statusCode, text: text, json: _decode(text));
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }
}

class _GeminiLogin implements CodexLogin {
  _GeminiLogin(this.url, this._server, this._state, Duration timeout) {
    _server.listen((request) => unawaited(_handle(request)));
    _timer = Timer(timeout, () {
      _finish(const CodexException('Google sign-in took too long.'));
    });
  }

  @override
  final Uri url;
  final HttpServer _server;
  final String _state;
  final Completer<String> _code = Completer();
  late final Timer _timer;
  late Future<ProviderAccount> resultFuture;

  Future<String> get code => _code.future;

  @override
  Future<ProviderAccount> get result => resultFuture;

  @override
  bool get listening => true;

  @override
  void submit(String callback) {
    final uri = Uri.tryParse(callback.trim());
    if (uri == null || uri.queryParameters['state'] != _state) {
      throw const CodexException(
        'That callback is not from this Google sign-in.',
      );
    }
    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      final reason =
          uri.queryParameters['error_description'] ??
          uri.queryParameters['error'] ??
          'No authorization code was returned.';
      _finish(CodexException('Google sign-in failed: $reason'));
      return;
    }
    _finish(code);
  }

  @override
  void cancel() => _finish(const CodexCancelled());

  void _finish(Object outcome) {
    _timer.cancel();
    if (!_code.isCompleted) {
      if (outcome is String) {
        _code.complete(outcome);
      } else {
        _code.completeError(outcome);
      }
    }
    Future<void>.delayed(
      const Duration(milliseconds: 200),
      () => unawaited(_server.close(force: true)),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path != '/oauth2callback') {
      response.statusCode = HttpStatus.notFound;
      return response.close();
    }
    final query = request.uri.queryParameters;
    final error = query['error'];
    final code = query['code'];
    final String title;
    final String detail;
    if (query['state'] != _state) {
      response.statusCode = HttpStatus.badRequest;
      title = 'Google sign-in did not match';
      detail = 'Start it again from BaoCode.';
    } else if (error != null || code == null || code.isEmpty) {
      response.statusCode = HttpStatus.badRequest;
      final reason =
          query['error_description'] ?? error ?? 'No code was returned.';
      title = 'Google sign-in failed';
      detail = reason;
      _finish(CodexException('Google sign-in failed: $reason'));
    } else {
      title = 'Signed in with Google (Antigravity)';
      detail = 'You can close this page and return to BaoCode.';
      _finish(code);
    }
    response.headers.contentType = ContentType.html;
    response.write(_page(title, detail));
    await response.close();
  }

  static String _page(String title, String detail) {
    const escape = HtmlEscape();
    return '<!doctype html><meta charset="utf-8"><title>BaoCode</title>'
        '<body style="font-family:system-ui;text-align:center;margin-top:20vh">'
        '<h2>${escape.convert(title)}</h2><p>${escape.convert(detail)}</p>';
  }
}
