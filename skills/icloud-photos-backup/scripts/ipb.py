#!/usr/bin/env python3
"""ipb.py - helper tools for icloud-photos-backup. Standard library only, Python 3.9+.

Checks (read-only: they never delete, move or change your photos):
  inventory    [ROOT]                     what's in the backup: photos, videos, Live Photo
                                          videos, sizes, years, leftovers
  reconcile    [ROOT] [--log FILE]        exact check against icloudpd's own list of files
  dupes        [ROOT] [--report FILE]     identical files (SHA-256)
  spotcheck    [ROOT] [--per-year N]      opens random files from every year
  find-outside --search DIR [DIR ...]     photos/videos elsewhere that aren't in the backup yet
  manifest     create|update|check [ROOT] SHA-256 fingerprints in ROOT/_manifest/ (the only
                                          thing these tools ever write inside the backup)
Used by the shell scripts: progress, status, plan, copy-session, fsinfo.

ROOT defaults to DEST from the settings file ($IPB_CONFIG, else ~/.config/icloud-photos-backup/config).
Run with "python3 -I ipb.py ..." so nothing from the current folder can be imported by accident.
"""
import argparse
import calendar
import collections
import concurrent.futures
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time

PHOTO = {'.heic', '.heif', '.jpg', '.jpeg', '.png', '.gif', '.tif', '.tiff', '.dng', '.webp', '.bmp',
         '.avif', '.raw', '.cr2', '.cr3', '.nef', '.arw', '.orf', '.rw2', '.raf'}
VIDEO = {'.mov', '.mp4', '.m4v', '.avi', '.3gp', '.mkv', '.hevc', '.mts', '.m2ts', '.mpg', '.mpeg', '.wmv'}
AUDIO = {'.m4a', '.mp3', '.wav', '.aac', '.caf', '.aiff', '.flac'}
SIDECAR = {'.xmp', '.aae'}
DECODABLE = {'.heic', '.heif', '.jpg', '.jpeg', '.png', '.gif', '.tif', '.tiff', '.webp', '.bmp', '.avif'}
SIZE_SUFFIX = re.compile(r'-\d+$')                  # icloudpd's "same name, other size" suffix
CLASS_MB = {'photo': 2.5, 'live': 8.0, 'video': 70.0}  # rough averages from a real 1 TB library
LOG_LINE = re.compile(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+(DEBUG|INFO|WARNING|ERROR|CRITICAL)\s+(.*)$')
TOTAL_RE = re.compile(r'^Downloading (\d+) .*? to (.+?) \.\.\.$')


# ---------------------------------------------------------------- settings and file walking
def config_path():
    p = os.environ.get('IPB_CONFIG')
    if p:
        return p
    base = os.environ.get('XDG_CONFIG_HOME') or os.path.join(os.path.expanduser('~'), '.config')
    return os.path.join(base, 'icloud-photos-backup', 'config')


def load_config():
    """Same rules as lib.sh: KEY=value lines, optional quotes, nothing executed."""
    cfg = {}
    try:
        with open(config_path(), encoding='utf-8') as fh:
            lines = fh.read().splitlines()
    except OSError:
        return cfg
    for line in lines:
        m = re.match(r'^([A-Z_][A-Z0-9_]*)=(.*)$', line)
        if not m:
            continue
        v = m.group(2)
        if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'':
            v = v[1:-1]
        if v.startswith('~/'):
            v = os.path.join(os.path.expanduser('~'), v[2:])
        cfg[m.group(1)] = v
    return cfg


def state_dir(cfg):
    if cfg.get('STATE_DIR'):
        return cfg['STATE_DIR']
    base = os.environ.get('XDG_STATE_HOME') or os.path.join(os.path.expanduser('~'), '.local', 'state')
    return os.path.join(base, 'icloud-photos-backup')


def resolve_root(given):
    if given:
        return os.path.abspath(given)
    dest = load_config().get('DEST')
    if not dest:
        sys.exit('No folder given and no settings file found (run setup.sh, or pass the folder).')
    return dest


def walk_files(root):
    """(relative path, full path) of every file under root, skipping hidden files and folders whose
    names start with '.' or '_' (the _manifest folder, quarantine folders, the hidden ID file)."""
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if not d.startswith(('.', '_')))
        for f in sorted(fns):
            if f.startswith('.'):
                continue
            p = os.path.join(dp, f)
            yield os.path.relpath(p, root).replace(os.sep, '/'), p


def ext_of(name):
    return os.path.splitext(name)[1].lower()


def stem(name):
    s = SIZE_SUFFIX.sub('', os.path.splitext(name)[0])
    return re.sub(r'_HEVC$', '', s, flags=re.I).lower()


def kinds_in_folder(names):
    """Labels each file. A video that shares its base name with a photo in the same folder is
    counted as a Live Photo video - a good estimate, not a certainty."""
    photos = {stem(n) for n in names if ext_of(n) in PHOTO}
    out = {}
    for n in names:
        e = ext_of(n)
        if e == '.part':
            out[n] = 'part'
        elif e in PHOTO:
            out[n] = 'photo'
        elif e in VIDEO:
            out[n] = 'live' if stem(n) in photos else 'video'
        elif e in AUDIO:
            out[n] = 'audio'
        elif e in SIDECAR:
            out[n] = 'sidecar'
        else:
            out[n] = 'other'
    return out


def scan(root):
    """One pass over the backup: per-file kind and size, grouped the way the reports need."""
    by_dir = collections.defaultdict(list)
    for rel, p in walk_files(root):
        by_dir[os.path.dirname(rel)].append((os.path.basename(rel), rel, p))
    rows = []
    for d in sorted(by_dir):
        items = by_dir[d]
        kinds = kinds_in_folder([n for n, _, _ in items])
        for n, rel, p in items:
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            rows.append((rel, p, kinds[n], size))
    return rows


