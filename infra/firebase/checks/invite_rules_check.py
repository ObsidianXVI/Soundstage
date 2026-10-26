# Invite-only rules check (m7.md T7.1) against the emulators:
#   firebase emulators:start --only auth,firestore,storage --project demo-soundstage
#   python3 -I infra/firebase/checks/invite_rules_check.py
import json, urllib.request, urllib.error
P='demo-soundstage'
A='http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1'
F=f'http://127.0.0.1:8085/v1/projects/{P}/databases/(default)/documents'
S='http://127.0.0.1:9199/v0/b/demo-soundstage.appspot.com/o'
def req(method,url,body=None,headers={},raw=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r=urllib.request.Request(url,data=data,method=method,headers={'content-type':'application/json',**headers})
    try:
        with urllib.request.urlopen(r) as x: return x.status, json.loads(x.read() or b'{}')
    except urllib.error.HTTPError as e: return e.code, e.read().decode()[:120]
def signup(email):
    s,b=req('POST',A+'/accounts:signUp?key=k',{'email':email,'password':'pw-123456','returnSecureToken':True}); return b
def signin(email):
    s,b=req('POST',A+'/accounts:signInWithPassword?key=k',{'email':email,'password':'pw-123456','returnSecureToken':True}); return b['idToken']
def verify(uid):
    print(' verify', req('POST',f'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/projects/{P}/accounts:update',{'localId':uid,'emailVerified':True},{'authorization':'Bearer owner'})[0])
def probe(uid,tok): return req('GET',f'{F}/members/{uid}',headers={'authorization':'Bearer '+tok})[0]
def upload(uid,tok): return req('POST',f'{S}?name=published%2F{uid}%2Fx%2Fa.txt',headers={'authorization':'Firebase '+tok,'content-type':'text/plain'},raw=b'hi')[0]
def story(uid,tok,i): return req('PATCH',f'{F}/stories/s{i}',{'fields':{'ownerId':{'stringValue':uid},'title':{'stringValue':'t'}}},{'authorization':'Bearer '+tok})[0]
a=signup('Author@Example.com'); uid=a['localId']; tok=a['idToken']
print('before invite: probe',probe(uid,tok),'upload',upload(uid,tok),'story',story(uid,tok,1))
print('invite', req('PATCH',f'{F}/config/invites',{'fields':{'emails':{'arrayValue':{'values':[{'stringValue':'author@example.com'}]}}}},{'authorization':'Bearer owner'})[0])
print('invited, unverified: probe',probe(uid,tok),'upload',upload(uid,tok),'story',story(uid,tok,2))
verify(uid); tok=signin('author@example.com')
print('invited, verified: probe',probe(uid,tok),'upload',upload(uid,tok),'story',story(uid,tok,3))
b=signup('other@example.com'); verify(b['localId']); t2=signin('other@example.com')
print('verified, not invited: probe',probe(b['localId'],t2),'upload',upload(b['localId'],t2),'story',story(b['localId'],t2,4))
print('read invites as author:', req('GET',f'{F}/config/invites',headers={'authorization':'Bearer '+tok})[0])
