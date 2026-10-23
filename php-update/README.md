# php-update: fix PHP2Shell (CVE-2026-109618 / CVE-2026-109619) in the containers

[PHP2Shell](https://www.php2shell.com/#upgrade-php) is a critical flaw in PHP itself. The only
complete fix is a fixed PHP release: **8.2.35, 8.3.36, 8.4.27 or 8.5.12** (PHP 8.1 and older get
no official fix).

`fix_php.sh` upgrades PHP from prebuilt packages. **Nothing is compiled.** By default it
**bakes the fix into the docker images**, so containers created by the reset scripts are already
patched and you do not have to run anything after a reset.

## What it fixes

| Container(s) | Base | Was | Method |
|---|---|---|---|
| `shopping`, `shopping_admin`, `forum` | Alpine 3.16, PHP built from source | 8.1.17 | PHP 8.2.35 from Alpine 3.22 packages, installed as a self-contained tree in `/opt/php82`. It runs through its own musl loader, so the old Alpine userland (MySQL, nginx, ...) is untouched. `/usr/local/bin/php` and `/usr/local/sbin/php-fpm` become small wrappers. The existing `php-fpm.conf` / `php-fpm.d` pool settings (including the tuning from `05_docker_patch_containers.sh`) are reused. |
| `classifieds` | Debian 12 (official `php` image) | 8.1.27 | `php8.2-*` packages from [packages.sury.org](https://packages.sury.org); `/usr/local/bin/php` is pointed at `/usr/bin/php8.2`. |
| `nominatim` | Ubuntu 22.04, Apache + mod_php | 8.1.2 | `php8.2` + `libapache2-mod-php8.2` from `ppa:ondrej/php`; Apache module swapped. |

Containers are discovered automatically (every *running* container that has `php`), so the same
script works on another machine with the same setup. Containers without PHP (gitlab, openstreetmap,
wikipedia, osrm, ...) are ignored; containers already on a fixed version are skipped.

**Why 8.2?** It is the closest fixed branch to 8.1 and the newest one that Magento 2.4.6
(`shopping*`) and Postmill (`forum`) officially support. Newer branches are selectable
(`PHP_BRANCH`, see below) but are more likely to break those apps.

## How the default (bake) mode works

For every image used by a running container with vulnerable PHP:

1. A throw-away container is started from the image with its entrypoint overridden
   (`sleep`), so **the app/database is never started and no runtime state is captured**.
2. PHP is upgraded in it and verified (version, required modules, `php-fpm -t`).
3. It is committed back over the **same image tag**. The original image stays available as
   `<repo>:<tag>-pre-php-update` (for rollback).
4. The old containers created from the old image are **stopped and removed** (running or not;
   their runtime state is lost, exactly like in a normal reset). You then re-create them with the
   normal reset flow, which now uses the patched images.

`nominatim` is special: it keeps its data in docker volumes and is not re-created by the reset,
so it is additionally patched **live** (Apache restart, HTTP health check, automatic rollback)
and is **not** stopped or removed.

The script asks for confirmation before it stops/removes anything (`--yes` skips the prompt).

## How to run

Requirements on the host: `docker` (run with `sudo` or as a docker-group user), `curl`, `tar`,
`gpg`, internet access (Alpine mirror, packages.sury.org, ppa.launchpadcontent.net,
keyserver.ubuntu.com, Docker Hub for the small `alpine:3.22` helper image). Free disk: about
1 GB (the images only gain a small extra layer; the big base layers are shared).

1. Containers whose PHP should be fixed must be **running** (the script finds images through
   running containers). The current state of the machine is fine.
2. Preview (changes nothing):
   ```bash
   cd php-update
   sudo ./fix_php.sh --dry-run
   ```
   It prints which images will be baked and which containers will be stopped and removed.
3. Run it:
   ```bash
   sudo ./fix_php.sh
   ```
   It lists the plan and asks `Proceed? [y/N]`. Expect roughly 5-15 minutes (package downloads).
   To test with one image first: `sudo ./fix_php.sh --only classifieds`.
4. Re-create the removed containers with your normal reset flow, e.g. for the setup in this repo
   ```bash
   cd ../webarena            # the 02 script removes/recreates shopping, shopping_admin, forum, gitlab, ...
   sudo bash 02_docker_remove_containers.sh
   sudo bash 03_docker_create_containers.sh
   sudo bash 04_docker_start_containers.sh
   sudo bash 05_docker_patch_containers.sh
   ```
   (or `cd ../visualwebarena` for the VisualWebArena set, or trigger the reset server). Run the
   set that matches how this machine is normally set up.
5. Verify:
   ```bash
   for c in shopping shopping_admin forum classifieds nominatim; do
     echo -n "$c: "; docker exec $c php -r 'echo PHP_VERSION, "\n";'
   done
   ```
   All should print 8.2.35 or later (only containers that exist on the machine, of course).
   Then click through the sites as in the normal "Safety check" of the setup README.

From now on every reset (02..05 or the reset server) creates patched containers. You only run the
script again if you load fresh original images (e.g. `01_docker_load_images.sh` from the downloaded
tar files, which brings back the vulnerable PHP).

## Test that everything is fixed

`test_php.sh` is read-only and checks, for every running container with PHP: the CLI version, the
php-fpm binary, the versions of the PHP processes that are **actually running** (so a container that
was patched but not restarted/recreated shows up as FAIL), the enabled Apache PHP modules, and that
the site still answers over HTTP. It also checks the PHP in every local image and on the host.

```bash
cd php-update
sudo ./test_php.sh                     # containers + images + host
sudo ./test_php.sh --containers-only   # or --images-only
```

Exit status 0 and the line `All checked PHP installations are on a fixed release.` mean you are
done. Any `FAIL` names the container/image and what to do. Run it before the fix to see the
baseline (all FAIL) and again after the reset. `*-pre-php-update` backup images are reported as INFO
(vulnerable on purpose; never run them).

## Options

```
sudo ./fix_php.sh [--dry-run] [--live] [--rollback] [--yes] [--keep-containers] [--only a,b]

--dry-run          show the plan, change nothing
--live             do NOT touch images: patch running containers in place (health-checked,
                   auto-rollback). Lost when a container is re-created.
--keep-containers  bake images but leave old containers alone (they keep running the old,
                   vulnerable PHP until you re-create them)
--yes              no confirmation prompt
--rollback         restore original PHP in patched live containers and re-point image tags
                   to the <tag>-pre-php-update originals
--only a,b         restrict to these container names

PHP_BRANCH=8.3 sudo -E ./fix_php.sh      # other fixed branch: 8.2 (default), 8.3, 8.4, 8.5
ALPINE_RELEASE=3.21 sudo -E ./fix_php.sh # Alpine release used as package source for 8.2
```

## Rollback

```bash
sudo ./fix_php.sh --rollback     # image tags go back to the originals; live containers restored
```
Then re-create containers (reset 02..05) so they use the original images again. The patched
images become untagged; `docker image prune` removes them (and the `-pre-php-update` tags can be
removed with `docker rmi <repo>:<tag>-pre-php-update` once you are happy).

## If something fails

* If the install or verification fails for an image, **that image is not modified** and its
  containers are not removed; the other images are unaffected. Look at the message above the
  `WARNING` (missing module, config test, ...).
* For `nominatim` (live), a failed HTTP check rolls back automatically.
* If Magento / Postmill misbehave on 8.2 after the reset, run `sudo ./fix_php.sh --rollback`
  and reset again.
* Partial mitigations if you cannot upgrade (not a fix): see "If you cannot upgrade immediately"
  on <https://www.php2shell.com/#upgrade-php>.

## Caveats

* The sury.org / Ondrej packages and the Alpine packages are third-party builds of PHP, not the
  php.net tarball. Repo signing-key fingerprints are verified before use.
* Old PECL extensions that the Alpine image had and that have no Alpine 3.22 package
  (e.g. grpc, swoole, phalcon, rdkafka, mongodb) are not carried over; neither Magento nor Postmill
  needs them. The script prints which optional modules ended up available.
* Bake mode runs `docker commit` on a throw-away container; images keep their original
  ENTRYPOINT/CMD (set explicitly during the commit) and gain a label `php-update.version`.
* This script was written without being run against these containers; use `--dry-run` first and
  try one image with `--only` before the full run.
