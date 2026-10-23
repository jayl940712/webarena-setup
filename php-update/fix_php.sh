#!/usr/bin/env bash
#
# fix_php.sh - PHP upgrade for the PHP2Shell flaws
# (CVE-2026-109618 / CVE-2026-109619, https://www.php2shell.com/#upgrade-php)
#
# Nothing is compiled. PHP is upgraded from prebuilt packages:
#
#   alpine-fpm    (shopping, shopping_admin, forum: Alpine 3.16, PHP 8.1 built from source)
#                 -> self-contained PHP tree from newer Alpine packages under /opt/phpXY,
#                    run through its own musl loader; /usr/local/bin/php and
#                    /usr/local/sbin/php-fpm become small wrappers around it.
#                    The existing php-fpm.conf / php-fpm.d pool config is reused.
#   debian-docker (classifieds: official docker-php image on Debian 12)
#                 -> packages from the sury.org apt repo; /usr/local/bin/php
#                    is pointed at /usr/bin/phpX.Y.
#   apt-apache    (nominatim: Ubuntu 22.04 + Apache mod_php)
#                 -> packages from Ondrej's PPA; Apache module swapped.
#
# Default mode (--bake): the fix is baked into the images, so that containers
# created by the reset scripts are already patched and this script does not have
# to run again after a reset.
#   1. for every image used by a running container with vulnerable PHP, a
#      throw-away container is started from the image WITHOUT starting the app
#      (so no runtime state / database changes are captured),
#   2. PHP is upgraded in it and verified,
#   3. it is committed back over the same image tag (the original image stays
#      available as <repo>:<tag>-pre-php-update),
#   4. the old containers created from the old image are stopped and removed
#      (their runtime state is lost, like in a normal reset). Recreate them
#      with the normal reset scripts (02..05).
#   nominatim (not recreated by the reset) is additionally patched live and
#   health-checked, with automatic rollback.
#
# --live: only patch the running containers in place (lost on re-creation).
#
# Usage: ./fix_php.sh [--dry-run] [--live] [--rollback] [--yes]
#                     [--keep-containers] [--only name[,name...]]
#   --dry-run          show the plan, change nothing
#   --live             patch running containers in place instead of baking images
#   --rollback         restore the original PHP (live containers) and the
#                      original image tags (<tag>-pre-php-update)
#   --yes              do not ask for confirmation
#   --keep-containers  bake images but do not stop/remove old containers
#   --only a,b         restrict to these container names
# Env:   PHP_BRANCH=8.2 (default) | 8.3 | 8.4 | 8.5     target branch
#        ALPINE_RELEASE=3.22        Alpine release used as package source
set -uo pipefail

PHP_BRANCH="${PHP_BRANCH:-8.2}"
DRY_RUN=0
ROLLBACK=0
LIVE=0
YES=0
KEEP=0
ONLY=""

# First fixed release per branch (https://www.php2shell.com/#upgrade-php).
declare -A FIXED=([8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12)

SURY_FPR="15058500A0235D97F5D10063B188E2B695BD4743"      # packages.sury.org (Debian)
ONDREJ_FPR="14AA40EC0831756756D7F66C4F4EA0AAE5267A6C"    # ppa:ondrej/php (Ubuntu)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case "$1" in
    --dry-run)         DRY_RUN=1 ;;
    --live)            LIVE=1 ;;
    --rollback)        ROLLBACK=1 ;;
    --yes|-y)          YES=1 ;;
    --keep-containers) KEEP=1 ;;
    --only)            shift; ONLY="${1:-}" ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

[[ -n "${FIXED[$PHP_BRANCH]:-}" ]] || die "PHP_BRANCH must be one of: ${!FIXED[*]}"
TARGET_MIN="${FIXED[$PHP_BRANCH]}"
PKG="php${PHP_BRANCH//./}"                       # e.g. php82 (Alpine package prefix)
case "$PHP_BRANCH" in
  8.2) ALPINE_RELEASE="${ALPINE_RELEASE:-3.22}" ;;   # php82 8.2.35 lives in v3.22 / v3.21
  *)   ALPINE_RELEASE="${ALPINE_RELEASE:-3.23}" ;;
esac

for t in docker curl tar gpg; do command -v "$t" >/dev/null || die "'$t' is required on the host"; done
docker info >/dev/null 2>&1 || die "cannot talk to docker (run with sudo?)"

