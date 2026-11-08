#!/usr/bin/env python3
"""Fake icloudpd for the test-suite: the same command-line surface as the parts the scripts use,
the same log format, a made-up library, and switches that inject failures. No network, ever.

Library: FAKE_ITEMS items (default 120) spread from 2019 to 2024, built deterministically. Every
10th item is a video, every 5th other item a Live Photo (HEIC + _HEVC.MOV), the rest JPG/HEIC/PNG.
Item 97 has a look-alike twin (same name, same size, same month), so one file serves two items.
FAKE_EXTRA adds that many newer items (2025) - for top-up tests.

Switches (environment): FAKE_STATE (marker folder), FAKE_FAIL_ONCE / FAKE_FAIL_ALWAYS (comma lists
of file names), FAKE_HANG_ONCE (seconds of silence on the first run), FAKE_DELAY (seconds per
file), FAKE_AUTH_FAIL=1, FAKE_CRASH_ONCE=1 (exit 1 halfway, first run), FAKE_EMPTY=1.
"""
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time

VALUE_FLAGS = {'--log-level', '--password-provider', '--mfa-provider', '--domain', '--username', '-u',
               '--cookie-directory', '--directory', '-d', '--folder-structure', '--live-photo-size',
               '--file-match-policy', '--library', '--size', '--skip-created-before',
               '--skip-created-after', '--until-found', '--recent', '--threads-num', '--album', '-a',
               '--live-photo-mov-filename-policy', '--align-raw', '--watch-with-interval'}
BOOL_FLAGS = {'--no-progress-bar', '--only-print-filenames', '--auth-only', '--xmp-sidecar',
              '--keep-unicode-in-filenames', '--dry-run', '--list-libraries', '--list-albums',
              '--version', '--skip-videos', '--skip-live-photos', '--skip-photos', '--force-size',
              '--adp-web-access', '--use-os-locale'}
DANGEROUS = {'--auto-delete', '--delete-after-download', '--keep-icloud-recent-days', '--set-exif-datetime',
             '--prune-orphans', '--prune-orphans-adopt-existing'}
HEADERS = {'.JPG': b'\xff\xd8\xff\xe0', '.HEIC': b'\x00\x00\x00\x18ftypheic', '.PNG': b'\x89PNG\r\n\x1a\n',
           '.MOV': b'\x00\x00\x00\x14ftypqt  '}


def log(level, msg):
    sys.stdout.write(f'{dt.datetime.now():%Y-%m-%d %H:%M:%S} {level:<8} {msg}\n')
    sys.stdout.flush()


def parse(argv):
    opts = {'--size': []}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in DANGEROUS:
            state = os.environ.get('FAKE_STATE')
            if state:
                open(os.path.join(state, 'DANGEROUS_OPTION_RECEIVED'), 'a').write(a + '\n')
            print(f'fake icloudpd: refusing to emulate {a}', file=sys.stderr)
            sys.exit(2)
        if a in VALUE_FLAGS:
            if i + 1 >= len(argv):
                sys.exit(f'error: {a} needs a value')
            if a == '--size':
                opts['--size'].append(argv[i + 1])
            else:
                opts[a] = argv[i + 1]
            i += 2
        elif a in BOOL_FLAGS:
            opts[a] = True
            i += 1
        else:
            print(f'error: unrecognized arguments: {a}', file=sys.stderr)
            sys.exit(2)
    return opts


def library():
    if os.environ.get('FAKE_EMPTY') == '1':
        return []
    n = int(os.environ.get('FAKE_ITEMS', '120'))
    start, end = dt.datetime(2019, 1, 3, 10, 0, 0), dt.datetime(2024, 12, 20, 18, 0, 0)
    span = (end - start).total_seconds()
    items = []

    def make(i, created, extra=False):
        if i % 10 == 0:
            kind, ext = 'video', '.MOV'
        elif i % 5 == 0:
            kind, ext = 'live', '.HEIC'
        else:
            kind, ext = 'photo', ['.JPG', '.HEIC', '.PNG'][i % 3]
        name = f"IMG_{'9' if extra else ''}{i:04d}{ext}"
        size = (4000 + (i * 13) % 2000) if kind == 'video' else 1000 + (i * 37) % 900
        return {'id': f'A{i:05d}{"x" if extra else ""}', 'name': name, 'created': created, 'kind': kind,
                'size': size, 'mov_size': 1500 + i}

    for i in range(1, n + 1):
        items.append(make(i, start + dt.timedelta(seconds=span * (i - 1) / max(n - 1, 1))))
    twin = next((it for it in items if it['name'].startswith('IMG_0097')), None)
    if twin:
        t = dict(twin)
        t['id'] = twin['id'] + 'b'
        t['created'] = twin['created'].replace(minute=(twin['created'].minute + 1) % 60)
        items.append(t)
    for k in range(1, int(os.environ.get('FAKE_EXTRA', '0')) + 1):
        items.append(make(k, dt.datetime(2025, 3, 1, 9, 0, 0) + dt.timedelta(days=k), extra=True))
    items.sort(key=lambda it: it['created'], reverse=True)   # newest first, like icloudpd
    return items


