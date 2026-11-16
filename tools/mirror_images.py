#!/usr/bin/env python3
"""คัดลอกรูปสินค้า tracker (ส่วนใหญ่อยู่บน tukatacenter.com) ไปเก็บใน Supabase Storage bucket product-images

- เขียนเฉพาะ bucket product-images (ไฟล์ p/<hash>.webp และ _index.json) ไม่แตะ app_data / ข้อมูลสินค้า
- ทำต่อจากเดิมได้ (resumable): สถานะอยู่ใน /workspace/img-mirror/state.json (url -> key/status)
- ย่อเป็น webp ด้านยาวไม่เกิน 600px (q80) ประหยัดพื้นที่ ~60%
- ข้ามรูปที่โหลดไม่ได้ (บันทึก fail ไว้ ลองใหม่รอบหน้า)
- ชื่อไฟล์ = cyrb53(url ที่ decode+NFC) ฐาน 16 -> หน้าเว็บคำนวณชื่อเดียวกันได้เองโดยไม่ต้องมีตารางจับคู่

ใช้: python3 /workspace/img-mirror/mirror_images.py --limit 50
     python3 /workspace/img-mirror/mirror_images.py            (ทั้งหมด ที่ยังไม่ได้ทำ)
     python3 /workspace/img-mirror/mirror_images.py --index-only (อัปเดต _index.json อย่างเดียว)
บรรทัดสุดท้าย: MIRROR DONE=<n> NEW=<n> FAIL=<n> TOTAL=<n> หรือ SUPPLIER_DOWN ... (exit 3)
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import io
import json
import re
import sys
import time
import unicodedata
import urllib.parse as up
from datetime import datetime
from pathlib import Path

import requests
from PIL import Image

sys.path.insert(0, '/workspace/weekly')
import supplier_health as sh  # noqa: E402
from run_weekly import read_tracker, TZ  # noqa: E402

HERE = Path('/workspace/img-mirror')
STATE = HERE / 'state.json'
BUCKET = 'product-images'
HTML = Path('/workspace/rc-repo/content-task-tracker.html')
UA = {'User-Agent': 'Mozilla/5.0'}
MAXPX = 600


def cyrb53(s: str, seed: int = 0) -> int:
    """ตรงกับ cyrb53 ใน JS (วนตาม UTF-16 code unit)"""
    M = 0xFFFFFFFF
    h1 = (0xdeadbeef ^ seed) & M
    h2 = (0x41c6ce57 ^ seed) & M
    b = s.encode('utf-16-le')
    for i in range(0, len(b), 2):
        ch = b[i] | (b[i + 1] << 8)
        h1 = ((h1 ^ ch) * 2654435761) & M
        h2 = ((h2 ^ ch) * 1597334677) & M
    h1 = ((h1 ^ (h1 >> 16)) * 2246822507) & M
    h1 ^= ((h2 ^ (h2 >> 13)) * 3266489909) & M
    h2 = ((h2 ^ (h2 >> 16)) * 2246822507) & M
    h2 ^= ((h1 ^ (h1 >> 13)) * 3266489909) & M
    return 4294967296 * (2097151 & h2) + (h1 & M)


def norm_url(u: str) -> str:
    try:
        u = up.unquote(u, errors='strict')
    except Exception:
        pass
    return unicodedata.normalize('NFC', u.strip())


def key_of(u: str) -> str:
    return format(cyrb53(norm_url(u)), 'x')


def creds() -> tuple[str, str]:
    h = HTML.read_text(encoding='utf-8')
    return (re.search(r'SUPABASE_URL = "([^"]+)"', h).group(1),
            re.search(r'SUPABASE_KEY = "([^"]+)"', h).group(1))


def upload(base: str, key: str, path: str, data: bytes, ctype: str, upsert: bool = False) -> tuple[bool, str]:
    r = requests.post(f'{base}/storage/v1/object/{BUCKET}/{path}', data=data, timeout=60, headers={
        'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': ctype,
        'x-upsert': 'true' if upsert else 'false', 'Cache-Control': 'max-age=31536000' if not upsert else 'max-age=300'})
    if r.status_code in (200, 201):
        return True, 'ok'
    if r.status_code in (400, 409) and 'exists' in r.text.lower():
        return True, 'exists'
    return False, f'upload HTTP {r.status_code} {r.text[:150]}'


def to_webp(raw: bytes) -> bytes:
    im = Image.open(io.BytesIO(raw))
    if im.mode in ('P', 'LA', 'RGBA'):
        im = im.convert('RGBA')
    else:
        im = im.convert('RGB')
    im.thumbnail((MAXPX, MAXPX))
    b = io.BytesIO()
    im.save(b, 'WEBP', quality=80, method=4)
    return b.getvalue()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--workers', type=int, default=4)
    ap.add_argument('--index-only', action='store_true')
    a = ap.parse_args()
    base, key = creds()
    st = json.loads(STATE.read_text(encoding='utf-8')) if STATE.exists() else {}

    def save():
        tmp = STATE.with_suffix('.tmp')
        tmp.write_text(json.dumps(st, ensure_ascii=False), encoding='utf-8')
        tmp.replace(STATE)

    new = fail = 0
    if not a.index_only:
        sh.check('mirror')
        TR = read_tracker(HERE / 'tracker_products.json')
        urls = []
        seen = set()
        for p in TR['list']:
            for u in [p.get('img')] + (p.get('imgs') or []):
                if isinstance(u, str) and u.startswith('http') and u not in seen:
                    seen.add(u)
                    urls.append(u)
        todo = [u for u in urls if st.get(u, {}).get('status') != 'done']
        if a.limit:
            todo = todo[:a.limit]
        print(f'urls {len(urls)} done {len(urls) - len([u for u in urls if st.get(u, {}).get("status") != "done"])} todo now {len(todo)}', flush=True)
        consec_down = 0

        def work(u):
            k = key_of(u)
            src = u if re.search(r'%[0-9A-Fa-f]{2}', u) else up.quote(u, safe=':/?&=%#+,;@!$()*~')
            try:
                r = requests.get(src, headers=UA, timeout=45)
            except (requests.Timeout, requests.ConnectionError) as e:
                return u, k, 'fail', f'net {type(e).__name__}', 0, True
            if r.status_code != 200:
                return u, k, 'fail', f'HTTP {r.status_code}', 0, r.status_code >= 500
            try:
                w = to_webp(r.content)
            except Exception as e:
                return u, k, 'fail', f'decode {type(e).__name__}', 0, False
            ok, msg = upload(base, key, f'p/{k}.webp', w, 'image/webp')
            return u, k, ('done' if ok else 'fail'), msg, len(w), False

        with cf.ThreadPoolExecutor(a.workers) as ex:
            for i, (u, k, status, msg, size, down) in enumerate(ex.map(work, todo), 1):
                st[u] = dict(key=k, status=status, msg=msg, bytes=size,
                             at=datetime.now(TZ).strftime('%Y-%m-%d %H:%M'))
                if status == 'done':
                    new += 1
                    consec_down = 0
                else:
                    fail += 1
                    consec_down = consec_down + 1 if down else 0
                if i % 100 == 0:
                    save()
                    print(f'{i}/{len(todo)} new {new} fail {fail}', flush=True)
                if consec_down >= 20:
                    save()
                    ex.shutdown(cancel_futures=True)
                    sh.mark_down(f'โหลดรูปล้มเหลวติดกัน {consec_down} รูป ({msg})', 'mirror')
        save()

    keys = sorted({v['key'] for v in st.values() if v.get('status') == 'done'})
    idx = json.dumps({'v': 1, 'updated': datetime.now(TZ).isoformat(timespec='seconds'), 'keys': keys}, separators=(',', ':'))
    ok, msg = upload(base, key, '_index.json', idx.encode(), 'application/json', upsert=True)
    if not ok:
        print(f'FAIL index upload: {msg}', flush=True)
        return 1
    total_b = sum(v.get('bytes', 0) for v in st.values() if v.get('status') == 'done')
    print(f'index keys {len(keys)} stored ~{total_b/1e6:.1f} MB', flush=True)
    print(f'MIRROR DONE={len(keys)} NEW={new} FAIL={fail} TOTAL_STATE={len(st)}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as e:
        print(f'FAIL {type(e).__name__}: {e}', flush=True)
        raise SystemExit(1)