WORK="$(mktemp -d)"
TMPC=""
cleanup() {
  [[ -n "$TMPC" ]] && docker rm -f "$TMPC" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

ver_ge()  { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }
ok_code() { [[ "$1" =~ ^[1-4][0-9][0-9]$ ]]; }
confirm() {
  ((YES)) && return 0
  [[ -t 0 ]] || die "not interactive: pass --yes to confirm"
  local a; read -r -p "$1 [y/N] " a; [[ "$a" == [yY]* ]]
}

http_code() {   # container url
  docker exec "$1" curl -s -o /dev/null -m 120 -w '%{http_code}' "$2" 2>/dev/null || true
}
wait_ok() {     # container url max_seconds -> echoes last code
  local code="" i
  for ((i = 0; i < $3; i += 5)); do
    code="$(http_code "$1" "$2")"
    ok_code "$code" && break
    sleep 5
  done
  echo "$code"
}

norm_ref() {    # image reference with an explicit tag
  local r=$1
  [[ "${r##*/}" == *:* || "$r" == *@* ]] || r="$r:latest"
  echo "$r"
}
ref_of()   { norm_ref "$(docker inspect -f '{{.Config.Image}}' "$1")"; }
tag_id()   { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

# ---------------------------------------------------------------- discovery
P_VER=""; P_OS=""; P_KIND=""
probe() {       # container -> P_VER P_OS P_KIND (fails if no php)
  local out
  out="$(docker exec "$1" sh -c '
    v=$(php -r "echo PHP_VERSION;" 2>/dev/null) || exit 3
    [ -n "$v" ] || exit 3
    id=$(. /etc/os-release 2>/dev/null; echo "$ID")
    kind=unsupported
    case "$id" in
      alpine)
        if { [ -e /usr/local/sbin/php-fpm ] || [ -e /usr/local/sbin/php-fpm.pre-php-update ]; } && [ -e /usr/local/bin/php ]; then kind=alpine-fpm; fi ;;
      debian|ubuntu)
        if [ "$id" = debian ] && [ -e /usr/local/bin/php ]; then kind=debian-docker
        elif ls /etc/apache2/mods-enabled/php*.load >/dev/null 2>&1; then kind=apt-apache; fi ;;
    esac
    echo "$v|$id|$kind"' 2>/dev/null)" || return 1
  IFS='|' read -r P_VER P_OS P_KIND <<<"$out"
  [[ -n "$P_VER" ]]
}

is_fixed() {    # version string -> 0 if already a fixed release
  local base="${1%%-*}" br
  br="${base%.*}"
  [[ -n "${FIXED[$br]:-}" ]] && ver_ge "$base" "${FIXED[$br]}"
}

# Earlier versions of this script wrote Alpine wrappers without ICU_DATA (Magento then
# returned HTTP 500 "No such time zone"). Such wrappers are "stale" and get refreshed.
wrapper_stale() {   # container -> 0 if it has the old-style wrapper
  docker exec "$1" sh -c '[ -e /opt/php-update/php ] && ! grep -q ICU_DATA /usr/local/bin/php' >/dev/null 2>&1
}

# ------------------------------------------------------------- alpine family
# Required: the abort-if-missing set (everything Magento 2.4.6 / Postmill need).
ALPINE_REQ_EXT="bcmath ctype curl dom fileinfo gd iconv intl mbstring mysqli mysqlnd openssl pdo pdo_mysql pdo_pgsql pgsql phar session simplexml soap sockets sodium tokenizer xml xmlreader xmlwriter xsl zip pcntl posix"
# Best effort: what the old image also had, if the package exists.
ALPINE_OPT_EXT="opcache calendar exif gmp bz2 gettext shmop sysvmsg sysvsem sysvshm sqlite3 pdo_sqlite ftp ldap tidy pecl-apcu pecl-igbinary pecl-msgpack pecl-redis pecl-imagick pecl-memcached pecl-yaml pecl-uuid pecl-ds pecl-lzf"
ALPINE_TREE=""

