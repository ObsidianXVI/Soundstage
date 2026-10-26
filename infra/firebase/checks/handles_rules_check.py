# Handles and sites rules check (m7.md T7.2) against the emulators:
#   firebase emulators:start --only auth,firestore,storage --project demo-soundstage
#   python3 -I infra/firebase/checks/handles_rules_check.py
import json, urllib.request, urllib.error, uuid
P = 'demo-soundstage'
A = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1'
ROOT = f'projects/{P}/databases/(default)/documents'
F = f'http://127.0.0.1:8085/v1/{ROOT}'


def req(method, url, body=None, headers={}):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method,
                               headers={'content-type': 'application/json', **headers})
    try:
        with urllib.request.urlopen(r) as x:
            return x.status
    except urllib.error.HTTPError as e:
        return e.code


def author(email, invite=True):
    req('POST', A + '/accounts:signUp?key=k', {'email': email, 'password': 'pw-123456'})
    r = urllib.request.urlopen(urllib.request.Request(
        A + '/accounts:signInWithPassword?key=k', method='POST',
        data=json.dumps({'email': email, 'password': 'pw-123456', 'returnSecureToken': True}).encode(),
        headers={'content-type': 'application/json'}))
    uid = json.loads(r.read())['localId']
    req('POST', f'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/projects/{P}/accounts:update',
        {'localId': uid, 'emailVerified': True}, {'authorization': 'Bearer owner'})
    r = urllib.request.urlopen(urllib.request.Request(
        A + '/accounts:signInWithPassword?key=k', method='POST',
        data=json.dumps({'email': email, 'password': 'pw-123456', 'returnSecureToken': True}).encode(),
        headers={'content-type': 'application/json'}))
    return uid, json.loads(r.read())['idToken']


def s(v): return {'stringValue': v}


def claim(uid, tok, handle):
    return req('POST', f'{F}:commit', {'writes': [
        {'update': {'name': f'{ROOT}/handles/{handle}', 'fields': {'ownerId': s(uid), 'name': s('')}}},
        {'update': {'name': f'{ROOT}/profiles/{uid}', 'fields': {'handle': s(handle), 'name': s('')}}},
    ]}, {'authorization': 'Bearer ' + tok})


def record(uid, story, version=1):
    return {'fields': {'ownerId': s(uid), 'storyId': s(story), 'version': {'integerValue': str(version)},
                       'path': s('p'), 'versions': {'arrayValue': {}}}}


def put(path, tok, body):
    return req('PATCH', f'{F}/{path}', body, {'authorization': 'Bearer ' + tok})


tag = uuid.uuid4().hex[:6]
emails = [f'a-{tag}@example.com', f'b-{tag}@example.com', f'c-{tag}@example.com']
req('PATCH', f'{F}/config/invites', {'fields': {'emails': {'arrayValue': {'values': [s(e) for e in emails[:2]]}}}},
    {'authorization': 'Bearer owner'})
ua, ta = author(emails[0])
ub, tb = author(emails[1])
uc, tc = author(emails[2])
ha, hb = f'ada-{tag}', f'bob-{tag}'
checks = {
    'claim own handle': (claim(ua, ta, ha), 200),
    'claim a second handle': (claim(ua, ta, f'two-{tag}'), 403),
    'claim a taken handle': (claim(ub, tb, ha), 403),
    'claim a reserved handle': (claim(ub, tb, 'admin'), 403),
    'claim while not invited': (claim(uc, tc, f'cy-{tag}'), 403),
    'claim own handle (b)': (claim(ub, tb, hb), 200),
    'publish a draft under own handle': (put(f'sites/{ha}/drafts/walk', ta, record(ua, 'st')), 200),
    'publish under another handle': (put(f'sites/{ha}/drafts/x', tb, record(ub, 'st')), 403),
    'replace the draft with another story': (put(f'sites/{ha}/drafts/walk', ta, record(ua, 'other')), 403),
    'make an older version live': (put(f'sites/{ha}/drafts/walk', ta, record(ua, 'st', 0)), 200),
    'create a publication': (put(f'sites/{ha}/publications/weekly', ta, {'fields': {
        'ownerId': s(ua), 'projectId': s('p'), 'title': s('W'), 'issues': {'arrayValue': {}}}}), 200),
    'create the reserved publication s': (put(f'sites/{ha}/publications/s', ta, {'fields': {
        'ownerId': s(ua), 'projectId': s('p'), 'issues': {'arrayValue': {}}}}), 403),
    'publish an issue': (put(f'sites/{ha}/publications/weekly/issues/one', ta, record(ua, 'i1')), 200),
    'read a draft signed out': (req('GET', f'{F}/sites/{ha}/drafts/walk'), 200),
    'read a handle signed out': (req('GET', f'{F}/handles/{ha}'), 200),
}
bad = 0
for name, (got, want) in checks.items():
    ok = got == want
    bad += not ok
    print(('ok  ' if ok else 'FAIL'), name, got)
raise SystemExit(bad)
