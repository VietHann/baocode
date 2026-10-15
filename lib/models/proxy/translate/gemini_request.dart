import 'dart:convert';

import 'openai_chat_request.dart';

/// Claude Messages -> Google Antigravity GenerateContent request body.
Map<String, Object?> convertClaudeRequestToGemini(
  String model,
  Map<String, Object?> request, {
  String? session,
}) {
  final openai = convertClaudeRequestToOpenAI(
    model,
    request,
    true,
    preserveThinking: false,
  );

  final rawContents = <Map<String, Object?>>[];
  final systemParts = <Map<String, Object?>>[];
  final toolNameById = <String, String>{};

  final messages = openai['messages'];
  if (messages is List) {
    for (final raw in messages) {
      if (raw is! Map) continue;
      final role = '${raw['role'] ?? ''}';
      final parts = <Map<String, Object?>>[];

      if (role == 'system') {
        _contentParts(raw['content'], systemParts);
        continue;
      }

      if (role == 'assistant') {
        _contentParts(raw['content'], parts);
        final calls = raw['tool_calls'];
        if (calls is List) {
          for (final call in calls) {
            if (call is! Map) continue;
            final id = '${call['id'] ?? ''}';
            final fn = call['function'];
            if (fn is! Map) continue;
            final name = '${fn['name'] ?? ''}';
            if (name.isEmpty) continue;
            if (id.isNotEmpty) toolNameById[id] = name;
            parts.add({
              'functionCall': {
                'name': name,
                'args': _jsonObject(fn['arguments']),
              },
              // Antigravity validates thought signatures on replayed tool calls.
              // Its own client accepts this sentinel when no signature was kept.
              'thoughtSignature': 'skip_thought_signature_validator',
            });
          }
        }
        if (parts.isNotEmpty) {
          rawContents.add({'role': 'model', 'parts': parts});
        }
        continue;
      }

      if (role == 'tool') {
        final id = '${raw['tool_call_id'] ?? ''}';
        final name = '${raw['name'] ?? toolNameById[id] ?? 'function'}';
        final value = _jsonValue(raw['content']);
        rawContents.add({
          'role': 'user',
          'parts': [
            {
              'functionResponse': {
                'name': name,
                'response': value is Map
                    ? Map<String, Object?>.from(value)
                    : {'result': value},
              },
            },
          ],
        });
        continue;
      }

      _contentParts(raw['content'], parts);
      if (parts.isEmpty) parts.add({'text': ' '});
      rawContents.add({'role': 'user', 'parts': parts});
    }
  }

  // CloudCode expects user/model turns to alternate. Merge adjacent messages
  // of the same role rather than manufacturing extra model turns.
  final contents = <Map<String, Object?>>[];
  for (final item in rawContents) {
    final role = '${item['role']}';
    final parts = item['parts'] as List;
    if (contents.isNotEmpty && contents.last['role'] == role) {
      (contents.last['parts'] as List).addAll(parts);
    } else {
      contents.add({
        'role': role,
        'parts': List<Map<String, Object?>>.from(parts),
      });
    }
  }
  if (contents.isNotEmpty && contents.first['role'] != 'user') {
    contents.insert(0, {
      'role': 'user',
      'parts': [
        {'text': ' '},
      ],
    });
  }

  final requestBody = <String, Object?>{
    'contents': contents,
    if (systemParts.isNotEmpty)
      'systemInstruction': {'role': 'system', 'parts': systemParts},
  };

  final config = <String, Object?>{
    'maxOutputTokens': switch (openai['max_tokens']) {
      final num value when value > 0 => value.toInt(),
      _ => 65536,
    },
  };
  if (openai['temperature'] case final num value) config['temperature'] = value;
  if (openai['top_p'] case final num value) config['topP'] = value;
  switch (openai['stop']) {
    case final String stop when stop.isNotEmpty:
      config['stopSequences'] = [stop];
    case final List stops when stops.isNotEmpty:
      config['stopSequences'] = [for (final stop in stops) '$stop'];
  }
  requestBody['generationConfig'] = config;

  final tools = openai['tools'];
  if (tools is List) {
    final declarations = <Map<String, Object?>>[];
    for (final raw in tools) {
      if (raw is! Map || raw['function'] is! Map) continue;
      final fn = raw['function'] as Map;
      final name = '${fn['name'] ?? ''}';
      if (name.isEmpty) continue;
      declarations.add({
        'name': name,
        if ('${fn['description'] ?? ''}'.isNotEmpty)
          'description': '${fn['description']}',
        'parameters': _sanitizeSchema(fn['parameters']),
      });
    }
    if (declarations.isNotEmpty) {
      requestBody['tools'] = [
        {'functionDeclarations': declarations},
      ];
      requestBody['toolConfig'] = {
        'functionCallingConfig': {'mode': 'AUTO'},
      };
    }
  }

  if (openai['tool_choice'] case final choice?) {
    final functionCalling = <String, Object?>{};
    switch (choice) {
      case 'none':
        functionCalling['mode'] = 'NONE';
      case 'required':
        functionCalling['mode'] = 'ANY';
      case 'auto':
        functionCalling['mode'] = 'AUTO';
      case final Map map:
        final fn = map['function'];
        final name = fn is Map ? '${fn['name'] ?? ''}' : '';
        functionCalling['mode'] = 'ANY';
        if (name.isNotEmpty) functionCalling['allowedFunctionNames'] = [name];
      default:
        functionCalling['mode'] = 'AUTO';
    }
    requestBody['toolConfig'] = {'functionCallingConfig': functionCalling};
  }

  // The outer Antigravity envelope (project, requestId, credit type, model)
  // is added by GeminiAccounts, where the signed-in account/project is known.
  return {'model': model, 'request': requestBody};
}

