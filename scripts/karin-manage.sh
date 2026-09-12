# Invoked by the Nix-provided karin-manage wrapper as root.
set -euo pipefail
umask 077
[[ $EUID == 0 ]] || { echo 'Run as root' >&2; exit 1; }
exec 9>/run/lock/karin-manage.lock
flock -n 9 || { echo 'Another Karin maintenance operation is running' >&2; exit 1; }

backup() {
  install -d -m 0700 "$KARIN_BACKUPS"
  snapshot=$(mktemp -d "$KARIN_BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  podman inspect karin --format '{{.Image}}' > "$snapshot/image"
  systemctl stop podman-karin.service
  trap 'systemctl start podman-karin.service' EXIT
  tar -czf "$snapshot/app.tar.gz" -C "$KARIN_DATA" .
  echo "Backup: $snapshot"
}

restore() {
  local source=$1
  test -s "$source/app.tar.gz"
  tar -tzf "$source/app.tar.gz" >/dev/null
  systemctl stop podman-karin.service
  # Retain the replaced state for recovery; never delete user data here.
  mv "$KARIN_DATA" "$source/replaced-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$KARIN_DATA"
  tar -xzf "$source/app.tar.gz" -C "$KARIN_DATA"
  systemctl start podman-karin.service
}

case "${1:-help}" in
  backup)
    backup
    systemctl start podman-karin.service
    trap - EXIT
    ;;
  restart) systemctl restart podman-karin.service ;;
  update)
    shift
    backup
    image=$(cat "$snapshot/image")
    if ! podman run --rm --network=host --workdir /app \
      -v "$KARIN_DATA:/app" --entrypoint pnpm "$image" update --latest "$@"; then
      echo 'Update failed; restoring application backup' >&2
      restore "$snapshot"
      exit 1
    fi
    systemctl start podman-karin.service
    trap - EXIT
    echo "Update installed. Inspect logs; rollback with: karin-manage restore $snapshot"
    ;;
  restore)
    [[ $# == 2 ]] || { echo 'Usage: karin-manage restore /var/backups/karin/SNAPSHOT' >&2; exit 1; }
    restore "$2"
    ;;
  status) systemctl --no-pager status podman-karin.service ;;
  *) echo 'Usage: karin-manage {backup|restart|update [package ...]|restore SNAPSHOT|status}' ;;
esac
