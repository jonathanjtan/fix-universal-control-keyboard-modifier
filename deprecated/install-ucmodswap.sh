#!/bin/bash
# uc-modswap installer -- one file, no dependencies, no sudo, no kernel extension.
#
# Keeps option<->command swapped on the keyboard Universal Control hands to this
# Mac, re-applying it every time the virtual keyboard reconnects.
#
#   bash install-ucmodswap.sh              install and start
#   bash install-ucmodswap.sh --uninstall  remove everything it wrote
#
set -euo pipefail

LABEL="local.uc-modswap"
APPDIR="$HOME/.local/share/uc-modswap"
BINDIR="$HOME/.local/bin"
CFGDIR="$HOME/.config/uc-modswap"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_="$(id -u)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This only makes sense on macOS." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  /usr/bin/osascript -l JavaScript "$APPDIR/uc-modswap.js" unmap 2>/dev/null || true
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BINDIR/uc-modswap"
  rm -rf "$APPDIR" "$HOME/.local/state/uc-modswap"
  echo "Removed. Config left at $CFGDIR and log at ~/Library/Logs/uc-modswap.log."
  exit 0
fi

mkdir -p "$APPDIR" "$BINDIR" "$CFGDIR" "$HOME/Library/LaunchAgents"

cat > "$APPDIR/uc-modswap.js" <<'UCMODSWAP_JS_EOF'
// uc-modswap - keep option<->command swapped on Universal Control keyboards.
//
// macOS forgets the System Settings "Modifier Keys" choice for the virtual
// keyboard Universal Control publishes, because the device's LocationID (part
// of the preference key com.apple.keyboard.modifiermapping.VID-PID-LOC) is new
// on every connect. This watches for the device and re-applies the swap with
// hidutil, which works on the live device and needs no special permissions.
//
// Run:  osascript -l JavaScript uc-modswap.js [--list|--once|--unmap|--verbose]

ObjC.import('Foundation');

var HOME    = ObjC.unwrap($.NSHomeDirectory());
var CFGPATH = HOME + '/.config/uc-modswap/config.json';
var LOGPATH = HOME + '/Library/Logs/uc-modswap.log';
var STATE   = HOME + '/.local/state/uc-modswap';
var IOREG   = STATE + '/ioreg.plist';

var ARGS = [];
try {
  var a = $.NSProcessInfo.processInfo.arguments;
  for (var i = 0; i < a.count; i++) ARGS.push(ObjC.unwrap(a.objectAtIndex(i)));
} catch (e) {}
// Accepts "list" or "--list"; osascript eats leading dashes inconsistently.
function flag(f) {
  for (var i = 0; i < ARGS.length; i++) {
    if (ARGS[i].replace(/^--?/, '') === f) return true;
  }
  return false;
}

var VERBOSE = flag('verbose') || flag('list') || flag('once') || flag('unmap');

var DEFAULTS = {
  pollSeconds: 2,
  // Applied to every keyboard that is not built into this Mac, minus the
  // exclusions. Names are case-insensitive regexes matched against Product.
  excludeProducts: ['internal keyboard'],
  onlyProducts: [],
  includeBuiltIn: false,
  matchKeys: ['VendorID', 'ProductID', 'LocationID'],
  reverifyEveryNTicks: 10,
  restartAfterSeconds: 21600
};

// HID usage IDs, offset by 0x700000000 per Apple TN2450.
var SRC = 'HIDKeyboardModifierMappingSrc';
var DST = 'HIDKeyboardModifierMappingDst';
var SWAP = [
  ['0x7000000E2', '0x7000000E3'],  // left option  -> left command
  ['0x7000000E3', '0x7000000E2'],  // left command -> left option
  ['0x7000000E6', '0x7000000E7'],  // right option  -> right command
  ['0x7000000E7', '0x7000000E6']   // right command -> right option
];

// ---------------------------------------------------------------- plumbing

