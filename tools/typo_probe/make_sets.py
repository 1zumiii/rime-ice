import random, re, json, sys
random.seed(7)
REPO="/Users/izumi/Documents/RimeCustomised"
words=[]
for f in ["cn_dicts/base.dict.yaml","cn_dicts/8105.dict.yaml"]:
    for line in open(f"{REPO}/{f}",encoding="utf-8"):
        p=line.rstrip("\n").split("\t")
        if len(p)>=3 and re.fullmatch(r"[a-z ]+",p[1]) and p[2].isdigit():
            w,py,wt=p[0],p[1].split(" "),int(p[2])
            if re.fullmatch(r"[一-鿿]+",w) and len(py)==len(w) and 2<=len(w)<=4:
                words.append((w,py,wt))
words.sort(key=lambda x:-x[2])
seen=set(); top=[]
for w,py,wt in words:
    if w in seen: continue
    seen.add(w); top.append((w,py))
    if len(top)>=4000: break
random.shuffle(top)
json.dump(top, open("words.json","w"), ensure_ascii=False)
open("clean_all.txt","w").write("\n".join("".join(py) for w,py in top)+"\n")
print(len(top))
