import glob, re, os
os.chdir(r'C:\Users\Administrator\AppData\Local\Temp\juejin_js')
words = ['在此处浏览', '用APP', '打开APP', '在此浏览', 'APP内打开', '去APP',
         '打开应用', '立即打开', '继续浏览', '下载APP', 'app内打开', '在App内打开',
         '打开稀土掘金', '稀土掘金', '客户端', 'APP', '浏览']
for fn in glob.glob('*.js'):
    s = open(fn, encoding='utf-8', errors='ignore').read()
    hits = []
    for w in words:
        esc = ''.join('\\u%04x' % ord(c) for c in w)
        escu = esc.upper()
        if w in s or esc in s or escu in s:
            hits.append((w, 'direct' if w in s else 'escaped'))
    if hits:
        print(fn, hits)
