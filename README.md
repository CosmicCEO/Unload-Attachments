# Unload Attachments

A macOS menu bar app that watches an iCloud Mail inbox and automatically moves
large Office/PDF attachments out of incoming email into iCloud Drive —
replacing them with a summary table and download links, right in the message,
on every device.

## What it does

1. Runs quietly in the menu bar (no Dock icon, no windows).
2. Connects directly to iCloud Mail over IMAP and either waits on a push
   connection (IMAP IDLE) or polls, so new mail is picked up within seconds.
3. When a new message contains Office or PDF attachments (`xls`, `xlsx`,
   `doc`, `docx`, `ppt`, `pptx`, `pdf`):
   - Each attachment is decoded from the message and saved into iCloud
     Drive ▸ Documents ▸ `unloader-files`, organized **by year** or **by
     type** (your choice).
   - The message **on the server** is replaced with a slimmed copy: same
     subject, sender, date, and thread — but with the attachments removed
     and a table inserted at the top linking to the saved files (a
     `file://` link for this Mac, and an emailable `https://` iCloud
     download link that works from any device, including iPhone).
   - The original, untouched message is preserved — either archived to an
     "Unloaded Originals" mailbox (default) or deleted, per your setting.
   - The processed message is flagged green, and a notification and a
     green dot on the menu bar icon confirm what happened.
4. Images and other file types are left alone.

## Why IMAP instead of scripting Mail.app

An earlier version of this app drove Mail.app via AppleScript/ScriptingBridge.
That approach hit a hard wall: modern Mail.app rejects **every** scripted
attempt to modify a received message (save an attachment, delete an
attachment, edit the body) with an AppleEvent error. Reads still work, but
mutation does not. The app now speaks IMAP directly to iCloud Mail's server,
which allows real message replacement — restoring the original goal of
in-email links that work from any device. See
[`docs/PLAN.md`](docs/PLAN.md) for the full history and design rationale.

## Requirements

- macOS 14 or later.
- An iCloud Mail account with an **app-specific password**
  (generate one at [appleid.apple.com](https://appleid.apple.com) ▸
  Sign-In and Security ▸ App-Specific Passwords — your regular Apple ID
  password will not work here).

## Setup

1. Build and run the app in Xcode, or launch the built `.app`.
2. Open the menu bar icon ▸ **Mail Account…** and enter your iCloud email
   address and app-specific password, then **Test & Save**. The password
   is stored in the Keychain; nothing else leaves your Mac except the IMAP
   connection to `imap.mail.me.com`.
3. Turn on **Monitor for New Mail** (on by default) and leave the app
   running. Use **Process Inbox Now** to check immediately.

## Menu options

| Item | Effect |
|---|---|
| Monitor for New Mail | Starts/stops the background watcher |
| Process Inbox Now | Checks immediately instead of waiting for push/poll |
| Organize Files | Save attachments **By Year** or **By Type** |
| Flag Processed Emails | Adds a green flag to messages that were unloaded |
| Originals | **Archive** the original to "Unloaded Originals" (default) or **Delete** it once the slimmed copy is safely stored |
| Open Save Folder / Choose Save Folder… | View or relocate where attachments are saved |
| Mail Account… | Configure the iCloud IMAP account |
| Launch at Login | Registers the app as a login item |

## Project layout

- `Unload Attachments/` — the Swift app (SwiftUI menu bar app, IMAP client,
  MIME parser/rebuilder, attachment saving, settings).
- `docs/` — [`PLAN.md`](docs/PLAN.md), the design/architecture document, and
  [`Unload.applescript`](docs/Unload.applescript), the original manual
  AppleScript this app replaces, kept for historical reference.

## Status

Actively developed. The IMAP backend lives on the `imap-backend` branch
pending merge to `main`.
