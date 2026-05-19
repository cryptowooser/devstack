#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/pi-sync.sh [--prune] [--dry-run] [--no-update] [--manifest PATH]

Sync installed pi packages to the canonical manifest in pi-packages.json.

Options:
  --prune        Remove user/project package entries not listed in the manifest.
  --dry-run, -n  Print planned pi remove/install/update commands without running them.
  --no-update    Skip the final `pi update --extensions` pass.
  --manifest PATH
                 Use a different manifest path.
  --help, -h     Show this help.

Without --prune, only manifest-declared legacy replacements are removed before
missing canonical packages are installed. With --prune, local path/dev installs,
old plugins, and project-local package entries are removed unless they are listed
in the manifest with "scope": "local".
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/pi-packages.json"
PRUNE=false
DRY_RUN=false
UPDATE=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prune)
      PRUNE=true
      shift
      ;;
    --no-prune)
      PRUNE=false
      shift
      ;;
    --dry-run|-n)
      DRY_RUN=true
      shift
      ;;
    --no-update)
      UPDATE=false
      shift
      ;;
    --update)
      UPDATE=true
      shift
      ;;
    --manifest)
      if [ "$#" -lt 2 ]; then
        echo "error: --manifest requires a path" >&2
        exit 2
      fi
      MANIFEST="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -f "$MANIFEST" ]; then
  echo "error: manifest not found: $MANIFEST" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to parse $MANIFEST" >&2
  exit 1
fi

if [ "$DRY_RUN" != true ] && ! command -v pi >/dev/null 2>&1; then
  echo "error: pi is required unless --dry-run is used" >&2
  exit 1
fi

PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
USER_SETTINGS="$PI_AGENT_DIR/settings.json"
LOCAL_SETTINGS="$REPO_ROOT/.pi/settings.json"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

node - "$MANIFEST" "$USER_SETTINGS" "$LOCAL_SETTINGS" "$PRUNE" "$TMP_DIR" <<'NODE'
const fs = require('fs');
const path = require('path');

const [manifestPath, userSettingsPath, localSettingsPath, pruneFlag, outDir] = process.argv.slice(2);
const prune = pruneFlag === 'true';

function readJson(filePath, fallback) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    if (error && error.code === 'ENOENT') return fallback;
    throw new Error(`Failed to read JSON ${filePath}: ${error.message}`);
  }
}

function normalizeScope(value, fallback = 'user') {
  const scope = value || fallback;
  if (scope === 'global') return 'user';
  if (scope !== 'user' && scope !== 'local' && scope !== 'both') {
    throw new Error(`Unsupported package scope "${scope}". Use "user", "local", or "both".`);
  }
  return scope;
}

function normalizePackage(entry, index) {
  if (typeof entry === 'string') {
    return { source: entry, scope: 'user' };
  }
  if (!entry || typeof entry !== 'object') {
    throw new Error(`packages[${index}] must be a source string or object`);
  }
  if (!entry.source || typeof entry.source !== 'string') {
    throw new Error(`packages[${index}].source must be a non-empty string`);
  }
  const scope = normalizeScope(entry.scope || (entry.local ? 'local' : 'user'));
  if (scope === 'both') {
    throw new Error(`packages[${index}] cannot use scope "both"; choose "user" or "local"`);
  }
  return { source: entry.source, scope };
}

function normalizeRemoval(entry, index, sourceName) {
  if (typeof entry === 'string') {
    return [{ source: entry, scope: 'user' }];
  }
  if (!entry || typeof entry !== 'object') {
    throw new Error(`${sourceName}[${index}] must be a source string or object`);
  }
  if (!entry.source || typeof entry.source !== 'string') {
    throw new Error(`${sourceName}[${index}].source must be a non-empty string`);
  }
  const scope = normalizeScope(entry.scope || (entry.local ? 'local' : 'user'));
  if (scope === 'both') {
    return [
      { source: entry.source, scope: 'user' },
      { source: entry.source, scope: 'local' },
    ];
  }
  return [{ source: entry.source, scope }];
}

function settingsPackages(filePath) {
  const settings = readJson(filePath, {});
  if (!Array.isArray(settings.packages)) return [];
  return settings.packages.filter((source) => typeof source === 'string' && source.length > 0);
}

function writeList(name, values) {
  fs.writeFileSync(path.join(outDir, `${name}.txt`), values.join('\n') + (values.length ? '\n' : ''));
}

const manifest = readJson(manifestPath, null);
if (!manifest || typeof manifest !== 'object') {
  throw new Error(`Manifest must be a JSON object: ${manifestPath}`);
}

const packages = (manifest.packages || []).map(normalizePackage);
if (!packages.length) {
  throw new Error(`Manifest has no packages: ${manifestPath}`);
}

