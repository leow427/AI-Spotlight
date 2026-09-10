# Screen-sharing privacy (checkpoint 7)

The chat panel and the owned Settings window set `NSWindow.sharingType = .none`
before attaching their content and before their first presentation. This is
always enabled and survives closing/reopening the windows. The panel stays
visible and editable locally; capture exclusion does not dismiss it or stop a
response. The existing manual hide shortcuts are unchanged.

## Zoom compatibility

Zoom is the primary target. The flag requests exclusion from capture clients
that honor the legacy macOS window-sharing setting. It does not establish
universal invisibility, including for system-owned menus or separate popups.

Apple now describes [SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)
as legacy. [Electron's content-protection documentation](https://www.electronjs.org/docs/latest/api/browser-window#winsetcontentprotectionenable-macos-windows)
confirms that its equivalent macOS flag can be ignored by ScreenCaptureKit.
Research found no supported general-purpose replacement appropriate for this
simple AppKit prototype, so this checkpoint uses the requested legacy flag.

Zoom documents capture choices under **Settings > Share Screen > Advanced**,
including Auto and Legacy/Previous operating systems, with availability depending
on the operating system. If a legacy option is available, it is worth testing;
its compatibility with this flag is an inference, not a Zoom guarantee.
See [Zoom's advanced screen-sharing settings](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0063824).
Enigma does not change Zoom's preferences.

## Verify with Zoom

1. Run the updated app and join a test Zoom meeting from a second device or
   participant. Record macOS version, Zoom version, and capture mode.
2. Share the entire display. Open the panel over another window, type, resize,
   and move it while watching the receiving participant's screen. The desired
   result is an interactive local panel with the underlying content visible to
   the participant, without a blank rectangle or panel shadow.
3. Start sharing both before and after opening Enigma. Stop/restart the
   share, reopen the panel, and open Settings and the model menu. Check each
   surface on the receiving screen.
4. Repeat with the capture modes offered by the installed Zoom version,
   especially Auto and any legacy option. Separately test sharing an individual
   application window; that result does not prove whole-display exclusion.

Automated tests verify early flag configuration, local visibility/editability,
and persistence across reopening. They do not verify Zoom's outgoing stream.
A two-participant Zoom compatibility check remains manual.

Local validation on 2026-09-04 with Xcode 26.6: shared-scheme build and static
analysis succeeded; all 62 tests passed.
