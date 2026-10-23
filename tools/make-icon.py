from PIL import Image, ImageDraw
from pathlib import Path
import json

folder=Path('Resources/Assets.xcassets/AppIcon.appiconset')
folder.mkdir(parents=True,exist_ok=True)
size=4096
scale=size/100
im=Image.new('RGB',(size,size),(3,5,8))
draw=ImageDraw.Draw(im)
white=(245,247,250)

def cubic(a,b,c,d):
    points=[]
    for step in range(121):
        t=step/120; u=1-t
        points.append((u*u*u*a[0]+3*u*u*t*b[0]+3*u*t*t*c[0]+t*t*t*d[0],
                       u*u*u*a[1]+3*u*u*t*b[1]+3*u*t*t*c[1]+t*t*t*d[1]))
    return points

def stroke(points,width):
    pixels=[(round(x*scale),round(y*scale)) for x,y in points]
    draw.line(pixels,fill=white,width=round(width*scale),joint='curve')
    r=width*scale/2
    for x,y in [pixels[0],pixels[-1]]:
        draw.ellipse((x-r,y-r,x+r,y+r),fill=white)

# Original P monogram with two open orbital paths; keep geometry aligned with PLSBrand.swift.
stroke(cubic((18,60),(21,31),(52,12),(77,21))+cubic((77,21),(91,26),(92,40),(82,55))[1:],2.5)
stroke(cubic((79,61),(61,86),(32,91),(18,78))+cubic((18,78),(13,73),(13,67),(18,60))[1:],2.5)
stroke([(34,73),(34,27),(56,27)]+cubic((56,27),(76,27),(76,55),(56,55))[1:]+[(34,55)],7)
x,y,r=82*scale,55*scale,3.7*scale
draw.ellipse((x-r,y-r,x+r,y+r),fill=white)
im.resize((1024,1024),Image.Resampling.LANCZOS).save(folder/'AppIcon.png')
(folder/'Contents.json').write_text(json.dumps({'images':[{'filename':'AppIcon.png','idiom':'universal','platform':'ios','size':'1024x1024'}],'info':{'author':'xcode','version':1}},indent=2))
(folder.parent/'Contents.json').write_text('{"info":{"author":"xcode","version":1}}')
