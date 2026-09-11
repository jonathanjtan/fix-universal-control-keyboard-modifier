# Deprecated

## `install-ucmodswap.sh`

The first attempt at this problem. **It does not work — don't run it.** Kept
because *why* it fails is the whole reason the real fix looks the way it does.

It tried to hold the swap in place with `hidutil`, re-applying it whenever the
Universal Control keyboard reconnected. Three things were wrong with that, in
increasing order of severity:

1. **It enumerated keyboards with `ioreg -c IOHIDDevice`.** Universal Control's
   virtual devices are IOHIDEventSystem services and never enter the
   IORegistry, so it found nothing and silently did nothing. Its log contained a
   single "started" line after seven hours of running.

2. **`hidutil` cannot modify those devices anyway.** Writes are accepted and
   echoed back as though they succeeded, then discarded — `--get` immediately
   afterwards returns null. The same sequence against a built-in keyboard
   persists correctly. So even with correct enumeration, the approach was dead.

3. **Its premise was wrong.** The header claimed the device's LocationID changes
   on every connect, churning the preference key
   (`com.apple.keyboard.modifiermapping.VID-PID-LOC`) and losing the setting.
   The LocationID is `0` and stable, and the preference is already saved
   correctly. macOS simply never re-applies it.

Smaller bugs it also had, none of which mattered given the above: the registry
class fallback list was unreachable because the first class always matched the
built-in keyboard and returned early; `excludeProducts: ["internal keyboard"]`
would also have excluded `V-Apple Internal Keyboard / Trackpad`; the helper
function was named `run`, which osascript invokes as the AppleScript run handler
with `argv`, printing a spurious error to stdout on every CLI invocation; and it
shelled out to `ioreg` and wrote a 2.5 MB plist to disk every two seconds,
indefinitely.

See the "Why the obvious approaches don't work" section of the top-level README.
