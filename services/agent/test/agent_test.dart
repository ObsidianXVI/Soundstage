import 'package:soundstage_agent/agent.dart';
import 'package:test/test.dart';

void main() {
  test('routes', () {
    expect(Route.parse('GET', '/keys/anthropic'), isA<KeyStatus>());
    expect(Route.parse('PUT', '/keys/quiver'), isA<PutKey>());
    expect(Route.parse('DELETE', '/keys/quiver'), isA<DeleteKey>());
    expect(Route.parse('POST', '/anthropic/messages'), isA<Forward>());
    expect(Route.parse('POST', '/quiver/svgs/generations'), isA<Forward>());
    expect(Route.parse('POST', '/quiver/svgs/edits'), isNull);
    expect(Route.parse('GET', '/anthropic/messages'), isNull);
    expect(Route.parse('PUT', '/keys/openai'), isNull);
  });

  test('secret ids', () {
    expect(
      secretIdFor('ZSI7RTyMt2Nw', Provider.anthropic),
      'agent-ZSI7RTyMt2Nw-anthropic',
    );
    expect(secretIdFor('a/b.c', Provider.quiver), 'agent-a_b_c-quiver');
  });

  test('origins', () {
    const site = ['https://project-soundstage.web.app'];
    expect(originAllowed('https://project-soundstage.web.app', site), isTrue);
    expect(originAllowed('http://localhost:8766', site), isTrue);
    expect(originAllowed('http://127.0.0.1:5000', site), isTrue);
    expect(originAllowed('https://evil.example', site), isFalse);
    expect(originAllowed('https://localhost.evil.example', site), isFalse);
    expect(originAllowed(null, site), isFalse);
  });

  test('bodies', () {
    expect(
      checkBody(Provider.anthropic, {'model': 'm', 'messages': []}),
      isNull,
    );
    expect(checkBody(Provider.anthropic, {'messages': []}), isNotNull);
    expect(checkBody(Provider.anthropic, {'model': 'm'}), isNotNull);
    expect(
      checkBody(Provider.quiver, {'model': 'arrow-2', 'prompt': 'a'}),
      isNull,
    );
    expect(checkBody(Provider.quiver, {'model': 'arrow-2'}), isNotNull);
    expect(checkBody(Provider.quiver, 'x'), isNotNull);
  });

  test('provider headers', () {
    expect(providerHeaders(Provider.anthropic, 'k'), {
      'x-api-key': 'k',
      'anthropic-version': '2026-10-21',
      'content-type': 'application/json',
    });
    expect(providerHeaders(Provider.quiver, 'k')['authorization'], 'Bearer k');
  });
}
