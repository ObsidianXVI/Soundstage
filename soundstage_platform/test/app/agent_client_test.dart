import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/agent/agent_client.dart';
import 'package:soundstage_platform/editor/agent/agent_transport.dart';

typedef _Call = ({
  String method,
  String url,
  Map<String, String> headers,
  String? body,
});

void main() {
  late List<_Call> calls;
  late (int, String) Function(_Call) answer;
  late List<(String, int, int)> drawn;

  AgentServiceClient client({String? token = 'tok'}) => AgentServiceClient(
    baseUrl: 'https://agent.test',
    idToken: () async => token,
    readConfig: () => const AgentConfig(
      claudeModel: 'claude-opus-5-5',
      quiverModel: 'arrow-2',
    ),
    send: (method, url, {headers = const {}, body}) async {
      final c = (method: method, url: url, headers: headers, body: body);
      calls.add(c);
      return answer(c);
    },
    rasterize: (svg, w, h) async {
      drawn.add((svg, w, h));
      return Uint8List.fromList([1, 2]);
    },
  );

  setUp(() {
    calls = [];
    drawn = [];
    answer = (_) => (200, '{"content": [], "stop_reason": "end_turn"}');
  });

  test('Claude requests carry the model and the ID token', () async {
    final r = await client().claude({'max_tokens': 10, 'messages': []});
    expect(r['stop_reason'], 'end_turn');
    final c = calls.single;
    expect(c.method, 'POST');
    expect(c.url, 'https://agent.test/anthropic/messages');
    expect(c.headers['authorization'], 'Bearer tok');
    expect(jsonDecode(c.body!), {
      'max_tokens': 10,
      'messages': <Object?>[],
      'model': 'claude-opus-5-5',
    });
  });

  test('errors become messages; a missing key says so', () async {
    answer = (_) => (412, '{"error": {"message": "Add your anthropic key."}}');
    await expectLater(
      client().claude({'messages': []}),
      throwsA(
        isA<AgentException>()
            .having((e) => e.needsKey, 'needsKey', isTrue)
            .having((e) => e.message, 'message', 'Add your anthropic key.'),
      ),
    );
    answer = (_) => (529, 'overloaded');
    await expectLater(
      client().claude({'messages': []}),
      throwsA(
        isA<AgentException>().having(
          (e) => e.message,
          'message',
          contains('529'),
        ),
      ),
    );
    await expectLater(
      client(token: null).claude({'messages': []}),
      throwsA(isA<AgentException>()),
    );
  });

  test('illustrations: Quiver SVG drawn at twice the layer size', () async {
    answer = (_) => (
      200,
      jsonEncode({
        'id': 'resp_1',
        'created': 1,
        'data': [
          {'mime_type': 'image/svg+xml', 'svg': '<svg/>'},
        ],
      }),
    );
    final png = await client().illustrate(
      'a lighthouse',
      width: 300,
      height: 200,
    );
    expect(png, [1, 2]);
    final body = jsonDecode(calls.single.body!) as Map;
    expect(calls.single.url, 'https://agent.test/quiver/svgs/generations');
    expect(body['model'], 'arrow-2');
    expect(body['prompt'], 'a lighthouse');
    expect(body['attributes'], {
      'viewBox': {'minX': 0, 'minY': 0, 'width': 300.0, 'height': 200.0},
    });
    expect(drawn.single, ('<svg/>', 600, 400));
    answer = (_) => (200, '{"data": []}');
    await expectLater(client().illustrate('x'), throwsA(isA<AgentException>()));
  });

  test('keys', () async {
    answer = (c) =>
        (200, c.method == 'GET' ? '{"set": true}' : '{"set": false}');
    expect(await client().hasKey('quiver'), isTrue);
    await client().setKey('anthropic', 'sk');
    await client().removeKey('anthropic');
    expect(
      [for (final c in calls) '${c.method} ${c.url}'],
      [
        'GET https://agent.test/keys/quiver',
        'PUT https://agent.test/keys/anthropic',
        'DELETE https://agent.test/keys/anthropic',
      ],
    );
    expect(jsonDecode(calls[1].body!), {'key': 'sk'});
  });
}
