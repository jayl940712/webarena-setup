#!/usr/bin/env bash
#
# test_php.sh - verify that every PHP on this machine is a fixed release
# (PHP2Shell, CVE-2026-109618 / CVE-2026-109619, https://www.php2shell.com/#upgrade-php)
#
# Read-only: it only inspects. For every running container with PHP it checks
#   - the PHP CLI version,
#   - the php-fpm binary version (if any),
#   - the versions of the PHP processes that are ACTUALLY RUNNING right now
#     (php-fpm master/workers, php -S server, Apache mod_php), so a container
#     that was patched on disk but not restarted is reported as FAIL,
#   - the enabled Apache PHP modules,
#   - that the site still answers over HTTP (smoke test).
# It also checks the PHP in every local image (what a re-created container
# would run) and the host's own php, if any.
#
# Fixed releases: 8.2 >= 8.2.35, 8.3 >= 8.3.36, 8.4 >= 8.4.27, 8.5 >= 8.5.12.
# 8.1 and older have no fix.
#
# Usage: ./test_php.sh [--containers-only] [--images-only]
# Exit status: 0 = everything fixed, 1 = at least one FAIL.
set -uo pipefail

DO_CONTAINERS=1
DO_IMAGES=1
case "${1:-}" in
  --containers-only) DO_IMAGES=0 ;;
  --images-only)     DO_CONTAINERS=0 ;;
  "") ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

