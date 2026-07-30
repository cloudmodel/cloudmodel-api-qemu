#!/bin/sh
# install.sh — prepare the host for `rake dev:net:{up,down,status,plan}`.
#
# Deliberately does very little and nothing dangerous: it validates the Ruby
# version, marks the standalone helpers executable, and checks the optional
# socket_vmnet dependency. It does NOT install a passwordless-sudo rule: the
# privileged executor lives in a user-writable gem checkout, so a NOPASSWD entry
# for it would be a local privilege-escalation hole. `dev:net:up`/`down` prompt
# for sudo once each instead — that is intended.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
libexec="$here/libexec"

echo "cloudmodel-api-qemu dev:net installer"
echo "  gem root: $here"

# ── Ruby (the helpers need >= 3.2, and Resolv::DNS::Message from stdlib) ────────
if ! command -v ruby >/dev/null 2>&1; then
  echo "  ✗ ruby not found on PATH" >&2
  exit 1
fi
ruby_ok=$(ruby -e 'puts(RUBY_VERSION.split(".").map(&:to_i).<=>([3,2,0]) >= 0 ? "yes" : "no")')
if [ "$ruby_ok" != "yes" ]; then
  echo "  ✗ ruby $(ruby -e 'print RUBY_VERSION') is too old (need >= 3.2)" >&2
  exit 1
fi
echo "  ✓ ruby $(ruby -e 'print RUBY_VERSION')"

# ── make the standalone helpers executable ─────────────────────────────────────
chmod +x "$libexec/cm-dev-net-exec" "$libexec/cm-dev-net-dns"
echo "  ✓ helpers executable ($libexec)"

# ── optional: socket_vmnet (only needed for the macOS vmnet L2 join) ───────────
case "$(uname -s)" in
  Darwin)
    if [ -S /opt/homebrew/var/run/socket_vmnet ] || [ -S /usr/local/var/run/socket_vmnet ]; then
      echo "  ✓ socket_vmnet daemon socket present"
    else
      echo "  ! socket_vmnet not detected — needed to reach guests over the vmnet L2."
      echo "    install with:  brew install socket_vmnet && sudo brew services start socket_vmnet"
    fi
    ;;
  Linux)
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      echo "  ✓ systemd-resolved active"
    else
      echo "  ! systemd-resolved not active — the Linux DNS path requires it."
    fi
    ;;
esac

cat <<'USAGE'

Ready. From the core-admin app (development):

  bundle exec rake dev:net:plan     # show what would change (no sudo)
  bundle exec rake dev:net:up        # bring routing + DNS up (sudo once)
  bundle exec rake dev:net:status    # verify routes + name resolution
  bundle exec rake dev:net:down      # remove everything (sudo once)
USAGE