build_alpine_tree() {
  [[ -n "$ALPINE_TREE" ]] && return 0
  local req="$PKG $PKG-fpm" opt="" e
  for e in $ALPINE_REQ_EXT; do req+=" $PKG-$e"; done
  for e in $ALPINE_OPT_EXT; do opt+=" $PKG-$e"; done
  log "building PHP $PHP_BRANCH tree from Alpine $ALPINE_RELEASE packages (helper container alpine:$ALPINE_RELEASE; nothing is compiled)"
  docker run --rm -i -e PKG="$PKG" -e REQ="$req" -e OPT="$opt" "alpine:$ALPINE_RELEASE" sh -s \
    > "$WORK/$PKG.tar" <<'EOF' || return 1
set -eu
R=/opt/$PKG
mkdir -p "$R/etc/apk"
cp /etc/apk/repositories "$R/etc/apk/repositories"
cp -a /etc/apk/keys "$R/etc/apk/keys"
apk --root "$R" --initdb --no-scripts --no-cache add $REQ >&2
for p in $OPT; do
  apk --root "$R" --no-scripts --no-cache add "$p" >&2 || echo "optional package $p skipped" >&2
done
rm -rf "$R/lib/apk" "$R/etc/apk" "$R/var/cache" "$R/usr/share/man" "$R/usr/share/doc"
tar -C /opt -cf - "$PKG"
EOF
  [[ "$(stat -c %s "$WORK/$PKG.tar")" -gt 1000000 ]] || { warn "tree archive looks empty"; return 1; }
  ALPINE_TREE="$WORK/$PKG.tar"
}

