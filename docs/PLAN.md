# Unload Attachments — Design & Plan

This document explains what the app does, why it's built the way it is, and
what was tried and abandoned along the way. It supersedes the various
scratch plans written during development; keep it updated when the design
changes.

## 1. Origin and goal

The project started as a manual AppleScript (`docs/Unload.applescript`,
itself a macOS Mail port of an older Outlook VBA script) that a user ran by
hand, with messages selected in Mail.app, to save Office/PDF attachments to
disk, strip them from the email, and prepend an HTML summary table with
links to the saved files.

The goal of the rewrite was to make this **automatic and backgrounded** —
a macOS app that watches an inbox and does this to every qualifying message
without manual intervention — while preserving the original premise: the
attachment is gone from the email, and a working link to it is left behind,
readable from any device.

## 2. Why direct IMAP instead of scripting Mail.app

The first working version drove Mail.app through ScriptingBridge/AppleScript
from a `MenuBarExtra` app. This got attachment saving working, but hit a wall
that no amount of AppleScript phrasing could fix: **modern Mail.app rejects
every scripted attempt to modify a received message** — `save` on an
attachment, `delete` on an attachment, and `set content of message` all fail
with "AppleEvent handler failed" (error ‑10000). Reading a message (`source`,
properties) still works; message-level operations (move whole message,
delete whole message) still work; only *content mutation* is blocked.

Workarounds were tried in order:
1. Scripted save → broken, confirmed above.
2. Extract the attachment by MIME-decoding `source of theMessage` (still
   works) instead of asking Mail to save it → attachment saving fixed, but
   removing it from the email and rewriting the body were still blocked.
3. Accept the limitation: save files, flag the message, notify — leave the
   email itself untouched. This shipped and worked, but gave up the
   in-email-links premise entirely.
4. **Bypass Mail.app.** Connect directly to the mail server over IMAP.
   Reading and — critically — **replacing a message** are both ordinary IMAP
   operations (`APPEND` a new message, `MOVE`/delete the old one), so the
   original premise becomes achievable again. This is the current design.

## 3. Scope decision: iCloud Mail only

The app targets `imap.mail.me.com` with an **app-specific password**
(generated at appleid.apple.com, stored in the Keychain) rather than a
general multi-provider IMAP client with OAuth. This kept the IMAP client
small and let it be hand-rolled (no third-party dependencies) against one
well-behaved server, rather than building general-purpose robustness against
arbitrary IMAP servers and OAuth flows for providers like Gmail.

## 4. Architecture

All Mail I/O runs off the main thread so the menu bar UI never blocks on a
network round trip.

| File | Role |
|---|---|
| `Unload_AttachmentsApp.swift` | `MenuBarExtra` scene, menu bar icon (with unseen-count badge), the menu UI |
| `MailMonitor.swift` | `@MainActor @Observable` — owns the polling/IDLE loop, activity log, notifications, unseen badge count. The only class that touches UI state |
| `MailBridge.swift` | `MailWorker` actor — owns the IMAP session and the full per-message pipeline |
| `IMAPClient.swift` | Minimal hand-rolled IMAP4rev1 client (`actor` over `Network.framework`/TLS): LOGIN, SELECT, UID SEARCH/FETCH/STORE/MOVE/EXPUNGE, APPEND, CREATE, IDLE |
| `MIMEMessage.swift` | Parses a raw RFC 822 message into a part tree; rebuilds it with attachment parts removed and a summary injected, preserving every original header |
| `AttachmentUnloader.swift` | Folder/naming logic, writing decoded attachment data to disk, iCloud link publishing, HTML/plain summary rendering |
| `KeychainStore.swift` | Stores/retrieves the app-specific password |
| `AccountSettingsView.swift` | Account setup window with a live "Test & Save" connection check |
| `Settings.swift` | All `UserDefaults`-backed settings (`AppSettings`) and their keys |

### Concurrency model

- `MailWorker` is an `actor`; it's the only thing that talks to `IMAPClient`
  (also an `actor`), so only one command is ever in flight on the IMAP
  socket. `MailMonitor.processNow()` deliberately does **not** run a second
  poll concurrently with the monitor loop — it wakes the loop's IDLE wait (or
  cancels its fallback sleep) and lets the loop perform the single check, to
  avoid interleaving two callers' commands/responses on one connection.
- `MailMonitor` is `@MainActor`; every other type touched by the pipeline
  (`MIMEMessage`, `AttachmentUnloader`, the model structs) is `nonisolated`
  and `Sendable` so they can run freely on `MailWorker`'s executor.

## 5. Per-message pipeline

