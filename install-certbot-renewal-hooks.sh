#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: sudo bash ./install-certbot-renewal-hooks.sh [--dry-run] [--renew]

Installs Certbot hooks for a Jitsi web container using standalone HTTP
validation. DOMAIN is read from this project's .env file.

  --dry-run  Install hooks, then run Certbot's staging renewal test.
  --renew    Install hooks, then renew the DOMAIN certificate if it is due.
EOF
}

ACTION="install"
case "${1:-}" in
    "") ;;
    --dry-run) ACTION="dry-run" ;;
    --renew) ACTION="renew" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [[ $EUID -ne 0 ]]; then
    echo "Run this installer with sudo." >&2
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
HOOK_ROOT="/etc/letsencrypt/renewal-hooks"

read_env() {
    local key="$1"
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1 | tr -d '\"\r'
}

command -v certbot >/dev/null || {
    echo "certbot is not installed." >&2
    exit 1
}
DOCKER_BIN="$(command -v docker || true)"
[[ -n "$DOCKER_BIN" ]] || {
    echo "docker is not installed." >&2
    exit 1
}
[[ -f "$ENV_FILE" ]] || {
    echo "Missing $ENV_FILE" >&2
    exit 1
}
[[ -f "$COMPOSE_FILE" ]] || {
    echo "Missing $COMPOSE_FILE" >&2
    exit 1
}

DOMAIN="$(read_env DOMAIN)"
[[ -n "$DOMAIN" ]] || {
    echo "DOMAIN is missing from $ENV_FILE" >&2
    exit 1
}

if [[ "$(read_env ENABLE_LETSENCRYPT)" != "0" ]]; then
    echo "ENABLE_LETSENCRYPT must be 0 when Certbot manages certificates." >&2
    exit 1
fi

compose() {
    "$DOCKER_BIN" compose \
        --project-directory "$PROJECT_DIR" \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        "$@"
}

WEB_CONTAINER="$(compose ps -q web)"
[[ -n "$WEB_CONTAINER" ]] || {
    echo "The Jitsi web container must be running while hooks are installed." >&2
    exit 1
}

WEB_CONFIG_DIR="$("$DOCKER_BIN" inspect --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$WEB_CONTAINER")"
[[ -n "$WEB_CONFIG_DIR" ]] || {
    echo "Could not discover the web container's /config mount." >&2
    exit 1
}

CERT_SOURCE="/etc/letsencrypt/live/$DOMAIN"
CERT_DESTINATION="$WEB_CONFIG_DIR/acme-certs/$DOMAIN"
[[ -r "$CERT_SOURCE/fullchain.pem" && -r "$CERT_SOURCE/privkey.pem" ]] || {
    echo "No Certbot certificate found for $DOMAIN." >&2
    echo "Create it with: certbot certonly --standalone -d $DOMAIN" >&2
    exit 1
}

install -d -m 755 "$HOOK_ROOT/pre" "$HOOK_ROOT/deploy" "$HOOK_ROOT/post"

cat > "$HOOK_ROOT/pre/01-stop-jitsi.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$DOCKER_BIN" compose --project-directory "$PROJECT_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" stop web 2>&1
EOF

cat > "$HOOK_ROOT/post/01-start-jitsi.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$DOCKER_BIN" compose --project-directory "$PROJECT_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" start web 2>&1
EOF

cat > "$HOOK_ROOT/deploy/10-jitsi-cert.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
DOMAIN="\$(sed -n 's/^DOMAIN=//p' "$ENV_FILE" | tail -n 1 | tr -d '\"\r')"
case " \${RENEWED_DOMAINS:-} " in
    *" \$DOMAIN "*) ;;
    *) exit 0 ;;
esac
SRC="\${RENEWED_LINEAGE:?Certbot did not provide RENEWED_LINEAGE}"
DST="$WEB_CONFIG_DIR/acme-certs/\$DOMAIN"
install -d -m 755 "\$DST"
install -m 644 "\$SRC/fullchain.pem" "\$DST/fullchain.pem"
install -m 600 "\$SRC/privkey.pem" "\$DST/privkey.pem"
EOF

chmod 755 \
    "$HOOK_ROOT/pre/01-stop-jitsi.sh" \
    "$HOOK_ROOT/deploy/10-jitsi-cert.sh" \
    "$HOOK_ROOT/post/01-start-jitsi.sh"

# Synchronize immediately. A deploy hook only runs after an actual renewal, so
# without this step Jitsi may keep serving an older copied certificate when
# Certbot decides the current certificate is not due yet.
install -d -m 755 "$CERT_DESTINATION"
install -m 644 "$CERT_SOURCE/fullchain.pem" "$CERT_DESTINATION/fullchain.pem"
install -m 600 "$CERT_SOURCE/privkey.pem" "$CERT_DESTINATION/privkey.pem"
compose exec web nginx -s reload

if command -v systemctl >/dev/null && systemctl list-unit-files certbot.timer --no-legend | grep -q '^certbot.timer'; then
    systemctl enable --now certbot.timer
fi

echo "Installed Certbot hooks for $DOMAIN"
echo "Web config mount: $WEB_CONFIG_DIR"
echo "Synchronized the current certificate and reloaded Nginx"

case "$ACTION" in
    dry-run)
        certbot renew --cert-name "$DOMAIN" --dry-run --no-random-sleep-on-renew
        ;;
    renew)
        certbot renew --cert-name "$DOMAIN" --no-random-sleep-on-renew
        ;;
esac
