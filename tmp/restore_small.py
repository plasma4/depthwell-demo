import re,os,sys
thr=int(sys.argv[1])
restored=0
for root,d,files in os.walk('tmp/zig-backup'):
    for f in files:
        if not f.endswith('.zig'): continue
        bp=os.path.join(root,f)
        cp=bp.replace('tmp/zig-backup','zig',1)
        blines=open(bp).read().split('\n')
        cur=open(cp).read().split('\n')
        targets=[]
        for i,l in enumerate(blines):
            if re.match(r'^\s*(pub )?inline fn ',l):
                # brace balance from this line
                depth=0; body=0; started=False
                for j in range(i,len(blines)):
                    depth+=blines[j].count('{')-blines[j].count('}')
                    if '{' in blines[j]: started=True
                    if started:
                        body+=1
                        if depth==0: break
                if body<=thr:
                    targets.append(l.replace('inline fn ','fn ',1))
        if not targets: continue
        tset=set(targets)
        out=[]
        for l in cur:
            if l in tset and re.match(r'^\s*(pub )?fn ',l):
                l=l.replace('fn ','inline fn ',1); restored+=1
            out.append(l)
        open(cp,'w').write('\n'.join(out))
print('restored',restored)