def files_of(item, policy):
    stem, ext = os.path.splitext(item['name'])
    tag = '_' + hashlib.sha1(item['id'].encode()).hexdigest()[:7] if policy == 'name-id7' else ''
    out = [(f'{stem}{tag}{ext}', item['size'], item['id'])]
    if item['kind'] == 'live':
        out.append((f'{stem}{tag}_HEVC.MOV', item['mov_size'], item['id'] + 'm'))
    return out


def when(text):
    m = re.fullmatch(r'(\d+)d', text)
    if m:
        return dt.datetime.now() - dt.timedelta(days=int(m.group(1)))
    return dt.datetime.fromisoformat(text)


def content(seed, size, ext):
    body = hashlib.sha256(seed.encode()).digest() * (size // 32 + 2)
    return (HEADERS.get(ext.upper(), b'') + body)[:size]


def marker(name):
    d = os.environ.get('FAKE_STATE') or '.'
    return os.path.join(d, name)


def main():
    o = parse(sys.argv[1:])
    if o.get('--version'):
        print('version:1.33.0, commit sha:fake000, commit timestamp:Thu Jan  1 00:00:00 2026')
        return 0
    user = o.get('--username') or o.get('-u') or ''
    cookies = os.path.expanduser(o.get('--cookie-directory', '~/.pyicloud'))
    sid = re.sub(r'\W', '', user)
    if os.environ.get('FAKE_AUTH_FAIL') == '1':
        log('ERROR', 'Invalid email/password combination.')
        return 1
    try:
        ok = bool(json.load(open(os.path.join(cookies, sid + '.session'))).get('session_token'))
    except (OSError, ValueError):
        ok = False
    if not ok:
        print('Traceback (most recent call last):\nEOFError: EOF when reading a line')
        return 1
    if o.get('--auth-only'):
        log('INFO', 'Authentication completed successfully')
        return 0
    if o.get('--list-libraries'):
        print('PrimarySync\nSharedSync-FAKE-0001')
        return 0
    hang = os.environ.get('FAKE_HANG_ONCE')
    if hang and not os.path.exists(marker('hung')):
        open(marker('hung'), 'w').close()
        time.sleep(float(hang))
    dest = o.get('--directory') or o.get('-d')
    folders = o.get('--folder-structure', '{:%Y/%m/%d}')
    policy = o.get('--file-match-policy', 'name-size-dedup-with-suffix')
    items = library()
    listing = o.get('--only-print-filenames', False)
    if not listing:
        log('INFO', f"Downloading {len(items)} {','.join(o['--size']) or 'original'} photos and videos to {dest} ...")
    before = when(o['--skip-created-before']) if '--skip-created-before' in o else None
    after = when(o['--skip-created-after']) if '--skip-created-after' in o else None
    recent = int(o['--recent']) if '--recent' in o else None
    until = int(o['--until-found']) if '--until-found' in o else None
    fail_once = set(filter(None, os.environ.get('FAKE_FAIL_ONCE', '').split(',')))
    fail_always = set(filter(None, os.environ.get('FAKE_FAIL_ALWAYS', '').split(',')))
    delay = float(os.environ.get('FAKE_DELAY', '0'))
    crash = os.environ.get('FAKE_CRASH_ONCE') == '1' and not os.path.exists(marker('crashed'))
    downloaded, found_in_a_row = 0, 0
    for idx, it in enumerate(items):
        if recent is not None and idx >= recent:
            break
        if (before and it['created'] < before) or (after and it['created'] > after):
            continue
        folder = '' if folders == 'none' else folders.format(it['created'])
        all_there = True
        for fname, size, seed in files_of(it, policy):
            path = os.path.join(dest, folder, fname)
            if os.path.exists(path) and os.path.getsize(path) != size and policy != 'name-id7':
                s, e = os.path.splitext(fname)
                path = os.path.join(dest, folder, f'{s}-{size}{e}')
            if os.path.exists(path) and (policy == 'name-id7' or os.path.getsize(path) == size):
                if not listing:
                    log('DEBUG', f'{path} already exists')
                continue
            all_there = False
            if listing:
                print(path)
                continue
            if fname in fail_always or (fname in fail_once and not os.path.exists(marker('failed-' + fname))):
                open(marker('failed-' + fname), 'w').close()
                log('ERROR', f'Could not connect to iCloud to download {path}: 410 Client Error: Gone')
                continue
            log('DEBUG', f'Downloading {path}...')
            os.makedirs(os.path.dirname(path), exist_ok=True)
            part = os.path.join(os.path.dirname(path), hashlib.md5(path.encode()).hexdigest() + '.part')
            with open(part, 'wb') as fh:
                fh.write(content(seed, size, os.path.splitext(fname)[1]))
            if delay:
                time.sleep(delay)
            os.replace(part, path)
            log('INFO', f'Downloaded {path}')
            downloaded += 1
            if crash and downloaded >= 20:
                open(marker('crashed'), 'w').close()
                log('ERROR', f'Connection lost while downloading {path}: Connection reset by peer')
                return 1
        if until is not None:
            found_in_a_row = found_in_a_row + 1 if all_there else 0
            if found_in_a_row >= until:
                log('INFO', f'Found {until} consecutive previously downloaded photos. Exiting')
                break
    return 0


if __name__ == '__main__':
    sys.exit(main())
