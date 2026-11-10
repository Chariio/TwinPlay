# Replaces the "TwinPlay" wordmark on the alternate TwinPlay app icons (same idea as mk.py).
import sys
from PIL import Image, ImageDraw, ImageFont
from collections import Counter
A='/workspace/ds-emu/DSEmu/Resources/Assets.xcassets/'
F='/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
sets={'Classic':(360,230,664,400),'Crimson':(360,230,664,400),'Lime':(360,230,664,400),
      'Midnight':(360,230,664,400),'Ocean':(360,230,664,400),'Advance':(360,420,664,620)}
for name,box in sets.items():
    p=f'{A}AppIcon-{name}.appiconset/AppIcon-{name}-1024.png'
    im=Image.open(p).convert('RGB'); px=im.load()
    reg=[(x,y) for x in range(box[0],box[2]) for y in range(box[1],box[3])]
    bg=Counter(px[q] for q in reg).most_common(1)[0][0]
    far=lambda c:sum(abs(a-b) for a,b in zip(c,bg))>120
    tp=[q for q in reg if far(px[q])]
    tc=Counter(px[q] for q in tp).most_common(1)[0][0]
    xs=[q[0] for q in tp]; ys=[q[1] for q in tp]
    bb=(min(xs)-14,min(ys)-14,max(xs)+14,max(ys)+14)
    print(name,bg,tc,bb)
    d=ImageDraw.Draw(im); d.rectangle(bb,fill=bg)
    cx,cy=(bb[0]+bb[2])/2,(bb[1]+bb[3])/2; maxw=(bb[2]-bb[0])+40
    size=int((bb[3]-bb[1]-28)*1.0)
    while True:
        fnt=ImageFont.truetype(F,size)
        if d.textlength('TwinPlay',font=fnt)<=maxw: break
        size-=2
    d.text((cx,cy),'TwinPlay',font=fnt,fill=tc,anchor='mm')
    im.save(f'alts/AppIcon-{name}-1024.png')