function run(path, args) {
  var task = $.NSTask.alloc.init;
  task.launchPath = path;
  task.arguments = args;
  var o = $.NSPipe.pipe, e = $.NSPipe.pipe;
  task.standardOutput = o;
  task.standardError = e;
  try { task.launch; } catch (err) { return { code: -1, out: '', err: String(err), data: null }; }
  var od = o.fileHandleForReading.readDataToEndOfFile;
  var ed = e.fileHandleForReading.readDataToEndOfFile;
  task.waitUntilExit;
  var dec = function (d) {
    try { return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(d, $.NSUTF8StringEncoding)) || ''; }
    catch (x) { return ''; }
  };
  return { code: task.terminationStatus, out: dec(od), err: dec(ed), data: od };
}

function mkdirp(p) {
  try {
    $.NSFileManager.defaultManager
      .createDirectoryAtPathWithIntermediateDirectoriesAttributesError(p, true, $(), null);
  } catch (e) {}
}

function log(msg) {
  var line = '[' + new Date().toISOString().replace('T', ' ').slice(0, 19) + '] ' + msg;
  if (VERBOSE) console.log(line);
  try {
    var fm = $.NSFileManager.defaultManager;
    mkdirp(HOME + '/Library/Logs');
    if (!fm.fileExistsAtPath(LOGPATH)) {
      $('').writeToFileAtomicallyEncodingError(LOGPATH, true, $.NSUTF8StringEncoding, null);
    }
    var fh = $.NSFileHandle.fileHandleForWritingAtPath(LOGPATH);
    if (fh && !fh.isNil()) {
      fh.seekToEndOfFile;
      fh.writeData($(line + '\n').dataUsingEncoding($.NSUTF8StringEncoding));
      fh.closeFile;
    }
  } catch (e) {}
}

function rotateLog() {
  try {
    var at = $.NSFileManager.defaultManager.attributesOfItemAtPathError(LOGPATH, null);
    if (at && !at.isNil() && ObjC.unwrap(at.objectForKey('NSFileSize')) > 1048576) {
      $.NSFileManager.defaultManager.removeItemAtPathError(LOGPATH, null);
    }
  } catch (e) {}
}

function loadConfig() {
  var cfg = {};
  for (var k in DEFAULTS) cfg[k] = DEFAULTS[k];
  try {
    var s = $.NSString.stringWithContentsOfFileEncodingError(CFGPATH, $.NSUTF8StringEncoding, null);
    if (s && !s.isNil()) {
      var user = JSON.parse(ObjC.unwrap(s));
      for (var j in user) cfg[j] = user[j];
    }
  } catch (e) {
    log('config at ' + CFGPATH + ' is not valid JSON, using defaults: ' + e);
  }
  return cfg;
}

// ------------------------------------------------------------- enumeration

var IOREG_CLASSES = ['IOHIDDevice', 'IOHIDInterface', 'AppleUserHIDDevice'];

function keyboardsForClass(cls) {
  mkdirp(STATE);
  var r = run('/usr/sbin/ioreg', ['-a', '-r', '-d', '1', '-c', cls]);
  if (!r.data) return [];
  try { r.data.writeToFileAtomically(IOREG, true); } catch (e) { return []; }

  var list = [];
  try {
    var arr = $.NSArray.arrayWithContentsOfFile(IOREG);
    if (arr && !arr.isNil()) {
      for (var i = 0; i < arr.count; i++) list.push(arr.objectAtIndex(i));
    } else {
      var one = $.NSDictionary.dictionaryWithContentsOfFile(IOREG);
      if (one && !one.isNil()) list.push(one);
    }
  } catch (e) { return []; }

  var out = [];
  for (var n = 0; n < list.length; n++) {
    var d = list[n];
    var get = (function (dict) {
      return function (key) {
        try {
          var v = dict.objectForKey(key);
          if (!v || v.isNil()) return null;
          return ObjC.unwrap(v);
        } catch (x) { return null; }
      };
    })(d);
    if (get('PrimaryUsagePage') !== 1 || get('PrimaryUsage') !== 6) continue;
    var bi = get('Built-In');
    out.push({
      Product: get('Product') || '(unnamed)',
      VendorID: get('VendorID'),
      ProductID: get('ProductID'),
      LocationID: get('LocationID'),
      Transport: get('Transport') || '',
      BuiltIn: bi === true || bi === 1
    });
  }
  return out;
}

