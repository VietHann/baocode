import 'dart:convert';

/// Adapts Google Antigravity SSE chunks to OpenAI Chat Completions-shaped
/// chunks. BaoCode's existing OpenAI -> Claude response translator then emits
/// the Anthropic Messages response Claude Code expects.
class GeminiResponseAdapter {
  GeminiResponseAdapter({required this.model, required this.stream});

  final String model;
  final bool stream;

  final StringBuffer _text = StringBuffer();
  final List<Map<String, Object?>> _calls = [];
  Map<String, Object?>? _usage;
  String? _finish;
  String? _id;
  int _callIndex = 0;
  bool _nonStreamEmitted = false;

  Iterable<String> convert(String line) sync* {
    if (!line.startsWith('data:')) return;
    final data = line.substring(5).trim();
    if (data.isEmpty || data == '[DONE]') return;

    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final root = Map<String, Object?>.from(decoded);
    final wrapped = root['response'];
    final response = wrapped is Map ? Map<String, Object?>.from(wrapped) : root;

    _id ??=
        '${root['traceId'] ?? root['requestId'] ?? 'antigravity-${DateTime.now().microsecondsSinceEpoch}'}';
    final modelVersion = '${response['modelVersion'] ?? model}';
    final delta = <String, Object?>{};

    final candidates = response['candidates'];
    Map? candidate;
    if (candidates is List &&
        candidates.isNotEmpty &&
        candidates.first is Map) {
      candidate = candidates.first as Map;
    }
    final content = candidate?['content'];
    final parts = content is Map ? content['parts'] : null;
    if (parts is List) {
      final text = StringBuffer();
      final toolCalls = <Map<String, Object?>>[];
      for (final raw in parts) {
        if (raw is! Map) continue;
        if (raw['thought'] == true) continue;
        if (raw['text'] case final String value when value.isNotEmpty) {
          text.write(value);
          _text.write(value);
        }
        if (raw['functionCall'] case final Map fn) {
          final name = '${fn['name'] ?? ''}';
          if (name.isEmpty) continue;
          final index = _callIndex++;
          final id = switch (fn['id']) {
            final String value when value.isNotEmpty => value,
            _ => 'agcall_$index',
          };
          final args = fn['args'] is Map
              ? fn['args']
              : const <String, Object?>{};
          final call = <String, Object?>{
            'index': index,
            'id': id,
            'type': 'function',
            'function': {'name': name, 'arguments': jsonEncode(args)},
          };
          toolCalls.add(call);
          _calls.add(call);
        }
      }
      if (text.isNotEmpty) delta['content'] = text.toString();
      if (toolCalls.isNotEmpty) delta['tool_calls'] = toolCalls;
    }

    if (candidate?['finishReason'] case final String reason
        when reason.isNotEmpty) {
      _finish = _finishReason(reason, _calls.isNotEmpty);
    }
    _usage = _openAiUsage(response['usageMetadata']) ?? _usage;

    if (!stream) return;
    if (delta.isEmpty && _finish == null && _usage == null) return;
    yield 'data: ${jsonEncode({
      'id': _id,
      'object': 'chat.completion.chunk',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': modelVersion,
      'choices': [
        {'index': 0, 'delta': delta, if (_finish != null) 'finish_reason': _finish},
      ],
      if (_usage != null) 'usage': _usage,
    })}';
  }

  Iterable<String> finish() sync* {
    if (stream) {
      yield 'data: [DONE]';
      return;
    }
    if (_nonStreamEmitted) return;
    _nonStreamEmitted = true;
    yield 'data: ${jsonEncode({
      'id': _id ?? 'antigravity-${DateTime.now().microsecondsSinceEpoch}',
      'object': 'chat.completion',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': model,
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': _text.toString(), if (_calls.isNotEmpty) 'tool_calls': _calls},
          'finish_reason': _finish ?? (_calls.isNotEmpty ? 'tool_calls' : 'stop'),
        },
      ],
      if (_usage != null) 'usage': _usage,
    })}';
  }
}

String _finishReason(String value, bool hasCalls) =>
    switch (value.toUpperCase()) {
      'MAX_TOKENS' => 'length',
      'SAFETY' ||
      'RECITATION' ||
      'BLOCKLIST' ||
      'PROHIBITED_CONTENT' => 'content_filter',
      'STOP' when hasCalls => 'tool_calls',
      'STOP' => 'stop',
      _ when hasCalls => 'tool_calls',
      _ => 'stop',
    };

Map<String, Object?>? _openAiUsage(Object? value) {
  if (value is! Map) return null;
  int read(String key) => switch (value[key]) {
    final num number => number.toInt(),
    _ => 0,
  };
  final prompt = read('promptTokenCount');
  final output = read('candidatesTokenCount') + read('thoughtsTokenCount');
  final total = read('totalTokenCount');
  final cached = read('cachedContentTokenCount');
  if (prompt == 0 && output == 0 && total == 0 && cached == 0) return null;
  return {
    'prompt_tokens': prompt,
    'completion_tokens': output,
    'total_tokens': total == 0 ? prompt + output : total,
    if (cached > 0) 'prompt_tokens_details': {'cached_tokens': cached},
  };
}