def ym_of(rel):
    m = re.match(r'^(\d{4})/(\d{2})/', rel)
    return (m.group(1) + '/' + m.group(2)) if m else None


def sha256_file(path, chunk=4 << 20):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            b = fh.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def gb(n):
    return f'{n / 1e9:,.1f} GB'


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    tmp = f'{path}.tmp-{os.getpid()}'
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(text)
    os.replace(tmp, path)


# ---------------------------------------------------------------- progress / status
def progress_counts(root):
    c = collections.Counter()
    months = set()
    if not os.path.isdir(root):
        return c, months
    for rel, _, k, size in scan(root):
        if k == 'part':
            c['parts'] += 1
            continue
        c[k] += 1
        c['files'] += 1
        c['bytes'] += size
        ym = ym_of(rel)
        if ym:
            months.add(ym)
    return c, months


def cmd_progress(a):
    c, months = progress_counts(resolve_root(a.root))
    ms = sorted(months)
    print(f"photos={c['photo']} videos={c['video']} live={c['live']} audio={c['audio']} "
          f"other={c['other'] + c['sidecar']} files={c['files']} bytes={c['bytes']} parts={c['parts']} "
          f"oldest={ms[0] if ms else '-'} newest={ms[-1] if ms else '-'}")
    return 0


def read_text(path, default=''):
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            return fh.read()
    except OSError:
        return default


def pid_alive(pid_text, pattern):
    try:
        pid = int(pid_text.strip())
        os.kill(pid, 0)
    except (ValueError, ProcessLookupError, OSError):
        return False
    out = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout
    return re.search(pattern, out) is not None


def tail_lines(path, nbytes=2 << 20):
    try:
        with open(path, 'rb') as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - nbytes))
            return fh.read().decode('utf-8', 'replace').splitlines()
    except OSError:
        return []


def human_range(args):
    lo = hi = None
    toks = args.split()
    for i, t in enumerate(toks[:-1]):
        if t == '--skip-created-before':
            lo = toks[i + 1][:7]
        elif t == '--skip-created-after':
            hi = toks[i + 1][:7]
    if lo and hi:
        return f'{lo} to {hi}'
    if lo:
        return f'{lo} to now'
    if hi:
        return f'up to {hi}'
    return 'whole library'


def short_status(line):
    s = line.strip()[20:] if re.match(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ', line) else line.strip()
    s = re.sub(r' -> \S.*$', '', s)
    s = re.sub(r' \((/[^()]*\.log)\)$', '', s)
    return s or '?'


def power_text():
    if sys.platform != 'darwin' or not shutil.which('pmset'):
        return None
    out = subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True).stdout
    src = 'on power adapter' if 'AC Power' in out else ('ON BATTERY - plug it in' if 'Battery Power' in out else '?')
    m = re.search(r'(\d+)%', out)
    return src + (f', battery {m.group(1)}%' if m else '')


def fmt_dur(sec):
    if sec < 3600:
        return f'{max(1, round(sec / 60))} min'
    if sec < 48 * 3600:
        return f'{sec / 3600:.1f} h'
    return f'{sec / 86400:.1f} days'