# Install + verify + switch the files. Does not restart anything.
install_alpine() {
  local c=$1
  build_alpine_tree || return 1
  log "[$c] installing PHP tree into /opt/$PKG"
  docker exec -i -e PKG="$PKG" "$c" sh -c 'rm -rf "/opt/$PKG" && mkdir -p /opt && tar -C /opt -xf -' \
    < "$ALPINE_TREE" || return 1

  log "[$c] creating wrappers and verifying the new PHP before switching"
  docker exec -i -e PKG="$PKG" -e MIN="$TARGET_MIN" "$c" sh -s <<'EOF' || return 1
set -eu
R=/opt/$PKG
CONF=$R/etc/$PKG/conf.d
[ -x "$R/usr/bin/$PKG" ] && [ -e "$R/lib/ld-musl-x86_64.so.1" ] || { echo "incomplete tree in $R"; exit 1; }
FPM=$(ls "$R"/usr/sbin/php-fpm* | head -n1)
# ICU looks for its data at an absolute path (/usr/share/icu/..) that does not exist
# outside our /opt tree; without this, Magento fails with "No such time zone: 'UTC'"
ICU=$(ls -d "$R"/usr/share/icu/* 2>/dev/null | head -n1)
[ -n "$ICU" ] || { echo "no ICU data directory in $R/usr/share/icu"; exit 1; }

mkdir -p /opt/php-update
mk() {  # wrapper-name binary extra-args
  cat > "/opt/php-update/$1" <<EOT
#!/bin/sh
export ICU_DATA=$ICU PHPRC=$R/etc/$PKG PHP_INI_SCAN_DIR=$CONF
exec $R/lib/ld-musl-x86_64.so.1 --library-path $R/lib:$R/usr/lib $2 -d extension_dir=$R/usr/lib/$PKG/modules $3 "\$@"
EOT
  chmod 755 "/opt/php-update/$1"
}
mk php "$R/usr/bin/$PKG" ""
mk php-fpm "$FPM" "-p /usr/local"

# carry over the old image's non-extension ini tweaks (memory_limit, short_open_tag, ...)
for f in /usr/local/etc/php/conf.d/*.ini; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in docker-php-ext-*) continue ;; esac
  cp "$f" "$CONF/99-legacy-$(basename "$f")"
done
# old build had no php.ini -> $_ENV was populated; keep that
printf 'variables_order = "EGPCS"\n' > "$CONF/99-legacy-compat.ini"

ver=$(/opt/php-update/php -r 'echo PHP_VERSION;')
echo "new php: $ver"
[ "$(printf '%s\n%s\n' "$ver" "$MIN" | sort -V | head -n1)" = "$MIN" ] || { echo "version $ver is older than $MIN"; exit 1; }

# functional check: ICU data (time zones, locales) must be usable
/opt/php-update/php -r 'try { new IntlDateFormatter("en_US", 3, 3, "UTC"); new NumberFormatter("en_US", NumberFormatter::DECIMAL); } catch (Throwable $e) { fwrite(STDERR, "intl check failed: " . $e->getMessage() . "\n"); exit(1); }' \
  || { echo "ICU data is not usable by the new PHP"; exit 1; }

out=$(/opt/php-update/php -m 2>&1)
if echo "$out" | grep -qiE 'warning|unable to load|fatal'; then echo "$out" | grep -iE 'warning|unable|fatal'; exit 1; fi
mods=$(echo "$out" | tr 'A-Z' 'a-z')
missing=
for m in bcmath ctype curl dom fileinfo gd iconv intl mbstring mysqli mysqlnd openssl pdo pdo_mysql pdo_pgsql session simplexml soap sockets sodium tokenizer xml xmlreader xmlwriter xsl zip pcntl posix; do
  echo "$mods" | grep -qx "$m" || missing="$missing $m"
done
[ -z "$missing" ] || { echo "missing modules:$missing"; exit 1; }
echo "optional modules present: $(echo "$mods" | grep -xE 'opcache|apcu|igbinary|redis|imagick|memcached|yaml|uuid|msgpack|ds|lzf|gmp|exif|calendar|bz2|ldap|tidy' | tr '\n' ' ')"

/opt/php-update/php-fpm -t -y /usr/local/etc/php-fpm.conf

sw() {  # target wrapper
  [ -e "$1.pre-php-update" ] || mv "$1" "$1.pre-php-update"
  cp "/opt/php-update/$2" "$1"
  chmod 755 "$1"
}
sw /usr/local/bin/php php
sw /usr/local/sbin/php-fpm php-fpm
EOF
}

rollback_alpine() {
  docker exec "$1" sh -c '
    for f in /usr/local/bin/php /usr/local/sbin/php-fpm; do
      [ -e "$f.pre-php-update" ] && { rm -f "$f"; mv "$f.pre-php-update" "$f"; }
    done
    supervisorctl restart php-fpm' >/dev/null 2>&1
}

# ---------------------------------------------------- apt-based (key + repo)
SURY_KEY=""; ONDREJ_KEY=""
fetch_key() {   # sury|ondrej
  local f
  if [[ "$1" == sury ]]; then
    [[ -n "$SURY_KEY" ]] && return 0
    f="$WORK/sury.gpg"
    curl -fsSL https://packages.sury.org/php/apt.gpg -o "$f" || return 1
    gpg --show-keys --with-colons "$f" 2>/dev/null | grep -q "^fpr:::::::::$SURY_FPR:" \
      || { warn "sury.org key fingerprint mismatch"; return 1; }
    SURY_KEY="$f"
  else
    [[ -n "$ONDREJ_KEY" ]] && return 0
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$ONDREJ_FPR" -o "$WORK/ondrej.asc" || return 1
    gpg --batch --yes --dearmor -o "$WORK/ondrej.gpg" "$WORK/ondrej.asc" || return 1
    gpg --show-keys --with-colons "$WORK/ondrej.gpg" 2>/dev/null | grep -q "^fpr:::::::::$ONDREJ_FPR:" \
      || { warn "ondrej PPA key fingerprint mismatch"; return 1; }
    ONDREJ_KEY="$WORK/ondrej.gpg"
  fi
}

# --------------------------------------------------------- debian-docker family
install_debian_docker() {
  local c=$1
  fetch_key sury || return 1
  docker cp "$SURY_KEY" "$c:/usr/share/keyrings/sury-php.gpg" || return 1

  log "[$c] installing php$PHP_BRANCH packages from packages.sury.org (apt)"
  docker exec -i -e B="$PHP_BRANCH" -e MIN="$TARGET_MIN" "$c" sh -s <<'EOF' || return 1
set -eu
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
# the official php image pins every php* package to -1 so apt cannot replace its
# source-built PHP; that is exactly what we are doing here
rm -f /etc/apt/preferences.d/no-debian-php
echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ $VERSION_CODENAME main" \
  > /etc/apt/sources.list.d/php-update.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl \
  php$B-cli php$B-common php$B-gd php$B-mysql php$B-mbstring php$B-xml php$B-curl php$B-sqlite3 php$B-readline >/dev/null
# the old image had no php.ini: keep $_ENV populated and short tags on
printf 'variables_order = "EGPCS"\nshort_open_tag = On\n' > /etc/php/$B/cli/conf.d/99-legacy-compat.ini

ver=$(/usr/bin/php$B -r 'echo PHP_VERSION;')
echo "new php: $ver"
[ "$(printf '%s\n%s\n' "$ver" "$MIN" | sort -V | head -n1)" = "$MIN" ] || { echo "version $ver older than $MIN"; exit 1; }
out=$(/usr/bin/php$B -m 2>&1)
if echo "$out" | grep -qiE 'warning|unable to load|fatal'; then echo "$out" | grep -iE 'warning|unable|fatal'; exit 1; fi
mods=$(echo "$out" | tr 'A-Z' 'a-z')
for m in gd mysqli mysqlnd curl dom mbstring sodium sqlite3 pdo_sqlite simplexml xml fileinfo ctype iconv session; do
  echo "$mods" | grep -qx "$m" || { echo "missing module $m"; exit 1; }
done

# switch: /usr/local/bin comes first in PATH
[ -e /usr/local/bin/php.pre-php-update ] || mv /usr/local/bin/php /usr/local/bin/php.pre-php-update
rm -f /usr/local/bin/php
ln -s /usr/bin/php$B /usr/local/bin/php
EOF
}

rollback_debian_docker() {
  docker exec "$1" sh -c '
    [ -e /usr/local/bin/php.pre-php-update ] && { rm -f /usr/local/bin/php; mv /usr/local/bin/php.pre-php-update /usr/local/bin/php; }'
  docker restart "$1" >/dev/null
}

# ------------------------------------------------------------ apt-apache family
install_apt_apache() {
  local c=$1
  fetch_key ondrej || return 1
  docker cp "$ONDREJ_KEY" "$c:/usr/share/keyrings/ondrej-php.gpg" || return 1

  log "[$c] installing php$PHP_BRANCH + mod_php from ppa:ondrej/php (apt)"
  docker exec -i -e B="$PHP_BRANCH" -e MIN="$TARGET_MIN" "$c" sh -s <<'EOF' || return 1
set -eu
export DEBIAN_FRONTEND=noninteractive
. /etc/os-release
mkdir -p /opt/php-update
OLD=$(basename "$(ls /etc/apache2/mods-enabled/php*.load | head -n1)" .load)
echo "deb [signed-by=/usr/share/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $VERSION_CODENAME main" \
  > /etc/apt/sources.list.d/php-update.list
apt-get update -qq
# keep apt from restarting apache (two mod_php versions loaded at once would fail)
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT
extra=""; apt-cache show php$B-opcache >/dev/null 2>&1 && extra="php$B-opcache"
apt-get install -y -qq --no-install-recommends ca-certificates curl \
  php$B-cli php$B-cgi php$B-common php$B-intl php$B-pgsql php$B-readline libapache2-mod-php$B $extra >/dev/null
rm -f /usr/sbin/policy-rc.d; trap - EXIT

ver=$(/usr/bin/php$B -r 'echo PHP_VERSION;')
echo "new php: $ver"
[ "$(printf '%s\n%s\n' "$ver" "$MIN" | sort -V | head -n1)" = "$MIN" ] || { echo "version $ver older than $MIN"; exit 1; }
mods=$(/usr/bin/php$B -m 2>&1 | tr 'A-Z' 'a-z')
for m in intl pgsql pdo_pgsql json; do echo "$mods" | grep -qx "$m" || { echo "missing module $m"; exit 1; }; done

# switch the Apache module (takes effect at the next Apache start/restart)
echo "$OLD" > /opt/php-update/old-apache-php
echo "php$B" > /opt/php-update/new-apache-php
a2dismod "$OLD" >/dev/null
a2enmod "php$B" >/dev/null
update-alternatives --set php "/usr/bin/php$B" >/dev/null 2>&1 || true
EOF
}

rollback_apt_apache() {
  docker exec "$1" sh -c '
    [ -f /opt/php-update/old-apache-php ] || exit 0
    OLD=$(cat /opt/php-update/old-apache-php); NEW=$(cat /opt/php-update/new-apache-php)
    a2dismod "$NEW" >/dev/null 2>&1; a2enmod "$OLD" >/dev/null
    update-alternatives --set php "/usr/bin/$OLD" >/dev/null 2>&1 || true
    service apache2 restart >/dev/null 2>&1
    rm -f /opt/php-update/old-apache-php /opt/php-update/new-apache-php'
}

# ------------------------------------------------------- kind dispatch helpers
do_install()  { case "$2" in alpine-fpm) install_alpine "$1" ;; debian-docker) install_debian_docker "$1" ;; apt-apache) install_apt_apache "$1" ;; *) return 1 ;; esac; }
do_rollback() { case "$2" in alpine-fpm) rollback_alpine "$1" ;; debian-docker) rollback_debian_docker "$1" ;; apt-apache) rollback_apt_apache "$1" ;; esac; }
do_restart()  {
  case "$2" in
    alpine-fpm)    docker exec "$1" supervisorctl restart php-fpm ;;
    debian-docker) docker restart "$1" >/dev/null ;;
    apt-apache)    docker exec "$1" sh -c 'apache2ctl configtest && service apache2 restart' ;;
  esac
}
health_url() {
  local port
  case "$2" in
    alpine-fpm)    echo "http://127.0.0.1/" ;;
    debian-docker) port="$(docker inspect -f '{{join .Config.Cmd " "}}' "$1" | sed -n 's/.*-S [^ :]*:\([0-9]*\).*/\1/p')"
                   echo "http://127.0.0.1:${port:-9980}/" ;;
    apt-apache)    echo "http://127.0.0.1:8080/status.php" ;;
  esac
}

