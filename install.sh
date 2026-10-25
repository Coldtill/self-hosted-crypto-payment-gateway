#!/usr/bin/env bash
# Coldtill installer. Downloads an edition, checks its SHA-256, loads the Docker image and starts the
# stack. Re-run it to upgrade. Free comes from GitHub releases with no account; Standard and Pro need
# the install token from your account.
#
#   curl -fsSL https://coldtill.com/install.sh | sudo bash -s -- --edition free
#   curl -fsSL https://coldtill.com/install.sh | sudo bash -s -- --edition pro --token cti_…
#
# Options:
#   --edition free|standard|pro   which edition (required)
#   --token TOKEN            Standard and Pro: install token from https://coldtill.com/account (or set COLDTILL_INSTALL_TOKEN)
#   --version VERSION        a release such as v1.0.0 (default: the latest your purchase includes)
#   --dir DIR                install directory (default: /opt/coldtill)
#   --mode testnet|mainnet   first install only (default: testnet)
#   --site-url URL           first install only, e.g. https://pay.example.com (prompted if omitted)
#   --no-start               install or upgrade the image without starting the stack
#   --download-only          just download and verify a file into the current directory (no root or Docker needed)
#   --kind image|binary      with --download-only: Docker image tarball (default) or static binary
#   --arch amd64|arm64       with --download-only: another architecture than this machine's
#
# Run this script as is, on the server, rather than rebuilding its requests by hand: it handles the
# Authorization header, the checksum and file ownership. The download API is documented at
# https://coldtill.com/docs/install/#download-api
set -euo pipefail

SITE=https://coldtill.com
GITHUB=https://github.com/Coldtill/self-hosted-crypto-payment-gateway
# The image's nonroot user. It owns the install directory so the sweeper and payouts containers can read secrets/.
APP_UID=65532
tmp=""
token=""

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }

usage() {
  echo "Usage: install.sh --edition free|standard|pro [--token TOKEN] [--version V] [--dir DIR] [--mode testnet|mainnet] [--site-url URL] [--no-start]"
  echo "       install.sh --download-only --edition free|standard|pro [--token TOKEN] [--version V] [--kind image|binary] [--arch amd64|arm64]"
}