def cmd_status(a):
    cfg = load_config()
    if not cfg:
        print('Not set up yet: run setup.sh first.')
        return 1
    st = state_dir(cfg)
    logs = os.path.join(st, 'logs')
    dest = cfg.get('DEST', '')
    now = time.time()
    job_line = read_text(os.path.join(logs, 'STATUS.job')).strip()
    if not job_line:
        print('No backup has run yet. Start one with start.sh.')
        return 0
    start_raw = read_text(os.path.join(logs, 'job-start')).split()
    start_epoch = float(start_raw[0]) if start_raw else 0.0
    start_text = ' '.join(start_raw[1:3]) if len(start_raw) >= 3 else ''
    job_alive = pid_alive(read_text(os.path.join(st, 'job.lock', 'pid')), r'orchestrate\.sh')

    names, ranges = [], {}
    for line in read_text(os.path.join(logs, 'job-plan.txt')).splitlines():
        parts = line.split(' ', 2)
        if len(parts) >= 2 and parts[0] == 'SLICE':
            names.append(parts[1])
            ranges[parts[1]] = human_range(parts[2] if len(parts) > 2 else '')
    for extra in ('full', 'topup'):
        f = os.path.join(logs, f'STATUS.{extra}')
        if os.path.exists(f) and os.path.getmtime(f) >= start_epoch - 5:
            names.append(extra)
            ranges[extra] = 'quick top-up' if extra == 'topup' else 'whole library'

    job_state = short_status(job_line)
    if job_state.startswith(('STARTING', 'LISTING', 'RUNNING', 'SLICES', 'FINAL', 'TOP-UP')) and not job_alive:
        job_state += '  (the job process is NOT running - run start.sh to resume)'
    lines = [f"Job:        {job_state}"
             + (f"  (started {start_text}, {fmt_dur(now - start_epoch)} ago)" if start_epoch else '')]
    running = 0
    for n in names:
        st_line = read_text(os.path.join(logs, f'STATUS.{n}')).strip()
        alive = pid_alive(read_text(os.path.join(logs, f'run.lock.{n}', 'pid')), r'run-backup\.sh')
        running += alive
        where = ''
        m = re.search(r' -> (\S.*\.log)', st_line)
        if alive and m:
            for l in reversed(tail_lines(m.group(1), 1 << 20)):
                if 'DEBUG    Downloading /' in l:
                    mm = re.search(r'/(\d{4})/(\d{2})/[^/]*$', l.rstrip('.'))
                    where = f', now at {mm.group(1)}/{mm.group(2)}' if mm else ''
                    break
        state = short_status(st_line) if st_line else 'not started'
        if state.startswith(('RUNNING', 'WAITING')) and not alive:
            state += '  (its process is NOT running - start.sh resumes it)'
        lines.append(f"  {n:6s} {ranges.get(n, ''):22s} {state}{where}")

    c, months = progress_counts(dest) if dest and os.path.isdir(dest) else (collections.Counter(), set())
    ms = sorted(months)
    lines.append(f"On drive:   {c['photo'] + c['video']:,} photos+videos ({c['photo']:,} photos, {c['video']:,} videos)"
                 f" + {c['live']:,} Live Photo videos = {c['files']:,} files, {gb(c['bytes'])}"
                 + (f"  [{ms[0]} .. {ms[-1]}]" if ms else ''))
    start_counts = dict(kv.split('=', 1) for kv in read_text(os.path.join(logs, 'job-start-progress')).split() if '=' in kv)
    files0 = int(start_counts.get('files', '0') or 0)
    listing = read_text(os.path.join(logs, 'job-listing-count')).strip()
    done = max(c['files'] - files0, 0)
    left = None
    if listing.isdigit():
        todo = int(listing)
        left = max(todo - done, 0)
        pct = 100.0 if todo == 0 else min(100.0, 100.0 * done / todo)
        lines.append(f"This job:   {done:,} of {todo:,} files saved ({pct:.1f}%), {left:,} to go")
    else:
        lines.append(f"This job:   {done:,} files saved so far")

    # speed and ETA from the previous status call
    prev_path = os.path.join(logs, '.status-prev')
    try:
        prev = json.loads(read_text(prev_path) or '{}')
    except ValueError:
        prev = {}
    if prev.get('job') == start_epoch and now - prev.get('t', now) >= 60:
        dt = now - prev['t']
        dfiles = c['files'] - prev.get('files', 0)
        dbytes = c['bytes'] - prev.get('bytes', 0)
        rate = dfiles / dt if dt > 0 else 0
        eta = f", about {fmt_dur(left / rate)} left" if (left and rate > 0) else ''
        lines.append(f"Speed:      last {fmt_dur(dt)}: +{dfiles:,} files, +{gb(max(dbytes, 0))} "
                     f"({max(dbytes, 0) / dt / 1e6:.1f} MB/s){eta}")
    if not prev or prev.get('job') != start_epoch or now - prev.get('t', 0) >= 60:
        try:
            write_atomic(prev_path, json.dumps({'job': start_epoch, 't': now, 'files': c['files'], 'bytes': c['bytes']}))
        except OSError:
            pass

    errors, last_saved, total = 0, '', None
    for f in sorted(os.listdir(logs)) if os.path.isdir(logs) else []:
        if not (f.startswith('pass-') and f.endswith('.log')):
            continue
        p = os.path.join(logs, f)
        if os.path.getmtime(p) < start_epoch - 5:
            continue
        with open(p, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                if ' ERROR ' in line and line[:19] >= start_text:
                    errors += 1
                elif total is None and ' INFO ' in line:
                    t = re.search(r' INFO +Downloading (\d+) ', line)
                    if t:
                        total = int(t.group(1))
        for l in reversed(tail_lines(p)):
            if ' INFO     Downloaded ' in l:
                if l[:19] > last_saved[:19]:
                    last_saved = l[:19] + '  ' + os.path.basename(l.split(' INFO     Downloaded ', 1)[1])
                break
    if total is not None:
        lines.append(f"iCloud:     {total:,} items (as icloudpd counts them)")
    lines.append(f"Errors:     {errors} this job" + (' (normal on long runs: the next pass retries them)' if errors else ''))
    lines.append(f"Last saved: {last_saved or '-'}")
    extra = []
    if dest and os.path.isdir(dest):
        extra.append(f'{shutil.disk_usage(dest).free / 1e9:,.0f} GB free on the drive')
    else:
        extra.append('DRIVE NOT CONNECTED')
    pw = power_text()
    if pw:
        extra.append(pw)
    if c['parts']:
        extra.append(f"{c['parts']} download(s) in progress")
    lines.append('Machine:    ' + ' | '.join(extra))
    if job_alive or running:
        lines.append(f"Processes:  running ({running} downloader(s) active)")
    else:
        lines.append('Processes:  nothing running')
    print('\n'.join(lines))
    return 0


# ---------------------------------------------------------------- inventory
def cmd_inventory(a):
    root = resolve_root(a.root)
    if not os.path.isdir(root):
        sys.exit(f'not a folder: {root}')
    cnt, size, exts = collections.Counter(), collections.Counter(), collections.Counter()
    per_year = collections.defaultdict(collections.Counter)
    months, outside, parts, other = set(), [], [], []
    for rel, p, k, s in scan(root):
        if k == 'part':
            parts.append(rel)
            continue
        cnt[k] += 1
        size[k] += s
        exts[ext_of(rel) or '(none)'] += 1
        ym = ym_of(rel)
        if ym:
            months.add(ym)
            per_year[ym[:4]][k] += 1
        else:
            outside.append(rel)
        if k == 'other':
            other.append(rel)
    labels = [('photo', 'photos'), ('video', 'videos'), ('live', 'Live Photo videos (estimated)'),
              ('audio', 'audio'), ('sidecar', 'sidecars (.xmp/.aae)'), ('other', 'other files')]
    print(f'backup folder: {root}')
    for k, label in labels:
        if cnt[k] or k in ('photo', 'video', 'live'):
            print(f'  {label:32s} {cnt[k]:>9,}   {gb(size[k]):>12}')
    print(f"  {'TOTAL':32s} {sum(cnt.values()):>9,}   {gb(sum(size.values())):>12}")
    print(f"photos + videos (compare with the item count iCloud shows): {cnt['photo'] + cnt['video']:,}")
    ms = sorted(months)
    print(f"month folders: {len(ms)}   range: {ms[0] if ms else '-'} .. {ms[-1] if ms else '-'}")
    if per_year:
        print('by year:          photos    videos   Live videos')
        for y in sorted(per_year):
            c = per_year[y]
            print(f'  {y}         {c["photo"]:>9,} {c["video"]:>9,} {c["live"]:>12,}')
    print('file types: ' + ', '.join(f'{e}={n:,}' for e, n in exts.most_common()))
    print(f'unfinished downloads (.part): {len(parts)}')
    for r in parts[:20]:
        print('   ', r)
    print(f'files outside year/month folders: {len(outside)}')
    for r in outside[:20]:
        print('   ', r)
    if len(outside) > 20:
        print(f'    ... and {len(outside) - 20:,} more')
    return 0


# ---------------------------------------------------------------- reconcile
def parse_pass_log(path):
    info = {'refs': [], 'errors': [], 'total': None, 'log_root': None, 'downloaded': 0}
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = LOG_LINE.match(line.rstrip('\n'))
            if not m:
                continue
            lvl, msg = m.group(2), m.group(3)
            if lvl == 'DEBUG' and msg.endswith(' already exists'):
                info['refs'].append(msg[:-len(' already exists')])
            elif lvl == 'INFO' and msg.startswith('Downloaded '):
                info['refs'].append(msg[len('Downloaded '):])
                info['downloaded'] += 1
            elif lvl == 'INFO' and info['total'] is None and TOTAL_RE.match(msg):
                t = TOTAL_RE.match(msg)
                info['total'], info['log_root'] = int(t.group(1)), t.group(2)
            elif lvl in ('ERROR', 'CRITICAL'):
                info['errors'].append(msg)
    return info


def pick_log(explicit):
    if explicit:
        return explicit, 'the log you chose'
    logs = os.path.join(state_dir(load_config()), 'logs')
    st = read_text(os.path.join(logs, 'STATUS.full')).strip()
    m = re.search(r'\((/[^()]*pass-full-[^()]*\.log)\)$', st)
    if st[20:].startswith('COMPLETE') and m and os.path.exists(m.group(1)):
        return m.group(1), 'the last COMPLETE whole-library pass'
    cands = sorted(f for f in os.listdir(logs) if f.startswith('pass-full-') and f.endswith('.log')) if os.path.isdir(logs) else []
    if cands:
        return os.path.join(logs, cands[-1]), 'the newest whole-library pass (NOT a confirmed COMPLETE pass)'
    return None, ''


def cmd_reconcile(a):
    root = resolve_root(a.root)
    log, why = pick_log(a.log)
    if not log:
        print('No whole-library pass log found. Run start.sh (without --top-up) until it reports COMPLETE, then try again.')
        return 2
    info = parse_pass_log(log)
    log_root = (info['log_root'] or root).rstrip('/')
    refs = [p[len(log_root) + 1:] for p in info['refs'] if p.startswith(log_root + '/')]
    counts = collections.Counter(refs)
    expected = set(counts)
    on_disk, sidecars = set(), 0
    for rel, _ in walk_files(root):
        e = ext_of(rel)
        if e == '.part':
            continue
        if e in SIDECAR and rel not in expected:
            sidecars += 1
            continue
        on_disk.add(rel)
    missing = sorted(expected - on_disk)
    extra = sorted(on_disk - expected)
    shared = sorted((p, n) for p, n in counts.items() if n > 1)
    exp_dirs = {os.path.dirname(p) for p in expected}
    extra_in = [p for p in extra if os.path.dirname(p) in exp_dirs]
    extra_out = [p for p in extra if os.path.dirname(p) not in exp_dirs]

    print(f'Exact check against icloudpd\'s own file list ({why}):')
    print(f'  log: {log}')
    if log_root != root.rstrip('/'):
        print(f'  (that pass wrote to {log_root}; comparing its list with {root})')
    print(f"  items in iCloud (icloudpd's count):             {info['total'] if info['total'] is not None else '?':>9}")
    print(f"  files those items produce:                      {len(refs):>9,}  (photos, Live Photo videos, extra versions)")
    k = len(refs) - len(expected)
    print(f"  different file names among them:                {len(expected):>9,}"
          + (f"  ({k:,} look-alike item{'s' if k != 1 else ''}: same name and size as another item, so one file serves both)" if shared else ''))
    print(f"  files in the backup folder:                     {len(on_disk):>9,}")
    print(f"  MISSING (in iCloud's list, not on the drive):   {len(missing):>9,}")
    print(f"  EXTRA (on the drive, not in iCloud's list):     {len(extra):>9,}"
          + (f"  ({len(extra_in):,} inside the backup's folders, {len(extra_out):,} elsewhere)" if extra else ''))
    if sidecars:
        print(f'  sidecar files (.xmp/.aae) not counted:         {sidecars:>9,}')
    for p in missing[:20]:
        print('    missing:', p)
    for p in extra_in[:10]:
        print('    extra:  ', p)
    if extra_in:
        print('  Extra files are usually items deleted from iCloud after they were saved, or files added by hand.')
    if a.report:
        rows = ['kind\tpath\tnote']
        rows += [f'MISSING\t{p}\t' for p in missing]
        inside = set(extra_in)
        rows += [f'EXTRA\t{p}\t{"in backup folders" if p in inside else "elsewhere"}' for p in extra]
        rows += [f'SHARED\t{p}\t{n} iCloud items share this file' for p, n in shared]
        write_atomic(a.report, '\n'.join(rows) + '\n')
        print(f'  report: {a.report}')
    if info['errors']:
        print(f"WARNING: that pass logged {len(info['errors'])} error(s), so its list may be incomplete. "
              'Run start.sh again until it reports COMPLETE, then re-check.')
    if missing:
        print(f'Verdict: {len(missing):,} FILE(S) MISSING - run start.sh again (it fetches only what is missing).')
        return 1
    if info['errors']:
        return 1
    print("Verdict: EXACT MATCH - every file in iCloud's list is on the drive.")
    return 0


# ---------------------------------------------------------------- duplicates
def cmd_dupes(a):
    root = resolve_root(a.root)
    by_size, chrome, n = collections.defaultdict(list), [], 0
    chrome_rx = re.compile(r' \(\d+\)(\.[^.]+)?$')
    for rel, p in walk_files(root):
        if rel.endswith('.part'):
            continue
        try:
            by_size[os.path.getsize(p)].append((rel, p))
        except OSError:
            continue
        n += 1
        if chrome_rx.search(rel):
            chrome.append(rel)
    groups, hashed = [], 0
    for size, items in by_size.items():
        if len(items) < 2 or size == 0:
            continue
        by_hash = collections.defaultdict(list)
        for rel, p in items:
            by_hash[sha256_file(p)].append(rel)
            hashed += 1
        groups += [(h, size, sorted(g)) for h, g in by_hash.items() if len(g) > 1]
    groups.sort(key=lambda g: (-g[1], g[2]))
    redundant = sum(len(g) - 1 for _, _, g in groups)
    print(f'files scanned: {n:,} | same-size files hashed: {hashed:,}')
    print(f'identical-content groups: {len(groups)} | redundant copies: {redundant} '
          f'({gb(sum(s * (len(g) - 1) for _, s, g in groups))})')
    for h, s, g in groups[:50]:
        print(f'  sha256 {h[:16]}  ({s:,} bytes)')
        for rel in g:
            print(f'     {rel}')
    print(f"names like 'photo (1).jpg' (browser-style copies): {len(chrome)}"
          + ('  - only a problem if they are also in the identical groups above' if chrome else ''))
    for rel in chrome[:20]:
        print('   ', rel)
    if a.report:
        rows = ['sha256\tbytes\tpath'] + [f'{h}\t{s}\t{rel}' for h, s, g in groups for rel in g]
        write_atomic(a.report, '\n'.join(rows) + '\n')
        print('report:', a.report)
    print('Nothing was deleted. Remove a copy only after the owner says yes to that exact file.')
    return 0


# ---------------------------------------------------------------- spot check
def header_ok(path, e):
    with open(path, 'rb') as fh:
        h = fh.read(32)
    if not h:
        return False
    box = h[4:8]
    if e in ('.jpg', '.jpeg'):
        return h[:3] == b'\xff\xd8\xff'
    if e == '.png':
        return h[:8] == b'\x89PNG\r\n\x1a\n'
    if e == '.gif':
        return h[:4] == b'GIF8'
    if e in ('.heic', '.heif', '.avif', '.cr3', '.mov', '.mp4', '.m4v', '.3gp', '.m4a'):
        return box in (b'ftyp', b'moov', b'mdat', b'wide', b'free', b'skip', b'pnot')
    if e == '.webp':
        return h[:4] == b'RIFF' and h[8:12] == b'WEBP'
    if e in ('.tif', '.tiff', '.dng', '.nef', '.cr2', '.arw', '.orf', '.rw2'):
        return h[:2] in (b'II', b'MM')
    if e == '.bmp':
        return h[:2] == b'BM'
    return True


def check_file(path, e, sips, ffprobe, tmp):
    size = os.path.getsize(path)
    if size == 0:
        return False, 'empty file'
    if not header_ok(path, e):
        return False, f'not a valid {e} file (bad header)'
    if sips and e in DECODABLE:
        r = subprocess.run([sips, '-s', 'format', 'jpeg', path, '--out', os.path.join(tmp, 'x.jpg')],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            return False, 'macOS could not open it'
        d = subprocess.run([sips, '-g', 'pixelWidth', '-g', 'pixelHeight', path], capture_output=True, text=True).stdout
        w, hh = re.search(r'pixelWidth: (\d+)', d), re.search(r'pixelHeight: (\d+)', d)
        return True, f'{w.group(1)}x{hh.group(1)}, opened' if w and hh else 'opened'
    if ffprobe and e in VIDEO:
        r = subprocess.run([ffprobe, '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path],
                           capture_output=True, text=True, timeout=120)
        try:
            dur = float(r.stdout.strip().splitlines()[0])
        except (ValueError, IndexError):
            return False, 'video could not be read'
        return (dur > 0), f'{dur:.1f} s video'
    return True, f'{size:,} bytes, header OK'


def cmd_spotcheck(a):
    root = resolve_root(a.root)
    seed = a.seed if a.seed is not None else int(time.time())
    rnd = random.Random(seed)
    groups = collections.defaultdict(list)
    for rel, p in walk_files(root):
        e = ext_of(rel)
        if e in PHOTO or e in VIDEO:
            top = rel.split('/')[0]
            groups[top if re.fullmatch(r'\d{4}', top) else 'other folders'].append((rel, p, e))
    magic_only = a.magic_only or os.environ.get('IPB_SPOTCHECK_MAGIC_ONLY') == '1'   # (the tests use made-up files)
    sips = None if magic_only else shutil.which('sips')
    ffprobe = None if magic_only else shutil.which('ffprobe')
    bad = total = 0
    with tempfile.TemporaryDirectory() as tmp:
        for key in sorted(groups):
            for rel, p, e in rnd.sample(groups[key], min(a.per_year, len(groups[key]))):
                total += 1
                try:
                    ok, detail = check_file(p, e, sips, ffprobe, tmp)
                except (OSError, subprocess.SubprocessError) as ex:
                    ok, detail = False, str(ex)
                bad += not ok
                print(f"  {'OK ' if ok else 'BAD'} {rel}  ({detail})")
    how = []
    if sips:
        how.append('photos opened with sips')
    if ffprobe:
        how.append('videos read with ffprobe')
    print(f"{total} random files checked from {len(groups)} year folder(s): {bad} problem(s). "
          f"[{', '.join(how) or 'file headers only'}; seed {seed}]")
    return 1 if bad else 0


# ---------------------------------------------------------------- manifest
def list_for_manifest(root):
    out, skipped = [], []
    for rel, p in walk_files(root):
        if rel.endswith('.part'):
            continue
        if '\t' in rel or '\n' in rel:
            skipped.append(rel)
            continue
        out.append((rel, p))
    return out, skipped


def hash_many(items, jobs):
    """items: [(rel, path)] -> {rel: (size, mtime_ns, sha256)}; prints progress to stderr."""
    total_bytes = 0
    stats = {}
    for rel, p in items:
        st = os.stat(p)
        stats[rel] = (st.st_size, st.st_mtime_ns)
        total_bytes += st.st_size
    result, done_b, last = {}, 0, time.time()
    t0 = last
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        futs = {ex.submit(sha256_file, p): rel for rel, p in items}
        for i, f in enumerate(concurrent.futures.as_completed(futs), 1):
            rel = futs[f]
            result[rel] = stats[rel] + (f.result(),)
            done_b += stats[rel][0]
            if time.time() - last > 5:
                last = time.time()
                rate = done_b / max(last - t0, 1e-6)
                left = (total_bytes - done_b) / rate if rate else 0
                print(f'  hashed {i:,}/{len(items):,} files, {gb(done_b)} of {gb(total_bytes)} '
                      f'({rate / 1e6:.0f} MB/s, ~{fmt_dur(left)} left)', file=sys.stderr)
    return result


def load_manifest(path):
    entries = {}
    for line in read_text(path).splitlines():
        if not line or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) == 4:
            sha, size, mt, rel = parts
            entries[rel] = (int(size), int(mt), sha)
        else:
            m = re.match(r'^([0-9a-f]{64})\s+\*?(.+)$', line)
            if m:
                entries[m.group(2)] = (None, None, m.group(1))
    return entries


def save_manifest(mdir, root, entries):
    stamp = time.strftime('%Y-%m-%d %H:%M:%S')
    rows = [f'# icloud-photos-backup manifest v1 - {stamp} - {len(entries)} files - sha256, size, mtime_ns, path']
    rows += [f'{sha}\t{size}\t{mt}\t{rel}' for rel, (size, mt, sha) in sorted(entries.items())]
    write_atomic(os.path.join(mdir, 'index.tsv'), '\n'.join(rows) + '\n')
    sums = [f'{sha}  {rel}' for rel, (_, _, sha) in sorted(entries.items())]
    write_atomic(os.path.join(mdir, 'SHA256SUMS'), '\n'.join(sums) + '\n')


def cmd_manifest(a):
    root = resolve_root(a.root)
    mdir = os.path.join(root, '_manifest')
    mpath = a.manifest or os.path.join(mdir, 'index.tsv')
    items, skipped = list_for_manifest(root)
    for rel in skipped:
        print('  skipped (tab or newline in the name):', rel)
    if a.action == 'create':
        if os.path.exists(mpath) and not a.force:
            print(f'A manifest already exists ({mpath}). Use "manifest update" to add new files, or --force.')
            return 1
        entries = hash_many(items, a.jobs)
        save_manifest(mdir, root, entries)
        print(f"Manifest created: {len(entries):,} files, {gb(sum(v[0] for v in entries.values()))} -> {mdir}/")
        print(f'Anyone can re-check it without this tool:  cd "{root}" && shasum -a 256 -c _manifest/SHA256SUMS')
        return 0
    old = load_manifest(mpath)
    if not old:
        print(f'No manifest at {mpath} - run "manifest create" first.')
        return 2
    if a.action == 'update':
        reuse, todo, changed = {}, [], []
        for rel, p in items:
            st = os.stat(p)
            o = old.get(rel)
            if o and o[0] == st.st_size and o[1] == st.st_mtime_ns:
                reuse[rel] = o
            else:
                todo.append((rel, p))
                if o:
                    changed.append(rel)
        fresh = hash_many(todo, a.jobs)
        changed = [rel for rel in changed if fresh[rel][2] != old[rel][2]]   # same bytes, new date = fine
        gone = sorted(set(old) - {rel for rel, _ in items})
        entries = dict(reuse)
        entries.update(fresh)
        save_manifest(mdir, root, entries)
        n_new = sum(1 for rel, _ in todo if rel not in old)
        print(f'Manifest updated: {len(entries):,} files ({n_new:,} new, '
              f'{len(changed):,} changed, {len(gone):,} no longer on the drive).')
        for rel in changed[:20]:
            print('  CHANGED (photos should never change - check this file):', rel)
        for rel in gone[:20]:
            print('  GONE:', rel)
        return 0
    # check
    present = dict(items)
    targets = [(rel, present[rel]) for rel in old if rel in present]
    missing = sorted(rel for rel in old if rel not in present)
    hashed = hash_many(targets, a.jobs)
    corrupt = sorted(rel for rel, v in hashed.items() if v[2] != old[rel][2])
    new = sorted(set(present) - set(old))
    print(f'Checked {len(hashed):,} files against {mpath}')
    print(f'  OK: {len(hashed) - len(corrupt):,}   CHANGED/CORRUPT: {len(corrupt):,}   MISSING: {len(missing):,}'
          f'   NEW since the manifest: {len(new):,}')
    for rel in corrupt[:30]:
        print('  CORRUPT:', rel)
    for rel in missing[:30]:
        print('  MISSING:', rel)
    for rel in new[:10]:
        print('  new:    ', rel)
    if corrupt or missing:
        print('Verdict: PROBLEMS FOUND - nothing was changed; compare with the other copy before doing anything.')
        return 1
    print('Verdict: every file matches its fingerprint.')
    return 0


# ---------------------------------------------------------------- find media outside the backup
JUNK_DIRS = {'node_modules', 'DerivedData', '__pycache__', 'venv', 'Caches', 'site-packages'}


def cmd_find_outside(a):
    root = resolve_root(a.root)
    rr = os.path.realpath(root)
    exts = PHOTO | VIDEO | (AUDIO if a.audio else set())
    by_size = collections.defaultdict(list)
    for rel, p in walk_files(root):
        if ext_of(rel) in exts:
            try:
                by_size[os.path.getsize(p)].append(p)
            except OSError:
                pass
    cache, rows = {}, []
    per_dir = collections.defaultdict(collections.Counter)
    for top in a.search:
        for dp, dns, fns in os.walk(top):
            real = os.path.realpath(dp)
            if real == rr or real.startswith(rr + os.sep):
                dns[:] = []
                continue
            dns[:] = sorted(d for d in dns if not d.startswith('.') and d not in JUNK_DIRS)
            for f in sorted(fns):
                if f.startswith('.') or ext_of(f) not in exts:
                    continue
                p = os.path.join(dp, f)
                try:
                    size = os.path.getsize(p)
                except OSError:
                    continue
                match = ''
                if size in by_size:
                    h = sha256_file(p)
                    for q in by_size[size]:
                        if q not in cache:
                            cache[q] = sha256_file(q)
                        if cache[q] == h:
                            match = os.path.relpath(q, root)
                            break
                rows.append((p, size, match))
                per_dir[dp]['in' if match else 'out'] += 1
    out = [r for r in rows if not r[2]]
    print(f'photos/videos found outside the backup: {len(rows):,}')
    print(f'  already in the backup (identical copy): {len(rows) - len(out):,}')
    print(f'  NOT in the backup:                      {len(out):,}  ({gb(sum(r[1] for r in out))})')
    ranked = sorted(per_dir.items(), key=lambda kv: -kv[1]['out'])
    if out:
        print('folders with the most files not in the backup:')
        for d, c in ranked[:20]:
            if c['out']:
                print(f"  {c['out']:6,} not in backup, {c['in']:6,} already in   {d}")
    if a.report:
        lines = ['status\tbytes\tpath\tbackup_copy'] + \
                [f"{'IN_BACKUP' if m else 'NOT_IN_BACKUP'}\t{s}\t{p}\t{m}" for p, s, m in rows]
        write_atomic(a.report, '\n'.join(lines) + '\n')
        print('report:', a.report)
    print('Nothing was copied or moved. Decide with the owner what to bring into the backup.')
    return 0


# ---------------------------------------------------------------- plan (used by orchestrate.sh)
def last_moment_before(mo):
    """'2023-02' -> '2023-01-31T23:59:59.999999' (icloudpd reads it as local time)."""
    y, m = int(mo[:4]), int(mo[5:7])
    y, m = (y, m - 1) if m > 1 else (y - 1, 12)
    return f'{y:04d}-{m:02d}-{calendar.monthrange(y, m)[1]:02d}T23:59:59.999999'


def cmd_plan(a):
    """Splits the to-do list into date ranges of roughly equal download time. Each range is whole
    months, ranges never overlap, and together they cover all time (the first is open towards now,
    the last towards the past), so every photo belongs to exactly one downloader."""
    dest = a.dest.rstrip('/') + '/'
    per_month = collections.defaultdict(list)
    for line in read_text(a.listing).splitlines():
        if not line.startswith(dest):
            continue
        rel = line[len(dest):].strip()
        m = re.match(r'^(\d{4})/(\d{2})/', rel)
        if m:
            per_month[f'{m.group(1)}-{m.group(2)}'].append(os.path.basename(rel))
    if not per_month:
        print('PLAN none (no year/month paths in the to-do list)', file=sys.stderr)
        return 0
    cost, files, est_bytes = {}, {}, 0.0
    for mo, names in per_month.items():
        kinds = kinds_in_folder(names)
        secs = 0.0
        for n in names:
            k = kinds[n] if kinds[n] in CLASS_MB else 'photo'
            secs += 0.4 + CLASS_MB[k] / 8.0          # request latency + size at ~8 MB/s per stream
            est_bytes += CLASS_MB[k] * 1e6
        cost[mo], files[mo] = secs, len(names)
    months = sorted(cost, reverse=True)              # newest first, the order icloudpd works in
    k = max(1, min(a.slices, len(months)))
    total = sum(cost.values())
    bounds, acc = [], 0.0                            # bounds[i] = oldest month of range i
    for i, mo in enumerate(months):
        acc += cost[mo]
        j = len(bounds)
        if j >= k - 1:
            break
        rem_months, rem_slices = len(months) - (i + 1), k - (j + 1)
        if acc >= total * (j + 1) / k or rem_months == rem_slices:
            bounds.append(mo)
    print(f'to-do: {sum(files.values()):,} files in {len(months)} months ({months[-1]} .. {months[0]}), '
          f'roughly {est_bytes / 1e9:,.0f} GB, ~{total / 3600:.1f} h with one downloader', file=sys.stderr)
    longest = 0.0
    for i in range(len(bounds) + 1):
        lo = bounds[i] if i < len(bounds) else None
        hi = bounds[i - 1] if i > 0 else None
        args = []
        if lo:
            args += ['--skip-created-before', f'{lo}-01T00:00:00']
        if hi:
            args += ['--skip-created-after', last_moment_before(hi)]
        ms = [m for m in months if (lo is None or m >= lo) and (hi is None or m < hi)]
        hours = sum(cost[m] for m in ms) / 3600
        longest = max(longest, hours)
        print(f'  s{i + 1}: {ms[-1]} .. {ms[0]}  {sum(files[m] for m in ms):7,} files  ~{hours:.1f} h', file=sys.stderr)
        print(f"SLICE s{i + 1} {' '.join(args)}".rstrip())
    print(f'ESTIMATE files={sum(files.values())} bytes={int(est_bytes)} '
          f'hours_one_stream={total / 3600:.1f} hours_split={longest:.1f}')
    return 0


# ---------------------------------------------------------------- session copy, filesystem facts
def session_valid(d):
    sessions = [f for f in os.listdir(d) if f.endswith('.session')]
    if not sessions:
        return False
    for f in os.listdir(d):
        p = os.path.join(d, f)
        if not os.path.isfile(p):
            continue
        text = read_text(p)
        if f.endswith('.session'):
            try:
                if not json.loads(text).get('session_token'):
                    return False
            except ValueError:
                return False
        elif text.startswith('#LWP-Cookies') and not text.endswith('\n'):
            return False
    return True


def cmd_copy_session(a):
    if not os.path.isdir(a.src) or not session_valid(a.src):
        print(f'no valid Apple session in {a.src} - sign in again with signin.sh', file=sys.stderr)
        return 1
    os.makedirs(a.dst, exist_ok=True)
    os.chmod(a.dst, 0o700)
    for _ in range(10):                      # retry if a running icloudpd was mid-write
        for f in os.listdir(a.src):
            p = os.path.join(a.src, f)
            if os.path.isfile(p):
                shutil.copy2(p, os.path.join(a.dst, f))
        if session_valid(a.dst):
            print(f'session copied to {a.dst}')
            return 0
        time.sleep(0.5)
    print(f'could not make a valid copy of the session in {a.dst}', file=sys.stderr)
    return 1


def cmd_fsinfo(a):
    path = os.path.realpath(a.path)
    while not os.path.exists(path) and path != '/':
        path = os.path.dirname(path)
    best, fstype = '/', ''
    out = subprocess.run(['mount'], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.match(r'^.+? on (.+?) type (\S+) \(', line) or re.match(r'^.+? on (.+?) \(([^,)]+)', line)
        if not m:
            continue
        mp = m.group(1)
        if (path == mp or path.startswith(mp.rstrip('/') + '/')) and len(mp) >= len(best):
            best, fstype = mp, m.group(2)
    du = shutil.disk_usage(path)
    internal = best in ('/', '/System/Volumes/Data', '/home')
    print(f'mount={best}\nfstype={fstype}\nfree_gb={du.free // 10**9}\ntotal_gb={du.total // 10**9}\n'
          f"internal={'yes' if internal else 'no'}")
    return 0


# ---------------------------------------------------------------- command line
def main(argv=None):
    ap = argparse.ArgumentParser(prog='ipb.py', description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('progress'); s.add_argument('root', nargs='?'); s.set_defaults(fn=cmd_progress)
    s = sub.add_parser('status'); s.set_defaults(fn=cmd_status)
    s = sub.add_parser('inventory'); s.add_argument('root', nargs='?'); s.set_defaults(fn=cmd_inventory)
    s = sub.add_parser('reconcile'); s.add_argument('root', nargs='?'); s.add_argument('--log')
    s.add_argument('--report'); s.set_defaults(fn=cmd_reconcile)
    s = sub.add_parser('dupes'); s.add_argument('root', nargs='?'); s.add_argument('--report'); s.set_defaults(fn=cmd_dupes)
    s = sub.add_parser('spotcheck'); s.add_argument('root', nargs='?'); s.add_argument('--per-year', type=int, default=4)
    s.add_argument('--seed', type=int); s.add_argument('--magic-only', action='store_true'); s.set_defaults(fn=cmd_spotcheck)
    s = sub.add_parser('manifest'); s.add_argument('action', choices=['create', 'update', 'check'])
    s.add_argument('root', nargs='?'); s.add_argument('--manifest'); s.add_argument('--jobs', type=int, default=4)
    s.add_argument('--force', action='store_true'); s.set_defaults(fn=cmd_manifest)
    s = sub.add_parser('find-outside'); s.add_argument('root', nargs='?'); s.add_argument('--search', nargs='+', required=True)
    s.add_argument('--audio', action='store_true'); s.add_argument('--report'); s.set_defaults(fn=cmd_find_outside)
    s = sub.add_parser('plan'); s.add_argument('listing'); s.add_argument('--dest', required=True)
    s.add_argument('--slices', type=int, default=3); s.set_defaults(fn=cmd_plan)
    s = sub.add_parser('copy-session'); s.add_argument('src'); s.add_argument('dst'); s.set_defaults(fn=cmd_copy_session)
    s = sub.add_parser('fsinfo'); s.add_argument('path'); s.set_defaults(fn=cmd_fsinfo)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == '__main__':
    sys.exit(main())