declare -A FIXED=([8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12)

command -v docker >/dev/null || { echo "docker not found" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "cannot talk to docker (run with sudo?)" >&2; exit 2; }

NPASS=0; NFAIL=0; NWARN=0
pass() { NPASS=$((NPASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { NFAIL=$((NFAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
warn() { NWARN=$((NWARN + 1)); printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info() { printf '  INFO %s\n' "$*"; }

ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }
is_fixed() {    # "8.2.35" / "8.1.2-1ubuntu2.28" -> 0 if a fixed release
  local base="${1%%-*}" br
  br="${base%.*}"
  [[ -n "${FIXED[$br]:-}" ]] && ver_ge "$base" "${FIXED[$br]}"
}
need() {        # version -> what to upgrade to
  local base="${1%%-*}" br
  br="${base%.*}"
  if [[ -n "${FIXED[$br]:-}" ]]; then echo ">= ${FIXED[$br]}"
  else echo "an upgrade to 8.2.35+ / 8.3.36+ / 8.4.27+ / 8.5.12+ (no fix exists for $br)"; fi
}
ok_code() { [[ "$1" =~ ^[1-4][0-9][0-9]$ ]]; }

# Runs inside the container (busybox-compatible sh). Prints "key|value..." lines.
read -r -d '' CONTAINER_CHECK <<'EOF'
cli=$(php -r 'echo PHP_VERSION;' 2>/dev/null)
echo "cli|${cli:-none}"
fv=$(php-fpm -v 2>/dev/null | sed -n '1s/^PHP \([0-9][0-9.]*\).*/\1/p')
[ -n "$fv" ] && echo "fpmbin|$fv"
if php -m 2>/dev/null | grep -qix intl; then
  r=$(php -r 'try { new IntlDateFormatter("en_US", 3, 3, "UTC"); new NumberFormatter("en_US", NumberFormatter::DECIMAL); echo "ok"; } catch (Throwable $e) { echo "fail: " . $e->getMessage(); }' 2>&1)
  echo "intl|$r"
fi
mods=$(ls /etc/apache2/mods-enabled/php*.load 2>/dev/null | sed 's#.*/##; s#\.load$##' | tr '\n' ' ')
[ -n "$mods" ] && echo "apachemods|$mods"
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  exe=$(readlink "$d/exe" 2>/dev/null) || continue
  case "$exe" in *php*|*ld-musl*|*apache2*) ;; *) continue ;; esac
  case "$exe" in
    *apache2*)
      lib=$(grep -oE 'libphp[0-9.]+\.so' "$d/maps" 2>/dev/null | head -n1)
      [ -n "$lib" ] || continue
      b=${lib#libphp}; b=${b%.so}
      v=$(dpkg-query -W -f='${Version}' "libapache2-mod-php$b" 2>/dev/null | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')
      echo "proc|mod_php|${v:-unknown}|$lib" ;;
    *ld-musl*)
      opt=$(grep -oE '/opt/php[0-9]+/usr/(sbin/php-fpm|bin/php)[0-9]*' "$d/maps" 2>/dev/null | head -n1)
      [ -n "$opt" ] || continue
      case "$opt" in *php-fpm*) w=/opt/php-update/php-fpm ;; *) w=/opt/php-update/php ;; esac
      v=$($w -v 2>/dev/null | sed -n '1s/^PHP \([0-9][0-9.]*\).*/\1/p')
      echo "proc|opt-tree|${v:-unknown}|$opt" ;;
    *)
      v=$("$d/exe" -v 2>/dev/null | sed -n '1s/^PHP \([0-9][0-9.]*\).*/\1/p')
      note=""
      case "$exe" in *pre-php-update*|*"(deleted)"*) note=" [OLD binary still running: restart/recreate needed]" ;; esac
      echo "proc|binary|${v:-unknown}|$exe$note" ;;
  esac
done
EOF

smoke_url() {   # container -> url (or empty)
  local c=$1 cmd port
  cmd="$(docker inspect -f '{{join .Config.Cmd " "}}' "$c")"
  port="$(sed -n 's/.*-S [^ :]*:\([0-9]*\).*/\1/p' <<<"$cmd")"
  if [[ -n "$port" ]]; then echo "http://127.0.0.1:$port/"; return; fi
  if docker exec "$c" sh -c 'ls /etc/apache2/mods-enabled/php*.load >/dev/null 2>&1'; then
    echo "http://127.0.0.1:8080/status.php"; return
  fi
  if docker exec "$c" sh -c 'command -v php-fpm >/dev/null 2>&1 || [ -e /usr/local/sbin/php-fpm ]'; then
    echo "http://127.0.0.1/"; return
  fi
}

# ------------------------------------------------------------- containers
if ((DO_CONTAINERS)); then
  echo "== Running containers"
  mapfile -t ALL < <(docker ps --format '{{.Names}}')
  found=0
  for c in "${ALL[@]}"; do
    out="$(docker exec -i "$c" sh -s <<<"$CONTAINER_CHECK" 2>/dev/null)" || continue
    cli="$(sed -n 's/^cli|//p' <<<"$out" | head -n1)"
    [[ -n "$cli" && "$cli" != none ]] || continue            # no PHP here
    found=1
    echo "[$c]"

    if is_fixed "$cli"; then pass "CLI php $cli"
    else fail "CLI php $cli (need $(need "$cli"))"; fi

    fpm="$(sed -n 's/^fpmbin|//p' <<<"$out" | head -n1)"
    if [[ -n "$fpm" ]]; then
      if is_fixed "$fpm"; then pass "php-fpm binary $fpm"
      else fail "php-fpm binary $fpm (need $(need "$fpm"))"; fi
    fi

    intl="$(sed -n 's/^intl|//p' <<<"$out" | head -n1)"
    if [[ "$intl" == ok ]]; then pass "intl/ICU works (time zones, locales)"
    elif [[ -n "$intl" ]]; then fail "intl/ICU broken: $intl (apps such as Magento return HTTP 500)"; fi

    mods="$(sed -n 's/^apachemods|//p' <<<"$out" | head -n1)"
    for m in $mods; do
      b="${m#php}"
      if [[ -n "${FIXED[$b]:-}" ]]; then pass "Apache module $m enabled"
      else fail "Apache module $m enabled (branch $b has no fix)"; fi
    done

    declare -A GROUP=()
    while IFS='|' read -r _ kind v extra; do
      GROUP["$kind|$v|$extra"]=$(( ${GROUP["$kind|$v|$extra"]:-0} + 1 ))
    done < <(grep '^proc|' <<<"$out")
    if ((${#GROUP[@]} == 0)); then
      info "no running PHP server process found (container idle or PHP started on demand)"
    fi
    for k in "${!GROUP[@]}"; do
      IFS='|' read -r kind v extra <<<"$k"
      n="${GROUP[$k]}"
      label="running $kind ($n process$([[ $n -gt 1 ]] && echo es)) php $v  $extra"
      if [[ "$v" == unknown ]]; then warn "$label: version could not be determined"
      elif [[ "$extra" == *"OLD binary"* ]] || ! is_fixed "$v"; then fail "$label"
      else pass "$label"; fi
    done
    unset GROUP

    url="$(smoke_url "$c")"
    if [[ -n "$url" ]]; then
      code="$(docker exec "$c" curl -s -o /dev/null -m 120 -w '%{http_code}' "$url" 2>/dev/null || true)"
      if ok_code "$code"; then pass "site answers: $url -> HTTP $code"
      else fail "site does not answer: $url -> HTTP ${code:-none}"; fi
    fi
  done
  ((found)) || warn "no running container with PHP found (are the containers started?)"
fi

# ----------------------------------------------------------------- images
if ((DO_IMAGES)); then
  echo "== Local images (what a re-created container would run)"
  mapfile -t IMGS < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
  for img in "${IMGS[@]}"; do
    v="$(timeout 120 docker run --rm --entrypoint php "$img" -r 'echo PHP_VERSION;' 2>/dev/null)" || continue
    [[ -n "$v" ]] || continue
    if [[ "$img" == *-pre-php-update ]]; then
      info "$img: php $v (backup of the original image, vulnerable on purpose; do not run it)"
    elif is_fixed "$v"; then pass "image $img: php $v"
    else fail "image $img: php $v (need $(need "$v"))"; fi
  done
fi

# ------------------------------------------------------------------- host
echo "== Host"
if command -v php >/dev/null; then
  hv="$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
  if is_fixed "$hv"; then pass "host php $hv"; else fail "host php $hv"; fi
else
  info "no php on the host"
fi

echo
printf 'Result: %d passed, %d failed, %d warnings\n' "$NPASS" "$NFAIL" "$NWARN"
if ((NFAIL)); then
  echo "NOT fully fixed. Containers still showing an old PHP need re-creating (reset 02..05) or restarting; see README."
  exit 1
fi
echo "All checked PHP installations are on a fixed release."
