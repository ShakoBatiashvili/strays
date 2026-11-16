#!/bin/bash
# Verifies Strays' safety claims from the source (and the built app, if present).
# Anyone can run this before trusting a build. Exit code is non-zero if any check fails.
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
pass() { printf "  \033[32mPASS\033[0m  %s\n" "$1"; }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; shift; for l in "$@"; do echo "          $l"; done; FAIL=1; }
note() { printf "  \033[33mINFO\033[0m  %s\n" "$1"; }

# Matches in code only (comment-only lines are ignored).
code_grep() { grep -rnE --include='*.swift' "$1" Sources 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|///)' || true; }

# <description> <regex> [allowed-file-regex]
check_none() {
  local hits; hits="$(code_grep "$2")"
  [ -n "${3:-}" ] && hits="$(echo "$hits" | grep -vE "$3" || true)"
  if [ -z "$hits" ]; then pass "$1"; else fail "$1" "$hits"; fi
}

echo "Source checks"
check_none "No internet APIs (URLSession, Network.framework, WebKit, CFNetwork)" \
  'import Network|import WebKit|URLSession|URLRequest|NWConnection|NWListener|NWPathMonitor|CFNetwork|CFSocket|WKWebView|MultipeerConnectivity|getaddrinfo|gethostbyname'
check_none "Sockets only in LocalSockets (loopback probe, Docker unix socket) and PortAvailability (bind test)" \
  '[^a-zA-Z_.]socket\(' 'Sources/StraysSystem/(LocalSockets|SettingsStore)\.swift'
check_none "Outgoing connections only to 127.0.0.1, ::1 or a unix socket" \
  'inet_addr\("[^1]|inet_addr\("1[^2]|inet_pton'
check_none "No privilege escalation (sudo, helpers, daemons, setuid)" \
  'SMJobBless|SMAppService\.(daemon|agent|loginItem)|AuthorizationExecute|sudo|setuid|seteuid'
check_none "No shell invocation (/bin/sh, /bin/zsh, /bin/bash, osascript; the snapshot's made-up process table is data)" \
  '"/bin/(sh|zsh|bash)"|/usr/bin/osascript' 'Sources/StraysApp/Snapshot\.swift'
check_none "No private APIs or dynamic code loading (dlopen, NSClassFromString, ...)" \
  'dlopen|dlsym|NSClassFromString|NSSelectorFromString|performSelector|objc_getClass|PrivateFrameworks'
check_none "Subprocesses only in LaunchdReader (fixed /bin/launchctl list)" \
  'Process\(\)|NSTask|posix_spawn|popen\(|[^a-zA-Z_.]system\(' 'Sources/StraysSystem/Readers\.swift'
check_none "Signals only sent by Stopper (after a live PID + start-time + owner check)" \
  '[^a-zA-Z_.]kill\(|killpg\(' 'Sources/StraysSystem/Stopper\.swift'
check_none "AppleScript only in Actions.jumpToTab (fixed scripts for Terminal and iTerm2)" \
  'NSAppleScript' 'Sources/StraysApp/Support\.swift'
check_none "Claude Code token files (*.key) are never opened" \
  '"\.key"|\.key"\)|hasSuffix\("\.key|appendingPathExtension\("key'
check_none "No file writes outside settings (no FileManager.createFile / write(to:) in the app or libraries)" \
  'createFile\(|\.write\(to:|FileHandle\(forWritingTo|FileHandle\(forUpdating' 'Sources/StraysApp/Snapshot\.swift'

if grep -qE '^\s*\.package\(' Package.swift; then
  fail "No third-party dependencies" "$(grep -nE '^\s*\.package\(' Package.swift)"
else
  pass "No third-party dependencies (Package.swift has no .package entries)"
fi
[ -e Package.resolved ] && fail "No lockfile of external packages" "Package.resolved exists" || pass "No Package.resolved (nothing external to pin)"

script_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
code_version="$(sed -n 's/.*public static let version = "\(.*\)"/\1/p' Sources/StraysCore/CLI.swift)"
[ -n "$script_version" ] && [ "$script_version" = "$code_version" ] \
  && pass "Version is consistent (build script and CLI both say $script_version)" \
  || fail "Version is consistent" "scripts/build-app.sh: '$script_version'  Sources/StraysCore/CLI.swift: '$code_version'"

echo
echo "Built app checks"
APP="${APP:-dist/Strays.app}"   # override to audit a build elsewhere
if [ ! -d "$APP" ]; then
  note "dist/Strays.app not found; run scripts/build-app.sh to check the binary too"
else
  if codesign --verify --strict "$APP" 2>/dev/null; then pass "Code signature is valid and strict"; else fail "Code signature is valid and strict"; fi

  flags="$(codesign -dv "$APP" 2>&1 | grep -E 'flags=' || true)"
  echo "$flags" | grep -q 'runtime' && pass "Hardened runtime enabled ($flags)" || fail "Hardened runtime enabled" "$flags"

  ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '?')"
  [ "$ents" = '{"com.apple.security.automation.apple-events":true}' ] \
    && pass "Only entitlement: Apple Events (for Show terminal tab)" \
    || fail "Only entitlement: Apple Events (for Show terminal tab)" "$ents"

  helper_ents="$(codesign -d --entitlements - "$APP/Contents/Helpers/strays" 2>/dev/null | grep -vE '^Executable=' | tr -d '[:space:]')"
  [ -z "$helper_ents" ] && pass "CLI helper requests no entitlements" || fail "CLI helper requests no entitlements" "$helper_ents"

  plist="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$plist" >/dev/null 2>&1 \
    && fail "No custom URL scheme (nothing a web page can trigger)" || pass "No custom URL scheme (nothing a web page can trigger)"
  usage="$(/usr/libexec/PlistBuddy -c 'Print' "$plist" 2>/dev/null | grep -E 'UsageDescription' | grep -v NSAppleEventsUsageDescription || true)"
  [ -z "$usage" ] && pass "No privacy permissions requested beyond Apple Events" || fail "No privacy permissions requested beyond Apple Events" "$usage"
  [ -z "$(find "$APP" -path '*LaunchDaemons*' -o -path '*LaunchAgents*' 2>/dev/null)" ] \
    && pass "No launchd daemon/agent plists bundled" || fail "No launchd daemon/agent plists bundled"
  [ -z "$(find "$APP" -name '*.framework' -o -name '*.dylib' 2>/dev/null)" ] \
    && pass "No bundled frameworks or dylibs (nothing to swap or update)" || fail "No bundled frameworks or dylibs" "$(find "$APP" -name '*.framework' -o -name '*.dylib')"

  extra="$(find "$APP/Contents/Resources" -type f ! -name 'AppIcon.icns' 2>/dev/null)"
  [ -z "$extra" ] && pass "Resources contain only the app icon" || fail "Resources contain only the app icon" "$extra"

  net="$(otool -L "$APP/Contents/MacOS/Strays" "$APP/Contents/Helpers/strays" | grep -E 'WebKit|Network\.framework|MultipeerConnectivity|CFNetwork' || true)"
  [ -z "$net" ] && pass "Binaries do not link WebKit, Network.framework or CFNetwork" || fail "Binaries do not link WebKit, Network.framework or CFNetwork" "$net"

  # Raw byte scan of the whole bundle (not `strings`, which only reads Mach-O sections and can miss data).
  homes="$(LC_ALL=C grep -raoE '/Users/[A-Za-z0-9._-]+' "$APP" 2>/dev/null | sed 's/^[^:]*://' \
    | grep -vxF -e '/Users/Shared' -e '/Users/demo' -e '/Users/dev' | sort -u || true)"
  [ -z "$homes" ] && pass "No build-machine home path or username in the binaries" \
    || fail "No build-machine home path or username in the binaries" "$homes"

  urls="$(LC_ALL=C grep -aoE 'https?://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+' \
      "$APP/Contents/MacOS/Strays" "$APP/Contents/Helpers/strays" 2>/dev/null \
    | grep -vE 'apple\.com|w3\.org|swift\.org|schemas\.|ns\.adobe|purl\.org|:https?://localhost:?$' | sort -u || true)"
  [ -z "$urls" ] && pass "No hard-coded URLs in the binaries (beyond localhost and Apple/standards namespaces)" \
    || fail "No hard-coded URLs in the binaries" "$urls"
fi

echo
if [ "$FAIL" -eq 0 ]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit "$FAIL"
