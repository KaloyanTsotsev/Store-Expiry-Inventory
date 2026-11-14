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
expected=15ea3f4e06d13114aae0170af29576cb97d5eeb92708ba3699db912fed395862
actual=$(sha256sum "$base/pb_hooks/lib/delivery_finalization.js" | cut -d ' ' -f1)
test "$actual" = "$expected" || { echo 'Finalizer changed since inspection. Stop and review the diff.'; exit 1; }
test ! -e "$base/pb_hooks/expiry_handling.pb.js"
test ! -e "$base/pb_hooks/lib/handle_expiry.js"
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
    cp -p "$backup/delivery_finalization.js" "$base/pb_hooks/lib/delivery_finalization.js"
    rm -f "$base/pb_hooks/expiry_handling.pb.js" "$base/pb_hooks/lib/handle_expiry.js"
  fi
  systemctl start pocketbase.service
}
trap finish EXIT
systemctl stop pocketbase.service
tar -C "$base" -czf "$backup/pocketbase-before-workflow.tar.gz" pb_data pb_hooks
tar -tzf "$backup/pocketbase-before-workflow.tar.gz" >/dev/null
sha256sum "$backup/pocketbase-before-workflow.tar.gz" > "$backup/backup.sha256"
cp -p "$base/pb_hooks/lib/delivery_finalization.js" "$backup/delivery_finalization.js"
cp -p /etc/systemd/system/pocketbase.service "$backup/pocketbase.service"
changed=yes
install -o user -g root -m 644 pb_hooks/lib/delivery_finalization.js "$base/pb_hooks/lib/delivery_finalization.js"
install -o user -g root -m 644 pb_hooks/lib/handle_expiry.js "$base/pb_hooks/lib/handle_expiry.js"
install -o user -g root -m 644 pb_hooks/expiry_handling.pb.js "$base/pb_hooks/expiry_handling.pb.js"
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
