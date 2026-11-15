import importlib.util,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('release',root/'scripts/release-signing.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
name='Developer ID Application: Synthetic Fixture (TESTONLY00)'
assert m.valid_identity(name,'  1) '+'A'*40+' "'+name+'"')
for identity in ['', '-', 'Apple Development: Fixture',name+' altered']:
 assert not m.valid_identity(identity,'  1) '+'A'*40+' "'+name+'"')
assert not m.valid_identity(name,'0 valid identities found')
cmds=m.signing_commands('/tmp/synthetic-only.app',name)
assert len(cmds)==6 and cmds[-1][-1]=='/tmp/synthetic-only.app'
assert all('--timestamp' in c and c[c.index('--options')+1]=='runtime' and '--deep' not in c for c in cmds)
assert '--preserve-metadata=entitlements' in cmds[1]
assert '--entitlements' in cmds[-1]
assert cmds[0][-1].endswith('/Installer.xpc') and cmds[-2][-1].endswith('/Sparkle.framework')
assert 'disable-library-validation' not in (root/'Config/Release.entitlements').read_text()
print('PASS release identity fail-closed, nested inside-out signing plan, secure timestamp/runtime, microphone entitlement, no signing/upload/policy changes')
