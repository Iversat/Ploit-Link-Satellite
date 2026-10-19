import plistlib, sys, zipfile, json
with zipfile.ZipFile(sys.argv[1]) as z:
    plist = plistlib.loads(z.read('Payload/PloitSatellite.app/Info.plist'))
    binary = z.read('Payload/PloitSatellite.app/' + plist['CFBundleExecutable'])
    assert binary[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'), 'Not a Mach-O executable'
    assert plist['CFBundleIdentifier'] == 'ru.ploit.satellite'
    for name in ['catalog.json', 'seed-tle.json', 'satellite.min.js', 'orbit.js', 'earth-night.jpg']:
        assert len(z.read('Payload/PloitSatellite.app/' + name)) > 0, name
    assert 'NSLocationWhenInUseUsageDescription' in plist
    assert 'NSMotionUsageDescription' in plist
    print(json.dumps({'ipa_verified':True,'bundle':plist['CFBundleIdentifier'],'executable_bytes':len(binary),'signed':False}))