function hidKeyboards() {
  // Registry class names have shifted across macOS releases; take the first
  // class that actually reports keyboards.
  for (var i = 0; i < IOREG_CLASSES.length; i++) {
    var ks = keyboardsForClass(IOREG_CLASSES[i]);
    if (ks.length) {
      var seen = {}, uniq = [];
      ks.forEach(function (d) {
        var id = idOf(d);
        if (!seen[id]) { seen[id] = true; uniq.push(d); }
      });
      return uniq;
    }
  }
  return [];
}

function rxAny(patterns, s) {
  for (var i = 0; i < patterns.length; i++) {
    try { if (new RegExp(patterns[i], 'i').test(s)) return true; } catch (e) {}
  }
  return false;
}

function isTarget(d, cfg) {
  if (d.BuiltIn && !cfg.includeBuiltIn) return false;
  if (cfg.onlyProducts && cfg.onlyProducts.length) return rxAny(cfg.onlyProducts, d.Product);
  return !rxAny(cfg.excludeProducts || [], d.Product);
}

function idOf(d) { return [d.VendorID, d.ProductID, d.LocationID].join('-'); }
function describe(d) {
  return '"' + d.Product + '" vid=' + d.VendorID + ' pid=' + d.ProductID +
         ' loc=' + d.LocationID + (d.Transport ? ' via ' + d.Transport : '');
}

// ---------------------------------------------------------------- mapping

