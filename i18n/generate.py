import sys,os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from i18n_map import M,F
root=os.path.dirname(os.path.abspath(__file__))
entries={}  # key -> (en,es,pt)
for pt,en,es in M:
    if en in entries and entries[en]!=(en,es,pt): print('CONFLICT',en,entries[en],(en,es,pt))
    entries[en]=(en,es,pt)
for key,es,pt in F:
    entries[key]=(key,es,pt)
def esc(s): return s.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n')
for i,lang in enumerate(['en','es','pt']):
    d=f'{root}/{lang}.lproj'; os.makedirs(d,exist_ok=True)
    with open(f'{d}/Localizable.strings','w',encoding='utf-8') as f:
        f.write(f'/* {lang} — generated from i18n source; keys are the English strings */\n')
        for k,v in sorted(entries.items()):
            f.write(f'"{esc(k)}" = "{esc(v[i] if lang!="en" else k)}";\n')
print(len(entries),'entries')
