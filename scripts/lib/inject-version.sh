# Inject release version into Sources/BarkVisorCore/Config.swift
#
# Source after ROOT is set:
#   # shellcheck source=lib/inject-version.sh
#   source "$ROOT/scripts/lib/inject-version.sh"
#   barkvisor_inject_config_version "1.2.3"
#
# Matches any current string in:
#   public static let version = "…"
# so scripts do not break when the in-tree default changes (e.g. 0.0.0-dev).

barkvisor_inject_config_version() {
  local version="${1:?version required}"
  local config="${2:-}"
  local root="${ROOT:-}"

  if [[ -z "$config" ]]; then
    if [[ -n "$root" ]]; then
      config="$root/Sources/BarkVisorCore/Config.swift"
    else
      config="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/Sources/BarkVisorCore/Config.swift"
    fi
  fi

  if [[ ! -f "$config" ]]; then
    echo "error: Config.swift not found: $config" >&2
    return 1
  fi

  # Refuse characters that would break the Swift string literal or sed.
  if [[ "$version" == *"\""* || "$version" == *$'\n'* || "$version" == *"\\"* ]]; then
    echo "error: version must not contain quotes, backslashes, or newlines: $version" >&2
    return 1
  fi

  if ! grep -qE '^[[:space:]]*public static let version = "' "$config"; then
    echo "error: version assignment not found in $config" >&2
    return 1
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' -E \
      's|^([[:space:]]*public static let version = ")[^"]*(".*)|\1'"${version}"'\2|' \
      "$config"
  else
    sed -i -E \
      's|^([[:space:]]*public static let version = ")[^"]*(".*)|\1'"${version}"'\2|' \
      "$config"
  fi

  if ! grep -F "public static let version = \"${version}\"" "$config" >/dev/null; then
    echo "error: failed to inject version '${version}' into $config" >&2
    return 1
  fi

  echo "injected Config.version = \"${version}\" → $config"
}