void _contentParts(Object? content, List<Map<String, Object?>> out) {
  if (content is String) {
    if (content.isNotEmpty) out.add({'text': content});
    return;
  }
  if (content is! List) return;
  for (final raw in content) {
    if (raw is! Map) continue;
    switch ('${raw['type'] ?? ''}') {
      case 'text':
        final text = '${raw['text'] ?? ''}';
        if (text.isNotEmpty) out.add({'text': text});
      case 'image_url':
        final image = raw['image_url'];
        final url = image is Map ? '${image['url'] ?? ''}' : '';
        final inline = _inlineData(url);
        if (inline != null) out.add({'inlineData': inline});
    }
  }
}

Map<String, Object?>? _inlineData(String url) {
  final match = RegExp(r'^data:([^;,]+);base64,(.+)$', dotAll: true).firstMatch(url);
  if (match == null) return null;
  return {'mimeType': match.group(1)!, 'data': match.group(2)!};
}

Object? _jsonValue(Object? value) {
  if (value is! String) return value;
  final text = value.trim();
  if (text.isEmpty) return '';
  try {
    return jsonDecode(text);
  } on FormatException {
    return value;
  }
}

Map<String, Object?> _jsonObject(Object? value) {
  final decoded = _jsonValue(value);
  return decoded is Map
      ? Map<String, Object?>.from(decoded)
      : <String, Object?>{};
}

const _unsupportedSchemaKeys = {
  r'$schema',
  r'$ref',
  r'$defs',
  r'$comment',
  'examples',
  'unevaluatedProperties',
  'unevaluatedItems',
  'patternProperties',
  'propertyNames',
  'exclusiveMinimum',
  'exclusiveMaximum',
  'multipleOf',
  'dependencies',
  'dependentSchemas',
  'dependentRequired',
  'deprecated',
  'readOnly',
  'writeOnly',
  'x-mcp-header',
  'const',
  'default',
  'additionalProperties',
  'title',
  'format',
};

const _protoTypes = {
  'string': 'STRING',
  'number': 'NUMBER',
  'integer': 'INTEGER',
  'boolean': 'BOOLEAN',
  'array': 'ARRAY',
  'object': 'OBJECT',
};

Object _sanitizeSchema(Object? value) {
  if (value is List) return [for (final item in value) _sanitizeSchema(item)];
  if (value is! Map) return value ?? <String, Object?>{};
  final out = <String, Object?>{};
  for (final entry in value.entries) {
    final key = '${entry.key}';
    if (_unsupportedSchemaKeys.contains(key)) continue;
    final child = entry.value;
    if (key == 'type' && child is String) {
      out[key] = _protoTypes[child.toLowerCase()] ?? child.toUpperCase();
    } else {
      out[key] = _sanitizeSchema(child);
    }
  }
  if (!out.containsKey('type') && out.containsKey('properties')) {
    out['type'] = 'OBJECT';
  }
  if (out.isEmpty) {
    return <String, Object?>{'type': 'OBJECT', 'properties': <String, Object?>{}};
  }
  return out;
}
