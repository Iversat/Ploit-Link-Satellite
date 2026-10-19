from PIL import Image, ImageDraw, ImageFilter
from pathlib import Path
import json, math
folder=Path('Resources/Assets.xcassets/AppIcon.appiconset')
folder.mkdir(parents=True,exist_ok=True)
n=1024
im=Image.new('RGB',(n,n),(4,11,23))
d=ImageDraw.Draw(im)
for r in range(750,0,-1):
    v=1-r/750
    d.ellipse((512-r,750-r,512+r,750+r),fill=(int(4+5*v),int(11+27*v),int(23+40*v)))
orbit=Image.new('RGBA',(n,n));o=ImageDraw.Draw(orbit)
o.arc((122,280,902,690),195,533,fill=(105,194,239,160),width=6)
orbit=orbit.rotate(-34,resample=Image.Resampling.BICUBIC)
im.paste(orbit,(0,0),orbit)
sat=Image.new('RGBA',(n,n));s=ImageDraw.Draw(sat)
s.rounded_rectangle((436,402,588,606),radius=25,fill=(241,246,252),outline=(255,255,255),width=3)
for x in (228,616):
    s.rounded_rectangle((x,425,x+180,583),radius=12,fill=(49,126,179),outline=(124,203,248),width=6)
    for i in range(1,4):s.line((x+i*45,426,x+i*45,582),fill=(120,195,237),width=3)
    for y in (478,530):s.line((x,y,x+180,y),fill=(120,195,237),width=3)
s.line((408,500,436,500),fill='white',width=10);s.line((588,500,616,500),fill='white',width=10)
s.line((512,402,512,341),fill='white',width=9)
s.ellipse((495,316,529,350),fill='white')
sat=sat.rotate(38,resample=Image.Resampling.BICUBIC)
im.paste(sat,(0,0),sat)
d=ImageDraw.Draw(im)
for x,y,r in [(194,183,3),(782,190,2),(842,788,3),(220,774,2)]:d.ellipse((x-r,y-r,x+r,y+r),fill=(193,222,241))
im.save(folder/'AppIcon.png')
(folder/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
(folder.parent/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}')
