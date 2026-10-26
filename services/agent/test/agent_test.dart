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

  test('invite list from the Firestore document', () {
    final doc = {
      'fields': {
        'emails': {
          'arrayValue': {
            'values': [
              {'stringValue': ' Author@Example.com '},
              {'integerValue': '3'},
            ],
          },
        },
      },
    };
    expect(inviteEmails(doc), {'author@example.com'});
    expect(inviteEmails({'fields': {}}), isEmpty);
    expect(inviteEmails(null), isEmpty);
  });

  test('only a verified, listed email is invited', () {
    const list = {'author@example.com'};
    expect(
      isInvited(email: 'AUTHOR@example.com', verified: true, invites: list),
      isTrue,
    );
    expect(
      isInvited(email: 'author@example.com', verified: false, invites: list),
      isFalse,
    );
    expect(
      isInvited(email: 'other@example.com', verified: true, invites: list),
      isFalse,
    );
    expect(isInvited(email: null, verified: true, invites: list), isFalse);
  });

  test('domain routes and names', () {
    expect(Route.parse('GET', '/domains'), isA<ListDomains>());
    expect(Route.parse('POST', '/domains'), isA<AddDomain>());
    expect(
      (Route.parse('DELETE', '/domains/news.example.com')! as RemoveDomain)
          .host,
      'news.example.com',
    );
    expect(Route.parse('DELETE', '/domains/Bad_Host'), isNull);
    expect(Route.parse('PUT', '/domains'), isNull);
    expect(isValidDomain('example.com'), isTrue);
    expect(isValidDomain('www.client.co.uk'), isTrue);
    expect(isValidDomain('Example.com'), isFalse);
    expect(isValidDomain('localhost'), isFalse);
    expect(isValidDomain('x.web.app'), isFalse);
    expect(isValidDomain('a.firebaseapp.com'), isFalse);
    expect(isValidDomain('-a.com'), isFalse);
  });

  test('a Hosting custom domain as the app shows it', () {
    expect(domainSummary('a.com', null)['state'], 'pending');
    final dns = domainSummary('a.com', {
      'hostState': 'HOST_UNHOSTED',
      'ownershipState': 'OWNERSHIP_MISSING',
      'cert': {'state': 'CERT_PREPARING'},
      'requiredDnsUpdates': {
        'desired': [
          {
            'domainName': 'a.com',
            'records': [
              {
                'domainName': 'a.com',
                'type': 'A',
                'rdata': '199.36.158.100',
                'requiredAction': 'ADD',
              },
              {
                'domainName': 'a.com',
                'type': 'TXT',
                'rdata': 'hosting-site=x',
                'requiredAction': 'ADD',
              },
              {
                'domainName': 'a.com',
                'type': 'A',
                'rdata': '1.2.3.4',
                'requiredAction': 'NONE',
              },
            ],
          },
        ],
      },
      'issues': [
        {'message': 'DNS not found'},
      ],
    });
    expect(dns['state'], 'dns');
    expect((dns['records']! as List).length, 2);
    expect((dns['records']! as List).first, {
      'action': 'ADD',
      'name': 'a.com',
      'type': 'A',
      'value': '199.36.158.100',
    });
    expect(dns['issues'], ['DNS not found']);
    final live = domainSummary('a.com', {
      'hostState': 'HOST_ACTIVE',
      'ownershipState': 'OWNERSHIP_ACTIVE',
      'cert': {'state': 'CERT_ACTIVE'},
    });
    expect(live['state'], 'live');
  });
}