const canonical = { user: new Set(), local: new Set() };
for (const pkg of packages) {
  if (canonical[pkg.scope].has(pkg.source)) {
    throw new Error(`Duplicate ${pkg.scope} package in manifest: ${pkg.source}`);
  }
  canonical[pkg.scope].add(pkg.source);
}
for (const source of canonical.user) {
  if (canonical.local.has(source)) {
    throw new Error(`Package cannot be both user and local canonical: ${source}`);
  }
}

const explicitRemovals = { user: new Set(), local: new Set() };
const removalBlocks = [
  ['removeBefore', manifest.removeBefore || []],
  ['legacyPackages', manifest.legacyPackages || []],
  ['prune.remove', (manifest.prune && manifest.prune.remove) || []],
];
for (const [name, entries] of removalBlocks) {
  if (!Array.isArray(entries)) {
    throw new Error(`${name} must be an array when present`);
  }
  entries.flatMap((entry, index) => normalizeRemoval(entry, index, name)).forEach((entry) => {
    if (!canonical[entry.scope].has(entry.source)) {
      explicitRemovals[entry.scope].add(entry.source);
    }
  });
}

const installed = {
  user: settingsPackages(userSettingsPath),
  local: settingsPackages(localSettingsPath),
};

function uniqueInOrder(values) {
  const seen = new Set();
  return values.filter((value) => {
    if (seen.has(value)) return false;
    seen.add(value);
    return true;
  });
}

function planScope(scope) {
  const canonicalSet = canonical[scope];
  const explicitSet = explicitRemovals[scope];
  const remove = uniqueInOrder(installed[scope].filter((source) => {
    if (explicitSet.has(source)) return true;
    return prune && !canonicalSet.has(source);
  }));
  const removeSet = new Set(remove);
  const installedAfterRemove = new Set(installed[scope].filter((source) => !removeSet.has(source)));
  const install = packages
    .filter((pkg) => pkg.scope === scope)
    .map((pkg) => pkg.source)
    .filter((source) => !installedAfterRemove.has(source));
  return { remove, install };
}

const plan = {
  manifest: manifestPath,
  prune,
  settings: {
    user: userSettingsPath,
    local: localSettingsPath,
  },
  canonical: {
    user: packages.filter((pkg) => pkg.scope === 'user').map((pkg) => pkg.source),
    local: packages.filter((pkg) => pkg.scope === 'local').map((pkg) => pkg.source),
  },
  installed,
  user: planScope('user'),
  local: planScope('local'),
};

writeList('canonical-user', plan.canonical.user);
writeList('canonical-local', plan.canonical.local);
writeList('remove-user', plan.user.remove);
writeList('remove-local', plan.local.remove);
writeList('install-user', plan.user.install);
writeList('install-local', plan.local.install);
fs.writeFileSync(path.join(outDir, 'summary.json'), `${JSON.stringify(plan, null, 2)}\n`);
NODE

list_count() {
  if [ ! -s "$1" ]; then
    echo 0
  else
    wc -l < "$1" | tr -d ' '
  fi
}

print_list() {
  label="$1"
  file="$2"
  count="$(list_count "$file")"
  echo "$label ($count):"
  if [ "$count" = "0" ]; then
    echo "  - none"
  else
    sed 's/^/  - /' "$file"
  fi
}

run_pi() {
  if [ "$DRY_RUN" = true ]; then
    printf '+ (cd %q && pi' "$REPO_ROOT"
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf ')\n'
  else
    (cd "$REPO_ROOT" && pi "$@")
  fi
}

echo "Syncing pi packages from $MANIFEST"
echo "User settings: $USER_SETTINGS"
echo "Project settings: $LOCAL_SETTINGS"
echo "Prune: $PRUNE"
print_list "Canonical user packages" "$TMP_DIR/canonical-user.txt"
print_list "Canonical project-local packages" "$TMP_DIR/canonical-local.txt"
print_list "User packages to remove" "$TMP_DIR/remove-user.txt"
print_list "Project-local packages to remove" "$TMP_DIR/remove-local.txt"
print_list "User packages to install" "$TMP_DIR/install-user.txt"
print_list "Project-local packages to install" "$TMP_DIR/install-local.txt"

while IFS= read -r source || [ -n "$source" ]; do
  [ -z "$source" ] && continue
  run_pi remove "$source"
done < "$TMP_DIR/remove-user.txt"

while IFS= read -r source || [ -n "$source" ]; do
  [ -z "$source" ] && continue
  run_pi remove "$source" -l
done < "$TMP_DIR/remove-local.txt"

while IFS= read -r source || [ -n "$source" ]; do
  [ -z "$source" ] && continue
  run_pi install "$source"
done < "$TMP_DIR/install-user.txt"

while IFS= read -r source || [ -n "$source" ]; do
  [ -z "$source" ] && continue
  run_pi install "$source" -l
done < "$TMP_DIR/install-local.txt"

if [ "$UPDATE" = true ]; then
  run_pi update --extensions
fi

echo "pi package sync complete. Run 'pi list' to inspect the active package list."
