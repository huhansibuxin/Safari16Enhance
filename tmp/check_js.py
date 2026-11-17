import re, sys

src = open('Tweak.xm', encoding='utf-8').read()
start = src.index('static NSString *SPEHOpenInAppJS(void)')
end = src.index('@protocol SPEHWebViewJS')
body = src[start:end]

parts = re.findall(r'"((?:[^"\\]|\\.)*)"', body)
js = ''.join(parts)
out = []
i = 0
while i < len(js):
    c = js[i]
    if c == '\\' and i + 1 < len(js):
        n = js[i + 1]
        out.append(n if n in '\\"' else '\\' + n)
        i += 2
    else:
        out.append(c)
        i += 1
js = ''.join(out)

open('tmp/speh_openinapp.js', 'w', encoding='utf-8').write(js)
print('len', len(js))
print(js[:160])