# Patch a RUNNING container in place and health-check it.
patch_live() {
  local c=$1 kind=$2 url base new
  url="$(health_url "$c" "$kind")"
  base="$(http_code "$c" "$url")"
  log "[$c] baseline HTTP code: ${base:-none}"
  do_install "$c" "$kind" || { warn "[$c] install failed"; do_rollback "$c" "$kind"; return 1; }
  log "[$c] restarting the PHP service"
  do_restart "$c" "$kind" || { warn "[$c] restart failed, rolling back"; do_rollback "$c" "$kind"; return 1; }
  new="$(wait_ok "$c" "$url" 90)"
  log "[$c] HTTP code after switch: ${new:-none}"
  if { [[ "$kind" == alpine-fpm ]] && ! docker exec "$c" supervisorctl status php-fpm 2>/dev/null | grep -q RUNNING; } \
     || { ok_code "$base" && ! ok_code "$new"; }; then
    warn "[$c] health check failed, rolling back"
    do_rollback "$c" "$kind"
    return 1
  fi
  if docker exec "$c" test -x /var/www/magento2/bin/magento 2>/dev/null; then
    docker exec "$c" php /var/www/magento2/bin/magento --version 2>&1 | tail -n1 \
      | sed "s/^/[$c] magento CLI under new PHP: /"
  fi
  log "[$c] now running: $(docker exec "$c" php -r 'echo PHP_VERSION;')"
}