function matchDict(d, keys) {
  var parts = [];
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i], v = d[k];
    if (v === null || v === undefined) continue;
    parts.push(typeof v === 'number'
      ? '"' + k + '":' + v
      : '"' + k + '":"' + String(v).replace(/["\\]/g, '\\$&') + '"');
  }
  return '{' + parts.join(',') + '}';
}

function mapJSON(clear) {
  if (clear) return '{"UserKeyMapping":[]}';
  var parts = SWAP.map(function (p) {
    return '{"' + SRC + '":' + p[0] + ',"' + DST + '":' + p[1] + '}';
  });
  return '{"UserKeyMapping":[' + parts.join(',') + ']}';
}

function apply(d, cfg, clear) {
  return run('/usr/bin/hidutil',
    ['property', '--matching', matchDict(d, cfg.matchKeys), '--set', mapJSON(clear)]);
}

function verify(d, cfg) {
  var r = run('/usr/bin/hidutil',
    ['property', '--matching', matchDict(d, cfg.matchKeys), '--get', 'UserKeyMapping']);
  return r.out.indexOf('HIDKeyboardModifierMapping') !== -1;
}

// ------------------------------------------------------------------- modes

function printList(cfg) {
  var ks = hidKeyboards();
  if (!ks.length) {
    console.log('No keyboard-class HID devices found. Is ioreg readable?');
    return;
  }
  console.log('Keyboards visible to this Mac right now:\n');
  ks.forEach(function (d) {
    var t = isTarget(d, cfg);
    console.log('  ' + (t ? '[SWAP]    ' : '[ignored] ') + describe(d) +
                (d.BuiltIn ? ' (built-in)' : '') +
                (t ? '  mapped=' + (verify(d, cfg) ? 'yes' : 'no') : ''));
  });
  console.log('\nEdit ' + CFGPATH + ' to change which ones get swapped.');
}

function tick(cfg, state) {
  var seen = {};
  var targets = hidKeyboards().filter(function (d) { return isTarget(d, cfg); });

  targets.forEach(function (d) {
    var id = idOf(d);
    seen[id] = true;
    var attempted = Object.prototype.hasOwnProperty.call(state.applied, id);
    // Untried devices are handled at once; ones we have already dealt with
    // (including ones that refused the mapping) only on the reverify tick.
    if (attempted && state.ticks % cfg.reverifyEveryNTicks !== 0) return;
    if (state.applied[id] === true && verify(d, cfg)) return;

    var was = state.applied[id];
    apply(d, cfg, false);
    var ok = verify(d, cfg);
    state.applied[id] = ok;
    if (ok) {
      log('swapped option<->command on ' + describe(d));
    } else if (was !== false) {
      log('hidutil would not take the mapping on ' + describe(d) +
          ' -- run "uc-modswap list" and try trimming matchKeys in ' + CFGPATH);
    }
  });

  Object.keys(state.applied).forEach(function (id) {
    if (!seen[id]) { delete state.applied[id]; log('keyboard ' + id + ' disconnected'); }
  });
  state.ticks++;
}

function main() {
  var cfg = loadConfig();

  if (flag('list')) { printList(cfg); return; }

  if (flag('unmap')) {
    hidKeyboards().filter(function (d) { return isTarget(d, cfg); }).forEach(function (d) {
      apply(d, cfg, true);
      log('cleared mapping on ' + describe(d));
    });
    return;
  }

  rotateLog();
  var state = { applied: {}, ticks: 0 };

  if (flag('once')) { tick(cfg, state); return; }

  log('uc-modswap started (poll ' + cfg.pollSeconds + 's)');
  var started = Date.now();
  while (true) {
    try { tick(cfg, state); } catch (e) { log('tick error: ' + e); }
    if (cfg.restartAfterSeconds > 0 &&
        (Date.now() - started) / 1000 > cfg.restartAfterSeconds) {
      log('scheduled restart');
      return;  // launchd KeepAlive brings it straight back
    }
    $.NSThread.sleepForTimeInterval(cfg.pollSeconds);
  }
}

main();
UCMODSWAP_JS_EOF

if [ ! -f "$CFGDIR/config.json" ]; then
  cat > "$CFGDIR/config.json" <<'UCMODSWAP_CFG_EOF'
{
  "_comment": "Every keyboard that is NOT built into this Mac gets option<->command swapped, minus anything matching excludeProducts. Patterns are case-insensitive regexes tested against the device's Product name. Set onlyProducts to a non-empty list to switch to an allowlist instead.",
  "pollSeconds": 2,
  "excludeProducts": ["internal keyboard"],
  "onlyProducts": [],
  "includeBuiltIn": false,
  "matchKeys": ["VendorID", "ProductID", "LocationID"]
}
UCMODSWAP_CFG_EOF
fi

cat > "$BINDIR/uc-modswap" <<WRAP_EOF
#!/bin/sh
exec /usr/bin/osascript -l JavaScript "$APPDIR/uc-modswap.js" "\$@"
WRAP_EOF
chmod +x "$BINDIR/uc-modswap"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/osascript</string>
    <string>-l</string>
    <string>JavaScript</string>
    <string>$APPDIR/uc-modswap.js</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/uc-modswap.err.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
launchctl kickstart -k "gui/$UID_/$LABEL" >/dev/null 2>&1 || true

echo "Installed and running."
echo "  daemon   $APPDIR/uc-modswap.js"
echo "  agent    $PLIST"
echo "  config   $CFGDIR/config.json"
echo "  log      ~/Library/Logs/uc-modswap.log"
echo "  cli      $BINDIR/uc-modswap  (list | once | unmap | verbose)"
echo
sleep 1
/usr/bin/osascript -l JavaScript "$APPDIR/uc-modswap.js" list || true
echo
echo "If the Universal Control keyboard is connected it should be marked [SWAP]"
echo "with mapped=yes. If it says mapped=no, tail the log for the reason."
