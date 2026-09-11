# fix-universal-control-keyboard-modifier

Swap <kbd>option</kbd> and <kbd>command</kbd> on a keyboard that reaches your Mac
over **Universal Control**, and make it stick across reconnects.

If you drive a Mac from another Mac's peripherals and the keyboard is a Windows
layout (<kbd>Ctrl</kbd> / <kbd>Win</kbd> / <kbd>Alt</kbd>), the modifiers land in
the wrong order. Setting **System Settings → Keyboard → Modifier Keys** appears to
work, but the choice is forgotten the next time Universal Control connects.

## Install

```sh
git clone https://github.com/jonathanjtan/fix-universal-control-keyboard-modifier
cd fix-universal-control-keyboard-modifier
./install.sh
```

Then grant Accessibility when asked: **System Settings → Privacy & Security →
Accessibility → ucmodswap**. That is the whole setup. The agent starts at login
and swaps only the keys arriving over Universal Control; the Mac's own built-in
keyboard is untouched.

Requires the Command Line Tools (`xcode-select --install`) for `swiftc`.

```sh
ucmodswap check     # is Accessibility granted?
ucmodswap probe     # print every modifier event and where it came from
./install.sh --uninstall
```

## Why the obvious approaches don't work

Worth writing down, because three plausible fixes all fail for the same
underlying reason.

**Universal Control's keyboard is not in the IORegistry.** It exists only as an
IOHIDEventSystem service. `hidutil` can see it; `ioreg` cannot:

```
$ ioreg -l | grep -c '"Product" = "V-'
0
$ hidutil list | grep 'V-'
0x483  0x5021  0x0  1  6  0xa79b6f8000066  USB  V-87EC-S
...
```

Anything that enumerates keyboards through IOKit — including most remapping
tools — will never find the device, so it silently does nothing.

**`hidutil` can see it but cannot change it.** Writes are accepted and echoed
back as though they succeeded, then discarded:

```
$ hidutil property --matching '{"VendorID":1155,"ProductID":20513}' \
      --set '{"UserKeyMapping":[...]}'      # prints the mapping back
$ hidutil property --matching '{"VendorID":1155,"ProductID":20513}' \
      --get UserKeyMapping
a79b6f8000066   UserKeyMapping   (null)     # nothing stuck
```

The identical sequence against the built-in keyboard persists fine. Matching by
`RegistryID` is not supported, `HIDKeyboardModifierMappingPairs` behaves the same
way, and a global unmatched `--set` reaches the built-in keyboard but not the
virtual one.

**The preference is saved correctly — macOS just never applies it.** The common
theory is that the device's `LocationID` changes on every connect, churning the
preference key. It doesn't; it is `0`, and the key is stable:

```
com.apple.keyboard.modifiermapping.1155-20513-0 = ( E2->E3, E3->E2, E6->E7, E7->E6 )
```

So System Settings does persist your choice under a stable key. The bug is that
the setting is never re-applied to the virtual device when it reappears. Writing
the preference yourself does not help for the same reason.

## What this does instead

The events never touch this Mac's HID layer, but they do reach the Quartz event
stream, so a `CGEventTap` rewrites them in flight.

The hard part is telling Universal Control's keyboard from this Mac's own, and
the two obvious fields are both useless here:

| field | internal keyboard | Universal Control |
|---|---|---|
| `kCGEventSourceUnixProcessID` | `0` | `0` |
| `kCGKeyboardEventKeyboardType` | `91` | `91` |

The source pid is 0 for both because Universal Control publishes HID devices
rather than calling `CGEventPost`, so its events enter through the HID layer just
like real hardware.

What does work is that a `CGEvent` wraps the `IOHIDEvent` it came from, and that
carries the originating service's registry ID:

```
CGEventCopyIOHIDEvent(event)  ->  IOHIDEventGetSenderID(hidEvent)  ->  0xa79b6f8000066
```

