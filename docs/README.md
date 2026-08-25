# docs

- [`PLAN.md`](PLAN.md) — design, architecture, and the history of decisions
  behind the app. Read this first for the "why."
- [`Unload.applescript`](Unload.applescript) — the original manual
  AppleScript this app replaces. Kept for historical reference; no longer
  used or maintained.

## Predecessor projects

This app's lineage traces back through two earlier scripts by the same
author, written for Outlook rather than Mail.app:

- [outlook-documents-vba](https://github.com/CosmicCEO/outlook-documents-vba)
- [outlook-documents-applescript](https://github.com/CosmicCEO/outlook-documents-applescript) —
  "Selectively handle attachments in Outlook for Mac using AppleScript. Tidy
  and clean up. Save server space." Written against Outlook 2016 on macOS
  10.11+; pushed `.office`-type attachments to a synced folder (box.com) so
  they'd land in the cloud instead of bloating the mailbox.

`Unload.applescript` is the macOS Mail (rather than Outlook) evolution of
that idea, and this app is the fully-automated evolution of `Unload.applescript`.