# fetch_free VERSION ARCH KIND OUT: downloads one Free release file from GitHub and checks it against the
# release's SHA256SUMS. Sets FETCHED_VERSION and FETCHED_SHA256.
fetch_free() {
  local base="$GITHUB/releases/latest/download" suffix="-free-linux-$2" line name want got
  [ "$1" = latest ] || base="$GITHUB/releases/download/v${1#v}"
  [ "$3" = image ] && suffix="$suffix-image.tar.gz"
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" \
    || die "could not get SHA256SUMS from $base; check the version exists and this machine can reach github.com"
  line=$(grep -E "^[0-9a-f]{64}  coldtill-v[^ /]*$suffix\$" "$tmp/SHA256SUMS" | head -n 1)
  [ -n "$line" ] || die "that release has no Free linux/$2 $3 file"
  want=${line%% *}
  name=${line##* }
  FETCHED_VERSION=${name#coldtill-}
  FETCHED_VERSION=${FETCHED_VERSION%%-free-linux-*}
  curl -fSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 -o "$4" "$GITHUB/releases/download/$FETCHED_VERSION/$name" \
    || die "download of $name failed"
  got=$(sha256sum "$4" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { rm -f "$4"; die "checksum mismatch (expected $want, got $got); not using it"; }
  FETCHED_SHA256=$got
  say "Checksum OK ($got)"
}

# fetch EDITION VERSION ARCH KIND OUT: downloads one release file (with the token for Standard and Pro)
# and checks its SHA-256. Sets FETCHED_VERSION and FETCHED_SHA256.
fetch() {
  if [ "$1" = free ]; then fetch_free "$2" "$3" "$4" "$5"; return; fi
  local code
  code=$(curl -sS --proto '=https' --tlsv1.2 --retry 3 -H @<(printf 'Authorization: Bearer %s\n' "$token") \
    -D "$tmp/headers" -o "$5" -w '%{http_code}' "$SITE/api/install/$1/$2/$3/$4") \
    || die "download failed; check this machine can reach $SITE over HTTPS"
  if [ "$code" != 200 ]; then
    local reason="" help=""
    reason=$(sed -n 's/.*"error":"\([^"]*\)".*/\1/p' "$5" 2>/dev/null | head -c 300)
    help=$(sed -n 's/.*"help":"\([^"]*\)".*/\1/p' "$5" 2>/dev/null | head -c 300)
    rm -f "$5"
    die "$SITE refused the download (HTTP $code${reason:+: $reason})${help:+
  $help}"
  fi
  header() { tr -d '\r' < "$tmp/headers" | sed -n "s/^$1: *//Ip" | tail -n 1; }
  local want got
  want=$(header X-Checksum-SHA256)
  FETCHED_VERSION=$(header X-Coldtill-Version)
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { rm -f "$5"; die "the download had no checksum; not using it"; }
  got=$(sha256sum "$5" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { rm -f "$5"; die "checksum mismatch (expected $want, got $got); not using it"; }
  FETCHED_SHA256=$got
  say "Checksum OK ($got)"
}

# set_env KEY VALUE FILE replaces the KEY= line or appends one. It rewrites the file in place, so its owner and
# mode stay as they were.
set_env() {
  local key=$1 val=$2 file=$3 t
  t=$(mktemp)
  { grep -v "^${key}=" "$file" || true; printf '%s=%s\n' "$key" "$val"; } > "$t"
  cat "$t" > "$file"
  rm -f "$t"
}

# ensure_updater sets up one-click updates from the dashboard: the updater service in docker-compose.yml, its
# script, a secret the API and the updater share, and updater.env. The install token goes only in updater.env,
# which is readable by root and the updater container alone; .env is loaded by every Coldtill container,
# including the public API.
ensure_updater() {
  local edition=$1 dc=$2 secret prev_token="" profiles
  secret=$(sed -n 's/^COLDTILL_UPDATE_SECRET=//p' .env | tail -n 1)
  [[ "$secret" =~ ^[0-9a-f]{64}$ ]] || secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  set_env COLDTILL_DIR "$PWD" .env
  set_env COLDTILL_UPDATER_URL "http://updater:8090" .env
  set_env COLDTILL_UPDATE_SECRET "$secret" .env
  # An earlier draft of this script put the install token in .env; move it out.
  prev_token=$(sed -n 's/^COLDTILL_INSTALL_TOKEN=//p' .env | tail -n 1)
  if grep -q '^COLDTILL_INSTALL_TOKEN=' .env; then
    local t; t=$(mktemp); grep -v '^COLDTILL_INSTALL_TOKEN=' .env > "$t" || true; cat "$t" > .env; rm -f "$t"
  fi
  profiles=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -n 1)
  case ",$profiles," in *,updater,*) ;; ,,) set_env COMPOSE_PROFILES updater .env ;; *) set_env COMPOSE_PROFILES "$profiles,updater" .env ;; esac

  [ -f updater.env ] && [ -z "$prev_token" ] && prev_token=$(sed -n 's/^COLDTILL_INSTALL_TOKEN=//p' updater.env | tail -n 1)
  ( umask 077
    { echo "# Read only by the updater container. Keep this file private."
      echo "COLDTILL_EDITION=$edition"
      echo "COLDTILL_UPDATE_SECRET=$secret"
      if [ "$edition" != free ] && [ -n "${token:-$prev_token}" ]; then echo "COLDTILL_INSTALL_TOKEN=${token:-$prev_token}"; fi
    } > updater.env.tmp )
  chown 0:0 updater.env.tmp
  chmod 600 updater.env.tmp
  mv -f updater.env.tmp updater.env

  if curl -fsS --proto '=https' --tlsv1.2 -o updater.sh.tmp "$SITE/deploy/updater.sh"; then
    chown 0:0 updater.sh.tmp
    chmod 755 updater.sh.tmp
    mv -f updater.sh.tmp updater.sh
  else
    rm -f updater.sh.tmp
    say "Could not download the one-click updater; updates still work by re-running this script"
  fi

  # Installs from before one-click updates have a compose file without the updater service.
  if ! grep -q '^  updater:' docker-compose.yml; then
    curl -fsS --proto '=https' --tlsv1.2 -o compose.new.tmp "$SITE/deploy/docker-compose.yml" || { rm -f compose.new.tmp; return 0; }
    awk '/^  # coldtill-updater:/ { on = 1 } on && /^volumes:/ { exit } on { print }' compose.new.tmp > updater.block.tmp
    awk -v block=updater.block.tmp '
      /^volumes:/ && !done { while ((getline line < block) > 0) print line; print ""; done = 1 }
      { print }' docker-compose.yml > docker-compose.yml.tmp
    if grep -q '^  updater:' docker-compose.yml.tmp && $dc -f docker-compose.yml.tmp config -q 2>/dev/null; then
      cat docker-compose.yml.tmp > docker-compose.yml
      say "Added the one-click updater to docker-compose.yml"
    else
      say "Could not add the updater to your docker-compose.yml automatically; updates still work by re-running this script"
    fi
    rm -f compose.new.tmp updater.block.tmp docker-compose.yml.tmp
  fi
}

