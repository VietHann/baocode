import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// Google-account backed Gemini Code Assist provider. It intentionally
/// implements the same account-service surface as Codex so Settings -> Models
/// can reuse BaoCode's existing account UI and keychain storage.
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
    final secrets = _providers().secrets;
    final ref = ModelProvider.accountRefFor(providerId, account.id);
    String? refreshToken;
    try {
      refreshToken = await secrets.read(ref);
    } on SecretStoreException catch (error) {
      throw _fail(key, 'The Google token could not be read: $error');
    }
    if (refreshToken == null || refreshToken.isEmpty) {
      throw _fail(key, 'Signed out: sign in with Google again.', signedOut: true);
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
            ? 'Google sign-in expired: sign in again.'
            : 'The Google token could not be refreshed: ${upstreamErrorMessage(status, text)}',
        signedOut: refused,
      );
    }
    final tokens = GeminiTokens.fromJson(_decode(text), _now());
    if (tokens == null) {
      throw _fail(key, 'Google returned no access token.');
    }
    if (tokens.refresh case final rotated? when rotated != refreshToken) {
      try {
        await secrets.write(ref, rotated);
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
        'Google OAuth client id is not configured. Build BaoCode with --dart-define=BAOCODE_GOOGLE_OAUTH_CLIENT_ID=<client-id>.',
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
      geminiCodeForm(
        endpoints,
        port: port,
        code: code,
        verifier: verifier,
      ),
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
        'Google sign-in returned no refresh token. Remove BaoCode/Gemini CLI access from your Google account and sign in again.',
      );
    }

    final email = await _email(tokens.access);
    if (email == null || email.isEmpty) {
      throw const CodexException('Google sign-in returned no account email.');
    }
    final user = await _setupUser(tokens.access);

    final providers = _providers();
    final provider = providers.provider(providerId);
    if (provider == null) throw const CodexException('The provider was removed.');
    final id = geminiAccountKey(email);
    final account = switch (provider.account(id)) {
      final known? => known.copyWith(
        email: email,
        plan: user.tier,
        accountId: user.project,
      ),
      null => ProviderAccount(
        id: id,
        email: email,
        plan: user.tier,
        accountId: user.project,
      ),
    };

    try {
      await providers.secrets.write(
        ModelProvider.accountRefFor(providerId, account.id),
        refreshToken,
      );
    } on SecretStoreException catch (error) {
      throw CodexException('The Google refresh token could not be kept: $error');
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
      {'email': final String email} when email.trim().isNotEmpty => email.trim(),
      _ => null,
    };
  }

  Future<({String project, String tier})> _setupUser(String token) async {
    const metadata = <String, Object?>{
      'ideType': 'IDE_UNSPECIFIED',
      'platform': 'PLATFORM_UNSPECIFIED',
      'pluginType': 'GEMINI',
    };
    final load = await _postJson(
      endpoints.method('loadCodeAssist'),
      token,
      {'metadata': metadata},
    );
    if (load.status >= 400 || load.json is! Map) {
      throw CodexException(
        'Gemini Code Assist setup failed: ${upstreamErrorMessage(load.status, load.text)}',
      );
    }
    final data = load.json as Map;
    final currentTier = data['currentTier'];
    final paidTier = data['paidTier'];
    if (currentTier is Map) {
      final project = '${data['cloudaicompanionProject'] ?? ''}'.trim();
      if (project.isEmpty) {
        throw const CodexException(
          'This Google account requires a Google Cloud project. BaoCode Google sign-in currently supports the managed personal Gemini Code Assist project only.',
        );
      }
      return (
        project: project,
        tier: _tierName(paidTier is Map ? paidTier : currentTier),
      );
    }

    final allowed = data['allowedTiers'];
    Map? tier;
    if (allowed is List) {
      for (final item in allowed) {
        if (item is Map && item['isDefault'] == true) {
          tier = item;
          break;
        }
      }
      tier ??= allowed.whereType<Map>().firstOrNull;
    }
    if (tier == null) {
      final ineligible = data['ineligibleTiers'];
      final reason = ineligible is List && ineligible.isNotEmpty
          ? '${(ineligible.first as Map?)?['reasonMessage'] ?? 'Account is not eligible.'}'
          : 'No eligible Gemini Code Assist tier was returned.';
      throw CodexException(reason);
    }

    final tierId = '${tier['id'] ?? ''}';
    if (tierId != 'free-tier') {
      throw CodexException(
        'Google account tier "$tierId" requires a Google Cloud project; only personal managed-project sign-in is enabled.',
      );
    }
    var op = await _postJson(
      endpoints.method('onboardUser'),
      token,
      {'tierId': tierId, 'metadata': metadata},
    );
    if (op.status >= 400 || op.json is! Map) {
      throw CodexException(
        'Gemini Code Assist onboarding failed: ${upstreamErrorMessage(op.status, op.text)}',
      );
    }
    var operation = op.json as Map;
    for (var attempt = 0; operation['done'] != true && attempt < 24; attempt++) {
      final name = '${operation['name'] ?? ''}';
      if (name.isEmpty) break;
      await Future<void>.delayed(const Duration(seconds: 5));
      op = await _getJson(endpoints.operation(name), token);
      if (op.status >= 400 || op.json is! Map) break;
      operation = op.json as Map;
    }
    final response = operation['response'];
    final companion = response is Map ? response['cloudaicompanionProject'] : null;
    final project = companion is Map ? '${companion['id'] ?? ''}'.trim() : '';
    if (project.isEmpty) {
      throw const CodexException(
        'Gemini Code Assist onboarding did not return a managed project.',
      );
    }
    return (project: project, tier: _tierName(tier));
  }

  static String _tierName(Map tier) {
    final name = '${tier['name'] ?? ''}'.trim();
    return name.isNotEmpty ? name : '${tier['id'] ?? 'Google'}';
  }

  @override
  Future<void> refreshUsage(ModelProvider provider) async {
    // Code Assist quota is request/model dependent. We intentionally keep the
    // generic account row but do not fake Codex-style percentage windows.
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

  Future<List<RemoteModel>> listModels(ModelProvider provider) async {
    if (pick(provider) == null) {
      throw const UpstreamException('Sign in with Google first.');
    }
    return geminiCodeAssistModels;
  }

  /// Opens one Code Assist streaming request and returns OpenAI-shaped SSE
  /// lines for BaoCode's existing OpenAI -> Claude response translator.
  Future<Stream<String>> open(
    ModelProvider provider,
    Map<String, Object?> codeAssistRequest, {
    required String model,
    required bool stream,
    String? session,
  }) async {
    final tried = <String>{};
    String? lastError;
    var lastStatus = 429;

    while (true) {
      final account = pick(provider, session: session, exclude: tried);
      if (account == null) {
        throw CodexException(
          lastError ??
              (provider.accounts.isEmpty
                  ? 'Sign in with Google first.'
                  : 'No signed-in Google account can be used now.'),
        );
      }

      String? rejected;
      for (var attempt = 0; attempt < 2; attempt++) {
        final token = await accessToken(provider, account, rejected: rejected);
        final request = await _http.postUrl(
          endpoints.method('streamGenerateContent', query: {'alt': 'sse'}),
        );
        geminiHeaders(token, events: true).forEach(request.headers.set);

        final outgoing = Map<String, Object?>.from(codeAssistRequest);
        outgoing['project'] = account.accountId;
        outgoing['user_prompt_id'] =
            session ?? 'baocode-${DateTime.now().microsecondsSinceEpoch}';
        request.add(utf8.encode(jsonEncode(outgoing)));
        final response = await request.close().timeout(const Duration(seconds: 60));
        if (response.statusCode >= 400) {
          final text = await utf8.decodeStream(response);
          final message = upstreamErrorMessage(response.statusCode, text);
          if (response.statusCode == 401 && rejected == null) {
            rejected = token;
            continue;
          }
          lastStatus = response.statusCode;
          lastError = '${account.displayName}: $message';
          _errors[_key(provider.id, account.id)] = message;
          notifyListeners();
          if (response.statusCode == 401 || response.statusCode == 429) {
            tried.add(account.id);
            break;
          }
          throw CodexException(message);
        }

        _errors.remove(_key(provider.id, account.id));
        notifyListeners();
        final adapter = GeminiResponseAdapter(model: model, stream: stream);
        return (() async* {
          await for (final line in response
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
      if (tried.length >= provider.accounts.length) {
        throw CodexException(lastError ?? 'Gemini request failed ($lastStatus).');
      }
    }
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
      final response = await request.close().timeout(const Duration(seconds: 30));
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

  Future<({int status, String text, Object? json})> _getJson(
    Uri url,
    String token,
  ) async {
    final request = await _http.getUrl(url);
    geminiHeaders(token).forEach(request.headers.set);
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
      throw const CodexException('That callback is not from this Google sign-in.');
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
      final reason = query['error_description'] ?? error ?? 'No code was returned.';
      title = 'Google sign-in failed';
      detail = reason;
      _finish(CodexException('Google sign-in failed: $reason'));
    } else {
      title = 'Signed in with Google';
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
