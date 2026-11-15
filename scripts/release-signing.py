#!/usr/bin/env python3
"""Local-only release signing support. Never submits, exports keys, or changes policy."""
import argparse, os, pathlib, re, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parent.parent

def run(args):
    return subprocess.run(args,check=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

def valid_identity(identity,listing):
    if not identity or identity=='-' or not identity.startswith('Developer ID Application: '):return False
    return any(re.match(r'^\s*\d+\) [0-9A-Fa-f]{40} "'+re.escape(identity)+r'"\s*$',line) for line in listing.splitlines())

def preflight(identity):
    listing=run(['/usr/bin/security','find-identity','-v','-p','codesigning']).stdout
    if not valid_identity(identity,listing):raise ValueError('A matching valid Developer ID Application identity is required. No build or signing performed.')
    for tool in ['notarytool','stapler']:run(['/usr/bin/xcrun','--find',tool])

def signing_commands(app,identity):
    app=pathlib.Path(app); framework=app/'Contents/Frameworks/Sparkle.framework';base=framework/'Versions/B'
    paths=[base/'XPCServices/Installer.xpc',base/'XPCServices/Downloader.xpc',base/'Autoupdate',base/'Updater.app',framework,app]
    commands=[]
    for p in paths:
        cmd=['/usr/bin/codesign','--force','--sign',identity,'--options','runtime','--timestamp']
        if p.name=='Downloader.xpc':cmd+=['--preserve-metadata=entitlements']
        if p==app:cmd+=['--entitlements',str(ROOT/'Config/Release.entitlements')]
        commands.append(cmd+[str(p)])
    return commands

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['preflight','sign','verify-notarized'])
    parser.add_argument('app',nargs='?');args=parser.parse_args()
    identity=os.environ.get('SIGN_IDENTITY','')
    if args.mode in ['preflight','sign']:preflight(identity)
    if args.mode=='sign':
        if not args.app:raise ValueError('App path required')
        commands=signing_commands(args.app,identity)
        for cmd in commands:
            if not pathlib.Path(cmd[-1]).exists():raise ValueError('Required nested code missing; nothing signed')
        for cmd in commands:run(cmd)
        run(['/usr/bin/codesign','--verify','--deep','--strict',args.app])
        info=run(['/usr/bin/codesign','--display','--verbose=4',args.app]).stderr
        if 'runtime' not in info or 'Timestamp=' not in info or 'Authority=Developer ID Application:' not in info:raise ValueError('Release signature requirements not met')
        print('SIGNED ONLY: Apple notarization and final Gatekeeper assessment are still required.')
    elif args.mode=='verify-notarized':
        if not args.app:raise ValueError('App path required')
        run(['/usr/bin/codesign','--verify','--deep','--strict',args.app])
        run(['/usr/bin/xcrun','stapler','validate',args.app])
        run(['/usr/sbin/spctl','--assess','--type','execute','--verbose=2',args.app])
        print('PASS stapled ticket and current Gatekeeper assessment; no application was launched.')
    else:print('PASS signing identity and notarization tool availability; no credentials accessed or upload performed.')
if __name__=='__main__':
    try:main()
    except (ValueError,subprocess.CalledProcessError) as error:
        print('BLOCKED:',error if isinstance(error,ValueError) else (error.stderr.strip() or 'Required tool failed'),file=sys.stderr);sys.exit(1)
