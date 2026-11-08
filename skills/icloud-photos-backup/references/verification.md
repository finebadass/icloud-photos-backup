# Verifying a backup

Run `bash scripts/verify.sh` once the job says COMPLETE. It is read-only, it saves everything under
`<state>/logs/verify-<date>/`, and it exits 0 only if the exact check and the spot check both pass.

## 1. Exact check (`ipb.py reconcile`)

The last COMPLETE whole-library pass logged one line for every file of every iCloud item: either
"already exists" or "Downloaded". `reconcile` compares that list with the folder, path by path.

| Line | Meaning |
|---|---|
| items in iCloud | icloudpd's item count (not the number of files) |
| files those items produce | photos, plus the Live Photo videos, plus edited versions if `SIZES` includes `adjusted` |
| different file names | the files that should exist |
| MISSING | in iCloud's list, not on the drive. **Must be 0.** If it isn't, run `start.sh` again |
| EXTRA | on the drive, not in iCloud's list. Usually items deleted from iCloud after they were saved, or files added by hand. Never a problem by itself |

**Look-alike items.** These are two or more iCloud items with the same file name and the same
size in the same month. With the default naming they share one file. They are nearly always true
duplicates inside iCloud, for example a photo saved twice. A real library of about 81,000 items had 20 of
them.

- To get one file per item anyway, set up a **new** folder with `--file-match-policy name-id7`.

**Which log is used.** By default, the log of the last COMPLETE whole-library pass.

- A `--top-up` doesn't produce one, so run a full `start.sh` first.
- You can pass `--log FILE` to use another log.
- When checking a copy on another drive, pass that folder as ROOT. The log's paths are matched by
  their position inside the backup, not by drive name.

## 2. Inventory

`inventory` lists:

- photos, videos and Live Photo videos, with their sizes, per year
- file types
- leftover `.part` files, which mean unfinished downloads (run `start.sh`)
- files outside the year/month folders

"Live Photo videos" are an **estimate**: a video with the same base name as a photo in the same
folder is counted as a Live Photo video. Use the exact check for completeness, and the inventory
for the human summary.

## 3. Duplicates (`ipb.py dupes`)

The tool groups files by size, then compares the same-size files by SHA-256, so it is exact and
fast. It also lists browser-style names such as `photo (1).jpg`. Those only count as duplicates if
they also appear in an identical-content group.

**Before removing anything:**

1. Show the user each group: the paths, the size, and the fact that the content is identical.
2. Ask about those exact files.
3. Prefer moving extra copies into `<backup>/_quarantine-YYYYMMDD/` (keeping their relative path)
   over deleting them. The checks skip folders whose names start with `_`.
4. Never "clean up" the look-alike pairs from the exact check. They are already one file.

## 4. Spot check (`ipb.py spotcheck`)

The spot check picks 4 random files from every year folder (`--per-year N` changes that). It then
checks:

- that the file isn't empty
- that its header matches its type
- on macOS, that the photo actually decodes (`sips`)
- that a video has a readable duration (`ffprobe`)

The seed is printed, so a run can be repeated (`--seed`).

## 5. Manifest (`ipb.py manifest`)

| Command | What it does |
|---|---|
| `manifest create` | Hashes every file: about 1 hour per TB on a fast SSD. It writes `_manifest/index.tsv` and `_manifest/SHA256SUMS` inside the backup |
| `manifest update` | After a top-up: hashes only new or changed files. It warns if an existing photo's content changed, which should never happen |
| `manifest check [ROOT]` | Re-hashes everything and reports CORRUPT, MISSING and NEW files. Use it on the original once a year, and on every copy |

`SHA256SUMS` is in the standard format. Anyone can verify it without these tools:
`cd <backup> && shasum -a 256 -c _manifest/SHA256SUMS`.

## Explaining count differences to the user

- **Files are not items.** A Live Photo is 2 files. With `adjusted`, an edited photo is 2 files.
- **The iPhone's count can differ from iCloud's.** Common reasons:
  - the Hidden album (usually not included in icloudpd's list)
  - Recently Deleted
  - items still uploading: the iPhone shows "Uploading…" or "Paused" at the bottom of the library
  - a Shared Library, which is separate
  - Shared Albums, which are not part of the library at all
- **iCloud.com's count can differ from icloudpd's by a few.** Recently added items may still be
  processing, and a re-run picks them up.
- **The photos + videos count from the inventory vs icloudpd's item count.** The difference is the
  look-alike items plus Live Photo videos the estimate mislabels as plain videos. The exact check
  is the authority.

## Report template

> ✅ Backup complete and verified.
> - **Items:** N items from iCloud are now F files (P photos, V videos, L Live Photo videos),
>   S GB, from <first month> to <last month>.
> - **Exact check:** 0 missing; X look-alike items share a file; E extra files (why).
> - **Duplicates:** none, or G groups waiting for your decision.
> - **Spot check:** K random files from every year opened fine.
> - **Manifest:** created, or not yet.
> - **iCloud:** nothing was touched. The backup only downloads, and the delete options are blocked
>   in code.