That value is per-device, and it is exactly what `hidutil list` prints in its
RegistryID column — so it resolves to a product name. Universal Control names
everything it publishes `V-<original name>`, which makes the rule a name pattern
that survives reconnects:

```
0x100000b48      Apple Internal Keyboard / Trackpad     pass through
0xa79b6f8000066  V-87EC-S                               SWAP
0xa79b6fe000067  V-Razer Pro Click                      SWAP
0xa79b6ee000064  V-Apple Internal Keyboard / Trackpad   pass through
```

Note the last line. The other Mac's *built-in* keyboard also arrives over
Universal Control, and it already has Mac modifier placement — swapping it would
break it. Hence the default pattern `" V-(?!Apple)"`.

Both `CGEventCopyIOHIDEvent` and `IOHIDEventGetSenderID` are private but
long-stable exports, resolved by name at startup so a missing symbol degrades to
"swap nothing" rather than crashing.

Other details that matter:

- Rewrites the `flagsChanged` keycode (55↔58, 54↔61) *and* the flag bits, both
  the documented `maskCommand`/`maskAlternate` and the `NX_DEVICE*` side bits
  that tell left from right. Apps that read the side bits directly — Electron
  ones especially — misbehave if only half the pair is swapped.
- The device table is rebuilt on a background queue every few seconds; the event
  callback only does a dictionary lookup. Shelling out to `hidutil` per event
  adds tens of milliseconds to every keystroke, and macOS silently disables an
  event tap whose callback is slow to return.
- The rule lives in `~/.config/ucmodswap/config.json` and reloads on `SIGHUP`, so
  changing it needs no rebuild — which matters, because rebuilding changes the
  code signature and costs the Accessibility grant.
- Re-arms itself when macOS disables the tap, and exits rather than polling when
  Accessibility has not been granted yet, because `AXIsProcessTrustedWithOptions`
  caches its answer for the life of the process. launchd restarts it, and the
  fresh process sees the new permission.

## Configuration

`~/.config/ucmodswap/config.json`:

```json
{
  "swapPattern": " V-(?!Apple)",
  "learnOnly": false,
  "refreshSeconds": 3
}
```

- `swapPattern` — case-insensitive regex tested against the device's row in
  `hidutil list`. Set it to `" V-"` to include Apple keyboards shared over
  Universal Control, or to something like `"V-87EC-S"` to target one keyboard.
- `learnOnly` — log what would be swapped, change nothing. Useful for finding
  the right pattern on a new setup.

Reload without restarting:

```sh
kill -HUP "$(pgrep -f ucmodswap.app)"
```

## Trade-offs

- **Accessibility permission is required.** Anything that rewrites keystrokes
  system-wide needs it; there is no way around it short of a kernel driver.
- **Rebuilding costs the Accessibility grant.** The app is ad-hoc signed, so each
  build has a new code identity and TCC treats it as a different program.
  Toggling the existing entry off and on does *not* rebind it — remove the row
  and add it again. Signing with a self-signed certificate from your keychain
  would make the grant survive rebuilds; that is not set up here.
- **Private API.** `CGEventCopyIOHIDEvent` / `IOHIDEventGetSenderID` are not
  public. They are resolved by name, so if a future macOS drops them the daemon
  stops swapping rather than crashing — but it would stop working.
- **The mouse is matched too.** `V-Razer Pro Click` and `V-UC Automouse` match
  the pattern. They emit no modifier keys in practice, so it is harmless; narrow
  `swapPattern` if you would rather be strict.

## Files

- `ucmodswap.swift` — the daemon
- `install.sh` — build, sign, install the LaunchAgent; `--uninstall` to remove
- `config.example.json` — the default config, copied to `~/.config/ucmodswap/`
- `APPLE-FEEDBACK.md` — a bug report for Apple; this should be fixed in the OS
- `deprecated/` — the first attempt, built on `hidutil`. It does not work; see
  `deprecated/README.md` for the post-mortem.
