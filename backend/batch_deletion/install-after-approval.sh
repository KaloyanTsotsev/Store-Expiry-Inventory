#!/bin/sh
# Run manually on OnePlus ONLY after approving the deployment plan.
# This script never runs migrations or changes API Rules.
set -eu
base=/home/user/pocketbase
release=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$release"
command -v curl >/dev/null
sha256sum -c SHA256SUMS
test -d "$base/pb_data"
test -d "$base/pb_hooks/lib"
test "$(id -u)" = 0 || { echo 'Run with sudo after approval'; exit 1; }
printf '%s  %s\n' '545444a194042574bb5e8a5aea758a79fb5a7c8d25a4582448cc26652b024f76' "$base/pb_hooks/lib/handle_expiry.js" | sha256sum -c -
printf '%s  %s\n' '12652b645661562997f474547e688402a0e91a273390b7d61bab06ec3a7b2fef' "$base/pb_hooks/lib/handlers.js" | sha256sum -c -
printf '%s  %s\n' 'a2cc3dc1e87810a50544eeed71c9156dc827a83c2c588e6748f12236fa90d643' "$base/pb_hooks/expiry_handling.pb.js" | sha256sum -c -
systemctl is-active --quiet pocketbase.service
stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=/home/user/storeflow-backups/$stamp
install -d -m 700 "$backup"
df -h "$base" "$backup"
du -sh "$base/pb_data"
# SQLite consistency: stop only at this explicitly approved maintenance step.
changed=no
success=no
finish() {
  if [ "$success" != yes ] && [ "$changed" = yes ]; then
    cp -p "$backup/handle_expiry.js" "$base/pb_hooks/lib/handle_expiry.js"
    cp -p "$backup/handlers.js" "$base/pb_hooks/lib/handlers.js"
  fi
  systemctl start pocketbase.service
}
trap finish EXIT
systemctl stop pocketbase.service
tar -C "$base" -czf "$backup/pocketbase-before-batch-delete.tar.gz" pb_data pb_hooks
tar -tzf "$backup/pocketbase-before-batch-delete.tar.gz" >/dev/null
sha256sum "$backup/pocketbase-before-batch-delete.tar.gz" > "$backup/backup.sha256"
cp -p "$base/pb_hooks/lib/handle_expiry.js" "$backup/handle_expiry.js"
cp -p "$base/pb_hooks/lib/handlers.js" "$backup/handlers.js"
cp -p /etc/systemd/system/pocketbase.service "$backup/pocketbase.service"
changed=yes
install -o user -g root -m 644 pb_hooks/lib/handlers.js "$base/pb_hooks/lib/handlers.js"
install -o user -g root -m 644 pb_hooks/lib/handle_expiry.js "$base/pb_hooks/lib/handle_expiry.js"
systemctl start pocketbase.service
sleep 2
systemctl is-active --quiet pocketbase.service
# No records are written by this probe; auth middleware should return 401.
status=$(curl --silent --output "$backup/route-check.json" --write-out '%{http_code}' \
  -X POST -H 'Content-Type: application/json' -d '{}' \
  http://127.0.0.1:8090/api/store/batches/aaaaaaaaaaaaaaa/handle)
test "$status" = 401
success=yes
echo "Installed. Backup: $backup. Review journal and complete authenticated acceptance tests."