# ------------------------------------------------------------------- baking
image_fixed() {  # image-ref -> 0 if the image already contains a fixed PHP
  local v
  v="$(docker run --rm --entrypoint php "$1" -r 'echo PHP_VERSION;' 2>/dev/null)" || return 1
  is_fixed "$v" || return 1
  # image baked by an earlier version of this script (wrapper without ICU_DATA): not good enough
  ! docker run --rm --entrypoint sh "$1" -c '[ -e /opt/php-update/php ] && ! grep -q ICU_DATA /usr/local/bin/php' >/dev/null 2>&1
}

# Patch a throw-away container of the image (app NOT started) and commit it
# back over the same tag. The original stays as <ref>-pre-php-update.
bake_image() {
  local ref=$1 kind=$2 tmp="phpfix-bake-$$" ep cmd ver bak chg=()
  ep="$(docker image inspect -f '{{json .Config.Entrypoint}}' "$ref")"; [[ "$ep" == null ]] && ep='[]'
  cmd="$(docker image inspect -f '{{json .Config.Cmd}}' "$ref")";       [[ "$cmd" == null ]] && cmd='[]'

  log "[$ref] starting throw-away container (entrypoint overridden, app not started)"
  docker run -d --name "$tmp" --entrypoint sleep "$ref" 86400 >/dev/null || return 1
  TMPC="$tmp"

  if ! do_install "$tmp" "$kind"; then
    warn "[$ref] install/verification failed; image left untouched"
    docker rm -f "$tmp" >/dev/null 2>&1; TMPC=""
    return 1
  fi
  [[ "$kind" == alpine-fpm ]] || docker exec "$tmp" sh -c 'rm -rf /var/lib/apt/lists/*' >/dev/null 2>&1
  ver="$(docker exec "$tmp" php -r 'echo PHP_VERSION;')"
  log "[$ref] throw-away container now has PHP $ver"

  bak="$ref-pre-php-update"
  # never overwrite an existing backup (a refresh of an already baked image must keep the ORIGINAL)
  if ! docker image inspect "$bak" >/dev/null 2>&1; then
    docker tag "$ref" "$bak" || { docker rm -f "$tmp" >/dev/null 2>&1; TMPC=""; return 1; }
  fi
  chg=(--change "ENTRYPOINT $ep" --change "CMD $cmd" --change "LABEL php-update.version=$ver")
  [[ "$kind" == apt-apache ]] || chg+=(--change "ENV PHP_VERSION=$ver")
  docker commit "${chg[@]}" "$tmp" "$ref" >/dev/null \
    || { warn "[$ref] docker commit failed"; docker rm -f "$tmp" >/dev/null 2>&1; TMPC=""; return 1; }
  docker rm -f "$tmp" >/dev/null 2>&1; TMPC=""
  log "[$ref] baked: tag now points at the patched image; original kept as $bak"
}

