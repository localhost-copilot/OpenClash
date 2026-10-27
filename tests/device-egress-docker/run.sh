#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
MIHOMO_SOURCE=${MIHOMO_SOURCE:-$(dirname "$REPO")/mihomo}
export COMPOSE_FILE="$HERE/compose.yaml"
export UI_PORT=${UI_PORT:-18080}
export ROUTER_IMAGE=${ROUTER_IMAGE:-openwrt}
case "$ROUTER_IMAGE" in
  openwrt) BASE_IMAGE=openwrt/rootfs:armsr-armv8-24.10.8; BASE_PLATFORM=linux/aarch64_generic ;;
  qwrt) BASE_IMAGE=coolsnowwolf/qwrt:arm64-latest; BASE_PLATFORM=linux/amd64 ;;
  *) echo 'ROUTER_IMAGE must be openwrt or qwrt' >&2; exit 2 ;;
esac
export HARNESS_ROUTER_IMAGE="device-egress-$ROUTER_IMAGE-router"
export HARNESS_MASTER_IMAGE="device-egress-$ROUTER_IMAGE-master"
export HARNESS_RESULTS="$HERE/results/$ROUTER_IMAGE"
MODE=${1:-test}
case "$MODE" in
  down) docker compose down --volumes --remove-orphans; exit ;;
  test|ui|upgrade) ;;
  *) echo 'Usage: run.sh [test|ui|upgrade|down]' >&2; exit 2 ;;
esac
mkdir -p "$HARNESS_RESULTS" "$HERE/.cache/master"
KEEP=0
cleanup() {
  status=$?
  if [ "$KEEP" != 1 ]; then
    docker compose logs --no-color > "$HARNESS_RESULTS/containers.log" 2>&1 || true
    docker compose down --volumes --remove-orphans || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker compose down --volumes --remove-orphans
python3 - "$UI_PORT" <<'PY'
import socket, sys
port = int(sys.argv[1])
try:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", port))
except OSError as error:
    sys.exit(f"Host port {port} is unavailable: {error}. Stop its owner, or set UI_PORT to another port.")
PY
git -C "$REPO" archive master luci-app-openclash | tar -x -C "$HERE/.cache/master"
git -C "$REPO" rev-parse master > "$HARNESS_RESULTS/master-revision.txt"
"$HERE/build-ipk.sh"
PACKAGE_SOURCE="$HERE/.cache/master/luci-app-openclash" PACKAGE_OUTPUT="$HERE/.cache/master.ipk" "$HERE/build-ipk.sh"
for target in router peer master; do
  echo "Building $ROUTER_IMAGE/$target (log: $HARNESS_RESULTS/build-$target.log)"
  docker build --platform linux/arm64 \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" --build-arg "BASE_PLATFORM=$BASE_PLATFORM" \
    --build-arg "ROUTER_FLAVOR=$ROUTER_IMAGE" \
    --build-context "mihomo=$MIHOMO_SOURCE" \
    --target "$target" -t "device-egress-$ROUTER_IMAGE-$target" \
    -f "$HERE/Dockerfile" "$REPO" > "$HARNESS_RESULTS/build-$target.log" 2>&1 || {
      tail -80 "$HARNESS_RESULTS/build-$target.log"; exit 1;
    }
done
# The peer is independent of the router base.
docker tag "device-egress-$ROUTER_IMAGE-peer" device-egress-peer
if [ "$MODE" = upgrade ]; then
  docker build --platform linux/arm64 --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "BASE_PLATFORM=$BASE_PLATFORM" --build-arg "ROUTER_FLAVOR=$ROUTER_IMAGE" \
    --build-context "mihomo=$MIHOMO_SOURCE" --target upgrade \
    -t "device-egress-$ROUTER_IMAGE-upgrade" -f "$HERE/Dockerfile" "$REPO" \
    > "$HARNESS_RESULTS/build-upgrade.log" 2>&1
  export HARNESS_ROUTER_IMAGE="device-egress-$ROUTER_IMAGE-upgrade"
fi
docker compose up -d
OUTPUT_LOG=last-run.txt
[ "$MODE" != ui ] || OUTPUT_LOG=ui-run.txt
[ "$MODE" != upgrade ] || OUTPUT_LOG=upgrade-run.txt
python3 "$HERE/scenarios.py" "$MODE" | tee "$HARNESS_RESULTS/$OUTPUT_LOG"
if [ "$MODE" = ui ]; then
  KEEP=1
  echo "UI: http://127.0.0.1:$UI_PORT/cgi-bin/luci/admin/services/openclash/device-egress"
  echo 'Login: root / test. Stop with tests/device-egress-docker/run.sh down'
fi