main() {
  local edition="" version=latest dir=/opt/coldtill mode=testnet site_url="" start=1 download_only=0 kind=image arch="" from_updater=0
  token="${COLDTILL_INSTALL_TOKEN:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --edition) edition="${2:-}"; shift 2 ;;
      --token) token="${2:-}"; shift 2 ;;
      --version) version="${2:-}"; shift 2 ;;
      --dir) dir="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --site-url) site_url="${2:-}"; shift 2 ;;
      --no-start) start=0; shift ;;
      --from-updater) from_updater=1; shift ;;
      --download-only) download_only=1; shift ;;
      --kind) kind="${2:-}"; shift 2 ;;
      --arch) arch="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
  done

  # Tolerate a token pasted with quotes, spaces or a "Bearer " prefix.
  token=$(printf %s "$token" | tr -d " \t\r\n\"'")
  token=${token#Bearer}
  token=${token#bearer}
  case "$edition" in free|standard|pro) ;; *) usage >&2; die "--edition must be free, standard or pro" ;; esac
  if [ "$edition" != free ]; then
    [ -n "$token" ] || die "--token is missing. Create one under Install token on $SITE/account"
    [[ "$token" =~ ^cti_[A-Za-z0-9_-]{20,}$ ]] || die "--token doesn't look like an install token (cti_ followed by 43 characters); copy it again from $SITE/account"
  fi
  [[ "$version" =~ ^(latest|v?[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*)$ ]] || die "--version must look like v1.0.0"
  case "$mode" in testnet|mainnet) ;; *) die "--mode must be testnet or mainnet" ;; esac
  case "$kind" in image|binary) ;; *) die "--kind must be image or binary" ;; esac

  if [ -z "$arch" ]; then
    case "$(uname -m)" in
      x86_64|amd64) arch=amd64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) die "unsupported CPU architecture $(uname -m); Coldtill ships for amd64 and arm64" ;;
    esac
  fi
  case "$arch" in amd64|arm64) ;; *) die "--arch must be amd64 or arm64" ;; esac
  for c in curl sha256sum; do command -v "$c" >/dev/null || die "$c is not installed (sudo apt install $c)"; done

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  if [ "$download_only" = 1 ]; then
    say "Downloading Coldtill ${edition^} ($version, linux/$arch, $kind)"
    local part="./.coldtill-download.part" name
    [ -w . ] || die "can't write to $PWD; cd to a writable directory first"
    fetch "$edition" "$version" "$arch" "$kind" "$part"
    name="coldtill-${FETCHED_VERSION:-$version}-$edition-linux-$arch"
    [ "$kind" = image ] && name="$name-image.tar.gz"
    mv -f "$part" "$name"
    [ "$kind" = binary ] && chmod 0755 "$name"
    echo "$FETCHED_SHA256  $name" > "$name.sha256"
    echo
    echo "Saved $PWD/$name (SHA-256 in $name.sha256)"
    if [ "$kind" = image ]; then echo "Load it with: docker load -i $name"
    else echo "Install it with: sudo install -m 0755 $name /usr/local/bin/coldtill"; fi
    return
  fi

  [ "$(uname -s)" = Linux ] || die "Coldtill runs on Linux"
  [ "$(id -u)" = 0 ] || die "run as root: curl -fsSL $SITE/install.sh | sudo bash -s -- … (or add --download-only to just fetch the file)"
  if [ "$arch" != "$(case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; esac)" ]; then
    die "--arch $arch doesn't match this machine; use --download-only to fetch another architecture"
  fi

  command -v docker >/dev/null || die "Docker is not installed. On Ubuntu, Debian or Linux Mint: sudo apt install docker.io docker-compose-v2"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (sudo systemctl start docker)"
  local dc
  if docker compose version >/dev/null 2>&1; then dc="docker compose"
  elif command -v docker-compose >/dev/null; then dc="docker-compose"
  else die "Docker Compose is missing: sudo apt install docker-compose-v2"; fi

  # stdin is this script when piped from curl, so init's prompts read from the terminal instead.
  local tty=() input=/dev/null
  if [ ! -f "$dir/.env" ] && [ -z "${COLDTILL_HOT_PASSPHRASE:-}" ]; then
    { : </dev/tty; } 2>/dev/null || die "no terminal for the passphrase prompt; set COLDTILL_HOT_PASSPHRASE (sudo -E) or run this in an interactive shell"
    tty=(-it); input=/dev/tty
  fi

  say "Downloading Coldtill ${edition^} ($version, linux/$arch)"
  fetch "$edition" "$version" "$arch" image "$tmp/image.tar.gz"
  local release=$FETCHED_VERSION

  say "Loading the Docker image"
  local image
  image=$(docker load -i "$tmp/image.tar.gz" | sed -n 's/^Loaded image: //p' | tail -n 1)
  [ -n "$image" ] || die "docker load did not report an image name"

  mkdir -p "$dir"
  cd "$dir"
  for f in docker-compose.yml Caddyfile; do
    if [ ! -f "$f" ]; then
      curl -fsS --proto '=https' --tlsv1.2 -o "$f" "$SITE/deploy/$f" || die "could not download $f"
    fi
  done

  if [ ! -f .env ]; then
    say "Generating secrets (coldtill init)"
    chown "$APP_UID:$APP_UID" "$dir"
    local args=(init --dir /work --mode "$mode")
    [ -n "$site_url" ] && args+=(--site-url "$site_url")
    docker run --rm "${tty[@]}" --user "$APP_UID:$APP_UID" -v "$dir:/work" \
      ${COLDTILL_HOT_PASSPHRASE:+-e COLDTILL_HOT_PASSPHRASE} "$image" "${args[@]}" < "$input"
  else
    say ".env already exists; keeping the existing secrets"
    if $dc ps --status running --services 2>/dev/null | grep -qx postgres; then
      mkdir -p backups
      local dump
      dump="backups/coldtill-$(date +%Y%m%d-%H%M%S).sql.gz"
      say "Backing up the database to $dir/$dump"
      $dc exec -T postgres pg_dump -U coldtill coldtill | gzip > "$dump" || die "database backup failed; not upgrading"
      chmod 600 "$dump"
    fi
  fi

  if grep -q '^COLDTILL_IMAGE=' .env; then sed -i "s|^COLDTILL_IMAGE=.*|COLDTILL_IMAGE=$image|" .env
  else printf '# Image loaded by install.sh\nCOLDTILL_IMAGE=%s\n' "$image" >> .env; fi
  ensure_updater "$edition" "$dc"
  chown "$APP_UID:$APP_UID" .env
  chmod 600 .env
  chmod 700 secrets

  if [ "$start" = 0 ]; then
    say "Installed $image. Start it with: cd $dir && $dc up -d --no-build"
    return
  fi
  say "Starting Coldtill ${release:-$version}"
  if [ "$from_updater" = 1 ]; then
    # Run by the updater container: restarting it now would stop this script halfway through the upgrade.
    local services
    services=$($dc config --services | grep -vx updater)
    # shellcheck disable=SC2086 # one service name per word
    $dc up -d --no-build $services
  else
    $dc up -d --no-build
  fi

  local url
  url=$(sed -n 's/^COLDTILL_SITE_URL=//p' .env)
  echo
  echo "Coldtill ${edition^} ${release:-} is starting at $url"
  echo "Open it to create the root account, then enable two-factor authentication."
  if [[ $url =~ ^https?://[^/]+/. ]]; then
    echo "Coldtill listens on http://127.0.0.1:8080 for your reverse proxy. Point its location for that path there:"
    echo "https://coldtill.com/docs/guides/domains-and-dashboard/#run-coldtill-under-a-path-of-another-site"
  fi
  echo "Logs: cd $dir && sudo $dc logs -f    Stop: cd $dir && sudo $dc down"
  echo "Back up $dir/.env and $dir/secrets/ somewhere safe (offline)."
}

main "$@"