containers_of() {   # image-ref -> names of all containers (any state) created from it
  local n
  while read -r n; do
    [[ -n "$n" && "$(ref_of "$n")" == "$1" ]] && echo "$n"
  done < <(docker ps -a --format '{{.Names}}')
}

# ---------------------------------------------------------------- rollback
if ((ROLLBACK)); then
  while read -r img; do
    [[ "$img" == *-pre-php-update ]] || continue
    orig="${img%-pre-php-update}"
    if ((DRY_RUN)); then log "would retag $img -> $orig"; else
      docker tag "$img" "$orig" && log "image tag restored: $orig (old baked image becomes untagged; 'docker image prune' removes it)"
    fi
  done < <(docker images --format '{{.Repository}}:{{.Tag}}')
  mapfile -t RUNNING < <(docker ps --format '{{.Names}}')
  for c in "${RUNNING[@]}"; do
    [[ -z "$ONLY" || ",$ONLY," == *",$c,"* ]] || continue
    probe "$c" || continue
    if ((DRY_RUN)); then log "would roll back live container $c [$P_KIND]"; continue; fi
    docker exec "$c" sh -c '[ -e /usr/local/bin/php.pre-php-update ] || [ -e /opt/php-update/old-apache-php ]' || continue
    log "[$c] rolling back live container"
    do_rollback "$c" "$P_KIND"
  done
  log "rollback finished. Containers created from the restored images need re-creation (reset scripts 02..05)."
  exit 0
fi

