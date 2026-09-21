# Windows messenger UI portable — 2026-09-21

Delivered package: `target/portable/Envelope-Windows-win-x64-1.0.1.20260921102828.zip`

- App version: `v1.0.1.20260921102828`, Windows file version `1.0.1.0`.
- Self-contained Windows x64, .NET 8 runtime included; extract all files and run `Envelope.Windows.exe`.
- ZIP: 73,684,882 bytes; SHA-256 `20e7b10e56ff4b671966f9ec67186960fd02072fe93184e3a2957dd9d15863f3`.
- EXE SHA-256: `a1c0257812b50a4982f67f6b87113311e19c5491fb3f7c39516e0c6935b507cc`.
- Previous unversioned portable ZIP and directory retained. Work continued on `master`; no branch, worktree, commit or push created.

## Changes

Messages is now the starting page. The shell uses a 68 px navigation rail and
280 px conversation list, with compact all/unread/group filters and a persistent
composer. Android's orange/cream palette, gray-green outgoing messages and original
launcher PNGs are reused. Windows ICO frames contain the Android PNG bytes rather
than generated illustrations. Settings and About remain accessible at the bottom.

Closing the window hides it to the system tray; explicit Quit ends reception.
The native tray menu has Open, temporary Do not disturb, Lock, Settings and Quit.
Unread counts survive background refresh and other pages. Generic count-only
notifications route to the affected conversation without displaying plaintext.
Session drafts stay with their conversation. Existing attachments, offline
envelopes, group invitations/management, delivery states and earlier messages remain.

## Verification

- Release build: zero warnings and errors.
- Existing verification harness: all 11 reported suites passed, including FFI,
  secure storage, backups, QR, delivery reliability, groups and networking.
- UI harness: 28 checks passed, including unread transitions with unchanged total
  count, no startup backlog notifications, DND expiry, hidden/background read
  boundaries, drafts, bound list refresh, native tray menu callback wiring,
  hide/restore/explicit close, minimum size and dark-theme text contrast.
- Real WPF renders for all five pages, 960x640 minimum size, dark theme and English;
  no binding errors. Screenshots use explicit synthetic fixtures in the test project,
  not product demo data or the user's message history.
- ZIP extracted into a separate directory: 477 files; EXE and ZIP hashes matched;
  `coreclr.dll` present. Extracted program started under isolated profile roots with
  shell registration disabled. Computer Use clicked the real Close button: window
  disappeared, PID 15860 stayed responsive. A second invocation exited with code 0
  and restored the same original window handle, 10620754. The isolated test process
  was then terminated for cleanup; actual process exit via the tray was not driven
  through the OS UI. Menu exit routing and window explicit-close are harness-tested.
- Android source PNG and WPF resource PNG SHA-256 matched.

Logs and render evidence: `target/ui-redesign-evidence/build.log`, `ui-final.log`,
`windows-chat-light.png`, `windows-chat-compact.png`, and other page PNGs.

This verifies packaging and the local UI lifecycle. Real cross-device message/file
delivery, system notification display/click behavior under the user's Windows
notification policy, and interactive Windows Hello remain live acceptance checks.
No production server, user identity, or user file associations were changed by smoke tests.

## Rebuild

```powershell
./scripts/build-windows-wpf.ps1 -SelfContained -AppVersion v1.0.1.20260921102828 -BuildName 1.0.1 -PackageSuffix 1.0.1.20260921102828
```

The source tree also contains pre-existing in-progress work. This release was built
from the current complete working tree; it is not tied to a newly created Git commit.
