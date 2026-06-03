#!/usr/bin/env python3
"""Extract BANK questions from QuestionBank.swift → questions.json for the PWA."""
import re, json, sys

def unescape(s):
    result, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            c = s[i+1]
            if   c == '"':  result.append('"');  i += 2
            elif c == '\\': result.append('\\'); i += 2
            elif c == 'n':  result.append('\n'); i += 2
            elif c == 't':  result.append('\t'); i += 2
            elif c == 'r':  result.append('\r'); i += 2
            else:           result.append(s[i]); i += 1
        else:
            result.append(s[i]); i += 1
    return ''.join(result)

src = '../CGRCTrainer/QuestionBank.swift'
with open(src, encoding='utf-8') as f:
    content = f.read()

pat = re.compile(
    r'Question\('
    r'id:\s*(\d+),\s*domain:\s*(\d+),\s*text:\s*"((?:[^"\\]|\\.)*)",\s*'
    r'options:\s*\[((?:[^\[\]]|\\.)*)\],\s*answer:\s*(\d+),\s*'
    r'explain:\s*"((?:[^"\\]|\\.)*)"\s*\)'
)

questions = []
for m in pat.finditer(content):
    qid, dom, text, opts_raw, ans, expl = m.groups()
    opts = re.findall(r'"((?:[^"\\]|\\.)*)"', opts_raw)
    if len(opts) != 4:
        print(f'WARNING: id={qid} has {len(opts)} options', file=sys.stderr)
    questions.append({
        'id':      int(qid),
        'domain':  int(dom),
        'text':    unescape(text),
        'options': [unescape(o) for o in opts],
        'answer':  int(ans),
        'explain': unescape(expl)
    })

questions.sort(key=lambda q: q['id'])

out = 'questions.json'
with open(out, 'w', encoding='utf-8') as f:
    json.dump(questions, f, ensure_ascii=False, separators=(',', ':'))

# Verify
dom_counts = {}
for q in questions:
    dom_counts[q['domain']] = dom_counts.get(q['domain'], 0) + 1

print(f'✓ Extracted {len(questions)} questions → {out}')
print(f'  Domains: {dict(sorted(dom_counts.items()))}')
ids = [q['id'] for q in questions]
dups = len(ids) - len(set(ids))
print(f'  Duplicates: {dups}  Bad opts: {sum(len(q["options"])!=4 for q in questions)}')