# ---------------------------------------------------------------- main scan
mapfile -t ALL < <(docker ps --format '{{.Names}}')
[[ ${#ALL[@]} -gt 0 ]] || die "no running containers; start them first"

declare -a TODO=() SKIPPED=() UNSUPPORTED=()
log "scanning ${#ALL[@]} running containers (target PHP $PHP_BRANCH, fixed from $TARGET_MIN)"
for c in "${ALL[@]}"; do
  [[ -z "$ONLY" || ",$ONLY," == *",$c,"* ]] || continue
  probe "$c" || continue                 # no PHP in this container
  if is_fixed "$P_VER"; then
    if [[ "$P_KIND" == alpine-fpm ]] && wrapper_stale "$c"; then
      log "[$c] PHP $P_VER is fixed but was set up by an earlier version of this script (no ICU_DATA): will refresh"
    elif [[ "$P_KIND" == alpine-fpm ]] && ((! LIVE)) && ! image_fixed "$(ref_of "$c")"; then
      log "[$c] container is fine, but its IMAGE still has the old wrapper (no ICU_DATA): image will be refreshed"
      log "[$c] (pass --keep-containers to leave this running container alone)"
    else
      SKIPPED+=("$c ($P_VER already fixed)"); continue
    fi
  fi
  if [[ "$P_KIND" == unsupported ]]; then UNSUPPORTED+=("$c ($P_VER on $P_OS)"); continue; fi
  TODO+=("$c|$P_KIND|$P_VER")
done

for s in ${SKIPPED[@]+"${SKIPPED[@]}"};         do log "skip: $s"; done
for s in ${UNSUPPORTED[@]+"${UNSUPPORTED[@]}"}; do warn "unsupported layout, fix manually: $s"; done
[[ ${#TODO[@]} -gt 0 ]] || { log "nothing to do"; exit $(( ${#UNSUPPORTED[@]} > 0 )); }

# ------------------------------------------------------------- live mode
if ((LIVE)); then
  for t in "${TODO[@]}"; do IFS='|' read -r c k v <<<"$t"; log "plan (live): patch $c  $v  [$k]"; done
  ((DRY_RUN)) && { log "dry run: no changes made"; exit 0; }
  FAILED=0
  for t in "${TODO[@]}"; do
    IFS='|' read -r c k v <<<"$t"
    patch_live "$c" "$k" || { warn "[$c] FAILED (rolled back)"; FAILED=$((FAILED + 1)); }
  done
  log "live patch finished. NOTE: re-creating a container (reset) brings the old PHP back; use the default --bake mode to avoid that."
  ((FAILED)) && exit 1
  exit 0
fi

# ------------------------------------------------------------- bake mode
declare -A IMG_KIND=()       # image ref -> kind
declare -a LIVE_NOW=()       # containers that are patched live as well (not recreated by reset)
for t in "${TODO[@]}"; do
  IFS='|' read -r c k v <<<"$t"
  ref="$(ref_of "$c")"
  if [[ "$ref" =~ ^(sha256:)?[0-9a-f]{12,64}:latest$ || "$ref" == sha256:* ]]; then
    warn "[$c] uses an untagged image ($ref); cannot bake, use --live for it"; continue
  fi
  IMG_KIND["$ref"]="$k"
  [[ "$k" == apt-apache ]] && LIVE_NOW+=("$c")
done
[[ ${#IMG_KIND[@]} -gt 0 ]] || { log "nothing to bake"; exit 0; }

declare -a REMOVE=()
for ref in "${!IMG_KIND[@]}"; do
  [[ "${IMG_KIND[$ref]}" == apt-apache ]] && continue
  while read -r n; do [[ -n "$n" ]] && REMOVE+=("$n|$ref"); done < <(containers_of "$ref")
done

echo
log "PLAN"
for ref in "${!IMG_KIND[@]}"; do log "  bake image:   $ref  [${IMG_KIND[$ref]}]   (backup tag: $ref-pre-php-update)"; done
for c in ${LIVE_NOW[@]+"${LIVE_NOW[@]}"}; do log "  patch live:   $c  (stateful, not recreated by the reset)"; done
if ((KEEP)); then
  log "  containers:   kept (--keep-containers); they keep running the OLD php until re-created"
else
  for r in ${REMOVE[@]+"${REMOVE[@]}"}; do
    IFS='|' read -r n ref <<<"$r"
    log "  stop+remove:  $n  ($(docker inspect -f '{{.State.Status}}' "$n"), image $ref)  <- runtime state of this container is lost"
  done
fi
echo
((DRY_RUN)) && { log "dry run: no changes made"; exit 0; }
confirm "Proceed?" || die "aborted"

FAILED=0
declare -A BAKED=()
for ref in "${!IMG_KIND[@]}"; do
  if image_fixed "$ref"; then
    log "[$ref] image already contains a fixed PHP, nothing to bake"
    BAKED["$ref"]=1
  elif bake_image "$ref" "${IMG_KIND[$ref]}"; then
    BAKED["$ref"]=1
  else
    FAILED=$((FAILED + 1))
  fi
done

for c in ${LIVE_NOW[@]+"${LIVE_NOW[@]}"}; do
  patch_live "$c" apt-apache || { warn "[$c] live patch FAILED (rolled back)"; FAILED=$((FAILED + 1)); }
done

if ! ((KEEP)); then
  for r in ${REMOVE[@]+"${REMOVE[@]}"}; do
    IFS='|' read -r n ref <<<"$r"
    [[ -n "${BAKED[$ref]:-}" ]] || { warn "[$n] kept (its image was not baked)"; continue; }
    [[ "$(docker inspect -f '{{.Image}}' "$n")" == "$(tag_id "$ref")" ]] && continue   # already on the new image
    log "[$n] stopping and removing (old image)"
    docker stop -t 30 "$n" >/dev/null 2>&1
    docker rm "$n" >/dev/null || warn "[$n] could not be removed"
  done
fi

echo
if ((FAILED)); then
  warn "$FAILED step(s) failed; see messages above (failed images were not modified). Try PHP_BRANCH=8.3 or investigate."
fi
log "NEXT: re-create the removed containers with your normal reset flow (02..05 in webarena/ or visualwebarena/,"
log "      or the reset server). They are now created from the patched images, no need to run this script again."
((FAILED)) && exit 1
exit 0
