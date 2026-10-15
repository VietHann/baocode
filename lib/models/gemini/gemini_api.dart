import '../upstream.dart';

/// Google OAuth client id supplied by the BaoCode build.
/// Example: --dart-define=BAOCODE_GOOGLE_OAUTH_CLIENT_ID=...
const geminiOAuthClientId = String.fromEnvironment(
  'BAOCODE_GOOGLE_OAUTH_CLIENT_ID',
);

const geminiOAuthScopes = [
  'https://www.googleapis.com/auth/cloud-platform',
  'https://www.googleapis.com/auth/userinfo.email',
  'https://www.googleapis.com/auth/userinfo.profile',
];

const geminiCodeAssistUserAgent =
    'GeminiCLI-BaoCode/1.0/gemini-2.5-pro (desktop; dart; baocode)';

class GeminiEndpoints {
  const GeminiEndpoints({
    this.authorizeBase = 'https://accounts.google.com/o/oauth2/v2/auth',
    this.tokenBase = 'https://oauth2.googleapis.com/token',
    this.userInfoBase = 'https://www.googleapis.com/oauth2/v2/userinfo',
    this.codeAssistBase = 'https://cloudcode-pa.googleapis.com/v1internal',
  });

  final String authorizeBase;
  final String tokenBase;
  final String userInfoBase;
  final String codeAssistBase;

  Uri get authorize => Uri.parse(authorizeBase);
  Uri get token => Uri.parse(tokenBase);
  Uri get userInfo => Uri.parse(userInfoBase);

  Uri method(String name, {Map<String, String>? query}) =>
      Uri.parse('$codeAssistBase:$name').replace(queryParameters: query);

  Uri operation(String name) => Uri.parse('$codeAssistBase/$name');

  String redirectUri(int port) => 'http://127.0.0.1:$port/oauth2callback';
}

const geminiCodeAssistModels = <RemoteModel>[
  RemoteModel('gemini-3.1-pro-preview', label: 'Gemini 3.1 Pro Preview', contextWindow: 1000000, efforts: [], images: true),
  RemoteModel('gemini-3-pro-preview', label: 'Gemini 3 Pro Preview', contextWindow: 1000000, efforts: [], images: true),
  RemoteModel('gemini-2.5-pro', label: 'Gemini 2.5 Pro', contextWindow: 1000000, efforts: [], images: true),
  RemoteModel('gemini-3.5-flash', label: 'Gemini 3.5 Flash', contextWindow: 1000000, efforts: [], images: true),
  RemoteModel('gemini-3-flash', label: 'Gemini 3 Flash', contextWindow: 1000000, efforts: [], images: true),
  RemoteModel('gemini-3.1-flash-lite', label: 'Gemini 3.1 Flash Lite', contextWindow: 1000000, efforts: [], images: true),
];

Map<String, String> geminiHeaders(String accessToken, {bool events = false}) => {
  'authorization': 'Bearer $accessToken',
  'user-agent': geminiCodeAssistUserAgent,
  'content-type': 'application/json',
  'accept': events ? 'text/event-stream' : 'application/json',
};
