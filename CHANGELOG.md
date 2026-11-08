# Changelog

## 0.1.0 (first public version)

- **Backup:** a whole-library backup with icloudpd 1.33.0 (pinned and checksum-verified).
  - Parallel date ranges that can't overlap, then a final whole-library pass.
  - Automatic retries, a watchdog for hung passes, and a drive guard and space guard.
  - Locks, so two downloaders never write the same files.
- **Sign-in:** happens only in the user's own terminal, with Advanced Data Protection and
  mainland-China support.
- **Checks:**
  - an exact check against icloudpd's own file list
  - an inventory
  - an exact-duplicate scan
  - a spot check that opens random files from every year
  - a SHA-256 manifest that standard tools can verify
- **Other tools:** quick top-ups, stop and resume, plain-language status, and a finder for media
  that is elsewhere on a drive but not in the backup.
- **Guides:** freeing up the iPhone safely, second-drive copies, restore, voice memos and WhatsApp
  exports.
- **Tests:** 100+ checks against a fake icloudpd, run on macOS and Linux in CI.
