# Apple Feedback Assistant report

Copy the sections below into Feedback Assistant. Filing instructions are at the
bottom.

**Area:** macOS → Universal Control (or Keyboard, if Universal Control is not
offered as a category)

---

## Title

Universal Control ignores modifier key remapping on both the sending and
receiving Mac

## Summary

When a keyboard is shared to another Mac over Universal Control, modifier key
remapping is not applied — in either direction:

1. **The sending Mac's remapping is not carried over.** A keyboard with
   Option/Command swapped in System Settings on the host Mac arrives at the
   receiving Mac with the original, unswapped modifier layout.

2. **The receiving Mac's own remapping does not persist.** Setting Modifier Keys
   for the virtual keyboard in System Settings on the receiving Mac appears to
   work, and the preference is written to disk under a stable key, but it is
   never re-applied when Universal Control reconnects.

The result is that a Windows-layout keyboard (Ctrl / Win / Alt) cannot be made
to behave like a Mac keyboard on the receiving Mac, even though it has been
configured correctly on the Mac it is physically attached to.

There is no supported way to fix this. The virtual keyboard Universal Control
publishes is not present in the IORegistry, so `hidutil` and every IOKit-based
remapping tool cannot address it either.

## Steps to reproduce

1. Attach a third-party keyboard with a Windows layout to Mac A.
2. On Mac A, open System Settings → Keyboard → Keyboard Shortcuts → Modifier
   Keys, select that keyboard, and swap Option and Command. Confirm it works
   locally on Mac A.
3. Use Universal Control to move to Mac B and type there.
4. On Mac B, open System Settings → Keyboard → Keyboard Shortcuts → Modifier
   Keys, select the Universal Control keyboard, swap Option and Command, and
   click Done. Confirm the swap now works on Mac B.
5. Disconnect and reconnect Universal Control — move the pointer back to Mac A,
   then over to Mac B again. (Sleeping or locking either Mac also triggers it.)
6. Type on Mac B again.

## Expected

Either the remapping configured on Mac A applies to the events Universal Control
forwards, or the remapping configured on Mac B for that device persists across
reconnects. Ideally the first, since that setting already exists and is where a
user would expect to configure the keyboard they own.

## Actual

The keyboard reverts to its unmapped layout on Mac B at step 6. The setting made
in step 4 has to be redone after every reconnect, and is lost again immediately.

## Diagnostic detail

Collected on the receiving Mac (Mac B).

**The preference is saved correctly and under a stable key.** The claim that the
device's LocationID changes on every connect is not the cause — it is `0`, and
the key does not churn:

```
$ defaults -currentHost read -g | grep -A6 modifiermapping.1155-20513-0
"com.apple.keyboard.modifiermapping.1155-20513-0" = (
    { HIDKeyboardModifierMappingDst = 30064771299;
      HIDKeyboardModifierMappingSrc = 30064771298; },
    ...
);
```

So the setting persists on disk. It is simply never re-applied to the device.

**The virtual device is absent from the IORegistry**, so no IOKit-based tool can
reach it:

```
$ ioreg -l | grep -c '"Product" = "V-87EC-S"'
0
$ hidutil list | grep 'V-87EC-S'
0x483  0x5021  0x0  1   6   0xa7e7e8c000071  USB  (null)  V-87EC-S  (null)  0
0x483  0x5021  0x0  12  1   0xa7e7e8200006d  USB  (null)  V-87EC-S  (null)  0
```

**`hidutil` accepts writes to the device and silently discards them.** The
`--set` call prints the mapping back as though it succeeded; an immediate `--get`
returns null:

```
$ hidutil property --matching '{"VendorID":1155,"ProductID":20513}' \
      --set '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x7000000E2,
                                 "HIDKeyboardModifierMappingDst":0x7000000E3}]}'
RegistryID       Key              Value
a7e7e8c000071    UserKeyMapping   ( { ...the mapping, echoed back... } )

$ hidutil property --matching '{"VendorID":1155,"ProductID":20513}' \
      --get UserKeyMapping
RegistryID       Key              Value
a7e7e8c000071    UserKeyMapping   (null)
```

The identical sequence against this Mac's built-in keyboard persists correctly,
so this is specific to the Universal Control virtual devices. Setting
`HIDKeyboardModifierMappingPairs` instead behaves the same way, and a global
`--set` with no `--matching` reaches the built-in keyboard but not the virtual
one.

**Universal Control's device registry IDs change on every reconnect** (observed
`0xa79b6f8000066` → `0xa7e7e8c000071` across one reconnect), which may be related
to why the saved preference is not re-matched to the device.

## Workaround

A `CGEventTap` that rewrites `flagsChanged` / `keyDown` / `keyUp` events in the
Quartz stream. Distinguishing the Universal Control keyboard from the local one
requires reading the sender ID from the `IOHIDEvent` behind each `CGEvent`, since
`kCGEventSourceUnixProcessID` is `0` for both and `kCGKeyboardEventKeyboardType`
is identical for both. That relies on private API, needs an Accessibility grant,
and should not be necessary for something System Settings already offers a UI
for.

## Configuration

- Receiving Mac: MacBook Air (Mac17,3), Apple M5, macOS 26.6.2 (25G83)
- Keyboard: generic USB Windows-layout keyboard, VID 0x483 / PID 0x5021,
  published by Universal Control as `V-87EC-S`
- Reproduces every time, on every reconnect

---

## How to file

1. Open **Feedback Assistant** (in `/System/Applications/Utilities/`, or
   <https://feedbackassistant.apple.com>).
2. Choose **macOS** → the area that best matches (Universal Control, or Keyboard).
3. Paste the sections above. Feedback Assistant will offer to attach a
   sysdiagnose — accept it; it captures the HID and Universal Control state that
   makes this actionable.
4. Attach `~/Library/Logs/ucmodswap.log` if you want to show the per-device
   evidence directly.