1. **Wake**: IMAP IDLE (RFC 2177) suspends `MailWorker` until the server
   reports inbox activity, re-issued every 25 minutes to stay under the
   protocol's 29-minute limit. If IDLE isn't available, `MailMonitor` falls
   back to interval polling (default 30s).
2. **Checkpoint**: `MailWorker.checkNewMail()` compares the mailbox's
   `UIDVALIDITY`/`UIDNEXT` against a stored checkpoint. On first connection
   (or if the server resets its UID space), the checkpoint is set to
   `UIDNEXT − 1` and nothing is processed — **mail history is never
   touched**, only mail that arrives after that point.
3. **Fetch & parse**: each new UID's raw message is fetched and parsed by
   `MIMEMessage` into a part tree. Messages carrying the app's own
   `X-Unloaded-By` header are skipped (never reprocess our own output).
4. **Extract**: leaf parts whose extension is in the Office/PDF set
   (`xls xlsx doc docx ppt pptx pdf`) are decoded and written to
   iCloud Drive ▸ Documents ▸ `unloader-files`, in a year or type subfolder
   per the **Organize Files** setting. Other attachments (e.g. images) are
   left untouched and just noted in the summary as "left in place".
5. **Publish a link**: for each saved file, `AttachmentUnloader` waits for
   the iCloud upload to finish, then calls
   `FileManager.url(forPublishingUbiquitousItemAt:)` to get an emailable
   `https://` download URL. This link works from any device; it's separate
   from the `file://` link, which only resolves on this Mac.
6. **Rebuild**: `MIMEMessage.rebuiltRemoving(...)` produces the slimmed
   message: attachment parts removed, an HTML summary table (with both
   links, plus the human-readable save location) injected into the
   existing HTML part — or, if the original was plain-text only, the body
   is **upgraded to `multipart/alternative`** so the formatted table still
   renders instead of dumping raw text. **Every original header is copied
   verbatim** — `Message-ID`, `In-Reply-To`, `References`, `From`, `Date`,
   `Subject` — so the replacement is indistinguishable from the original
   for threading purposes on every client, including when someone replies
   to it later.
7. **Swap on the server**, per the **Originals** setting:
   - *Archive* (default): move the original to an "Unloaded Originals"
     mailbox **first**, then `APPEND` the slimmed copy to INBOX. If the
     append fails, the original is still safe in that mailbox (the error
     message says so).
   - *Delete*: `APPEND` the slimmed copy first, then delete the original —
     ordered so a failure never loses the only copy of the message.
   - The slimmed copy is flagged `\Flagged` (green) when **Flag Processed
     Emails** is on, and keeps the original's `\Seen` state.
8. **Report**: the activity log, a system notification, and a green dot on
   the menu bar icon (cleared when the user actually opens the menu — see
   below) reflect what happened, including any per-attachment failures.

## 6. Notable implementation details

- **Menu bar badge**: `MailMonitor.unseenCount` drives a green dot drawn
  onto a non-template `NSImage` (the menu bar renders template images
  monochrome, which would turn a colored dot gray). The badge is cleared on
  `NSMenu.didBeginTrackingNotification` — the actual "user opened the menu"
  signal — rather than a SwiftUI view lifecycle hook. An earlier attempt
  cleared it from the menu content view's `init`, which fired every time the
  icon (and therefore the menu scene) re-rendered, clearing the dot before
  the user ever saw it.
- **Plain-text-only bodies**: if the original message had no HTML part, the
  rebuild synthesizes one (escaping the original plain text into a `<pre>`
  block) rather than falling back to a plain-text summary that would have
  to inline the full, very long iCloud download URL in raw text.
- **iCloud publish errors**: the link-publishing step waits for
  `URLResourceKey.ubiquitousItemIsUploadedKey` to go true before calling the
  publish API, instead of calling it immediately and retrying on failure —
  the retry approach worked but spammed the system log with
  `NSFileProviderError`/`BRCloudDocsError` on every premature attempt.

## 7. Known limitations

- iCloud Mail only; no Gmail/Exchange/generic-IMAP support.
- Published iCloud download links expire (~1 month); the `file://` link and
  the plain-text save-location note are permanent references on this Mac.
- MIME structures the parser can't confidently rebuild are left unprocessed
  for that message (logged, not silently corrupted) rather than guessed at.
- Single account; no multi-account support.

## 8. Verification approach

The MIME parser/rebuilder is exercised with a standalone Swift harness (not
part of the app target) against synthetic messages covering:
multipart/alternative with multiple attachments, plain-text-only bodies,
HTML-only bodies, RFC 2047/2231 encoded filenames, quoted-printable bodies,
and truncated/malformed boundaries. Everything else (the IMAP pipeline, the
menu, notifications, the badge) has been verified end-to-end against a real
iCloud account and checked on both Mac and iPhone Mail.
