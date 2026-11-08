# Freeing up the iPhone after the backup

Claude can't touch the phone. Give exact steps, one at a time. Menu names below are English; other
languages use their own names in the same places.

## The one fact that matters

With **iCloud Photos** turned on, **deleting a photo on the iPhone deletes it from iCloud** and from
every other device. It goes to Recently Deleted for 30 days, then it is gone for good.

So never suggest deleting photos to save space while sync is on. And never suggest "cleaner" apps:
they delete for real.

## Option A: Optimize iPhone Storage (keeps everything in sync)

**Settings > [name] > iCloud > Photos > Optimize iPhone Storage.**

- The phone keeps small previews and fetches the full photo when you open it.
- It frees space by itself, gradually, and only when the phone runs low. Nothing can force it.
- It can't free a photo that hasn't uploaded yet.

## Option B: Turn off iCloud Photos on this iPhone (frees almost all photo space)

### Checklist before doing it. All of it

1. **The backup is verified:** `verify.sh` shows `RESULT: OK`.
2. **The iPhone has finished uploading.** Open Photos > Library and scroll to the very bottom.
   - "Synced" or "Updated just now" means it's done.
   - "Uploading N items" means wait, on Wi-Fi and the charger, ideally overnight.
   - **"Paused" with "Not enough storage"** means the phone is too full to even upload.
     1. Free 2-3 GB first: Settings > General > iPhone Storage > pick a big app > **Offload App**.
        That keeps the app's data; **Delete App** doesn't.
     2. Then wait for the upload to finish.
3. **Compare the counts.** The iPhone's count (Photos > profile picture) should match the
   `iCloud:` line in `status.sh`, apart from a small gap.
   - If the gap matches the **Hidden** album's count (Albums > Utilities > Hidden), that's fine.
   - If the phone has more items and they aren't hidden, they may not be uploaded yet. **Stop
     here.**

### Steps

1. **Settings > [name] > iCloud > Photos >** turn off **Sync this iPhone**.
2. Choose **Remove from iPhone**.
   - Not "Download Photos & Videos": that tries to download everything to the phone.
3. Removal runs in the background and takes minutes to hours for big libraries. The Photos app
   can still show everything for a while.
   - Keep the phone charging.
   - Restart it after an hour if nothing changed.
   - Check progress in Settings > General > iPhone Storage > Photos.
4. **If nothing happens after a few hours and a restart:**
   - With sync definitely **off**, deleting photos on the phone no longer touches iCloud.
   - Check that the switch is grey, and check that icloud.com still shows everything.
   - Only then select all in Photos and delete, then empty Recently Deleted.

## Afterwards

- **New photos and videos stay only on this phone.** They are not uploaded and not backed up to
  iCloud Photos.
  - Copy them off regularly, for example with AirDrop to the Mac.
  - A normal iCloud Backup of the phone (Settings > [name] > iCloud > iCloud Backup) includes the
    photo library when iCloud Photos is off. That gives a safety net.
- **Turning sync back on later** downloads the library to the phone again.
  - With "Optimize iPhone Storage" chosen, that means previews only: a few GB for tens of
    thousands of items, so space fills up again partly.
  - Never choose "Download and Keep Originals" on a phone smaller than the library.
- **On a new or erased iPhone,** signing in and turning on iCloud Photos brings the whole library
  back.

## Voice memos and other synced apps

Voice Memos (with iCloud on) behave like photos: deleting a recording on the phone deletes it
everywhere. Save them first; see `extras.md`.
