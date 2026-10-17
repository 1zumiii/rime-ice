import json, random, sys, subprocess, collections
random.seed(11)
words=json.load(open("words.json",encoding="utf-8"))
base=[json.loads(l) for l in open("clean_all.txt.base.jsonl",encoding="utf-8")]
# 选“基线输入正确拼音时首位就是这个词”的词作为受试对象（任何变化都算影响）
S=[(w,py) for (w,py),r in zip(words,base) if r["c"] and r["c"][0]==w]
print("受试词:", len(S))
ROWS=["qwertyuiop","asdfghjkl","zxcvbnm"]
pos={c:(r,i) for r,row in enumerate(ROWS) for i,c in enumerate(row)}
def nb(c):
    r,i=pos[c]; out=[]
    for c2,(r2,i2) in pos.items():
        if c2!=c and ((r2==r and abs(i2-i)==1) or (abs(r2-r)==1 and abs((i2+(0.25 if r2==1 else 0.75 if r2==2 else 0))-(i+(0.25 if r==1 else 0.75 if r==2 else 0)))<=0.6)): out.append(c2)
    return out
def typo(py,kind):
    cand=[k for k,s in enumerate(py) if len(s)>=3]
    if not cand: return None
    k=random.choice(cand); s=py[k]
    j=random.randrange(1,len(s))  # 不动首字母
    if kind=="sub": t=s[:j]+random.choice(nb(s[j]))+s[j+1:]
    elif kind=="del": t=s[:j]+s[j+1:]
    elif kind=="trans":
        if j>=len(s)-1 or s[j]==s[j+1]: return None
        t=s[:j]+s[j+1]+s[j]+s[j+2:]
    elif kind=="ins": t=s[:j]+random.choice(nb(s[j]))+s[j:]
    out=py[:k]+[t]+py[k+1:]
    return "".join(out)
random.shuffle(S); S=S[:1200]
sets={}
for kind in ["sub","del","trans","ins"]:
    items=[]
    for w,py in S:
        t=typo(py,kind)
        if t and t!="".join(py): items.append((w,t))
    sets[kind]=items
json.dump({"S":S,"sets":sets}, open("sets.json","w"), ensure_ascii=False)
open("clean_S.txt","w").write("\n".join("".join(py) for w,py in S)+"\n")
for kind,items in sets.items(): open(f"typo_{kind}.txt","w").write("\n".join(t for w,t in items)+"\n")
print({k:len(v) for k,v in sets.items()})
